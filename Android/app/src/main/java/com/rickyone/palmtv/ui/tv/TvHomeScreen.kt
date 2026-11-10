package com.rickyone.palmtv.ui.tv

import android.app.Activity
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.rickyone.palmtv.MainViewModel
import com.rickyone.palmtv.UiState
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.Epg
import com.rickyone.palmtv.data.Log
// ★ 2026-10-05：本工程**第一次**在 Kotlin 里引用资源（`R.layout.tv_player_view`）——
//   以前资源只在 manifest 里引 ⇒ 没有任何 Kotlin 文件 import 过 `R` ⇒ 少这一句就报
//   "Unresolved reference 'layout'"（编译期就挂，且报错位置在 `inflate(...)` 的实参上，很容易看歪 ✗）。
import com.rickyone.palmtv.R
import com.rickyone.palmtv.player.Logos
import com.rickyone.palmtv.player.PalmPlayer
import com.rickyone.palmtv.player.PlayStats
import com.rickyone.palmtv.ui.Palette
import com.rickyone.palmtv.ui.Strings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * ★★ 2026-10-04：安卓 **TV 版**界面（方案 A —— 同一个 APK，运行时按设备分流）★★
 *
 * 与手机版的差别（**只差 UI 层**，业务/取流/解密/播放器 100% 复用同一个 `MainViewModel`）：
 *   · **焦点优先**：所有可交互项都走 Compose 焦点系统（遥控方向键移动、OK 键点击），
 *     焦点态 = 蓝色描边 + 底色变亮（TV 上没有鼠标悬停，必须给"我在哪"的视觉反馈）；
 *   · **不用触摸手势、也不放"应用内音量"**：手机版的"左半调亮度 / 右半调音量"在 TV 上是死的 ⇒
 *     **音量完全交给电视遥控/系统**（音量键我们**不拦**）—— 这是 TV 应用的惯例（2026-10-04 用户拍板；
 *     当日曾短暂加过「音量− / 音量+」按钮，随后按要求撤掉，控制行只留「播放/暂停 · 静音 · 全屏」）。
 *     播放/暂停用 OK 键，切台用遥控「频道 +/-」键（`Key.ChannelUp/ChannelDown`）或列表里选；
 *   · **全屏规则（2026-10-05 用户定稿）**：**真的出画面之后 8 秒**无操作才自动进全屏（没画面绝不切）；
 *     全屏时 **OK = 直接退出全屏**（控制条已收起的情况下，一键返回，省掉"先唤出再挪焦点"）；
 *     全屏时 **上/下 = 换台**（手机遥控常没有"频道±"键）；控制条 4 秒自动收起，按方向键唤出；
 *     **退出全屏后焦点默认停在"正在播的那个台"上**（`TvChannelGrid` 把 `gridFocus` 挂在在播台格子上 ✓）；
 *   · **恒横屏、大尺寸**：不做竖屏分支，频道卡片与字号都比手机大一档；
 *   · **不做自定义 IPTV 源**（用户 2026-10-04 决定）：TV 上打字太痛苦 ⇒ 关于页里改为一行说明，
 *     编辑仍在手机版 / 桌面版做；
 *   · 布局：左 68% = 状态行 + 画面 + 节目条 + 控制行；右 32% = 分组 Tab + 频道网格 / 关于页
 *     （比例与手机横屏分栏一致，见 `MainScreen.LAND_VIDEO_WEIGHT`）。
 */
/** 全屏 HUD（控制行）无操作后自动隐藏的时间（2026-10-04 用户要求"别一直摆着"）。 */
private const val HUD_AUTO_HIDE_MS = 4_000L

/**
 * **真的出画面之后**，再无任何操作多久就自动进全屏。
 *
 * ★ 2026-10-05（用户要求："一定要在正常播放出画面后才自动全屏，调整为 8 秒"）★
 *   ⇒ 计时**起点 = `ui.playing`**（由 `onIsPlayingChanged` 驱动，= 真的在播了），时长 **8 秒**；
 *   ⚠️ 旧做法挂在 `activeChannelId` 上（"点了台就开始数"）⇒ 还在"正在缓冲…"就先替用户切了全屏 ✗。
 *   ⚠️ 代价：某台一直起不来 ⇒ **永远不自动全屏**。这正是用户要的（宁可不动，也不要"没画面就全屏"）。
 */
private const val AUTO_FULLSCREEN_MS = 8_000L

