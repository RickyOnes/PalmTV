package com.rickyone.palmtv

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.rickyone.palmtv.data.Log
import com.rickyone.palmtv.ui.MainScreen
import com.rickyone.palmtv.ui.PalmTvTheme

/**
 * 唯一 Activity（旋转不重建：manifest 里 `configChanges` 已声明 —— 播放器/Surface 不能被重建）。
 *
 * 屏幕常亮 / 状态栏：全屏时隐藏系统栏（对应鸿蒙 `setWindowSystemBarEnable([])` +
 * `setWindowLayoutFullScreen(true)`）；退出全屏恢复。
 */
class MainActivity : ComponentActivity() {

    private val vm: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // ★ 2026-10-13（L4 判定实验）：ckey 预热开关
        //   /sdcard/ckey_wait 存在时：后台线程等 /sdcard/ckey_go 放行后主动 genCKey 一次
        //   （触发 ensureLoaded → CkeyMoudleInit → GenCKey，给 frida 预埋钩子的时机）。
        if (java.io.File("/sdcard/ckey_wait").exists()) {
            Thread {
                android.util.Log.i("PalmTV", "[ckey-wait] 预热 genCKey（挂起点交给 ensureLoaded 内层等待）")
                runCatching {
                    com.rickyone.palmtv.data.YspAndroidCKey.genCKey(
                        applicationContext, System.currentTimeMillis() / 1000, "2024075403"
                    )
                }.onFailure { android.util.Log.w("PalmTV", "[ckey-wait] 预热失败: $it") }
            }.start()
        }

        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // ★ 2026-10-01（用户要求：媒体播控卡片）：Android 13+ 需先有通知权限，否则前台服务的媒体通知
        //   （通知栏/锁屏播控卡片）不显示。只在未授权时请求一次；拒绝也不影响播放，只是看不到卡片。
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            androidx.core.content.ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.POST_NOTIFICATIONS
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
        }

        // 前后台：与鸿蒙 `onPageHide` / `onPageShow` 对齐（退后台暂停，回前台续播）
        lifecycle.addObserver(LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> vm.onBackground()
                Lifecycle.Event.ON_START -> vm.onForeground()
                else -> {}
            }
        })

        setContent {
            PalmTvTheme {
                val ui by vm.ui.collectAsState()
                // ★★ 2026-10-04：**设备分流**（方案 A：同一个 APK）★★
                //   TV（Android TV / 电视盒子 / 系统声明了 Leanback / **没有触摸屏**）⇒ `TvHomeScreen`
                //   （焦点/遥控优先、不做自定义源）；其余 ⇒ `MainScreen`（触摸/手势）。**业务层共用同一个 vm**。
                //   调试：`--ez force_tv true`（强制 TV UI）/ `--ez force_phone true`（强制手机 UI，
                //   用来在电视上验证触摸版，或排查"这台机器被判成 TV"）。
                // ⚠️ 用 `remember` 只判定一次：`hasSystemFeature` 每次组合都查一遍没必要，
                //   而且 `isTvDevice` 里有日志 —— 不记住就会在每次重组时刷一行（实测踩过）。
                val isTv = remember {
                    val forceTv = intent?.getBooleanExtra("force_tv", false) == true
                    val forcePhone = intent?.getBooleanExtra("force_phone", false) == true
                    when {
                        forceTv -> true
                        forcePhone -> false
                        else -> isTvDevice(applicationContext)
                    }
                }
                // ★ 2026-10-04（用户实测电视端卡跳）：TV 用"稳"的直播参数（落后 10s、不追播），
                //   手机保持"低延迟"（落后 6s、0.97~1.03× 追播）。见 `MainViewModel.setTvPlaybackMode`。
                LaunchedEffect(isTv) { vm.setTvPlaybackMode(isTv) }
                // ★★ 2026-10-07（回看调试开关，与 `--ez force_tv true` 同风格）★★
                //   `adb shell am start -n com.rickyone.palmtv/.MainActivity --ei replay_min 60`
                //   ⇒ 自动开播后，从"60 分钟前"开始**回看**（走央视频「安卓平台」链路的 playbacktime）。
                //   为什么要这个开关：TV 界面是**自绘网格**（没有可点的文本节点），自动化点不到节目单，
                //   有个 intent 入口就能把回看链路单独验证掉；用户手工复现/比对也方便。
                val replayMin = intent?.getIntExtra("replay_min", 0) ?: 0
                // ★ 2026-10-21：指定频道（自动化验证用）
                //   `--es debug_ch "CCTV-2 财经"` —— 名称与 `Channels` 里逐字一致
                //   ⚠️ 频道名带空格，`adb shell` 会把它拆开 ⇒ 优先用 **id**：`--es debug_id cctv2`
                val debugCh = intent?.getStringExtra("debug_ch")
                val debugId = intent?.getStringExtra("debug_id")
                LaunchedEffect(replayMin, debugCh, debugId) {
                    if (replayMin <= 0 && debugCh.isNullOrBlank() && debugId.isNullOrBlank()) {
                        return@LaunchedEffect
                    }
                    // 等自动开播把 activeChannelId 定下来（TV 界面由 `startTvDefaultChannel()` 触发）
                    var waited = 0
                    while (vm.ui.value.activeChannelId.isEmpty() && waited < 25_000) {
                        kotlinx.coroutines.delay(400); waited += 400
                    }
                    val want = when {
                        !debugId.isNullOrBlank() -> com.rickyone.palmtv.data.Channels.byId(debugId)
                        !debugCh.isNullOrBlank() ->
                            com.rickyone.palmtv.data.Channels.all.firstOrNull { it.name == debugCh }
                        else -> null
                    }
                    if (want != null) {
                        android.util.Log.i("PalmTV", "[debug] 切到频道：${want.name}（cnlId=${want.cnlId}）")
                        // ★ 2026-10-23 诊断开关：把首分片解出一帧存成 cache/probe.png（判"绿屏是否=加密"）
                        //   `--es debug_id cctv11 --ez dump_frame true`
                        if (intent?.getBooleanExtra("dump_frame", false) == true) {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                com.rickyone.palmtv.player.FrameProbe.dump(applicationContext, want)
                            }
                        }
                        vm.playChannel(want, userInitiated = true)
                        kotlinx.coroutines.delay(3000)
                    } else if (!debugId.isNullOrBlank() || !debugCh.isNullOrBlank()) {
                        android.util.Log.w("PalmTV", "[debug] 频道不存在：id=$debugId name=$debugCh")
                    }
                    kotlinx.coroutines.delay(2500)   // 让首次取流先落定，别和自动开播抢 playRequestId
                    if (replayMin > 0) {
                        vm.playReplayFrom(System.currentTimeMillis() / 1000 - replayMin * 60L, newRef = true)
                    }


                }
                // ★★ 2026-10-01（用户实测：横屏非全屏看不到状态栏的时间/电量）★★
                //   主题里已声明 `windowLightStatusBar=false`（浅色图标），竖屏正常；
                //   但系统/宿主（桌易通）在**旋转后**可能把状态栏藏起来或把图标翻成深色，
                //   而我们原先只在 `ui.fullscreen` 变化时才设置一次 ⇒ 旋转时不会被重新断言。
                //   ⇒ 把**配置（旋转/尺寸）**也作为 key：每次旋转都重新 show 一次 + 重新钉死浅色图标。
                //   ⚠️ 若宿主在横屏**主动隐藏**状态栏（桌易通/HarmonyOS 常见做法），应用侧无法强制显示，
                //      这种情况只能靠我们自己的顶部状态行承载同样信息（本应用一直有画）。
                val cfg = androidx.compose.ui.platform.LocalConfiguration.current
                LaunchedEffect(ui.fullscreen, cfg.orientation, cfg.screenWidthDp, cfg.screenHeightDp) {
                    val ctl = WindowInsetsControllerCompat(window, window.decorView)
                    // ★ 2026-10-01（用户实测：横屏非全屏时看不到系统栏的时间/电量）：
                    //   本应用是**深色主题** ⇒ 系统栏图标必须是**浅色（白）**才看得见。
                    //   竖屏能看见、横屏看不见，说明图标外观被系统/兼容层在旋转后翻成了深色
                    //   ⇒ 两种状态下都显式钉死"浅色图标"（与鸿蒙全屏/非全屏都保持白字同口径）。
                    ctl.isAppearanceLightStatusBars = false
                    ctl.isAppearanceLightNavigationBars = false
                    if (ui.fullscreen) {
                        ctl.hide(WindowInsetsCompat.Type.systemBars())
                        ctl.systemBarsBehavior =
                            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        // ★★ 2026-10-01（复刻鸿蒙 `toggleFullscreen()`）★★
                        //   鸿蒙进全屏：`setPreferredOrientation(AUTO_ROTATION_LANDSCAPE)` ——
                        //   **忽略系统旋转锁**，只在两个横屏方向间跟随重力翻转 ⇒ 全屏必须是横的。
                        //   安卓对应常量 = SCREEN_ORIENTATION_SENSOR_LANDSCAPE（sensor + 仅横屏）。
                        requestedOrientation =
                            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    } else {
                        ctl.show(WindowInsetsCompat.Type.systemBars())
                        // 退出全屏：鸿蒙回到 `AUTO_ROTATION`（跟随传感器）⇒ 等价于 manifest 的 fullSensor
                        requestedOrientation =
                            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                    }
                }
                if (isTv) {
                    // ★★★ 2026-10-22（用户要求"sp → dp 相对单位"）★★★
                    //   TV 界面里有一两百处绝对 sp/dp（24sp 标题、46dp 行高、170dp 时间列…），
                    //   逐个改成 `maxWidth * 比例` 既易错又难维护。
                    //   等效且零风险的写法：**把 TV 子树的 density 按屏宽缩放**，
                    //   使 TV 布局**永远看到恒定的 1280x720dp 设计空间**（= 720p 电视）。
                    //     真机 1442dp 宽 ⇒ k=1.13（同一套比例，像素更大）
                    //     模拟器 640dp 宽 ⇒ k=0.5 （同一套比例，整体缩小 ⇒ 与真机观感一致）
                    //   ⇒ 效果等价于"所有尺寸都是屏宽的比例值"，但不用改一处 sp/dp。
                    androidx.compose.foundation.layout.BoxWithConstraints {
                        val base = androidx.compose.ui.platform.LocalDensity.current
                        val k = (maxWidth.value / 1280f).coerceIn(0.45f, 2.5f)
                        androidx.compose.runtime.CompositionLocalProvider(
                            androidx.compose.ui.platform.LocalDensity provides
                                androidx.compose.ui.unit.Density(base.density * k, base.fontScale)
                        ) {
                            com.rickyone.palmtv.ui.tv.TvHomeScreen(
                                vm = vm, ui = ui, activity = this@MainActivity
                            )
                        }
                    }
                } else {
                    MainScreen(vm = vm, ui = ui)
                }
            }
        }
    }
}

