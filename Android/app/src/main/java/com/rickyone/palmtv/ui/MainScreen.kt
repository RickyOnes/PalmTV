package com.rickyone.palmtv.ui

import android.app.Activity
import androidx.compose.foundation.Image
import android.view.ViewGroup
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
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
import com.rickyone.palmtv.data.Log
import com.rickyone.palmtv.player.Logos
import kotlinx.coroutines.delay

/**
 * 横屏分栏里**视频列**的宽度权重（右侧频道栏 = `1f - 它`）。
 *
 * ★★ 2026-10-01（用户实测：安卓频道栏比鸿蒙窄）⇒ **回到与鸿蒙逐像素一致** ★★
 *   鸿蒙 `Index.ets`：左列 `layoutWeight(this.isWide() ? 68 : …)`、右列 `layoutWeight(this.isWide() ? 32 : 1)`，
 *   且 `videoAreaW()` 写的是 `w * 0.68` ⇒ 这里必须同样是 **0.68 / 0.32**（否则频道栏更窄、台标也更小）。
 *   ⚠️ 中途为"让画面更大"曾改成 0.74：画面确实变大了（横屏 16:9 窗口下画面是**宽度受限**的，
 *      1088 → 1184），但代价是频道栏从 32% 掉到 26% ⇒ 与鸿蒙不一致，用户要求按鸿蒙来 ⇒ 已改回 0.68。
 *   ℹ️ 横屏 16:9 窗口下画面上下仍有约 10% 黑边（`h = 0.68W × 9/16 ≈ 0.38H < H`）——
 *      这是**数学必然**（除非裁切掉画面），鸿蒙在同样窗口下也一样；宽屏手机（≈20:9）没有这个现象。
 */
private const val LAND_VIDEO_WEIGHT = 0.68f

/**
 * 主界面 —— 分区与鸿蒙 `Index.ets` 一一对应：
 *   状态栏 → 播放区（含手势/控制条/浮层）→ EPG 条 → 分段控件（央视/卫视/地方/关于）→ 网格 / 关于页
 * 遮罩：EPG 弹层、免责声明弹窗（最上层，点空白不关）。
 */