@Composable
fun TvHomeScreen(vm: MainViewModel, ui: UiState, activity: Activity?) {
    // 返回键：先关节目单、再退全屏，最后才是退出应用
    BackHandler(enabled = true) {
        when {
            ui.showEpg -> vm.closeEpg()
            ui.fullscreen -> vm.toggleFullscreen()
            else -> activity?.finish()
        }
    }

    // ★★ 2026-10-04（用户问："全屏后下方三个按钮一直都在显示？"）★★
    //   全屏时的控制行改成**自动隐藏的 HUD**：进全屏先显示，**4 秒无操作自动隐藏**；
    //   隐藏后**方向键只负责"唤出"HUD**（这一下不执行按钮动作 —— 免得用户只是想看一眼控制条
    //   却把播放按暂停了），再按一下才是真正的操作；`频道±` / 媒体键属于明确动作 ⇒ 唤出同时直接执行。
    //   ★ 2026-10-05（用户要求："全屏后按 OK 键直接退出全屏，减少操作"）：HUD 隐藏时 **OK = 直接退出全屏** ✓
    //     （原来还要"唤出 → 方向键挪到[退出全屏]按钮 → 再按 OK"，太绕）。
    //   ⚠️ HUD 用 `alpha` 变透明而**不是"不组合"**：这样焦点不丢、根部的按键回调照收 ——
    //     Compose 的按键沿"焦点路径"分发，一个可聚焦元素都没有时根部是收不到键的（实测坑）。
    //   ⚠️ 定时器用 `hudTick` 自增来重置：只把 `hudVisible` 置 true 是**不会**重开 `LaunchedEffect` 的。
    var hudVisible by remember { mutableStateOf(true) }
    var hudTick by remember { mutableIntStateOf(0) }
    fun pokeHud() { hudVisible = true; hudTick++ }
    LaunchedEffect(ui.fullscreen) { pokeHud() }          // 进出全屏先露出来
    LaunchedEffect(hudTick, hudVisible) {
        if (hudVisible) {
            delay(HUD_AUTO_HIDE_MS)
            hudVisible = false
            // 打一行便于真机/模拟器核对（logcat 过滤 [tv] 即可）
            Log.i("[tv] 全屏控制条自动隐藏（方向键唤出 · OK 直接退出全屏）")
        }
    }

    // ★ 2026-10-04：台标解码**后台预热** —— `TvChannelTile` 原来是在组合里**同步** `Logos.load()`
    //   （主线程解码 PNG）⇒ 第一次进分组 / 切台那一下会顿一下。这里在分组变化时后台把整组解进缓存
    //   （`Logos`：整包已读进内存 + `android.util.LruCache` 线程安全 ⇒ 后台解是安全的），之后格子全命中缓存、零解码。
    //   ⚠️ 只是"预热"：取不到图不影响任何逻辑（格子仍走原来的文字兜底）。
    val ctx = LocalContext.current
    LaunchedEffect(ui.activeGroup, ui.channels) {
        withContext(Dispatchers.IO) {
            ui.channels.filter { it.group == ui.activeGroup }.forEach { c ->
                runCatching { Logos.load(ctx, c) }
            }
        }
    }

    // ★★ 2026-10-04（用户要求："TV 侧默认打开 CCTV-1 台"）★★
    //   TV **冷启动自动开播**：优先**续播上次看的那台**，没有记录/台不在了 ⇒ **CCTV-1**
    //   （VM 里的 `startDefaultChannel()` 有完整说明）。
    //   ★ 2026-10-08：手机版也接上了同一套（见 `MainScreen`），不再是 TV 专属。
    //   ⚠️ 等免责声明关掉再起播（首启弹层时别在后台偷偷拉流）；⚠️ 只在"当前没有台在播"时动手（旋转重建/回前台不打断）。
    LaunchedEffect(ui.showDisclaimer) {
        if (!ui.showDisclaimer) vm.startDefaultChannel()
    }

    // ★★ 2026-10-04（用户要求："记住上次选中的台"）★★ 焦点策略：
    //   进界面 / 换分组 / 切 Tab / 进出全屏 / 关掉免责声明之后 ⇒ 把焦点放到**正在播的那个频道格子**上
    //   （那台不在当前分组就放第一格；关于页或全屏则给控制行）—— 于是"上次选中的台"始终在焦点上，
    //   用户按方向键就能接着逛，不用每次从左上角重新开始。
    //   ⚠️ 只在**这些时机**搬焦点，**不要**跟着 `activeChannelId` 走：否则用户正在按控制条 / 看节目单时
    //     被看门狗切台会把焦点抢走（这条思路坑记在这儿，别再这样写）。
    val gridFocus = remember { FocusRequester() }
    val barFocus = remember { FocusRequester() }
    LaunchedEffect(ui.activeGroup, ui.aboutTab, ui.fullscreen, ui.showDisclaimer) {
        if (ui.showDisclaimer) return@LaunchedEffect
        withFrameNanos { }   // 让一帧：等目标（网格 / 控制行）组合完成
        runCatching {
            if (ui.aboutTab || ui.fullscreen) barFocus.requestFocus() else gridFocus.requestFocus()
        }
    }

    // ★★ 2026-10-04 电视实测反馈的落地（三件一起做）★★
    //   ① EPG"首次打开没定位焦点、OK 关不掉" ⇒ 把**滚动状态提到这里**，节目单的按键（上下滚动 / OK·返回关闭）
    //      **由根部按键预览统一处理**，不再依赖"焦点有没有落在弹层上"（焦点那次只是没抢到，见 `TvEpgModal` 的修复）。
    //   ② "自动播放/换台播放 N 秒后没有操作自动全屏" ⇒ `autoFsPending` 计时；**任何按键都取消**它
    //      （用户已经在操作了，不该再替他切全屏）。
    //      ★ 2026-10-05（用户要求："一定要在正常播放出画面后才自动全屏，调整为 8 秒"）：
    //        计时**只在"真的出画面"（`ui.playing`）之后开始**、时长 **8 秒**；换台/掉线/重缓冲（playing 变假）
    //        ⇒ 立刻清零，等下次真正出画面再重新数（见 `AUTO_FULLSCREEN_MS` 与下面那段注释）。
    //   ③ "全屏不能换台"（华为手机遥控没有"频道±"键）⇒ 全屏下 **上/下＝换台**（见按键预览那段）。
    val uiScope = rememberCoroutineScope()
    val epgScroll = rememberScrollState()
    val epgRowPx = with(LocalDensity.current) { 46.dp.roundToPx() }
    // ★★ 2026-10-07（回看入口）★★ 节目单里"当前聚焦行"的下标 —— 提到根部的理由与 `epgScroll` 同：
    //   节目单的按键**统一在根部预览里处理**（弹层自己拿不到 OK），所以"聚焦在哪一行"也必须提到这里。
    //   用途：OK 落在**已播完**的节目上 ⇒ **回看**该节目；否则维持原行为（OK = 关闭弹层）。
    var epgFocusIdx by remember { mutableStateOf(-1) }
    var autoFsPending by remember { mutableStateOf(false) }
    // ★ 2026-10-05（用户要求"一定要在正常播放出画面后才自动全屏"）：
    //   起点 = **`ui.playing` 为真**（`onIsPlayingChanged` 给的信号 ⇒ 真的在播、画面已经出来了）；
    //   换台 / 掉线 / 重缓冲 ⇒ `playing` 变假 ⇒ **立刻停表清零**，等下次真正出画面再重新数 8 秒。
    //   ⚠️ 旧做法挂在 `activeChannelId` 上（"点了台就开始数"）⇒ 缓冲阶段就把画面切成全屏 ✗（本次按用户要求改掉）。
    //   ⚠️ 当时不挂 `playing` 的顾虑是"那台电视常在缓冲 ⇒ 功能不触发"；现在"起不来就不自动全屏"是**期望行为**，
    //     不再当缺陷（用户 2026-10-05 明确）。
    LaunchedEffect(ui.activeChannelId, ui.playing) {
        autoFsPending = ui.playing && ui.activeChannelId.isNotEmpty() && !ui.fullscreen
    }
    LaunchedEffect(autoFsPending) {
        if (!autoFsPending) return@LaunchedEffect
        delay(AUTO_FULLSCREEN_MS)
        autoFsPending = false
        if (!ui.fullscreen && !ui.showEpg && !ui.showDisclaimer && !ui.aboutTab) {
            Log.i("[tv] ${AUTO_FULLSCREEN_MS / 1000} 秒无操作 ⇒ 自动进全屏")
            vm.toggleFullscreen()
        }
    }

    // ★ 2026-10-04（电视没法接 adb 给日志）：**诊断浮层** —— 遥控「菜单」键开关。
    //   显示"取流耗时 / 解密速率 / 码率 / 分辨率 / 播放器状态"，用来判断卡跳是**解密跟不上**还是**网络/缓冲跟不上**：
    //     · 解密 KB/s 明显小于 `码率/8`（例 4Mbps ⇒ 500KB/s）⇒ 是解密瓶颈；
    //     · 解密跟得上、但状态长期 buffering ⇒ 是网络/CDN 或解码瓶颈。
    var dbg by remember { mutableStateOf(false) }
    var dbgText by remember { mutableStateOf("") }
    // ★★ 2026-10-05（用户要求："关掉关于页面上的诊断显示。保留按菜单键显示诊断"）★★
    //   ⇒ "关于"页不再常显这几个数字（当初常显是为了"用户按不出菜单键时也能把数字念给我们"，
    //     代价是**任何用户**都会在关于页看到一串技术数字）；诊断浮层照旧只用遥控「菜单」键开关 ✓。
    //   ⚠️ 顺带把采样**改成只在浮层打开时才跑**（`LaunchedEffect(dbg)` + 提前 return）：以前常驻是为喂"关于"页，
    //     现在没有那个消费方 ⇒ 关着时**零开销** ✓（原来也只是每秒一次读数 + 拼串，对播放性能无可测影响 —— 用户问过）。
    // ★★ 2026-10-05（用户报"所有台声音都延后约 0.3~0.5 秒"）★★ 诊断用的一行：**这台电视的音频能力**。
    //   判断"音频是不是被**直通**（passthrough）给了电视/音响自己解码" —— 直通那一段的延迟系统**不上报**，
    //   是"声音延后"最典型的元凶。用它 + 下面流里的音频编码，就能推断出到底走没走直通。
    val audioCaps = remember {
        runCatching { androidx.media3.exoplayer.audio.AudioCapabilities.getCapabilities(ctx) }.getOrNull()
    }
    LaunchedEffect(dbg) {
        if (!dbg) return@LaunchedEffect
        while (true) {
            val p = vm.exoPlayer()
            var br = 0
            var wh = ""
            var audio = ""
            for (g in p.currentTracks.groups) {
                for (i in 0 until g.length) {
                    if (!g.isSelected || !g.isSupported) continue
                    val f = g.getTrackFormat(i)
                    // ⚠️ 优先取**视频轨**的码率/分辨率：音频轨的 bitrate 常是 0，取到它就显示"码率 0kbps" ✗（本次踩到）
                    if (androidx.media3.common.MimeTypes.isVideo(f.sampleMimeType)) {
                        if (f.bitrate > 0) br = f.bitrate
                        if (f.width > 0 && f.height > 0) wh = "${f.width}x${f.height}"
                    } else if (androidx.media3.common.MimeTypes.isAudio(f.sampleMimeType)) {
                        // ★ 2026-10-05：显示"音频编码 + 声道 + **是否走电视直通**"。
                        //   直通判据（都用公开 API）：编码不是 PCM 且**电视声明支持**该编码 ⇒ Media3 会直通。
                        val name = (f.sampleMimeType ?: "?").substringAfterLast('/')
                        val ch = if (f.channelCount > 0) f.channelCount else 0
                        // ⚠️ 两个编译期踩坑（都试过、别再走回头路）：
                        //   ① Media3 的 `Format` **没有** `encoding` 字段 ⇒ `f.encoding` 编译不过 ✗；
                        //   ② `MimeTypes.getEncoding(mime)` 在本版本签名不是单参 ⇒ 也编译不过 ✗。
                        //   ⇒ 直接用 Media3 为此准备的公开判据：`isPassthroughPlaybackSupported(format)`
                        //     （= 这个音频格式会不会被**直通**交给电视/音响自己解码）。
                        val direct = audioCaps?.isPassthroughPlaybackSupported(f) == true
                        audio = " · 音频 $name/${ch}ch" + (if (direct) "（电视直通）" else "（本机解码）")
                        if (br == 0 && f.bitrate > 0) br = f.bitrate
                    } else if (br == 0 && f.bitrate > 0) {
                        br = f.bitrate
                    }
                }
            }
            // ★ 2026-10-04：「缓冲余量」是最关键的一项 —— 它**持续掉到 0~1s** ⇒ 生产端（网络）跟不上；
            //   一直有几秒 ⇒ 卡顿在解码/渲染那一侧（那时就该考虑降分辨率或查电视的图像处理/码率）。
            // ★ 2026-10-22：CMG 解密链路已删除 ⇒ 浮层里不再有"解密 xKB/s"（那个计数没有写入方，
            //   会恒显示 0 而误导判断）；判"生产端 vs 解码端"看缓冲余量即可。
            val buffered = ((p.bufferedPosition - p.currentPosition).coerceAtLeast(0) / 1000.0)
            dbgText = "诊断 · 取流 ${PlayStats.resolveMs}ms" +
                (if (br > 0) " · 码率 ${br / 1000}kbps" else " · 码率未知") +
                (if (wh.isEmpty()) "" else " · $wh") + audio +
                " · 缓冲 " + String.format("%.1f", buffered) + "s" +
                " · ${PalmPlayer.stateName(p.playbackState)}" + (if (p.isPlaying) "(播放中)" else "")
            delay(1000)
        }
    }

    // ★ 2026-10-04：节目单开关打一行日志（`logcat -s PalmTV:V` 里搜"节目单"）——
    //   排查"点了节目条没反应"时先看它：有这行 = VM 状态没问题（问题在渲染/焦点）；
    //   没这行 = 按键/点击根本没到 `openEpg()`（多半是焦点不在节目条上）。
    LaunchedEffect(ui.showEpg) {
        Log.i("[tv] 节目单" + (if (ui.showEpg) "打开：${ui.epg.size} 条" else "关闭"))
    }

    // ★★ 2026-10-04（用户实测："同一画面一闪一闪"）★★ 画面层用 `movableContentOf` 包起来：
    //   全屏 ⇄ 分栏 切换时，下面的 `AndroidView/PlayerView` 会被**移动**到新位置而**不重建**。
    //   否则每次进/出全屏都是"销毁旧 Surface + 重挂新 Surface" ⇒ 黑一下、并出现"同帧闪烁" ✗
    //   （配合"出画面后 8 秒无操作自动全屏"，进全屏那一下尤其明显）。
    //   ⚠️ 两个分支里只能调用**一处**（当前只会有一处生效 ✓）。
    //   ★★ 2026-10-05 修 bug（用户实测："'请选择频道开始观看'的提示一直存在"）★★
    //     根因就在这一行：原来写成 `remember { movableContentOf { m -> TvPlayerArea(vm, ui, m) } }` ——
    //     `remember` 只建一次 ⇒ 这个 lambda **捕获的是第一次组合时的 `ui`**（那时还没选台、`activeChannelId=""`）
    //     ⇒ 被"搬来搬去"的画面层里**永远看到初始状态** ⇒ 那句空态提示画上去就再也去不掉了 ✗✗
    //     （同理：`videoAr`/`arFix`/`videoNotice` 也跟着冻结，换台时的尺寸修正与浮层都会失效）。
    //     ⇒ 正确写法：**把会变的状态当参数传进去**（`movableContentOf` 支持带参数 —— 移动的是"节点身份/状态"，
    //       每次组合仍会用**当前**参数重新执行内容 ✓）。`vm` 是长生命周期单例，捕获它无妨 ✓。
    val playerContent = remember { movableContentOf { m: Modifier, s: UiState -> TvPlayerArea(vm, s, m) } }

    Box(
        Modifier
            .fillMaxSize()
            .background(Palette.Bg)
            // ★ 只截「遥控器专用键」：方向键 / OK 交给焦点系统处理，音量键**故意不拦**（留给电视）
            // ⚠️ 必须用 `onPreviewKeyEvent`（**在焦点子节点之前**跑）而不是 `onKeyEvent`：
            //    HUD 隐藏时要把"第一下方向键 / OK"拦成"唤出控制条 / 退出全屏"，若用 `onKeyEvent`，焦点还在按钮上 ⇒
            //    子节点先把 OK 吃掉（变成暂停/播放）⇒ 拦不住。
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                // 诊断浮层开关（遥控「菜单」键）—— 电视不能接 adb 时靠它把数字念给我们
                if (e.key == Key.Menu) {
                    dbg = !dbg
                    Log.i("[tv] 诊断浮层${if (dbg) "开" else "关"}")
                    return@onPreviewKeyEvent true
                }
                // ★ 2026-10-04：诊断浮层**开着**时，OK 键用来切"画质"（超清 1080p ⇄ 流畅 720p）。
                //   慢电视上"流畅优先"是最有效的一招：网络 / 解密 / 硬解码三处压力一起降。
                //   ⚠️ 只在浮层开着时接管 OK —— 平时 OK 仍是"播放/暂停"，行为完全不变。
                // ⚠️⚠️ 2026-10-04 真机实测结论：**上游根本不认 `defn=hd`** —— 切过去后每次取流都
                //   `get-live-info 无 playurl` ✗ ⇒ 这个"画质降档"开关**从 UI 上撤掉**（保留 `Config.defn`
                //   与 `vm.setVideoDefn` 以便将来真验证过再启用；启动强制 fhd + 失败自动回退仍在 ✓）。
                //   ⇒ 诊断浮层开着时，OK 键**不再改画质**（保持原来的"播放/暂停"语义）。
                // ★ 2026-10-04（用户实测："EPG 首次弹层不能按 OK 关闭"）：节目单打开时，
                //   **所有**按键都在这里处理，不再依赖弹层自己有没有拿到焦点：
                //     上下 = 滚动；OK/回车/空格/返回 = 关闭；频道±/媒体键 = 吃掉（看节目单别把台切了）。
                if (ui.showEpg) {
                    return@onPreviewKeyEvent when (e.key) {
                        Key.DirectionUp -> { uiScope.launch { epgScroll.scrollBy(-epgRowPx * 2f) }; true }
                        Key.DirectionDown -> { uiScope.launch { epgScroll.scrollBy(epgRowPx * 2f) }; true }
                        Key.DirectionCenter, Key.Enter, Key.Spacebar -> {
                            // ★ 2026-10-07：焦点在**已播完**的节目上 ⇒ OK 变成「回看」；否则仍是「关闭弹层」。
                            //   判据与列表里画"回看"小标**完全同一条**（start/end 都是 epoch 秒且已结束）。
                            val nowS = System.currentTimeMillis() / 1000
                            val pick = ui.epg.getOrNull(epgFocusIdx)
                            if (pick != null && pick.start > 0 && pick.end > 0 && pick.end < nowS) {
                                vm.playReplayFrom(pick.start)
                                true
                            } else {
                                vm.closeEpg()
                                true
                            }
                        }
                        Key.Back -> { vm.closeEpg(); true }
                        Key.ChannelUp, Key.ChannelDown,
                        Key.MediaPlayPause, Key.MediaPlay, Key.MediaPause -> true
                        else -> false
                    }
                }
                // ★ 2026-10-04：任何按键都算"用户还在操作" ⇒ 取消"自动全屏"（等下次**真正出画面**再重新计时）
                autoFsPending = false
                // ★★ 必须先判这一条（2026-10-04 实测踩到）★★ 全屏下 上/下 = 换台 ——
                //   若放在后面，HUD 隐藏时会被"第一下只唤出 HUD"那个分支**吃掉** ⇒ 换台无效 ✗。
                if (ui.fullscreen && (e.key == Key.DirectionUp || e.key == Key.DirectionDown)) {
                    pokeHud()
                    vm.switchChannelBy(if (e.key == Key.DirectionUp) -1 else 1)
                    Log.i("[tv] 全屏 上/下 换台：${if (e.key == Key.DirectionUp) "上一台" else "下一台"}")
                    return@onPreviewKeyEvent true
                }
                val wasHidden = ui.fullscreen && !hudVisible
                if (ui.fullscreen) pokeHud()      // 任意按键都重置"4 秒"计时（正在操作时不该消失）
                when {
                    // ① HUD 刚才是隐藏的：**方向键只唤出**（消费掉、不做动作）；**OK 直接退出全屏**
                    //    （2026-10-05 用户要求："全屏后按 OK 键直接退出全屏，减少操作"）；频道±/媒体键 = 明确动作 ⇒ 照常执行。
                    //    ⚠️ OK 只在"HUD 隐藏"时定义成"退全屏"：HUD 可见时焦点在按钮上，**必须**让 OK 能把按钮按下去
                    //      （否则"播放/暂停 · 静音"就永远点不到了 ✗）。日常场景正是"控制条已自动收起 ⇒ 按一下 OK 就退出全屏" ✓。
                    wasHidden -> when (e.key) {
                        // ★ 2026-10-22：全屏 + HUD 隐藏时，**左/右 = 时移 ±10 秒**（顺手唤出 HUD）
                        //   与触摸一致：左 = 后退（更早）、右 = 前进（更接近直播）。
                        Key.DirectionLeft -> {
                            vm.shiftBy(-10L); Log.i("[tv] 遥控 左 ⇒ 时移 -10s"); true
                        }
                        Key.DirectionRight -> {
                            vm.shiftBy(10L); Log.i("[tv] 遥控 右 ⇒ 时移 +10s"); true
                        }
                        Key.DirectionUp, Key.DirectionDown -> {
                            Log.i("[tv] 这一下方向键只用于唤出控制条: ${e.key}")
                            true
                        }
                        Key.DirectionCenter, Key.Enter, Key.Spacebar -> {
                            Log.i("[tv] 全屏下按 OK ⇒ 直接退出全屏（2026-10-05 用户要求）")
                            vm.toggleFullscreen()
                            true
                        }
                        Key.ChannelUp -> { vm.switchChannelBy(-1); true }
                        Key.ChannelDown -> { vm.switchChannelBy(1); true }
                        Key.MediaPlayPause, Key.MediaPlay, Key.MediaPause -> { vm.togglePlayPause(); true }
                        else -> false
                    }
                    // ② 常态：只截遥控器专用键，方向键/OK 交给焦点系统
                    else -> when (e.key) {
                        // ★ 2026-10-04（用户实测："遥控器上的频道按钮无效（华为手机遥控），全屏不能换台"）★★
                        //   手机遥控一般**没有** `频道±` 键，但一定有**方向键**和 ⏭/⏮。
                        //   ⇒ 全屏下 **上/下 = 上一台/下一台**（最常见也最好按，顺带唤出 HUD）；
                        //     非全屏时上/下仍然用于在网格/分组间移动（保持原样）。
                        Key.DirectionUp -> {
                            if (ui.fullscreen) { pokeHud(); vm.switchChannelBy(-1); true } else false
                        }
                        Key.DirectionDown -> {
                            if (ui.fullscreen) { pokeHud(); vm.switchChannelBy(1); true } else false
                        }
                        // ★ 2026-10-22：全屏下 **左/右 = 时移 ∓10 秒**（遥控没有触摸滑动，
                        //   这是唯一的时移入口；按住不放系统会连发 KeyDown ⇒ 连续 -10/-20/-30…）。
                        //   非全屏时左/右仍交给焦点系统（频道网格左右移动要用）。
                        Key.DirectionLeft -> {
                            if (ui.fullscreen) { pokeHud(); vm.shiftBy(-10L); true } else false
                        }
                        Key.DirectionRight -> {
                            if (ui.fullscreen) { pokeHud(); vm.shiftBy(10L); true } else false
                        }
                        Key.ChannelUp -> { vm.switchChannelBy(-1); true }
                        Key.ChannelDown -> { vm.switchChannelBy(1); true }
                        // ⏭ / ⏮（手机遥控、耳机按键上都有）也当"下一台 / 上一台"
                        Key.MediaNext -> { vm.switchChannelBy(1); true }
                        Key.MediaPrevious -> { vm.switchChannelBy(-1); true }
                        // ⚠️ 全屏下的 上/下 = 换台**已在上面单独处理**（必须先于"HUD 隐藏只唤出"那个分支）
                        Key.MediaPlayPause, Key.MediaPlay, Key.MediaPause -> { vm.togglePlayPause(); true }
                        else -> false
                    }
                }
            }
    ) {
        if (ui.fullscreen) {
            // ★★ 2026-10-04（用户实测："全屏不生效"）★★
            //   根因：TV 版原来**完全不看** `ui.fullscreen` —— 点"全屏"只是改了 VM 里的状态，
            //   界面布局没动 ⇒ 看着"没反应" ✗。现在按手机版同语义处理：
            //     全屏 = **画面铺满整屏**，控制行**浮在底部**（半透明底），状态行 / 节目条 / 频道列表全部让位；
            //     退出全屏（点"退出全屏"或按返回键）= 回到"左画面 + 右频道列表"分栏。
            //   ⚠️ TV 本来就恒横屏，所以这里**不需要**动方向（`MainActivity` 里那段改方向的逻辑对 TV 无害）。
            Box(Modifier.fillMaxSize()) {
                playerContent(Modifier.fillMaxSize(), ui)
                TvControlRow(
                    vm, ui,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        // ★ 4 秒自动隐藏（只改透明度：焦点与按键通路都不变，见上方注释）
                        .alpha(if (hudVisible) 1f else 0f)
                        .background(Color(0x88000000))
                        .padding(horizontal = 12.dp),
                    focusReq = barFocus      // 进全屏 ⇒ 焦点给控制行（HUD 上就靠它，见上方焦点策略）
                )
                // ★ 2026-10-04：诊断浮层（遥控「菜单」键开关）—— 全屏时贴在左上角
                if (dbg) {
                    Text(
                        dbgText, fontSize = 15.sp, color = Color(0xFF7FE07F),
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(12.dp)
                            .background(Color(0xCC000000), RoundedCornerShape(8.dp))
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                    )
                }
            }
        } else {
            Row(Modifier.fillMaxSize()) {
                Column(
                    Modifier.weight(0.68f).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    TvStatusBar(ui)
                    // ★ 2026-10-04：诊断浮层（遥控「菜单」键开关）—— 非全屏时贴在状态行下面
                    if (dbg) {
                        Text(
                            dbgText, fontSize = 14.sp, color = Color(0xFF7FE07F),
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.fillMaxWidth().background(Color(0xCC000000))
                                .padding(horizontal = 12.dp, vertical = 4.dp)
                        )
                    }
                    playerContent(Modifier.weight(1f).fillMaxWidth(), ui)
                    // ★ 2026-10-04：节目条**可聚焦** —— 遥控走到它上面按 OK 就是"看节目单"（右端有「节目单 ☰」提示）
                    TvEpgLine(ui) { vm.openEpg() }
                    TvControlRow(vm, ui, focusReq = barFocus)
                }
                Column(Modifier.weight(0.32f).fillMaxHeight().background(Palette.ChannelBg)) {
                    TvTabs(vm, ui)
                    if (ui.aboutTab) TvAboutScreen(ui) else TvChannelGrid(vm, ui, gridFocus)
                }
            }
        }

        // ★★ 2026-10-22（用户要求：TV 也要显示时移提示）★★
        //   原来这里注释说"TV 没触摸手势 ⇒ 不需要 gestureHint"，但遥控**左/右 = 时移 ±10 秒**
        //   也需要 OSD 反馈（`时移 -10 秒` / `直播`）。与手机版同款中央浮层，只是字号更大。
        if (ui.gestureHint.isNotEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    ui.gestureHint,
                    fontSize = 28.sp, color = Color.White,
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xCC000000))
                        .padding(horizontal = 28.dp, vertical = 14.dp)
                )
            }
        }

        // ★★ 2026-10-04（用户要求：TV 侧补 EPG 弹层）★★
        if (ui.showEpg) TvEpgModal(vm, ui, epgScroll, epgFocusIdx) { epgFocusIdx = it }

        if (ui.showDisclaimer) TvDisclaimer(vm, ui)
    }
}