/**
 * ★★ 2026-10-04：是不是 TV 设备（决定走哪套 UI）★★
 *
 * 判据（按可靠性排序）：
 *   ① `FEATURE_LEANBACK` —— Android TV / Google TV / 电视盒子在系统里声明 `android.software.leanback`。
 *      这是"系统特性"，**同一台设备恒定**（TV 恒 true、手机恒 false），商店判定 TV 应用也用它 ⇒ 主判据；
 *   ② `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` —— 当前配置就是电视界面 ⇒ 辅助判据
 *      （理论上会随外接显示 / 桌面模式变化，所以不单独用）；
 *   ③ ★★ 2026-10-22：**没有触摸屏** ⇒ 也按 TV 处理（`FEATURE_TOUCHSCREEN == false`）★★
 *      原因：国产电视 / 老盒子大量是**AOSP 定制**（无 GMS、不少也不声明 `leanback`），
 *      于是 ①② 都判 false ⇒ 装的是**手机 UI（要触摸）**，遥控器根本没法操作。
 *      这类设备几乎必然**没有触摸屏**（电视/盒子）而手机/平板必然有 ⇒ 这条判据能把它们救回来。
 *      ⚠️ 反例风险：极少数"无触摸"的奇葩设备（如某些广告机）会进 TV UI —— 这对本应用无害
 *      （TV UI 也能被鼠标/遥控操作）；真判错时可用调试开关 `--ez force_phone true` 强制手机 UI。
 *   ④ 调试开关：`--ez force_tv true` / `--ez force_phone true`（见调用处）。
 *
 * ⚠️ 这些都是**运行时**判断，不是"安装时"判断：
 *   · "**能不能装**到 TV / 手机"由 manifest 的 `uses-feature ... required="false"` 决定（否则其中一类装不上）；
 *   · "**能不能出现在 TV 桌面**"由 `LEANBACK_LAUNCHER`（TV 桌面只列声明了它的应用）决定
 *     —— ⚠️ 无 leanback 的国产电视**不会有这张卡片**，要从"应用列表/U 盘安装器"里打开；
 *   · "TV 桌面上显示什么图"由 `android:banner`（320×180）决定，不是 `icon`。
 */
private fun isTvDevice(ctx: android.content.Context): Boolean {
    val pm = ctx.packageManager
    if (pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK)) return true
    val um = ctx.getSystemService(android.content.Context.UI_MODE_SERVICE) as? android.app.UiModeManager
    if (um?.currentModeType == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION) return true
    val touch = pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_TOUCHSCREEN)
    Log.i("[tv] 设备判定：leanback=false / uiMode=${um?.currentModeType} / touchscreen=$touch ⇒ ${if (touch) "手机 UI" else "TV UI"}")
    return !touch
}