@Composable
fun MainScreen(vm: MainViewModel, ui: UiState) {
    val ctx = LocalContext.current
    val activity = ctx as? Activity
    // ★★ 2026-10-08（用户要求：手机版也"打开就能看"）★★
    //   与 TV 端**同一套**语义（`startDefaultChannel()`）：优先**续播上次看的那台**，否则 **CCTV-1**。
    //   ⚠️ 等免责声明关掉再起播（首启弹层时别在后台偷偷拉流）；⚠️ 只在"当前没有台在播"时动手
    //     —— 旋转重建 / 回前台不会打断正在播的台。
    LaunchedEffect(ui.showDisclaimer) {
        if (!ui.showDisclaimer) vm.startDefaultChannel()
    }
    // ★★ 2026-10-01：横屏且非全屏 ⇒ **左右分栏**（与鸿蒙 `isWide()` 完全同口径、同比例）：
    //   · 左列 **68%** 宽：状态栏 + 视频区（吃掉剩余高度；画面按视频真实比例 contain，由 PlayerView 负责）+ 节目条
    //   · 右列 **32%**：分段控件 + 频道网格（横屏 **3 列** / 竖屏 5 列 —— 与鸿蒙 columnsTemplate 一致）
    //   ⚠️ 全屏时窗口也是横的，但必须按"整屏"处理（不分栏），否则画面还是半屏大小
    //      —— 鸿蒙真机上踩过同一个坑，所以那边专门用 `isWide()` 而不是 `isLandscape`。
    //   ★ 判据用**实测容器宽高**（BoxWithConstraints），不用 Configuration.orientation：
    //     多窗口/模拟器里"窗口比例"与"系统朝向"不一定一致，实测最稳（与鸿蒙"监听 windowSizeChange"同思路）。
    BoxWithConstraints(
        Modifier.fillMaxSize().background(Palette.Bg)
            // ★ 2026-10-01：**避让系统栏**（顶部状态栏 / 底部导航栏）—— 原来内容从 y=0 开始画，
            //   模拟器与真机上系统时钟会压在我们的状态栏文案上（用户实测指出）。与鸿蒙 `readInsets()` 同目的。
            // ★★ 2026-10-01 修 bug（用户实测："全屏时左右黑边宽度不一致、没居中"）★★
            //   全屏时系统栏已隐藏，可 inset 仍可能只剩**单边**（刘海/挖孔、横屏时的侧边导航栏）
            //   ⇒ 内容整体被推向一侧，画面在屏幕上看就不居中。
            //   鸿蒙全屏用**整屏**（`videoAreaW/H` 全屏时直接取窗口尺寸）⇒ 这里对齐：全屏不缩进。
            .then(if (ui.fullscreen) Modifier else Modifier.safeDrawingPadding())
    ) {
        val isWide = !ui.fullscreen && maxWidth > maxHeight
        // ★★ 2026-10-01（用户要求：与鸿蒙同步"三者与画面同宽"）★★
        //   鸿蒙里 **状态栏、节目条、XComponent** 全是 `.width(this.videoBoxW())`（Index.ets 2274 / 2691 / 2295），
        //   节目单弹窗横屏也是 `videoBoxW()`（2895）⇒ 画面比可用区窄时（设备很宽 ⇒ 16:9 画面被高度限制），
        //   这三者也跟着变窄并**居中**，与画面左右边缘对齐。
        //   这里由 `PlayerArea` 量出画面实际宽度后回填（0.dp = 还没量到 ⇒ 退回 fillMaxWidth）。
        var videoW by remember { mutableStateOf(0.dp) }

        when {
            ui.fullscreen -> PlayerArea(vm, ui, activity, Modifier.fillMaxSize()) { videoW = it }

            isWide -> Row(Modifier.fillMaxSize()) {
                Column(
                    Modifier.weight(LAND_VIDEO_WEIGHT).fillMaxHeight(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    StatusBar(ui, videoW)
                    PlayerArea(vm, ui, activity, Modifier.weight(1f).fillMaxWidth()) { videoW = it }
                    EpgStrip(ui, isWide = true, width = videoW, onOpen = { vm.openEpg() },
                onBackToLive = { vm.backToLive() })
                }
                ChannelSection(
                    vm, ui, columns = 3,
                    boxModifier = Modifier.weight(1f - LAND_VIDEO_WEIGHT).fillMaxHeight()
                )
            }

            else -> Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                StatusBar(ui, videoW)
                PlayerArea(vm, ui, activity, Modifier.fillMaxWidth().height(210.dp)) { videoW = it }
                EpgStrip(ui, isWide = false, width = videoW, onOpen = { vm.openEpg() },
                onBackToLive = { vm.backToLive() })
                Spacer(Modifier.height(4.dp))
                ChannelSection(vm, ui, columns = 5)
            }
        }

        if (ui.showEpg) {
            // 横屏（分栏）⇒ 弹窗与**画面同宽**（鸿蒙 `isWide() ? videoBoxW() : '92%'`）
            EpgModal(
            ui, matchVideo = isWide, videoW = videoW,
            onClose = { vm.closeEpg() },
            // ★ 2026-10-07：点已播完的节目 ⇒ 回看（走安卓平台链路的 playbacktime）
            onReplay = { vm.playReplayFrom(it, newRef = true) }   // ★ 节目单点击 ⇒ 重设时移基准
        )
        }
        if (ui.showDisclaimer) {
            DisclaimerModal(ui, onAgree = { vm.agreeDisclaimer() }, onRefuse = {
                vm.dismissDisclaimer()
                activity?.finish()
            }, onClose = { vm.dismissDisclaimer() })
        }
    }
}

// ======================================================================
// 状态栏
// ======================================================================

@Composable
private fun StatusBar(ui: UiState, width: Dp) {
    val dot = when {
        ui.playErr -> Palette.OnAirRed
        ui.playing -> Palette.NextGreen
        else -> Palette.TextDim
    }
    // ★★ 2026-10-01（用户最终决定）：**③ 放弃，不自绘时间/电量** ★★
    //   来龙去脉（免得以后又有人加回来）：
    //     · 宿主导致的横屏系统状态栏隐藏（卓易通 / HarmonyOS 兼容层）**应用侧无解**：
    //       `show(systemBars())` 无效，官方也没有"兼容层里保留系统栏"的能力；
    //     · 于是做过两版自绘（① 仅在系统栏不可见时画、② 永远画），用户评估后要求**整段删除** ——
    //       本应用的顶部状态行只承载"状态灯 + 播放状态文案"，时间/电量交给系统（真实安卓机上正常）。
    Row(
        Modifier
            // 与画面同宽（鸿蒙 `statusBar()` 也是 `.width(videoBoxW())`）；量不到就退回整宽
            .then(if (width > 0.dp) Modifier.width(width) else Modifier.fillMaxWidth())
            .background(Palette.StatusBg).padding(horizontal = 12.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(8.dp))
        Text(
            ui.bootMsg,
            // ★ 2026-10-01：显式行高（Material3 默认 lineHeight 24sp 会把 12sp 的行撑高 ⇒ 状态栏比鸿蒙厚）
            fontSize = 12.sp, lineHeight = 16.sp,
            color = Palette.TextDim,
            maxLines = 1,
            modifier = Modifier.weight(1f)
        )
    }
}

