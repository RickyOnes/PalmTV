using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;

namespace PalmTVDesktop;

public partial class MainWindow : Window
{
    TvChannel? _current;
    bool _fullscreen;
    // ★ 单文件发布下, AppDir 指向临时解压目录(无伴生文件). 改用 exe 真实所在目录.
    static readonly string AppDir = System.IO.Path.GetDirectoryName(Environment.ProcessPath)!;
    Rect _normalRect;
    Rect _fsRestoreRect;      // ★ 全屏专用: 退出全屏时的位置大小 (不与 BtnMaxRestore 的 _normalRect 混淆)
    WindowState _fsRestoreState;  // ★ 全屏专用: 退出全屏时的窗口状态
    CancellationTokenSource? _loadCts;
    // ★ 2026-11-05：`_proxyProcess` 已删除（不再启动 Go 代理，见 StartProxy 的说明）

    /// <summary>true = 当前这台**已经出画**（VLC `Playing`）。出画后缓冲事件不再覆盖状态栏。</summary>
    volatile bool _channelLive;
    /// <summary>出画后状态栏要显示的文案（"播放中 · X" / "回看中 · X" / "时移中 · -10 分钟"）。</summary>
    string _playbackLabel = "";
    // ★ 原 _signatureTcs / _tokenRndTcs 已随「签名原生化」删除：cKey(进程内 V8) / rnd / signature / yspticket
    //   全部由原生算（见 PalmTVCore.cs），页面不再被要求计算签名 ⇒ 不需要 TCS 回传通道。
    // hls.js 致命错误恢复
    // ★ 2026-11-05：kvcollect 心跳（_kvTimer/_kvPid/_kvM3u8）已删除 ——
    //   它只服务 Web/PC 链路的鉴权会话，那条链已整体移除。
    // 节目信息刷新
    System.Threading.Timer? _epgTimer;
    string _playingChannelName = "";
    // ★ EPG 缓存 + 心跳刷新 (2026-09-04): 拉取失败也能用本地时钟推进"正在/即将"
    List<EpgProgram> _epgCache = new List<EpgProgram>();
    DateTime _lastEpgFetch = DateTime.MinValue;

    // ★★ 调试日志总开关 (2026-09-04)
    //   false(发布) = 屏蔽全部调试日志:
    //     · 不再写 player-debug.log / proxy.log
    //     · 不再接收并转发页面的 {log}/{err} 诊断消息(含 Go 代理注入的 CMG 探针), 在 JSON 解析前直接丢弃
    //     · 状态栏只保留用户可见提示, 即 Log(msg, userFacing: true) 的那些调用
    //   true(排查) = 恢复旧行为(全量落盘 + 状态栏精简过滤)。
    //   ★ 用 static readonly 而非 const, 避免 DEBUG_LOG=false 时编译期产生"无法访问的代码"警告。
    //   ★ 2026-09-20: 改为**命令行按需开启** —— `WinPalmTV.exe --log` 即写全量 player-debug.log。
    //     默认关闭：日志按帧落盘（实测 40 秒 1.4 万行 / 约 1MB），常态开着既费 I/O 又刷屏状态栏。
    static readonly bool DEBUG_LOG = Environment.GetCommandLineArgs().Any(a => a == "--log");
    //   ★ 2026-09-20: `--dec` = 启用**本地解密代理**(127.0.0.1:18899) 并打印本地播放地址。
    //     目的是让 P2 能先独立验证"原生解密 + 明文 HLS"这条链路（不改变页面播放行为），
    //     验证通过后再让 VLC 直接吃这个地址、把 WebView2 移出播放链路。
    static readonly bool DEC_TEST = Environment.GetCommandLineArgs().Any(a => a == "--dec");
    LocalDecryptServer? _decServer;

    // ==================== P2b：LibVLC 播放模式（`--vlc`）====================
    // ★ 默认关闭 ⇒ 与现有 WebView2 播放**完全并行、互不影响**；画面验收通过后再整块拆掉 WebView2（P3）。
    //   设计：播放器只吃**明文 HLS** —— 央视频走本地解密代理(18899)，地方台走 Go 代理(18888) 的 /jstv.m3u8。
    // ★★★ P3b（2026-09-21）：**VLC 是唯一播放器** —— `--web` 逃生门已删除（用户验收"播放正常"后按要求摘除）。
    //   页内播放路径自此**不可达**；WebView2 的初始化代码成为待删死代码，下一步按块清理（每块都保持可编译）。
    const bool VLC_MODE = true;

    /// <summary>
    /// P3b：WebView2 **不再创建**（页内播放已摘除，VLC 是唯一播放器）。
    /// 用 `static readonly` 而非常量 ⇒ 不产生 CS0162 警告，整段初始化代码得以编译保留、待最终机械清理。
    /// （P3b 收尾：WebView2 相关代码/元素/包已全部删除，本节注释保留作历史记录。）
    ///    否则 CoreWebView2 为 null 会抛 NullReferenceException（已逐个核对过）。
    /// </summary>
    // ★ 2026-09-21：两条取流路径（CMG / 地方台）都已在最前面加了 `if (VLC_MODE) { …直接起播…; return; }` 早退
    //   ⇒ 这些调用点随后已**全部删除**（含两段"导航准备"死代码），WebView2 彻底移出工程。
    //   ⚠️⚠️ 教训（勿重犯）：**必须先给散点加保护/早退，再关这个总闸**；上一次顺序做反 ⇒ 一关就 NRE。
    //   ⚠️ 配套：`--ch` 自动播放原来在初始化方法尾部，已搬到构造器（否则停用后它会静默失效）。
    LibVLCSharp.Shared.LibVLC? _vlc;
    LibVLCSharp.Shared.MediaPlayer? _vlcMp;
    string _vlcUrl = "";

    /// <summary>
    /// ★★ 2026-11-06（用户要求：参照安卓「播放参数：全托管」）★★
    /// <c>true</c> = 直播**不注入任何缓冲/位置参数**，全部交 VLC 默认 —— 对应安卓 `PalmPlayer.FULL_AUTO_LIVE = true`
    /// （安卓那边直播不挂 `LiveConfiguration`，位置策略交 Media3 默认；用户实测那版缓冲少、CCTV-4K 正常）。
    ///
    /// 为什么这么改：桌面此前是**按台手动给缓存**（普通 1200ms / 4K-8K 8000ms），
    /// 与安卓当年"按窗口算 targetOffset"是同一类"应用侧强推策略"的做法，前后调过四轮
    /// （1200 → 5000 → 3000 → 8000），4K 台仍是幻灯片 ⇒ 改为把调度权还给播放器。
    /// ⚠️ 想回退只需把这个开关改回 <c>false</c>（会恢复"全局 1200ms + 4K/8K 8000ms"的旧行为）。
    /// </summary>
    static readonly bool FULL_AUTO_LIVE = true;

    /// <summary>★ 2026-09-24：VLC 启动参数（EnsureVlc 与后台预热**必须一致**，别在一边单独改）。</summary>
    static readonly string[] VlcArgs = BuildVlcArgs();

    static string[] BuildVlcArgs()
    {
        var args = new List<string>
        {
            "--no-video-title-show",
            "--no-mouse-events",        // ★ VLC 自己的鼠标处理会吃掉点击（还试图切全屏并失败）⇒ 关掉，交给我们
            /* ★★ 2026-11-06：**开启硬件解码** ★★
             *   实测 4K 分片：下载 99~240ms、sm4c 解密 155~232ms（都很快），但分片间隔 3.5~7 秒
             *   ⇒ 瓶颈在**解码/渲染**，不是网络也不是解密。4K H.265 用 CPU 软解必然"幻灯片"。
             *   `any` = 自动挑可用的硬解（D3D11VA / DXVA2 / NVDEC）；显卡不支持时 VLC 自动回退软解。 */
            /* ★ 2026-11-06：实测 `any` 没被采用（日志里是 `frame thread mode with 5 threads` = 软解）。
             *   Windows 上显式指定 **d3d11va**；显卡/驱动不支持时 VLC 会自动回退软解（不会黑屏）。 */
            "--avcodec-hw=d3d11va",
            /* ★ 2026-11-06：关掉去隔行（默认 auto 会在 4K 上做软去隔行，直接吃满一个核）。 */
            "--deinterlace=0",
        };
        /* ★★ 2026-11-06：**缓冲参数默认不再注入**（全托管，见 FULL_AUTO_LIVE）★★
         *   原来这里写死 1200ms（直播/本地文件都改），后来又在起播处给 4K/8K 抬到 8000ms。
         *   VLC 的 HLS 模块本来就会按清单的 `#EXT-X-TARGETDURATION` 自己决定取片节奏与缓冲；
         *   应用侧硬塞一个值只会覆盖掉它的规划（这正是安卓"全托管"要避开的坑）。 */
        if (!FULL_AUTO_LIVE)
        {
            args.Add("--network-caching=1200");
            args.Add("--live-caching=1200");
            args.Add("--file-caching=1200");
        }
        return args.ToArray();
    }

    static LibVLCSharp.Shared.LibVLC? _vlcWarm;

    /// <summary>★ 2026-09-24：**后台预热 VLC 原生库**（首播卡顿的主因之一）。
    /// 只做"定位 libvlc.dll + Core.Initialize（载入 dll、扫插件）+ 建一个 LibVLC 实例"，
    /// **不碰 VideoView / MediaPlayer / HWND** ⇒ 可以在后台线程做；
    /// 首次播放时 `EnsureVlc()` 直接复用这个实例（省掉 0.3~1.5s 的首次载入）。</summary>
    static void WarmVlcLib()
    {
        try
        {
            var flat = System.IO.Path.Combine(AppDir, "libvlc");
            var legacy = System.IO.Path.Combine(AppDir, "libvlc", "win-x64");
            string? dir = System.IO.File.Exists(System.IO.Path.Combine(flat, "libvlc.dll")) ? flat
                        : System.IO.File.Exists(System.IO.Path.Combine(legacy, "libvlc.dll")) ? legacy : null;
            if (dir != null) LibVLCSharp.Shared.Core.Initialize(dir);
            if (_vlcWarm == null) { _vlcWarm = new LibVLCSharp.Shared.LibVLC(VlcArgs); }
        }
        catch { /* 预热失败无所谓：首次播放时 EnsureVlc 会照旧自己来一遍 */ }
    }

    // ==================== ★★ 状态栏状态机（2026-11-06）★★ ====================
    //   用户要求：换台 / 缓冲 / 严重错误必须在左下状态栏看得见。
    //   三档配色：绿=正常（播放中/就绪）、黄=忙（切换中/取流中/缓冲中）、红=严重错误。
    //   原来的 `StatusText.Text = ...`（18 处）只有文字、颜色恒为绿 ⇒ 现在统一走 SetStatus。
    enum StatusKind { Normal, Busy, Error }

    static readonly System.Windows.Media.SolidColorBrush StatusNormal = new(System.Windows.Media.Color.FromRgb(0x4C, 0xAF, 0x50));
    static readonly System.Windows.Media.SolidColorBrush StatusBusy = new(System.Windows.Media.Color.FromRgb(0xFF, 0xB3, 0x00));
    static readonly System.Windows.Media.SolidColorBrush StatusError = new(System.Windows.Media.Color.FromRgb(0xFF, 0x52, 0x52));

    /// <summary>节目条前缀「正在播出：」的红色（= XAML 里的 #E94560，回看结束要还原成它）</summary>
    static readonly System.Windows.Media.SolidColorBrush NowLabelRed = new(System.Windows.Media.Color.FromRgb(0xE9, 0x45, 0x60));
    /// <summary>节目条前缀「回看中：」的蓝色（对齐安卓 `Palette.Primary` 一类的主蓝，与"接下来"同色系）</summary>
    static readonly System.Windows.Media.SolidColorBrush ReplayLabelBlue = new(System.Windows.Media.Color.FromRgb(0x4F, 0xC3, 0xF7));

