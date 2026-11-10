using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Collections.Concurrent;

namespace PalmTVDesktop;

/// <summary>
/// 本地解密代理（对标鸿蒙 <c>LocalDecryptServer.ets</c>，端口同为 <b>18899</b>）。
///
/// 目的：让播放器**只看到明文 HLS** —— 页内 hls.js / CMG wasm / slim 补丁全部不再需要。
///
/// 链路（与鸿蒙逐条对齐）：
/// <code>
///   播放器 → http://127.0.0.1:18899/local.m3u8?u=&lt;远端m3u8&gt;&amp;ck=&lt;cnlId&gt;
///            /local.m3u8 : 拉远端 playlist，把每个分片 URL 改写成 /local-seg?u=&lt;分片&gt;&amp;k=&lt;缓存键&gt;
///            /local-seg  : 下载原始分片 → PalmTVCore.DecryptSegment(**原地**解密) → 返回明文 TS
///            /health     : 探活
/// </code>
///
/// ★ 为什么用 <see cref="TcpListener"/> 裸 HTTP 而不是 <c>HttpListener</c>：
///   Windows 上 <c>HttpListener</c> 绑定含主机名的前缀需要 URL 保留（非管理员会 Access denied），
///   而 VLC 只会发 GET/HEAD 且不需要长连接 ⇒ 裸实现最省事、零权限依赖（鸿蒙侧也是裸 socket）。
///
/// ★ 解密三要素（缺一必花屏，见 PalmTVCore 类注释）：
///   ① 完整 43 字符 activeURL = <c>https://yangshipin.cn/tv/home?pid=&lt;Pid&gt;</c>（**随频道变**）；
///   ② 每分片开头 reseed（<see cref="PalmTVCore.DecryptSegment"/> 已内建）；
///   ③ 真实墙钟（<see cref="PalmTVCore.Init"/> 已内建）。
/// </summary>
internal sealed class LocalDecryptServer : IDisposable
{
    internal const int Port = 18899;
    internal const string M3U8_MIME = "application/vnd.apple.mpegurl";
    internal const string TS_MIME = "video/mp2t";

    /// <summary>日志回调（由宿主注入；本类不依赖 UI）</summary>
    internal static Action<string>? Log;

    static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = true,
        AutomaticDecompression = System.Net.DecompressionMethods.All,
        /* ★ 2026-11-06：4K 的 CDN 会轮询到不同节点（live-dtocnc / hlsliveali），
         *   个别节点握手要 10 秒以上 ⇒ 原 `ConnectTimeout=10s` 直接判死（`playlist 失败: 操作已取消` → 502）。 */
        ConnectTimeout = TimeSpan.FromSeconds(25),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    { Timeout = TimeSpan.FromSeconds(30) };

    // ★ 上游要的是"像浏览器/播放器"的头：CMG 分片走 CDN 时会校验 Referer/UA
    const string UpUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";

    /// <summary>江苏荔枝用的 UA（与 `windows/proxy/main.go` 里 `jstvUA` 逐字一致）。</summary>
    const string JstvUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

    /// <summary>
    /// ★★ 2026-11-05：**按上游域名选请求头**（桌面去掉 `proxy.exe` 后，江苏台也走这个代理）★★
    ///   · 央视频 CDN：`Referer: https://yangshipin.cn/`
    ///   · 江苏荔枝 CDN：`Referer/Origin: https://live.jstv.com/`（缺了直接 403，实测）
    ///   ⚠️ 千万别"统一用一个 Referer"——两边都校验，写成对方的一定挂。
    /// </summary>
    static void ApplyUpstreamHeaders(HttpRequestMessage req, string url)
    {
        bool jstv = url.Contains("jstv.com", StringComparison.OrdinalIgnoreCase);
        req.Headers.TryAddWithoutValidation("User-Agent", jstv ? JstvUa : UpUa);
        req.Headers.TryAddWithoutValidation("Referer",
            jstv ? "https://live.jstv.com/" : "https://yangshipin.cn/");
        if (jstv) req.Headers.TryAddWithoutValidation("Origin", "https://live.jstv.com");
    }

    TcpListener? _listener;
    CancellationTokenSource? _cts;
    Task? _accept;
    int _port;                       // 实际监听端口（便于将来做端口回退/测试）
    string _coreKey = "";            // 当前 C 解密核用的 (pid)；换台时不同则重建

    // 分片缓存：键 = k（pid+mediaSequence+序号），值 = 明文 TS。换台/回退时避免重复下载解密。
    readonly ConcurrentDictionary<string, byte[]> _segCache = new();
    readonly ConcurrentQueue<string> _segOrder = new();
    const int SegCacheMax = 24;