// ======================================================================
// 播放区（手势 + 控制条 + 浮层）
// ======================================================================

@Composable
private fun PlayerArea(
    vm: MainViewModel,
    ui: UiState,
    activity: Activity?,
    modifier: Modifier = Modifier,
    /** ★ 2026-10-01：把**画面实际宽度**回填给上层 —— 状态栏 / 节目条 / 节目单弹窗都要与画面同宽
     *  （鸿蒙 `videoBoxW()` 同口径）。画面比可用区窄时（设备很宽 ⇒ 16:9 被高度限制）这个值才有意义。 */
    onVideoWidth: (Dp) -> Unit = {}
) {
    // ★★ 2026-10-01（复刻鸿蒙 `videoArFix`）★★ 宽高比修正用"**画面上已生效**的值"，
    //   **不要**用 `ASPECT_OVERRIDES[ui.currentName]` 现查表：换台瞬间 `currentName` 已改成新台、
    //   而旧画面还挂在屏上 ⇒ 现查表会把修正提前撤销 ⇒ 旧帧先弹回原始尺寸（"切出三个修正台还会抖一下"）。
    //   现在由 VM 在**新流的 `onVideoSizeChanged` 到达时**才把 `videoArFix` 切过去（= 鸿蒙"新台 prepared 时"）。
    val arFix = ui.videoArFix
    // 量画面宽度用（`LayoutCoordinates` 这个版本不暴露 density，必须用 LocalDensity）
    val density = LocalDensity.current
    var dragStartX by remember { mutableFloatStateOf(0f) }
    var startVolume by remember { mutableFloatStateOf(ui.volume) }
    // ★★ 2026-10-01（用户真机实测：音量手势坏）★★ 手势位移的**累计量**（与鸿蒙 `event.offsetY` 同义）。
    //   Compose 的 `onVerticalDrag` 给的是**每帧增量** `dragAmount`，而"起点 + 增量"的换算必须以
    //   **手势起点的值**为基准 ⇒ 必须自己累加，否则每个事件都从起点重算（见 `dragVolume` 注释）。
    var dragOffsetY by remember { mutableFloatStateOf(0f) }
    // ★ 2026-10-01：亮度**起点由"当前窗口亮度"决定**（见下面 onDragStart），-1 = 还没量过。
    //   原实现写死 0.5 ⇒ 不管现在多亮，第一下拖动就"跳"到 50% 附近（手感不对）。
    var brightness by remember { mutableFloatStateOf(-1f) }
    /** 本次手势开始时的亮度（鸿蒙 `gestureStartBri` 同义） */
    var brightnessStart by remember { mutableFloatStateOf(0.5f) }

    fun applyBrightness(v: Float) {
        brightness = v
        val w = activity?.window ?: return
        val lp = w.attributes
        lp.screenBrightness = v.coerceIn(0.02f, 1f)
        w.attributes = lp
    }

    BoxWithConstraints(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        // ★★ 2026-10-01（用户要求：横屏更紧凑、画面更大、设备很宽时居中）★★
        //   画面盒子**自己算准**（算法与鸿蒙 `Index.ets` 的 `videoBox()` 完全一致），
        //   不再让 PlayerView 在一个比视频大一圈的盒子里自己去留边：
        //     · 比例 = 视频**真实**比例（`ui.videoAr`，由 `onVideoSizeChanged` 回填，含 PAR 修正；
        //       未知时按 16:9）。AR 修正台（哈尔滨电影/综合、农林卫视）用 `Channels.aspectOverrides` 强制 16:9。
        //     · 尺寸 = 可用区里能放下的**最大**该比例矩形：宽度先吃满；若按宽度算出的高度超出可用区，
        //       就改成"高度吃满 + 按比例反推宽度"（两种情况都刚好贴住可用区，不浪费）。
        //     · 位置 = 居中（`contentAlignment = Center`）⇒ 设备很宽时画面**左右居中**，不再贴边。
        //     · 盒子比例 == 视频比例 ⇒ `RESIZE_MODE_FIT` 在盒子内部**不会再有第二层黑边**，画面即盒子。
        val ar = if (arFix > 0f) arFix
        else ui.videoAr.takeIf { it > 0.01f } ?: (16f / 9f)
        // ★ 2026-10-01：两个分支都写成**显式**约束（高度先定 / 宽度先定），不再依赖 aspectRatio 的
        //   "先试宽度、装不下再退回高度"隐式回退 —— 全屏居中问题排查时这里要绝对确定。
        val videoBox = if (maxWidth / maxHeight > ar) {
            Modifier.fillMaxHeight().aspectRatio(ar, matchHeightConstraintsFirst = true)
        } else {
            Modifier.fillMaxWidth().aspectRatio(ar)
        }
        // ★★ 2026-11-04：`key(videoViewGen)` —— 这个数一变，Compose 就**销毁并重建** PlayerView
        //   （= 新 SurfaceView / 新 Surface），等价于用户实测有效的“切一次横屏”。
        key(ui.videoViewGen) {
        AndroidView(
            // ★ 2026-10-01：把画面实际宽度回填给上层（状态栏/节目条/弹窗与画面同宽，与鸿蒙 `videoBoxW()` 同口径）
            modifier = videoBox.onGloballyPositioned { c ->
                val w = with(density) { c.size.width.toDp() }
                if (w > 0.dp) onVideoWidth(w)
            },
            factory = { c ->
                // ★★ 2026-11-04：改用 **TextureView**（`res/layout/phone_player_view.xml`）。
                //   原因：SurfaceView 在退后台/回前台时会"握着已失效的 Surface" ⇒ 有声无画，
                //   且换台也修不好（视图与 Surface 都没换）；用户实测只有横屏一次才恢复
                //   （转屏使 SurfaceView 尺寸变化 ⇒ Surface 被动重建）。TextureView 没有这个生命周期问题，
                //   TV 端一直用它、从没出现过该现象。
                val v = android.view.LayoutInflater.from(c)
                    .inflate(com.rickyone.palmtv.R.layout.phone_player_view, null) as PlayerView
                v.apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
                    )
                    if (arFix > 0f) resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FILL
                    // 换台/重置时保留最后一帧，避免闪黑（TV 端同款）
                    setKeepContentOnPlayerReset(true)
                    setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                    player = vm.exoPlayer()
                    vm.attachVideoView(this)
                }
                v
            },
            update = { v ->
                v.player = vm.exoPlayer()
                // ★★ 2026-10-01 修 bug：`resizeMode` 原来**只在 factory（首次组合）里设一次** ⇒
                //   换台后宽高比修正**失效**：先看普通台、再切哈尔滨电影/综合/农林卫视，画面就退回
                //   "4:3 + 左右黑边"（用户报的"三个台尺寸有问题"就是这个）。
                //   ⇒ 改成每次 update 都按当前频道重设（Compose 换台会走到这里）。
                v.resizeMode = if (arFix > 0f) AspectRatioFrameLayout.RESIZE_MODE_FILL
                else AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
        )
        }

        // 手势层
        Box(
            Modifier.fillMaxSize()
                .pointerInput(Unit) { detectTapGestures { vm.toggleControls() } }
                // ★★★ 2026-10-22（用户要求）：**左右滑动 = 时移 ±10 秒** ★★★
                //   与竖滑（音量/亮度）分开挂在两个 pointerInput 上：Compose 按主方向仲裁，互不干扰。
                .pointerInput(ui.locked) {
                    if (ui.locked) return@pointerInput   // 锁屏时不响应
                    var acc = 0f
                    detectHorizontalDragGestures(
                        onDragStart = { acc = 0f },
                        onHorizontalDrag = { _, delta ->
                            acc += delta
                            // ★ 2026-10-22（用户反馈"多次滑动常停在上一个位置"）：
                            //   拖动过程中每 120px 就走 10 秒，本地立刻累加 + OSD 实时显示；
                            //   真正取流交给 `settleTimeshift()`（抬手后防抖 400ms 只发一次）。
                            //
                            // ★★ 约定与主流播放器一致：**右滑 = 前进、左滑 = 后退** ★★
                            //   ⚠️ `shiftBy` 的入参语义已改为"**播放位置增量**"（epoch 秒的增减）：
                            //     正数 ⇒ 往后 +N 秒（前进）；负数 ⇒ 往前 -N 秒（后退）。
                            //   （2026-10-22 之前它是"相对直播沿的偏移变化"，符号相反 ——
                            //     改成"位置基准"后这里必须同步，否则方向又反。别再改错。）
                            while (acc >= 120f) { acc -= 120f; vm.shiftBy(10L) }
                            while (acc <= -120f) { acc += 120f; vm.shiftBy(-10L) }
                        },
                        onDragEnd = { vm.settleTimeshift() },
                        onDragCancel = {
                            // 手势被取消 ⇒ 状态回退到"还没生效"的偏移（重新取流以服务端为准）
                            vm.settleTimeshift()
                        }
                    )
                }
                .pointerInput(ui.locked) {
                    detectVerticalDragGestures(
                        onDragStart = { offset ->
                            dragStartX = offset.x
                            // ★ 2026-10-01：**不能读 `ui.volume`** —— 这个 lambda 固化的是组合时的 `ui` 快照，
                            //   会导致每次手势都从"旧音量"（实测表现为 100%）起算。改成向 VM 现读。
                            startVolume = vm.currentVolume()
                            dragOffsetY = 0f        // ★ 每次手势重新开始累计（鸿蒙 PanGesture 同义）
                            // ★ 2026-10-01：首次拖动前先读**当前窗口亮度**当增量起点
                            //   （window 的 screenBrightness = -1 表示"跟随系统" ⇒ 这时按 0.5 起步）。
                            //   注意：Window 亮度在真机有效；**MuMu 等模拟器的呈现层可能不兑现**
                            //   —— 真机才是验收环境。
                            if (brightness < 0f) {
                                val cur = activity?.window?.attributes?.screenBrightness ?: -1f
                                brightness = if (cur in 0.01f..1f) cur else 0.5f
                            }
                            brightnessStart = brightness
                        },
                        onVerticalDrag = { _, dy ->
                            dragOffsetY += dy       // ★★ 累加（Compose 给的是每帧增量，不是累计位移）★★
                            val leftHalf = dragStartX < size.width / 2f
                            if (leftHalf) {
                                // 与鸿蒙一致：`step = -offsetY / 300`，且以**手势起点的亮度**为基准
                                val v = (brightnessStart - dragOffsetY / 300f).coerceIn(0f, 1f)
                                applyBrightness(v)
                                vm.hintBrightness((v * 100).toInt())
                            } else {
                                // ★ 传**累计位移**（不是每帧增量）—— 修复"只能在 95%~100% 抖"（见 dragVolume 注释）。
                                //   方向与鸿蒙一致：上滑(dy<0) 变大、下滑变小。
                                vm.dragVolume(startVolume, dragOffsetY)
                            }
                        },
                        onDragEnd = { vm.clearGestureHint() },
                        onDragCancel = { vm.clearGestureHint() }
                    )
                }
        )

        // ★★ 控制条：改用**原版图片资源** ★★（用户要求与鸿蒙一致）
        //   图标来源：鸿蒙工程 `harmony/entry/src/main/resources/base/media/` 的
        //   `plyay.png` / `pause.png` / `player_sound_on|off.png` / `fullscreen.png` / `window.png` /
        //   `locked.png` / `unlock.png`（已复制到 `Android/app/src/main/res/drawable/ic_player_*.png`）。
        //   尺寸与间距照抄鸿蒙：播放/暂停 44、静音 36、全屏 44，间距 16；
        //   全屏时左右边距 40（原来 10 太贴屏边不好点），窗口模式 10。
        //   ⚠️ 原来用 emoji 文字（"⏸ ▶ 🔇 🔊 ⤡ ⛶"）—— 各系统字形不一、也与鸿蒙不一致，已弃用。
        if (ui.controlsVisible && !ui.locked) {
            Row(
                Modifier.align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(Color(0x88000000))
                    .padding(horizontal = if (ui.fullscreen) 40.dp else 10.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                CtrlIcon(if (ui.playing) "pause" else "play", 44.dp, "播放/暂停") { vm.togglePlayPause() }
                Spacer(Modifier.weight(1f))
                CtrlIcon(if (ui.muted) "sound_off" else "sound_on", 36.dp, "静音") { vm.toggleMute() }
                CtrlIcon(if (ui.fullscreen) "window" else "fullscreen", 44.dp, "全屏") { vm.toggleFullscreen() }
            }
        }
        if (ui.fullscreen && ui.controlsVisible) {
            // ★ 2026-10-01（用户要求与鸿蒙同步）：左边距用**控制条同款**的 40dp（原来 12dp ⇒ 与播放/暂停没对齐）；
            //   鸿蒙写法：`.position({ x: this.isFullscreen ? 40 : 12, y: '50%' }).translate({ y: '-50%' })`
            //   —— 水平贴 40vp、竖直居中；本行 `align(CenterStart)` 正是这个语义。
            Box(Modifier.align(Alignment.CenterStart).padding(start = 40.dp)) {
                CtrlIcon(if (ui.locked) "locked" else "unlock", 28.dp, "锁屏") { vm.toggleLock() }
            }
        }

        // 手势提示
        if (ui.gestureHint.isNotEmpty()) {
            Text(
                ui.gestureHint,
                fontSize = 13.sp, color = Color.White,
                modifier = Modifier.align(Alignment.Center)
                    .background(Color(0x99000000), RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }

        // 空态提示 / 中央浮层
        if (ui.activeChannelId.isEmpty() && ui.videoNotice.isEmpty()) {
            // ★ 2026-10-01：改用 `Strings.PICK_CHANNEL`（原来硬编码）—— 文案已去掉"下方"
            //   （横屏分栏时列表在右侧，说"下方"会误导；鸿蒙同名文案同步改了）
            Text(Strings.PICK_CHANNEL, fontSize = 13.sp, color = Palette.TextDim)
        }
        if (ui.videoNotice.isNotEmpty()) {
            Text(
                ui.videoNotice,
                fontSize = 14.sp, color = Color(0xFFDDDDDD), textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center)
                    .background(Color(0xB0000000), RoundedCornerShape(12.dp))
                    .padding(horizontal = 20.dp, vertical = 14.dp)
            )
        }
    }
}

/**
 * 播放控件图标（原版图片资源，与鸿蒙 `media/` 是**同一批图**）。
 * ★ 2026-10-01：不再用 `painterResource(R.drawable.ic_player_*)`，改从**单个** `assets/palmres.dat`
 *   里取（`ui/play`、`ui/pause`、`ui/sound_on|off`、`ui/fullscreen|window`、`ui/locked|unlock`）
 *   —— 用户要求"打包后文件数量不要太多"，那 8 个 drawable PNG 已从工程删除。
 * ⚠️ 图没加载到（老包/构建脚本没跑）时直接不画，不崩。
 */
@Composable
private fun CtrlIcon(name: String, size: Dp, desc: String, onClick: () -> Unit) {
    val ctx = LocalContext.current
    val bmp by remember(name) { mutableStateOf(Logos.ui(ctx, name)) }
    val b = bmp ?: return
    Image(
        bitmap = b.asImageBitmap(),
        contentDescription = desc,
        modifier = Modifier.size(size).clickable { onClick() }
    )
}

// ======================================================================
// EPG 条
// ======================================================================

@Composable
private fun EpgStrip(
    ui: UiState, isWide: Boolean, width: Dp,
    onOpen: () -> Unit,
    /** ★ 2026-10-21：回看中时节目条上出现「回到直播」 */
    onBackToLive: () -> Unit = {}
) {
    // ★★ 2026-10-01（用户要求：与鸿蒙 `Index.ets` 的 `epgStrip()` 同步）★★
    //   · **横屏（分栏）只显示"正在播出"一行** —— 鸿蒙原话："横向空间紧张，且用户明确要求横屏不要'接下来'"
    //     ⇒ 条高从 ~50dp 降到 ~30dp，省下的高度都给画面（配合横屏紧凑的整体目标）；
    //   · 竖屏两行（正在播出 / 接下来），字号与颜色照抄鸿蒙（12/13sp，红 `#ff4444` / 绿 `#3ddc84` / 灰）；
    //   · 内边距 **横屏 5 / 竖屏 10**（鸿蒙 `.padding({top: isWide()?5:10, bottom: …})`）；
    //   · 圆角 8 + `#181818` 底（鸿蒙 `.borderRadius(8)`）；"节目单 ☰" 相对两行竖直居中。
    Row(
        // ★ 2026-10-01：与**画面同宽**（鸿蒙 `epgStrip()` 也是 `.width(videoBoxW())`，且容器居中）——
        //   设备很宽时画面被高度限制 ⇒ 节目条跟着变窄并居中，与画面左右边缘对齐。
        Modifier
            .then(if (width > 0.dp) Modifier.width(width) else Modifier.fillMaxWidth())
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.EpgStripBg)
            .padding(horizontal = 10.dp, vertical = if (isWide) 5.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                // ★★ 2026-10-01：**必须显式给 lineHeight** ★★（用户实测"节目条明显比鸿蒙高"）
                //   Material3 的 `LocalTextStyle` 是 `bodyLarge`（fontSize 16sp / **lineHeight 24sp**）——
                //   我们只覆盖了 fontSize，**行高仍是 24sp** ⇒ 12sp 的字被按 24sp 排，自然高一大截。
                //   取值 = 字号 × 1.32（≈鸿蒙默认行高），与 `Index.ets` 的两行视觉高度对齐。
                // ★ 2026-10-21：回看中 ⇒ 标"回看中"（用户要求：回看成功后节目条要同步成当前回看的节目）
                Text(
                    if (ui.replayStart > 0L) Strings.REPLAYING else Strings.EPG_NOW_TITLE,
                    fontSize = 12.sp, lineHeight = 16.sp,
                    color = if (ui.replayStart > 0L) Palette.Primary else Palette.NowRed
                )
                Text(
                    ui.epgNow, fontSize = 13.sp, lineHeight = 17.sp, color = Palette.TextBright,
                    fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
            }
            if (!isWide) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        Strings.EPG_NEXT_TITLE, fontSize = 12.sp, lineHeight = 16.sp,
                        color = Palette.NextGreen
                    )
                    Text(
                        ui.epgNext, fontSize = 12.sp, lineHeight = 16.sp, color = Palette.TextDim,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        }
        if (ui.replayStart > 0L) {
            Text(
                Strings.BACK_TO_LIVE, fontSize = 12.sp, lineHeight = 16.sp, color = Palette.NextGreen,
                modifier = Modifier.clickable { onBackToLive() }.padding(4.dp)
            )
        }
        Text(
            Strings.EPG_BUTTON, fontSize = 12.sp, lineHeight = 16.sp, color = Palette.Primary,
            modifier = Modifier.clickable { onOpen() }.padding(4.dp)
        )
    }
}