// ======================================================================
// 通用：可聚焦容器（TV 上"焦点态"必须有视觉反馈）
// ======================================================================

/**
 * 遥控可操作的最小单元：`focusable()` + 焦点态描边/底色。
 * ⚠️ `clickable` **必须**保留 —— TV 上按 OK 键时，Compose 会把 DPAD_CENTER 映射成 click。
 */
@Composable
private fun TvFocusable(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(10.dp),
    onClick: () -> Unit,
    content: @Composable () -> Unit
) {
    var focused by remember { mutableStateOf(false) }
    Box(
        modifier
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clickable { onClick() }
            .clip(shape)
            .background(if (focused) Palette.TabTrack else Color.Transparent)
            .border(width = if (focused) 2.dp else 1.dp,
                color = if (focused) Palette.Primary else Palette.BorderIdle, shape = shape),
        contentAlignment = Alignment.Center
    ) { content() }
}

// ======================================================================
// 状态行 / 画面 / 节目条 / 控制行
// ======================================================================

@Composable
private fun TvStatusBar(ui: UiState) {
    val dot = when {
        ui.playErr -> Palette.OnAirRed
        ui.playing -> Palette.NextGreen
        else -> Palette.TextDim
    }
    Row(
        Modifier.fillMaxWidth().background(Palette.StatusBg).padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(12.dp))
        Text(ui.bootMsg, fontSize = 16.sp, color = Palette.TextMid, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text(ui.currentName, fontSize = 18.sp, fontWeight = FontWeight.Bold,
            color = Palette.TextBright, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** 播放画面（与手机版**同一套**：同一个 `vm.exoPlayer()`、同样的宽高比修正与居中算法，只是没有手势层）。 */
@Composable
private fun TvPlayerArea(vm: MainViewModel, ui: UiState, modifier: Modifier = Modifier) {
    val arFix = ui.videoArFix
    BoxWithConstraints(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        val ar = if (arFix > 0f) arFix else ui.videoAr.takeIf { it > 0.01f } ?: (16f / 9f)
        val videoBox = if (maxWidth / maxHeight > ar) {
            Modifier.fillMaxHeight().aspectRatio(ar, matchHeightConstraintsFirst = true)
        } else {
            Modifier.fillMaxWidth().aspectRatio(ar)
        }
        // ★ 2026-11-04：整块重建画面层（videoViewGen 变化 ⇒ 旧 PlayerView 销毁、新 Surface）
        key(ui.videoViewGen) {
        AndroidView(
            modifier = videoBox,
            factory = { c ->
                // ★★ 2026-10-05（真机实测："所有台都闪跳、缓冲却有 5~12 秒、官方 App 同台正常"）★★
                //   ⇒ 数据/电视都没问题，锅在**渲染方式**：
                //     ① 默认的 **SurfaceView** 在 Compose 里是"挖洞 + 单独合成"，与 Compose 那层不同步 ⇒
                //        部分电视 GPU 上表现为"同帧闪/跳" ✗ ⇒ 改用 **TextureView**（见 `res/layout/tv_player_view.xml`）；
                //     ② `update` 里**每次重组都重设 `player`/`resizeMode`** ⇒ `resizeMode` 会 requestLayout，
                //        画面就会一跳一跳 ✗ ⇒ 改成"只在真的变了才设"。
                @Suppress("InflateParams")
                val v = android.view.LayoutInflater.from(c)
                    .inflate(R.layout.tv_player_view, null) as PlayerView
                v.apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
                    )
                    // 换台/缓冲/重置时**保留最后一帧**，别闪一下黑（SurfaceView 时代这是黑屏闪的来源之一）
                    setKeepContentOnPlayerReset(true)
                    setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                    if (arFix > 0f) resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
                    player = vm.exoPlayer()
                    // ★ 2026-11-03：登记画面层 —— 回前台要显式重挂 Surface（修"秒回前台有声无画"）
                    vm.attachVideoView(this)
                }
                v
            },
            update = { v ->
                if (v.player !== vm.exoPlayer()) v.player = vm.exoPlayer()
                val want = if (arFix > 0f) AspectRatioFrameLayout.RESIZE_MODE_FILL
                else AspectRatioFrameLayout.RESIZE_MODE_FIT
                // ⚠️ 只在变化时设置：反复 setResizeMode 会 requestLayout ⇒ 画面"一跳一跳"（真机踩到）
                if (v.resizeMode != want) v.resizeMode = want
            }
        )
        }
        // ★★ 2026-10-05（用户实测："'请选择频道开始观看'一直存在"）★★
        //   根因是上一层 `movableContentOf` 捕获了初始 `ui`（已修，见那段注释）。这里再收紧判据：
        //   **只要已经在播（`ui.playing`）就绝不再显示空态提示** —— 双保险，避免"状态没同步上"时它赖着不走。
        if (ui.activeChannelId.isEmpty() && !ui.playing && ui.videoNotice.isEmpty()) {
            Text(Strings.PICK_CHANNEL, fontSize = 20.sp, color = Palette.TextDim)
        }
        if (ui.videoNotice.isNotEmpty()) {
            Text(
                ui.videoNotice, fontSize = 20.sp, color = Color(0xFFDDDDDD), textAlign = TextAlign.Center,
                modifier = Modifier
                    .background(Color(0xB0000000), RoundedCornerShape(12.dp))
                    .padding(horizontal = 28.dp, vertical = 18.dp)
            )
        }
    }
}

/**
 * 节目条（"正在播出 / 接下来"）。
 *
 * ★★ 2026-10-04（用户要求：TV 侧补 EPG 弹层）★★ 它现在**可聚焦**：遥控走到它上面按 OK ⇒ 打开节目单弹层
 * （右端固定显示 `Strings.EPG_BUTTON`「节目单 ☰」，与手机版同一个文案 ⇒ 用户一眼知道能按）。
 * ⚠️ 焦点态必须给底色 + 描边（TV 上"我在哪"全靠它）。
 */
@Composable
private fun TvEpgLine(ui: UiState, onOpen: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clickable { onOpen() }
            .clip(RoundedCornerShape(8.dp))
            .background(if (focused) Palette.TabTrack else Palette.EpgStripBg)
            .border(width = if (focused) 2.dp else 1.dp,
                color = if (focused) Palette.Primary else Color.Transparent,
                shape = RoundedCornerShape(8.dp))
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(Strings.EPG_NOW_TITLE, fontSize = 15.sp, color = Palette.NowRed)
        Spacer(Modifier.width(10.dp))
        Text(ui.epgNow, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text(Strings.EPG_NEXT_TITLE, fontSize = 15.sp, color = Palette.NextGreen)
        Spacer(Modifier.width(8.dp))
        Text(ui.epgNext, fontSize = 15.sp, color = Palette.TextDim, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(10.dp))
        Text(Strings.EPG_BUTTON, fontSize = 15.sp, fontWeight = FontWeight.Bold,
            color = if (focused) Color.White else Palette.Primary)
    }
}

/**
 * 控制行：TV 上全部用文本按钮（比图标更好认）。
 *
 * [modifier] 由调用方决定位置：非全屏时是分栏左列的普通一行；**全屏时是浮在画面底部的半透明条**。
 * [focusReq] 由外层（`TvHomeScreen` 的焦点策略）提供 —— 只有"该把焦点给控制行"的时机（关于页 / 进全屏）
 * 才会 `requestFocus()`；这里**不再自动抢焦点**（否则会和"把焦点放正在播的台"打架）。
 */
@Composable
private fun TvControlRow(
    vm: MainViewModel,
    ui: UiState,
    modifier: Modifier = Modifier,
    focusReq: FocusRequester? = null
) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        TvFocusable(
            modifier = Modifier
                .then(if (focusReq != null) Modifier.focusRequester(focusReq) else Modifier)
                .height(48.dp).padding(horizontal = 4.dp),
            onClick = { vm.togglePlayPause() }
        ) {
            Text(
                if (ui.playing) Strings.TV_PAUSE else Strings.TV_PLAY,
                fontSize = 18.sp, color = Palette.TextBright, modifier = Modifier.padding(horizontal = 20.dp)
            )
        }
        // ★★ 2026-10-04 用户拍板：**TV 版不做"应用内音量"** ★★
        //   用户原话："既然默认能通过遥控调节电视音量，我觉得就没有必要在 APP 中再调节了吧？符合 TV app 的惯例吧？"
        //   ⇒ 本轮曾短暂加过「音量− / 音量+」两个按钮（`vm.nudgeVolume`），**按用户要求撤掉**，
        //     控制行回到"播放/暂停 · 静音 · 全屏"三个按钮，与主流 TV 应用一致。
        //   ⚠️ **别再加回来**：音量归电视遥控/系统（音量键我们**故意不拦**）；我们只保留"静音"这一个
        //     应用内的独立开关（TV 应用普遍都有）。
        TvFocusable(
            modifier = Modifier.height(48.dp).padding(horizontal = 4.dp),
            onClick = { vm.toggleMute() }
        ) {
            Text(
                if (ui.muted) Strings.TV_UNMUTE else Strings.TV_MUTE,
                fontSize = 18.sp, color = Palette.TextBright, modifier = Modifier.padding(horizontal = 20.dp)
            )
        }
        TvFocusable(
            modifier = Modifier.height(48.dp).padding(horizontal = 4.dp),
            onClick = { vm.toggleFullscreen() }
        ) {
            Text(
                if (ui.fullscreen) Strings.TV_EXIT_FULLSCREEN else Strings.TV_FULLSCREEN,
                fontSize = 18.sp, color = Palette.TextBright, modifier = Modifier.padding(horizontal = 20.dp)
            )
        }
        Spacer(Modifier.weight(1f))
        Text(Strings.TV_KEY_HINT, fontSize = 13.sp, color = Palette.TextDim, maxLines = 2)
    }
}