    internal int Port2 => _port;
    internal string CoreKey => _coreKey;

    /// <summary>
    /// 该流是否**明文**（不需要 CMG 解密）。判据与鸿蒙 <c>isNoDecryptUrl</c> 一致：
    /// ① CDN host 含 <c>mobilelive</c>；② URL 含 <c>m3u8_with_time_tag</c>。
    /// ★ CCTV-6（pid=600108442）走的就是 mobilelive 源、TS 本身未加密 ⇒ 必须直通，否则花屏。
    /// </summary>
    internal static bool IsNoDecryptUrl(string url)
    {
        var u = url.ToLowerInvariant();
        // ★★ 临时兜底（2026-09-22）：四川卫视（pid=600002516）**也是明文流** ——
        //   用户实测铁证：`sc_raw.ts`（未解密原始分片）在 VLC 里**正常**，`sc_dec.ts`（过了解密核）**花屏**。
        //   但它的 URL/playlist 与"确实加密"的 CCTV-5/湖南卫视**逐项相同**（`<cnlId>_web.m3u8` + 标准干净 HLS）
        //   ⇒ 任何启发式都判不出它 ⇒ 先按 pid 精确兜底（只影响这一个台，风险为零）。
        //   ⚠️ 这不是正解。正解 = 用 `get_live_info` 响应里的权威加密标记（见实现记录 §20）：
        //      用户的观察"官方主页那个 m3u8 在**浏览器**里就能播"说明官方对四川**没有解密**
        //      ⇒ 该决定来自接口，靠 URL 猜必然继续漏台（西藏/青海等未逐台枚举）。
        if (u.Contains("pid=600002516")) return true;
        return u.Contains("mobilelive") || u.Contains("m3u8_with_time_tag");
    }

    /// <summary>
    /// ★★ 2026-09-22 新增：**playlist 内容**层面的明文判据 —— 腾讯 QQ-HLS 那一套下发。
    ///
    /// 实证（本轮逐台实测，用户目视验证）：
    ///   · 天津卫视 / 新疆卫视：playlist 有 10 行 <c>#EXT-QQHLS-*</c>（SEGMENT-TYPE/SEGMENT_RANGE/
    ///     MACHINEID/START-TIME + <c>#EXT-SID</c>），URL 是 <c>&lt;cnlId&gt;.m3u8</c>（**无** <c>_web</c>），
    ///     分片名 <c>&lt;urlid&gt;-&lt;sid&gt;.ts</c> —— ★ 用户把**未解密的上游原始分片**（tj_raw.ts）交给
    ///     单机 VLC 播放，**画面完全正常** ⇒ 该路流**本就是明文**，我们此前"无条件解密每个 type-1/5 NALU"
    ///     把好的帧改坏了 ⇒ 花屏（这条链与 CCTV-6/mobilelive 是同一个 bug：判定漏检）。
    ///   · 所有正常台（CCTV-1/5、湖南/山东/东方卫视）实测 <c>#EXT-QQHLS</c> **0 行**，
    ///     URL 一律 <c>&lt;cnlId&gt;_web.m3u8</c> ⇒ 新判据不会误伤它们（这是动手前专门验过的）。
    ///   ⚠️ 四川卫视是**另一回事**：它 <c>_web</c> + 无 QQ-HLS 标记，与正常台特征相同却同样花屏 ⇒
    ///     本判据**治不了它**，需单独排查（别把它算作"已修"）。
    ///   ⚠️ 用内容判据而不是"URL 里没有 `_web` 就当真"：后者会波及命名不同的未知频道，风险无法枚举。
    /// </summary>
    internal static bool IsNoDecryptPlaylist(string playlistText)
        => playlistText.Contains("#EXT-QQHLS", StringComparison.OrdinalIgnoreCase);

