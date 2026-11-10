package com.rickyone.palmtv.player

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.YspAndroidCKey
import com.rickyone.palmtv.data.JiangsuTv
import com.rickyone.palmtv.data.Log

/**
 * 播放器封装（**只有 Media3，不做第二套兜底**）。
 *
 * 与鸿蒙的对应关系：
 *   AVPlayer + Surface            →  ExoPlayer(+ PlayerView 的 SurfaceView/TextureView)
 *   端上取流                       →  `DefaultHttpDataSource`（**明文直连 CDN**，不再有解密层）
 *   `#EXT-X-KEY` 等由播放器自理     →  ExoPlayer 原生处理（我们的链路里已无自定义 DataSource）
 *
 * ★ 关键参数（照抄鸿蒙 `PlaybackStrategy` 的意图：**低延迟起播 + 首帧即出**）：
 *   · `setLiveConfiguration`：手机 = 目标落后直播沿 6s、追播 0.97~1.03×；**TV = 落后 10s、不追播**（见
 *     [relaxedLive]，2026-10-04 用户实测电视端"画面卡跳"后新增）；
 *   · 直播追边沿（不 pauseAtEndOfMediaItems）；
 *   · 音量走播放器内音量（`player.volume`），与鸿蒙 `AVPlayer.setVolume` 同口径。
 */
class PalmPlayer(context: Context) {

    /** 只用于读台标字节（媒体播控卡片的封面）—— 必须 applicationContext，不能持有 Activity。 */
    private val appContext: Context = context.applicationContext

    /**
     * ★★★ 2026-10-27：**按频道分流**（三端同步策略）★★★
     *
     *  · 8 个 ChinaDRM(SM4-CBC) 加密台（`Channel.needsCmg`）⇒ `plainChannel=false` ⇒ 走 CMG 解密；
     *  · 其余频道（移动端链路 + 自研 cKey 的明文流）⇒ `plainChannel=true` ⇒ 原样透传。
     *
     * ★★★ 2026-11-04：**配置改成"起播快照"** ★★★
     *   原来换台是直接改这个工厂的 `headers/pid/plainChannel/replayMode` 字段。
     *   缺陷：换台那一瞬间，**旧 MediaSource 的 DataSource 可能还在 open()（下载最后一片）**，
     *   它读到的是新台的配置 ⇒ 旧片被按新台的解密策略处理（偶发报错/花屏），新片的头也可能不对。
     *   用户实测症状：**点了新台却还在放旧台，要再点一次才跳过去**（换台也明显变慢）。
     *   ⇒ 现在 `Factory.update()` 只是原子替换一份**不可变快照**，`createDataSource()` 把当时的
     *     快照交给 DataSource（4 个配置参数都是 val）⇒ 已建好的一律用旧快照，不存在竞态。
     *     真正要跨台共享的（分片缓存 / 预取 / 按 pid 的明文判据）都下沉到了 `CmgShared`。
     *
     * ⚠️ 2026-10-22 一度删掉 CMG、换成 `PlainHlsDataSourceFactory`（只剔 `#EXT-X-KEY` 不解密）
     *   ⇒ 那 8 个台就变成**绿屏但不报错**（能播、画面是乱码），排查了很久。别再走这条路。
     *
     * 与"MediaSource 复用"的关系（2026-11-04 澄清，别再做无用功）：
     *   HLS 的 `MediaSource` 持有一次性 Timeline，**换台必然新建**，不存在复用的可能；
     *   真正可复用的只有播放器实例（`PlayerHolder`）、解码器（换台不 `stop()` 即可）、
     *   以及这里的 DataSource 层缓存（已下沉到 `CmgShared` 单例）。
     */
    private val factory = CmgDataSource.Factory()