// ======================================================================
// 右侧：分组 Tab + 频道网格
// ======================================================================

@Composable
private fun TvTabs(vm: MainViewModel, ui: UiState) {
    val labels = listOf(Strings.TAB_CCTV, Strings.TAB_SATELLITE, Strings.TAB_LOCAL, Strings.TAB_ABOUT)
    val selected = if (ui.aboutTab) 3 else when (ui.activeGroup) {
        Channel.Group.CCTV -> 0
        Channel.Group.SATELLITE -> 1
        Channel.Group.LOCAL -> 2
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        labels.forEachIndexed { i, t ->
            TvFocusable(
                modifier = Modifier.weight(1f).height(46.dp),
                shape = RoundedCornerShape(9.dp),
                onClick = {
                    when (i) {
                        0 -> vm.switchGroup(Channel.Group.CCTV)
                        1 -> vm.switchGroup(Channel.Group.SATELLITE)
                        2 -> vm.switchGroup(Channel.Group.LOCAL)
                        else -> vm.switchAbout()
                    }
                }
            ) {
                Text(
                    t, fontSize = if (i == selected) 18.sp else 17.sp,
                    fontWeight = if (i == selected) FontWeight.Bold else FontWeight.Normal,
                    color = if (i == selected) Color.White else Palette.UnselectedTabText
                )
            }
        }
    }
}