    /// <summary>写状态栏（线程安全；可从任意线程调用）。</summary>
    void SetStatus(string text, StatusKind kind = StatusKind.Normal)
    {
        try
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                StatusText.Text = text;
                StatusText.Foreground = kind switch
                {
                    StatusKind.Busy => StatusBusy,
                    StatusKind.Error => StatusError,
                    _ => StatusNormal,
                };
            }));
        }
        catch { }
    }

    /// <summary>初始化 LibVLC（幂等）。**必须在 UI 线程**调用（MediaPlayer 要挂到 VideoView）。</summary>
    void EnsureVlc()
    {
        if (_vlcMp != null) return;
        // ★★★ 2026-09-21：发布包的 libvlc 目录**已扁平化**（`libvlc\` 而不是 `libvlc\win-x64\`）⇒
        //   LibVLCSharp 的默认搜索路径失效，必须显式告诉它目录（它会据此找 libvlc.dll 并设好 plugins 路径）。
        //   ⚠️ 但**调试输出仍是 NuGet 原样的 `libvlc\win-x64\`** ⇒ 两个都认（谁有 libvlc.dll 用谁），
        //      否则扁平化会把现在能用的调试版弄坏。
        try
        {
            var flat = System.IO.Path.Combine(AppDir, "libvlc");
            var legacy = System.IO.Path.Combine(AppDir, "libvlc", "win-x64");
            string? dir = System.IO.File.Exists(System.IO.Path.Combine(flat, "libvlc.dll")) ? flat
                        : System.IO.File.Exists(System.IO.Path.Combine(legacy, "libvlc.dll")) ? legacy : null;
            if (dir != null) LibVLCSharp.Shared.Core.Initialize(dir);
            else
            {
                Log($"[vlc] 未找到 libvlc.dll（libvlc\\ 与 libvlc\\win-x64\\ 都没有）");
                SetStatus("播放组件缺失（libvlc），无法播放", StatusKind.Error);
            }
        }
        catch (Exception ex)
        {
            Log($"[vlc] Core.Initialize 失败: {ex.Message}");
            SetStatus("播放组件初始化失败（libvlc），无法播放", StatusKind.Error);
        }
        _vlc = _vlcWarm ?? new LibVLCSharp.Shared.LibVLC(VlcArgs);   // ★ 复用后台预热好的实例（见 WarmVlcLib）
        _vlcWarm = null;
        _vlc.Log += (_, e) =>
        {
            if (DEBUG_LOG && e.Level <= LibVLCSharp.Shared.LogLevel.Error) Log($"[vlc] {e.Level}: {e.Message}");
        };
        _vlcMp = new LibVLCSharp.Shared.MediaPlayer(_vlc);
        VlcView.MediaPlayer = _vlcMp;
        // ★ 缓冲进度进状态栏（用户要求"缓冲时要有显示"）：<100% 时黄字，回到 100% 由起播成功覆盖
        /* ★★ 2026-11-06 修（用户报"出画后一直显示缓冲 96%"）★★
         *   **直播流的 `Buffering.Cache` 永远到不了 100%**（HLS 滚动窗口，实测稳定卡在 96%），
         *   原实现每次缓冲事件都写"缓冲中 96%"，把起播成功写的"播放中 · X"覆盖掉。
         *   ⇒ 出画（`Playing` 事件）之后，缓冲事件一律不再动状态栏。 */
        _vlcMp.Buffering += (_, e) =>
        {
            if (_channelLive) return;
            if (e.Cache < 100) SetStatus($"缓冲中 {e.Cache:F0}%", StatusKind.Busy);
        };
        // ★ 真正开始播放 ⇒ 恢复"播放中/回看中/时移中"文案（`_playbackLabel` 由各起播入口设置）
        _vlcMp.Playing += (_, _) =>
        {
            _channelLive = true;
            if (!string.IsNullOrEmpty(_playbackLabel))
                SetStatus(_playbackLabel, StatusKind.Normal);
        };
        /* ★★★ 2026-11-06（用户报"回看播完就停住，不自动播下一档"）★★★
         *   回看走的是**带 `#EXT-X-ENDLIST` 的整段 VOD 清单** ⇒ 播到末尾 VLC 会正常结束并抛 `EndReached`。
         *   原来没人接这个事件 ⇒ 停在 ENDED（最后一帧/黑屏），必须手动再点一次节目单。
         *   对齐安卓 `MainViewModel.autoNextReplay()`（HANDOFF「回看播完停在黑屏，不能接着看下一档」）：
         *     · 节目单里**排在当前回看节目之后**、**已播完**、**可回看**的那一档 ⇒ 直接接着播；
         *     · 找不到（已是最新一档）⇒ 回直播，别停在黑屏。
         *   ⚠️ 回调在 VLC 的线程上 ⇒ 必须切回 UI 线程（要动播放器 / 界面）。
         *   ⚠️ 直播流不会自然结束；时才移（无 ENDLIST）也走不到这里 ⇒ 用 `_replayProg` 判"是不是节目回看"。 */
        _vlcMp.EndReached += (_, _) =>
        {
            try { Dispatcher.BeginInvoke(new Action(() => _ = OnVlcEndReachedAsync())); } catch { }
        };
        Log($"[vlc] LibVLC {_vlc.Version} 已初始化（缓冲策略：{(FULL_AUTO_LIVE ? "全托管/VLC 默认" : "按台指定")}）");
        // ★★ 视频区交互 = **低层鼠标钩子（唯一路径）** ★★
        //   证据（2026-09-20 用户提供的 VLC 日志）：双击时 VLC 自己的 vout 窗口收到了事件 ——
        //     `VoutDisplayEvent 'mouse button' 0` ×2 → `'double click'` → `'fullscreen' 0`
        //   而我们的 `VideoArea_*` 处理器**一行都没打** ⇒ VLC 的视频窗口吃掉了输入
        //   ⇒ `VideoView.Content` 覆盖层这条路**不成立**（别再回去改它）。
        //   ⚠️ 历史事故：钩子里 GetModuleHandle 误写 user32.dll（实际在 kernel32）⇒ 异常打断初始化 ⇒ 连播放都不能。
        //     现已 kernel32 + try/catch 兜底，不会再影响播放。
        //   ⚠️ 覆盖层里**不许**再挂鼠标事件（两处同时触发会各切一次全屏 = 看起来没反应）。
        InstallVideoMouseHook();
    }

    /// <summary>★ 2026-09-23：**源标错 PAR** 的台 ⇒ 强制画面宽高比（键 = 频道名；缺省 = 不干预，按流里的 SAR 自适应）。
    /// 依据（鸿蒙端同轮实测）：哈尔滨两台编码 640x480 且 SPS **未声明 SAR** ⇒ VLC 只能按 4:3 摆，
    /// 而内容是宽屏压扁的 ⇒ 看着"宽度不够/被拉长"。
    /// ⚠️ 别放宽成"SD 一律 16:9"：农林卫视 SPS 明确声明 SAR 16:15（真 4:3），一刀切会把它拉宽。</summary>
    static readonly Dictionary<string, string> AspectOverride = new()
    {
        ["哈尔滨电影"] = "16:9",
        ["哈尔滨综合"] = "16:9",
        ["农林卫视"] = "16:9",
    };

    static string? AspectOf(TvChannel ch) => AspectOverride.TryGetValue(ch.Name, out var a) ? a : null;

    /// <summary>用 VLC 播放一个流地址（明文 HLS）。aspect 非空 ⇒ 强制宽高比（`:aspect-ratio`）。</summary>
    /* ★★ 2026-09-24：Stop 挪线程池（**只挪 Stop，不挪 Media/Play**）★★
     * 实测（用户）：切到/切离香港卫视时 `Stop()` 在 UI 线程阻塞 **7068ms**，窗口直接"未响应"。
     * 病因：慢源把 VLC 的 input 线程挂在网络读上，`libvlc_media_player_stop` 要等它退。
     * ⚠️ 与 09-23 那次回滚的区别（务必看清）：那次把 **Stop 和 Play 一起**放进 `Task.Run` ⇒ 画面再也没起来；
     *    这里只把 Stop 挪走，`Media` 创建与 `Play()` **仍留在 UI 线程** ⇒ 不碰 VideoView 的 HWND 绑定假设。
     *    Stop 期间又换台 ⇒ 只记"最新一次"，等 Stop 回来再起播（防止并发把播放器搞乱）。 */
    bool _vlcStopping;
    string? _pendingUrl, _pendingLabel, _pendingAspect;

    async Task StopOnPoolAsync()
    {
        if (_vlcMp == null) return;
        _vlcStopping = true;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        await Task.Run(() => { try { _vlcMp?.Stop(); } catch { } });
        long ms = sw.ElapsedMilliseconds;
        _vlcStopping = false;
        if (ms > 200) { Log($"[vlc] ★ Stop() 在后台线程阻塞 {ms}ms（UI 已不再被拖住）"); }
    }

    async Task PlayVlc(string url, string label, string? aspect = null)
    {
        EnsureVlc();
        /* ⚠️⚠️ 2026-09-23 已回滚一次尝试（**别再这样改**）：
         *   原方案想把 `Stop()`/`Play()` 挪到 `Task.Run` 线程池，以规避"慢源 ⇒ Stop() 同步阻塞 ⇒
         *   UI 未响应"。**实测后果：CCTV-5 起播变成 `[tune] 无信号（VLC 12s 未起播）`** ——
         *   即"能记日志、但画面再也没起来"（`[dec] seg 已解密` 一行都没有）。
         *   原因待查（疑与 LibVLCSharp 的 `Media` 生命周期 / VideoView 的 HWND 绑定线程有关）。
         *   ⇒ 先恢复原样（这是**已验证可用**的版本）；真要解决卡顿，另找不触碰这几行调用的办法
         *      （例如本文件里 `IptvSourceAliveAsync` 那种"起播前带超时的预检"，它不碰 VLC 内部线程）。 */
        if (_vlcStopping) { _pendingUrl = url; _pendingLabel = label; _pendingAspect = aspect; Log("[vlc] Stop 进行中 ⇒ 本次换台排队等它回来"); return; }
        await StopOnPoolAsync();
        if (_pendingUrl != null)
        {
            Log("[vlc] 排队的新台优先起播");
            var pu = _pendingUrl; var pl = _pendingLabel; var pa = _pendingAspect;
            _pendingUrl = null; _pendingLabel = null; _pendingAspect = null;
            await PlayVlc(pu, pl, pa);
            return;
        }
        _vlcUrl = url;
        using var media = new LibVLCSharp.Shared.Media(_vlc!, new Uri(url));
        /* ★★ 2026-11-06（用户要求：参照安卓「播放参数：全托管」）★★
         *   原来这里按"是不是 4K/8K"给 `:network-caching` / `:live-caching`（8000ms / 1200ms）——
         *   与安卓旧版"按窗口算 targetOffset"同源：应用侧替播放器决定位置。
         *   安卓改成全托管后 CCTV-4K 反而正常 ⇒ 桌面也交还给 VLC 自己按清单调度。
         *   ⚠️ 回退开关 = `FULL_AUTO_LIVE`（改回 false 即恢复按台缓存）。
         *   同时没动 `--avcodec-hw=d3d11va` 与 `--deinterlace=0`：那两个是**解码**参数，与"位置/缓冲"无关。 */
        if (!FULL_AUTO_LIVE)
        {
            bool bigStream = label.Contains("4K", StringComparison.OrdinalIgnoreCase)
                          || label.Contains("8K", StringComparison.OrdinalIgnoreCase);
            int cacheMs = bigStream ? 8000 : 1200;
            media.AddOption($":network-caching={cacheMs}");
            media.AddOption($":live-caching={cacheMs}");
        }
        /* ★ 实测（用户）：`:aspect-ratio` 作为 **media 选项无效**（三台仍按原比例）⇒ 改用**播放器属性**。
         *   `null` = 不干预（按流里的 SAR 自适应）——必须显式设，否则会沿用上一台的强制值。 */
        try { _vlcMp!.AspectRatio = aspect; } catch { }
        var swPl = System.Diagnostics.Stopwatch.StartNew();
        _vlcMp!.Play(media);
        long msPl = swPl.ElapsedMilliseconds;
        if (msPl > 200) { Log($"[vlc] ★ Play() 阻塞 {msPl}ms（UI 线程）"); }
        VlcView.Visibility = Visibility.Visible;   // ★ P3b：WebView2 已删 ⇒ 不再需要 airspace 互斥处理
        Log($"[vlc] 播放 {label} ← {url[..Math.Min(100, url.Length)]}");
        _ = WatchVlcStartAsync(_current?.Name ?? label);      // ★ 起播看门狗（无信号 ⇒ 提示 + 回退上一台）
    }

    void StopVlc()
    {
        /* ★ 诊断打点（2026-09-23）：`Stop()` 是**同步**调用，慢源的 input 线程还没退 ⇒ 会挂住 UI 线程。
         *   >200ms 就打日志 ⇒ 下次"假死"复现时能直接指认是不是它（别凭猜改线程模型，见 PlayVlc 上方注释）。 */
        var swStop = System.Diagnostics.Stopwatch.StartNew();
        /* ★ 2026-09-24：**同步 Stop 会挂住 UI**（实测 7068ms）⇒ 挪线程池、不等它（同 PlayVlc 口径）。
         *   调用方（回退原台等）随后会走 `PlayVlc`，那里会 await 自己的 Stop 并在其完成后起播。 */
        _vlcStopping = true;
        if (_vlcMp != null) { _ = Task.Run(() => { try { _vlcMp?.Stop(); } catch { } }).ContinueWith(_ => { _vlcStopping = false; }); }
        else { _vlcStopping = false; }
        long msStop = swStop.ElapsedMilliseconds;
        if (msStop > 200) { Log($"[vlc] ★ Stop() 发起耗时 {msStop}ms"); }
        _vlcUrl = "";
        VlcView.Visibility = Visibility.Collapsed;
    }

    // ==================== ★ 无信号处理 / VLC 路径缺失的交互（原来由页面 postMessage 驱动）====================

    // ============ ★ 视频区鼠标事件：**备用方案**（低层鼠标钩子，当前**未启用**）============
    //   ★ 结论更正（用户实测）：把透明 Grid 放进 `VideoView.Content` 是**可用**的 ——
    //     之前判它"收不到点击"，是因为当时跑的是 **XAML 编译失败(MC3072) 留下的旧 exe**（界面还是旧的）。
    //     ⇒ 正常用 XAML 那层覆盖层即可，**不需要**这个钩子。
    //   ★ 保留原因：万一某些环境/驱动下覆盖层失效，改成调 `InstallVideoMouseHook()` 即可兜底。
    //   ⚠️ 与覆盖层**不可同时启用**（各触发一次 ⇒ 双击被切两次 = 看起来没反应）。
    //   ⚠️ 启用时委托必须保引用（`_mouseProc` 字段），否则被 GC 回收后钩子**静默失效**。
    //     WH_MOUSE_LL 按屏幕坐标判区域；**不拦消息**（始终 CallNextHookEx），不影响其它程序。
    const int WH_MOUSE_LL = 14;
    const int WM_LBUTTONDOWN = 0x0201, WM_RBUTTONUP = 0x0205;
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    static extern System.IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, System.IntPtr hMod, uint dwThreadId);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(System.IntPtr hhk);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern System.IntPtr CallNextHookEx(System.IntPtr hhk, int nCode, System.IntPtr wParam, System.IntPtr lParam);
    // ★ 全局钩子必须做"归属判定"，否则别的窗口盖在视频区上时也会被当成视频区点击（见 VideoMouseHookProc）
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr WindowFromPoint(HookPoint pt);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint gaFlags);
    const uint GA_ROOT = 2;
    // ★ GetModuleHandle 在 **kernel32.dll**（不是 user32.dll！写错会抛 EntryPointNotFoundException，
    //   若又跑在初始化路径上就会把播放一起打断 —— 2026-09-20 踩过）
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
    static extern System.IntPtr GetModuleHandle(string? lpModuleName);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetDoubleClickTime();

    delegate System.IntPtr LowLevelMouseProc(int nCode, System.IntPtr wParam, System.IntPtr lParam);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct HookPoint { public int X; public int Y; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct MouseHookData { public HookPoint pt; public uint mouseData; public uint flags; public uint time; public System.IntPtr dwExtraInfo; }

    System.IntPtr _mouseHook = System.IntPtr.Zero;
    LowLevelMouseProc? _mouseProc;              // ★ 必须保引用：被 GC 回收后钩子会静默失效
    DateTime _lastDownAt = DateTime.MinValue;
    HookPoint _lastDownPt;

    void InstallVideoMouseHook()
    {
        if (_mouseHook != System.IntPtr.Zero) return;
        try
        {
            _mouseProc = VideoMouseHookProc;
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, GetModuleHandle(null), 0);
        }
        catch (Exception ex)
        {
            // ★ 任何异常都吞掉：这个调用绝不允许影响播放（它就是上次"不能播放"的元凶）
            Log($"[交互] 钩子安装异常（已忽略，不影响播放）: {ex.Message}");
            return;
        }
        int err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
        /* ★ 2026-09-30：**成功的常态不再上屏**（原来 userFacing=true ⇒ 它会在"开始播放"之后
           把状态栏覆盖成"[交互] 视频区已启用…"，且要等下一次点击才恢复 ⇒ 用户看到的是
           "第一次点台后提示不消失、再点一次才显示播放中"）。
           现在只有"真的装失败"才提示（那时确实需要用户知道双击/右键为什么没反应）。 */
        if (_mouseHook == System.IntPtr.Zero)
            Log($"[交互] 鼠标钩子安装失败 err={err} ⇒ 视频区双击/右键将不可用", true);
        else
            Log("[交互] 视频区已启用：双击全屏 / 右键菜单（低层鼠标钩子）");
    }

    System.IntPtr VideoMouseHookProc(int nCode, System.IntPtr wParam, System.IntPtr lParam)
    {
        try
        {
            if (nCode >= 0 && VlcView.Visibility == Visibility.Visible && VlcView.ActualWidth > 0)
            {
                var info = System.Runtime.InteropServices.Marshal.PtrToStructure<MouseHookData>(lParam);
                var tl = VlcView.PointToScreen(new Point(0, 0));
                var rect = new Rect(tl.X, tl.Y, VlcView.ActualWidth, VlcView.ActualHeight);
                // ★★★ 归属判定（两道，缺一不可）★★★
                //   WH_MOUSE_LL 是**全局**钩子：任何程序（文件管理器 / 浏览器 / 桌面）的鼠标事件都会经过这里。
                //   只凭"坐标落在 VlcView 矩形内"是不够的 —— 实测 BUG：视频在窗口下层播放时，在它上面打开
                //   文件管理器、双击目录 ⇒ 视频直接全屏（用户反馈）。
                //   ① 光标下那个窗口必须属于**本进程**（覆盖在视频上的其它程序会被挡在这里）；
                //   ② 本窗口（根窗口）当前必须是**前台窗口**（防止任务栏预览/幽灵点击之类）。
                var under = WindowFromPoint(info.pt);
                if (under == System.IntPtr.Zero) return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
                GetWindowThreadProcessId(under, out uint underPid);
                if (underPid != (uint)Environment.ProcessId)
                {
                    // ★ 静默忽略（**不要**在这里打日志：鼠标移动也走同一回调，打日志会刷爆 —— 实测刷了几十条）
                    return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
                }
                var fgRoot = GetAncestor(GetForegroundWindow(), GA_ROOT);
                var myRoot = GetAncestor(new System.Windows.Interop.WindowInteropHelper(this).Handle, GA_ROOT);
                if (fgRoot != myRoot) return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
                if (rect.Contains(info.pt.X, info.pt.Y))
                {
                    int msg = (int)wParam;
                    if (msg == WM_RBUTTONUP)
                    {
                        Log("[hook] 视频区右键");
                        Dispatcher.BeginInvoke(() => ShowVideoContextMenu());
                    }
                    else if (msg == WM_LBUTTONDOWN)
                    {
                        var now = DateTime.UtcNow;
                        bool dbl = (now - _lastDownAt).TotalMilliseconds < GetDoubleClickTime() &&
                                   Math.Abs(info.pt.X - _lastDownPt.X) < 10 && Math.Abs(info.pt.Y - _lastDownPt.Y) < 10;
                        _lastDownAt = now; _lastDownPt = info.pt;
                        if (dbl)
                        {
                            _lastDownAt = DateTime.MinValue;        // 防三连击触发两次
                            Log("[hook] 视频区双击 ⇒ 全屏切换");
                            Dispatcher.BeginInvoke(() => ToggleFullscreen());
                        }
                    }
                }
            }
        }
        catch { }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    /// <summary>上一台"确实播起来了"的频道 —— 无信号时回退到它</summary>
    TvChannel? _lastGoodChannel;

    // ★ 原 VideoArea_MouseLeftDown / VideoArea_MouseRightClick（XAML 覆盖层的处理器）已删除：
    //   实测 VLC 的 vout 窗口吃掉鼠标输入，那层覆盖层**收不到事件** ⇒ 交互统一由低层鼠标钩子负责
    //   （见 InstallVideoMouseHook，判据日志 `[交互] 视频区已启用：双击全屏 / 右键菜单（低层鼠标钩子）`）。

    /// <summary>视频区尺寸变化：保持 16:9 内接，避免上下/左右出现黑边</summary>
    void VideoHost_SizeChanged(object s, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width <= 0 || e.NewSize.Height <= 0) return;
        var h = Math.Min(e.NewSize.Height, e.NewSize.Width * 9.0 / 16.0);
        VlcView.Width = h * 16.0 / 9.0;
        VlcView.Height = h;
    }

    /// <summary>
    /// 起播看门狗：VLC 若 12s 内没进入 Playing ⇒ 判为**无信号**，状态栏提示并**回退到上一台**
    /// （含台标选中态同步）。对标鸿蒙"提示 + 继续播换台前的台"。
    /// 说明：本方法从 UI 线程启动且不 ConfigureAwait(false) ⇒ await 之后仍回到 UI 线程，可直接动控件。
    /// </summary>
    async Task WatchVlcStartAsync(string want)
    {
        if (!VLC_MODE || string.IsNullOrEmpty(want)) return;
        for (int i = 0; i < 25; i++)          // 25 × 200ms = 5s（**不是 12s**：自检阶段已判死绝大多数无信号）
        {
            await Task.Delay(200);
            if (_vlcMp == null) return;
            if (_current?.Name != want) return;                 // 已经切走/停止 ⇒ 本次看门狗作废
            var st = _vlcMp.State;
            if (st == LibVLCSharp.Shared.VLCState.Playing)
            {
                _lastGoodChannel = _current;                    // ★ 这一台确实出画了，记下来
                LastChannelStore.Save(_current?.Id);            // ★ 同时落盘：下次启动续播这一台
                return;
            }
            // ★ 状态明确失败 ⇒ 立即回退，不等满 5s
            if (st == LibVLCSharp.Shared.VLCState.Error || st == LibVLCSharp.Shared.VLCState.Ended ||
                st == LibVLCSharp.Shared.VLCState.Stopped) break;
        }
        if (_current?.Name != want) return;
        var prev = _lastGoodChannel;
        if (prev == null || prev.Name == want)
        {
            StatusText.Text = $"{want} 无信号；按「播放」可重试";
            return;
        }
        StatusText.Text = $"{want} 无信号，已切回 {prev.Name}";   // ★ 2026-10-02：措辞与手机端统一（原"已回到"）
        StopVlc();
        SelectTileByName(prev.Name);                            // ★ 台标选中态同步回原台
        _isPlaying = false;
        PlayChannel(prev.Name);
    }

    /// <summary>
    /// 拉一次远端播放单，确认里面**至少有一个分片行**（注释行不算）。
    /// 空清单 ⇒ 该台此刻没信号（原版鸿蒙所谓 "no-playurl"），调用方立即回退，不必等播放器超时。
    /// </summary>
    async Task<bool> PlaylistHasSegmentAsync(string playlistUrl, int timeoutMs)
    {
        try
        {
            // ★ 绝不因为"我们解析不了这个 URL"就判无信号 —— 交给播放器 + 看门狗兜底
            if (!Uri.TryCreate(playlistUrl, UriKind.Absolute, out _))
            {
                Log($"[tune] 播放单不是合法绝对 URL，跳过自检: {playlistUrl[..Math.Min(90, playlistUrl.Length)]}");
                return true;
            }
            using var hc2 = new HttpClient { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };
            using var req = new HttpRequestMessage(HttpMethod.Get, playlistUrl);
            req.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
            req.Headers.TryAddWithoutValidation("Referer", "https://yangshipin.cn/");
            using var resp = await hc2.SendAsync(req);
            if (!resp.IsSuccessStatusCode)
            {
                Log($"[tune] 播放单自检 HTTP {(int)resp.StatusCode}（不判无信号，交看门狗）");
                return true;
            }
            var txt = await resp.Content.ReadAsStringAsync();
            foreach (var raw in txt.Split('\n'))
            {
                var t = raw.Trim();
                if (t.Length > 0 && !t.StartsWith('#')) return true;   // 有分片行 ⇒ 有信号
            }
            return false;   // ★ HTTP 200 且没有分片行 ⇒ 真没信号（原版鸿蒙所谓 no-playurl）
        }
        catch (Exception ex)
        {
            Log($"[tune] 播放单自检异常（不判无信号，交看门狗）: {ex.Message}");
            return true;
        }
    }

    /// <summary>★ 2026-09-23 IPTV 源预检：6 秒内取到非空响应体即视为"源可用"。
    /// 语义与 `PlaylistHasSegmentAsync` **不同**：那个只在 HTTP 200 且无分片行时才判无信号（超时一律放过），
    /// 而 IPTV 源是外部公开源、慢/失效是常态 ⇒ 这里**超时/连接失败/非 2xx 一律判 false**，
    /// 目的是**不把死链路交给 VLC**（否则 VLC 的 input 线程会长时间卡在网络读上，进而拖死 UI）。
    /// 只对 `Src=="iptv"` 调用；央视频/江苏台链路不受影响。</summary>
    /// ⚠️ 非 static：内部要调实例方法 `Log`（写成 static 会 CS0120，实测踩过）。
    /// <summary>GET 文本（异常向上抛，由调用方判"不可达"）。</summary>
    static async Task<(int code, string text)> FetchTextAsync(string url, TimeSpan timeout)
    {
        using var hc = new HttpClient { Timeout = timeout };
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
        using var resp = await hc.SendAsync(req);
        return ((int)resp.StatusCode, await resp.Content.ReadAsStringAsync());
    }

    /// <summary>从清单里解析**首个分片**地址；若首行还是子清单（哈尔滨就是 `sd/live.m3u8`）就往下追，最多 3 层。
    /// 解析不出来返回 null（调用方按"不拦，交 VLC 试播"处理）。</summary>
    async Task<string?> FirstSegmentUrlAsync(string baseUrl, string text)
    {
        string cur = baseUrl, body = text;
        for (int depth = 0; depth < 3; depth++)
        {
            string? first = null;
            foreach (var raw in body.Split('\n'))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                first = line;
                break;
            }
            if (first == null) return null;
            var abs = new Uri(new Uri(cur), first).ToString();
            if (abs.Contains(".ts") || abs.Contains(".m4s") || abs.Contains(".mp4")) return abs;
            var (code, t) = await FetchTextAsync(abs, TimeSpan.FromSeconds(6));
            if (code < 200 || code >= 300 || t.Length == 0) return null;
            cur = abs;
            body = t;
        }
        return null;
    }

    /// <summary>只读前 want 字节；返回实际字节数，非 2xx 返回 -1（= "不确定"，不拦）。</summary>
    async Task<int> FetchPrefixBytesAsync(string url, int want, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        using var hc = new HttpClient();
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
        using var resp = await hc.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        if (!resp.IsSuccessStatusCode) return -1;
        using var s = await resp.Content.ReadAsStreamAsync(cts.Token);
        var buf = new byte[want];
        int total = 0;
        while (total < want)
        {
            int n = await s.ReadAsync(buf.AsMemory(total, want - total), cts.Token);
            if (n <= 0) break;
            total += n;
        }
        return total;
    }

    /// <summary>★★ 2026-09-24（方案 A）：IPTV 起播前**两段预检** ★★
    ///   ① 清单：6 秒内可达且非空（= 原 `IptvSourceAliveAsync`）；
    ///   ② **首个分片**：4 秒内真的吐出 ≥8KB 字节。
    /// 为什么必须查分片：只查清单挡不住"清单秒回 200、**分片**却不出数据"的源，而那种源一旦交给 VLC，
    ///   它的 input 线程会长期挂住 ⇒ 换台/回退时的 `Stop()`（同步、UI 线程）一起被挂 ⇒ **界面假死/无响应**。
    ///   ⇒ 判不可用就**根本不碰 VLC**，只 `RevertToLastGood`（原台不断音）。
    /// 宽松边界（不误杀）：非 2xx 一律**不拦**（外部源常因缺 Referer 回 403，VLC 或许能播）；解析不出分片地址也不拦。</summary>
    async Task<bool> IptvPlayableAsync(string url)
    {
        if (!await IptvSourceAliveAsync(url)) return false;
        try
        {
            var (code, text) = await FetchTextAsync(url, TimeSpan.FromSeconds(6));
            var seg = await FirstSegmentUrlAsync(url, text);
            if (seg == null)
            {
                Log("[iptv] 清单里没解析出分片地址（不拦，交 VLC 试播）");
                return true;
            }
            int got = await FetchPrefixBytesAsync(seg, 8192, TimeSpan.FromSeconds(4));
            if (got == -1)
            {
                Log($"[iptv] 分片 HTTP {code} 非 2xx（不拦，交 VLC 试播）");
                return true;
            }
            if (got < 8192)
            {
                Log($"[iptv] 首个分片 4 秒内只取到 {got} B ⇒ 判不可用（不交给 VLC，避免假死）");
                return false;
            }
            Log($"[iptv] 预检通过：清单 OK + 分片前 {got} B OK");
            return true;
        }
        catch (Exception ex)
        {
            Log($"[iptv] 分片预检异常（判不可用）: {ex.Message}");
            return false;
        }
    }

    async Task<bool> IptvSourceAliveAsync(string url)
    {
        try
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out _)) return false;
            using var hc = new HttpClient { Timeout = TimeSpan.FromSeconds(6) };
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            // ★ 只带浏览器 UA、**不带 Referer** —— 这些是外部源，用央视频的 Referer 反而可能被拒
            req.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
            using var resp = await hc.SendAsync(req);
            if (!resp.IsSuccessStatusCode)
            {
                /* ★ 关键取舍（2026-09-23）：非 2xx **不再拦下**，仍交给 VLC。
                 *   原因：本预检的目的仅是"避免超时挂住界面"，而 403/404 这类响应是**秒回**的、
                 *   不会造成阻塞；且外部源常因**缺少 Referer/其它头**而对我们返 403，VLC 或许能播
                 *   ⇒ 拦下反而会误杀可用源（实测：广州电视 403）。⇒ 只有"超时/连不上"才判不可用。 */
                Log($"[iptv] 源预检 HTTP {(int)resp.StatusCode}（不拦，交 VLC 试播）: {url[..Math.Min(90, url.Length)]}");
                return true;
            }
            var txt = await resp.Content.ReadAsStringAsync();
            return txt.Length > 0;
        }
        catch (Exception ex)
        {
            Log($"[iptv] 源预检失败（超时/不可达）: {ex.Message}");
            return false;
        }
    }

    /// <summary>取流阶段就失败（如没有 m3u8）时的回退：提示 + 回到上一台（含台标选中态）</summary>
    void FallbackToLastGood(string failName)
    {
        var prev = _lastGoodChannel;
        if (prev == null || prev.Name == failName)
        {
            StatusText.Text = $"{failName} 无信号；按「播放」可重试";
            return;
        }
        StatusText.Text = $"{failName} 无信号，已切回 {prev.Name}";   // ★ 同上：三端同文案
        StopVlc();
        SelectTileByName(prev.Name);
        _isPlaying = false;
        PlayChannel(prev.Name);
    }

    /// <summary>★ 起播前**预检**失败 ⇒ 只回退 UI（**VLC 还没被换过 ⇒ 原台不中断、不断音**）。
    /// 与 FallbackToLastGood 的分工：那个会 StopVlc + 重播上一台（画面会断一下），
    /// 只在"已经把坏源交给 VLC"时才用；这里连 VLC 都没碰过，回退就只改状态/选中态。</summary>
    void RevertToLastGood(string failName)
    {
        var prev = _lastGoodChannel;
        if (prev == null || prev.Name == failName)
        {
            StatusText.Text = $"{failName} 无信号；按「播放」可重试";
            return;
        }
        StatusText.Text = $"{failName} 无信号，仍看 {prev.Name}";
        _current = prev;
        _playingChannelName = prev.Name;
        NowPlaying.Text = "正在播出：";
        SelectTileByName(prev.Name);
    }

    /// <summary>把台标瓷砖的选中态切到指定频道；不在当前分组时先切分组（用户要求"选中态同步为原台"）</summary>
    void SelectTileByName(string name)
    {
        var ch = TvApiClient.Channels.FirstOrDefault(c => c.Name == name);
        if (ch != null && ch.Group != _activeGroup)
        {
            _activeGroup = ch.Group;
            TabCctv.IsChecked = (ch.Group == "cctv");
            TabSat.IsChecked = (ch.Group == "satellite");
            TabLocal.IsChecked = (ch.Group == "local");
            /* ★ 若当时停在「关于」页，回退原台时要把界面切回频道网格（否则两个面板状态打架） */
            TabAbout.IsChecked = false;
            if (AboutPanel != null) AboutPanel.Visibility = Visibility.Collapsed;
            if (ChannelScroll != null) ChannelScroll.Visibility = Visibility.Visible;
            RefreshChannelList(SearchBox.Text.Trim() is { Length: > 0 } t ? t : null);
        }
        if (ChannelGrid?.ItemsSource is List<ChannelTile> tiles)
        {
            var t = tiles.FirstOrDefault(x => x.Name == name);
            if (t != null) { _selectedTile = t; UpdateChannelListVisual(); }
        }
    }

    // ★ seqid 持久化: 对齐浏览器, 计数器存于本地文件, 跨运行单调递增, 永不复用旧值。
    //   浏览器把 nseqId 存在 cookie/localStorage, 删 cookie 才归 1; 服务器据此校验 seqid 不回退, 复用旧值 → 20401。
    static long _persistedSeqId = LoadPersistedSeqId();
    static long LoadPersistedSeqId()
    {
        try { var p = System.IO.Path.Combine(AppDir, "seqid.state"); if (System.IO.File.Exists(p)) return long.Parse(System.IO.File.ReadAllText(p).Trim()); } catch { }
        return 0;
    }
    static string NextPersistedSeqId()
    {
        var v = System.Threading.Interlocked.Increment(ref _persistedSeqId);
        try { System.IO.File.WriteAllText(System.IO.Path.Combine(AppDir, "seqid.state"), v.ToString()); } catch { }
        return v.ToString();
    }

    public MainWindow()
    {
        InitializeComponent();
        /* ★★ 2026-09-30：图标改从**嵌入资源**读（发布包里已不再有 `tv-icon.ico` 文件）★★
           优先嵌入资源（`EmbeddedResource` + LogicalName），拿不到再退回"exe 同目录的文件"（旧包/调试期）。
           ⚠️ 用 `Assembly.GetManifestResourceStream`，**不要改成 pack URI** —— 单文件发布下 pack URI 不可靠
              （此前就是因为这个才退回"读 AppDir 文件"，现在换成嵌入资源即可两全）。 */
        System.IO.Stream? iconStream = typeof(MainWindow).Assembly.GetManifestResourceStream("tv-icon.ico");
        if (iconStream == null)
        {
            var iconPath = System.IO.Path.Combine(AppDir, "tv-icon.ico");
            if (System.IO.File.Exists(iconPath))
                iconStream = new System.IO.FileStream(iconPath, System.IO.FileMode.Open, System.IO.FileAccess.Read);
        }
        if (iconStream != null)
        {
            using (iconStream)
            {
                var decoder = System.Windows.Media.Imaging.BitmapDecoder.Create(iconStream,
                    System.Windows.Media.Imaging.BitmapCreateOptions.None, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                // ★ 标题栏 24x24: 取最合适的一帧(ICO 内含 16~256 共 7 帧, Frames[0] 是最小的 16x16)
                //   优先选 >=32 的最小帧, 没有就用最大的一帧, 缩放时最清晰。
                var frames = decoder.Frames;
                var iconFrame = frames.FirstOrDefault(f => f.PixelWidth >= 32)
                                ?? frames.OrderByDescending(f => f.PixelWidth).FirstOrDefault();
                TitleIcon.Source = iconFrame;
                // ★ 任务栏 / Alt-Tab 图标: WindowStyle=None 时不会走系统标题栏,
                //   Window.Icon 决定任务栏按钮图标(与 exe 嵌入图标一致)。
                Icon = iconFrame;
            }
        }
        RefreshChannelList();
        // ★ WebView2 初始化：**暂仍保留**（其停用开关见 `WEBVIEW_DISABLED` 的注释）。
        //   ⚠️⚠️ 这一行曾在"搬移 --ch 逻辑"时被我**误删** ⇒ 初始化不跑 ⇒ `CoreWebView2` 为 null ⇒
        //       取流路径裸调 ⇒ NRE；或 `--ch` 根本不触发（日志里连初始化痕迹都没有）。**勿删这一行**。

        // ★★ `--ch <频道名>` 启动即自动播放：**必须放在这里** —— WebView2 已停用后，初始化方法里那份不再执行。
        //   ⚠️ 上一次把它搬进构造器时**误删了上面的 `InitializeWebView();`** ⇒ 初始化不跑、--ch 静默失效（勿重犯）。
        //   （InitializeWebView 尾部还留着一份同样的逻辑，属死代码，待机械清理时删除。）
        var __args = Environment.GetCommandLineArgs();
        var __ci = Array.FindIndex(__args, a => a == "--ch");
        if (__ci >= 0 && __ci + 1 < __args.Length)
        {
            var __chName = __args[__ci + 1];
            Log($"[联调] 启动参数自动播放: {__chName}");
            _ = Dispatcher.InvokeAsync(async () =>
            {
                await Task.Delay(800);
                PlayChannel(__chName);
            });
        }
        /* ★ 2026-11-06：`--replay <分钟>` = 启动后直接回看"N 分钟前正在播的那一档"。
         *   对齐安卓的调试开关（`--ei replay_min 60`）。用途：
         *     · 快速验证回看链路 / 节目条是否同步成"回看中：xxx"；
         *     · 验证"回看播完自动接下一档"（配合下面注释里的截断开关）。
         *   ⚠️ 必须在频道起播之后（`_current` 与 EPG 都要就绪）⇒ 延迟 8 秒。 */
        var __ri = Array.FindIndex(__args, a => a == "--replay");
        if (__ri >= 0 && __ri + 1 < __args.Length && int.TryParse(__args[__ri + 1], out var __minsAgo))
        {
            _ = Dispatcher.InvokeAsync(async () =>
            {
                await Task.Delay(8000);
                var ch = _current;
                if (ch == null || string.IsNullOrEmpty(ch.Pid) || ch.Pid == "0")
                {
                    Log("[replay] --replay 需要先有一条央视频道在播（用 --ch 指定）", true);
                    return;
                }
                if (_epgCache.Count == 0) _epgCache = await FetchEpgAsync(ch.Pid);
                long at = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - __minsAgo * 60L;
                var prog = _epgCache.FirstOrDefault(p => p.StartEpoch > 0 && at >= p.StartEpoch && at < p.EndEpoch);
                if (prog == null)
                {
                    Log($"[replay] --replay {__minsAgo}：节目单里找不到该时刻的节目", true);
                    return;
                }
                Log($"[replay] --replay {__minsAgo}：回看「{prog.Display}」", true);
                await PlayReplayAsync(prog, ch);
            });
        }
        //   原先这里的 `InitializeWebView()` 会创建 WebView2 环境 + 空白页 + 资源拦截 —— 纯浪费，已停用。
        //   ⚠️ `--ch` 自动播放**仍留在 WebView2 初始化方法的尾部**（那里是等初始化完成后才触发，时序正确）。
        //      我曾把它搬到构造器 ⇒ 800ms 后 WebView2 尚未 init 完 ⇒ CoreWebView2 为 null ⇒ 取流路径裸调 ⇒ NRE（已踩）。
        //      摘除 WebView2 时，这段**必须**挪到"不依赖任何 CoreWebView2 调用"的位置，见 WEBVIEW_DISABLED 注释。
    }



    // ==================== 频道台标网格（三个分组 tab）====================
    // ★ 与鸿蒙 PalmTV 的分组方式一致：综合 / 卫视 / 地方台 三个 tab，每个 tab 是**台标瓷砖网格**。
    //   台标 PNG 取 `logos/real/<频道id>.png`（本地解码自鸿蒙 rawfile/rf/*.dat，**gitignore 不进公开仓库**）；
    //   缺失时自动退化为"文字瓷砖"（只是没有图片，功能与高亮完全一致）。
    string _activeGroup = "cctv";
    ChannelTile? _selectedTile;
    /// <summary>
    /// 侧栏宽度 —— **以 XAML 的 `SidebarCol` 为唯一来源，启动时记下来**。
    /// ★★ 不要硬编码 ★★（2026-09-20 实锤 bug）：`ToggleFullscreen` 退出分支与 `ApplyFullscreenUI`
    ///   原来都写死 `new GridLength(192)`，但 XAML 里是 240 ⇒ 只要切过一次全屏，
    ///   侧栏就被压成 192 ⇒ 每格 (192−16−滚动条)/3 ≈ 53px < 台标圆 64px
    ///   ⇒ 瓷砖互相压盖、被裁掉，表现为"切回窗口后显示全乱"（用户报的问题）。
    /// </summary>
    /// <summary>
    /// 侧栏宽度（**保留 GridLength 的完整语义，含 Star 单位**）。
    /// ★★ 2026-11-06 修：原来存 `double`（= `Width.Value`）。列宽改成 `30*` 后 `.Value` 是 0.30，
    ///   全屏退出时 `new GridLength(0.30)` 会被当成 **0.30 像素** ⇒ 右侧频道区缩成一条线
    ///   （用户截图："全屏后回到窗口 UI 右侧看不见"）。
    ///   ⇒ 现在直接保存/还原整个 `GridLength`，星号列才不会丢单位。
    /// </summary>
    GridLength _sidebarWidth = new(30, GridUnitType.Star);

    void RefreshChannelList(string? filter = null)
    {
        if (ChannelGrid == null) return;
        IEnumerable<TvChannel> q = TvApiClient.Channels.Where(c => c.Group == _activeGroup);
        if (!string.IsNullOrWhiteSpace(filter))
            q = q.Where(c => c.Name.Contains(filter!, StringComparison.OrdinalIgnoreCase));
        int withLogo = 0;
        var tiles = q.Select(c =>
        {
            var path = ResolveLogoPath(c);   // ★ 传整个频道：内部先按 id 查、再按中文名兜底
            var logo = ChannelTile.LoadLogo(path);   // ★ 预载 + Freeze（切勿改成绑定文件路径，见 ChannelTile.LoadLogo 注释）
            if (logo != null) withLogo++;
            else if (DEBUG_LOG) Log($"[logo] 缺图: {c.Id} -> {(path.Length == 0 ? "(未找到文件)" : path)}");
            return new ChannelTile
            {
                Id = c.Id,
                Name = c.Name,
                // ★ 2026-10-02：文字台标显示**完整频道名**（原来走 ShortLabel 只留一个字）
                FallbackText = c.Name,
                Logo = logo,
                Channel = c,
            };
        }).ToList();
        ChannelGrid.ItemsSource = tiles;
        if (DEBUG_LOG) Log($"[logo] tab={_activeGroup} 频道 {tiles.Count} 个, 有台标 {withLogo} 个, AppDir={AppDir}");
        if (!tiles.Contains(_selectedTile!)) _selectedTile = tiles.FirstOrDefault();
        UpdateChannelListVisual();
    }

    /// <summary>圈内兜底短名：取空格前的一段（"CCTV-1 综合" → "CCTV-1"），无空格则原样</summary>
    static string ShortLabel(string name)
    {
        var i = name.IndexOf(' ');
        return i > 0 ? name[..i] : name;
    }
    /// <summary>频道台标：发布版从 logos.dat 解出的缓存目录找，其次 logos/real/&lt;id&gt;.png、logos/&lt;id&gt;.png；
    /// 再退一步按**频道中文名**找（见下方说明）；都没有则返回空串</summary>
    /// <summary>兼容重载：只给 id 的调用点（拿不到频道对象时用）—— 只走 id 查找，不做名称兜底。</summary>
    static string ResolveLogoPath(string id) => ResolveLogoPath(new TvChannel { Id = id });

    static string ResolveLogoPath(TvChannel ch)
    {
        try
        {
            var id = ch.Id;
            // ★ 发布版：台标打包进单个 logos.dat（不再散落明文 PNG），此处指向解包后的缓存目录
            var cache = LogoPack.CacheDir;
            if (cache != null)
            {
                var pc = System.IO.Path.Combine(cache, id + ".png");
                if (File.Exists(pc)) return pc;
            }
            var p = System.IO.Path.Combine(AppDir, "logos", "real", id + ".png");
            if (File.Exists(p)) return p;
            p = System.IO.Path.Combine(AppDir, "logos", id + ".png");
            if (File.Exists(p)) return p;

            /* ★★ 2026-09-23：**按频道名兜底**（用户习惯用中文名为台标命名，如 `广州电视.png`）。
             *   理由：`logos.dat` 打包时按**文件名**入包，运行时先按 id 查、查不到再按名查 ⇒
             *   中文命名的 PNG 在**调试版与发布版都能命中**，用户以后丢一张 `香港卫视.png` 进去即可生效，
             *   不必改名、也不必改代码/映射表（此前只有 id 一种查找方式，中文名会全部退化成文字台标）。
             *   ⚠️ 顺序要紧：**先 id 后名** —— id 是稳定键（清单顺序不变则不变），名称是兜底。 */
            if (!string.IsNullOrWhiteSpace(ch.Name))
            {
                if (cache != null)
                {
                    var pc2 = System.IO.Path.Combine(cache, ch.Name + ".png");
                    if (File.Exists(pc2)) return pc2;
                }
                var p2 = System.IO.Path.Combine(AppDir, "logos", "real", ch.Name + ".png");
                if (File.Exists(p2)) return p2;
                p2 = System.IO.Path.Combine(AppDir, "logos", ch.Name + ".png");
                if (File.Exists(p2)) return p2;
            }
        }
        catch { }
        return "";
    }

    /// <summary>切换分组 tab（同时把其它两个 tab 取消选中，保证互斥）</summary>
    void ChannelTab_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton tb || tb.Tag is not string g) return;
        _activeGroup = g;
        TabCctv.IsChecked = (g == "cctv");
        TabSat.IsChecked = (g == "satellite");
        TabLocal.IsChecked = (g == "local");
        TabAbout.IsChecked = (g == "about");
        /* ★ 2026-09-24：「关于」与频道网格**同格互斥**（关于页不参与频道筛选/不上屏） */
        bool about = (g == "about");
        if (AboutPanel != null) AboutPanel.Visibility = about ? Visibility.Visible : Visibility.Collapsed;
        if (ChannelScroll != null) ChannelScroll.Visibility = about ? Visibility.Collapsed : Visibility.Visible;
        _selectedTile = null;
        if (about) { FillAbout(); return; }
        RefreshChannelList(CurrentFilter);   // ★ 必须走 CurrentFilter：占位文案不能当筛选条件
    }

    // ==================== ★ 2026-09-24：关于页（与鸿蒙端对齐）====================

    /// <summary>★ 内容来源与免责声明正文（**与鸿蒙端 `DISCLAIMER_TEXT` 必须一致**；改这里两端都要改）。
    /// ★ 2026-09-29：改成 `internal` —— 首启弹窗 `DisclaimerWindow` 也读它（**单一来源**，别另抄一份）。
    /// ⚠️ 改正文要同时升 <see cref="DisclaimerVersion"/>（两端一起升）⇒ 老用户会再弹一次。</summary>
    internal const string DisclaimerText =
        "1. 本应用为纯播放器客户端，自身不提供、不存储、不制作任何音视频内容。\n\n" +
        "2. 所有频道的播放地址（直播流）与台标图片均来自互联网公开渠道，包括 GitHub、Gitee 等开源项目" +
        "以及各地电视台公开发布的直播地址，仅用于网络流媒体播放技术的演示与个人学习。\n\n" +
        "3. 音视频内容的著作权、播出权及解释权归原电视台或相应权利人所有；" +
        "本应用不对其合法性、准确性、完整性与可用性作任何担保。\n\n" +
        "4. 若权利人认为本应用展示或播放的内容侵犯其合法权益，请通过下方联系方式告知我们，核实后将及时移除相关来源。\n\n" +
        "5. 请勿将本应用用于商业用途或二次分发；使用者应自行确保其使用行为符合所在地区法律法规。";

    /// <summary>★ 举报/联系渠道（**与鸿蒙端 `CONTACT_EMAIL` 保持一致**）</summary>
    internal const string ContactEmail = "162004332@qq.com";
    /// <summary>标签（与鸿蒙端 `CONTACT_LABEL` 同文案）</summary>
    internal const string ContactLabel = "举报 / 联系：";

    /// <summary>
    /// ★ 2026-09-29：声明的**版本号**（**与鸿蒙端 `Index.discVer` 保持一致**）。
    /// 改声明正文时两端一起升版 ⇒ 老用户升级后会再弹一次；只改联系方式不必动它。
    /// </summary>
    const string DisclaimerVersion = "disc_v2";

    /// <summary>同意标记文件：%LOCALAPPDATA%\WinPalmTV\disclaimer.txt，内容 = 已同意的声明版本号。
    /// （与鸿蒙端把 `disc` 写进 preferences 等价；不写 AppDir —— 那里可能没写权限。）</summary>
    static string DisclaimerFlagPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinPalmTV", "disclaimer.txt");

    /// <summary>
    /// 首启（或声明升版）⇒ 弹一次「内容来源与免责声明」，**必须点"我已阅读并同意"才继续**
    /// （与鸿蒙端 `Index.disclaimerModal()` 同口径：关窗/不同意都视为拒绝）。
    /// @return false = 用户不同意 ⇒ 应用已开始关闭，调用方**必须立即结束启动流程**。
    /// </summary>
    bool EnsureDisclaimerAccepted()
    {
        try
        {
            if (System.IO.File.Exists(DisclaimerFlagPath) &&
                System.IO.File.ReadAllText(DisclaimerFlagPath).Trim() == DisclaimerVersion)
                return true;
        }
        catch { /* 读不到 / 读坏 ⇒ 按"该弹"处理（合规优先），只记日志 */ }

        var dlg = new DisclaimerWindow(firstRun: true) { Owner = this };
        if (dlg.ShowDialog() != true)
        {
            Log("[about] 用户不同意内容来源声明 ⇒ 退出");
            Application.Current.Shutdown();
            return false;
        }
        try
        {
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(DisclaimerFlagPath)!);
            System.IO.File.WriteAllText(DisclaimerFlagPath, DisclaimerVersion);
            Log("[about] 已记录免责声明同意状态");
        }
        catch (Exception ex) { Log($"[about] 写声明同意标记失败: {ex.Message}"); }
        return true;
    }

    /// <summary>填充关于页（版本号、版权图标、联系方式）——每次切过去都刷一次，避免启动期控件还没建好</summary>
    void FillAbout()
    {
        try
        {
            var v = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            AboutVersion.Text = v == null ? "版本 -" : $"版本 {v.Major}.{v.Minor}.{v.Build}";
        }
        catch { AboutVersion.Text = "版本 -"; }
        AboutContact.Text = ContactEmail;
        /* ★ 2026-09-29：条目数放 **ToolTip**（侧栏窄，行内那串数字会被截断） */
        BtnIptvSource.ToolTip = IptvChannels.LastCount == 0
            ? "添加自己的直播直链（m3u8 / ts）；当前没有地方台"
            : $"添加自己的直播直链（m3u8 / ts）；已载入 {IptvChannels.LastCount} 个地方台（自定义 {IptvChannels.LastUserCount} 条）";
        /* ★★ 2026-10-02（用户要求：三端一致）★★
         *   品牌区左侧图标 = **应用图标** `app_icon.png`（原来是版权图标）；
         *   版权图标（用户 `版权.ico` 的 256 帧 → `copyright.png`）挪到「版权人：飘渺峰」后面，
         *   显示 16px **圆角矩形**（不是圆形 —— 用户明确要求；WPF 的 Image 要自己给 Clip）。
         *   ⚠️ 仍与 tv-icon.ico **同策略**：嵌入资源优先（csproj 的 EmbeddedResource），
         *      退回 AppDir 文件（旧包/调试期）；走 GetManifestResourceStream，不用 pack URI。 */
        LoadAboutImage(AboutIcon, "app_icon.png", "[about] 应用图标加载失败");
        LoadAboutImage(AboutCopyrightIcon, "copyright.png", "[about] 版权图标加载失败");
        AboutCopyrightIcon.Clip = new System.Windows.Media.RectangleGeometry(
            new System.Windows.Rect(0, 0, 16, 16), 4, 4);
    }

    /// <summary>
    /// 从嵌入资源（优先）或程序目录取一张 PNG 填进 Image 控件；只在控件还没图时加载
    /// （`FillAbout()` 每次切到关于页都会调，避免重复解码）。
    /// </summary>
    void LoadAboutImage(System.Windows.Controls.Image target, string fileName, string logTag)
    {
        if (target.Source != null)
        {
            return;
        }
        try
        {
            System.IO.Stream? s = typeof(MainWindow).Assembly.GetManifestResourceStream(fileName);
            if (s == null)
            {
                var p = System.IO.Path.Combine(AppDir, fileName);
                if (System.IO.File.Exists(p))
                {
                    s = new System.IO.FileStream(p, System.IO.FileMode.Open, System.IO.FileAccess.Read);
                }
            }
            using (s)
            {
                if (s != null)
                {
                    target.Source = System.Windows.Media.Imaging.BitmapFrame.Create(
                        s, System.Windows.Media.Imaging.BitmapCreateOptions.None,
                        System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                }
            }
        }
        catch (Exception ex)
        {
            Log($"{logTag}: {ex.Message}");
        }
    }

    /// <summary>登录按钮：**目前只是占位**（与鸿蒙端同口径，别在 UI 上假装已登录）</summary>
    void AboutLogin_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show("登录功能开发中，将在后续版本开放。\n\n登录后可用于跨设备同步「收藏」与偏好；未登录也可正常观看。",
            "敬请期待", MessageBoxButton.OK, MessageBoxImage.Information);

    /// <summary>
    /// 关于页"查看完整声明"⇒ 复用首启那个弹窗（同正文、同联系方式）。
    /// ★ `firstRun: false` —— **不显示"不同意"按钮**：用户早已同意过，那一步逻辑上不该再出现；
    ///   这里只是"再看一遍"，关闭不影响使用、也不改任何状态。
    /// </summary>
    void AboutDisclaimer_Click(object sender, MouseButtonEventArgs e) =>
        new DisclaimerWindow(firstRun: false) { Owner = this }.ShowDialog();

    /// <summary>
    /// ★ 2026-09-29：关于页「添加 / 编辑自定义源…」⇒ 编辑 `%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`，
    /// 保存后**立即重新载入**地方台列表（不重启；正在播放的画面不受影响）。
    /// </summary>
    void AboutIptv_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new IptvSourceWindow { Owner = this };
        if (dlg.ShowDialog() != true) return;
        ReloadIptvChannels();
        StatusText.Text = $"已保存自定义 IPTV 源（自定义 {IptvChannels.LastUserCount} 条 / 共 {IptvChannels.LastCount} 个地方台）";
        Log($"[iptv] 自定义源已保存：用户 {IptvChannels.LastUserCount} 条，合计 {IptvChannels.LastCount} 个地方台");
    }

    /// <summary>重新载入"用户自定义 + 内置"地方台并刷新列表（只动 `Src=="iptv"` 的项，不影响央视频道）。</summary>
    void ReloadIptvChannels()
    {
        try
        {
            TvApiClient.Channels.RemoveAll(c => c.Src == "iptv");
            TvApiClient.Channels.AddRange(IptvChannels.Load());
            RefreshChannelList();
        }
        catch (Exception ex) { Log($"[iptv] 重新载入失败: {ex.Message}"); }
    }

    void AboutContact_Click(object sender, MouseButtonEventArgs e)
    {
        try
        {
            Clipboard.SetText(ContactEmail);
            StatusText.Text = $"已复制联系邮箱：{ContactEmail}";
            Log($"[about] 已复制联系邮箱 {ContactEmail}");
        }
        catch (Exception ex) { Log($"[about] 复制失败: {ex.Message}"); }
    }

    /// <summary>单击瓷砖 = 播放（比"单击选中 + 双击播放"省一步）</summary>
    void ChannelTile_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is ChannelTile t)
        {
            _selectedTile = t;
            UpdateChannelListVisual();
            PlayChannel(t.Name);
        }
    }

    /// <summary>瓷砖上右键 = 与视频区同一套菜单（含节目单/切换频道）</summary>
    void ChannelTile_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is ChannelTile t)
        {
            _selectedTile = t;
            UpdateChannelListVisual();
        }
        ShowVideoContextMenu();
    }

    /// <summary>网格里上下左右移动选中项（不播放）</summary>
    void MoveSelection(int delta)
    {
        var tiles = ChannelGrid?.ItemsSource as List<ChannelTile>;
        if (tiles == null || tiles.Count == 0) return;
        int i = tiles.IndexOf(_selectedTile!) + delta;
        _selectedTile = tiles[Math.Clamp(i, 0, tiles.Count - 1)];
        UpdateChannelListVisual();
    }

    // NormalizeName 方法已被删除（从未使用）

    void Window_Loaded(object sender, RoutedEventArgs e)
    {
        /* ★ 2026-09-29：**首启「内容来源与免责声明」** —— 必须点"我已阅读并同意"才继续；
           点"不同意（退出）"或直接关窗 ⇒ 关掉应用、下面的初始化一概不做（与鸿蒙端同口径）。
           顺序放在最前：合规上不能先跑代理/取流再问用户。 */
        if (!EnsureDisclaimerAccepted()) return;

        /* ★ 2026-09-24：IPTV 清单必须在**首次 RefreshChannelList 之前**并入 ——
         *   原来放在函数末尾 ⇒ 第一次列表里根本没有 IPTV 台（要切一次分组才出现）。 */
        try
        {
            TvApiClient.Channels.AddRange(IptvChannels.Load());
            if (IptvChannels.LastCount > 0) Log($"[iptv] 已并入地方台 {IptvChannels.LastCount} 个频道");
        }
        catch (Exception ex) { Log($"[iptv] 清单载入失败（已忽略）: {ex.Message}"); }
        RefreshChannelList();
        _selectedTile = (ChannelGrid?.ItemsSource as List<ChannelTile>)?.FirstOrDefault();
        UpdateChannelListVisual();
        // ★ 记下 XAML 里的侧栏宽度（必须在任何全屏切换之前取，之后被改过就取不到了）
        if (SidebarCol.Width.Value > 0) _sidebarWidth = SidebarCol.Width;   // ★ 保存整个 GridLength（含 Star）
        // ★ 排查用（--log）：一次性核对三个分组的台标能否加载（顺带预热缓存），不用逐个点 tab
        if (DEBUG_LOG)
        {
          /* ★ 2026-09-24：这段是**纯诊断**（要解全部 64~79 张台标）⇒ 挪到后台跑，
             否则会在 Window_Loaded 里同步解码几十张 PNG（首次打开卡顿的元凶之一）。 */
          _ = Task.Run(() =>
          {
            Log($"[logo] 搜索框文本=\"{SearchBox.Text}\" ⇒ 判定筛选词={(CurrentFilter == null ? "(空)" : '"' + CurrentFilter + '"')}");
            foreach (var g in new[] { "cctv", "satellite", "local" })
            {
                var ids = TvApiClient.Channels.Where(c => c.Group == g).Select(c => c.Id).ToList();
                int ok = ids.Count(id => ChannelTile.LoadLogo(ResolveLogoPath(id)) != null);
                Log($"[logo] {g}: {ok}/{ids.Count} 张可加载");
            }
          });
        }
        /* ★★★ 2026-11-05：**不再启动 Go 代理** ★★★
         *   央视频早已改走"安卓平台"链路（`YspAndroidLive`），江苏台也改成 C# 现算签名
         *   + `LocalDecryptServer` 转发（见 `PlayLocalAsync`）⇒ `proxy.exe`（18888）整条不用了：
         *   `/auth` `/open-token` `/get-live-info` 属于已废弃的 Web/PC 取流，
         *   `/jstv.m3u8` `/jstv-seg` 被本地代理取代，`/warm` 只是预热（去掉只影响首次连接快慢）。
         *   `StartProxy()` / `WarmProxyAsync()` 方法体保留但不再调用（回退时改回来即可）。 */
        // StartProxy();
        // _ = WarmProxyAsync();
        /* ★ 2026-09-24：后台预热 VLC 原生库（首次播放少等 0.3~1.5s，见 WarmVlcLib）。 */
        _ = Task.Run(() => WarmVlcLib());
        // ★ 阻止 Windows 屏保/休眠 (媒体播放器标准行为)
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        // ★ P3b：`EnsureServedHtml()` 调用已删除 —— 页内播放已摘除，不再需要生成带 base64 注入的 served html。
        //   （方法定义暂留，随后续 WebView2 初始化块一起删除。）

        /* ★★ 2026-11-06：启动默认台 ★★
         *   用户要求"打开 APP 直接播上次的台，没有则 CCTV-1"。
         *   优先级：`--ch <频道>` 命令行（调试/外部调用）> 上次播放的台 > CCTV-1。
         *   延迟 800ms 再起播：等窗口完成布局、VLC 原生库预热有戏，避免首帧卡在 Loaded 里。 */
        bool hasExplicitCh = Array.Exists(Environment.GetCommandLineArgs(), a => a == "--ch");
        if (!hasExplicitCh)
        {
            var lastId = LastChannelStore.Load() ?? LastChannelStore.DefaultChannelId;
            Log($"[startup] 自动播放上次频道：{lastId}");
            _ = Dispatcher.InvokeAsync(async () =>
            {
                await Task.Delay(800);
                PlayChannel(lastId);
            });
        }
        else
        {
            Log("就绪 — 单击频道播放", true);
        }
    }

    void CopyDirectory(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src))
            File.Copy(f, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(f)), true);
        foreach (var d in Directory.GetDirectories(src))
            CopyDirectory(d, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(d)));
    }

    async void PlayChannel(string chName)
    {
        _loadCts?.Cancel();
        _loadCts = new CancellationTokenSource();
        _channelLive = false;                                  // ★ 换台：重新进入"未出画"状态
        _playbackLabel = $"播放中 · {chName}";
        BtnBackToLive.Visibility = Visibility.Collapsed;       // ★ 回到直播 ⇒ 隐藏"回到直播"按钮
        // ★ 2026-11-06：换台 / 回到直播 ⇒ 退出"节目单回看"状态（标签还原 + 不再自动接档）
        _replayProg = null;
        NowPlaying.Text = "正在播出：";
        NowPlaying.Foreground = NowLabelRed;
        SetStatus($"正在切换 · {chName}…", StatusKind.Busy);   // ★ 换台立刻有反馈（原来要等起播成功才更新）
        await PlayOfficialAsync(chName);
    }

    // ★ player.served.html 构建结果缓存 (进程内只构建一次)

    // ★ 生成(或复用) player.served.html = player.html + 三个注入资产(base64 内联)。
    //   旧逻辑: 每次换台都重建一遍 (读 44KB + 3 次 base64 编码≈1.1MB + 写 1.5MB) —— 换台卡顿的主因之一。
    //   新逻辑: 进程内只构建一次; 若磁盘已有 served html 且不比 player.html 旧, 直接复用。
    //   ★ 因此发布包可以只带预生成的 player.served.html, 不必带 player.html / keygen_bg.wasm /
    //     ts_module_body.js / RJq7sO71JF.wasm (它们只在"重建"时才需要)。

    // ==================== 地方台（地方频道组）====================
    // ★ 与央视频链路**完全独立**：
    //   · 无 auth / 无 session / 无 get_live_info —— 上游地址只靠一次 `txSecret` 签名成立；
    //   · 上游 **TS 是明文** ⇒ 不做任何解密，播放页走 `__startPlain()`（不碰 CMG 解密层）；
    //   · 取流全程经本地代理：`/jstv.m3u8?ch=<streamId>`（代理现算签名并带 Referer/UA 转发分片）。
    //   ★★ 播放前必须让播放页**重新加载**：CMG 解密模块在新页面里处于"恒等直通"状态
    //      （尚未对任何流做过 InitPlayer），否则上一路央视频留下的模块状态有可能改动明文字节。
    async Task PlayLocalAsync(TvChannel ch)
    {
        _loadCts?.Cancel();
        _loadCts = new CancellationTokenSource();

        _channelLive = false;
        _playbackLabel = $"播放中 · {ch.Name}";
        SetStatus($"正在切换 · {ch.Name}…", StatusKind.Busy);   // ★ 换台立刻有反馈
        _current = ch;
        NowPlaying.Text = "正在播出：";
        NowProg.Text = "";
        NextProg.Text = "";
        // 地方台没有 EPG，也没有 kvcollect 会话心跳；pid 为空，必须显式清掉，
        // 否则 EPG 会带着空 pid 去打接口（虽然会被兜底吃掉，但会白刷日志）。
        // ★★ 顺序很关键（2026-09-20 实锤 bug）：`BtnStop_EpgDisabled()` 内部会把 `_playingChannelName` 清成空串
        //    （它同时被"停止播放"复用）⇒ 必须在它之后再设 `_playingChannelName`，
        //    否则地方台在播时列表里没有任何瓷砖被标为在播 ⇒ **红外圈不亮**（用户报的"地方台在播没有红外圈"）。
        BtnStop_EpgDisabled();
        _playingChannelName = ch.Name;
        // ★ 2026-11-05：kvcollect 心跳已随 Web/PC 链路一起删除，这里不再需要清会话状态
        UpdateChannelListVisual();

        try
        {
            await StartLocalStream(ch);   // ★ P3b：页内播放已摘除 ⇒ 地方台直接起播（不再"加载播放页"+等导航完成）
        }
        catch (Exception ex)
        {
            Log($"[local] 播放失败: {ex.Message}");
            FallbackToLastGood(ch.Name);      // ★ 与央视频链路同一套无信号策略（提示 + 回退上一台）
        }
    }

    /// <summary>把地方台交给播放页（明文 HLS，不经过 CMG 解密）</summary>
    async Task StartLocalStream(TvChannel ch)
    {
        // ★ IPTV 地方台（Src=="iptv"）：**明文 HLS 直链** ⇒ VLC 直接播；不经解密代理、不经 Go 代理
        if (ch.Src == "iptv")
        {
            // ★ 2026-09-23：起播前**带超时的预检** —— IPTV 源不可控，慢/失效是常态。
            //   预检失败就明确提示并**不交给 VLC**（VLC 一旦卡在网络读上，input 线程会拖死 UI）。
            //   本方法是 async ⇒ await 不阻塞消息泵（真正会阻塞的调用也已在 PlayVlc 里挪到线程池）。
            if (!await IptvPlayableAsync(ch.StreamId))
            {
                Log($"[iptv] 源无响应，取消起播: {ch.Name}");
                RevertToLastGood(ch.Name);   // ★ 与鸿蒙同口径：不换播放器，只把状态/选中退回原台
                return;
            }
            PlayVlc(ch.StreamId, ch.Name + "（IPTV 直连）", AspectOf(ch));
            _isPlaying = true;
            BtnPlay.Content = "⏸ 暂停";
            SetStatus($"播放中 · {ch.Name}", StatusKind.Normal);
            UpdateChannelListVisual();
            return;
        }

        /* ★★ 2026-11-05：**不再经过 Go 代理** ★★
         *   原来：`http://127.0.0.1:18888/jstv.m3u8?ch=` → Go 代理算 txSecret + 拉清单 + 转发分片。
         *   现在：C# 用 `jstv_sign.c` 现算签名（`JstvLive.UpstreamUrl`），清单与分片都交给
         *   `LocalDecryptServer`（它按 host 自动带江苏的 Referer/Origin）。
         *   ⇒ `proxy.exe` 彻底不需要了（央视频早就改走安卓链路）。 */
        var up = JstvLive.UpstreamUrl(ch.StreamId);
        if (up == null)
        {
            Log($"[jstv] 签名失败：{PalmTVCore.LastSignError}", true);
            RevertToLastGood(ch.Name);
            return;
        }
        try
        {
            _decServer ??= new LocalDecryptServer();
            LocalDecryptServer.Log = m => Log(m);
            _decServer.Start();
            // 江苏不是加密台 ⇒ pid 在密钥表里查不到 ⇒ `Sm4C.TryDecrypt` 返回 false ⇒ 分片原样直通
            _decServer.EnsureCore(ch.StreamId);
            var localUrl = LocalDecryptServer.LocalPlaylistUrl(up, ch.StreamId);
            if (DEC_TEST) Log($"[jstv] 本地播放地址: {localUrl}");
            PlayVlc(localUrl, ch.Name + "（地方台）");
            _isPlaying = true;
            BtnPlay.Content = "⏸ 暂停";
            SetStatus($"播放中 · {ch.Name}", StatusKind.Normal);
            UpdateChannelListVisual();
        }
        catch (Exception ex)
        {
            Log($"[jstv] 本地代理启动失败: {ex.Message}", true);
            RevertToLastGood(ch.Name);
        }
    }

    async Task PlayOfficialAsync(string chName)
    {

		//StatusText.Text = $"{chName} [官方源]";
        NowPlaying.Text = "正在播出：";
        NowProg.Text = "";
        NextProg.Text = "";
        _playingChannelName = chName;

        // ★★ 查找必须**先精确匹配整名**，再做模糊兜底 ★★
        //   踩坑（2026-09-20，用户报"江苏卫视4K 源不对，不是 4K 播放源"）：
        //   原来只有 `StartsWith || Contains(双向)` 的模糊匹配，而频道表里卫视频道组的 `jsws`（江苏卫视）
        //   排在地方台的 `jsws4kpro`（江苏卫视4K）之前 ⇒ 点"江苏卫视4K"时
        //   `"江苏卫视4K".Contains("江苏卫视")` 先命中 ⇒ **实际播的是卫视组 HD 流**
        //   （运行时分辨率探针实测 1920x1080，而地方台 4K 那路根本没被用上）。
        //   同理 "CCTV-1 综合" vs "CCTV-10 科教" 也靠精确匹配才稳。
        /* ★★★ 2026-11-06：**先按 Id 精确匹配** ★★★
         *   踩坑：启动续播传的是频道 Id（`cctv1`），而这里原来只比 `Name`
         *   ⇒ 匹配不到 ⇒ 走进"不是频道名 ⇒ 用系统浏览器打开官网搜索页"的分支
         *   （用户截图：状态栏「cctv1」不是频道名…，浏览器打开 yangshipin.cn/search?q=cctv1）。
         *   Id 是稳定主键（`PlayerService` 频道表每个台都有），今后按 Id 调用一律走这条路。 */
        var tvCh = TvApiClient.Channels.FirstOrDefault(c => string.Equals(c.Id, chName, StringComparison.OrdinalIgnoreCase))
            ?? TvApiClient.Channels.FirstOrDefault(c => string.Equals(c.Name, chName, StringComparison.OrdinalIgnoreCase))
            ?? TvApiClient.Channels.FirstOrDefault(c =>
                c.Name.StartsWith(chName, StringComparison.OrdinalIgnoreCase)
                || chName.Contains(c.Name, StringComparison.OrdinalIgnoreCase)
                || c.Name.Contains(chName, StringComparison.OrdinalIgnoreCase));

        // 传进来的是 Id ⇒ 立刻统一成频道名，后续 UI / 高亮 / 落盘都按名字走
        if (tvCh != null && !string.Equals(chName, tvCh.Name, StringComparison.OrdinalIgnoreCase))
        {
            chName = tvCh.Name;
            NowPlaying.Text = "正在播出：";
            _playingChannelName = chName;
        }
        // ★ 地方台（地方频道组）：链路与央视频完全不同 ⇒ 单独一条路（不查 pid、不走取流签名）
        if (tvCh != null && (tvCh.Src == "jstv" || tvCh.Src == "iptv"))
        {
            await PlayLocalAsync(tvCh);
            return;
        }
        if (tvCh == null || tvCh.Pid == "0" || string.IsNullOrEmpty(tvCh.Pid))
        {
            _current = new TvChannel { Name = chName };
            // ★ P3b：页内浏览器已摘除 ⇒ 输入非频道名时改用**系统默认浏览器**打开官网搜索页
            //   （原来是把 WebView2 导航过去；CoreWebView2 现在为 null，直接调用会抛 NRE）。
            StopVlc();
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = $"https://yangshipin.cn/search?q={Uri.EscapeDataString(chName)}",
                    UseShellExecute = true,
                });
                Log($"「{chName}」不是频道名，已用系统浏览器打开官网搜索页", true);
            }
            catch (Exception ex) { Log($"打开搜索页失败: {ex.Message}", true); }
            return;
        }
        _current = tvCh;

        try
        {
            _channelLive = false;
            _playbackLabel = $"播放中 · {tvCh.Name}";
            SetStatus($"取流中 · {tvCh.Name}…", StatusKind.Busy);   // ★ 取流阶段也有反馈
            /* ★★★ 2026-11-05：央视频**只有一条链**（安卓平台），Web/PC 链路已整体删除 ★★★
             *   失败就直接报错 + 回退原台，不再"回落老链路"（那条依赖 proxy.exe 的 auth/open-token/
             *   get_live_info，代理已移除，回落必然失败，只会拖长失败时间）。 */
            if (!await TryAndroidLiveAsync(tvCh))
            {
                Log($"[android-live] 取流失败：{YspAndroidLive.LastError}", true);
                FallbackToLastGood(tvCh.Name);
            }
        }
        catch (Exception ex) { Log($"错误: {ex.Message}", true); }
    }

    /// <summary>
    /// ★★★★★ 2026-11-05：**央视频唯一取流入口**（安卓平台链路，与 `Android/data/YspAndroidLive.kt` 同参数）★★★★★
    ///
    /// 流程：`YspAndroidLive.ResolveAsync`（cKey → liveinfo → m3u8）
    ///   → `LocalDecryptServer`（改写清单 + 分片按 pid 解密）
    ///   → VLC 播 `http://127.0.0.1:18899/...`。
    ///
    /// 直播优先"真直播"；被 CDN 拒时退"时移 <see cref="YspAndroidLive.LiveShiftSec"/> 秒"
    /// （播放地址换成 playback CDN，代价是晚 10 秒）。
    /// ⚠️ 失败**不再回落** Web/PC 链路（那条依赖已删除的 proxy.exe / auth / open-token）。
    /// </summary>
    async Task<bool> TryAndroidLiveAsync(TvChannel ch)
    {
        var r = await YspAndroidLive.ResolveAsync(ch.CnlId, ch.Pid, null, null, m => Log(m));
        if (r == null)
        {
            var liveReason = YspAndroidLive.LastError;
            long pb = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - YspAndroidLive.LiveShiftSec;
            Log($"[android-live] 真直播不可用（{liveReason}）⇒ 退时移 {YspAndroidLive.LiveShiftSec}s");
            r = await YspAndroidLive.ResolveAsync(ch.CnlId, ch.Pid, pb, null, m => Log(m));
            if (r == null)
            {
                Log($"[android-live] 时移也不可用：{YspAndroidLive.LastError}", true);
                return false;
            }
        }

        // ★ 起播前自检播放单：**空清单 = 该台此刻没信号** ⇒ 立刻判死，不等播放器超时
        //   （CCTV-10 偶发无信号时上游返回的正是没有分片的清单，几百毫秒就能判出来）
        if (!await PlaylistHasSegmentAsync(r.Url, 6000))
        {
            Log($"[tune] {ch.Name} 播放单为空（无信号）⇒ 判死");
            return false;
        }

        try
        {
            _decServer ??= new LocalDecryptServer();
            LocalDecryptServer.Log = m => Log(m);
            _decServer.Start();
            _decServer.EnsureCore(ch.Pid);
            var local = LocalDecryptServer.LocalPlaylistUrl(r.Url, ch.CnlId);
            if (DEC_TEST) Log($"[dec] 本地播放地址: {local}");
            PlayVlc(local, ch.Name);
            _isPlaying = true;
            BtnPlay.Content = "⏸ 暂停";
            SetStatus($"播放中 · {ch.Name}", StatusKind.Normal);
            UpdateChannelListVisual();
            StartEpgRefresh(ch.Pid);        // ★ 央视频 EPG（原来在 FetchViaPostMessage 里）
            return true;
        }
        catch (Exception ex)
        {
            Log($"[dec] 本地解密代理启动失败: {ex.Message}", true);
            return false;
        }
    }

    /// <summary>当前 EPG 对应的 pid（用于判断"换台"还是"同一台重复启动"）。</summary>
    string _epgPid = "";

    /// <summary>
    /// ★ 2026-11-06：**当前正在"节目单回看"的那一档**（null = 直播 / 时移）。
    /// 两个用途：① `EndReached` 时据此决定"接下一档还是回直播"；
    ///          ② 节目条要把"正在播出"换成这一档（用户要求：回看时节目条同步当前回看的节目）。
    /// ⚠️ 换台（`PlayChannel`）、时移、停止播放都必须清掉 —— 否则会把回看标签/自动接档带到直播上。
    /// </summary>
    EpgProgram? _replayProg;

    void StartEpgRefresh(string pid)
    {
        /* ★ 2026-11-06：同一 pid 被重复调用（起播成功 + 看门狗 + 重试各一次）时，
         *   原来每次都把 `_lastEpgFetch` 重置 ⇒ 15 秒内连拉 3 次上游 EPG（实测日志可证）。
         *   只有 pid 真的变了才清缓存 + 立即拉。 */
        bool sameChannel = string.Equals(_epgPid, pid, StringComparison.Ordinal);
        _epgTimer?.Dispose();
        _scrollTimer?.Stop();
        if (!sameChannel)
        {
            _epgPid = pid;
            _epgCache = new List<EpgProgram>();
            _lastEpgFetch = DateTime.MinValue;
        }
        // ★ 2026-09-04: 修复"长时间播放跨节目单不更新"——
        //   每 10s 用本地时钟按缓存推进"正在/即将"(跨节目单 ≤10s 内切换);
        //   拉取失败/为空则沿用缓存。
        // ★★ 2026-11-10（用户要求：三端统一）：上游对齐由 ≥60s 改为 **≥30s** 一次
        //   （节目单是"今天"这一天的列表，30s 重拉 = 与鸿蒙/安卓的"每 30 秒对齐一次"同义）。
        _epgTimer = new System.Threading.Timer(async _ =>
        {
            try
            {
                if ((DateTime.Now - _lastEpgFetch).TotalSeconds >= 30)
                {
                    _lastEpgFetch = DateTime.Now;
                    var programs = await FetchEpgAsync(pid);
                    if (programs != null && programs.Count > 0)
                    {
                        _epgCache = programs;
                    }
                }
            }
            catch { /* 拉取失败: 沿用缓存, 界面仍按本地时钟推进 */ }
            _ = Dispatcher.BeginInvoke(new Action(() => UpdateProgramDisplay(_epgCache)));
        }, null, 0, 10000);
        // 独立的滚动定时器: 每 150ms 滚 1px
        _scrollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _scrollTimer.Tick += (_, _) => ScrollNextProg();
        _scrollTimer.Start();
    }
    DispatcherTimer? _scrollTimer;

    double _nowOff, _nextOff;

    void UpdateProgramDisplay(List<EpgProgram> programs)
    {
        /* ★★ 2026-11-06（用户要求：回看时节目条也要同步当前回看的节目）★★
         *   对齐安卓 `MainScreen`：前缀由「正在播出」换成「回看中」并把颜色从红换成主蓝，
         *   内容显示**正在回看的那一档**，不是直播此刻的那一档。
         *   ⚠️ 这段必须放在"按本地时钟取 IsCurrent"之前并 **return** ——
         *      否则每 10 秒的 EPG 定时器会把节目条刷回"直播正在播出"。 */
        if (_replayProg != null)
        {
            NowPlaying.Text = "回看中：";
            NowPlaying.Foreground = ReplayLabelBlue;
            NowProg.Text = $"▶  {_replayProg.Display}";
            NowProgBorder.Background = new SolidColorBrush(Color.FromRgb(0x12, 0x18, 0x28));
            var rIdx = programs.IndexOf(_replayProg);
            var rNext = rIdx >= 0 && rIdx + 1 < programs.Count ? programs[rIdx + 1] : null;
            NextProg.Text = rNext != null ? $"⌛  {rNext.Display}" : "";
            NextProgBorder.Background = rNext != null
                ? new SolidColorBrush(Color.FromRgb(0x0F, 0x34, 0x60)) : Brushes.Transparent;
            _nowOff = 0; NowProgScroller.ScrollToHorizontalOffset(0);
            _nextOff = 0; NextProgScroller.ScrollToHorizontalOffset(0);
            return;
        }
        NowPlaying.Text = "正在播出：";
        NowPlaying.Foreground = NowLabelRed;

        var cur = programs.FirstOrDefault(p => p.IsCurrent);
        /* ★ 2026-11-10（用户要求：与鸿蒙端一致）：地方台 / 没有节目单 ⇒
         *   「正在播出」显示 **白粗字「暂无节目单」**，「接下来」显示 `-`（鸿蒙 `episodeNow/episodeNext` 同款）；
         *   有节目单时恢复绿色节目名。 */
        var epgGreen = new SolidColorBrush(Color.FromRgb(0x4C, 0xAF, 0x50));
        var epgWhite = new SolidColorBrush(Color.FromRgb(0xE0, 0xE0, 0xE0));
        if (cur != null)
        {
            NowProg.Text = $"▶  {cur.Display}";
            NowProg.Foreground = epgGreen;
        }
        else
        {
            NowProg.Text = "暂无节目单";
            NowProg.Foreground = epgWhite;   // XAML 里已是 Bold
        }
        NowProgBorder.Background = cur != null
            ? new SolidColorBrush(Color.FromRgb(0x12, 0x18, 0x28)) : Brushes.Transparent;
        var curIdx = cur != null ? programs.IndexOf(cur) : -1;
        var next = curIdx >= 0 && curIdx + 1 < programs.Count ? programs[curIdx + 1] : null;
        NextProg.Text = next != null ? $"⌛  {next.Display}" : "-";
        NextProgBorder.Background = next != null
            ? new SolidColorBrush(Color.FromRgb(0x0F, 0x34, 0x60)) : Brushes.Transparent;
        // ★ 节目更新时复位滚动偏移
        _nowOff = 0; NowProgScroller.ScrollToHorizontalOffset(0);
        _nextOff = 0; NextProgScroller.ScrollToHorizontalOffset(0);
    }

    void ScrollNextProg()
    {
        ScrollOne(NowProg, NowProgScroller, ref _nowOff);
        ScrollOne(NextProg, NextProgScroller, ref _nextOff);
    }

    void ScrollOne(TextBlock tb, ScrollViewer sv, ref double off)
    {
        if (string.IsNullOrEmpty(tb.Text)) { off = 0; return; }
        var viewW = sv.ViewportWidth;
        if (viewW <= 0) return;
        var ft = new FormattedText(
            tb.Text,
            System.Globalization.CultureInfo.CurrentCulture,
            FlowDirection.LeftToRight,
            new Typeface(tb.FontFamily, tb.FontStyle, tb.FontWeight, tb.FontStretch),
            tb.FontSize,
            Brushes.Black,
            1.0);
        var fullW = ft.WidthIncludingTrailingWhitespace;
        if (fullW <= viewW + 4) { off = 0; return; }
        var maxOff = fullW - viewW + 30;
        // ★ 自维护偏移量, 不依赖 sv.HorizontalOffset 回读 (getter 在 timer 回调中不可靠)
        off += 1;
        if (off >= maxOff) off = 0;
        sv.ScrollToHorizontalOffset(off);
    }

    bool _muted = false;
    double _preMuteVolume = 80;
    void BtnMute_Click(object s, RoutedEventArgs e)
    {
        _muted = !_muted;
        if (_muted)
        {
            _preMuteVolume = VolSlider.Value;
            VolSlider.Value = 0;
            BtnMute.Content = "🔇";
        }
        else
        {
            VolSlider.Value = _preMuteVolume;
            BtnMute.Content = "🔊";
        }
    }

    void BtnStop_EpgDisabled()
    {
        _epgTimer?.Dispose();
        _scrollTimer?.Stop();
        // ★ 2026-11-06：停止播放 ⇒ 退出回看状态（否则下次播放回来还挂着"回看中"）
        _replayProg = null;
        NowPlaying.Text = "正在播出：";
        NowPlaying.Foreground = NowLabelRed;
        _nowOff = 0; _nextOff = 0;
        NowProg.Text = "";
        NowProgBorder.Background = Brushes.Transparent;
        NextProg.Text = "";
        NextProgBorder.Background = Brushes.Transparent;
        _playingChannelName = "";
        UpdateChannelListVisual();
    }

    // ★ 高亮改为**数据驱动**（IsPlaying / IsSelected → XAML 里的 DataTrigger 画红外圈/青圈）。
    //   旧实现靠 `ItemContainerGenerator.ContainerFromIndex()` 找容器 —— 虚拟化未实现或项滚动出屏时
    //   拿不到容器 ⇒ 在播频道不亮（用户报的"地方台在播没显示红粗字"就是这个根因）。
    void UpdateChannelListVisual()
    {
        if (ChannelGrid?.ItemsSource is not List<ChannelTile> tiles) return;
        foreach (var t in tiles)
        {
            t.IsPlaying = (t.Name == _playingChannelName);
            t.IsSelected = ReferenceEquals(t, _selectedTile);
        }
    }

    void Window_KeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter: if (_selectedTile != null) PlayChannel(_selectedTile.Name); break;
            case Key.Up: MoveSelection(-3); break;      // 网格为 3 列
            case Key.Down: MoveSelection(3); break;
            case Key.Left: PlayAdjacent(-1); break;
            case Key.Right: PlayAdjacent(1); break;
            case Key.F: case Key.F11: ToggleFullscreen(); break;
            case Key.Escape: if (_fullscreen) ToggleFullscreen(); break;
        }
    }

    void PlayAdjacent(int delta)
    {
        MoveSelection(delta);
        if (_selectedTile != null) PlayChannel(_selectedTile.Name);
    }

    /// <summary>搜索框占位文案（必须与 XAML 里 `SearchBox` 的 `Text=` 一致）</summary>
    const string SearchHint = "🔍 搜索频道...";

    /// <summary>
    /// 搜索框里是否有**真实的**筛选词。
    /// ★★ 踩坑（2026-09-20，用户报"点 tab 后台标全没了 / 卫视本地一个台标都没有"）★★
    ///   原实现把占位文案当关键词：XAML 的 `Text="🔍 搜索频道..."` 与代码里判定的 `"🔍 输入频道名搜索..."`
    ///   **两个串不一样** ⇒ 占位串没被识别成"空" ⇒ `ChannelTab_Click` 拿它当筛选条件 ⇒ 每个 tab 都筛出 0 个频道
    ///   ⇒ 网格整片空白（启动时只有央视是好的，因为构造/加载时没传筛选）。
    ///   现在统一：凡是以 🔍 开头的都视为占位、不算筛选词。
    /// </summary>
    string? CurrentFilter =>
        string.IsNullOrWhiteSpace(SearchBox.Text) || SearchBox.Text.TrimStart().StartsWith("🔍")
            ? null
            : SearchBox.Text.Trim();

    void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        RefreshChannelList(CurrentFilter);
    }

    void SearchBox_GotFocus(object sender, RoutedEventArgs e)
    {
        if (SearchBox.Text.TrimStart().StartsWith("🔍") || SearchBox.Text == SearchHint)
        {
            SearchBox.Text = "";
            SearchBox.Foreground = System.Windows.Media.Brushes.White;
        }
        else
        {
            SearchBox.SelectAll();
        }
    }

    void SearchBox_LostFocus(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(SearchBox.Text))
        {
            SearchBox.Text = SearchHint;
            SearchBox.Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(0x88, 0x88, 0x88));
        }
    }

    [DllImport("kernel32.dll")]
    static extern uint SetThreadExecutionState(uint esFlags);
    const uint ES_CONTINUOUS = 0x80000000;
    const uint ES_SYSTEM_REQUIRED = 0x00000001;
    const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("user32.dll")]
    static extern bool GetCursorPos(ref POINT lpPoint);
    struct POINT { public int X; public int Y; }

    DispatcherTimer? _hideTimer, _pollTimer;
    bool _uiVisible = true;
    POINT _lastMousePos;
    DateTime _lastMoveTime;

    void SetFullscreenCursor(Cursor cur)
    {
        // Window 级光标 (侧边栏等 WPF 区域)
        Cursor = cur;
        // ★ P3b：原"WebView2 是独立 Chromium 进程 ⇒ 必须用 JS 注入覆盖 CSS cursor"已删除；
        //   VLC 是原生子窗口，靠上面那行 Window 级 `Cursor` 即可，不需要 CSS 注入。
    }

    void ShowVideoContextMenu()
    {
        var menu = new ContextMenu
        {
            Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint,
            Style = (Style)FindResource("DarkMenu"),
        };
        if (_fullscreen)
            menu.Items.Add(MakeMenuItem("退出全屏  Esc / F11", () => ToggleFullscreen()));
        else
            menu.Items.Add(MakeMenuItem("进入全屏 (F11)", () => ToggleFullscreen()));
        menu.Items.Add(new Separator { Style = (Style)FindResource("DarkSeparator") });
        // 切换央视频道组（菜单文案与左侧 tab「央视」保持一致）
        var tvMenu = MakeSubMenu("切换央视");
        foreach (var ch in TvApiClient.Channels.Where(c => c.Group == "cctv"))
            tvMenu.Items.Add(MakeMenuItem(ch.Name, () => PlayChannel(ch.Name)));
        menu.Items.Add(tvMenu);
		// 切换卫视 (非 CCTV 开头)
		var wsMenu = MakeSubMenu("切换卫视");
		foreach (var ch in TvApiClient.Channels.Where(c => c.Group == "satellite"))
			wsMenu.Items.Add(MakeMenuItem(ch.Name, () => PlayChannel(ch.Name)));
		menu.Items.Add(wsMenu);
        // 切换地方台（地方频道组）
        var localMenu = MakeSubMenu("切换地方台");
        foreach (var ch in TvApiClient.Channels.Where(c => c.Group == "local"))
            localMenu.Items.Add(MakeMenuItem(ch.Name, () => PlayChannel(ch.Name)));
        menu.Items.Add(localMenu);
		// ★ 2026-11-06：改为**直接打开弹层**（原来在子菜单里逐条列 30~60 条，
		//   超出屏幕且没有滚动条，下面的根本看不到；弹层有滚动 + 自动定位当前节目）。
		menu.Items.Add(MakeMenuItem("节目单", ShowEpgOverlay));
		// ★ 2026-11-06 时移（与安卓同机制：liveinfo + playbacktime，不带 endtime）
		var tsMenu = MakeSubMenu("时移");
		foreach (var m in new[] { 10, 30, 60 })
		{
			int back = m;
			tsMenu.Items.Add(MakeMenuItem($"⏪ 回到 {back} 分钟前", () => _ = PlayTimeshiftAsync(back)));
		}
		tsMenu.Items.Add(new Separator { Style = (Style)FindResource("DarkSeparator") });
		tsMenu.Items.Add(MakeMenuItem("▶ 回到直播", () => { if (_current != null) PlayChannel(_current.Name); }));
		menu.Items.Add(tsMenu);
		menu.Items.Add(new Separator { Style = (Style)FindResource("DarkSeparator") });
		menu.Items.Add(MakeMenuItem("停止播放", () => Dispatcher.BeginInvoke(() => BtnStop_Click(null!, null!))));
		menu.IsOpen = true;
	}

	// ★ 2026-11-06：`EpgProgram` 已提到 `EpgClient.cs`（顶层类型），供 EpgClient 解码时构造。
	/* ★★ 2026-11-06：EPG **直连 capi**（protobuf），不再走 18888 代理 ★★
	 *   原来这里请求 `127.0.0.1:18888/capi/...` 并期望 JSON（代理转过码），
	 *   proxy 移除后该请求必然失败 ⇒ 节目单/正在播/接下来长期为空。
	 *   解码逻辑见 `EpgClient.cs`（与安卓 `Epg.kt` 的 protobuf 字段一一对应）。 */
	async Task<List<EpgProgram>> FetchEpgAsync(string pid)
	{
		var list = await EpgClient.FetchAsync(pid);
		if (list.Count == 0) Log($"[epg] {pid} 拉取为空（上游无数据或字段变更）");
		/* ★ 2026-11-06：诊断 8K"看不出状态区别"——把原始 epoch / 判定结果一起打出来。
		 *   若 `epoch=0-0` 说明上游只给了 HH:mm（字段 5/6），IsPast/IsCurrent 走兜底分支。 */
		else Log($"[epg] {pid} 拉到 {list.Count} 条，首条 {list[0].Display} 可回看={list[0].Replayable} " +
				 $"epoch={list[0].StartEpoch}-{list[0].EndEpoch} IsPast={list[0].IsPast} IsCur={list[0].IsCurrent}");
		return list;
	}

	/* ★★★ 2026-11-06：**回看** ★★★
	 *   机制与安卓一致：还是 `liveinfo` 那条接口，只是带上 `playbacktime=节目开始时刻`
	 *   + `endtime=节目结束时刻` ⇒ 服务端返回**整段 VOD 清单**（可连续播完，不会周期性卡）。
	 *   入口：视频区右键 → 节目单 → 点击"已播完且可回看"的条目（见 ShowVideoContextMenu）。 */
	async Task<bool> PlayReplayAsync(EpgProgram prog, TvChannel ch)
	{
		_channelLive = false;
		_playbackLabel = $"回看中 · {prog.Title}";
		BtnBackToLive.Visibility = Visibility.Visible;   // ★ 回看中 ⇒ 节目条右侧出现"回到直播"
		SetStatus($"回看 · {prog.Title}…", StatusKind.Busy);
		long end = prog.EndEpoch > prog.StartEpoch ? prog.EndEpoch
				 : prog.StartEpoch + 1800;              // 兜底：节目单没给 end 时按 30 分钟
		/* ★ 2026-11-06 调试开关：`PALMTV_REPLAY_CAP=<秒>` ⇒ 只回看该节目前 N 秒。
		 *   唯一的用途是**验证"播完自动接下一档"**（真节目动辄 30~60 分钟，等不起）。
		 *   不设置时行为完全不变。 */
		var __capEnv = Environment.GetEnvironmentVariable("PALMTV_REPLAY_CAP");
		if (int.TryParse(__capEnv, out var __capSec) && __capSec > 0)
		{
			long capped = prog.StartEpoch + __capSec;
			if (capped < end) { end = capped; Log($"[replay] 调试截断：本次只播 {__capSec} 秒（PALMTV_REPLAY_CAP）"); }
		}
		var r = await YspAndroidLive.ResolveAsync(ch.CnlId, ch.Pid, prog.StartEpoch, end, m => Log(m));
		if (r == null)
		{
			SetStatus($"回看失败：{YspAndroidLive.LastError}", StatusKind.Error);
			return false;
		}
		try
		{
			_decServer ??= new LocalDecryptServer();
			LocalDecryptServer.Log = m => Log(m);
			_decServer.Start();
			_decServer.EnsureCore(ch.Pid);
			var local = LocalDecryptServer.LocalPlaylistUrl(r.Url, ch.CnlId);
			// ★ 先登记"正在回看哪一档"，再起播：`EndReached` 与节目条都靠它
			_replayProg = prog;
			PlayVlc(local, $"{ch.Name}（回看·{prog.Title}）");
			_isPlaying = true;
			BtnPlay.Content = "⏸ 暂停";
			SetStatus($"回看中 · {prog.Title}", StatusKind.Normal);
			UpdateChannelListVisual();
			UpdateProgramDisplay(_epgCache);   // ★ 节目条立刻切到这一档（不等 10 秒定时器）
			Log($"「{prog.Title}」→ 回看地址 {local[..Math.Min(110, local.Length)]}");
			return true;
		}
		catch (Exception ex)
		{
			SetStatus($"回看失败：{ex.Message}", StatusKind.Error);
			_replayProg = null;
			return false;
		}
	}

	/// <summary>
	/// ★ 2026-11-06：**回看播完 ⇒ 自动接下一档**（对齐安卓 `MainViewModel.autoNextReplay()`，
	/// 见 `docs/ysp-ckey/ref/drm/HANDOFF.md`「回看播完停在黑屏，不能接着看下一档」）。
	///
	/// 规则（与节目单同源，不另取网络）：
	///   · 取"起点晚于当前这档、**已播完**、**可回看**"里**起点最早**的一条 ⇒ 接着回看它；
	///   · 一条都没有（已是最新一档 / 后面都不可回看）⇒ **回直播**，不停在黑屏。
	/// ⚠️ 不按"当前档在列表里的下标 +1"取：EPG 与 `playbacktime` 差 1 秒就会 `idx=-1`
	///   （安卓踩过："07:05-07:06 播完在重复，没接 07:06-07:11"）。
	/// </summary>
	async Task OnVlcEndReachedAsync()
	{
		var prog = _replayProg;
		var ch = _current;
		if (prog == null || ch == null) return;      // 直播/时移自然结束 ⇒ 不管

		/* ★★ 2026-11-06（用户实测："11-05 的 06:00-06:01 那一分钟节目，要播两次才到 06:01"）★★
		 *   根因：`_epgCache` 是**今天**的节目单，而用户回看的可能是**昨天/前几天**的节目
		 *   ⇒ 在"今天"的列表里找"起点晚于它"的节目，命中的是**今天最早那档**；
		 *   而 4K 台每天 06:00 都有同名的一分钟"宣传片/标识演绎" ⇒ 看起来就是**同一档又播了一遍**，
		 *   播完才顺着今天的列表走到 06:01。
		 *   ⇒ 必须用**当前回看那档所属日期**的节目单（`EpgProgram.Day` = 拉取时的 yyyyMMdd）。 */
		string wantDay = string.IsNullOrEmpty(prog.Day) ? DateTime.Now.ToString("yyyyMMdd") : prog.Day;
		var list = _epgCache;
		string haveDay = list.Count > 0 ? list[0].Day : "";
		if ((list.Count == 0 || haveDay != wantDay) && !string.IsNullOrEmpty(ch.Pid))
		{
			var day = DateTime.TryParseExact(wantDay, "yyyyMMdd", null,
				System.Globalization.DateTimeStyles.None, out var d0) ? d0 : DateTime.Today;
			try
			{
				var fetched = await EpgClient.FetchAsync(ch.Pid, day);
				if (fetched.Count > 0) { list = fetched; haveDay = wantDay; }
				else Log($"[replay] 拉不到 {wantDay} 的节目单 ⇒ 改用现有列表找下一档");
			}
			catch { }
		}
		Log($"[replay] 结束接档：当前「{prog.Title}」day={prog.Day} 用 {list.Count} 条（day={haveDay}）找下一档");

		long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
		var next = list
			.Where(p => p.StartEpoch > prog.StartEpoch && p.EndEpoch > p.StartEpoch
					 && p.EndEpoch <= now && p.Replayable)
			.OrderBy(p => p.StartEpoch)
			.FirstOrDefault();

		if (next != null)
		{
			Log($"[replay] 「{prog.Title}」播完 ⇒ 自动接下一档「{next.Title}」（{next.StartTime}）", true);
			if (await PlayReplayAsync(next, ch)) return;
			Log("[replay] 下一档起播失败 ⇒ 回直播", true);
		}
		else
		{
			Log($"[replay] 「{prog.Title}」播完，后面没有可回看的节目 ⇒ 回直播", true);
		}
		_replayProg = null;
		PlayChannel(ch.Name);
	}

	/* ★★★ 2026-11-06：**时移** ★★★
	 *   与回看共用同一条接口，区别是**不传 endtime**（传了就变 VOD，会"停在某一段不再前进"）。
	 *   时移窗口由上游决定（安卓端实测约 2 小时），超出范围服务端直接报错。
	 *   `minutesBack = 0` 等价"回到直播"。 */
	async Task PlayTimeshiftAsync(int minutesBack)
	{
		var ch = _current;
		if (ch == null || string.IsNullOrEmpty(ch.Pid) || string.IsNullOrEmpty(ch.CnlId)) return;
		if (minutesBack <= 0) { PlayChannel(ch.Name); return; }

		_channelLive = false;
		_playbackLabel = $"时移中 · -{minutesBack} 分钟";
		BtnBackToLive.Visibility = Visibility.Visible;   // ★ 时移中 ⇒ 同样显示"回到直播"
		// ★ 2026-11-06：时移**不是**"节目单回看"（没有 ENDLIST，也不会自然播完）⇒ 清掉回看标记，
		//   否则节目条会一直挂着上一档回看的名字
		_replayProg = null;
		NowPlaying.Text = "正在播出：";
		NowPlaying.Foreground = NowLabelRed;
		UpdateProgramDisplay(_epgCache);
		SetStatus($"时移 · 回到 {minutesBack} 分钟前…", StatusKind.Busy);
		long pb = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - minutesBack * 60L;
		var r = await YspAndroidLive.ResolveAsync(ch.CnlId, ch.Pid, pb, null, m => Log(m));
		if (r == null)
		{
			SetStatus($"时移失败：{YspAndroidLive.LastError}", StatusKind.Error);
			return;
		}
		try
		{
			_decServer ??= new LocalDecryptServer();
			LocalDecryptServer.Log = m => Log(m);
			_decServer.Start();
			_decServer.EnsureCore(ch.Pid);
			var local = LocalDecryptServer.LocalPlaylistUrl(r.Url, ch.CnlId);
			PlayVlc(local, $"{ch.Name}（时移-{minutesBack}分）");
			_isPlaying = true;
			BtnPlay.Content = "⏸ 暂停";
			SetStatus($"时移中 · -{minutesBack} 分钟（右键可回到直播）", StatusKind.Busy);
			UpdateChannelListVisual();
		}
		catch (Exception ex)
		{
			SetStatus($"时移失败：{ex.Message}", StatusKind.Error);
		}
	}

	/// <summary>点击节目条 → 打开全屏节目单弹层（对齐安卓 `EpgStrip` 的 onOpen）。</summary>
	void EpgStrip_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
	{
		ShowEpgOverlay();
	}

	/// <summary>
	/// ★ 2026-11-06（用户要求：与安卓一致）：节目条右端「节目单 ☰」按钮。
	/// 与点节目条本体同一个入口（<see cref="ShowEpgOverlay"/>）；`e.Handled = true` 阻止冒泡到 EpgStrip。
	/// </summary>
	void BtnEpg_Click(object sender, RoutedEventArgs e)
	{
		e.Handled = true;
		ShowEpgOverlay();
	}

	/// <summary>节目条右侧「回到直播」：结束回看/时移。</summary>
	void BtnBackToLive_Click(object sender, RoutedEventArgs e)
	{
		// ★ 阻止冒泡到 EpgStrip（否则点按钮会同时打开节目单弹层）
		e.Handled = true;
		if (_current != null) PlayChannel(_current.Name);
	}

	/// <summary>打开全屏节目单覆盖层（前 6 后 3 天 = 10 天；点可回看条目直接起播 VOD）。</summary>
	void ShowEpgOverlay()
	{
		if (_current == null || string.IsNullOrEmpty(_current.Pid) || _current.Pid == "0")
		{
			SetStatus("该频道没有节目单", StatusKind.Busy);
			return;
		}
		// ★ 2026-11-06：把"正在回看的那一档"带进去 ⇒ 弹层里该行标红粗「回看中」，
		//   同时把正在直播那档退为绿色「直播中」（对齐安卓 `EpgModal` 的 liveSecondary）
		var w = new EpgOverlayWindow(_current, _replayProg) { Owner = this };
		w.ReplayRequested += (prog, ch) =>
		{
			w.Close();
			_ = PlayReplayAsync(prog, ch);
		};
		w.ShowDialog();
	}

	MenuItem MakeMenuItem(string text, Action action)
    {
        var item = new MenuItem { Header = text, Style = (Style)FindResource("DarkMenuItem") };
        item.Click += (_, _) => action();
        return item;
    }

    MenuItem MakeSubMenu(string text)
    {
        return new MenuItem { Header = text + "  ▸", Style = (Style)FindResource("DarkMenuItem") };
    }

    void ToggleFullscreen()
    {
        _fullscreen = !_fullscreen;
        if (_fullscreen)
        {
            _fsRestoreRect = new Rect(Left, Top, Width, Height);
            _fsRestoreState = WindowState;
            _wasMaximizedBeforeFs = _isMaximized;
            ResizeMode = ResizeMode.NoResize;
            TitleBarRow.Height = new GridLength(0);
            OuterBorder.CornerRadius = new CornerRadius(0);
            OuterBorder.BorderThickness = new Thickness(0);
            WindowChrome.SetWindowChrome(this, null);
            Topmost = true;
            WindowState = WindowState.Maximized;
            // ★ 2026-11-10：全屏去掉左栏那 8px 内边距（画面铺满）
            LeftPane.Margin = new Thickness(0);
            _uiVisible = false;
            /* ★★ 2026-11-06（用户要求："全屏后不要上面的状态栏和下面的节目条"）★★
             *   对齐安卓全屏语义（`TvHomeScreen` 的全屏分支）：**画面铺满 + 只有底部控制行**，
             *   状态栏与节目条**始终不出现**（安卓那边是彻底不组合这两块，不是"随 HUD 淡出"）。
             *   ⇒ 这里用 `Collapsed`（连布局空间一起收掉），画面区随之变高。
             *   ⚠️ 与 Sidebar / BottomBar 不同：那两个是"鼠标一动就回来"的 HUD 成员，
             *      StatusBar / EpgStrip **不参与** `ApplyFullscreenUI` 的显隐轮换（全程隐藏）。 */
            StatusBar.Visibility = Visibility.Collapsed;
            EpgStrip.Visibility = Visibility.Collapsed;
            ApplyFullscreenUI();
            SetFullscreenCursor(Cursors.None);
            _lastMoveTime = DateTime.Now;
            GetCursorPos(ref _lastMousePos);
            _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            _pollTimer.Tick += FullscreenPollMouse;
            _pollTimer.Start();
        }
        else
        {
            _pollTimer?.Stop(); _pollTimer = null;
            _hideTimer?.Stop(); _hideTimer = null;
            SetFullscreenCursor(Cursors.Arrow);
            _uiVisible = true;
            SidebarCol.Width = _sidebarWidth;   // ★ 还原完整的 GridLength（含 Star 单位）
            Sidebar.Visibility = Visibility.Visible;
            BottomBar.Visibility = Visibility.Visible;
            // ★ 2026-11-06：退出全屏 ⇒ 状态栏 + 节目条恢复（进全屏时被 Collapsed，见上）
            StatusBar.Visibility = Visibility.Visible;
            EpgStrip.Visibility = Visibility.Visible;
            // ★ 2026-11-10：窗口模式恢复左栏 8px 内边距（与 XAML 初始值一致）
            LeftPane.Margin = new Thickness(8, 0, 0, 0);
            Topmost = false;
            ResizeMode = ResizeMode.CanResize;
            TitleBarRow.Height = new GridLength(36);
            OuterBorder.CornerRadius = new CornerRadius(10);
            OuterBorder.BorderThickness = new Thickness(1);
            // ★ 用全屏专用字段恢复, 不污染 BtnMaxRestore 的 _normalRect/_normalState
            WindowState = _fsRestoreState;
            _isMaximized = _wasMaximizedBeforeFs;
            BtnMaxRestore.Content = _isMaximized ? "❐" : "□";
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, GlassFrameThickness = new Thickness(0),
                CornerRadius = new CornerRadius(10), ResizeBorderThickness = new Thickness(4) });
            Left = _fsRestoreRect.Left;
            Top = _fsRestoreRect.Top;
            Width = _fsRestoreRect.Width;
            Height = _fsRestoreRect.Height;
        }
    }

    void FullscreenPollMouse(object? s, EventArgs e)
    {
        var pos = new POINT();
        GetCursorPos(ref pos);
        // 屏幕绝对坐标比较, 不受 UI 布局变化影响
        if (pos.X != _lastMousePos.X || pos.Y != _lastMousePos.Y)
        {
            _lastMoveTime = DateTime.Now;
            _lastMousePos = pos;
            if (!_uiVisible)
            {
                _uiVisible = true;
                ApplyFullscreenUI();
                SetFullscreenCursor(Cursors.Arrow);
            }
        }
        else if (_uiVisible && (DateTime.Now - _lastMoveTime).TotalSeconds > 2)
        {
            _uiVisible = false;
            ApplyFullscreenUI();
            SetFullscreenCursor(Cursors.None);
        }
    }

    /// <summary>
    /// ★★ 2026-11-06（用户："全屏后移动鼠标时右侧频道图标太宽了"）★★ 全屏下侧栏的**像素上限**。
    ///
    /// 侧栏列是 `30*`（占 30%）：窗口 1100 宽时 ≈330px，3 列 72px 圆看着正好；
    /// 但 1080p 全屏是 1920×0.30 = **576px** ⇒ 圆与圆之间空出 ~150px，视觉上"散得很宽"。
    /// ⇒ 全屏时改用 `min(30%, 360px)`：1920 下每格 ≈109px，与窗口模式手感一致，画面还多出 200px。
    /// ⚠️ 只影响**全屏 HUD**；窗口模式仍然用 XAML 里的 `30*`（`_sidebarWidth` 原样还原）。
    /// </summary>
    const double FsSidebarMaxPx = 360;

    /// <summary>当前模式下的侧栏列宽：窗口 = 原 Star；全屏 = min(30%, <see cref="FsSidebarMaxPx"/>)。</summary>
    GridLength SidebarWidthForCurrentMode()
    {
        if (!_fullscreen) return _sidebarWidth;
        // 进全屏那一刻 ActualWidth 可能还是旧值（UiVisible=false 时本来就是 0 宽，等到鼠标唤醒时已刷新）
        double w = ActualWidth > 0 ? ActualWidth : SystemParameters.PrimaryScreenWidth;
        return new GridLength(Math.Min(w * 0.30, FsSidebarMaxPx));   // 0.30 = 30/(30+70)，与 XAML 的 30*/70* 同源
    }

    void ApplyFullscreenUI()
    {
        if (_uiVisible)
        {
            SidebarCol.Width = SidebarWidthForCurrentMode();   // ★ 全屏另有像素上限，见 FsSidebarMaxPx
            Sidebar.Visibility = Visibility.Visible;
            BottomBar.Visibility = Visibility.Visible;
        }
        else
        {
            SidebarCol.Width = new GridLength(0);
            Sidebar.Visibility = Visibility.Collapsed;
            BottomBar.Visibility = Visibility.Collapsed;
        }
    }

    bool _isPlaying;

    async void BtnPlay_Click(object s, RoutedEventArgs e)
    {
        if (!_isPlaying)
        {
            // ★ VLC 模式下"继续播"直接恢复，不必重走取流（省一次 auth/签名/换台抖动）
            if (VLC_MODE && _vlcUrl.Length > 0 && _vlcMp?.Media != null)
            {
                try
                {
                    _vlcMp.Play();
                    _isPlaying = true;
                    BtnPlay.Content = "⏸ 暂停";
                    StatusText.Text = $"播放中 · {_playingChannelName}";
                    return;
                }
                catch { }
            }
            if (_selectedTile != null) PlayChannel(_selectedTile.Name);
        }
        else
        {
            _isPlaying = false;
            BtnPlay.Content = "▶ 播放";
            NowPlaying.Text = "正在播出：";
            StatusText.Text = "已暂停";
            if (_vlcMp != null) { try { _vlcMp.Pause(); } catch { } }
        }
    }

    async void BtnStop_Click(object s, RoutedEventArgs e)
    {
        _isPlaying = false;
        BtnPlay.Content = "▶ 播放";
        if (VLC_MODE) StopVlc();
        BtnStop_EpgDisabled();
        // ★ P3b：原页内清理（hls.stopLoad/destroy + NavigateToString 显示"已停止"页）已删除；
        //   VLC 由 StopVlc() 停止，画面即黑（VlcView Background=Black），无需页内兜底 HTML。
        NowPlaying.Text = "已停止";
        StatusText.Text = "就绪";
    }

    void BtnPrev_Click(object s, RoutedEventArgs e) => PlayAdjacent(-1);
    void BtnNext_Click(object s, RoutedEventArgs e) => PlayAdjacent(1);
    void BtnFull_Click(object s, RoutedEventArgs e) => ToggleFullscreen();

    void TitleBar_Drag(object s, MouseButtonEventArgs e) { if (e.ClickCount == 1) DragMove(); }
    void BtnMinimize_Click(object s, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    bool _isMaximized;
    bool _wasMaximizedBeforeFs;  // ★ 进入全屏前是否已最大化
    void BtnMaxRestore_Click(object s, RoutedEventArgs e)
    {
        if (_isMaximized)
        {
            _isMaximized = false;
            WindowState = WindowState.Normal;
            Left = _normalRect.Left; Top = _normalRect.Top;
            Width = _normalRect.Width; Height = _normalRect.Height;
            BtnMaxRestore.Content = "□";
        }
        else
        {
            // AllowsTransparency=True 时 Maximized 会覆盖任务栏 → 用工作区手动定位
            _isMaximized = true;
            _normalRect = new Rect(Left, Top, Width, Height);
            var wa = SystemParameters.WorkArea;
            WindowState = WindowState.Normal;
            Left = wa.Left; Top = wa.Top;
            Width = wa.Width; Height = wa.Height;
            BtnMaxRestore.Content = "❐";
        }
    }
    void BtnClose_Click(object s, RoutedEventArgs e) => Close();
    void TitleBtn_MouseEnter(object s, MouseEventArgs e) { }
    void TitleBtn_MouseLeave(object s, MouseEventArgs e) { }


    void VolSlider_ValueChanged(object s, RoutedPropertyChangedEventArgs<double> e)
    {
        // ★ P3b：音量交给 VLC（原为注入 JS 改页面 <video>.volume，页内播放器已摘除）
        if (_vlcMp != null) { try { _vlcMp.Volume = (int)VolSlider.Value; } catch { } }
    }

    void Log(string msg, bool userFacing = false)
    {
        // ★ 联调 (2026-09-01): 所有 C# 日志镜像落盘到 player-debug.log（[JS] 消息已由 HandleWebMessage 落盘）
        //   状态栏仍保持精简, 但文件里保留全量链路, 便于离线诊断。
        if (DEBUG_LOG)
            try { File.AppendAllText(System.IO.Path.Combine(AppDir, "player-debug.log"),
                $"[{DateTime.Now:HH:mm:ss.fff}] [CS] {msg}\n"); } catch { }
        // ★ 调试日志关闭时: 只放行用户可见提示, 其余诊断消息全部丢弃
        if (!DEBUG_LOG && !userFacing) return;
        // ★ 状态精简: 只显示关键信息；静默掉过于频繁的 diagnostic 消息
        if (msg.Contains("auth签名") || msg.Contains("MEDIA") || msg.Contains("wasm")
            || msg.Contains("cKey") || msg.Contains("yspticket") || msg.Contains("player.served")
            || msg.Contains("[JS]") || msg.Contains("m3u8获取") || msg.Contains("Go 代理"))
            return;
        SetStatus(msg, StatusKind.Normal);
    }

    protected override void OnClosed(EventArgs e)
    {
        _loadCts?.Cancel();
        // ★ 2026-11-05：不再有 proxy 子进程需要回收
        base.OnClosed(e);
    }
}