    /* ★★ 2026-10-02（用户实测："安卓版安装后音频独占了，其他视频都没声音了"）★★
     *   原来是 `handleAudioFocus = **true**` ⇒ ExoPlayer 会向 AudioManager 申请
     *   **AUDIOFOCUS_GAIN（独占）** ⇒ 正在播放的其它应用会被系统暂停/静音 ✗✗（就是这个现象）。
     *   ⇒ 改成 **false**：**完全不申请音频焦点** = 与其它应用**混音共存** ✓。
     *   ⚠️ 这是**照鸿蒙端口径**改的，鸿蒙那边两处都写死了"不独占"：
     *     · `Index.setupPlayer`：`p.audioInterruptMode = audio.InterruptMode.SHARE_MODE`
     *       （注释：\"SHARE_MODE（默认值，不独占）—— 合规要求：不打断其它应用的音频\"）；
     *     · `common/AudioFocus.ets`：策略恒为 `CONCURRENCY_MIX_WITH_OTHERS`，并引用了**官方审核口径**——
     *       \"无论静音还是有声播放，都必须使用 MIX(share) 策略、与其他应用音频混合播放；
     *         **绝不使用 PAUSE/STOP 独占策略**打断其他音频\"。
     *   ⚠️ 代价（知悉并接受，正是"混音共存"的语义）：别家抢焦点时系统**不会**自动暂停我们；
     *      真要"被来电/别家打断就暂停"，得自己监听（安卓侧没 hold 焦点就拿不到回调，故不实现）。
     *      `setHandleAudioBecomingNoisy(true)` **保留** —— 拔耳机自动暂停，与焦点无关 ✓。
     *   ⚠️ **别再改回 true**：那是独占，等于打断别人，与三端口径相悖。 */
    /* ★★ 2026-10-05（用户实测："所有台声音都延后约 0.3~0.5 秒"，诊断浮层显示**本机解码**）★★
     *   已排除（都在代码里核过，别再走回头路 ✗）：
     *     · 全进程**只有一个** ExoPlayer（`PlayerHolder`：界面与播控服务共用）⇒ 不是"两份声音错位"；
     *     · 一个分片里音视频**在同一条时间轴、整片一起解密** ⇒ 我方链路里没有"把音频单独拖后"的环节；
     *     · 诊断显示**本机解码**（不是 AC-3 直通）⇒ 也排除"直通延迟不上报"这一大类。
     *   ⇒ 曾想做的实验 ——"把 AudioTrack 缓冲区压小"（若误差来自'系统上报的音频位置偏乐观'，它会随之变小）——
     *     **做不了**：这版 Media3 **没有暴露注入自定义音频出口的口子** ✗：
     *       `ExoPlayer.Builder.setAudioSink` **不存在**、`DefaultRenderersFactory.setAudioSink` **也不存在**
     *       （两次编译期实测）；`AudioTrackBufferSizeProvider` 还是 **`DefaultAudioSink` 的嵌套类型** ✗。
     *     真要走到那一步，得**重写 `DefaultRenderersFactory.buildAudioRenderers(...)`** 自行 new
     *     `MediaCodecAudioRenderer` 来塞我们的 sink（可行但动播放器构造 ⇒ 先等"是不是我们的锅"判出来再动 ✗）。
     *   ⇒ 现阶段只做**判定**：① 其它 Android App（爱奇艺 / 央视频官方）在这台电视上同步吗？
     *     ② 同一个包放**手机**上（耳机听）同步吗？③ 关电视音效 / 电视里的"音画同步·音频延迟"设置。
     */
    /**
     * ★ 2026-11-01 解码器 A/B 开关（**不写文件时行为完全不变**）。
     *
     * 背景：解密产物已被证明与官方 App 的解码器入参**逐字节一致**
     * （262 条配对、尾巴 0 条不一致，见 `docs/ysp-ckey/ref/drm/HANDOFF.md` §3），
     * 所以"偶发斑块"只可能出在**解码/渲染路径**上。这里用 `cache/codec` 文件强制指定解码器做对照：
     *    · 空 / 不存在 ⇒ 走 ExoPlayer 默认（现状）
     *    · 写 `c2.android.avc` ⇒ 强制 Codec2 软解
     *    · 写 `OMX.google` ⇒ 强制老 OMX 软解
     */
    private val forcedCodec: String = try {
        java.io.File("/data/data/com.rickyone.palmtv/cache/codec").readText().trim()
    } catch (_: Throwable) {
        ""
    }

    private val renderersFactory: androidx.media3.exoplayer.DefaultRenderersFactory =
        androidx.media3.exoplayer.DefaultRenderersFactory(context).apply {
            if (forcedCodec.isNotEmpty()) {
                setMediaCodecSelector { mimeType, secure, tunneling ->
                    val all = androidx.media3.exoplayer.mediacodec.MediaCodecSelector.DEFAULT
                        .getDecoderInfos(mimeType, secure, tunneling)
                    val hit = all.filter { it.name.contains(forcedCodec, ignoreCase = true) }
                    Log.i(
                        "[player] 解码器A/B 强制=$forcedCodec 命中=${hit.map { it.name }}" +
                            " 可选=${all.map { it.name }}"
                    )
                    hit
                }
            }
        }

    /* ★★★ 2026-11-04：「运行中动态下调直播偏移」功能**已整体移除**，别再复活 ★★★
     *   · 曾用 `ExoPlayer.Builder.setLivePlaybackSpeedControl(...)` +
     *     `DefaultLivePlaybackSpeedControl.setTargetLiveOffsetOverrideUs(...)` 实现"窗口变化时跟随调整"
     *     （API 确实存在，已核对 media3-exoplayer-1.11.1.aar，不是记忆猜测）；
     *   · 但实测**反而更差**：
     *       双向跟随：浙江卫视缓冲 4 次 → **9 次**（offset 一路涨到 14s，而直播位置无法后退）；
     *       改成"只向下"：offset 被从 8.4s 压到 6.8s ⇒ 库存更薄 ⇒ 体感不如 `858d30c`。
     *   ⇒ 结论：**offset 宁大勿小、一次算准**比运行中反复调更稳。 */