@Composable
private fun TvChannelGrid(vm: MainViewModel, ui: UiState, focusReq: FocusRequester) {
    val list = ui.channels.filter { it.group == ui.activeGroup }
    if (list.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(Strings.GROUP_EMPTY, fontSize = 16.sp, color = Color(0xFF666666))
        }
        return
    }
    // ★ 2026-10-04（用户要求："记住上次选中的台"）：焦点目标 = **正在播的那台**；它不在本分组 ⇒ 第一格。
    //   只有外层焦点策略会 `requestFocus()`（进界面 / 换分组 / 切 Tab 后），平时按方向键不受影响。
    val targetId = if (list.any { it.id == ui.activeChannelId }) ui.activeChannelId else list.first().id
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // 与手机版同一套"单元格宽 × 0.88"，只是 TV 列数固定 3（大屏更少的列、更大的卡片）
        val tile = ((maxWidth - 16.dp) / 3) * 0.88f
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            modifier = Modifier.fillMaxSize().padding(horizontal = 6.dp),
            contentPadding = PaddingValues(vertical = 4.dp)
        ) {
            items(list, key = { it.id }) { ch ->
                TvChannelTile(vm, ch, ui.activeChannelId == ch.id, tile,
                    focusReq = if (ch.id == targetId) focusReq else null)
            }
        }
    }
}

