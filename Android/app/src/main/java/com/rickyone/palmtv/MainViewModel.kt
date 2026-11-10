package com.rickyone.palmtv

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.rickyone.palmtv.data.AuthExpiredException
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Channels
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.Epg
import com.rickyone.palmtv.data.IptvSources
import com.rickyone.palmtv.data.JiangsuTv
import com.rickyone.palmtv.data.Log
import com.rickyone.palmtv.data.Prefs
import com.rickyone.palmtv.data.YspAndroidLive
import com.rickyone.palmtv.player.PalmPlayer
import com.rickyone.palmtv.player.PlayStats
import com.rickyone.palmtv.player.PlayerHolder
import com.rickyone.palmtv.ui.Strings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** ★ 2026-10-01（与鸿蒙 `Index.ets:118` 同名同值）：回前台"轻量恢复（复用同一 URL 重新 prepare）"
 *  的适用上限；超过它就完整重新拉流。实测 22s 后台用同一 token 仍能恢复成功，故取 30s（10s 太保守）。 */
private const val REVIVE_SAME_URL_MAX_MS = 30_000L

/** 界面状态（字段与鸿蒙 `Index.ets` 的状态变量一一对应） */
data class UiState(
    val bootMsg: String = Strings.BOOT_INIT,
    val currentName: String = Strings.NO_CHANNEL,
    val activeChannelId: String = "",
    /**
     * ★★ 2026-11-04（用户实测："黑屏时换台也没用，**横屏一次就好**"）★★
     *   ⇒ 只重建 Surface（隐藏/显示）不够，必须**把整块 PlayerView 重新 inflate**，
     *     这正是横竖屏切换时 Compose 做的事。
     *   UI 侧：`key(ui.videoViewGen) { AndroidView(...) }`；这个数一变 ⇒ 旧视图销毁、新视图重建 ⇒ 新 Surface。
     */
    val videoViewGen: Int = 0,
    val playing: Boolean = false,
    val playErr: Boolean = false,
    val videoNotice: String = "",
    val gestureHint: String = "",
    val activeGroup: Channel.Group = Channel.Group.CCTV,
    val aboutTab: Boolean = false,
    val channels: List<Channel> = Channels.all,
    val epgNow: String = Strings.EPG_DASH,
    val epgNext: String = Strings.EPG_DASH,
    val epg: List<Epg.Item> = emptyList(),
    /** ★★ 2026-10-22（用户反馈）：**相对直播沿的累计时移秒数**（0 = 直播）。
     *  只在直播链路上用于 OSD；回看链路改用"相对点击节目起点的带符号秒数"（见 [replayRefSec]）。 */
    val shiftOffsetSec: Int = 0,
    /** ★★ 2026-10-22（用户要求）：时移 OSD 的**显示基准**（epoch 秒；0 = 直播模式）。
     *  · 回看：= **用户点击的那个节目单的起始时间**（固定，跨节目滑动时也**不变**）
     *    ⇒ 显示 `时移 +125 秒` / `时移 -30 秒`（正负表示相对该节目起点之后/之前）；
     *  · 直播：0 ⇒ 显示 `直播` / `时移 -10 秒`（负 = 落后直播沿多少秒）。
     *  ⚠️ 不要显示 `03:40 / 63:00` 这种"位置/时长"，用户明确要求只显示时移秒数。 */
    val replayRefSec: Long = 0,
    /** ★★ 2026-10-22：手势**待结算的目标位置**（epoch 秒）。连滑期间本地累加，抬手防抖后才真正取流 */
    val shiftPendingSec: Long = 0,
    /** ★ 2026-10-22：节目单覆盖的日期列表（yyyyMMdd，升序，过去 6 天 ~ 未来 3 天） */
    val epgDays: List<String> = emptyList(),
    val showEpg: Boolean = false,
    val showDisclaimer: Boolean = false,
    val disclaimerReadOnly: Boolean = false,
    val fullscreen: Boolean = false,
    val controlsVisible: Boolean = true,
    val locked: Boolean = false,
    val muted: Boolean = false,
    val volume: Float = 1f,
    val videoAr: Float = 0f,           // 视频**自身**的真实比例（含 PAR；0 = 未知 ⇒ UI 按 16:9 兜底）
    /** ★★ 2026-10-01（复刻鸿蒙 `videoArFix`）★★ 当前**画面上已生效**的宽高比修正（0 = 不干预）。
     *  ⚠️ 不能在渲染时用 `ASPECT_OVERRIDES[currentName]` 现查表：`playChannel` 一进来就把 `currentName`
     *     改成新台，而**旧画面此时还挂在屏上** ⇒ 修正被提前撤销 ⇒ 旧帧先弹回原始尺寸、再切到新台
     *     （用户实测"切出三个尺寸修正台还会再抖一下"）。⇒ 改为**新流的 `onVideoSizeChanged` 到达时**
     *     才切换（= 鸿蒙在新台 `prepared` 时才 `videoArFix = pendingArFix`）。 */
    val videoArFix: Float = 0f,
    val appVersion: String = "-",
    /** ★ 2026-10-21：回看/时移的起播时刻（epoch 秒；**0 = 直播**）。
     *  节目条的"正在播出/接下来"、节目单的自动定位都**以它为基准**（回看时基准是"那个节目"，不是此刻）。 */
    val replayStart: Long = 0L
)

/**
 * 主界面状态机 —— 逻辑与文案照鸿蒙 `pages/Index.ets`（取流重试/无信号回退/网络续播/EPG/手势）。
 *
 * 常量与鸿蒙一致：
 *   NET_RESUME_GAP_MS = 5000、NET_RESUME_MAX = 24、**LOCAL_DIRECT_NOPIC_MS = 15000（2026-10-02 三端统一，
 *   见 `companion object` 里的注释：安卓曾因慢源单独放宽到 18s、鸿蒙一直是 12s ⇒ 用户实测"安卓判无信号比鸿蒙慢很久"）**、
 *   EPG_REFRESH_MS = 60000
 */
class MainViewModel(app: Application) : AndroidViewModel(app) {

    private val prefs = Prefs(app)
    /**
     * ★ 2026-10-27：`StreamResolver`（Web/PC 取流链）回来了 —— **只给 8 个 ChinaDRM 台用**。
     *   原因：两条链给的**加密格式不同**
     *     · 移动端链路 → `METHOD=SM4-CBC`（ChinaDRM）⇒ CMG 解不了 ⇒ 有声音但画面绿屏
     *     · Web/PC 链路 → CMG 格式 ⇒ `cmg_rt_decrypt_ts` 能解 ✓
     */
    // ★ 2026-10-31：`webResolver`（Web/PC 取流链）已随 CMG 一起删除，见下方 resolveDrm 处的注释。
    // ★ 2026-10-01：改用**全局唯一**播放器 —— 与 `player/PlaybackService` 的 MediaSession 共用同一个
    //   ExoPlayer 实例，媒体卡片上的播放/暂停才会作用到界面正在用的播放器上（见 `player/PlayerHolder`）。
    private val player = PlayerHolder.get(app)

    private val _ui = MutableStateFlow(UiState())
    val ui: StateFlow<UiState> = _ui.asStateFlow()

    /** 播放器实例给 UI 层（PlayerView 用） */
    fun exoPlayer(): Player = player.player

    // ---- 内部状态 ----
    private var playRequestId = 0
    private var retried = false
    /** ★ 2026-10-02：直连台（IPTV/江苏）播放器报错后的**轻量重试**计数与窗口起点（慢源容忍，见 `recoverPlayer`） */
    private var directRetries = 0
    private var directRetryAt = 0L
    private var playerRebuilds = 0
    private var lastPlayingId = ""

    /** ★ 2026-10-22：**真正出过画的台**（最近 4 个，最新在前）。
     *  回退时挑"最近的、且不是当前失败台"的那个 —— 比只看 `lastPlayingId` 一个更抗揍：
     *  快速连按换台时 `onFirstFrame` 可能把**正在失败的那个台**记成"播过"（上一台的最后一帧触发），
     *  单值版本就会判"无可回退"，用户看到的就是"回退失败、台标不回退"。 */
    private val recentPlaying = java.util.ArrayDeque<String>()
    private var netDownAt = 0L
    /** ★★ 2026-10-01（与鸿蒙 `onPageHide` / `onPageShow` 对齐）★★
     *  · `hideAt`：0 = 在前台；>0 = 后台起点时刻 —— 回前台按**离场时长**决定恢复方式
     *  · `lastPlayUrl`：≤30s 内回前台时复用它（跳过 auth/签名/取流，鸿蒙 `reviveSameUrl()` 同思路）
     *  · `needRecoverOnShow`：后台期间播放器报过错 ⇒ 回前台必须**完整重新拉流**（后台不重建） */
    private var hideAt = 0L
    private var lastPlayUrl = ""
    private var needRecoverOnShow = false

    /* ★★★ 2026-10-07（央视频安卓平台链路）★★★
     *  · `currentPlaybackTime`：秒级时刻；**null = 直播**，非 null = 时移/回看（从该时刻起播）。
     *    用户换台/显式指定时重置，内部重取（看门狗/回前台/重建）**沿用** —— 否则时移看两秒就被拉回直播。
     *  · `lastPlayPlain`：这条 URL 是不是**明文**（央视频安卓平台 / jstv / iptv 都是明文）
     *    ⇒ 播放器据此**跳过 CMG 解密**。必须与 `lastPlayUrl` 成对维护（轻量重试/轻量恢复会复用它们）。 */
    private var currentPlaybackTime: Long? = null

    /**
     * ★★★ 2026-11-04：当前播放是不是"**从节目单点进来的回看**"（而不是时移）★★★
     *
     * 为什么必须区分（用户实测 bug："时移后只播一个分片就跳回直播"）：
     *   · **回看**（`playReplayFrom(newRef = true)`，节目单点进来）⇒ 取流时带 `endtime`，
     *     服务端给**整段 VOD 清单**（有 `#EXT-X-ENDLIST`）⇒ 播完会 `STATE_ENDED` ⇒ 自动接下一档 ✓；
     *   · **时移**（`newRef = false`，左右滑动）⇒ **绝不能带 `endtime`**：带上就变成"从 X 到现在的点播"，
     *     这段一播完就 `ENDED` ⇒ 走"回看结束"逻辑 ⇒ **跳回直播**（这就是用户看到的 bug）。
     *     不带 `endtime` 才是"滚动时移流"：播放位置随窗口一起前进 ⇒ **一直保持这个延迟播下去** ✓。
     */
    private var replayIsProgram: Boolean = false
    private var lastPlayPlain = false

    /** 一次"取流结果"：地址 + 是否明文（央视频安卓平台链路回来的是明文流）。 */
    private data class ResolvedPlay(val url: String, val plain: Boolean)
    /** 当前这次起播是不是"回前台的轻量恢复（复用旧 URL）"—— 失败时退化为完整重新拉流（鸿蒙同语义） */
    private var lightReviving = false
    /** ★ 下一条"视频尺寸回调"到达时要应用的宽高比修正（= 鸿蒙 `pendingArFix`）：
     *  换台时**只登记、不当场生效**，避免旧画面先弹回默认尺寸（见 `UiState.videoArFix` 注释）。 */
    private var pendingArFix = 0f

    /**
     * ★★ 2026-10-02（与鸿蒙同步修："无信号回退原台时条幅认错台"）★★
     *   **用户最后一次亲手点的频道 id**（只有 `playChannel(..., userInitiated = true)` 才刷新）。
     *
     * 为什么需要：自动回退会用 `playChannel(原台, userInitiated = false)` 把**原台**拉回来，
     *   之后原台若也判无信号，老写法会对它说"xxx 暂无信号，请点击其他频道" —— 而 xxx 正是
     *   用户**没点过**的那个原台（鸿蒙实测：看 CCTV-1、点无信号的广州电视 ⇒ 回退后条幅显示
     *   "CCTV-1 暂无信号，请点击其他频道"），用户会觉得条幅"认错了台"。
     * ⇒ 只有"失败的就是用户亲手点的那个台"才用那句口径；自动拉起的台改用中性的
     *   [Strings.INTERRUPTED_RETRY]（不提台名）。与鸿蒙 `Index.userPickedId` 同口径。
     */
    private var userPickedId = ""

    /**
     * ★★ 2026-10-02（与鸿蒙 `Index.noticeFallbackAt` 同口径）★★
     *  **最近一次展示"已切回原台"提示的时刻**。用途：接下来 5 秒内若又因"原台没出画"要走中性提示，
     *  **不动视频区浮层**（只改状态栏文案），免得把刚显示的回退提示顶掉 ——
     *  回退到的原台多是直连慢源，这一会儿没出画是正常的（用户实测：从地方台切广州台，
     *  回退条幅被"信号中断，正在自动重试…"顶掉了）。
     */
    private var noticeFallbackAt = 0L
    private var netResumeCount = 0
    private var hideControlsJob: Job? = null
    private var epgJob: Job? = null
    /** ★ 2026-10-22：时移防抖用的 job（连滑多次只发最后一次请求） */
    private var shiftSettleJob: Job? = null
    /** ★ 2026-10-22：时移 OSD 自动消失用的 job（每次滑动都会取消重建） */
    private var hintClearJob: Job? = null

    /* ==========================================================================
     * ★★★ 2026-10-22（用户反馈）：**播放位置时钟** ★★★
     *
     * ## 问题（用户实测："-50 秒与 -60 秒常落在同一位置，数字在变但起播点没变"）
     * 原来 `shiftBy()` 的基准取 `replayStart` —— 那是**上一次取流时传给服务端的 `playbacktime`**，
     * 是一个**固定不变的请求时刻**。可播放一旦开始，**真实位置就随时间往前走了**：
     *   t0     取流 playbacktime = T-50   ⇒ 从 T-50 开始播
     *   t0+30s 用户又滑 -10s
     *          旧实现：base 仍读 replayStart = T-50 ⇒ target = T-60  （相对"起播点"只退 10s）
     *          真实应在：T-20 处再退 10s        ⇒ target = T-30
     *   ⇒ **每次滑动的实际幅度都不是 10 秒**，间隔越久偏差越大（可差到几十秒）。
     *
     * ## 标准做法（对标 IPTV 机顶盒 / 主流播放器）
     * 维护一个"当前播放位置"，
     *     位置 = 起播时刻 + 已播放墙钟时长（暂停期间不计）
     * 每一次 ±10s 都是相对**这个实时位置**，与你眼睛看到的画面对齐。
     * ⇒ 连滑 = 精确累加；隔一会儿再滑也仍然"退 10 秒"。
     *
     * ⚠️ 已知残余误差：HLS 只能按"提交 playbacktime 重新取流"来定位，服务端会把起点
     *   **吸附到分片边界**（分片 2~6s）⇒ 相邻两次滑动若落在同一分片内，画面可能看起来一样。
     *   这是"按时间点重新起流"的固有限制；要彻底消除得改成"同一条流内 seek"（见 memory 待办）。
     * ========================================================================== */
    /** 起播时刻（epoch 秒）；0 = 直播（位置即"此刻"） */
    private var posBaseEpoch = 0L
    /** 起播时的墙钟（ms） */
    private var posBaseWallMs = 0L
    /** 累计暂停时长（ms） */
    private var posPausedAccumMs = 0L
    /** 本次暂停起点（ms）；0 = 未暂停 */
    private var posPauseStartMs = 0L