    // ==================== ★ 自证式解密（tag 不再靠猜）====================
    //   背景：tag（= 官方的 `mediaTagId`，由 hls.js 在 init 时写入 `config[0x291]`，**只赋值一次**）
    //   决定 CMG 密钥流；而"密钥流依赖时间"（cmg_env.c）。实测**固定常量**与 **Date.now()** 都各自
    //   出现过"完全干净（unchanged=0）"和"整段提前返回（unchanged==frames、lastMa 恒 2094）"两种结果
    //   —— 说明它与**该会话的 CDN 侧取值**有关，靠猜必然时好时坏。
    //   ⇒ 改用**自证**：内核自带 `unchanged`（输出==输入的帧数）这个判据，逐个候选 tag 试解一片，
    //     哪把能让**本片一帧都不"原样返回"**就用哪把，并记住它（本会话内不再试）。
    // ★ `_goodTag`（"每会话自证 tag"实验的遗留字段）已删除 —— 现在 tag 固定在 `EnsureCore`，
    //   不再有"逐候选自证"的概念（那套已被证明会破坏会话，见 DecryptSelfChecked 的结论注释）。
    string _lastPlaylistUrl = "";
        /// <summary>★ 2026-11-04：上次清单请求时刻（用于打“轮询间隔”，验证归一化是否真的让 VLC 轮询变快）</summary>
        static long _lastPlaylistAtMs;

    byte[] DecryptSelfChecked(byte[] data)
    {
        // ★★ 自证实验结论（2026-09-20，勿再走回头路）★★
        //   在同一进程里"逐个候选 tag 试解"**必然失败** —— 因为 wasm 运行时是进程级全局，
        //   **二次 init 会让后续解密整段失效**（实测：候选 #1 用 now 只有 50% 解密、后续全死）。
        //   正确形态 = **进程内只 init 一次**（tag=Date.now()）+ 之后一路只调 decrypt（内核自带 reseed/重启自愈）。
        //   实测该形态：`unchanged=0`、`lastMa` 健康。
        // ★ 2026-11-05：sm4c 解密（按台密钥）。解不了 = 本来就不是密文 ⇒ **原样直通**，绝不能改写数据。
        if (!Sm4C.TryDecrypt((byte[])data.Clone(), ActivePid, out var plain, out var info))
        {
            Log?.Invoke($"[dec] seg {data.Length}B 直通（{Sm4C.LastReason}）");
            return data;
        }
        Log?.Invoke($"[dec] seg {data.Length}B sm4c 已解密 {info}");
        return plain;
    }

    /// <summary>
    /// 候选 tag 列表：官方语义（`Date.now()`）+ **播放单 URL 里所有像时间戳的参数**（秒/毫秒两份）+ 鸿蒙常量。
    /// 依据：`mediaTagId` 是"每会话一个"的**精确时间戳**（实测 tag 差 1.4 秒就从"完全不解"变成"解一半"），
    /// 而它由 hls.js 从取流配置里取 ⇒ 最可能就在取流 URL 的参数里。让自证逐个试、选真正解开的那个。
    /// </summary>
    List<string> TagCandidates()
    {
        var list = new List<string>();
        void Add(string? v)
        {
            if (string.IsNullOrEmpty(v) || v.Length < 6 || v.Length > 14) return;
            if (!long.TryParse(v, out _)) return;
            if (!list.Contains(v)) list.Add(v);
        }
        Add(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString());
        try
        {
            var q = new Uri(_lastPlaylistUrl).Query.TrimStart('?');
            foreach (var kv in q.Split('&'))
            {
                var p = kv.Split('=', 2);
                if (p.Length != 2) continue;
                var v = p[1];
                if (v.Length < 9 || v.Length > 13 || !long.TryParse(v, out var n)) continue;
                if (n > 1_000_000_000 && n < 10_000_000_000) Add((n * 1000).ToString());  // 秒 → 毫秒
                Add(n.ToString());
            }
        }
        catch { }
        Add("1788255533974");                                   // 鸿蒙侧写死过的那把
        return list;
    }

    void EnsureCoreWithTag(string tag)
    {
        // ★ 重复初始化被**硬禁止**：wasm 运行时是进程级全局，二次 init 会让解密整段失效
        //   （实测：二次 init 后 unchanged 从 0 变成 50%~100%）⇒ 这里只在"尚未初始化"时才真正生效。
        if (_coreInited) return;
        _coreInited = true;
        _coreKey = tag;
        Log?.Invoke("[dec] sm4c 解密就绪（首片，无内核初始化）");
    }

    /// <summary>启动监听（幂等）。失败抛异常。</summary>
    internal void Start()
    {
        if (_listener != null) return;
        var cts = new CancellationTokenSource();
        var lis = new TcpListener(IPAddress.Loopback, Port);
        lis.Start();
        _port = ((IPEndPoint)lis.LocalEndpoint).Port;
        _cts = cts;
        _listener = lis;
        _accept = Task.Run(() => AcceptLoopAsync(lis, cts.Token));
        Log?.Invoke($"[dec] 已监听 127.0.0.1:{_port}");
    }