@Composable
private fun TvChannelTile(
    vm: MainViewModel,
    ch: Channel,
    onAir: Boolean,
    size: Dp,
    /** ★ 2026-10-04：只有"焦点目标"（正在播的那台 / 分组第一台）才挂这个请求器，见 `TvChannelGrid` */
    focusReq: FocusRequester? = null
) {
    val ctx = LocalContext.current
    val bmp by remember(ch.id) { mutableStateOf(Logos.load(ctx, ch)) }
    var focused by remember { mutableStateOf(false) }
    // ★★ 2026-10-04（用户要求："台标不要文字说明，只要图标"）★★
    //   原来在圆台标**下面**还写了一行频道名 ⇒ 已删除：TV 上"卡片 = 圆形台标 + 焦点描边"就够了，
    //   也与手机版 `MainScreen.ChannelTile` 一致（那边同样**只有圆、没有文字行**）。
    //   焦点态描边**直接画在圆上**（原来外面套了方角描边 + 底色块，去掉文字后那就是个空方框，很难看）。
    Box(
        Modifier
            // ⚠️ `focusRequester` 要排在 `focusable()` **之前**（Compose 的焦点请求器与可聚焦节点同一链上，且靠前）
            .then(if (focusReq != null) Modifier.focusRequester(focusReq) else Modifier)
            .padding(6.dp)
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .clickable { vm.playChannel(ch) }
            .size(size)
            .clip(CircleShape)
            .background(Color.White)
            .border(
                width = if (focused) 4.dp else 2.dp,
                color = when {
                    focused -> Palette.Primary
                    onAir -> Palette.OnAirRed
                    else -> Palette.BorderIdle
                },
                shape = CircleShape
            ),
        contentAlignment = Alignment.Center
    ) {
        val b = bmp
        if (b != null) {
            Image(bitmap = b.asImageBitmap(), contentDescription = ch.name,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().padding(size * 0.07f))
        } else {
            // 文字兜底（**只对"没有台标图"的频道**，例如自定义源）：完整频道名写进圆里 ——
            // 字号规则与手机/鸿蒙/桌面**同一套数**（见 MainScreen.ChannelTile 的注释）。
            val n = ch.name.length
            val lines = if (n <= 4) 1 else 2
            val per = if (n <= 4) maxOf(n, 1) else (n + 1) / 2
            val fs = minOf(0.85f / per, if (lines == 1) 0.30f else 0.22f) * size.value
            Text(ch.name, fontSize = fs.sp, color = Color(0xFF333333), fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center, maxLines = lines, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(size * 0.86f))
        }
    }
}