    /** 当前**真实播放位置**（epoch 秒）。直播时返回"此刻"。 */
    private fun posNowEpoch(): Long {
        val now = System.currentTimeMillis()
        if (posBaseEpoch <= 0L) {
            // 直播：位置就是直播沿（now-2 与 `shiftBy` 里的 liveEdge 同口径）
            return now / 1000 - 2
        }
        val paused = posPausedAccumMs +
            (if (posPauseStartMs > 0L) now - posPauseStartMs else 0L)
        return posBaseEpoch + (now - posBaseWallMs - paused) / 1000
    }

    /** 记录暂停/继续（让位置时钟跟着停/走） */
    private fun markPause(paused: Boolean) {
        val now = System.currentTimeMillis()
        if (paused) {
            if (posPauseStartMs == 0L) posPauseStartMs = now
        } else if (posPauseStartMs > 0L) {
            posPausedAccumMs += now - posPauseStartMs
            posPauseStartMs = 0L
        }
    }
    private var watchdogJob: Job? = null
    /** ★ 2026-11-03：`armVideoWatchdog` 的句柄（"有声无画"看门狗，见该函数注释） */
    private var videoWatchdogJob: Job? = null


    private var lastEpgDay = ""
    private var epgPid = ""
    /** ★ 2026-11-10（用户要求，与鸿蒙一致）：上次"向服务端拿到节目单"的时刻（ms） —— 30s 对齐的门槛 */
    private var lastEpgFetchAt = 0L
    /** 30s 对齐（只拉今天）是否在飞，避免请求叠加 */
    private var epgTodayRefreshing = false
    /** ★ 节目单 30 秒向服务端对齐一次（用户要求；10s 的 ticker 只做本地推进） */
    private val EPG_REFRESH_MS = 30_000L
    // ★★ 2026-10-01 删除 `lastGoodChannelId` ★★
    //   它只在**开机后第一次出画**时被赋值（`onFirstFrame` 里那个 `if (isEmpty())`），此后再不更新
    //   ⇒ 回退目标永远停在"第一个播过的台"：用户实测"画面在播江苏综艺，状态栏却显示回到 CCTV-1"。
    //   现在统一用 `lastPlayingId`（**每次出画都更新**，与鸿蒙 `Index.ets` 的 `lastPlayingId` 同口径）。