// ======================================================================
// 频道区（分段控件 + 网格 / 关于页）
// ======================================================================

@Composable
private fun ChannelSection(
    vm: MainViewModel,
    ui: UiState,
    /** 网格列数：竖屏 5 列、横屏分栏 3 列（与鸿蒙 `columnsTemplate` 同口径） */
    columns: Int = 5,
    /** 由调用方决定外边距/权重（横屏右列用 `weight(0.32f)`） */
    boxModifier: Modifier = Modifier
) {
    Column(boxModifier.fillMaxSize()) {
        SegmentedTabs(ui, vm)
        if (ui.aboutTab) {
            Box(Modifier.weight(1f).fillMaxWidth()) { AboutView(vm, ui) }
        } else {
            val list = ui.channels.filter { it.group == ui.activeGroup }
            if (list.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(Strings.GROUP_EMPTY, fontSize = 11.sp, color = Color(0xFF666666))
                }
            } else {
                // ★★ 2026-10-01（用户要求：台标偏小 ⇒ 按鸿蒙口径放大）★★
                //   鸿蒙 `Index.ets`：`iconSize = ((可用宽 - 16) / 列数) * 0.88` —— 台标**跟着单元格自动变大**。
                //   安卓原来写死 `56.dp`，而横屏单元格实际有 ~113dp 宽 ⇒ 白圈只占一半，看着"小一圈"。
                //   现在同样按"单元格宽 × 0.88"算（横屏 3 列 / 竖屏 5 列都自适应，任何屏宽都不会溢出）。
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().background(Palette.ChannelBg)) {
                    val tile = ((maxWidth - 8.dp) / columns) * 0.88f
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(columns),
                        modifier = Modifier.fillMaxSize().padding(horizontal = 4.dp),
                        contentPadding = PaddingValues(vertical = 6.dp)
                    ) {
                        items(list, key = { it.id }) { ch ->
                            ChannelTile(vm, ch, ui.activeChannelId == ch.id, tile)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SegmentedTabs(ui: UiState, vm: MainViewModel) {
    val labels = listOf(Strings.TAB_CCTV, Strings.TAB_SATELLITE, Strings.TAB_LOCAL, Strings.TAB_ABOUT)
    val selected = if (ui.aboutTab) 3 else when (ui.activeGroup) {
        Channel.Group.CCTV -> 0
        Channel.Group.SATELLITE -> 1
        Channel.Group.LOCAL -> 2
    }
    BoxWithConstraints(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)
            .height(40.dp).clip(RoundedCornerShape(11.dp)).background(Palette.TabTrack)
    ) {
        val w = maxWidth / 4
        val x by animateDpAsState(targetValue = w * selected + 3.dp, label = "tab")
        Box(Modifier.offset(x = x, y = 3.dp).width(w - 6.dp).height(34.dp)
            .clip(RoundedCornerShape(8.dp)).background(Palette.Primary))
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            labels.forEachIndexed { i, t ->
                Box(
                    Modifier.weight(1f).fillMaxHeight().clickable {
                        when (i) {
                            0 -> vm.switchGroup(Channel.Group.CCTV)
                            1 -> vm.switchGroup(Channel.Group.SATELLITE)
                            2 -> vm.switchGroup(Channel.Group.LOCAL)
                            else -> vm.switchAbout()
                        }
                    },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        t,
                        fontSize = if (i == selected) 15.sp else 14.sp,
                        fontWeight = if (i == selected) FontWeight.Medium else FontWeight.Normal,
                        color = if (i == selected) Color.White else Palette.UnselectedTabText
                    )
                }
            }
        }
    }
}

@Composable
private fun ChannelTile(vm: MainViewModel, ch: Channel, selected: Boolean, size: Dp) {
    val ctx = LocalContext.current
    val bmp by remember(ch.id) { mutableStateOf(Logos.load(ctx, ch)) }
    Box(Modifier.padding(3.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(size).clip(CircleShape).background(Color.White)
                .border(2.dp, if (selected) Palette.OnAirRed else Palette.BorderIdle, CircleShape)
                .clickable { vm.playChannel(ch) },
            contentAlignment = Alignment.Center
        ) {
            val b = bmp
            if (b != null) {
                androidx.compose.foundation.Image(
                    bitmap = b.asImageBitmap(),
                    contentDescription = ch.name,
                    contentScale = ContentScale.Fit,
                    // ★ 2026-10-01：内边距按台标尺寸**成比例**（原来写死 4dp，台标放大后就显得贴边）
                    modifier = Modifier.fillMaxSize().padding(size * 0.07f)
                )
            } else {
                // ★★ 2026-10-02（用户："自定义频道在本地生成文本台标后，要显示**全部频道名**，
                //   而不是现在的一个"）★★ 文字台标原来只取**首字**（`ch.name.take(1)`，字号 = 直径×0.45）
                //   ⇒ 自定义台（无台标）光看一个"延"字不知道是哪个台。
                //   现在显示完整名称，字号按"圆内可用宽 ≈ 0.85×直径"反推（**三端同一套数**，
                //   见鸿蒙 `tileFontSize` / 桌面 `ChannelTile.FallbackFontSize`）：
                //     n ≤ 4 ⇒ 单行，字号 = min(0.85/n, 0.30) × 直径；
                //     n ≥ 5 ⇒ 两行（每行 ⌈n/2⌉ 字），字号 = min(0.85/⌈n/2⌉, 0.22) × 直径；最多 2 行、超出省略。
                //   “0.85”是圆内留边距后的可用弦长 ⇒ 改台标尺寸不用动这里（全按比例）。
                val n = ch.name.length
                val lines = if (n <= 4) 1 else 2
                val per = if (n <= 4) maxOf(n, 1) else (n + 1) / 2
                val fs = minOf(0.85f / per, if (lines == 1) 0.30f else 0.22f) * size.value
                Text(
                    ch.name,
                    fontSize = fs.sp, color = Color(0xFF333333),
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                    maxLines = lines,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.width(size * 0.86f)
                )
            }
        }
    }
}