    /// <summary>
    /// 给播放器用的本地 playlist 地址（对齐鸿蒙 <c>LocalDecryptServer.localPlaylistUrl</c>）。
    /// </summary>
    internal static string LocalPlaylistUrl(string remoteM3u8, string chanKey = "")
        => $"http://127.0.0.1:{Port}/local.m3u8?u={Uri.EscapeDataString(remoteM3u8)}" +
           (string.IsNullOrEmpty(chanKey) ? "" : $"&ck={Uri.EscapeDataString(chanKey)}");

    // ★★★ tag 的语义 = **本次会话开始时的时间戳（ms）**，不是固定常量，也不是频道 pid ★★★
    //   依据（内部逆向笔记 附录B / §8.2，一手可复现）：
    //     `mediaTagId` = `Date.now()` 时间戳（由 hls.js 在 init 时写入 `config[0x291]`，**只赋值一次**）；
    //     且"CMG 的密钥流**依赖时间**，官方用真实墙钟才有 0 字节差异"（cmg_env.c 同结论）。
    //   旧页面方案每次换台都**重载页面** ⇒ 每次都是**新的 now** ⇒ 一直正常；
    //   后来换成固定常量 `1788255533974`（某次抓到的旧值）+ 幂等初始化 ⇒ 必然漂移：
    //     正常时 `unchanged=0 / lastMa 5万~200万`；漂移时**整段提前返回**（`unchanged == frames`、`lastMa` 恒 2094/1828）⇒ **花屏**。
    //   ⚠️ 勿改回"固定常量"或"按频道 pid"。
    const string CmgActiveUrl = "https://yangshipin.cn/tv/home?pid=600001859";

    /// <summary>
    /// **每次起播**都重新初始化 C 解密核，并用新的 `Date.now()` 当 tag（= 官方 mediaTagId 语义）。
    /// 等价于旧页面方案"每次换台重载页面 ⇒ 新会话 + 新 tag"的行为。
    /// </summary>
    /// <param name="pid">仅用于日志（tag 与频道无关）</param>
    /// <summary>
    /// 初始化 C 解密核 —— ★★ **进程内只允许一次** ★★
    ///
    /// 依据（2026-09-20 实测 + 内部笔记）：
    ///  - C 核的 wasm 运行时是**进程级全局**（`cmg_runtime.c` 的 `g_wasm_rt_inited`），
    ///    二次 `cmg_rt_init` 会让后续解密**整段失效**（内部笔记亦记：`UnInit` 破坏上下文字段、
    ///    "唯一有效的重置 = 完整重载页面"）；
    ///  - 对照全部实测日志：**只有一次 init 的日志全部 `unchanged=0`**（干净）；
    ///    出现二次（或更多）init 的日志全部是 `unchanged ≈ 50%~100%`（花屏）。
    ///  ⇒ 换台**不要**重建内核；tag 用本次启动的 `Date.now()`（官方 `mediaTagId` 语义），
    ///    与鸿蒙"整个 App 只 init 一次"的做法一致。
    /// </summary>
    internal void EnsureCore(string pid)
    {
        lock (this)
        {
            /* ★★★★★ 2026-11-05 修 bug（用户实测："连续换台后 8 个加密台全是马赛克"）★★★★★
             *   原来这一段是 `if (_coreInited) return;` 之后才 `ActivePid = pid`，
             *   而 `_coreInited` 一旦为 true 就**永远不会再更新 pid** ⇒ 换台后 ActivePid
             *   仍停在**第一个台**：
             *     · 第一个台是加密台 ⇒ 用它的密钥去解新台的密文 ⇒ 解出乱数据 ⇒ 马赛克；
             *     · 第一个台是明文台 ⇒ 新台 pid 查不到密钥 ⇒ 原样直通 ⇒ 密文直接进解码器 ⇒ 马赛克。
             *   单台启动（每次重启进程）永远正常，所以只测单台发现不了。
             *   ⇒ **pid 与缓存必须在"是否已初始化"的判断之前处理**。 */
            bool changed = !string.Equals(ActivePid, pid ?? "", StringComparison.Ordinal);
            ActivePid = pid ?? "";
            if (changed)
            {
                _segCache.Clear();
                _segOrder.Clear();
            }
            if (_coreInited) return;
            // ★★★ 回退到「用户已验收通过」的配置：固定 tag = 鸿蒙同款常量 ★★★
            //   我中间把它换成 `Date.now()`（唯一依据是内部笔记里"mediaTagId = Date.now()"这句话，
            //   **没有做基准对照**），结果从"CCTV-5/6/卫视正常"退化到"所有加密台花屏"。
            //   ⇒ 先退回已知可用的值；要不要动它，必须用**同一频道的 A/B 两次运行**来证明，不许再"顺手改"。
            const string tag = "1788255533974";
            // ★★★ 2026-09-22 A/B 实验（针对"天津/四川/新疆卫视花屏，CCTV 正常"）★★★
            //   依据：本类头注释铁律①明确写「activeURL = …?pid=<Pid>（**随频道变**）」，
            //   而这里一直是**写死的 pid=600001859（CCTV-1 的）** ⇒ 卫视组用的种子是错的。
            //   ⚠️ 只动 activeURL **一个变量**，tag 保持"用户已验收"的固定常量不动（一次只改一个）。
            //   `PALM_ACTIVEURL=fixed` 可退回旧行为 ⇒ **同一份二进制做严格 A/B**，不靠"改完就算是它"。
            var useFixedUrl = string.Equals(
                Environment.GetEnvironmentVariable("PALM_ACTIVEURL"), "fixed",
                StringComparison.OrdinalIgnoreCase);
            var activeUrl = (useFixedUrl || string.IsNullOrEmpty(pid))
                ? CmgActiveUrl
                : $"https://yangshipin.cn/tv/home?pid={pid}";
            /* ★★★★★ 2026-11-05：**不再有 CMG 核** ★★★★★
             *   桌面改为对 sm4c 分片做本地解密（`Sm4C.TryDecrypt`，密钥按 pid 查表）。
             *   这里只做两件事：记下当前频道的 pid（解密要用）+ 清分片缓存（换台别串）。
             *   ⚠️ 原来那段 `PalmTVCore.Init(tag, activeUrl)` 的 tag/时钟自证全部作废 ——
             *      sm4c 是**无状态**算法，没有会话、没有密钥流、不需要 reseed。 */
            // ⚠️ ActivePid 与缓存清理已在方法开头做过（换台也要生效），这里不再重复。
            _coreInited = true;
            _coreKey = tag;
            Log?.Invoke($"[dec] sm4c 解密就绪（无内核初始化）pid={ActivePid} " +
                        $"({(useFixedUrl ? "固定" : "按频道")} activeURL={activeUrl})");
        }
    }

