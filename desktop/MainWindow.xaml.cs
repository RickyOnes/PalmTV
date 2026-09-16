using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Wpf;
using Microsoft.Web.WebView2.Core;

namespace PalmTVDesktop;

public partial class MainWindow : Window
{
    TvChannel? _current;
    bool _fullscreen;
    bool _webViewReady;
    CoreWebView2Environment? _webViewEnv;
    // ★ 单文件发布下, AppDir 指向临时解压目录(无伴生文件). 改用 exe 真实所在目录.
    static readonly string AppDir = System.IO.Path.GetDirectoryName(Environment.ProcessPath)!;
    Rect _normalRect;
    Rect _fsRestoreRect;      // ★ 全屏专用: 退出全屏时的位置大小 (不与 BtnMaxRestore 的 _normalRect 混淆)
    WindowState _fsRestoreState;  // ★ 全屏专用: 退出全屏时的窗口状态
    CancellationTokenSource? _loadCts;
    System.Diagnostics.Process? _proxyProcess;
    TaskCompletionSource<string>? _signatureTcs;
    TaskCompletionSource<string>? _tokenRndTcs;
    // hls.js 致命错误恢复
    bool _needRecoverAfterNav;
    string _recoverChName = "";
    // kvcollect 心跳
    System.Threading.Timer? _kvTimer;
    string _kvPid = "", _kvM3u8 = "";
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
    static readonly bool DEBUG_LOG = false;

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
        // ★ 单文件发布: 从嵌入资源释放所有文件到临时目录
        // 加载图标
        var iconPath = System.IO.Path.Combine(AppDir, "tv-icon.ico");
        if (System.IO.File.Exists(iconPath))
        {
            using var fs = new System.IO.FileStream(iconPath, System.IO.FileMode.Open, System.IO.FileAccess.Read);
            var decoder = System.Windows.Media.Imaging.BitmapDecoder.Create(fs,
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
        RefreshChannelList();
        InitializeWebView();
    }

    async void InitializeWebView()
    {
        try
        {
            var opts = new CoreWebView2EnvironmentOptions
            {
                AdditionalBrowserArguments =
                    "--enable-gpu-rasterization " +
                    "--enable-features=UseChromeOSDirectVideoDecoder " +
                    "--autoplay-policy=no-user-gesture-required"
            };
            var userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "desktop", "WebView2");
            Directory.CreateDirectory(userData);
            var env = await CoreWebView2Environment.CreateAsync(null, userData, opts);
            _webViewEnv = env;
            await OfficialWebView.EnsureCoreWebView2Async(env);
            OfficialWebView.DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 26, 26, 46);
            // 初始显示提示页
            OfficialWebView.CoreWebView2.NavigateToString(
                "<html><body style='margin:0;background:#1A1A2E;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif'>" +
                "<div style='text-align:center;color:#555'><div style='font-size:48px;margin-bottom:16px'>📺</div>" +
                "<div style='font-size:18px'>双击左侧频道开始播放</div>" +
                "<div style='font-size:13px;margin-top:8px;color:#444'>或右键视频区切换频道</div></div></body></html>");
            var settings = OfficialWebView.CoreWebView2.Settings;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreDevToolsEnabled = false;
            settings.IsZoomControlEnabled = false;
            settings.AreBrowserAcceleratorKeysEnabled = false;
            settings.IsStatusBarEnabled = false;
            OfficialWebView.CoreWebView2.WebMessageReceived += (s, e) =>
            {
                Dispatcher.Invoke(() => HandleWebMessage(e.WebMessageAsJson));
            };
            // ★ 给 CDN / 官方域请求注入 Referer, 解决 TS 分片与解密 key 的防盗链
            //   (WebView2 以 file:// 加载 player.html, 向 *.cctv.cn 请求时 Referer 为空/被拒
            //    → TS/KEY 请求 403 → hls.js demux 失败 → otherError/internalException)
            OfficialWebView.CoreWebView2.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            OfficialWebView.CoreWebView2.WebResourceRequested += (s, e) =>
            {
                var uri = e.Request.Uri;
                // ★ 拦截 yangshipin.cn 主文档与 /sapi 资源, 用本地内容/Go代理服务,
                //   使 WebView2 真实 location.href = yangshipin.cn (CMG 解密种子来源),
                //   从而复刻官方站点行为 (InitPlayer 读 location.href 派生解密密钥)。
                if (uri.StartsWith("https://yangshipin.cn/", StringComparison.OrdinalIgnoreCase))
                {
                    var deferral = e.GetDeferral();
                    _ = ServeYangshipinAsync(e, deferral);
                    return;
                }
                // ★ 给 CDN / 官方域请求注入 Referer, 解决 TS 分片与解密 key 的防盗链
                if (uri.Contains("cctv.cn", StringComparison.OrdinalIgnoreCase)
                    || uri.Contains("yangshipin.cn", StringComparison.OrdinalIgnoreCase))
                {
                    try { e.Request.Headers.SetHeader("Referer", "https://yangshipin.cn/"); } catch { }
                    try { e.Request.Headers.SetHeader("Origin", "https://yangshipin.cn"); } catch { }
                }
            };
            // ★ 注入 JS hook 在 player.html 已自带, 此处不需要
            _webViewReady = true;
            // ★ 联调: 命令行 --ch <频道名> 启动即自动播放 (如 PalmTV.Desktop.exe --ch CCTV-1)
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
            // 右键菜单: JS 注入 contextmenu 事件 → postMessage → C# ContextMenu
            OfficialWebView.CoreWebView2.NavigationCompleted += (s, e) =>
            {
                OfficialWebView.CoreWebView2.ExecuteScriptAsync(
                    "document.addEventListener('contextmenu',function(e){e.preventDefault();window.chrome.webview.postMessage({menu:1});});" +
                    "document.addEventListener('dblclick',function(e){window.chrome.webview.postMessage({dblclick:1});});");
            };
        }
        catch (Exception ex)
        {
            Log($"WebView2 初始化失败: {ex.Message}", true);
            _webViewReady = false;
        }
    }

    // ★ 拦截 yangshipin.cn 资源: 主文档返回本地注入后的 player.served.html,
    //   /sapi/* 代理到本地 Go 代理 (保持 hls.cmg.js/cmg.worker.js 的同源注入)。
    //   这样页面真实 origin = https://yangshipin.cn, location.href 与官方一致,
    //   CMG 的 InitPlayer 才能从正确的种子派生解密密钥。
    async Task ServeYangshipinAsync(CoreWebView2WebResourceRequestedEventArgs e, CoreWebView2Deferral deferral)
    {
        try
        {
            var u = new Uri(e.Request.Uri);
            if (u.AbsolutePath.StartsWith("/sapi", StringComparison.OrdinalIgnoreCase))
            {
                var localUrl = "http://127.0.0.1:18888" + u.PathAndQuery;
                using var cli = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
                var resp = await cli.GetAsync(localUrl);
                var bytes = await resp.Content.ReadAsByteArrayAsync();
                var ms = new MemoryStream(bytes);
                var ct = resp.Content.Headers.ContentType?.ToString() ?? "application/javascript";
                e.Response = _webViewEnv!.CreateWebResourceResponse(ms, 200, "OK",
                    $"Content-Type: {ct}\r\nCache-Control: no-store");
            }
            else
            {
                // 主文档 (如 /tv/home?pid=...): 返回本地注入后的 player.served.html
                var htmlPath = System.IO.Path.Combine(AppDir, "player.served.html");
                if (File.Exists(htmlPath))
                {
                    var ms = new MemoryStream(File.ReadAllBytes(htmlPath));
                    e.Response = _webViewEnv!.CreateWebResourceResponse(ms, 200, "OK",
                        "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store");
                }
                else
                {
                    // 兜底: 代理到本地 /player
                    using var cli = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
                    var resp = await cli.GetAsync("http://127.0.0.1:18888/player");
                    var bytes = await resp.Content.ReadAsByteArrayAsync();
                    var ms = new MemoryStream(bytes);
                    e.Response = _webViewEnv!.CreateWebResourceResponse(ms, 200, "OK",
                        "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store");
                }
            }
        }
        catch (Exception ex)
        {
            Log($"WebResource 拦截失败: {ex.Message} uri={e.Request.Uri}");
        }
        finally
        {
            deferral.Complete();
        }
    }

    void HandleWebMessage(string json)
    {
        // ★ 调试日志关闭时: 在 JSON 解析之前直接丢弃页面诊断消息(零开销, 播放期每秒可达数十条)
        if (!DEBUG_LOG && json.Length > 6 &&
            (json.StartsWith("{\"log\"", StringComparison.Ordinal) || json.StartsWith("{\"err\"", StringComparison.Ordinal)))
            return;

        System.Text.Json.Nodes.JsonNode? obj = null;
        try
        {
            obj = System.Text.Json.Nodes.JsonNode.Parse(json);
            if (obj?["log"] != null)
            {
                // ★ 联调: JS 日志落盘 (CMGDEC/CMG/FIX-PB/ slim 等解密诊断全靠它)
                if (DEBUG_LOG)
                    try { File.AppendAllText(System.IO.Path.Combine(AppDir, "player-debug.log"),
                        $"[{DateTime.Now:HH:mm:ss.fff}] {obj["log"]}\n"); } catch { }
                Log($"[JS] {obj["log"]}");
                return;
            }
            if (obj?["err"] != null)
            {
                if (DEBUG_LOG)
                    try { File.AppendAllText(System.IO.Path.Combine(AppDir, "player-debug.log"),
                        $"[{DateTime.Now:HH:mm:ss.fff}] [ERR] {obj["err"]}\n"); } catch { }
                Log($"[JS-ERR] {obj["err"]}");
                return;
            }
        }
        catch { }
        _signatureTcs?.TrySetResult(json);
        if (obj?["tokenRnd"] != null) { _tokenRndTcs?.TrySetResult(json); return; }
        // 右键菜单 (JS contextmenu → postMessage)
        if (obj?["menu"] != null) { Dispatcher.BeginInvoke(() => ShowVideoContextMenu()); return; }
        // 双击全屏切换 (JS dblclick → postMessage)
        if (obj?["dblclick"] != null) { Dispatcher.BeginInvoke(() => ToggleFullscreen()); return; }
        // ★ hls.js 致命错误恢复: 重新加载页面并自动拉流
        if (obj?["fatal"] != null)
        {
            var msg = obj["fatal"]!.ToString();
            //Log($"[HLS-FATAL] {msg} → 重载页面");
            _needRecoverAfterNav = true;
            _recoverChName = _current?.Name ?? "CCTV-1";
            try { OfficialWebView.CoreWebView2?.Reload(); } catch { }
            return;
        }
    }

    void RefreshChannelList(string? filter = null)
    {
        if (ChannelList == null) return;
        var all = TvApiClient.Channels.Select(c => c.Name).ToList();
        if (!string.IsNullOrWhiteSpace(filter))
            all = all.Where(n => n.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();
        ChannelList.ItemsSource = all;
    }

    // NormalizeName 方法已被删除（从未使用）

    void Window_Loaded(object sender, RoutedEventArgs e)
    {
        RefreshChannelList();
        ChannelList.SelectedIndex = 0;
        OfficialWebView.Visibility = Visibility.Visible;
        StartProxy();
        // ★ 启动后异步预热 CDN/API 域名连接 (代理 /warm), 加快后续首次/换台请求
        _ = WarmProxyAsync();
        // ★ 阻止 Windows 屏保/休眠 (媒体播放器标准行为)
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        // ★ 启动时就把 player.served.html 准备好, 换台时直接导航(旧逻辑每次换台重建一次 1.5MB 文件)
        EnsureServedHtml();
        Log("就绪 — 双击频道播放", true);
    }

    void CopyDirectory(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src))
            File.Copy(f, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(f)), true);
        foreach (var d in Directory.GetDirectories(src))
            CopyDirectory(d, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(d)));
    }

    void StartProxy()
    {
        try
        {
            // ★ 同时检查安装目录和 temp 解压目录
            var proxyPath = System.IO.Path.Combine(AppDir, "proxy.exe");
            if (!File.Exists(proxyPath))
                proxyPath = System.IO.Path.Combine(AppContext.BaseDirectory, "proxy.exe");
            if (!File.Exists(proxyPath)) { Log($"proxy.exe 未找到: {proxyPath}", true); return; }

            // ★ 确保 sapi_cache 在 proxy.exe 旁边 (单文件发布 .NET 会把 proxy.exe 解压到 temp, 但 sapi_cache 不会)
            var proxyDir = System.IO.Path.GetDirectoryName(proxyPath)!;
            var cacheSrc = System.IO.Path.Combine(AppDir, "sapi_cache");
            var cacheDst = System.IO.Path.Combine(proxyDir, "sapi_cache");
            if (Directory.Exists(cacheSrc) && !Directory.Exists(cacheDst))
            {
                CopyDirectory(cacheSrc, cacheDst);
                Log($"[proxy] sapi_cache 已复制到 {cacheDst}");
            }

            // ★ 先杀旧进程, 避免端口占用
            foreach (var p in System.Diagnostics.Process.GetProcessesByName("proxy"))
            {
                try { p.Kill(); p.WaitForExit(1000); } catch { }
            }
            _proxyProcess = new System.Diagnostics.Process
            {
                StartInfo = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = proxyPath,
                    WorkingDirectory = proxyDir,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
                EnableRaisingEvents = true,
            };
            _proxyProcess.OutputDataReceived += (s, e) =>
            {
                if (DEBUG_LOG && !string.IsNullOrEmpty(e.Data))
                    File.AppendAllText(System.IO.Path.Combine(proxyDir, "proxy.log"), $"[{DateTime.Now:HH:mm:ss}] {e.Data}\n");
            };
            _proxyProcess.ErrorDataReceived += (s, e) =>
            {
                if (DEBUG_LOG && !string.IsNullOrEmpty(e.Data))
                    File.AppendAllText(System.IO.Path.Combine(proxyDir, "proxy.log"), $"[{DateTime.Now:HH:mm:ss}] ERR {e.Data}\n");
            };
            _proxyProcess.Start();
            _proxyProcess.BeginOutputReadLine();
            _proxyProcess.BeginErrorReadLine();
         //   Log("Go 代理已启动 (Chrome TLS 指纹)");
        }
        catch (Exception ex) { Log($"Go 代理启动失败: {ex.Message}", true); }
    }

    // ★ 启动后异步预热 CDN/API 域名 (代理 /warm): DNS + TLS 握手并留空闲连接,
    //   加快后续首次请求 / 换台 (2026-09-04, 仅预热不缓存内容)。
    async Task WarmProxyAsync()
    {
        try
        {
            using var hc = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            for (int i = 0; i < 50; i++)   // 等代理就绪 (~最长 15s)
            {
                try
                {
                    var txt = await hc.GetStringAsync("http://127.0.0.1:18888/warm");
                    Log("[warm] " + (txt.Length > 260 ? txt.Substring(0, 260) : txt).Replace("\n", " | "));
                    return;
                }
                catch { await Task.Delay(300); }
            }
        }
        catch (Exception ex) { Log($"[warm] 预热失败: {ex.Message}"); }
    }

    async void PlayChannel(string chName)
    {
        _loadCts?.Cancel();
        _loadCts = new CancellationTokenSource();
        await PlayOfficialAsync(chName);
    }

    // ★ player.served.html 构建结果缓存 (进程内只构建一次)
    bool _servedHtmlReady;

    // ★ 生成(或复用) player.served.html = player.html + 三个注入资产(base64 内联)。
    //   旧逻辑: 每次换台都重建一遍 (读 44KB + 3 次 base64 编码≈1.1MB + 写 1.5MB) —— 换台卡顿的主因之一。
    //   新逻辑: 进程内只构建一次; 若磁盘已有 served html 且不比 player.html 旧, 直接复用。
    //   ★ 因此发布包可以只带预生成的 player.served.html, 不必带 player.html / keygen_bg.wasm /
    //     ts_module_body.js / RJq7sO71JF.wasm (它们只在"重建"时才需要)。
    void EnsureServedHtml()
    {
        if (_servedHtmlReady) return;
        var servedPath = System.IO.Path.Combine(AppDir, "player.served.html");
        var htmlPath = System.IO.Path.Combine(AppDir, "player.html");
        var wasmPath = System.IO.Path.Combine(AppDir, "keygen_bg.wasm");
        var ckeyPath = System.IO.Path.Combine(AppDir, "ts_module_body.js");
        var yspPath = System.IO.Path.Combine(AppDir, "RJq7sO71JF.wasm");

        bool haveHtml = File.Exists(htmlPath);
        bool canBuild = haveHtml && File.Exists(wasmPath) && File.Exists(ckeyPath) && File.Exists(yspPath);

        if (File.Exists(servedPath))
        {
            // ★ 发布包场景: 无源文件, 或 served 已不比 player.html 旧 → 直接复用, 不重建
            if (!canBuild || File.GetLastWriteTimeUtc(htmlPath) <= File.GetLastWriteTimeUtc(servedPath))
            {
                _servedHtmlReady = true;
                return;
            }
        }
        if (!haveHtml) { Log("player.html 缺失", true); return; }
        if (!canBuild)
        {
            Log("player.served.html 缺失且无法重建(注入资产不全)", true);
            return;
        }

        try
        {
            string html = File.ReadAllText(htmlPath, System.Text.Encoding.UTF8);
            // ★ keygen_bg.wasm: 页内 get_signature / get_token_rnd (openapi 签名链)
            html = html.Replace("<!-- WASM_BASE64 -->",
                $"<script>window.__wasmBase64='{Convert.ToBase64String(File.ReadAllBytes(wasmPath))}'</script>");
            // ★ ts_module_body.js: 官方 chunk-vendors 模块 fb15, cKey 动态生成核心
            html = html.Replace("<!-- CKEY_CORE -->",
                $"<script>window.__ckeyCoreB64='{Convert.ToBase64String(File.ReadAllBytes(ckeyPath))}'</script>");
            // ★ RJq7sO71JF.wasm: 页内 window.__genYspTicket 复刻官方 _c, 浏览器原生 V8, 零网络依赖
            html = html.Replace("<!-- YSPTICKET_WASM -->",
                $"<script>window.__yspTicketWasmB64='{Convert.ToBase64String(File.ReadAllBytes(yspPath))}'</script>");
            File.WriteAllText(servedPath, html, System.Text.Encoding.UTF8);
            _servedHtmlReady = true;
        }
        catch (Exception ex) { Log($"player.served.html 生成失败: {ex.Message}", true); }
    }

    async Task PlayOfficialAsync(string chName)
    {
        if (!_webViewReady) { Log("WebView2 未就绪", true); return; }

		//StatusText.Text = $"{chName} [官方源]";
        NowPlaying.Text = chName;
        NowProg.Text = "";
        NextProg.Text = "";
        _playingChannelName = chName;
        _recoverChName = chName;

        var tvCh = TvApiClient.Channels.FirstOrDefault(c =>
            c.Name.StartsWith(chName, StringComparison.OrdinalIgnoreCase)
            || chName.Contains(c.Name, StringComparison.OrdinalIgnoreCase)
            || c.Name.Contains(chName, StringComparison.OrdinalIgnoreCase));
        if (tvCh == null || tvCh.Pid == "0" || string.IsNullOrEmpty(tvCh.Pid))
        {
            _current = new TvChannel { Name = chName };
            OfficialWebView.CoreWebView2.Navigate($"https://yangshipin.cn/search?q={Uri.EscapeDataString(chName)}");
            OfficialWebView.Visibility = Visibility.Visible;
            return;
        }
        _current = tvCh;

        OfficialWebView.Visibility = Visibility.Visible;

        try
        {
            EnsureServedHtml();
            if (!_servedHtmlReady) return;

            var navTcs = new TaskCompletionSource<bool>();
            void OnNav(object? s, CoreWebView2NavigationCompletedEventArgs e)
            {
                navTcs.TrySetResult(e.IsSuccess);
                // ★ hls.js 致命错误恢复: 重载完成后, 重新拉流
                if (_needRecoverAfterNav && e.IsSuccess)
                {
                    _needRecoverAfterNav = false;
                    var rch = _recoverChName;
                    _recoverChName = "";
                  //  Log($"[HLS-FATAL] 重载完成, 恢复 {rch} 拉流");
                    Dispatcher.InvokeAsync(async () =>
                    {
                        try
                        {
                            var rc = TvApiClient.Channels.First(c =>
                                c.Name.StartsWith(rch, StringComparison.OrdinalIgnoreCase)
                                || rch.Contains(c.Name, StringComparison.OrdinalIgnoreCase));
                            await FetchViaPostMessage(rc);
                        }
                        catch (Exception ex) { Log($"[HLS-FATAL] 恢复失败: {ex.Message}", true); }
                    });
                }
            }
            OfficialWebView.CoreWebView2.NavigationCompleted += OnNav;
            // ★ 第二轮联调 (2026-09-01): 默认本地导航 http://127.0.0.1:18888/player, 不再跳转官网。
            //   依据 (Node 实证): wasm 取 location 的唯一出口 eval("self.location.host|href|protocol"),
            //   已被 player.html 的 WEVAL hook 用伪 location(yangshipin.cn) 拦截; 真正参与密钥派生的
            //   种子是 self.activeURL(预置完整 FAKE_HREF, 与官网场景逐字节一致)。
            //   cKey/yspticket/open-token 的 URL 均为 C# 显式传参, 不依赖真实导航。
            //   --nav=official 可切回官网跳转模式做 A/B 对比。
            var __navArgs = Environment.GetCommandLineArgs();
            var __navIdx = Array.FindIndex(__navArgs, a => a != null && a.StartsWith("--nav="));
            var __useLocal = !(__navIdx >= 0 && __navArgs[__navIdx].EndsWith("official"));
            if (__useLocal)
            {
                Log("[联调] 导航模式: 本地 (不跳官网)");
                OfficialWebView.CoreWebView2.Navigate("http://127.0.0.1:18888/player");
            }
            else
            {
                Log("[联调] 导航模式: 官网跳转");
                OfficialWebView.CoreWebView2.Navigate($"https://yangshipin.cn/tv/home?pid={tvCh.Pid}");
            }
            await Task.WhenAny(navTcs.Task, Task.Delay(10000));
            OfficialWebView.CoreWebView2.NavigationCompleted -= OnNav;

            //StatusText.Text = $"{chName} [CMG]";
            await FetchViaPostMessage(tvCh);
        }
        catch (Exception ex) { Log($"错误: {ex.Message}", true); }
    }

    // ===== 动态生成 cKey (替换原先硬编码的 TvApiClient.LiveCKey) =====
    // 通过已加载 cKey shim 的 WebView2 执行官方 chunk-vendors 模块 fb15 的 ts(),
    // 用 env-stub 精确复刻浏览器环境 (document.URL / navigator.userAgent / referrer),
    // 因此无需手动 F12 抓包即可生成与官方一致的 324 字符 cKey。
    async Task<string?> GenerateCKeyAsync(TvChannel ch)
    {
        if (OfficialWebView.CoreWebView2 == null) { Log("WebView2 未就绪, 无法生成 cKey"); return null; }
        try
        {
            // ★ 用【当前时间】作为 cKey 种子, 严格对齐官方 ru(): u=Math.round(Date.now()/1000)
            //   (官方 cKey 用当前时间, 仅 yspticket 才用 auth ts)。最小化 cKey ts 与请求的时间差,
            //   避免服务器 cKey 时效窗口 (error 85 防盗链cKey参数校验失败 → 20401) 拒绝。
            var tsSec = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
            var url = $"https://yangshipin.cn/tv/home?pid={ch.Pid}";
            var safeUrl = url.Replace("\\", "\\\\").Replace("'", "\\'");
            var js = $"window.__genCKey('{ch.CnlId}','{tsSec}','V1.0.0','{TvApiClient.Guid}','5910204','{safeUrl}')";
            var res = await OfficialWebView.CoreWebView2.ExecuteScriptAsync(js);
            // ExecuteScriptAsync 返回 JSON 字符串 (带引号), 解析为普通字符串
            if (!string.IsNullOrEmpty(res) && res.Length > 1)
            {
                var str = System.Text.Json.JsonDocument.Parse(res).RootElement.GetString();
                if (!string.IsNullOrEmpty(str)) { Log($"cKey 生成成功 ({str.Length} 字符)"); return str; }
            }
          //  Log("cKey 生成返回空");
        }
        catch (Exception ex) { Log($"cKey 生成异常: {ex.Message}"); }
        return null;
    }

    // ===== 动态生成 yspticket (替换原先硬编码的 TvApiClient.YspTicket) =====
    // 通过已加载 yspticket wasm 的 WebView2 执行复刻官方 _c(livepid, ts, cnlid, guid, yspappid, appVer):
    //   - 内部调用 RJq7sO71JF.wasm 的 AES-CTR (_aes_encrypt_ctr 导出 T) 对
    //     livepid|ts|guid|yspappid + PCG尾缀 加密, 输出 62 字节 hex。
    //   - ts 用认证返回的 authTs (秒): 既是 _c 第2参数, 又是 wasm _time/PCG 种子。
    //   - guid 用 Cookie 里的 TvApiClient.Guid, yspappid 用 TvApiClient.YspAppId。
    //   - 任何异常/超时都回退到硬编码 TvApiClient.YspTicket, 不影响其它流程。
    // 攻破要点详见内部实现记录: AES-CTR 密钥/IV 为 wasm 内常量,
    // cnlid/appVer 参与传参但 plaintext 不含它们, 尾缀为 _time 播种的 PCG 随机数。
    async Task<string> GenerateYspTicketAsync(TvChannel ch, string authTs)
    {
        try
        {
            if (OfficialWebView.CoreWebView2 == null) { Log("WebView2 未就绪, 回退 yspticket"); return TvApiClient.YspTicket; }
            var js = $"window.__genYspTicket('{ch.Pid}','{authTs}','{ch.CnlId}','{TvApiClient.Guid}','{TvApiClient.YspAppId}','V1.0.0')";
            // ★ __genYspTicket 现为同步函数, 直接返回 hex 字符串 (不再是 Promise);
            //   但 wasm 系页面加载时异步预实例化, 极端情况下首帧可能尚未就绪 → 短重试几次。
            for (int attempt = 0; attempt < 5; attempt++)
            {
                var res = await OfficialWebView.CoreWebView2.ExecuteScriptAsync(js);
                if (!string.IsNullOrEmpty(res) && res.Length > 1)
                {
                    string? str = null;
                    try { str = System.Text.Json.JsonDocument.Parse(res).RootElement.GetString(); }
                    catch (Exception pe) { Log($"yspticket 结果解析失败({attempt}): {pe.Message} raw={res}"); }
                    if (!string.IsNullOrEmpty(str) && str.Length >= 60)
                    {
                        //Log($"yspticket 动态生成成功 ({str.Length / 2} 字节)");
                        return str;
                    }
                    if (attempt == 0) Log($"yspticket 首次返回过短/空, 等待 wasm 就绪重试: {str}");
                }
                await Task.Delay(200);   // 等 wasm 异步实例化完成
            }
            Log("yspticket 多次重试仍失败, 回退硬编码值");
        }
        catch (Exception ex) { Log($"yspticket 生成异常, 回退: {ex.Message}"); }
        return TvApiClient.YspTicket;
    }

    async Task FetchViaPostMessage(TvChannel ch)
    {
        var g = TvApiClient.Guid;
        var seqId = NextPersistedSeqId();
        var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
        var reqId = "999999" + TvApiClient.RandStr(10) + ts;   // ★ 官方 changeCookie: 999999 + 10位随机 + 13位时间戳

        // ★ 关键修复 (401 根因): auth 签名必须用官方 su() 的盐化 MD5, 不依赖 wasm
        var randStr = TvApiClient.RandStr(10);
        var authSig = TvApiClient.ComputeAuthSignature(ch.Pid, g, randStr);
       // Log($"auth签名(盐化MD5): sig={authSig[..Math.Min(10, authSig.Length)]}... randStr={randStr}");

        var proxyBase = "http://127.0.0.1:18888";
        using var hc = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var ab = $"pid={ch.Pid}&guid={g}&appid=ysp_pc&rand_str={randStr}&signature={authSig}";
        var authReq = new HttpRequestMessage(HttpMethod.Post, $"{proxyBase}/auth");
        authReq.Content = new ByteArrayContent(System.Text.Encoding.UTF8.GetBytes(ab));
        authReq.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/x-www-form-urlencoded") { CharSet = "UTF-8" };
        authReq.Headers.TryAddWithoutValidation("yspappid", TvApiClient.YspAppId);
        authReq.Headers.TryAddWithoutValidation("seqid", seqId);
        authReq.Headers.TryAddWithoutValidation("request-id", reqId);
        authReq.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
        authReq.Headers.TryAddWithoutValidation("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7");
        // ★ 官方 HAR 将 nseqId/nrequest-id 放在 Cookie 中
        authReq.Headers.TryAddWithoutValidation("Cookie", TvApiClient.Cookie + $" nseqId={seqId}; nrequest-id={reqId}");
        var authResp = await hc.SendAsync(authReq);
        var authText = await authResp.Content.ReadAsStringAsync();
        if ((int)authResp.StatusCode != 200) { Log($"auth HTTP {authResp.StatusCode}: {authText[..Math.Min(100, authText.Length)]}"); return; }
        var token = System.Text.Json.Nodes.JsonNode.Parse(authText)?["data"]?["token"]?.ToString();
        if (token == null) { Log("无token", true); return; }
        // ★ auth 响应里的 data.ts (秒) 是官方 _c 的第2参数, 同时作为 wasm _time/PCG 尾缀种子
        var authTs = System.Text.Json.Nodes.JsonNode.Parse(authText)?["data"]?["ts"]?.ToString()
                     ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
       // Log($"auth成功: token={token[..Math.Min(10, token.Length)]}... ts={authTs}");

        // ★ 关键修复 (20401 根因): sig2(openapi_signature) 必须用 /web/open/token 返回的 sessionToken,
        //   上面的 token 是 authToken, 仅作网关层 yspplayertoken 校验! 二者是不同体系的 token, 混用 → sig2 错 → 20401。
        //   流程: 用 WebView2 内已实例化的 wasm 调 get_token_rnd 拿 rnd → GET /open-token 拿 sessionToken。
        string? sessionToken = null;
        try
        {
            var tsMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            var tkrJs = $"window.__genTokenRnd('{g}','{token}','{tsMs}')";
            _tokenRndTcs = new TaskCompletionSource<string>();
            await OfficialWebView.CoreWebView2.ExecuteScriptAsync(tkrJs);
            var rndTask = _tokenRndTcs.Task;
            string? rndVal = null;
            if (await Task.WhenAny(rndTask, Task.Delay(8000)) == rndTask)
            {
                try
                {
                    var rndJson = await rndTask;
                    var rndObj = System.Text.Json.Nodes.JsonNode.Parse(rndJson);
                    rndVal = rndObj?["tokenRnd"]?.ToString();
                }
                catch { }
            }
            if (!string.IsNullOrEmpty(rndVal))
            {
                var openUrl = $"{proxyBase}/open-token?yspappid={TvApiClient.YspAppId}&guid={g}&vappid={TvApiClient.VappId}&vsecret={TvApiClient.Vsecret}&raw=1&version=v1&ts={tsMs}&rnd={rndVal}";
                var otResp = await hc.GetAsync(openUrl);
                var otText = await otResp.Content.ReadAsStringAsync();
               // Log($"open/token HTTP{otResp.StatusCode}: {otText[..Math.Min(80, otText.Length)]}");
                try { var oj = System.Text.Json.Nodes.JsonNode.Parse(otText); sessionToken = oj?["data"]?["token"]?.ToString(); } catch { }
            }
            else { Log("get_token_rnd 超时/失败, 无法获取 sessionToken"); }
        }
        catch (Exception ex) { Log($"open/token 异常: {ex.Message}"); }
        if (string.IsNullOrEmpty(sessionToken)) { Log("sessionToken 获取失败, 终止本次播放", true); return; }
       // Log($"sessionToken 获取成功: {sessionToken[..Math.Min(12, sessionToken.Length)]}...");

        // ★★★ 重试: live 偶发 20401(获取直播信息失败 / 防盗链cKey校验失败 error 85),
        //   可能是服务器瞬时后端失败或 cKey 时效窗口边缘。重新生成 cKey+签名再试通常即可成功。★★★
        string? m3u8 = null;
        for (int attempt = 0; attempt < 1 && m3u8 == null; attempt++)
        {
            if (attempt > 0) Log($"live 重试 #{attempt} (重新生成 cKey+签名)...");
            seqId = NextPersistedSeqId();   // ★ 每次递增, 对齐官方 changeCookie 的 nseqId (持久化, 跨运行不回退)

            // ★ 动态生成 cKey (当前时间种子, 对齐官方 ru(): cKey=sc(cnlid, Math.round(Date.now()/1000), version, guid, platform))
            var cKey = await GenerateCKeyAsync(ch) ?? TvApiClient.LiveCKey;
            TvApiClient.LiveCKey = cKey ?? "";   // 同步给 PlayerService 等其他消费者

            var yspticket = await GenerateYspTicketAsync(ch, authTs);

            // ★★★ live 业务签名 (复刻官方 getSdkData / au / xs, 已用 接口抓包记录 抓包真值验证) ★★★
            //   1) yspsdkinput = xs()/ne() = md5(按 localeCompare 排序的 body, 不含 rand_str/signature)
            //   2) body signature = au() = md5(按 Ordinal 排序的 body 含 rand_str + LiveSaltTc 盐)
            //   3) Yspsdksign = openapi_signature = sig(由 wasm get_signature 算) - yspsdkinput - guid - seqid - reqid
            var randStrLive = TvApiClient.RandStr(10);
            var liveFields = new System.Collections.Generic.Dictionary<string, string>
            {
                ["cnlid"] = ch.CnlId, ["livepid"] = ch.Pid, ["stream"] = "2", ["guid"] = g, ["cKey"] = cKey ?? "",
                ["adjust"] = "1", ["sphttps"] = "1", ["platform"] = "5910204", ["cmd"] = "2", ["encryptVer"] = "8.1",
                ["dtype"] = "1", ["devid"] = "devid", ["otype"] = "ojson", ["appVer"] = "V1.0.0", ["app_version"] = "V1.0.0",
                ["channel"] = "ysp_tx", ["defn"] = "fhd", ["rand_str"] = randStrLive
            };
            var yspsdkinput = TvApiClient.ComputeLiveSdkInput(liveFields);   // ★ 纯 MD5, 与抓包 364e7007... 一致
            var bodySig = TvApiClient.ComputeLiveBodySignature(liveFields);  // ★ au 盐化 MD5, 与抓包 6891575e... 一致
            // ★ 临时: 打印签名原文 (已注释)
            /*
            {
                var dXs = new System.Collections.Generic.SortedDictionary<string, string>(System.StringComparer.Create(System.Globalization.CultureInfo.GetCultureInfo("en-US"), System.Globalization.CompareOptions.None));
                foreach (var kv in liveFields) if (kv.Key != "rand_str" && kv.Key != "signature") dXs[kv.Key] = kv.Value;
                var sbXs = new System.Text.StringBuilder(); bool fi = true;
                foreach (var kv in dXs) { if (!fi) sbXs.Append('&'); fi = false; sbXs.Append(kv.Key).Append('=').Append(kv.Value); }
                Log($"  xs原文: {sbXs.ToString()[..Math.Min(80, sbXs.Length)]}...");

                var dAu = new System.Collections.Generic.SortedDictionary<string, string>(System.StringComparer.Ordinal);
                foreach (var kv in liveFields) if (kv.Key != "signature") dAu[kv.Key] = kv.Value;
                var sbAu = new System.Text.StringBuilder(); fi = true;
                foreach (var kv in dAu) { if (!fi) sbAu.Append('&'); fi = false; sbAu.Append(kv.Key).Append('=').Append(kv.Value); }
                Log($"  au原文: {sbAu.ToString()[..Math.Min(80, sbAu.Length)]}...");
            }
            */

            // ★ 用 wasm get_signature 算 openapi_signature 的 sig 段; input = yspsdkinput-guid-seqid-reqid
            string sigJson = "";
            System.Text.Json.Nodes.JsonNode? sigResult = null;
            var ts2 = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            var reqId2 = "999999" + TvApiClient.RandStr(10) + ts2;   // ★ 官方 request-id: 999999 + 10位随机 + 13位时间戳
            _signatureTcs = new TaskCompletionSource<string>();
            var liveJs = $"window.__generateSignature('{ch.Pid}','{g}','{seqId}','{reqId2}','{sessionToken}', '{ts2}', '{yspsdkinput}')";   // ★ 传入 sessionToken 算 sig2
            await OfficialWebView.CoreWebView2.ExecuteScriptAsync(liveJs);
            var sigTask = _signatureTcs.Task;
            if (await Task.WhenAny(sigTask, Task.Delay(20000)) != sigTask) { Log("签名2超时"); continue; }
            try { sigJson = await sigTask; } catch { sigJson = ""; }
            sigResult = System.Text.Json.Nodes.JsonNode.Parse(string.IsNullOrEmpty(sigJson) ? "{}" : sigJson);
            string? sig2 = null;
            try { if (sigResult is System.Text.Json.Nodes.JsonObject o) sig2 = o["signature"]?.ToString(); } catch { }
            if (sig2 == null) { Log("openapi_signature 不完整"); continue; }
          //  Log($"live签名(#{attempt}): yspsdkinput={yspsdkinput[..12]}.. bodySig={bodySig[..12]}.. sig2={sig2[..12]}..");
          //  Log($"  cKey前40={cKey?[..Math.Min(40,cKey!.Length)]}");
          //  Log($"  yspticket前30={yspticket?[..Math.Min(30,yspticket!.Length)]}");
          //  Log($"  guid={g} rand_str={randStrLive} seqId={seqId} reqId2={reqId2[..20]}..");

            var lb = new System.Text.Json.Nodes.JsonObject
            {
                ["cnlid"] = ch.CnlId, ["livepid"] = ch.Pid, ["stream"] = "2", ["guid"] = g, ["cKey"] = cKey,
                ["adjust"] = 1, ["sphttps"] = "1", ["platform"] = "5910204", ["cmd"] = "2", ["encryptVer"] = "8.1",
                ["dtype"] = "1", ["devid"] = "devid", ["otype"] = "ojson", ["appVer"] = "V1.0.0", ["app_version"] = "V1.0.0",
                ["channel"] = "ysp_tx", ["defn"] = "fhd", ["rand_str"] = randStrLive, ["signature"] = bodySig
            };
            var lr = new HttpRequestMessage(HttpMethod.Post, $"{proxyBase}/get-live-info");
            lr.Content = new ByteArrayContent(System.Text.Encoding.UTF8.GetBytes(lb.ToJsonString()));
            lr.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json") { CharSet = "UTF-8" };
            lr.Headers.TryAddWithoutValidation("yspappid", TvApiClient.YspAppId);
            lr.Headers.TryAddWithoutValidation("yspplayertoken", token);
            lr.Headers.TryAddWithoutValidation("yspsdkinput", yspsdkinput);
            lr.Headers.TryAddWithoutValidation("yspsdksign", $"{sig2}-{yspsdkinput}-{g}-{seqId}-{reqId2}");
            lr.Headers.TryAddWithoutValidation("yspticket", yspticket);
            lr.Headers.TryAddWithoutValidation("request-id", reqId2);
            lr.Headers.TryAddWithoutValidation("seqid", seqId);
            lr.Headers.TryAddWithoutValidation("User-Agent", TvApiClient.Ua);
            lr.Headers.TryAddWithoutValidation("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7");
            lr.Headers.TryAddWithoutValidation("Cookie", TvApiClient.Cookie + $" nseqId={seqId}; nrequest-id={reqId2}");
            var lrResp = await hc.SendAsync(lr);
            var lrText = await lrResp.Content.ReadAsStringAsync();
            if ((int)lrResp.StatusCode != 200) { Log($"live HTTP {lrResp.StatusCode} (尝试{attempt}): {lrText[..Math.Min(120, lrText.Length)]}"); continue; }
            var parsed = System.Text.Json.Nodes.JsonNode.Parse(lrText);
            var m = parsed?["data"]?["playurl"]?.ToString() + (parsed?["data"]?["extended_param"]?.ToString() ?? "");
            if (string.IsNullOrEmpty(m)) { Log($"无m3u8 (尝试{attempt}): {lrText[..Math.Min(160, lrText.Length)]}"); continue; }
            m3u8 = m;
        }
        if (m3u8 == null) { Log("live 尝试失败 (未获取到m3u8)", true); return; }
        //Log("m3u8获取成功");
        var esc = m3u8.Replace("\\", "\\\\").Replace("'", "\\'");
        await OfficialWebView.CoreWebView2.ExecuteScriptAsync($"window.__startM3u8('{esc}')");
        _isPlaying = true;
        BtnPlay.Content = "⏸ 暂停";
        StatusText.Text = "播放中";
        UpdateChannelListVisual();
        StartEpgRefresh(ch.Pid);
        // ★ 启动 kvcollect 心跳, 每 60s 调一次保持会话(源站官方每 1 分钟调用)
        _kvPid = ch.Pid;
        _kvM3u8 = m3u8;
        StartKvCollectHeartbeat();
    }

    void StartKvCollectHeartbeat()
    {
        _kvTimer?.Dispose();
        _kvTimer = new System.Threading.Timer(async _ =>
        {
            try
            {
                var (code, body) = await TvApiClient.SendKvCollectAsync(_kvPid, _kvM3u8);
                var msg = code == 200 ? "● 播放中" : $"KVC:{code}";
                _ = Dispatcher.BeginInvoke(new Action(() => StatusText.Text = msg));
            }
            catch { _ = Dispatcher.BeginInvoke(new Action(() => StatusText.Text = "KVC:ERR")); }
        }, null, 500, 50000);
    }

    void StartEpgRefresh(string pid)
    {
        _epgTimer?.Dispose();
        _scrollTimer?.Stop();
        _epgCache = new List<EpgProgram>();
        _lastEpgFetch = DateTime.MinValue;
        // ★ 2026-09-04: 修复"长时间播放跨节目单不更新"——
        //   每 10s 用本地时钟按缓存推进"正在/即将"(跨节目单 ≤10s 内切换);
        //   拉取仅 ≥60s 一次(降低 capi 频率与失败影响); 拉取失败/为空则沿用缓存。
        _epgTimer = new System.Threading.Timer(async _ =>
        {
            try
            {
                if ((DateTime.Now - _lastEpgFetch).TotalSeconds >= 60)
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
        var cur = programs.FirstOrDefault(p => p.IsCurrent);
        NowProg.Text = cur != null ? $"▶  {cur.Display}" : "";
        NowProgBorder.Background = cur != null
            ? new SolidColorBrush(Color.FromRgb(0x12, 0x18, 0x28)) : Brushes.Transparent;
        var curIdx = cur != null ? programs.IndexOf(cur) : -1;
        var next = curIdx >= 0 && curIdx + 1 < programs.Count ? programs[curIdx + 1] : null;
        NextProg.Text = next != null ? $"⌛  {next.Display}" : "";
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
        _nowOff = 0; _nextOff = 0;
        NowProg.Text = "";
        NowProgBorder.Background = Brushes.Transparent;
        NextProg.Text = "";
        NextProgBorder.Background = Brushes.Transparent;
        _playingChannelName = "";
        UpdateChannelListVisual();
    }

    void ChannelList_SelectionChanged(object sender, SelectionChangedEventArgs e) { UpdateChannelListVisual(); }
    void ChannelList_MouseDoubleClick(object sender, MouseButtonEventArgs e) { if (ChannelList.SelectedItem is string s) PlayChannel(s); }

    void UpdateChannelListVisual()
    {
        for (int i = 0; i < ChannelList.Items.Count; i++)
        {
            if (ChannelList.ItemContainerGenerator.ContainerFromIndex(i) is ListBoxItem item)
            {
                var name = ChannelList.Items[i]?.ToString() ?? "";
                if (name == _playingChannelName)
                {
                    item.Foreground = new SolidColorBrush(Color.FromRgb(0xE9, 0x45, 0x60)); // playing=red
                    item.FontWeight = FontWeights.Bold;
                }
                else if (item.IsSelected)
                {
                    item.Foreground = new SolidColorBrush(Color.FromRgb(0x4F, 0xC3, 0xF7)); // selected=cyan
                    item.FontWeight = FontWeights.Normal;
                }
                else
                {
                    item.Foreground = new SolidColorBrush(Color.FromRgb(0xCC, 0xCC, 0xCC));
                    item.FontWeight = FontWeights.Normal;
                }
            }
        }
    }

    void Window_KeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter: if (ChannelList.SelectedItem is string s) PlayChannel(s); break;
            case Key.Up: ChannelList.SelectedIndex = Math.Max(0, ChannelList.SelectedIndex - 1); break;
            case Key.Down: ChannelList.SelectedIndex = Math.Min(ChannelList.Items.Count - 1, ChannelList.SelectedIndex + 1); break;
            case Key.Left: PlayAdjacent(-1); break;
            case Key.Right: PlayAdjacent(1); break;
            case Key.F: case Key.F11: ToggleFullscreen(); break;
            case Key.Escape: if (_fullscreen) ToggleFullscreen(); break;
        }
    }

    void PlayAdjacent(int delta)
    {
        if (ChannelList.Items.Count == 0) return;
        var idx = ChannelList.SelectedIndex < 0 ? 0 : ChannelList.SelectedIndex;
        idx = Math.Clamp(idx + delta, 0, ChannelList.Items.Count - 1);
        ChannelList.SelectedIndex = idx;
        if (ChannelList.SelectedItem is string s) PlayChannel(s);
    }

    void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        var t = SearchBox.Text;
        if (t == "🔍 输入频道名搜索...") t = "";
        RefreshChannelList(t);
    }

    void SearchBox_GotFocus(object sender, RoutedEventArgs e)
    {
        if (SearchBox.Text == "🔍 输入频道名搜索...")
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
            SearchBox.Text = "🔍 输入频道名搜索...";
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
        // WebView2 是独立 Chromium 进程, 必须用 JS 注入覆盖 CSS cursor
        try
        {
            if (OfficialWebView?.CoreWebView2 != null)
            {
                var css = cur == Cursors.None ? "none" : "auto";
                OfficialWebView.CoreWebView2.ExecuteScriptAsync(
                    $"document.body.style.cursor='{css}';");
            }
        }
        catch { }
    }

    void ShowVideoContextMenu()
    {
        var menu = new ContextMenu
        {
            Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint,
            Style = (Style)FindResource("DarkMenu"),
        };
        if (_fullscreen)
            menu.Items.Add(MakeMenuItem("退出全屏  Esc", () => ToggleFullscreen()));
        else
            menu.Items.Add(MakeMenuItem("进入全屏", () => ToggleFullscreen()));
        menu.Items.Add(new Separator { Style = (Style)FindResource("DarkSeparator") });
        // 切换源站 (CCTV 开头)
        var tvMenu = MakeSubMenu("切换频道");
        foreach (var ch in TvApiClient.Channels.Where(c => c.Name.StartsWith("CCTV", StringComparison.OrdinalIgnoreCase)))
            tvMenu.Items.Add(MakeMenuItem(ch.Name, () => PlayChannel(ch.Name)));
        menu.Items.Add(tvMenu);
		// 切换卫视 (非 CCTV 开头)
		var wsMenu = MakeSubMenu("切换卫视");
		foreach (var ch in TvApiClient.Channels.Where(c => !c.Name.StartsWith("CCTV", StringComparison.OrdinalIgnoreCase)))
			wsMenu.Items.Add(MakeMenuItem(ch.Name, () => PlayChannel(ch.Name)));
		menu.Items.Add(wsMenu);
		// 节目单: 需要初始占位项, 否则 SubmenuOpened 不会触发
		var epgMenu = MakeSubMenu("节目单");
		epgMenu.Items.Add(MakeMenuItem("加载中...", () => { }));
		epgMenu.SubmenuOpened += async (s, e) =>
		{
			epgMenu.Items.Clear();
			if (_current == null || string.IsNullOrEmpty(_current.Pid))
			{
				epgMenu.Items.Add(MakeMenuItem("(未在播放)", () => { }));
				return;
			}
			try
			{
				var programs = await FetchEpgAsync(_current.Pid);
				epgMenu.Items.Clear();
				if (programs.Count == 0)
				{
					epgMenu.Items.Add(MakeMenuItem("(无节目数据)", () => { }));
					return;
				}
				foreach (var p in programs)
				{
					var item = new MenuItem
					{
						Header = p.Display,
						Style = (Style)FindResource("DarkMenuItem"),
					};
					// 当前节目: 红色加粗
					if (p.IsCurrent)
					{
						item.FontWeight = FontWeights.Bold;
						item.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x44, 0x44));
					}
					epgMenu.Items.Add(item);
				}
			}
			catch
			{
				epgMenu.Items.Clear();
				epgMenu.Items.Add(MakeMenuItem("加载失败", () => { }));
			}
		};
		menu.Items.Add(epgMenu);
		menu.Items.Add(new Separator { Style = (Style)FindResource("DarkSeparator") });
		menu.Items.Add(MakeMenuItem("停止播放", () => Dispatcher.BeginInvoke(() => BtnStop_Click(null!, null!))));
		menu.IsOpen = true;
	}

	record EpgProgram
	{
		public string StartTime { get; init; } = "";
		public string EndTime { get; init; } = "";
		public string Title { get; init; } = "";
		public string Display => string.IsNullOrEmpty(StartTime) ? Title : $"{StartTime}-{EndTime}  {Title}";
		public int StartMinutes => ParseMin(StartTime);
		public int EndMinutes => ParseMin(EndTime);
		public bool IsCurrent
		{
			get
			{
				var now = DateTime.Now;
				int n = now.Hour * 60 + now.Minute;
				int s = StartMinutes, e = EndMinutes;
				if (e <= s) e += 24 * 60;           // 跨凌晨节目
				if (n < s && e >= 24 * 60) n += 24 * 60; // 凌晨时段归一化
				return n >= s && n < e;
			}
		}
		static int ParseMin(string t)
		{
			if (t.Length >= 5 && t[2] == ':')
				return int.Parse(t.Substring(0, 2)) * 60 + int.Parse(t.Substring(3, 2));
			return 0;
		}
	}

	async Task<List<EpgProgram>> FetchEpgAsync(string pid)
	{
		var list = new List<EpgProgram>();
		try
		{
			var date = DateTime.Now.ToString("yyyyMMdd");
			var url = $"http://127.0.0.1:18888/capi/api/yspepg/program/{pid}/{date}";
			using var hc = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
			hc.DefaultRequestHeaders.TryAddWithoutValidation("Referer", "https://yangshipin.cn/");
			var resp = await hc.GetAsync(url);
			if (!resp.IsSuccessStatusCode) return list;
			var text = await resp.Content.ReadAsStringAsync();
			// Go 代理已将 protobuf 解码为 JSON 数组 [{id,title,start,end},...]
			var arr = System.Text.Json.Nodes.JsonNode.Parse(text)?.AsArray();
			if (arr == null) return list;
			foreach (var p in arr)
			{
				list.Add(new EpgProgram
				{
					StartTime = p?["start"]?.ToString() ?? "",
					EndTime = p?["end"]?.ToString() ?? "",
					Title = p?["title"]?.ToString() ?? ""
				});
			}
		}
		catch { }
		return list;
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
            _uiVisible = false;
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
            SidebarCol.Width = new GridLength(192);
            Sidebar.Visibility = Visibility.Visible;
            BottomBar.Visibility = Visibility.Visible;
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

    void ApplyFullscreenUI()
    {
        if (_uiVisible)
        {
            SidebarCol.Width = new GridLength(192);
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
            if (ChannelList.SelectedItem is string ch) PlayChannel(ch);
        }
        else
        {
            _isPlaying = false;
            BtnPlay.Content = "▶ 播放";
            NowPlaying.Text = _playingChannelName;
            StatusText.Text = "已暂停";
            try { await OfficialWebView.CoreWebView2.ExecuteScriptAsync("v.pause();"); } catch { }
        }
    }

    async void BtnStop_Click(object s, RoutedEventArgs e)
    {
        _isPlaying = false;
        BtnPlay.Content = "▶ 播放";
        BtnStop_EpgDisabled();
        try
        {
            await OfficialWebView.CoreWebView2.ExecuteScriptAsync(
                "try{hls.stopLoad();hls.destroy();hls=null;}catch(e){}try{v.pause();v.removeAttribute('src');v.load();}catch(e){}");
        }
        catch { }
        NowPlaying.Text = "已停止";
        StatusText.Text = "就绪";
        OfficialWebView.CoreWebView2.NavigateToString(
            "<html><body style='margin:0;background:#1A1A2E;display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif'>" +
            "<div style='text-align:center;color:#555'><div style='font-size:48px;margin-bottom:16px'>⏹</div>" +
            "<div style='font-size:18px'>播放已停止</div>" +
            "<div style='font-size:13px;margin-top:8px;color:#444'>双击左侧频道重新播放</div></div></body></html>");
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


    async void VolSlider_ValueChanged(object s, RoutedPropertyChangedEventArgs<double> e)
    {
        try { await OfficialWebView.CoreWebView2.ExecuteScriptAsync($"v.volume={VolSlider.Value / 100:0.00};"); } catch { }
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
        Dispatcher.BeginInvoke(new Action(() =>
        {
            StatusText.Text = msg;
        }));
    }

    protected override void OnClosed(EventArgs e)
    {
        _loadCts?.Cancel();
        try { _proxyProcess?.Kill(); _proxyProcess?.Dispose(); } catch { }
        base.OnClosed(e);
    }
}