    init {
        // ★★ 2026-10-04 修正（用户真机实测："第一次能播，重新打开就一直取流、最后 get-live-info 错误"）★★
        //   上轮把"画质降档"的偏好**持久化**了 ⇒ 一旦上游并不认 `defn=hd`（返回里没有 playurl），
        //   这个坏值会被**每次启动**带进来 ⇒ **永远取流失败** ✗✗（用户就是这样被卡住的）。
        //   ⇒ 现在**启动一律回超清 `fhd`**（`hd` 只作为"本次运行内的临时对比开关"，见 `setVideoDefn`），
        //     并且取流失败时也会自动回退（见 `resolveUrl` 下方的失败分支）⇒ 再也不会出现"重开就废"。
        Config.defn = "fhd"   // 画质恒为超清（降档开关已撤，见 `Config.defn` 与 `setVideoDefn` 的注释）
        // ★ 2026-10-01：启动完成 ⇒ 状态栏切"就绪"（灰点待机），与鸿蒙 `bootSequence` 末尾 `bootMsg='就绪'` 同口径。
        //   原来只有 playChannel 才会改 bootMsg ⇒ App 起来后状态栏**一直显示"正在初始化…"**（用户实测指出）。
        //   native 没起来时给失败原因（鸿蒙同文案 `Strings.nativeInitFailed`）。
        _ui.value = _ui.value.copy(
            volume = prefs.volume,
            appVersion = appVersionName(),
            // ★ 2026-10-22：CMG 解密核已删除 ⇒ "native 是否就绪"改为看**自研 cKey + 签名器**
            //   （前者决定央视频明文链路能不能取流，后者决定回看/江苏台签名）
            bootMsg = if (com.rickyone.palmtv.native.SelfCKey.available) Strings.READY
            else Strings.nativeInitFailed(
                com.rickyone.palmtv.native.SelfCKey.error ?: "libpalmtv.so 未加载"
            )
        )
        // 自定义源并进频道表（内置在前、用户追加到最后）
        reloadCustomSources()
        // 首启免责声明：已同意版本 != 当前版本 ⇒ 弹（读失败也按"该弹"处理）
        _ui.value = _ui.value.copy(
            showDisclaimer = prefs.discAgreed != Config.DISC_VERSION,
            disclaimerReadOnly = false
        )
        // ★ 2026-10-02：注册"播控卡片切台"钩子（卡片的上一台/下一台、耳机上/下一曲 ⇒ 真正切台）。
        //   ⚠️ 单例持有这个 lambda ⇒ 会在 onCleared 里解绑，别让它长期引用已销毁的 ViewModel。
        PlayerHolder.onSwitchChannel = { offset -> switchChannelBy(offset) }
        player.player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_BUFFERING -> setBoot(Strings.buffering(_ui.value.currentName))
                    Player.STATE_READY -> {
                        if (player.player.playWhenReady) onFirstFrame()
                    }
                    Player.STATE_ENDED -> {
                        Log.i("[player] ended")
                        // ★ 2026-11-03（用户反馈"回看只能看一个，播完后不能继续下一个"）：
                        //   回看节目播完 ⇒ 自动接节目单里的**下一个可回看节目**；没有就回直播。
                        //   原来这里只打一行日志 ⇒ 播完就停在 ENDED（黑屏/定格），必须手动再点，
                        //   而用户点下一个时又常以为"回看坏了"。
                        // ★ 2026-11-04：只有"节目单回看"结束才自动接档；
                        //   **时移**（滚动流）如果真的 ENDED，就按当前位置继续，绝不跳回直播。
                        when {
                            replayIsProgram -> autoNextReplay()
                            currentPlaybackTime != null -> {
                                Log.i("[replay] 时移流播完 ⇒ 按当前位置继续（不跳直播）")
                                playReplayFrom(posNowEpoch().coerceAtMost(System.currentTimeMillis() / 1000 - 2), newRef = false)
                            }
                        }
                    }
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                _ui.value = _ui.value.copy(playing = isPlaying)
                if (isPlaying) onFirstFrame()
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e("[player] error: ${error.errorCodeName} ${error.message}")
                // ★ 2026-10-02：把**异常链**也打出来 —— ExoPlayer 的 message 常常只有一句
                //   "Source error"（如 hkstv 代理分片 302/超时、金鹰卡通分片慢到读超时），
                //   真正的原因在 cause 链里（`HttpDataSourceException` / `ParserException` / `SocketTimeoutException`）。
                //   排查"灌胶慢源为什么播不出"必须要这几行，别嫌啰嗦。
                var c: Throwable? = error.cause
                var depth = 0
                while (c != null && depth < 4) {
                    Log.e("[player]   ↳ ${c.javaClass.name}: ${c.message}")
                    c = c.cause
                    depth++
                }
                _ui.value = _ui.value.copy(playErr = true)
                /* ★★★★★ 2026-11-03（回看"播完又从头重播"的真凶）★★★★★
                 *   回看/时移走的是**时移型清单**（自检日志里的 `LiveTimeShift`），播放器一旦落到窗口外就抛
                 *   `ERROR_CODE_BEHIND_LIVE_WINDOW`。原来它走通用恢复 ⇒ **用同一个 `playbacktime` 重新取流**
                 *   ⇒ 又从同一分钟开始播（用户实测："CCTV-8K 07:05-07:06 播完在重复，不接 07:06-07:11"）。
                 *   ⇒ 回看/时移遇到这个错误必须**按"当前播放到的位置"续播**，绝不能回到原起点。
                 *   ⚠️ 直播（`currentPlaybackTime == null`）不受影响，仍走原来的重取直播逻辑。 */
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                    val chNow = Channels.byId(_ui.value.activeChannelId)
                    if (chNow != null) {
                        /* ★★★★★ 2026-11-03 二次修正（用户质问："为什么不能直接接着拉后面的分片？"）★★★★★
                         *   上一版对回看是"按当前位置**重新取流**（`playReplayFrom`）" —— 虽然不再重复，
                         *   但每次都要 **重新 resolve（~0.7~0.9s）+ 重建 MediaSource + 重新缓冲**，
                         *   而这条流每 ~19 秒就会掉一次窗 ⇒ 变成"每 19 秒卡 1~2 秒"的节奏。
                         *   正确做法（也是 Media3 对 `BehindLiveWindowException` 的标准处置）：
                         *   **不换 URL、不重新取流**，直接 `seekToDefaultPosition()`：
                         *   ExoPlayer 手里已经刷新过滚动清单，seek 一下就落在**新窗口的可用区间**里，
                         *   等于"接着后面的分片继续播"，代价只有一次定位（毫秒级）。
                         *   直播与回看**同一条路径**（回看的默认位置 = 窗口末端 − `liveConfigReplay` 的 6s）。 */
                        Log.w(
                            "[player] 落出窗口（${if (currentPlaybackTime != null) "回看/时移" else "直播"}）" +
                                "⇒ 直接在现有清单上 seek 续播（不重新取流）"
                        )
                        try {
                            player.player.seekToDefaultPosition()
                            player.player.prepare()
                            _ui.value = _ui.value.copy(playErr = false)
                            armWatchdog(chNow, playRequestId)
                            return
                        } catch (e: Exception) {
                            Log.w("[player] seek 续播失败，回落到重新取流: ${e.javaClass.simpleName}: ${e.message}")
                        }
                    }
                }
                /* ★★ 2026-10-02（用户实测："鸿蒙 ~3 秒就判出来了，安卓真的要 15 秒；我想安卓也这样"）★★
                 *   判死其实有**两条路径**，两端差在路径 ① 上：
                 *     ① **播放器报错** —— 鸿蒙（AVPlayer）一报错就 `recoverPlayer` 的直连分支**立即回退**（≈1~3s）；
                 *        安卓却要先"轻量重试 ≤2 次 / 25s"才回退 ⇒ 拖成 15~25s（这就是"安卓要等很久"的根因）；
                 *     ② **没报错但没画面**（静默缓冲）—— 只能等看门狗（两端已统一 15s）。
                 *   ⇒ 按**错误类型**分档（只影响路径 ①）：
                 *     · **确定性错误**（HTTP 状态码错、清单/容器解析不了…）⇒ "这条源就是不行，重试也不会好"
                 *       ⇒ **立即回退**，与鸿蒙同速 ✓；
                 *     · **瞬时错误**（连接超时 / 连接失败 / IO 未分类）⇒ 保留轻量重试（那是"慢源"，
                 *       香港卫视/金鹰卡通就是这一类，别误杀）。
                 *   ℹ️ 真正的死源在**起播前预检**（`probePlain`）阶段就判掉了，走不到这里 ⇒ 分档不会放过死源。 */
                var definitive = when (error.errorCode) {
                    PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,          // 403 / 404 / 410…
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
                    PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                    PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
                    PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> true
                    else -> false
                }
                /* ★★ 2026-10-02（模拟器实测补充）★★ 光看 `errorCode` **不够**：
                 *   ExoPlayer 把**分片级**失败统一包成 `ERROR_CODE_IO_UNSPECIFIED` ⇒ "死源"与"慢源"
                 *   在错误码上无法区分（实测广州电视：清单 403、分片 403，错误码却是 UNSPECIFIED）⇒
                 *   再沿 **cause 链**找 ExoPlayer 自带的 `InvalidResponseCodeException`（HTTP 4xx）。
                 *   ★ 2026-10-22：原来找的是 `CmgDataSource.SourceDeadException`，CMG 解密链路
                 *   删除后改用 ExoPlayer 的异常 —— 语义一样（4xx = 确定性失败），代码更少。 */
                var cc: Throwable? = error.cause
                var dd = 0
                while (cc != null && dd < 4) {
                    if ((cc is androidx.media3.datasource.HttpDataSource.InvalidResponseCodeException &&
                            cc.responseCode in 400..499) ||
                        // ★ 2026-10-27：CMG 解密链路已恢复，它抛的专用"死源"异常也认
                        false /* 2026-10-27: CMG 链路已彻底移除 */
                    ) {
                        definitive = true
                        break
                    }
                    cc = cc.cause
                    dd++
                }
                if (definitive) {
                    Log.w("[player] 判为**确定性**失败（${error.errorCodeName}）⇒ 跳过硬重试、立即回退（与鸿蒙同速）")
                }
                /* ⚠️ 2026-11-05（用户要求移除）：曾经对 `ERROR_CODE_DECODING_FAILED` 做过
                 *   "seek 前进一个分片继续播、不重建播放器"的轻量恢复。用户实测**体验不好**
                 *   （画面会跳过一段内容），已移除 —— 解码错误一律走原来的重建逻辑。
                 *   想重新启用必须先征得用户同意。 */
                recoverPlayer("state=error:${error.errorCodeName}", definitive)
            }

            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                Log.i("[player] videoSize=${videoSize.width}x${videoSize.height}")
                // ★ 2026-10-23 诊断：视频格式（判"绿屏是解码器不支持该 profile"还是码流问题）
                Log.i("[player] 视频格式: ${player.videoTrackInfo()}")
                // ★★ 2026-10-01（用户要求：横屏画面更紧凑/更大）★★ 把**真实显示比例**回填给 UI，
                //   让横屏画面盒子按它算"可用区里能放下的最大矩形"（`UiState.videoAr` 之前只是个没人写的字段）。
                //   ⚠️ 要用 `× pixelWidthHeightRatio`（PAR）：HLS 里大量 1440x1080 + PAR 4:3 的台，
                //      只看 width/height 会算出 4:3，画面就被压窄了。
                val w = videoSize.width
                val h = videoSize.height
                val par = if (videoSize.pixelWidthHeightRatio > 0f) videoSize.pixelWidthHeightRatio else 1f
                if (w > 0 && h > 0) {
                    // ★ 新流尺寸已到 = 新画面即将上屏 ⇒ 与鸿蒙"新台 prepared 时才切修正"同一时机。
                    //   两个值放在**同一次状态更新**里，避免出现"新比例 + 旧修正"的中间态。
                    _ui.value = _ui.value.copy(videoAr = w * par / h, videoArFix = pendingArFix)
                    // ★★★★★ 2026-10-08（**直播走安卓平台链路"永不出画"的根因修复**）★★★★★
                    //   实测：`libckeygenerator` 拿到官方签名后，直播地址、清单、分片全都正常
                    //   （分片实测 **3.58 MB 真 TS**），但**看门狗 8 秒到点就把还在准备中的播放打断**：
                    //     重取 ⇒ `InterruptedIOException: interrupted`（在途请求被取消）⇒ 又要重新起播
                    //     ⇒ 永远赶不上首帧 ⇒ "越看越没有画面"的死循环。
                    //   而"**已经报出视频尺寸**"= 解码器已经吃上数据、画面即将上屏 ⇒ 这时**撤销首次出画看门狗**，
                    //   把"没出画"的判定交给真正没进展的情形（此时若还不行，由 player error 路径兜底）。
                    if (watchdogJob != null) {
                        cancelWatchdog()
                        Log.i("[watchdog] 已收到视频尺寸 ${w}x${h} ⇒ 撤销首次出画看门狗（避免打断即将上屏的画面）")
                    }
                }
            }
        })
    }

    // ==================================================================
    // 免责声明
    // ==================================================================

    fun agreeDisclaimer() {
        prefs.discAgreed = Config.DISC_VERSION
        _ui.value = _ui.value.copy(showDisclaimer = false, disclaimerReadOnly = false)
    }

    /** 只关窗、**不写同意标记**（关于页"再次查看"模式） */
    fun dismissDisclaimer() {
        _ui.value = _ui.value.copy(showDisclaimer = false)
    }

    fun openDisclaimerReadOnly() {
        _ui.value = _ui.value.copy(showDisclaimer = true, disclaimerReadOnly = true)
    }

    // ==================================================================
    // 频道表 / 分组
    // ==================================================================

    private fun reloadCustomSources() {
        // ★★ 2026-10-02（同步桌面端 `IptvChannels.Load()`）★★
        //   ① **内置优先**：用户条目与内置 IPTV 台同 URL ⇒ 不重复加入（原来直接 `Channels.all + custom`，
        //      用户把内置地址再填一遍就会出现两条同名频道、台标/选中还会不一致）；
        //   ② 用户内部同 URL 去重；
        //   ③ 空名 ⇒ 取域名（桌面 `new Uri(url).Host`）；这些都在 `IptvSources.toChannels` 里做。
        val builtInUrls = Channels.all
            .filter { it.src == Channel.Src.IPTV }
            .map { it.streamId }
            .toSet()
        val raw = prefs.loadCustomSources()
        val custom = IptvSources.toChannels(raw, builtInUrls)
        _ui.value = _ui.value.copy(channels = Channels.all + custom)
        // 打一行日志：排查"加了源却看不到"时一眼看得出是**文件没读到**还是**被去重/校验滤掉了**
        Log.i(
            "[iptv] 自定义源：文件读到 ${raw.size} 条 ⇒ 并表 ${custom.size} 条" +
                "（内置 ${builtInUrls.size} 条优先去重）｜文件=${prefs.iptvFilePath()}"
        )
    }

    /** 保存自定义源；@return false = 写文件失败（上层要提示"保存失败（目录不可写？）"，别静默） */
    fun saveCustomSources(list: List<IptvSources.Entry>): Boolean {
        val ok = prefs.saveCustomSources(list)
        reloadCustomSources()
        return ok
    }

    /** 自定义源文件路径（关于页/编辑弹窗显示给用户；桌面端同款提示也会显示它） */
    fun iptvFilePath(): String = prefs.iptvFilePath()

    fun loadCustomSources(): List<IptvSources.Entry> = prefs.loadCustomSources()

    fun switchGroup(group: Channel.Group) {
        _ui.value = _ui.value.copy(activeGroup = group, aboutTab = false)
    }

    fun switchAbout() {
        _ui.value = _ui.value.copy(aboutTab = true)
    }

    fun visibleChannels(): List<Channel> =
        _ui.value.channels.filter { it.group == _ui.value.activeGroup }

    // ==================================================================
    // 播放：取流（最多 3 次）→ 起播 → 看门狗
    // ==================================================================

    /**
     * ★ 2026-10-02：**在当前分组的频道表里按 offset 切台** —— 供播控卡片的"上一台/下一台"、
     * 耳机/蓝牙的上/下一曲按键使用（见 `PlayerHolder.onSwitchChannel` + `PlaybackService` 的
     * `ForwardingPlayer` 拦截）。与鸿蒙 `Index.ets` 的 `switchChannelBy(offset)` 同语义：只在本分组内循环。
     * ⚠️ 由 `PlayerHolder.switchChannel` 在**主线程**（播放器的 application looper）回调 ⇒ 可直接改 UI 状态。
     */
    fun switchChannelBy(offset: Int) {
        val u = _ui.value
        val list = u.channels.filter { it.group == u.activeGroup }
        if (list.isEmpty()) {
            Log.w("[play] 播控切台：当前分组没有频道（忽略）")
            return
        }
        val cur = list.indexOfFirst { it.id == u.activeChannelId }
        val next = if (cur < 0) (if (offset >= 0) 0 else list.size - 1)
        else (cur + offset + list.size) % list.size
        Log.i("[play] 播控切台 offset=$offset ⇒ ${list[next].name}")
        playChannel(list[next], userInitiated = false)
    }

    /**
     * ★★ 2026-10-04（用户要求："TV 侧默认打开 CCTV-1 台"）★★
     * ★★ 2026-10-08（用户要求）：**TV 与手机都用它**（手机原来停在"请点击频道"，现在也自动开播，
     *   这样"打开就能看"，自动化测试也不用再手动点频道格）。两个界面都在**免责声明关掉后**调用。
     *
     * 语义（两条用户要求合起来）：
     *   · 已经在播（回前台 / 旋转重建 / 用户已选台）⇒ **什么都不做**（别打断）；
     *   · 否则优先**续播上次看过的那台**（`prefs.lastChannelId` —— 它一直只在 `playChannel` 里被写、
     *     从来没有被读过，这里起第一次真正使用它）⇒ "记住上次选中的台"；
     *   · 没有记录 / 那台已不在清单里 ⇒ **CCTV-1**（`cctv1`，央视组第一台）。
     *
     * ⚠️ 必须用 `userInitiated = false`：这是"自动起播"，**不能**刷新 `userPickedId`，
     *   否则"无信号"文案会把它当成"用户亲手点的台"而说出"请点击其他频道"，与三端口径不符。
     */
    fun startDefaultChannel() {
        if (_ui.value.activeChannelId.isNotEmpty()) return
        val last = prefs.lastChannelId
        val ch = Channels.all.firstOrNull { it.id == last }
            ?: Channels.all.firstOrNull { it.id == "cctv1" }
            ?: return
        Log.i("[auto] 启动自动开播：${ch.name}（${if (ch.id == last && last.isNotEmpty()) "续播上次" else "默认 CCTV-1"}）")
        playChannel(ch, userInitiated = false)
    }

    /**
     * @param playbackTime ★ 2026-10-07：秒级时刻 —— **null = 直播**，非 null = **时移/回看**（从该时刻起播）。
     *   只有"用户换台"或"显式给了值"才改时移状态；看门狗重取 / 回前台恢复这类**内部重取沿用**当前值。
     */
    /**
     * ★★★★★ 2026-10-07：**回看** —— 从节目单里点一个「已播完」的节目，从它的开始时刻播。★★★★★
     *
     * 走央视频「安卓平台」链路的 `playbacktime`（`YspAndroidLive`）：web/PC 链路给不出回看
     * （它的回看地址 `_web.m3u8` 恒 404），安卓平台链路才是正路，且回来的流是**明文**。
     * @param startSec 该节目的开始时刻（epoch 秒）—— 直接取自 `Epg.Item.start`
     */
    fun playReplayFrom(startSec: Long, newRef: Boolean = false) {
        val ch = Channels.byId(_ui.value.activeChannelId) ?: return
        replayIsProgram = newRef      // ★ true=节目单回看（带 endtime、可自动接档）；false=时移（滚动流、持续延迟）
        closeEpg()
        Log.i("[replay] ${ch.name} 回看：start=$startSec newRef=$newRef")
        // ★ 2026-10-22（用户要求）：**时移的显示基准 = 用户点击的那个节目单的起点**。
        //   只有"用户从节目单点进来"（newRef=true）才重设基准；
        //   左右滑动（settleTimeshift 调用）**不改基准** ⇒ 可以连续跨节目滑，数字连贯变化。
        if (newRef) {
            val prog = _ui.value.epg.firstOrNull {
                it.start > 0L && it.end > it.start && startSec >= it.start && startSec < it.end
            }
            val ref = prog?.start ?: startSec
            _ui.value = _ui.value.copy(replayRefSec = ref)
            Log.i("[timeshift] 基准节目：${prog?.title ?: "（不在节目单内）"} ref=$ref")
        }
        currentPlaybackTime = startSec
        // 立刻刷新节目条（不必等网络）：基准切到该节目 ⇒ "正在播出"= 它、"接下来"= 下一个
        if (_ui.value.epg.isNotEmpty()) applyEpg(_ui.value.epg)
        playChannel(ch, userInitiated = true, playbackTime = startSec)
    }
    /**
     * ★★★ 2026-10-22（用户要求）：**左右滑动 = 时移 ±10 秒** ★★★
     *
     * @param deltaSec +10 = 往后跳 10 秒（更接近直播）；-10 = 往前退 10 秒。
     * 规则：
     *   · 直播中往"后"滑（+）没有意义（已在直播沿）⇒ 不动；
     *   · 任何一次滑动都会进入"时移"状态（`playbacktime` = 目标时刻），走的是同一套回看链路；
     *   · 目标已经追上"此刻"（>= now-2s）⇒ 直接回直播（干净、不带 playbacktime）；
     *   · 往前退不能超过服务端回看窗口（实测 `playback.playbacktime = 604800` = **7 天**）。
     */
    fun shiftBy(deltaSec: Long) {
        val ch = Channels.byId(_ui.value.activeChannelId) ?: return
        val ui = _ui.value
        val now = System.currentTimeMillis() / 1000
        val liveEdge = now - 2                    // 直播沿
        val ref = ui.replayRefSec                 // >0 = 回看基准（点击的节目起点）；0 = 直播

        // ---- 基准位置 ----
        // ★ 基准：同一手势内用累加值；手势起点用**当前真实播放位置**（posNowEpoch），
        //   不能用 `replayStart` —— 那是上次请求的固定时刻，会随播放推进而过期（见字段注释）。
        val base = if (ui.shiftPendingSec > 0L) ui.shiftPendingSec else posNowEpoch()

        // ---- 边界：不夹节目，可跨节目连续滑 ----
        val lo = now - 7L * 24 * 3600             // 服务端回看窗口 7 天
        var target = base + deltaSec
        if (target > liveEdge) target = liveEdge
        if (target < lo) target = lo

        // ★ 2026-10-22 修 bug：直播模式的"落后秒数"用**累加**（`shiftOffsetSec - delta`），
        //   不要用 `now - target` —— 那样会把"正好在直播沿"算成落后 2s（显示"-2 秒"），
        //   而且手势期间 now 一直在走 ⇒ 数字会莫名变大。
        val newOff = if (ref > 0L) 0
        else (ui.shiftOffsetSec - deltaSec).toInt().coerceIn(0, 7 * 24 * 3600)

        // ---- 提示文案 ----
        val hint = when {
            ref > 0L -> Strings.timeshiftSigned((target - ref).toInt())  // 回看：相对节目起点
            newOff <= 0 -> Strings.timeshiftHint(0)                      // 直播沿 ⇒ "直播"
            else -> Strings.timeshiftSigned(-newOff)                     // 落后 ⇒ "时移 -N 秒"
        }

        if (target == base) {
            // 已到边界（直播沿 / 7 天前）⇒ 只显示提示（并且**会**自动消失），不动网络
            autoHint(hint)
            return
        }

        shiftSettleJob?.cancel()
        _ui.value = ui.copy(
            shiftPendingSec = target,
            shiftOffsetSec = newOff,
            gestureHint = hint
        )
        Log.i("[timeshift] ${ch.name} 目标 $base → $target（${if (ref > 0L) "基准内 ${target - ref}s" else "落后 ${newOff}s"}）")

        // ★★ 2026-10-22（TV 遥控）：遥控器**没有可靠的 KeyUp**（长按连发 KeyDown、抬手不一定有事件），
        //   所以这里挂一个 600ms 的自动结算 —— 连按期间不断取消重建，停手即落地。
        //   触摸路径抬手会调 `settleTimeshift()` 立即结算，两者等价（都是 `doSettle`）。
        shiftSettleJob = viewModelScope.launch {
            delay(600)
            doSettle(target)
        }
    }

    /** OSD 自动消失（可被下一次滑动取消） */
    private fun autoHint(text: String) {
        _ui.value = _ui.value.copy(gestureHint = text)
        hintClearJob?.cancel()
        hintClearJob = viewModelScope.launch {
            delay(1500)
            if (_ui.value.gestureHint == text) {
                _ui.value = _ui.value.copy(gestureHint = "")
            }
        }
    }

    /** ★ 手指抬起时调用：防抖 400ms 才真正重新取流 —— 连滑多次只发一次请求。
     *  ⚠️ `shiftPendingSec == 0` = 本次手势没有产生位移 ⇒ **什么都不做**
     *  （早前把它当成"回直播"，导致回看中滑到边界就跳回直播）。 */
    fun settleTimeshift() {
        val ch = Channels.byId(_ui.value.activeChannelId) ?: return
        val target = _ui.value.shiftPendingSec
        if (target <= 0L) {
            Log.i("[timeshift] ${ch.name} 本次无位移（已在边界）⇒ 不处理")
            return
        }
        shiftSettleJob?.cancel()
        shiftSettleJob = viewModelScope.launch { doSettle(target) }
    }

    /** 真正落地：到直播沿就回直播，否则按 playbacktime 重取流。调用方负责防抖。 */
    private suspend fun doSettle(target: Long) {
        val ch = Channels.byId(_ui.value.activeChannelId) ?: return
        _ui.value = _ui.value.copy(shiftPendingSec = 0L)
        if (target >= System.currentTimeMillis() / 1000 - 2) {
            Log.i("[timeshift] ${ch.name} 目标已到直播沿 ⇒ 回直播")
            backToLive()
        } else {
            Log.i("[timeshift] ${ch.name} 起播 playbacktime=$target")
            playReplayFrom(target)          // 不改基准 ⇒ 可跨节目连续滑
        }
        delay(1400)
        _ui.value = _ui.value.copy(gestureHint = "")
    }

    /**
     * ★ 2026-11-03：**回看节目播完 ⇒ 自动接下一个**。
     *
     * 规则（与节目单同源，不用另取网络）：
     *   · 当前回看的那档（`currentPlaybackTime` 落在 [start,end) 内）之后，
     *     第一个 `replayable` 且已结束的节目 ⇒ 直接回看它；
     *   · 找不到（已是最新一档 / 后面都是"未播完"或"不可回看"）⇒ **回直播**，别停在 ENDED 黑屏。
     * ⚠️ 只在"确实处于回看/时移"时调用（直播流结束不走这里）。
     */
    private fun autoNextReplay() {
        val cur = currentPlaybackTime ?: return
        val list = _ui.value.epg
        val now = System.currentTimeMillis() / 1000
        if (list.isEmpty()) {
            Log.i("[replay] 回看结束：节目单为空 ⇒ 回直播")
            backToLive()
            return
        }
        // ★ 2026-11-03（用户实测"CCTV-8K 07:05-07:06 播完在重复，没接 07:06-07:11"）：
        //   原来靠"`cur` 落在某档 [start,end) 内"定位当前档，一旦节目单与 `playbacktime` 对不上
        //   （EPG 滞后/边界差 1 秒）就 `idx=-1` ⇒ 找不到下一档。改法：**不看 idx**，
        //   直接取"起点晚于 `cur`、已播完、可回看"里**起点最早**的那一档 —— 与列表顺序无关，也不会重复当前档。
        val idx = list.indexOfFirst { it.start > 0L && it.end > it.start && cur >= it.start && cur < it.end }
        val next = list.asSequence()
            .filter { it.start > cur && it.end > it.start && it.end <= now && it.replayable }
            .minByOrNull { it.start }
        Log.i(
            "[replay] 回看结束：epg=${list.size} cur=$cur idx=$idx" +
                " 当前=${if (idx >= 0) list[idx].title + "@" + list[idx].start + "~" + list[idx].end else "（无匹配）"}" +
                " 下一档=${next?.let { it.title + "@" + it.start + "~" + it.end } ?: "（无）"}"
        )
        if (next != null) {
            playReplayFrom(next.start, newRef = true)
        } else {
            Log.i("[replay] 没有下一档可回看 ⇒ 回直播")
            backToLive()
        }
    }

    /** ★ 从回看/时移切回**直播**（同一频道按"无 playbacktime"重取一次）。 */
    fun backToLive() {
        val ch = Channels.byId(_ui.value.activeChannelId) ?: return
        Log.i("[replay] ${ch.name} 切回直播")
        currentPlaybackTime = null
        replayIsProgram = false
        _ui.value = _ui.value.copy(replayRefSec = 0L, shiftPendingSec = 0L)
        if (_ui.value.epg.isNotEmpty()) applyEpg(_ui.value.epg)
        playChannel(ch, userInitiated = true, playbackTime = null)
    }

    fun playChannel(ch: Channel, userInitiated: Boolean = true, playbackTime: Long? = null) {
        val req = ++playRequestId
        if (userInitiated || playbackTime != null) currentPlaybackTime = playbackTime
        // ★ 2026-11-04：直播（playbackTime==null）⇒ 一定不是"节目单回看"，把标记清掉，
        //   否则换台/回直播后仍会带着上一次的 endtime 语义。
        if (playbackTime == null) replayIsProgram = false
        if (userInitiated) userPickedId = ch.id   // ★ 只有真·用户选台才刷新（见 userPickedId 注释）
        retried = false
        directRetries = 0          // ★ 换台 ⇒ 慢源容忍额度重新计
        directRetryAt = 0L
        playerRebuilds = 0
        cancelWatchdog()
        val replayNow = currentPlaybackTime ?: 0L
        // ★ 2026-10-22：回看时保留时移基准（由 `playReplayFrom` 设），换台/回直播则清零
        val keepRef = _ui.value.replayRefSec
        // ★ 2026-10-22：起新流 ⇒ 位置时钟从"这个时刻"重新起算
        posBaseEpoch = replayNow
        posBaseWallMs = System.currentTimeMillis()
        posPausedAccumMs = 0L
        posPauseStartMs = 0L
        _ui.value = _ui.value.copy(
            playErr = false,
            videoNotice = "",
            activeChannelId = ch.id,
            currentName = ch.name,
            controlsVisible = true,
            // ★ 2026-10-21：把"回看/时移"状态同步给 UI（节目条 & 节目单定位以它为基准）
            replayStart = replayNow,
            // ★ 2026-10-22：**重置播放位置时钟**（新的起流点 = 新的位置基准）
            //   注意 `replayNow` 是"请求的时刻"，服务端可能吸附到分片边界，
            //   但用墙钟推进足够精确，且不再有"过期基准"问题。
            shiftOffsetSec = if (replayNow > 0L)
                ((System.currentTimeMillis() / 1000) - replayNow).toInt().coerceAtLeast(0) else 0,
            // ★ 2026-10-22：时移偏移量也同步（直播 ⇒ 0；回看/时移 ⇒ 落后多少秒）
            // ★ 2026-10-22：手势"待结算目标"每次都归零（本次已落地）
            shiftPendingSec = 0L,
            // ★ 2026-10-22：换台/回直播 ⇒ 清时移基准；回看则保留 `playReplayFrom` 刚设好的值
            //   （用局部变量，避免 copy 里同名参数自引用）
            replayRefSec = if (replayNow > 0L) keepRef else 0L
            // ★★ 2026-10-01 撤掉"换台清比例"（用户实测：三个尺寸修正的台换台时会**闪回原尺寸再跳台**）★★
            //   原因：清成 0 ⇒ 画面盒子**立刻**变成 16:9 兜底，而 SurfaceView 上还是**上一个台的最后一帧**
            //   ⇒ 旧画面被塞进新盒子里抖一下，等新 videoSize 到了再跳一次 = 肉眼看到的"闪一下"。
            //   与鸿蒙一致的做法是**保持上一次的尺寸**直到新流给出尺寸（鸿蒙 `videoW/videoH` 也是只在
            //   播放器的尺寸回调里更新，从不清零）；换台期间画面本来就在缓冲/黑屏 ⇒ 不显示错比例。
        )
        // ★★ 2026-10-01（复刻鸿蒙 `pendingArFix`）★★ 宽高比修正**不当场生效**，这里只登记；
        //   等这条流的 `onVideoSizeChanged` 到达（= 新画面即将上屏）再切 `videoArFix`。
        //   否则"切出"哈尔滨电影/综合、农林卫视时修正会被立刻撤销，旧帧又先弹回原始尺寸（实测仍会抖）。
        pendingArFix = Channels.aspectOverrides[ch.name] ?: 0f
        setBoot(Strings.gettingUrl(ch.name))
        // ★ 2026-10-01：把"宽高比修正"打出来（用户报哈尔滨两台 / 农林卫视尺寸不对）——
        //   一眼就能确认修正表是否命中（键 = 频道名；见 `Channels.aspectOverrides`）。
        Log.i("[player] ${ch.name} 宽高比修正=" +
            (Channels.aspectOverrides[ch.name]?.let { "16:9" } ?: "无（按流自身 SAR 自适应）"))

        viewModelScope.launch {
            var attempt = 1
            while (attempt <= 3) {
                try {
                    val (url, plain) = resolveUrl(ch, req)
                    if (req != playRequestId) return@launch
                    // ★★ 2026-10-01（同步鸿蒙 `probeIptvSource`）：IPTV 外部源**先探后播** ★★
                    //   此刻 activeChannelId 已切成新台、但**播放器还没被换过** ⇒ 判死时只回退 UI 就行
                    //   （原台画面/声音完全不中断，也不会黑屏）。不放在重试循环里：对外部源判死要快。
                    //   用户实测：四平综合这类源会让 ExoPlayer 反复报错 ⇒ "播放异常，正在恢复(1/3)"来回切。
                    //   ⚠️⚠️ 预检是**网络 I/O** ⇒ 必须切 IO 线程！`playChannel` 跑在 viewModelScope(=Main)，
                    //     直接在主线程发请求就是 `NetworkOnMainThreadException`（message 为 null，实测踩过：
                    //     预检"瞬时失败"让好源被判死）。
                    val alive = if (ch.isIptv) withContext(Dispatchers.IO) { player.probePlain(url) } else true
                    if (ch.isIptv && !alive) {
                        Log.w("[play] IPTV 源无响应 ⇒ 不换播放器，退回原台: ${ch.name}")
                        // ★ 2026-10-01（用户要求统一）：提示语与 CCTV-10 版权停播、直连台播放器报错合并 ——
                        //   有原台 ⇒ "xxx 无信号，已切回 yyy"；无 ⇒ "xxx 暂无信号，请点击其他频道"。
                        if (!revertWithNotice(ch.name)) setBoot(Strings.noSignalClick(ch.name))
                        return@launch
                    }
                    setBoot(Strings.buffering(ch.name))
                    // ★ 2026-10-01：起播前确保媒体播控服务在跑（幂等）——卡片标题/封面由 `PalmPlayer.play` 挂
                    PlayerHolder.ensureService(getApplication<Application>())
                    player.setVolume(if (_ui.value.muted) 0f else _ui.value.volume)
                    // ★ 记住这次真正用的 URL + 清掉"后台/轻量恢复"标记（回前台的"轻量恢复"要用它，鸿蒙同）
                    lastPlayUrl = url
                    lastPlayPlain = plain
                    hideAt = 0L
                    needRecoverOnShow = false
                    lightReviving = false   // 走完整取流 ⇒ 之前那次"轻量恢复"已结束
                    player.play(ch, url, plain, isReplay = currentPlaybackTime != null)
                    prefs.lastChannelId = ch.id
                    armWatchdog(ch, req)
                    // ★ 2026-11-03：起播后挂"有声无画"看门狗（换台/回前台都可能命中失效 Surface）
                    armVideoWatchdog(req)
                    // EPG（仅央视频链路有节目单）
                    if (!ch.isLocalDirect) fetchEpg(ch)
                    else clearEpg()
                    return@launch
                } catch (e: Exception) {
                    if (req != playRequestId) return@launch
                    val auth = isAuthErr(e)
                    val net = isNetErr(e)
                    Log.w("[play] 第 $attempt 次失败: ${e.message}")
                    // ★ 2026-10-21：回看不可用 = **确定性拒绝**（服务端 32 / 超出回看窗口）
                    //   ⇒ 不要走 3 次重试（否则短时间内连发多条 liveinfo，会被服务端限流，连直播都变 32）
                    // ★ 2026-10-22：**版权停播同理**（iretcode=12）—— 重试 3 次只是让用户多等 3 秒，
                    //   而且每次都是一条 liveinfo（会加剧限流）⇒ 直接走失败分支（回退原台 + 统一提示）。
                    if (e.message?.contains("回看不可用") == true || e.message?.contains("版权") == true) {
                        onFetchFailed(ch, e, auth, net, userInitiated)
                        return@launch
                    }
                    if (attempt == 3) {
                        onFetchFailed(ch, e, auth, net, userInitiated)
                        return@launch
                    }
                    setBoot(
                        when {
                            auth -> Strings.retryAuth(ch.name, attempt + 1)
                            net -> Strings.retryNet(ch.name, attempt + 1)
                            else -> Strings.retryOther(ch.name, attempt + 1)
                        }
                    )
                    delay(if (auth) 300 else 1500)
                    attempt++
                }
            }
        }
    }

    /**
     * 取流。**只有三条链路，全部明文**（2026-10-22）。
     *
     * ```
     * 江苏台  → JiangsuTv（txSecret 签名，明文 TS）
     * IPTV   → 用户/内置直链（明文）
     * 央视频  → YspAndroidLive（自研 cKey + liveinfo；直播 / 时移 / 回看都由 playbacktime 决定）
     * ```
     *
     * ★★★ 2026-10-22：**删掉了 web/PC 那条老链**（`StreamResolver`）★★★
     *   它要 auth→signature→yspticket→get_live_info 一整套 PC 版签名，最后拿到的是
     *   **CMG 加密的 `_web.m3u8`**；而端上解密核已经移除 ⇒ 那条链就算成功也只能放出花屏，
     *   属于"看起来有兜底、实际更糟"。⇒ 现在央视频只走安卓平台明文链路，失败就**如实报错**
     *   （`playChannel` 有 3 次重试 + 明确提示），不再偷偷换一条放不出来的路。
     *   ⚠️ 回看/时移尤其不能回落：老链给不出回看（其回看地址恒 404），回落等于"点了回看还在直播"。
     */
    private suspend fun resolveUrl(ch: Channel, req: Int): ResolvedPlay {
        if (ch.isJstv) {
            val u = JiangsuTv.upstreamUrl(ch)
            if (u.isEmpty()) throw IllegalStateException("江苏台签名失败")
            return ResolvedPlay(u, true)
        }
        if (ch.isIptv) return ResolvedPlay(ch.streamId, true)
        if (req == playRequestId) setBoot(Strings.phaseLive(ch.name))

        val t0 = System.currentTimeMillis()
        // ★★★ 2026-10-27（关键）：8 个 ChinaDRM 台走**原来的 Web/PC 取流链路** ★★★
        //   两条链路给的加密**格式不同**：
        //     · 移动端链路（liveinfo + hlsliveali-cdn）→ `#EXT-X-KEY:METHOD=SM4-CBC`（ChinaDRM）
        //       ⇒ CMG 解密核**解不了** ⇒ 有声音、画面绿屏（实测）
        //     · Web/PC 链路（player-api + `_web.m3u8`）→ CMG 格式 ⇒ `cmg_rt_decrypt_ts` **能解** ✓
        //   所以这 8 个台必须回到老链路 + `plain=false`（交给 CmgDataSource 边取边解）。
        // ★★★ 2026-10-27：**只有"直播"才走 Web/PC 链路** ★★★
        //   回看/时移（currentPlaybackTime != null）继续走移动端链路 + 自研 cKey：
        //   · 移动端链路的回看能用现成的 playbacktime（跨节目、7 天窗口都已在用）
        //   · 若回看流本身就是明文（没有 #EXT-X-KEY），这条路直接通，无需 CMG
        //   · 若回看流也是 SM4，则会绿屏 —— 日志里会看到「清单含 KEY 行 / 已解密」，
        //     那时再考虑别的办法（见 docs/ysp-ckey/ref/drm/）
        //   直播（currentPlaybackTime == null）⇒ Web/PC 链路 + CMG 解密
        //   回看（currentPlaybackTime != null）⇒ 移动端链路 + 明文直通（分片本就是明文）
        // ★★★★★ 2026-10-29：这 8 个台**改回移动端 cKey 链路 + sm4c 自解** ★★★★★
        //   2026-10-27 之所以回退 Web/PC 链路，是因为移动端链路给的是 `METHOD=SM4-CBC`、CMG 解不了。
        //   现在 CmgDataSource 里已实现 sm4c（SM4-CBC，common key + PSSH contentID 派生 IV，见
        //   `player/Sm4C.kt`，与桌面 `windows/Sm4C.cs` 同一套算法、逐字节对齐），
        //   移动端链路可以自解 ⇒ 不再需要 CMG 回退。
        // ★★★★★ 2026-10-31：**Web/PC 取流链（`StreamResolver` + `YspSign`）已整体删除** ★★★★★
        //   它只服务于"Web/PC 链 + CMG 解密"这条老路，而该路已被"移动端 cKey + sm4c"完全取代；
        //   删掉后 native 侧也随之瘦身（不再编 ysp_sign/ysp_keygen/ysp_rjq/wasm-rt）。
        // 其余频道：移动端链路 + 自研 cKey（明文直通）
        // ★★★ 2026-10-27：**回看走移动端链路且按明文处理** ★★★
        //   实测（官方 App 抓包，pair.pcap）：
        //     回看分片里 NAL 起始码大量存在（35MB 流里 6949 个）⇒ **分片是明文**，
        //     清单里那行 `#EXT-X-KEY:METHOD=SM4-CBC` 只是声明（decoy）。
        //   所以回看必须 `needCmg=false`（⇒ plainChannel=true ⇒ 只剔 KEY 行、不做解密），
        //   否则拿 CMG 去解明文 ⇒ 视频被解坏 ⇒ 有声音但绿屏（这正是之前的现象）。
        // ★ 2026-10-29：这 8 个台**直播和回看都要解密**（用户实测回看也花屏 ⇒ 回看同样是 SM4 密文）。
        //   原来这里固定 `ResolvedPlay(..., true)` 且回看强制 plain ⇒ 分片被当明文直通 ⇒ sm4c 从不被调用。
        //   回看若其实已是明文，CmgDataSource 的 `replayMode` 会原样直通（不会送 CMG 解坏）。
        val needDecrypt = ch.needsCmg
        // ★ 2026-11-03：回看/时移把「节目结束时刻」一并传下去 ⇒ 服务端给**整段 VOD 清单**
        //   （实测：只带 starttime = 5 片滚动窗口；再带 endtime = 302 片 + ENDLIST）。
        //   回看取节目单那一档的 end；找不到（或时移追到直播沿）就用"现在"。
        // ★ 2026-11-04：**只有"回看"才带 endtime**（见 `replayIsProgram` 注释）；时移一律不带，
        //   否则时移流会被做成"有终点的点播"，播完就跳回直播（用户实测 bug）。
        val replayEnd: Long? = currentPlaybackTime?.takeIf { replayIsProgram }?.let { pb ->
            val item = _ui.value.epg.firstOrNull {
                it.start > 0L && it.end > it.start && pb >= it.start && pb < it.end
            }
            (item?.end ?: (pb + 3600L)).coerceAtMost(System.currentTimeMillis() / 1000)
        }
        val rp = YspAndroidLive.resolve(
            getApplication<Application>(), ch.cnlId, ch.pid, currentPlaybackTime,
            needCmg = needDecrypt, endTime = replayEnd
        )
        // 取流耗时进诊断浮层（TV 无法接 adb 时靠用户念这一行）
        PlayStats.resolveMs = System.currentTimeMillis() - t0
        if (rp != null && rp.playUrl.isNotEmpty()) {
            Log.i(
                "[android-live] ${ch.name} 走安卓平台：defn=${rp.defn} pb=${currentPlaybackTime}" +
                    " start=${rp.playbackStart}（${if (needDecrypt) "sm4c/CMG 解密" else "明文，不解密"}）"
            )
            return ResolvedPlay(rp.playUrl, !needDecrypt)
        }
        // ★★ 2026-10-22（用户实测 CCTV-10）：**必须把上游的真实原因带上来** ★★
        //   `YspAndroidLive` 现在会把 `errinfo`（例："应版权方要求，暂停提供直播信号…"）写进 `lastError`。
        //   原来这里编一句通用文案 ⇒ `onFetchFailed` 的 `msg.contains("版权")` 分支永远走不到 ⇒
        //   既**不回退原台**、状态栏也**卡在"取流中…"**（用户截图里 CCTV-10 就是这样）。
        val reason = YspAndroidLive.lastError?.takeIf { it.isNotBlank() }
        if (currentPlaybackTime != null) {
            Log.w("[replay] ${ch.name} 安卓平台回看失败 ⇒ 不再回落（明文链路是唯一链路）: $reason")
            // 回看被拒（含 DRM）优先走"回看不可用"提示；其余原因原样抛给上层分档
            throw IllegalStateException(
                if (reason != null && reason.contains("回看不可用")) reason else "回看不可用"
            )
        }
        // ⚠️ 直播路径**绝不能**把"回看不可用"当原因抛出去：`playChannel` 的 catch 见到它就会走
        //   `backToLive()` 再拉一次直播 ⇒ 无限循环（2026-10-22 实测踩过）
        val liveReason = reason?.takeIf { !it.contains("回看不可用") }
        Log.w("[android-live] ${ch.name} 明文链路没有给出 playUrl: $liveReason")
        throw IllegalStateException(liveReason ?: "取流失败（上游未返回播放地址）")
    }

    private fun onFetchFailed(ch: Channel, e: Exception, auth: Boolean, net: Boolean, userInitiated: Boolean) {
        val msg = e.message ?: ""
        when {
            // ★ 2026-10-21：回看被拒（超出回看窗口 / 该频道不支持 / 服务端 32）⇒ 明确提示 + 回到直播
            msg.contains("回看不可用") -> {
                Log.w("[replay] ${ch.name} 回看不可用 ⇒ 提示并回到直播")
                notice(Strings.REPLAY_UNAVAILABLE)
                currentPlaybackTime = null
                backToLive()
            }
            msg.contains("版权") -> {
                // ★★ 2026-10-01（用户要求统一）★★ CCTV-10 这类"版权所有方停播"也走**同一句提示**
                //   （原为"xxx 应版权方要求，暂停提供直播信号，请点击其他频道观看"）：
                //   有原台可退就说"xxx 无信号，已切回 yyy"，没有可退的原台才说"请点击其他频道"。
                //   版权原因本身已在上面的 `[android-live] … iretcode/errinfo` 日志里。
                Log.i("[play] ${ch.name} 版权停播 ⇒ 走统一回退提示")
                if (!revertWithNotice(ch.name)) setBoot(Strings.noSignalClick(ch.name))
            }
            auth -> {
                _ui.value = _ui.value.copy(playErr = false)
                setBoot(Strings.authLater(ch.name))
                scheduleNetResume(5)
            }
            net -> {
                netDownAt = System.currentTimeMillis()
                setBoot(Strings.netUnavailable(ch.name))
                scheduleNetResume(5)
            }
            /* ★★ 2026-10-22（用户实测 CCTV-10）：其它取流失败**也要回退原台** ★★
             *   原来这里只 `notice(...)` 一句浮层就完事 ⇒
             *     · 选中台/状态栏**留在失败的那个台上**（用户："选中的台标还是 CCTV-10，没有回退"）；
             *     · 状态栏停在 `取流中…`（`bootMsg` 没人改）。
             *   ⇒ 与"版权停播 / IPTV 预检失败 / 看门狗超时"统一口径：有原台就真切回原台并提示
             *     "xxx 无信号，已切回 yyy"；没有可退的台才说"暂无信号，请点击其他频道"。 */
            else -> {
                Log.w("[play] ${ch.name} 取流失败（$msg）⇒ 回退原台并提示")
                if (!revertWithNotice(ch.name)) setBoot(Strings.noSignalClick(ch.name))
            }
        }
        if (userInitiated) Log.w("[play] ${ch.name} 取流失败: $msg")
    }

    /** 首播看门狗：8s（央视频）/ 12s（直连）内没出画 ⇒ 重取一次 ⇒ 再不行回退原台 */
    private fun armWatchdog(ch: Channel, req: Int) {
        watchdogJob = viewModelScope.launch {
            delay(if (ch.isLocalDirect) LOCAL_DIRECT_NOPIC_MS else FIRST_FRAME_MS)
            if (req != playRequestId) return@launch
            // ★ 2026-10-01（与鸿蒙同）：触发时已在后台 ⇒ **不重取**（后台不下载不解密），只登记；
            //   回前台由 `onForeground()` 按离场时长恢复。
            if (hideAt > 0) {
                needRecoverOnShow = true
                Log.i("[watchdog] 触发时已在后台 ⇒ 跳过重取（回前台再处理）")
                return@launch
            }
            if (_ui.value.playing || lastPlayingId == ch.id) return@launch
            if (isNetDownRecently()) return@launch
            Log.w("[watchdog] ${ch.name} 超时未出画（retried=$retried）")
            /* ★★ 2026-10-02（与鸿蒙 `armAutoRetry` 的 direct 分支逐条对齐）★★
             *   **直连台不做"再取一次"**：鸿蒙那边直连台到点直接判无信号、回退原台（一次窗口就完），
             *   安卓原来先重取一次 ⇒ 同一台最坏要等 **2 × 15s = 30s**（用户实测"安卓要等很久"）。
             *   ⚠️ 央视频链路保留重取（它真的会因 CDN 节点问题首播失败，重取能救 —— 见 armWatchdog 头部注释）。 */
            if (!retried && !ch.isLocalDirect) {
                retried = true
                playChannel(ch, userInitiated = false)
            } else {
                _ui.value = _ui.value.copy(playErr = true)
                // ★ 2026-10-01（同步鸿蒙的分工）：直连台（江苏/IPTV）**没有取流阶段**，卡住说明播放器
                //   已经被换成坏台 ⇒ 用"真切回原台重播"的版本；央视频链路此刻仍在取流阶段，UI 版即可。
                val ok = if (ch.isLocalDirect) fallbackToLastGood(ch.name, "看门狗超时未出画")
                else revertToLastGood()
                if (!ok) {
                    notifyNoSignal(ch)   // ★ 走统一口径（用户没点过的台不再说"请点击其他频道"）
                    player.stop()
                }
            }
        }
    }

    private fun cancelWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = null
    }

    /**
     * ★ 2026-11-03：**"有声无画"看门狗** —— 修"退后台 1~2 秒立刻回前台，视频黑、声音正常"。
     *
     * 机理：退后台/回前台的瞬间，`SurfaceView` 的 Surface 可能已经失效，而播放器还在往它上面画
     * （ExoPlayer 只要有 Surface 对象就一直播，不报错）⇒ 表现为**只出声、画面全黑**，
     * 而且**换台也黑**（同一个失效 Surface 被继续复用）。
     * 用户实测线索：**切一次横屏就恢复正常** —— 因为横竖屏切换会重建 `AndroidView` ⇒ 换了一块新 Surface。
     * ⇒ 这里照抄这个"有效动作"：起播后若**仍在播（含音频）但一帧新画面都没有**，
     *   就重挂 Surface，再不行就**销毁并重建画面层**。
     *
     * ★ 2026-11-04（用户要求）：判定时间 3.5s → **1s**，第二级等待 700ms → **500ms**。
     *   理由：用户反馈"快速切前台 1 秒内最明显"，3.5s 才动手太晚 —— 黑屏会白白持续 3.5 秒。
     *   风险：起播本身若需要 >1s 才出首帧（4K/慢网），会**误判**成"有声无画"而多重建一次画面层；
     *   所以第二级仍然要求"500ms 后依旧没有新帧"才重建（一次重建 ≈ 0.3s，可接受）。
     */
    private fun armVideoWatchdog(req: Int) {
        videoWatchdogJob?.cancel()
        // ★ 2026-11-04（**修正判定依据**）：用「真正渲染出来的帧数」`renderedOutputFrames`
        //   （解码器计数器，正常播放时**持续增长**）。旧版用的是「首帧回调次数」——
        //   它只在 prepare/seek 后 +1，正常播放时不涨 ⇒ 看门狗会**误判**，自己把画面层重建掉，
        //   反而制造"偶发黑一下"。
        val framesBefore = player.renderedOutputFrames
        videoWatchdogJob = viewModelScope.launch {
            kotlinx.coroutines.delay(1_000)
            if (req != playRequestId) return@launch
            if (!player.player.isPlaying) return@launch
            if (player.renderedOutputFrames != framesBefore) return@launch
            // ① 先试轻量重挂（部分机型 `setOutputSurface` 就够）
            Log.w("[life] 1s 内无新画面（有声无画）⇒ 先重挂 Surface")
            reattachVideoSurface()
            kotlinx.coroutines.delay(500)
            if (req != playRequestId || !player.player.isPlaying) return@launch
            if (player.renderedOutputFrames != framesBefore) return@launch
            // ② 还不行 ⇒ **整块重建 PlayerView**（= 用户实测唯一有效的"切一次横屏"；
            //   实测证明只做「隐藏/显示 SurfaceView」不够 —— 换台也修不好，只有重建视图才行）
            Log.w("[life] 重挂无效 ⇒ 整块重建画面层（等同切一次横屏）")
            _ui.value = _ui.value.copy(videoViewGen = _ui.value.videoViewGen + 1)
        }
    }

    private fun cancelVideoWatchdog() {
        videoWatchdogJob?.cancel()
        videoWatchdogJob = null
    }

    /* ★ 2026-11-04：曾加过「假直播守卫」（离沿 < 4s 就 seek 回退 6s）。实测**更差**：
     *   4K 缓冲中从 1.8% 升到 5.1%（seek 本身的代价 > 断粮的代价）⇒ 已删除，不要再加回来。
     *   4K 现在只靠"起播落后 10 秒 + 时移窗口更宽（24~30s）"来保稳定。 */

    private fun onFirstFrame() {
        val u = _ui.value
        // 出画即：清错误、记 lastPlayingId、重置重建计数与网络续播计数、3s 后自动隐藏控制条
        lastPlayingId = u.activeChannelId
        // 回退历史：最新在前、去重、最多 4 个
        recentPlaying.remove(u.activeChannelId)
        recentPlaying.addFirst(u.activeChannelId)
        while (recentPlaying.size > 4) recentPlaying.removeLast()
        playerRebuilds = 0
        netResumeCount = 0
        netDownAt = 0
        _ui.value = u.copy(playErr = false, bootMsg = Strings.playingOf(u.currentName))
        showControls()
    }

    /** 回退目标 = **最近的、真的出过画、且不是当前这个失败台**的频道；没有则 null。 */
    private fun revertTarget(): Channel? {
        val active = _ui.value.activeChannelId
        for (id in recentPlaying) {
            if (id == active) continue
            val ch = Channels.byId(id) ?: _ui.value.channels.firstOrNull { it.id == id }
            if (ch != null) return ch
        }
        // 兜底：历史上还没记过（例如刚启动）时，仍按单值比较一次
        val back = Channels.byId(lastPlayingId) ?: _ui.value.channels.firstOrNull { it.id == lastPlayingId }
        return back?.takeIf { it.id != active }
    }

    /** 回退目标台名；没有可退的目标时返回 `""`。 */
    private fun revertTargetName(): String = revertTarget()?.name ?: ""

    /** ★★ 2026-10-01（用户要求统一）★★ **所有"没源"的提示都说同一句**：
     *   · 有原台可退 ⇒ "xxx 无信号，已切回 yyy"；
     *   · 没有可退的原台 ⇒ "xxx 暂无信号，请点击其他频道"。
     *   IPTV 预检失败、CCTV-10 版权停播、直连台播放器报错、看门狗超时 —— 全部走这里（与鸿蒙
     *   `Index.ets` 的 `noticeNoSignal()` 同口径）。
     *  @return 是否成功回退（true = 状态栏/选中台已回到原台）。
     */
    private fun revertWithNotice(failedName: String): Boolean {
        val backName = revertTargetName()
        val ok = revertToLastGood()
        // ★ 2026-10-22：加一行日志 —— "到底有没有回退"以前只能靠猜（用户报"台标没回退"时无从判断）
        Log.w("[play] 取流失败 ⇒ 回退 UI：$failedName ⇒ ${if (ok) backName else "无可回退"}（ok=$ok）")
        if (ok) {
            notice(Strings.fallbackTo(failedName, backName))
            noticeFallbackAt = System.currentTimeMillis()   // ★ 5 秒内别再用中性提示顶掉这条
        } else {
            _ui.value = _ui.value.copy(playErr = true)
            notice(Strings.noSignalClick(failedName))
        }
        return ok
    }

    /**
     * ★★ 2026-10-02（与鸿蒙 `noticeNoSignal(failedName, failedId)` 同口径）★★
     * "没源"的统一提示入口（**没有原台可退**的那一支）：
     *   · 失败的就是**用户亲手点的那个台** ⇒ `Strings.noSignalClick`（"xxx 暂无信号，请点击其他频道"）；
     *   · 失败的是**自动回退/自动重取拉起来的原台**（用户没点过它）⇒ `Strings.INTERRUPTED_RETRY`
     *     （中性、不提台名）—— 否则用户会觉得"条幅认错了台"（鸿蒙实测就是这个现象）。
     */
    private fun notifyNoSignal(failed: Channel) {
        if (failed.id.isNotEmpty() && failed.id != userPickedId) {
            _ui.value = _ui.value.copy(playErr = false)   // 自动恢复流程，不该标红
            setBoot("${failed.name} ${Strings.INTERRUPTED_RETRY}")
            /* ★★ 2026-10-02：刚回退过（5s 内）⇒ **不用浮层**顶掉那条"xxx 无信号，已切回 yyy"。
             *   回退到的原台多是直连慢源，这一会儿没出画是正常的；用浮层顶掉会让用户只看到这句
             *   （与鸿蒙同口径，见 `noticeFallbackAt`）。 */
            if (System.currentTimeMillis() - noticeFallbackAt > 5_000L) {
                notice(Strings.INTERRUPTED_RETRY)
            }
        } else {
            _ui.value = _ui.value.copy(playErr = true)
            notice(Strings.noSignalClick(failed.name))
        }
    }

    /** 取流阶段失败：只改 UI（还没起播放器），与鸿蒙 `revertToPlayingChannel` 同义。
     *  ⚠️ 防套娃（鸿蒙 2026-09-23 补的）：回退目标 == 当前选中台 ⇒ 不能声称它"播放中"，返回 false。 */
    private fun revertToLastGood(): Boolean {
        // ★ 2026-10-22：用"最近出过画且不是当前失败台"的那个（见 `recentPlaying`），别退回"第一个台"
        val back = revertTarget() ?: return false
        _ui.value = _ui.value.copy(
            activeChannelId = back.id,
            currentName = back.name,
            playErr = false,
            bootMsg = Strings.playingOf(back.name)
        )
        return true
    }

    /**
     * ★★ 2026-10-01（同步鸿蒙 `fallbackToPlayingChannel`）：**播放器级**失败 ⇒ **真的切回原台重播** ★★
     *
     * 与 [revertToLastGood] 的**关键分工**（别混用）：
     *   · [revertToLastGood] —— 失败在**取流阶段**，播放器根本没被换过 ⇒ 只改 UI 即可（画面仍是原台）；
     *   · 本函数 —— 失败在**播放器阶段**（IPTV 直链压根没有取流阶段；或重建已达上限）
     *     ⇒ 播放器**已经**被换成坏台（黑屏/反复报错）⇒ 必须真的把原台重播一遍。
     *
     * ⚠️ 用户实测的"四平综合 播放异常，正在恢复(1/3) 卡住、也回不到原来正常的台"就是缺这一步：
     *    原来达上限只调 UI 版的 `revertToLastGood` ⇒ 状态栏写"原台 播放中"、但播放器还是那个坏台（谎报）。
     * 防套娃：回退目标就是 `lastGoodChannelId/lastPlayingId` 本身，切过去后 `activeChannelId` 即等于它
     *    ⇒ 它若再失败，入口判断直接 false ⇒ 不会无限递归（与鸿蒙同）。
     */
    private fun fallbackToLastGood(failedName: String, reason: String): Boolean {
        // ★ 2026-10-22：同 `revertToLastGood`（用最近出过画的、且不是当前失败台的那个）
        val back = revertTarget() ?: return false
        Log.w("[player] ★ $failedName 无信号（$reason）⇒ 自动切回原台 ${back.name}")
        playerRebuilds = 0      // 换到另一个台 ⇒ 自愈额度重新计（否则一进 recoverPlayer 就撞上限）
        retried = false
        playChannel(back, userInitiated = false)   // 真正切台：重建播放器 + 重新取流
        // ★★ 2026-10-01（用户实测：香港卫视无信号切回原台时"点了没反应"）★★
        //   `playChannel` 开头会把 `videoNotice` **清空**（换台本来就该清）⇒ 原先把 `notice()` 写在它
        //   **之前**，提示会被立刻清掉、用户根本看不到 ⇒ 误以为"点了没响应"。
        //   ⇒ 必须放在 `playChannel` **之后**（此时状态已就绪，提示才留得住）。
        notice(Strings.fallbackTo(failedName, back.name))
        noticeFallbackAt = System.currentTimeMillis()   // ★ 同上：保护好这条回退提示
        return true
    }

    // ==================================================================
    // 播放器容错重建 / 网络恢复续播
    // ==================================================================

    /** @param definitive 播放器报的错是不是**确定性**的（HTTP 状态码错 / 解析失败…）。
     *  true ⇒ 直连台**跳过硬重试立即回退**（与鸿蒙 `recoverPlayer` 的直连分支同速）；
     *  false ⇒ 保留轻量重试（瞬时错误 / 慢源；见 `onPlayerError` 里的分档说明）。 */
    private fun recoverPlayer(why: String, definitive: Boolean = false) {
        val ch = Channels.byId(_ui.value.activeChannelId)
            ?: _ui.value.channels.firstOrNull { it.id == _ui.value.activeChannelId }
            ?: return
        // ★★ 2026-10-01（与鸿蒙 `recoverPlayer` 同）★★ **后台绝不重建/重拉**：
        //   后台重建 = 白下载 + 白解密 + 反复作废 token（回前台反正要重新取流）⇒ 只登记，回前台再恢复。
        if (hideAt > 0) {
            needRecoverOnShow = true
            Log.w("[player] 已在后台 ⇒ 不重建/不重拉（回前台再恢复）: $why")
            return
        }
        if (isNetDownRecently()) {
            setBoot(Strings.waitingNet(ch.name))
            scheduleNetResume(5)
            return
        }
        // ★ 2026-10-01（与鸿蒙"轻量恢复失败会自动退化"同）：这次是回前台复用旧 URL 的轻量恢复 ⇒
        //   失败说明 URL/token 已过期，**不能**按"播放器被换成坏台"处理（那会直接回退原台），
        //   而要**完整重新拉流**（重跑 auth/签名/取流）。
        if (lightReviving) {
            lightReviving = false
            Log.w("[player] 轻量恢复失败（$why）⇒ 退化为完整重新拉流")
            playChannel(ch, userInitiated = false)
            return
        }
        // ★★ 2026-10-01（用户要求：**没有播放源就马上回退**）★★
        //   直连台（江苏 / IPTV）**根本没有取流阶段** —— 播放器一报错就说明源本身取不到（清单能拉到、
        //   分片却拿不到，例如"香港卫视"那条代理 m3u8）。此时"重建 3 次 + 重拉"只会让用户干看
        //   "播放异常，正在恢复(1/3)…"（用户实测就是这种）⇒ **直接真切回原台**，不重建、不显示恢复文案。
        //   央视频链路仍保留重建：那是另一个故障模式（播放器会话被系统回收 ⇒ 此后每个台都失败，
        //   只有重建能救 —— 鸿蒙 2026-09-15 的实测结论），而且它的"无源"在**取流阶段**就已经判掉，走不到这里。
        // ★★ 2026-10-02 修订（用户实测：香港卫视 / 金鹰卡通这类**慢源**）★★
        //   昨天这里改成"直连台一报错就**立即**真切回原台"，本意是"没源就别让用户干看'正在恢复(1/3)'"。
        //   但这两条源**是活的、只是慢或偶发超时**（实测：金鹰卡通每个分片 5.4 MB / **7.9 s**；
        //   香港卫视清单还要 302 跳到 `webcast.hkstv.tv`，分片经代理），ExoPlayer 只要遇到**一次**瞬时错误
        //   就被判死 —— 而鸿蒙侧（AVPlayer 容忍度高）能播出来。⇒ 改为**先用同一个 URL 轻量重试**：
        //     · 不重新取流、不弹"正在恢复"文案、界面就是"正在缓冲"（用户看到的是"慢"，不是"坏了"）；
        //     · 最多 [DIRECT_RETRY_MAX] 次，且全部落在 [DIRECT_RETRY_WINDOW_MS] 窗口内 ⇒ 不会无限赖着；
        //     · 仍失败才真切回原台（用户要的"没有播放源马上回退"体验不受影响 —— **真·死源在预检阶段就被判掉**）。
        /* ★★ 2026-10-22（用户实测 CCTV-11 / CCTV-4K）★★
         *   现象：进台就是"播放异常，正在恢复 (1/3)"反复闪、黑屏十几秒，最后才回退。
         *   原因：**确定性失败**（清单解析不了 / 4xx / 容器不支持 —— DRM 台就是 `PARSING_MANIFEST_MALFORMED`）
         *   在直连台会跳过轻量重试，但**央视频链路仍然固定重建 3 次**（那段是给"播放器会话被系统回收"用的）。
         *   对"这条流本身就不行"的错误，重建 3 次只是让用户干等 ⇒ 一次判死、立即回退原台。
         *   ⚠️ 非确定性错误（连接超时 / IO 未分类）仍走下面的 3 次重建（那才是它的用武之地）。 */
        if (definitive) {
            Log.w("[player] ${ch.name} 确定性失败（$why）⇒ 不重建，直接回退原台")
            if (!fallbackToLastGood(ch.name, why)) {
                notifyNoSignal(ch)
                player.stop()
            }
            return
        }
        if (ch.isLocalDirect) {
            /* ★★ 2026-10-02（模拟器复测发现的结构性 bug，必须记住）★★
             *   上一版写成 `if (ch.isLocalDirect && !definitive)` ⇒ **definitive 时整段被跳过**，
             *   直接掉到下面的"央视频重建"分支 ⇒ 对着坏台**反复重建**（每 3~4 秒一轮、无限循环）。
             *   ⇒ 现在 `definitive` 已在本函数**入口**统一收口（一次判死直接回退），
             *     走到这里的直连台错误一定是**非确定性**的（慢源/瞬时超时）⇒ 只做轻量重试。 */
            val now = System.currentTimeMillis()
            if (directRetries == 0) directRetryAt = now
            if (directRetries < DIRECT_RETRY_MAX && now - directRetryAt <= DIRECT_RETRY_WINDOW_MS &&
                lastPlayUrl.isNotEmpty()
            ) {
                directRetries++
                _ui.value = _ui.value.copy(playErr = false)   // 不是"出错"，是"源慢，正在缓冲"
                setBoot(Strings.buffering(ch.name))
                Log.w(
                    "[player] ${ch.name} 直连源报错（$why）⇒ 轻量重试 $directRetries/$DIRECT_RETRY_MAX" +
                        "（同一 URL 重新 prepare，不重新取流）"
                )
                player.play(ch, lastPlayUrl, lastPlayPlain, isReplay = currentPlaybackTime != null)
                armWatchdog(ch, playRequestId)   // 重试同样要有看门狗：卡住照样最终回退
                return
            }
            Log.w(
                "[player] ${ch.name} 直连源连续报错（$why；" +
                    "已轻量重试 $directRetries 次）⇒ 回退原台"
            )
            if (!fallbackToLastGood(ch.name, why)) {
                notifyNoSignal(ch)   // ★ 同看门狗：统一口径
                player.stop()
            }
            return
        }
        if (playerRebuilds >= 3) {
            // ★ 2026-10-01：这里必须用**真切回原台**的版本 —— 重建到上限说明播放器确实被换成坏台了，
            //   只改 UI 会"谎报原台在播"（用户实测：卡在"播放异常，正在恢复(1/3)"回不去）。
            if (!fallbackToLastGood(ch.name, "重建已达上限（$why）")) {
                notice(Strings.PLAYER_UNRECOVERABLE)
                player.stop()
            }
            return
        }
        playerRebuilds++
        Log.w("[player] 重建（$why, 第 $playerRebuilds/3 次）")
        setBoot(Strings.recovering(ch.name, playerRebuilds))
        viewModelScope.launch {
            player.stop()
            delay(300)          // 释放在前、重建在后（鸿蒙同序，release 不 await 以省 700~1100ms）
            playChannel(ch, userInitiated = false)
        }
    }

    private fun scheduleNetResume(sec: Int) {
        viewModelScope.launch {
            while (netResumeCount < NET_RESUME_MAX) {
                netResumeCount++
                var left = sec
                while (left > 0) {
                    setBoot(Strings.netResume(_ui.value.currentName, left, netResumeCount))
                    delay(1000)
                    left--
                    if (netDownAt == 0L) return@launch   // 已恢复
                }
                val ch = Channels.byId(_ui.value.activeChannelId)
                    ?: _ui.value.channels.firstOrNull { it.id == _ui.value.activeChannelId }
                    ?: return@launch
                // ★ 2026-10-22：明文链路**没有 auth/token 缓存**（每次现算 cKey 现请求）⇒ 直接重拉即可
                playChannel(ch, userInitiated = false)
                return@launch
            }
        }
    }

    private fun isNetDownRecently(): Boolean =
        netDownAt > 0 && System.currentTimeMillis() - netDownAt < 15_000

    private fun isAuthErr(e: Exception): Boolean =
        e is AuthExpiredException || (e.message ?: "").contains("鉴权失效")

    private fun isNetErr(e: Exception): Boolean {
        val m = (e.message ?: "").lowercase()
        return m.contains("网络") || m.contains("timeout") || m.contains("timed out") ||
            m.contains("unable to resolve") || m.contains("failed to connect") ||
            m.contains("connection") || m.contains("socket")
    }

    // ==================================================================
    // EPG
    // ==================================================================

    private fun clearEpg() {
        epgJob?.cancel()
        /* ★ 2026-11-10（用户要求：与鸿蒙端一致）：**地方台/没有节目单** ⇒
         *   「正在播出」显示「暂无节目单」（节目条里是白粗字）、「接下来」显示 `-`
         *   （鸿蒙 `episodeNow='暂无节目单'` / `episodeNext='-'` 同款）。原来这里是 `- / 暂无节目单`，反了。 */
        _ui.value = _ui.value.copy(
            epg = emptyList(),
            epgNow = Strings.EPG_NONE,
            epgNext = Strings.EPG_DASH
        )
    }

    private fun fetchEpg(ch: Channel) {
        epgJob?.cancel()
        epgPid = ch.pid
        epgJob = viewModelScope.launch {
            var attempt = 1
            while (attempt <= 3) {
                try {
                    // ★ 2026-10-22（用户要求）：节目单扩到"过去 6 天 + 今天 + 未来 3 天"
                    //   过去的天用于**回看**；未来的天用于**预约/预告**。
                    //   单天失败只跳过该天（fetchRange 内部已吞掉），不会整段失败。
                    val list = withContext(Dispatchers.IO) {
                        Epg.fetchRange(ch.pid, pastDays = 6, futureDays = 3)
                    }
                    if (epgPid != ch.pid) return@launch
                    lastEpgDay = Epg.todayYmd()
                    lastEpgFetchAt = System.currentTimeMillis()   // ★ 30s 对齐门槛从现在起算
                    applyEpg(list)
                    startEpgTicker(ch)
                    // ★★ 2026-10-22（用户实测）：重试成功后**必须把状态栏还给播放状态** ★★
                    //   原来 `EPG_RETRYING` 只是写进 bootMsg，成功分支没人改 ⇒ 状态栏永远挂在
                    //   "节目单加载失败，正在重试…"（用户原话"一直不消失，应该显示 XXX 播放中"）。
                    restoreBootAfterEpg(ch)
                    return@launch
                } catch (e: Exception) {
                    if (attempt == 3) {
                        setBoot(Strings.EPG_FAILED)
                        // ★ 2026-11-10：与鸿蒙同款（正在播出=暂无节目单，接下来=`-`）
                        _ui.value = _ui.value.copy(epgNow = Strings.EPG_NONE, epgNext = Strings.EPG_DASH)
                        delay(4000)          // 让用户看到"失败"这条，再还回播放状态（不然也永远不消失）
                        restoreBootAfterEpg(ch)
                        return@launch
                    }
                    setBoot(Strings.EPG_RETRYING)
                    delay(2000L * attempt)
                    attempt++
                }
            }
        }
    }

    /** EPG 只是"借状态栏显示进度" ⇒ 收尾时把状态栏还给**播放状态**。
     *  ★ 2026-10-22（用户实测"节目单重试成功后状态栏一直不消失"）：只在当前文案确实是 EPG 那两句时才改，
     *    避免把播放器刚写进去的"正在缓冲 / 播放中"覆盖掉。 */
    private fun restoreBootAfterEpg(ch: Channel) {
        val cur = _ui.value.bootMsg
        if (cur != Strings.EPG_RETRYING && cur != Strings.EPG_FAILED) return
        setBoot(if (_ui.value.playing) Strings.playingOf(ch.name) else Strings.buffering(ch.name))
    }

    private fun applyEpg(list: List<Epg.Item>) {
        val now = System.currentTimeMillis() / 1000
        // ★ 2026-10-21：回看/时移时，节目条的"正在播出"基准 = **正在回看的那个时刻**（不是此刻）
        val ref = _ui.value.replayStart.takeIf { it > 0L } ?: now
        val idx = Epg.indexOfNow(list, ref)
        val cur = if (idx >= 0) list[idx] else null
        val nxt = if (idx >= 0 && idx + 1 < list.size) list[idx + 1] else null
        _ui.value = _ui.value.copy(
            epg = list,
            epgDays = Epg.groupByDay(list).map { it.first },
            epgNow = cur?.let { "${Epg.hhmm(it, true)} ${it.title}" } ?: Strings.EPG_NONE,
            epgNext = nxt?.let { "${Epg.hhmm(it, true)} ${it.title}" } ?: Strings.EPG_NO_NEXT
        )
    }

    /**
     * ★ 2026-11-10（用户要求，与鸿蒙同款）：
     *   · ticker 仍是 **10s** 粒度，只做**本地**时间推进（零网络开销）；
     *   · 真正走网络的门槛 = `EPG_REFRESH_MS`(30s)，且**只重拉今天那一天**（1 个请求/30s）；
     *   · 其余 9 天只在换台 / 回前台 / 跨天时由 `fetchEpg` 全量拉 —— 否则 30s × 10 天请求过密。
     */
    private fun startEpgTicker(ch: Channel) {
        viewModelScope.launch {
            while (true) {
                delay(10_000)
                if (epgPid != ch.pid) return@launch
                val list = _ui.value.epg
                if (list.isNotEmpty()) applyEpg(list)
                val day = Epg.todayYmd()
                if (day != lastEpgDay) {
                    fetchEpg(ch)
                    continue
                }
                if (System.currentTimeMillis() - lastEpgFetchAt >= EPG_REFRESH_MS) refreshEpgToday(ch)
            }
        }
    }

    /**
     * ★ 2026-11-10（用户要求）：**只重拉今天**并合并进现有 10 天（1 个请求/30s，代价可忽略）。
     *   与鸿蒙 `fetchEpgToday` 完全同一条策略；失败静默（下一个 tick 再试，节目单是分钟级数据）。
     */
    private fun refreshEpgToday(ch: Channel) {
        if (epgTodayRefreshing) return
        epgTodayRefreshing = true
        viewModelScope.launch {
            try {
                val ymd = Epg.todayYmd()
                val one = withContext(Dispatchers.IO) { Epg.fetch(ch.pid, ymd) }
                if (epgPid != ch.pid || one.isEmpty()) return@launch
                val kept = _ui.value.epg.filter { it.ymd != ymd }
                lastEpgFetchAt = System.currentTimeMillis()
                // 先剔除今天的旧数据（服务端可能修正过标题/时间），再合并、按开始时间排序
                applyEpg((kept + one).sortedBy { it.start })
            } catch (_: Exception) {
                // 静默：不影响播放
            } finally {
                epgTodayRefreshing = false
            }
        }
    }

    fun openEpg() {
        _ui.value = _ui.value.copy(showEpg = true)
    }

    fun closeEpg() {
        _ui.value = _ui.value.copy(showEpg = false)
    }

    // ==================================================================
    // 手势 / 控制条 / 全屏
    // ==================================================================

    fun showControls() {
        _ui.value = _ui.value.copy(controlsVisible = true)
        hideControlsJob?.cancel()
        hideControlsJob = viewModelScope.launch {
            delay(3000)
            _ui.value = _ui.value.copy(controlsVisible = false)
        }
    }

    fun toggleControls() {
        if (_ui.value.controlsVisible) {
            hideControlsJob?.cancel()
            _ui.value = _ui.value.copy(controlsVisible = false)
        } else {
            showControls()
        }
    }

    /** 竖滑右半屏 = 音量（5% 一档，步进 -offsetY/300，起点为滑动开始时的音量）。
     *  ★★ 2026-10-01 修 bug（用户真机实测："音量只能在 95%~100% 抖，下滑后自己弹回 100%"）★★
     *   鸿蒙用的是 `PanGesture` 的**累计** `offsetY`（`step = -event.offsetY / 300`）⇒ 第二个参数
     *   必须是**从手势开始算起的累计位移**。原来 UI 层把 Compose `onVerticalDrag` 给的**每帧增量**
     *   直接传进来，却仍以"起点音量"为基准 ⇒ 每个事件只在起点附近偏移一点点、且下一帧又从头算
     *   ⇒ 表现就是"在起点附近来回抖 + 松手前弹回"。UI 层已改为累加（`PlayerArea` 的 `dragOffsetY`）。
     *  ⚠️ 音量改的是**播放器自身音量**（`AVPlayer.setVolume` / `player.volume`，0~1），与系统媒体
     *     音量叠加 —— 与鸿蒙同口径（鸿蒙注：`AudioManager.setVolume` 已 deprecated 且要权限，不用）。 */
    /** ★★ 手势的"起点值"必须**现读**（2026-10-01 用户实测："每次都从 100% 开始，不是从当前音量"）★★
     *   原因：`PlayerArea` 的手势跑在 `pointerInput(ui.locked)` 里，该 lambda 固化的是**组合时的 `ui` 快照**
     *   ⇒ `ui.volume` 停在旧值（用户后续调过音量，快照不会跟着变）。
     *   亮度之所以手感正常，是因为它的起点存在 `remember` 的 State 里（每次读都是最新值）✓。
     *   ⇒ 统一从 VM 现读，等价于鸿蒙在 `onActionStart` 里读 `this.volRatio`。 */
    fun currentVolume(): Float = _ui.value.volume

    /** 竖滑右半屏 = 音量（5% 一档，`起点 - 累计位移/300`，与鸿蒙 `PanGesture` 同口径）。 */
    fun dragVolume(startVolume: Float, offsetY: Float) {
        if (_ui.value.locked) { showControls(); return }
        val v = (startVolume - offsetY / 300f).coerceIn(0f, 1f)
        val snapped = Math.round(v * 20f) / 20f
        player.setVolume(snapped)
        prefs.volume = snapped
        // ★ 2026-10-01：**只在档位变化时**打一行（不刷屏）—— 用户真机复测时这一行能直接判定手势是否正常：
        //   正常：offsetY 逐渐累积、音量平滑升降；坏掉（老 bug）：offsetY 很小且在起点附近抖动。
        if (snapped != _ui.value.volume) {
            Log.i("[gesture] 音量 ${(snapped * 100).toInt()}%（起点 ${(startVolume * 100).toInt()}% 累计位移 ${offsetY.toInt()}px）")
        }
        _ui.value = _ui.value.copy(
            volume = snapped,
            muted = snapped == 0f,
            gestureHint = Strings.volumeHint((snapped * 100).toInt())
        )
    }

    // ★ 2026-10-04（用户拍板）：**TV 版不放"应用内音量"** —— "既然默认能通过遥控调节电视音量，就没有必要
    //   在 APP 中再调节了，符合 TV app 的惯例"。当日曾加过 `nudgeVolume(steps)`（给 TV 控制行的音量±按钮用）
    //   并已删除。⇒ 音量只走**电视遥控/系统**（TV 界面**不拦**音量键）+ 应用内只保留"静音"开关。
    //   ⚠️ 别再往这里是加"TV 音量"之类的接口。

    /** 竖滑左半屏 = 亮度（实际改 window 亮度由 UI 层做，这里只负责提示文案） */
    fun hintBrightness(percent: Int) {
        _ui.value = _ui.value.copy(gestureHint = Strings.brightnessHint(percent))
    }

    fun clearGestureHint() {
        viewModelScope.launch {
            delay(800)
            _ui.value = _ui.value.copy(gestureHint = "")
        }
    }

    /**
     * ★★ 2026-10-04（用户实测：电视端"画面卡跳严重、基本没法看"）★★ **TV 切到"稳"的直播参数**。
     *
     * 由 `MainActivity`（它才知道 `isTv`）在 `LaunchedEffect(isTv)` 里调用一次：
     * TV ⇒ `PalmPlayer.relaxedLive = true`（目标落后直播沿 10s、**不追播**）；手机 ⇒ false（低延迟 6s、0.97~1.03×）。
     * ⚠️ 只改一个标志位，**下一次 `play()`（换台/重取流）才生效** —— 正在播的这条流不会被中途改参数。
     */
    fun setTvPlaybackMode(on: Boolean) {
        if (player.relaxedLive == on) return
        player.relaxedLive = on
        Log.i("[tv] 播放参数：${if (on) "TV 稳（落后 10s、不追播）" else "手机 低延迟（6s、0.97~1.03×）"}")
    }

    // ⚠️ 2026-10-04：曾加的 `setVideoDefn()`（画质降档 hd/sd）**已删除** —— 真机实测证明上游不认 `hd`，
    //   切过去每个台都 `get-live-info 无 playurl` ✗（还因为持久化把"重开 App"也带废了）。
    //   ⇒ 画质恒为 `fhd`；要再试降档，必须先确认上游支持（看返回里有没有 playurl），别再接到 UI 上。

    fun toggleMute() {
        val muted = !_ui.value.muted
        player.setVolume(if (muted) 0f else _ui.value.volume)
        _ui.value = _ui.value.copy(muted = muted)
    }

    fun togglePlayPause() {
        // ★ 2026-10-22：暂停期间位置时钟必须停走，否则恢复后时移基准会偏
        if (player.player.isPlaying) {
            player.player.pause(); markPause(true)
        } else {
            player.player.play(); markPause(false)
        }
        showControls()
    }

    fun toggleFullscreen() {
        val f = !_ui.value.fullscreen
        _ui.value = _ui.value.copy(fullscreen = f, controlsVisible = true)
    }

    fun toggleLock() {
        _ui.value = _ui.value.copy(locked = !_ui.value.locked, controlsVisible = true)
    }

    /** 视频区中央浮层提示。
     *  ★ 2026-10-01（用户要求）：**2 秒后自动消失**（5 秒 → 1 秒 → 2 秒；鸿蒙 `showVideoNotice` 同步为 2 秒）。 */
    fun notice(text: String) {
        _ui.value = _ui.value.copy(videoNotice = text)
        viewModelScope.launch {
            delay(2000)
            if (_ui.value.videoNotice == text) _ui.value = _ui.value.copy(videoNotice = "")
        }
    }

    // ==================================================================
    // 生命周期
    // ==================================================================

    /**
     * ★ 2026-11-03：**回前台重新挂载视频 Surface** 用的界面引用（弱引用，界面销毁不拖住 VM）。
     *
     * 为什么需要：`onBackground()` 会 `pause()+stop()`，回前台走"轻量恢复"（复用同一 URL 重新 prepare）。
     * 用户实测：**退后台 1~2 秒立刻回前台 ⇒ 声音正常、画面全黑**；隔久一点（>30s，走完整重拉）就正常。
     * 差别只在"恢复得快不快"：快的时候 `SurfaceView` 的 surface 还没重新 attach 完，
     * 视频解码器就已经建好 ⇒ 拿不到（或拿到已失效的）输出面 ⇒ **只出音频**
     * （ExoPlayer 在 surface 为空时会照常播音频，所以"有声无画"）。
     * ⇒ 回前台后延迟 400ms **显式重挂一次** surface：此时它已就位，播放器会重新配置输出面，画面立刻回来，
     *   而且不打断已经开始播放的音频。
     */
    private var videoViewRef: java.lang.ref.WeakReference<android.view.View>? = null

    /** 由界面在创建 `PlayerView` 时调用（手机 `MainScreen` / TV `TvHomeScreen` 各一处）。 */
    fun attachVideoView(v: android.view.View) {
        videoViewRef = java.lang.ref.WeakReference(v)
    }

    /* ★ 2026-11-04：`recreateVideoSurface()`（隐藏/显示 SurfaceView）已删除。
     *   用户实测：黑屏时**换台也修不好，只有切一次横屏才恢复** ⇒ 说明"只重建 Surface"无效，
     *   必须**整块重建 PlayerView**。现由 `videoViewGen` + UI 侧 `key(...)` 完成（见该字段注释）。 */

    private fun reattachVideoSurface() {
        val pv = videoViewRef?.get() as? androidx.media3.ui.PlayerView ?: return
        val sv = pv.videoSurfaceView ?: return
        try {
            when (sv) {
                is android.view.SurfaceView -> player.player.setVideoSurfaceView(sv)
                is android.view.TextureView -> player.player.setVideoTextureView(sv)
                else -> return
            }
            Log.i("[life] 重新挂载视频 Surface（${sv.javaClass.simpleName}）")
        } catch (e: Exception) {
            Log.w("[life] 重挂 Surface 失败: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * ★★ 2026-10-01（与鸿蒙 `onPageHide` 对齐）★★ **退后台 = 暂停 + 立即停流**。
     *   为什么必须停流：直播的 m3u8 / 分片 token 都会过期，后台继续下载+解密毫无意义；
     *   而**只 pause 不停流**会让播放器继续缓冲 ⇒ 回前台时播的是一堆过期分片
     *   （用户实测："地方台超过 10 秒回前台，播完缓冲数据后直接显示信号中断"）。
     */
    fun onBackground() {
        hideAt = System.currentTimeMillis()
        Log.i("[life] 退后台 ⇒ 暂停 + 停流（后台不下载/不解密，回前台按离场时长恢复）")
        player.player.pause()
        player.player.stop()   // 释放 MediaSource ⇒ 真正停止下载（直播间不需要保留播放位置）
        cancelWatchdog()
        cancelVideoWatchdog()  // ★ 2026-11-03：后台不要触发"重建画面层"（回前台会重新挂）
        // ★ 2026-10-02（与鸿蒙 `onPageHide` → `TvSession.destroy()` 对齐）：连播控卡片一起收掉。
        //   此时播放器已 stop（IDLE），若留着服务，Media3 的 IDLE 默认策略
        //   （`SHOW_NOTIFICATION_FOR_IDLE_PLAYER_AFTER_STOP_OR_ERROR`）会**继续挂一张卡片**，
        //   而卡片上的播放键在后台按下去毫无反应（媒体源已释放）⇒ 正是鸿蒙注释里说的
        //   "留卡片 = 留失效按钮"。回前台起播时 `ensureService()` 会重建（见 PlayerHolder）。
        PlayerHolder.stopService(getApplication())
    }

    /**
     * ★★ 2026-10-01（与鸿蒙 `onPageShow` 对齐）：**按离场时长二选一** ★★
     *   · 离场 **≤30s** 且是**央视频链路** ⇒ **轻量恢复**：复用上次的 URL 重新 prepare（跳过 auth/签名/取流）；
     *   · 离场 **>30s**、或**直连台**（江苏/IPTV 的 URL 带时间戳 token，且重新取流本来就便宜）、
     *     或后台出过错 ⇒ **完整重新拉流**（`playChannel`）。
     *   ⚠️ 直连台**一律**重新拉流：它们的 `txSecret/txTime` 是时间敏感的，复用旧 URL 必然"播一会儿就断"
     *      —— 这正是用户实测的"信号中断"。
     */
    fun onForeground() {
        val away = if (hideAt > 0) System.currentTimeMillis() - hideAt else 0L
        hideAt = 0L
        val id = _ui.value.activeChannelId
        val ch = Channels.byId(id) ?: _ui.value.channels.firstOrNull { it.id == id }
        Log.i("[life] 回前台（后台 ${away / 1000}s）")
        if (ch == null) return
        // ★ 与鸿蒙 `onPageShow` **完全同口径**：只按"离场时长（>30s）+ 后台出过错 + 没有可复用 URL"决定。
        //   ⚠️ 我一开始还给直连台加了"一律完整重新拉流"，那是多余的：鸿蒙 `reviveSameUrl()` 对所有频道
        //   一视同仁（复用同一 URL 重建播放器），失败时**自动退化**为完整重新拉流
        //   （见 `recoverPlayer` 的 `lightReviving` 分支）—— 两段合起来才等价，别只抄一半。
        val needFull = away > REVIVE_SAME_URL_MAX_MS || needRecoverOnShow || lastPlayUrl.isEmpty()
        if (needFull) {
            // ★ 2026-10-22：明文链路没有 auth/token 缓存可作废（cKey 每次现算）⇒ 直接完整重拉
            Log.i("[life] 后台 ${away / 1000}s ⇒ 完整重新拉流（直连台/后台出过错/无可复用 URL）")
            playChannel(ch, userInitiated = false)
        } else {
            Log.i("[life] 后台 ${away / 1000}s（≤${REVIVE_SAME_URL_MAX_MS / 1000}s）⇒ 轻量恢复（复用同一 URL）")
            lightReviving = true   // ★ 失败时由 recoverPlayer 退化为"完整重新拉流"（鸿蒙同）
            val req = ++playRequestId
            retried = false
            _ui.value = _ui.value.copy(playErr = false, playing = false)
            setBoot(Strings.buffering(ch.name))
            player.setVolume(if (_ui.value.muted) 0f else _ui.value.volume)
            // ★ 2026-10-02：这条"轻量恢复"路径**不经过 `playChannel`** ⇒ 必须自己重建播控卡片
            //   （退后台时 `onBackground` 已把服务收掉）。否则"回前台后卡片再也起不来"——
            //   而它恰恰是最常见的路径（离场 <30s 回前台）。
            PlayerHolder.ensureService(getApplication())
            player.play(ch, lastPlayUrl, lastPlayPlain, isReplay = currentPlaybackTime != null)   // 同一 URL 重新 prepare（ExoPlayer 会重建 MediaSource）
            armWatchdog(ch, req)           // 轻量恢复也要看门狗：卡住照样回退
        }
        // ★ 2026-11-03：**"有声无画"看门狗** —— 回前台后若仍在出声但没新画面，就重建画面层
        //   （`setVideoSurfaceView` 对"已失效的 Surface"无效，实测用户反馈仍黑；重建视图才等价于
        //    "切一次横屏"，那是唯一被实测证明有效的动作）。见 `armVideoWatchdog` 注释。
        armVideoWatchdog(playRequestId)
    }

    override fun onCleared() {
        super.onCleared()
        cancelWatchdog()
        PlayerHolder.onSwitchChannel = null   // ★ 解绑播控切台钩子（避免单例引用已销毁的 VM）
        // ★★★★★ 2026-10-31 修 BUG：**这里绝不能 release 播放器** ★★★★★
        //   `player` 是 `PlayerHolder` 里的**全局唯一实例**。按返回键 → Activity 结束 → onCleared
        //   → release 掉它，再次打开时 `PlayerHolder.get()` 仍返回那个**已释放**的实例 ⇒
        //   ExoPlayer 内部线程已死，之后 `setMediaItem` 抛
        //   `IllegalStateException: Handler ... on a dead thread` ⇒ 分片不请求 ⇒ 看门狗死循环
        //   ⇒ 表现就是"回前台不能续播、切台也不能播，只能杀进程重开"。
        //   ⇒ 界面销毁只**停播**；播放器生命周期归 `PlayerHolder.release()`。
        try {
            player.player.stop()
        } catch (e: Exception) {
            Log.w("[life] onCleared stop 异常: ${e.javaClass.simpleName}: ${e.message}")
        }
        PlayerHolder.stopService(getApplication())
    }

    private fun setBoot(msg: String) {
        _ui.value = _ui.value.copy(bootMsg = msg)
    }

    private fun appVersionName(): String = try {
        val pi = getApplication<Application>().packageManager
            .getPackageInfo(getApplication<Application>().packageName, 0)
        pi.versionName ?: "-"
    } catch (e: Exception) {
        "-"
    }

    private companion object {
        /**
     * 央视频链路的"首帧"窗口。
     * ★★ 2026-10-08：**8s → 14s**。原因：这条链路现在多了"取流前置工作"——
     *   `liveinfo` 一次 + **可播性自检**（清单 + 首个分片）+ 3.5 MB 分片下载 + 解码器起播，
     *   实测**首帧会超过 8 秒** ⇒ 旧值会在画面即将上屏时把播放打断（表现为"一直不出画、反复重取"，见
     *   `onVideoSizeChanged` 里的长注释）。直连台仍是 `LOCAL_DIRECT_NOPIC_MS`(15s) 不变，两者量级一致。
     */
    const val FIRST_FRAME_MS = 14_000L
        /** ★★ 2026-10-02 二次调整（用户要求"安卓和鸿蒙的判断逻辑要同步"）：18s → **15s（三端统一）** ★★
         *  背景：安卓这边为容忍金鹰卡通那种"分片 5.4 MB / 7.9 s"的慢源，曾把 12s 上调到 18s，
         *  而鸿蒙一直是 12s ⇒ 同一台无信号，两端等待差 6 秒（用户实测："安卓判断无信号的耗时比鸿蒙长很久"）。
         *  ⇒ 取中间值 **15s 三端统一**（金鹰卡通首帧天然≈12s，留 3s 余量；鸿蒙 AVPlayer 起播更快，15s 绰绰有余）。
         *  ⚠️ 这个窗口同时决定"回退后的原台能不能来得及出画"：太短会把**能播但慢**的原台判成无信号，
         *     于是回退条幅被后一句中性提示顶掉（用户实测的两种表现是同一个根因）。
         *  真·死源在**预检阶段**就判掉了，所以放宽这里不会让用户白等死源。 */
        const val LOCAL_DIRECT_NOPIC_MS = 15_000L
        const val NET_RESUME_MAX = 24
        /** ★ 2026-10-02：直连台播放器报错后的**轻量重试**额度与窗口（慢源容忍，见 `recoverPlayer`）。
         *  ★ 2026-10-02 二次调整（用户要求"安卓也要像鸿蒙那样快"）：**2 次/25s → 1 次/15s**。
         *    现在这个重试**只对瞬时错误**生效（确定性错误立即回退，见 `onPlayerError` 分档）；
         *    所以额度收一半即可 —— 慢源仍有一次自愈机会，而坏源不会再被"赖着"等 25 秒。 */
        const val DIRECT_RETRY_MAX = 1
        const val DIRECT_RETRY_WINDOW_MS = 15_000L
    }
}