    /// <summary>★ 2026-11-05：当前频道的 pid（sm4c 密钥按它查表；换台时由 <c>EnsureCore</c> 更新）</summary>
    internal static string ActivePid = "";

    /// <summary>★ 进程内只允许 init 一次的闸门（见 EnsureCore 注释；重复 init 会让解密整段失效）</summary>
    static bool _coreInited;

    // ==================== 监听 / 连接 ====================

    async Task AcceptLoopAsync(TcpListener lis, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient c;
            try { c = await lis.AcceptTcpClientAsync(ct); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { Log?.Invoke($"[dec] accept 异常: {ex.Message}"); continue; }
            _ = Task.Run(() => HandleAsync(c), CancellationToken.None);
        }
    }

    async Task HandleAsync(TcpClient c)
    {
        try
        {
            using (c)
            {
                c.NoDelay = true;
                using var s = c.GetStream();
                var reqLine = await ReadRequestLineAsync(s).ConfigureAwait(false);
                if (reqLine == null) return;
                var parts = reqLine.Split(' ');
                if (parts.Length < 2) { await RespondAsync(s, 400, "text/plain", Array.Empty<byte>(), false); return; }
                var method = parts[0].ToUpperInvariant();
                var target = parts[1];
                bool head = method == "HEAD";
                int q = target.IndexOf('?');
                var path = q < 0 ? target : target[..q];
                var query = q < 0 ? "" : target[(q + 1)..];
                Log?.Invoke($"[dec] {method} {path}");

                switch (path)
                {
                    case "/health":
                        await RespondAsync(s, 200, "text/plain", "ok"u8.ToArray(), head);
                        return;

                    case "/local.m3u8":
                        await ServePlaylistAsync(s, query, head);
                        return;

                    case "/local-seg":
                        await ServeSegmentAsync(s, query, head);
                        return;

                    default:
                        await RespondAsync(s, 404, "text/plain", Array.Empty<byte>(), head);
                        return;
                }
            }
        }
        catch (Exception ex) { Log?.Invoke($"[dec] 连接异常: {ex.Message}"); }
    }