// ======================================================================
// 节目单弹层（TV 版，2026-10-04 补）
// ======================================================================

/**
 * ★★ 2026-10-04（用户要求：TV 侧补 EPG 弹层）★★
 *
 * 数据与手机版 `Overlays.EpgModal` **同一份**（`ui.epg` + "正在播"高亮 + 打开时自动滚到当前那一条），
 * 差别只在交互 —— **遥控优先**：
 *   · 面板整体可聚焦、打开即抢焦点 ⇒ 打开期间方向键不会再跑到后面的频道网格上；
 *   · `上下` = 滚动列表、`OK` = 关闭、`返回` = 关闭（根部 `BackHandler` 里已有 `ui.showEpg -> closeEpg()`）；
 *   · 根部的按键预览在 `ui.showEpg` 时**吃掉** `频道±`/媒体键 ⇒ 看节目单不会误把台切了。
 *
 * ⚠️ 每行高度固定 46dp、用 `verticalScroll` 而不是 `LazyColumn`：自动滚到"正在播出"可以直接用
 *   `序号 × 行高` 算偏移（TV 上不需要"行级焦点"，简单可靠、按键滚动也更好控）。
 */
@Composable
private fun TvEpgModal(
    vm: MainViewModel,
    ui: UiState,
    scroll: androidx.compose.foundation.ScrollState,
    /** ★ 2026-10-07：当前聚焦行（提到根部，见 `TvHomeScreen` 里 `epgFocusIdx` 的注释） */
    focusIdx: Int,
    onFocusIdx: (Int) -> Unit
) {
    val fr = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    val rowH = 46.dp
    val rowPx = with(LocalDensity.current) { rowH.roundToPx() }

    // ★★ 2026-10-04（用户实测："EPG 首次弹层没有定位焦点，不能按 OK 键关闭"）★★
    //   根因：`LaunchedEffect(Unit)` 可能在**布局完成之前**就执行 ⇒ `requestFocus()` 抛
    //   "FocusRequester is not initialized"（首次打开必现；第二次打开时尺寸已缓存反而"看着能用" ✗）。
    //   ⇒ 现在**先等一帧**再请求，并重试几帧兜底。
    //   ⚠️ 并且：即使焦点仍没落上，`OK / 返回 / 上下` 也照样能用 —— 它们已由根部按键预览统一处理
    //     （`TvHomeScreen` 的 `ui.showEpg` 分支）⇒ 弹层不再依赖焦点。
    LaunchedEffect(Unit) {
        repeat(6) {
            withFrameNanos { }
            if (runCatching { fr.requestFocus(); true }.getOrDefault(false)) return@LaunchedEffect
            delay(40)
        }
    }
    LaunchedEffect(ui.epg) {
        val idx = Epg.indexOfNow(ui.epg, System.currentTimeMillis() / 1000)
        if (idx > 0) {
            withFrameNanos { }                                        // 等列表布局完成（手机版是 delay 250ms）
            runCatching { scroll.scrollTo(idx * rowPx) }
        }
    }

    Box(
        Modifier.fillMaxSize().background(Color(0xC0000000)).clickable { vm.closeEpg() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                // ★ 2026-10-22（用户要求）：宽度回到 **62%** —— 对标 IPTV 机顶盒的回看菜单，
                //   只占屏幕一小块、不挡画面。之前显示差是因为**屏幕 dp 太小**，
                //   已由 `MainActivity` 的"TV 设计空间恒定 1280x720dp"统一解决（不再靠加宽硬撑）。
                .fillMaxWidth(0.62f).fillMaxHeight(0.84f)
                .clip(RoundedCornerShape(14.dp)).background(Palette.CardBg).padding(20.dp)
                .focusRequester(fr)
                .focusable()
                .onKeyEvent { e ->
                    if (e.type != KeyEventType.KeyDown) return@onKeyEvent false
                    when (e.key) {
                        Key.DirectionUp -> { scope.launch { scroll.scrollBy(-rowPx * 2f) }; true }
                        Key.DirectionDown -> { scope.launch { scroll.scrollBy(rowPx * 2f) }; true }
                        Key.DirectionCenter, Key.Enter, Key.Spacebar -> { vm.closeEpg(); true }
                        else -> false
                    }
                }
        ) {
            // ★ 2026-10-22：标题与提示**分成两行**。原来同一行里标题带 `weight(1f)`、提示不带约束，
            //   提示很长 ⇒ 标题只剩几十 dp ⇒ 被压成 "CCTV-/1 综合/· 节目/单" 四行（模拟器上就那样）。
            Text(
                Strings.epgTitle(ui.currentName),
                fontSize = 24.sp, color = Palette.TextBright, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.height(4.dp))
            Text(Strings.TV_EPG_HINT, fontSize = 15.sp, color = Palette.TextDim,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(10.dp))
            if (ui.epg.isEmpty()) {
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text(Strings.EPG_NONE, fontSize = 20.sp, color = Palette.TextDim)
                }
            } else {
                val now = System.currentTimeMillis() / 1000
                // ★ 2026-11-10：判据 = **当前是否在回看/时移**（与触摸版一起改成全局判断），
                //   跨天回看时正在直播的那档同样是绿字 + 文案「直播」。
                val hasReplay = ui.replayStart > 0L
                Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(scroll)) {
                    var lastYmd = ""
                    ui.epg.forEachIndexed { idx, it ->
                        val onAir = it.start > 0 && it.end > 0 && now in it.start until it.end
                        // ★ 2026-10-22：**必须叠加官方 protobuf 字段 [10]**（`it.replayable`）。
                        //   只判"已播完"会给"版权原因不可回看"的节目也画上「回看」⇒ 点了必然失败。
                        //   （与触摸版 `EpgModal` 用的是同一条判据，别只改一边。）
                        val replayable = it.start > 0 && it.end > 0 && it.end < now && it.replayable
                        // ★ 2026-10-22：正在回看的那档 / 正在直播的那档
                        val inReplay = ui.replayStart > 0L && it.start > 0 &&
                            ui.replayStart >= it.start - 5 && ui.replayStart < it.end
                        val liveSecondary = onAir && hasReplay
                        // ★ 2026-10-22：按天分组表头（TV 遥控不额外占按键，跟着滚动看即可）
                        if (it.ymd.isNotEmpty() && it.ymd != lastYmd) {
                            lastYmd = it.ymd
                            Text(
                                dayLabel(it.ymd),
                                fontSize = 17.sp, color = Palette.NextGreen,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)
                            )
                        }
                        Row(
                            Modifier.fillMaxWidth().height(rowH)
                                .then(
                                    if (replayable) {
                                        Modifier.onFocusChanged { if (it.isFocused) onFocusIdx(idx) }
                                            .clickable { vm.playReplayFrom(it.start) }
                                    } else Modifier
                                )
                                .background(
                                    if (replayable && focusIdx == idx) Palette.CardBg else Color.Transparent
                                ),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                "${Epg.hhmm(it, true)}-${Epg.hhmm(it, false)}", fontSize = 18.sp,
                                color = when {
                                    inReplay -> Color(0xFFFF7B7B)
                                    // ★ 2026-11-10：回看/时移时的直播那档 ⇒ 绿（与触摸版一致）
                                    liveSecondary -> Palette.NextGreen
                                    onAir -> Color(0xFFFF7B7B)
                                    else -> Palette.TextDim
                                },
                                modifier = Modifier.width(170.dp)
                            )
                            Text(
                                it.title, fontSize = 19.sp,
                                color = when {
                                    inReplay -> Palette.NowRed
                                    // ★ 2026-11-10：整行绿粗（不能只有状态标签变绿）
                                    liveSecondary -> Palette.NextGreen
                                    onAir -> Palette.NowRed
                                    else -> Palette.TextBright
                                },
                                fontWeight = if (inReplay || onAir)
                                    FontWeight.Bold else FontWeight.Normal,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            // 与触摸版一致：回看中（红粗）> 直播中 > 回看
                            when {
                                inReplay -> Text(Strings.EPG_IN_REPLAY, fontSize = 17.sp,
                                    color = Palette.NowRed, fontWeight = FontWeight.Bold)
                                onAir -> Text(
                                    if (liveSecondary) Strings.EPG_LIVE else Strings.EPG_LIVE_NOW,
                                    fontSize = 16.sp,
                                    color = if (liveSecondary) Palette.NextGreen else Palette.NowRed,
                                    fontWeight = FontWeight.Bold)
                                replayable -> Text(Strings.REPLAY, fontSize = 16.sp,
                                    color = Palette.Primary)
                                it.start > 0 && it.end > 0 && it.end < now && !it.replayable ->
                                    Text(Strings.EPG_NO_REPLAY_ITEM, fontSize = 14.sp,
                                        color = Palette.TextDim)
                            }
                        }
                    }
                }
            }
        }
    }
}