    val player: ExoPlayer = ExoPlayer.Builder(context, renderersFactory)
        /* ★★★★★ 2026-10-21（用户实测"卡顿/不流畅"）★★★★★
         * 加大缓冲：直播分片 1.7~3.5 MB，默认缓冲（50s 上限、2.5s 起播）在网络抖动时会直接见底。
         *   min 15s / max 60s：允许囤 3~5 个分片；
         *   bufferForPlayback 2.5s（起播快）；
         *   afterRebuffer 5s（卡过一次后多囤一点，避免"卡一下—再卡一下"）。 */
        .setLoadControl(
            androidx.media3.exoplayer.DefaultLoadControl.Builder()
                /* ★ 2026-10-31（第二次修正）：min 15s → **8s**、max 60s → **24s**
                 *   原因：CCTV-4K 直播窗口只有 ~15s（3 片 × 5s），15s 下限**永远攒不满**
                 *   ⇒ 一直判"缓冲不足" ⇒ 周期性停顿 + `videoSize=0x0` 反复重建 ⇒ 幻灯片/闪屏。
                 *   ⚠️ 这两个数曾被一次改动回退成 15s/60s，导致 4K 复发；改这行前先想清楚窗口长度。
                 *
                 * ★★ 2026-11-03（用户反馈"这 8 个台缓冲频率高、尤其 4K，尽量少缓冲"）★★
                 *   **关键关系：窗口只有 15s（3 片 × 5s），"落后直播沿 X 秒" 就等于"前方最多还能囤 (15−X) 秒"。**
                 *   原来偏移 12s（TV 15s）⇒ 前方只剩 0~3s ⇒ 码率稍一抖动就见底 ⇒ 反复重缓冲。
                 *   现在：偏移 5s（4K 4s / TV 8s）+ 下限 6s、上限 15s（= 整个窗口，再大没意义）：
                 *     · 前方可用 10s（4K 11s），min 6s 能满足 ⇒ 不会"永远攒不满"；
                 *     · 起播 1.5s / 重缓冲后 2.5s ⇒ 起播更快、卡过一次也能更快恢复。
                 *   ⚠️ 改这里必须同时看 `liveConfig*` 的 `targetOffsetMs`：**min 必须 ≤ 偏移**。
                 * ★ 2026-11-03：5/15/1.5/2.5 试过 ⇒ 4K 变幻灯片，**回退原值 8/24/2.5/4**。
                 *   结论：这套数是 2026-10-31 用真机逐项调出来的，没有量化日志前**不要再动**。 */
                /* ★ 2026-11-04 单变量实验已回退：min **5000 → 8000**（原值）。
                 *   假设是"4K 窗口收缩到 13.7s 时 min=8s 占窗口 58% ⇒ 永远缓冲"，
                 *   实测 130 秒仍然是 **4 次**，与 min=8000 完全一致 ⇒ 假设不成立，
                 *   **缓冲次数不随 minBuffer 变化**，是源端窗口收缩的物理结果。
                 *
                 * ★ 2026-11-04 第二个实验（**已回退**）：afterRebuffer 4000 → 1500。
                 *   目标不是减少次数，而是缩短每次卡顿时长。实测反而更差：
                 *     4000 ⇒ 3 次 / 共 5.6s / 最长 4.4s / 占 **4.3%**
                 *     1500 ⇒ 5 次 / 共 8.4s / 最长 3.3s / 占 **6.5%**
                 *   原因：恢复得太快 ⇒ 立刻又卡 ⇒ 次数上升，总时长反而更长。
                 *   ⇒ **这组数确实是调出来的，别动**（原注释的警告是对的）。 */
                .setBufferDurationsMs(8_000, 24_000, 2_500, 4_000)
                .build()
        )
        // ★ 2026-11-04：全局唯一工厂，但**配置是快照式的**（见 play() 与 `Factory.update` 的注释）。
        //   这里必须挂我们自己的工厂，否则会走 Media3 默认工厂 ⇒ 绕过清单清洗/解密（403 或绿屏）。
        .setMediaSourceFactory(DefaultMediaSourceFactory(context).setDataSourceFactory(factory))
        /* ★★ 2026-10-05（用户实测："所有台声音恒定延后 0.3~0.5s；**手机端不延后**；其它 TV App 也正常"）★★
         *   数据把范围钉在"**TV 独有的那条路径**"上（手机同一份播放代码 ✓ ⇒ 片源/解码/取流都无罪）。
         *   本次采纳建议的第一条（成本最低）：**关掉"播放器请求电视切刷新率"**。
         *   原因：Media3 默认会在视频帧率与显示刷新率不一致时调用 `Surface.setFrameRate()`
         *   （我们的流多是 25/50fps 而电视面板 60Hz ⇒ 一定会去请求切模式）⇒ 部分电视切完模式后
         *   **整条图像管线会多出一层处理**（画质增强/MEMC/去隔行的重配置），既有额外画面延迟、也可能
         *   让播放器与电视的时序对不上 ⇒ 恒定偏差。
         *   ⚠️ 判据：**延后变小/消失** ⇒ 命中，保留；**毫无变化** ⇒ 删掉这一行即可回退（其它一行不动）。
         *   ⚠️ 代价：不再"跟着片源帧率切刷新率" ⇒ 25fps 内容在 60Hz 上理论上可能极轻微抖动（多数电视无感）。*/
        /* ★★★ 2026-11-04 对照实验（用户选 B）：**打开帧率匹配请求** ★★★
         *   原来是 `VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF`（2026-10-05 为修"所有台声音延后
         *   0.3~0.5 秒"关掉的）。关掉的副作用：25fps 内容在 60Hz 屏上**不向系统请求切刷新率**，
         *   排帧完全交给 Media3 的 `VideoFrameReleaseHelper`（3:2 pulldown 式：一帧 2 vsync、
         *   下一帧 3 vsync）⇒ 观感上是"轻微一顿一顿"，正是用户说的"幻灯片"。
         *   ⇒ 本次改成 ON 做对照，判据两条：
         *     · 画面是否变顺（尤其运动镜头）；
         *     · **声音是否又开始延后 0.3~0.5 秒**（若延后 ⇒ 两个问题同源，改回 OFF 并把这条结论记下）。 */
        /* ⚠️ 这里**故意不调用** `setVideoChangeFrameRateStrategy(...)` ⇒ 用 Media3 默认 = **允许**
         * 向系统请求切换刷新率（帧率匹配）。做对照用，改回 OFF 只需恢复上面那两行调用。 */
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            /* handleAudioFocus = */ false
        )
        .setHandleAudioBecomingNoisy(true)
        .build()

    /**
     * ★ 2026-11-03：**已渲染出画面的次数**（每次 prepare 后第一帧 +1）。
     *   用途：回前台后"有声音但没画面"的判定 —— 1.8s 后计数没涨且 `isPlaying` ⇒ 重挂 Surface
     *   （见 `MainViewModel.onForeground`）。故意不写在 `MainViewModel` 里：那边拿不到这个回调。
     */
    @Volatile
    var renderedFrameCount: Long = 0L
        private set

    /**
     * ★ 2026-11-04：**真正渲染出来的帧数**（每渲染一帧 +1，取自解码器计数器）。
     *   用于“有声无画”判定：它在正常播放时**持续增长**；
     *   而 
enderedFrameCount（首帧回调）只在 prepare/seek 后 +1 —— 用错会误判。
     */
    val renderedOutputFrames: Long
        get() = try {
            (player.videoDecoderCounters?.renderedOutputBufferCount ?: 0).toLong()
        } catch (_: Throwable) {
            0L
        }


    init {
        /* ★ 2026-10-23 诊断：绿屏到底是"没渲染出帧"还是"渲染了但像素是绿的" —— 用播放器回调区分。
         *   · 出现 `首帧已渲染` + 之后 `丢帧` 不涨 ⇒ 像素问题（码流/解码器输出异常）；
         *   · **没有** `首帧已渲染` ⇒ 一帧都没出（与 Surface 未初始化的"绿"同源）。 */
        player.addAnalyticsListener(object : androidx.media3.exoplayer.analytics.AnalyticsListener {
            override fun onRenderedFirstFrame(
                eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,
                surface: Any,
                renderTimeMs: Long
            ) {
                renderedFrameCount++
                Log.i("[player] 首帧已渲染（surface=${surface.javaClass.simpleName} renderTime=$renderTimeMs）")
            }

            override fun onVideoDecoderInitialized(
                eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long
            ) {
                Log.i("[player] 视频解码器: $decoderName（初始化 ${initializationDurationMs}ms）")
            }

            override fun onDroppedVideoFrames(
                eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,
                droppedFrames: Int,
                elapsedMs: Long
            ) {
                Log.w("[player] 丢帧累计=$droppedFrames")
            }

        })
    }

    /**
     * ★ 2026-10-23 诊断：当前**视频轨道的真实格式**（mime / codecs 串 / 分辨率 / 色彩信息 / csd 段数）。
     * 用途：区分"解码器不支持该 profile（10-bit / 4:2:2 / 非 avc）"与"码流本身有问题"——
     * 现象是"有声、绿屏、但 videoSize 正常"，光看 videoSize 判不出来。
     */
    fun videoTrackInfo(): String {
        val tracks = player.currentTracks
        for (g in tracks.groups) {
            if (g.type != C.TRACK_TYPE_VIDEO || g.length == 0) continue
            val f = g.getTrackFormat(0)
            return "${f.sampleMimeType} codecs=${f.codecs} ${f.width}x${f.height}" +
                " color=${f.colorInfo} csd=${f.initializationData.size}"
        }
        return "（无视频轨）"
    }

    /** 直播参数（手机用）。
     *  ★ 2026-10-21（用户实测"卡顿"）：落后 **12s**（原 6s）、追播 **0.98~1.02×**（原 0.97~1.03×）。
     *  依据：我们的直播分片 1.7~3.5 MB，6 秒余量在一次抖动里就吃光；12 秒 ≈ 2 个分片余量，
     *  且追播更温和（不会为了贴边沿把缓冲再吃掉）。代价：比直播晚约 12 秒。 */
    private val liveConfig: androidx.media3.common.MediaItem.LiveConfiguration =
        androidx.media3.common.MediaItem.LiveConfiguration.Builder()
            // ★ 2026-11-03：试过 5s/8s，用户体感无改善且 4K 直接退化 ⇒ **回退到 12s**（原值）。
            //   语义记录（别再改错方向）：`targetOffsetMs` = 播放位置离"直播沿"多远，
            //   **它同时就是"前向可用缓冲时长"**：太大身后余量不足会掉出窗口，太小则贴着边沿播 ⇒ 幻灯片。
            //   15s 窗口下 12s 是"缓冲最厚且仍留 3s 身后余量"的临界值，别轻易动。
            .setTargetOffsetMs(12_000)
            .setMinPlaybackSpeed(0.98f)
            .setMaxPlaybackSpeed(1.02f)
            .build()

    /**
     * ★★ 2026-10-04（用户实测：电视端"取流换台超慢、画面卡跳严重，基本没法看"）★★
     * **TV / 慢设备的"稳"参数**：目标落后直播沿 **10s**、**完全不追播**（1.0×）。
     *
     * 为什么要分开：手机那套是"贴直播边沿"的思路（落后 6s、落后就 1.03× 猛追）——
     *   在电视这种"解码/解密/渲染本来就吃紧"的设备上，**追播会把仅剩的余量也吃光**，
     *   表现为"越看越卡、时不时顿一下"。落后多一点、不追播 ⇒ 缓冲余量更大、画面稳，
     *   代价只是比直播晚几秒（看电视完全可以接受）。
     * ⚠️ 由 `MainViewModel.setTvPlaybackMode()`（`MainActivity` 按 `isTv` 调用）设置；**下一次 `play()` 生效**。
     */
    @Volatile
    var relaxedLive: Boolean = false

    /**
     * ★★★★★ 2026-10-30：**直播窗口很窄的台**要用更小的追边沿延迟 ★★★★★
     *
     * 实测 CCTV-4K 直播：清单只有 **3 个分片 × 5 秒 = 15 秒窗口**（`TARGETDURATION:5`），
     * 而手机端默认落后直播沿 **12 秒** ⇒ 只剩 3 秒余量，播放器不断撞边沿/掉出窗口，
     * 表现为 **`videoSize=0x0` ↔ `1920x1080` 反复重建**（每次重建 = 黑闪 + 停顿 = "幻灯片"）。
     *
     * 对照：CCTV-16+ 也是 4K 但窗口更宽，所以它正常 —— 印证"窗口长度"才是关键，不是分辨率。
     */
    private val SHORT_WINDOW_PIDS = setOf(
        "600002264",   // CCTV-4K 超高清（3×5s 窗口）
    )

    /**
     * 窄窗口用。
     *
     * ★ 2026-10-31（第二次修正，关键关系）：**"落后直播沿 X 秒" 约等于"前方可用缓冲 X 秒"**。
     *   所以必须满足 `X ≥ 缓冲下限(min)`，否则**永远判缓冲不足** ⇒ 周期性停顿 + 黑闪
     *   （表现就是"幻灯片 + 闪屏"，但画面仍在缓慢推进 —— 实测 1.5s 像素差 4.17）。
     *   · 4K 窗口 = 3 片 × 5s = 15s；
     *   · 取 X = **9s**、min = **8s**（9 ≥ 8 满足），且 15 − 9 = 6s 余量，不会掉出窗口。
     *   ⚠️ 曾经取过 12s（配 min 15s ⇒ 12 < 15，必卡）和 4s（配 min 8s ⇒ 4 < 8，必卡），都错。
     */
    private val liveConfigNarrow: androidx.media3.common.MediaItem.LiveConfiguration =
        androidx.media3.common.MediaItem.LiveConfiguration.Builder()
            // ★ 2026-11-03：**6s 试过，4K 立刻退化成幻灯片 ⇒ 回退到 9s**（这个值是 2026-10-31 用真机调出来的）。
            //   原因：4K 单分片 ~3 MB、下载慢 ⇒ 偏移压得太小就等于"贴着直播边沿播"，
            //   每 5 秒都要等新分片 ⇒ 一帧一帧往前挪（幻灯片）。4K 要的就是"离边沿远一点"。
            .setTargetOffsetMs(9_000)
            .setMinPlaybackSpeed(0.98f)
            .setMaxPlaybackSpeed(1.02f)
            .build()

    /**
     * ★★★ 2026-11-03（回看"每 19 秒卡一次"的根因）★★★
     *
     * 回看/时移走的是**时移型清单**（`LiveTimeShift`）：服务端给的是**滚动窗口**（约 3 个分片 ≈ 18s），
     * 且窗口随时间前移。如果我们从 `playbacktime` 那个**最老的边界**起播，窗口一滑就会把我们正在播的
     * 那一段丢掉 ⇒ 抛 `BehindLiveWindowException`（实测正好每 19 秒一次）。
     * ⇒ 回看也要挂 LiveConfiguration，但偏移取**一个分片内**（6s）：
     *   · 太靠近窗口末端（以前试过 12s/15s）⇒ 起播直接跳到"节目末尾"附近，等于跳过内容；
     *   · 贴着窗口最老端（不挂配置）⇒ 每 18 秒掉窗一次。
     * 6s 的结果：跳过节目开头约 6 秒，之后按 1× 连续播、不再掉窗。
     */
    /**
     * ★★★★★ 2026-11-03：**按"清单真实窗口"自适应直播偏移**（取代写死的 per-pid 常量）★★★★★
     *
     * 依据（全部实测，见 HANDOFF）：
     *   · 4K 直播窗口 = 3 片 × 8.16s ≈ 24s；
     *   · 8K 直播窗口 ≈ 6~10s（3 片 × 2s）；
     *   · 回看窗口 = 5 片 × 2s = 10s。
     * 写死 12s/9s/15s 的结果就是：窗口小的台贴边（缓冲吃干 ⇒ 幻灯片/掉窗），窗口大的台白等。
     *
     * 规则：`offset = min(1.5×分片, 窗口 − 半片)`，再夹到 [2s, 0.8×窗口]。
     *       拿不到窗口信息时退回各模式的默认值（回看 6s / TV 10s / 手机 8s）。
     */
    private fun liveConfigDynamic(isReplay: Boolean, ch: Channel): androidx.media3.common.MediaItem.LiveConfiguration {
        val win = PlaylistWindow.windowMs(ch.pid)
        val seg = PlaylistWindow.segMs(ch.pid)
        val offset = calcOffsetMs(win, seg, isReplay)
        /* ★ 2026-11-04（用户要求撤销降速实验）：保持 0.98/1.02 的原值。
         *   降速（0.90）实测只把 4K 的缓冲中从 1.7% 压到 1.1%，代价是全程轻微变速，
         *   用户不接受 ⇒ 已撤销。
         *   ⚠️ 也曾给窄窗口加过"只加速不减速"（上限 1.05），这次与「动态偏移」一起回退了 ——
         *      本轮只保留 `858d30c` 的原样行为，一次只验证一个变量。 */
        val speedLo = if (relaxedLive) 1.0f else 0.98f
        val speedHi = if (relaxedLive) 1.0f else 1.02f
        return androidx.media3.common.MediaItem.LiveConfiguration.Builder()
            .setTargetOffsetMs(offset)
            .setMinPlaybackSpeed(speedLo)
            .setMaxPlaybackSpeed(speedHi)
            .build()
    }

    /**
     * ★★★★★ 2026-11-04：**目标偏移的唯一计算入口** ★★★★★
     *
     * ⚠️⚠️ 这里的系数/上限**已回退到 `858d30c`（用户实测"缓冲还好"的那一版）**，别再改：
     *   · 系数 **1.5 片**
     *   · 上限 **`窗口 − 1 片`**
     *   · 再夹到 `[2s, 0.8×窗口]`
     *
     * 为什么回退（这一轮踩的坑，记下来别再走）：
     *   我先后改成"2 片"、「窗口 − 半片」、「按平均分片登记窗口」、又加了"运行中动态下调偏移"，
     *   每一项单看都有道理，但它们**全都在把 offset 调小**：
     *     · 平均 5.6s vs 最大 6.64s ⇒ offset 8.4s vs 9.96s（浙江卫视）；
     *     · 动态下调再把它压到 7.5 → 6.8s。
     *   而 3 片窗口本来只有约 1.5 片可用库存 ⇒ **少 1.5 秒 = 少 25% 库存** ⇒ 缓冲明显变多。
     *   ⇒ 原则：**offset 宁大勿小**；掉窗风险由 `cap = 窗口 − 1 片` 兜住（它同时也随取大而变大）。
     */
    private fun calcOffsetMs(win: Long, seg: Long, isReplay: Boolean): Long {
        val fallback = when {
            isReplay -> 6_000L
            relaxedLive -> 10_000L
            else -> 8_000L
        }
        // 拿不到窗口 / 窗口不足 2 片（单片的时移窗口）⇒ 用兜底值
        if (win <= 0 || seg <= 0 || win < seg * 2) return fallback
        val cap = (win - seg).coerceAtLeast(2_000L)
        return minOf(seg * 3 / 2, cap).coerceIn(2_000L, win * 8 / 10)
    }

    private val liveConfigReplay: androidx.media3.common.MediaItem.LiveConfiguration =
        androidx.media3.common.MediaItem.LiveConfiguration.Builder()
            .setTargetOffsetMs(6_000)
            .setMinPlaybackSpeed(1.0f)
            .setMaxPlaybackSpeed(1.0f)
            .build()

    private val liveConfigRelaxed: androidx.media3.common.MediaItem.LiveConfiguration =
        androidx.media3.common.MediaItem.LiveConfiguration.Builder()
            // ★ 2026-11-03：**回退到 15s**（先试过 8s，未验证收益；TV 端以"稳"为先，别再拿电视做试验田）。
            .setTargetOffsetMs(15_000)
            .setMinPlaybackSpeed(1.0f)
            .setMaxPlaybackSpeed(1.0f)
            .build()

    /**
     * 播放一个已解析好的地址。
     * @param url 央视频：`resolve()` 给的 m3u8；江苏台/IPTV：上游直链
     * @param plain ⚠️ 2026-10-27 起**不再用于分流** —— 是否解密由 `Channel.needsCmg` 决定。
     *   保留参数只为不动调用方签名。
     */
    /**
     * @param isReplay ★ 2026-10-22：**回看/时移流**（`playbacktime != null` 那条链路）。
     *   ⚠️ 回看流**绝不能**挂 `LiveConfiguration`：它的"直播沿"其实是**录制末尾**，
     *   播放器会去追 `末尾 - 12s` ⇒ 起播后反复 seek/重缓冲（正是用户反馈的
     *   "回看前 15 秒常卡 1~2 次"）。回看只需从 `playbacktime` 正常播。
     */
    fun play(ch: Channel, url: String, plain: Boolean = false, isReplay: Boolean = false) {
        val headers: Map<String, String> = if (ch.isJstv) JiangsuTv.headers() else yspHeaders()
        // ★ 2026-10-27：**只有那 8 个 ChinaDRM 台需要解密**，其余明文流直接透传
        // ★★★ 2026-10-27（关键修正）★★★
        //   **回看分片是明文**（官方 App 抓包实证：回看流 35MB 里 NAL 起始码 6949 个，
        //   清单那行 `#EXT-X-KEY:METHOD=SM4-CBC` 只是声明/decoy）。
        //   若对明文再跑一遍 CMG 解密 ⇒ 视频被解坏 ⇒「有声音 + 绿屏」（正是之前的现象）。
        //   ⇒ 规则：**回看一律明文直通**；只有「直播 + needsCmg 台」才走 CMG 解密。
        //      · 直播 8 台：Web/PC 链路给 CMG 格式 ⇒ 必须解 ✓
        //      · 回看 8 台：移动端链路给明文    ⇒ 绝不能解 ✓
        // ★★★★★ 2026-10-29：**回看也要解 sm4c** ★★★★★
        //   用户实测：8 个台的**回看花屏**（直播正常）⇒ 回看分片其实也是 SM4 密文，
        //   之前"回看一律明文直通"的判断对这几个台是错的。
        //   ⇒ 回看同样走 `plainChannel=false`；但**解不了时必须原样直通**（replayMode），
        //     绝不能回落到 CMG（会把本来就明文的回看流解坏 ⇒ 绿屏，2026-10-22 踩过）。
        //
        // ★★★ 2026-11-04：**换配置 = 原子替换一份快照**（不再直接改字段）★★★
        //   旧 MediaSource 已经建好的 DataSource 读的是它**创建时**的快照 ⇒
        //   "换台瞬间旧片还在下载、却被按新台策略解密"的竞态从结构上消失。
        factory.update(
            headers = headers,
            plainChannel = plain || !ch.needsCmg,
            pid = ch.pid,
            replayMode = isReplay,
        )
        // 同一台**重播**时清掉上一次的"清单级明文"结论，让它重新判定（语义与旧版一致）。
        //   ⚠️ 现在按 pid 分桶，清的是本台，不会串到别的台。
        factory.plainByPlaylist = false

        Log.i("[player] 起播 ${ch.name} url=${url.take(110)}")
        // ★★ 2026-10-01（用户要求：媒体播控卡片）★★ 把**频道名 + 该频道台标**挂进 MediaMetadata
        //   ⇒ 通知栏/锁屏/耳机上的播控卡片显示的就是正在看的台。
        //   台标直接给**字节**（`setArtworkData`），不需要为了封面把图片落盘成文件。
        val md = MediaMetadata.Builder()
            .setTitle(ch.name)
            .setArtist(MEDIA_ARTIST)
            .apply {
                // 封面 = 该频道台标（字节直传，不落盘）。★ 2026-10-02：改用 `Logos.artworkBytes()`
                //   —— 它是"16:9 深色底 + 居中台标"，因为 **Android 13+ 会把 artwork 铺成整张卡片的背景**
                //   （直接给透明方图会被放大 + 居中裁切，用户截图里"台标文字被切掉、标题压在图上"就是这个）；
                //   缺图时退回原始台标字节（功能不受影响）。
                (Logos.artworkBytes(appContext, ch) ?: Logos.logoBytes(appContext, ch))?.let {
                    setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
                }
            }
            .build()
        // ⚠️ 直播参数要挂在 MediaItem 上（ExoPlayer 没有 setLiveConfiguration）
        player.setMediaItem(
            MediaItem.Builder()
                .setUri(url)
                // ★★ 2026-10-02（真机实测根因，别删）★★ **必须显式声明"HLS 清单"** ★★
                //   ExoPlayer 是拿 **URI 路径的扩展名**推断类型的（`Util.inferContentType`），后缀不像 m3u8
                //   就按"普通媒体流"处理 ⇒ 直接把手里的清单文本丢给各解封装器 sniff。香港卫视这条
                //   `https://hkstv.tv/api/m3u8-proxy?url=…%2Fplaylist.m3u8` **路径是 `/api/m3u8-proxy`**
                //   （`.m3u8` 只在查询参数里）⇒ 真机日志：
                //     `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED / UnrecognizedInputFormatException:
                //      None of the available extractors … could read the stream（sniff failures: [NoDeclaredBrand]）`
                //   ⇒ 点进去秒回原台，看着像"源无信号"，其实源和网络都没问题（预检也是 200/117 B 通过）。
                //   ⚠️ 鸿蒙侧 AVPlayer 不依赖后缀（那边一直能放）⇒ 这个坑**只出现在安卓**，所以别照搬"鸿蒙能播"下结论。
                .apply { if (url.contains("m3u8", ignoreCase = true)) setMimeType(MimeTypes.APPLICATION_M3U8) }
                // ★ 2026-10-04：TV 用"稳"参数（落后 10s、不追播），手机用低延迟那套（见 `relaxedLive`）
                // ★★ 2026-10-22（用户反馈"回看前 15 秒常卡 1~2 次"）：**回看/时移不挂这个** ★★
                //   原因：回看流的"直播沿"= 录制末尾，LiveConfiguration 会让播放器去追
                //   `末尾 - targetOffset` ⇒ 起播就 seek 到节目末尾、再回退 ⇒ 连续重缓冲。
                .apply {
                    // ★ 2026-11-03：回看/时移**也要挂** LiveConfiguration（原因见 `liveConfigReplay` 注释：
                    //   不挂 ⇒ 贴着滚动窗口最老端起播 ⇒ 每 ~19 秒掉窗一次）。
                    //   注意别用直播那套大偏移（12s/15s），否则会直接跳到节目末尾附近。
                    //
                    // ★★★ 2026-11-04：**全托管**（不挂 LiveConfiguration，交 Media3 默认）★★★
                    //   用户实测这版观感最好（缓冲少、4K 正常），故默认开启。
                    //   ⚠️ 默认行为是"尽量贴直播沿播"，在窗口只有 2~3 片的台上有较高 BEHIND_LIVE_WINDOW
                    //      风险（项目 2026-11-03 的历史结论）；若哪天要调回来，把 true 改成 false 即可。
                    if (!FULL_AUTO_LIVE) setLiveConfiguration(liveConfigDynamic(isReplay, ch))
                }
                .setMediaMetadata(md)
                .build()
        )
        player.prepare()
        player.playWhenReady = true
    }

    fun stop() {
        player.stop()
    }

    /**
     * ★★ 2026-10-02（用户实测：香港卫视 / 金鹰卡通这类**慢源**被安卓误判"无信号"，而鸿蒙能播）★★
     *   外部直链源预检 —— 判据**逐条对齐鸿蒙 `Index.ets` 的 `probeIptvSource()`**（及桌面端
     *   `IptvSourceAliveAsync`）。这里原来有三处比鸿蒙更严，正是误杀慢源的元凶：
     *     ① 超时 **4s → 6s**（鸿蒙/桌面端都是 6s。实测香港卫视那条代理清单要 1.2~2.2s，慢一点就超时）；
     *     ② 判据 **"正文必须含 `#EXTM3U`" → "拿到非空响应体就算活"**（鸿蒙只判非空）——
     *        代理源常见"主清单 + 302 子清单"结构，正文形态多变，卡 `#EXTM3U` 会误杀；
     *     ③ 请求头**不再用 `yspHeaders()`** —— 那是**央视频**的 `Origin/Referer`，发给第三方 IPTV 源
     *        语义就错了（还可能被防盗链挡）；鸿蒙只带 `User-Agent` + `Accept`（星号通配）。
     *        ⚠️ 注释里别写出 `Accept` 的字面通配值：那是「星号紧跟斜杠」两个字符，会把 KDoc 提前闭合，
     *           编译报 "Expecting member declaration"（实测踩过两次）。
     *   · 非 2xx **不拦**（判活）：外部源常因缺 Referer 回 403，且这类响应秒回、不挂界面；拦下会误杀可用源
     *     （鸿蒙侧注释原话："实测广州电视 403"）。真不能播时，播放器的 error 路径 + `fallbackToLastGood` 兜底。
     *   · 2xx 但**响应体为空** ⇒ 判无信号（鸿蒙原版所谓的 `no-playurl`）。
     *   ⚠️ 预检是网络 I/O ⇒ 调用方必须切 IO 线程（见 `MainViewModel` 的 `withContext(Dispatchers.IO)`）。
     */
    fun probePlain(url: String, timeoutMs: Long = IPTV_PROBE_TIMEOUT_MS): Boolean {
        if (url.isEmpty()) {
            Log.w("[player] 源预检：URL 为空 ⇒ 判无信号")
            return false
        }
        return try {
            val (code, len) = com.rickyone.palmtv.data.Http.probeGet(url, iptvProbeHeaders(), timeoutMs)
            when {
                code !in 200..299 -> {
                    Log.w("[player] 源预检 HTTP $code（不拦，交播放器试播）")
                    true
                }
                len == 0 -> {
                    Log.w("[player] 源预检 HTTP $code 但响应体为空 ⇒ 判无信号")
                    false
                }
                else -> {
                    Log.i("[player] 源预检 OK：HTTP $code / ${len} B（不校验正文形态，与鸿蒙同）")
                    true
                }
            }
        } catch (e: Exception) {
            // ★ 必须打异常类名 + 堆栈 —— 实测这里拿到过 `e.message == null` 的异常
            //   （如 `SocketTimeoutException`/`NetworkOnMainThreadException`），只打 message 等于没打。
            Log.w("[player] 源预检失败（${e.javaClass.name}）: ${e.message}\n" + android.util.Log.getStackTraceString(e))
            false
        }
    }

    /** IPTV 预检请求头：与鸿蒙 `probeIptvSource` 一致，**只带 UA + Accept**（理由见 [probePlain] ③） */
    private fun iptvProbeHeaders(): Map<String, String> = mapOf(
        "User-Agent" to Config.UA,
        "Accept" to "*/*"
    )


    fun setVolume(v: Float) {
        player.volume = v.coerceIn(0f, 1f)
    }

    fun setMuted(muted: Boolean) {
        player.volume = if (muted) 0f else 1f
    }

    fun release() {
        try {
            player.release()
        } catch (e: Exception) {
            Log.w("[player] release 异常: ${e.message}")
        }
    }

    /** 央视频链路：清单/分片请求要带的浏览器式头（与 auth/get_live_info 同一套）。
     *  ★★ 2026-10-08：**补 `UID`** —— 官方 app 发往 CDN 的请求头里有 `UID: <guid>`（80 端口中继实抓），
     *     而我们两条链路都漏了它。实测症状：**清单 200、分片 403**（播放器只刷清单、永远不出画）。 */
    private fun yspHeaders(): Map<String, String> = mapOf(
        "User-Agent" to Config.UA,
        "Accept" to "*/*",
        "Origin" to Config.ORIGIN,
        "Referer" to Config.REFERER,
        "Accept-Language" to "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        "UID" to YspAndroidCKey.GUID
    )

    companion object {
        /** 媒体播控卡片上的副标题（与 App 名一致，别写成英文）。
         *  ★ 2026-10-02（用户要求：卡片里不要出现英文 "PalmTV"）：`"PalmTV 掌上电视"` → **`"掌上电视"`**，
         *  与鸿蒙 `TvSession.setChannel()` 里的 `artist: '掌上电视'` 完全一致（三端同口径）。 */
        const val MEDIA_ARTIST = "掌上电视"

        /** ★ 2026-11-04 对照实验开关：`true` = 直播**不挂** `LiveConfiguration`（全交 Media3 默认）。
         *  只用于验证"我们调的参数是否不如默认"，**默认必须是 false**。 */
        const val FULL_AUTO_LIVE = true

        /** ★ 2026-10-02：IPTV 外部直链**起播前预检**超时 —— 与鸿蒙 `IPTV_PROBE_TIMEOUT_MS`（6s）一致。
         *  ⚠️ 原先是安卓自己拍的 4s，比鸿蒙严 2s，慢源（香港卫视代理清单 1.2~2.2s）会被误判成"无信号"。 */
        const val IPTV_PROBE_TIMEOUT_MS = 6_000L

        /** 当前视频尺寸（给"宽高比修正"用；鸿蒙靠 `videoArFix`，这边由 UI 侧改 view 尺寸） */
        fun onVideoSize(vs: VideoSize): Pair<Int, Int> = vs.width to vs.height

        /** 播放器状态文案（与鸿蒙一致的心智模型） */
        fun stateName(s: Int): String = when (s) {
            Player.STATE_IDLE -> "idle"
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> "ready"
            Player.STATE_ENDED -> "ended"
            else -> "?"
        }
    }
}