    /// <summary>读请求行（只读头，GET/HEAD 无 body）。VLC 可能带很多头，逐行读到空行为止。</summary>
    static async Task<string?> ReadRequestLineAsync(NetworkStream s)
    {
        var buf = new byte[8192];
        int total = 0;
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            int n = await s.ReadAsync(buf.AsMemory(total)).ConfigureAwait(false);
            if (n <= 0) return null;
            total += n;
            var text = System.Text.Encoding.ASCII.GetString(buf, 0, total);
            if (text.Contains("\r\n\r\n") || total >= buf.Length) return text.Split("\r\n")[0];
        }
        return null;
    }

    // ==================== 路由 ====================

    /// <summary>/local.m3u8：拉远端 playlist，把分片行改写成 /local-seg；其余行原样保留。</summary>
    async Task ServePlaylistAsync(NetworkStream s, string query, bool head)
    {
        var remote = Param(query, "u");
        if (string.IsNullOrEmpty(remote)) { await RespondAsync(s, 400, "text/plain", Array.Empty<byte>(), head, "缺 u"); return; }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, remote);
            ApplyUpstreamHeaders(req, remote);
            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Log?.Invoke($"[dec] playlist 上游 HTTP {(int)resp.StatusCode}");
                await RespondAsync(s, 502, "text/plain", Array.Empty<byte>(), head, $"上游 {(int)resp.StatusCode}");
                return;
            }
            var text = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            var ck = Param(query, "ck");                            // 频道键（缓存兜底，对齐鸿蒙）
            // ★★★ 明文流（非 CMG 加密）必须**直通、不解密**，否则会把本来正常的帧改坏 ⇒ 花屏 ★★★
            //   判据照搬鸿蒙 `LocalDecryptServer.ets` 的 isNoDecryptUrl()（真机实测 + 白皮书 §11.3/§14）：
            //     ① CDN host 含 `mobilelive`（如 mobilelive-play-3/4.ysp.cctv.cn）
            //     ② URL 含 `m3u8_with_time_tag`
            //   ★ CCTV-6 正是这一路（用户实测：不直通时 VLC 放出来就是花屏）。
            // ★ 明文判定 = URL 特征 **或** playlist 内容特征（腾讯 QQ-HLS 那一套，见 IsNoDecryptPlaylist）
            var noDec = IsNoDecryptUrl(remote) || IsNoDecryptPlaylist(text);
            _lastPlaylistUrl = remote;

            // ★ 不要用 svrtime 做"服务器时间对齐"（用户确认：官方那个 serverTime 请求**根本没有时钟**，
            //   新版鸿蒙特意取消了这套逻辑）⇒ 这里**不做**任何时钟对齐。C 侧 cmg_rt_set_server_time 保持不调用。
            _ = ExtractQueryValue(remote, "svrtime");
            var rawSuffix = noDec ? "&raw=1" : "";
            if (noDec) Log?.Invoke("[dec] 明文流（mobilelive / m3u8_with_time_tag）⇒ 分片直通不解密");
            var baseUri = new Uri(remote);
            var sb = new System.Text.StringBuilder(text.Length + 512);
            int seq = 0;

            /* ★★ 2026-11-06：TARGETDURATION 必须与**实际分片时长**匹配 ★★
             *   原来硬编码 2 秒：央视频 7~9 秒分片时，"轮询快于产出"只是浪费；
             *   但 4K 台分片是 3 秒 ⇒ VLC 每 2 秒来要一次、每 3 秒才有一个 ⇒ 缓冲区规划错误
             *   ⇒ 实测分片请求间隔被拉成 5 秒（播放速度 0.6x）⇒ 幻灯片。
             *   现在取清单里 `#EXTINF` 的最大值向上取整（下限 2）。 */
            double maxDur = 0;
            foreach (var ln in text.Split('\n'))
            {
                var tl = ln.Trim();
                if (!tl.StartsWith("#EXTINF:", StringComparison.Ordinal)) continue;
                var num = tl.Substring(8).Split(',')[0].Trim();
                if (double.TryParse(num, System.Globalization.NumberStyles.Float,
                                    System.Globalization.CultureInfo.InvariantCulture, out var d) && d > maxDur)
                    maxDur = d;
            }
            int targetDur = Math.Max(2, (int)Math.Ceiling(maxDur));
            foreach (var raw in text.Split('\n'))
            {
                var line = raw.TrimEnd('\r');
                var t = line.Trim();
                if (t.Length == 0 || t.StartsWith('#'))
                {
                    // ★★ 2026-11-04：**清单归一化——TARGETDURATION**★★
                    //   原因：上游清单声明 7~9 秒，但**它自己 12 秒才发一片**。
                    //   VLC 的 HLS 模块按该值决定“多久问一次清单” ⇒ 永远晚一拍 ⇒ 缓冲吃干 ⇒ 卡顿。
                    //   实测（re/work/vlc-poll-test.py，本地合成清单 + VLC 无界面）：
                    //     TARGETDURATION=8 ⇒ VLC 清单间隔 8047ms；=4 ⇒ 4116ms；=2 ⇒ 2063ms
                    //   ⇒ **VLC 确实按这个字段轮询**，所以这里的归一化是真有收益的（不是心理作用）。
                    if (t.StartsWith("#EXT-X-TARGETDURATION", StringComparison.Ordinal))
                    {
                        sb.Append($"#EXT-X-TARGETDURATION:{targetDur}").Append("\r\n");
                        continue;
                    }
                    // ★ EXT-X-KEY / EXT-X-MAP 里的 URI 也要走本地，否则播放器会直连上游拿不到（签名/防盗链）
                    sb.Append(RewriteTagUris(line, baseUri, ck)).Append("\r\n");
                    continue;
                }
                // 分片行：解析为绝对地址后改写成 /local-seg
                var abs = Uri.TryCreate(baseUri, t, out var u) ? u.ToString() : t;
                var key = BuildSegKey(ck, abs, seq++);
                sb.Append($"local-seg?u={Uri.EscapeDataString(abs)}&k={Uri.EscapeDataString(key)}{rawSuffix}\r\n");
            }
            var body = System.Text.Encoding.UTF8.GetBytes(sb.ToString());
            // ★ 轮询间隔日志（与安卓 `[cmg-ds] 清单请求间隔=` 同口径）⇒ 看这一行就能判断归一化生效了没有。
            var nowMs = Environment.TickCount64;
            var gap = _lastPlaylistAtMs > 0 ? (nowMs - _lastPlaylistAtMs).ToString() + "ms" : "（首次）";
            _lastPlaylistAtMs = nowMs;
            Log?.Invoke($"[dec] playlist 改写完成（{seq} 片）清单请求间隔={gap} TARGETDURATION→ {targetDur}（实测最大分片 {maxDur:F1}s）");
            await RespondAsync(s, 200, M3U8_MIME, body, head);
        }
        catch (Exception ex) { Log?.Invoke($"[dec] playlist 失败: {ex.Message}"); await RespondAsync(s, 502, "text/plain", Array.Empty<byte>(), head); }
    }

    /// <summary>把 EXT-X-KEY/EXT-X-MAP 的 URI 也指回本地（对齐鸿蒙：所有媒体类 URI 都不让播放器直连上游）</summary>
    static string RewriteTagUris(string line, Uri baseUri, string ck)
    {
        int i = line.IndexOf("URI=", StringComparison.Ordinal);
        if (i < 0) return line;
        int q1 = line.IndexOf('"', i);
        if (q1 < 0) return line;
        int q2 = line.IndexOf('"', q1 + 1);
        if (q2 < 0) return line;
        var uri = line[(q1 + 1)..q2];
        var abs = Uri.TryCreate(baseUri, uri, out var u) ? u.ToString() : uri;
        var key = BuildSegKey(ck, abs, -1);
        return line[..q1] + $"\"local-seg?u={Uri.EscapeDataString(abs)}&k={Uri.EscapeDataString(key)}\"" + line[(q2 + 1)..];
    }

    /// <summary>缓存键：对齐鸿蒙的 k（含频道键 + 分片地址）；换台时 _segCache 会被清空，所以键里必须带频道信息。</summary>
    static string BuildSegKey(string ck, string absUrl, int seq)
    {
        // ★ 用 pid（若有）而非整条 URL：远端 m3u8 的令牌每次重取都不同，用 URL 会导致缓存永不命中
        var pid = ExtractQueryValue(absUrl, "pid") ?? ExtractQueryValue(absUrl, "livepid") ?? "";
        return $"{(ck.Length > 0 ? ck : pid)}|{seq}|{absUrl.GetHashCode():x8}";
    }

    static string? ExtractQueryValue(string url, string name)
    {
        try
        {
            var u = new Uri(url);
            foreach (var kv in u.Query.TrimStart('?').Split('&'))
            {
                var p = kv.Split('=', 2);
                if (p.Length == 2 && p[0] == name) return p[1];
            }
        }
        catch { }
        return null;
    }

    /// <summary>/local-seg：下载密文分片 → 原地解密 → 返回明文 TS（命中缓存则直接返回）。</summary>
    async Task ServeSegmentAsync(NetworkStream s, string query, bool head)
    {
        var remote = Param(query, "u");
        var key = Param(query, "k");
        if (string.IsNullOrEmpty(remote)) { await RespondAsync(s, 400, "text/plain", Array.Empty<byte>(), head, "缺 u"); return; }

        if (head) { await RespondAsync(s, 200, TS_MIME, Array.Empty<byte>(), true); return; }

        // ★ 明文流（raw=1）：**原样返回、绝不解密** —— 判据见 ServePlaylistAsync 里的 isNoDecryptUrl 注释
        var isRaw = Param(query, "raw") == "1";

        if (key.Length > 0 && _segCache.TryGetValue(key, out var cached))
        {
            await RespondAsync(s, 200, TS_MIME, cached, false);
            return;
        }
        // ★ 2026-10-29：sm4c（ChinaDRM SM4-CBC）**不需要** CMG 内核，
        //   所以「内核未初始化 ⇒ 503」的判断下移到下载之后、确认不是 sm4c 再做。
        try
        {
            // ★ 2026-11-06：分片耗时打点（4K 卡顿定位：区分"上游下载慢"与"本地解密慢"）
            var swSeg = System.Diagnostics.Stopwatch.StartNew();
            using var req = new HttpRequestMessage(HttpMethod.Get, remote);
            ApplyUpstreamHeaders(req, remote);
            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Log?.Invoke($"[dec] seg 上游 HTTP {(int)resp.StatusCode}");
                await RespondAsync(s, 502, "text/plain", Array.Empty<byte>(), false, $"上游 {(int)resp.StatusCode}");
                return;
            }
            var data = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            long msDl = swSeg.ElapsedMilliseconds;      // 下载耗时
            byte[] st;
            if (isRaw)
            {
                st = data;                                       // ★ 明文流直通：不碰一个字节
                Log?.Invoke($"[dec] seg（明文流）直通未解密 {data.Length}B");
            }
            else if (Sm4C.TryDecrypt(data, ActivePid, out var sm4, out var sm4Info))
            {
                // ★ ChinaDRM sm4c（SM4-CBC，**按台密钥** + PSSH 派生 IV）
                st = sm4;
                Log?.Invoke($"[dec] seg {data.Length}B {sm4Info}（下载 {msDl}ms / 解密 {swSeg.ElapsedMilliseconds - msDl}ms）");
            }
            else
            {
                /* ★ 2026-11-05：**CMG 兜底已移除**。
                 *   解不出 sm4c 只可能是：① 该台本来就明文（我们不该拦它）；② 上游换了密钥。
                 *   两种情况都**原样直通**——绝不能改写数据（那才是花屏的经典成因）。 */
                st = data;
                Log?.Invoke($"[dec] seg {data.Length}B 非 sm4c（{Sm4C.LastReason}）⇒ 原样直通");
            }
            if (key.Length > 0)
            {
                _segCache[key] = st;
                _segOrder.Enqueue(key);
                while (_segOrder.Count > SegCacheMax && _segOrder.TryDequeue(out var old)) _segCache.TryRemove(old, out _);
            }
            await RespondAsync(s, 200, TS_MIME, st, false);
        }
        catch (Exception ex)
        {
            Log?.Invoke($"[dec] seg 失败: {ex.Message}");
            await RespondAsync(s, 502, "text/plain", Array.Empty<byte>(), false);
        }
    }

    // ==================== HTTP 工具 ====================

    static string Param(string query, string name)
    {
        foreach (var kv in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var p = kv.Split('=', 2);
            if (p.Length == 2 && p[0] == name) return Uri.UnescapeDataString(p[1].Replace('+', ' '));
        }
        return "";
    }

    static async Task RespondAsync(NetworkStream s, int code, string mime, byte[] body, bool head, string? note = null)
    {
        var head2 = $"HTTP/1.1 {code} {Reason(code)}\r\n" +
                    $"Content-Type: {mime}\r\n" +
                    $"Content-Length: {body.Length}\r\n" +
                    "Access-Control-Allow-Origin: *\r\n" +
                    "Cache-Control: no-store\r\n" +
                    "Connection: close\r\n\r\n";
        var hb = System.Text.Encoding.ASCII.GetBytes(head2);
        await s.WriteAsync(hb).ConfigureAwait(false);
        if (!head && body.Length > 0) await s.WriteAsync(body).ConfigureAwait(false);
        if (note != null) Log?.Invoke($"[dec] → {code} {note}");
        await s.FlushAsync().ConfigureAwait(false);
    }

    static string Reason(int code) => code switch
    {
        200 => "OK", 400 => "Bad Request", 404 => "Not Found", 503 => "Service Unavailable", _ => "Bad Gateway"
    };

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }
}