// ======================================================================
// 关于页（TV 版：**只读**，不含自定义源编辑）
// ======================================================================

@Composable
private fun TvAboutScreen(ui: UiState) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(Strings.ABOUT_TITLE, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright)
        // ★ 2026-10-05（用户要求）：**删掉**原来常显在关于页的运行诊断数字。
        //   现在要看诊断：按遥控「**菜单**」键 → 弹出诊断浮层（取流 ms / 解密 KB/s / 码率 / 缓冲 / 播放器状态），
        //   再按一次菜单键关闭。
        Text(Strings.aboutVersion(ui.appVersion), fontSize = 15.sp, color = Palette.TextDim)
        Text(Strings.ABOUT_EDITION_TV, fontSize = 15.sp, color = Palette.TextDim)
        Text(Strings.ABOUT_COPYRIGHT, fontSize = 15.sp, color = Palette.TextDim)

        Spacer(Modifier.height(4.dp))
        Text(Strings.SEC_TECH, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright)
        Text(Strings.TECH_1, fontSize = 14.sp, color = Palette.TextMid)
        Text(Strings.TECH_2, fontSize = 14.sp, color = Palette.TextMid)
        Text(Strings.TECH_3, fontSize = 14.sp, color = Palette.TextMid)
        // ★ 2026-10-04（用户决定：TV 版不做自定义源）⇒ 这里只留说明，编辑在手机/桌面版
        Text(Strings.TV_IPTV_NOTE, fontSize = 14.sp, color = Palette.TextMid)

        Spacer(Modifier.height(4.dp))
        Text(Strings.SEC_LEGAL, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright)
        Text(Strings.DISC_TEXT, fontSize = 13.sp, lineHeight = 20.sp, color = Palette.TextDim)

        Spacer(Modifier.height(4.dp))
        Text(Strings.SEC_CONTACT, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright)
        Text(Config.CONTACT_EMAIL, fontSize = 14.sp, color = Palette.LinkBlue)
    }
}

// ======================================================================
// 免责声明（首启 / 关于页"查看"）
// ======================================================================

@Composable
private fun TvDisclaimer(vm: MainViewModel, ui: UiState) {
    Box(
        Modifier.fillMaxSize().background(Color(0xE6000000)),
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier.fillMaxWidth(0.7f).fillMaxHeight(0.86f)
                .clip(RoundedCornerShape(14.dp)).background(Palette.DisclaimerBg).padding(24.dp)
        ) {
            Text(Strings.DISC_TITLE, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Palette.TextBright)
            Spacer(Modifier.height(8.dp))
            Text(
                Strings.DISC_TEXT, fontSize = 15.sp, lineHeight = 24.sp, color = Palette.TextMid,
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState())
            )
            Spacer(Modifier.height(8.dp))
            Text(
                if (ui.disclaimerReadOnly) Strings.DISC_AGREED_NOTE else Strings.DISC_FIRST_NOTE,
                fontSize = 13.sp, color = Palette.TextDim
            )
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Spacer(Modifier.weight(1f))
                if (!ui.disclaimerReadOnly) {
                    TvFocusable(
                        modifier = Modifier.height(46.dp),
                        onClick = { vm.dismissDisclaimer() }
                    ) {
                        Text(Strings.DISC_REFUSE, fontSize = 17.sp, color = Palette.TextMid,
                            modifier = Modifier.padding(horizontal = 22.dp))
                    }
                }
                TvFocusable(
                    modifier = Modifier.height(46.dp),
                    onClick = { if (ui.disclaimerReadOnly) vm.dismissDisclaimer() else vm.agreeDisclaimer() }
                ) {
                    Text(
                        if (ui.disclaimerReadOnly) Strings.CLOSE else Strings.DISC_AGREE,
                        fontSize = 17.sp, color = Color.White, modifier = Modifier.padding(horizontal = 22.dp)
                    )
                }
            }
        }
    }
}

/** yyyyMMdd ⇒ "今日 10/22" / "星期三 10/21"（TV 节目单的日期表头） */
private fun dayLabel(ymd: String): String {
    val d = runCatching { java.time.LocalDate.parse(ymd, java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd")) }
        .getOrNull() ?: return ymd
    val week = when (d.dayOfWeek.value) {
        1 -> "星期一"; 2 -> "星期二"; 3 -> "星期三"; 4 -> "星期四"
        5 -> "星期五"; 6 -> "星期六"; else -> "星期日"
    }
    val today = java.time.LocalDate.now()
    val head = if (d == today) "今日" else week
    return "$head ${d.monthValue}/${d.dayOfMonth}"
}
