using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;

namespace PalmTVDesktop;

public class TvChannel
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Pid { get; init; } = "";
    public string CnlId { get; init; } = "";
    public override string ToString() => Name;
}

public class TvApiClient
{
    HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };
    static readonly Random _rng = new();
    public const string YspAppId = "519748109";
    // ★ 必须用 golden 抓包同款 guid: 硬编码的 YspTicket / golden cKey 都是据此生成的,
    //   换别的 guid 会导致 yspticket 失效 → get_live_info 401。后续应改为动态生成 yspticket。
    public const string Guid = "mra3u75l_jdrj8csvhkk"; // 与 golden HAR 一致
    public const string Cookie = "guid=" + Guid + "; versionName=99.99.99; versionCode=999999; vplatform=109; platformVersion=Chrome; deviceModel=150; newLogin=1; pc_version=1.1.16; ysp_uinfo_pc=;";
    public const string Ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";

    // ★ 本地 Go 代理 (Chrome TLS 指纹), C# → localhost:18888 → player-api.yangshipin.cn
    public string ProxyBaseUrl { get; set; } = "http://127.0.0.1:18888";
    // ★ 关键: vappid/vsecret 来自浏览器真实抓包 (HAR), 不带这两个参数会被 401
    public const string VappId = "59306155";
    public const string Vsecret = "b42702bf7309a179d102f3d51b1add2fda0bc7ada64cb801";
    // ★ yspticket: 现由动态生成, 此常量仅作「最终回退兜底」, 切勿依赖!
    //   主路径: MainWindow.GenerateYspTicketAsync() 在 WebView2 内用浏览器原生 V8
    //           实例化 RJq7sO71JF.wasm 复刻官方 _c (AES-CTR + PCG 尾缀), 输出 62 字节。
    //   备用路径: PlayerService.GenerateYspTicket() 用 Node 跑 gen_yspticket.cjs,
    //           同样复刻官方 _c, 失败时回退到本常量。
    //   攻破方法详见内部实现记录§2.6。
    //   下面这串是 2026-02 抓包旧值 (61 字节、guid 不同、带时效性), 已过期, 仅供应急。
    public const string YspTicket = "5c40d99c304df40d750e99bac51120e8f2527178eceecf574f8a3f41c8b5f5fca5d1969a067ef1cb18b282fe1cb2211ec0e6ccbbceb01ecee923533208";

    // ★ 认证签名盐 (官方 chunk-vendors.js 的 su() 所用, 生产环境)
    //   su 源码: e = sorted(appid,guid,pid,rand_str) 拼接 + Ac;  return md5(e)
    //   Ac = (href 含 test=on) ? "PUlOFD%XM9jEdvuR" : "n@7QKk%YeSjfw%22"
    public const string AuthSalt = "n@7QKk%YeSjfw%22";
    // ★ live body 签名(au)与 yspsdkinput(ne) 的盐: 生产环境 LiveSaltTc; 测试 "62fb5e14f246f"
    public const string LiveSaltTc = "0f$IVHi9Qno?G";

    // ★ live 需要的 cKey (有时效性, 需从浏览器 F12 抓包获取最新值, 见 接口抓包记录)
    //   留空时 get_live_info 会被拒绝 (缺 cKey)
    public static string LiveCKey { get; set; } = "";

    /// <summary>
    /// 计算 auth 接口签名 —— 复刻官方 su()：md5( 按 key 字母序拼接 "appid/guid/pid/rand_str" + AuthSalt )。
    /// 注意: 这是盐化 MD5, 与 live 用的 wasm get_signature 完全不同!
    /// </summary>
    public static string ComputeAuthSignature(string pid, string guid, string randStr)
    {
        // 字母序: appid < guid < pid < rand_str (与官方默认 Array.sort 一致)
        var d = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["appid"] = "ysp_pc",
            ["guid"] = guid,
            ["pid"] = pid,
            ["rand_str"] = randStr,
        };
        // ★ 关键: 每对之间必须加 & 分隔符 (对齐官方 su: 0!=r&&(e+="&"))
        //   之前漏了 &, 拼成一个粘连字符串, md5 永远对不上 → auth 401
        var sb = new System.Text.StringBuilder();
        bool first1 = true;
        foreach (var kv in d)
        {
            if (!first1) sb.Append('&'); else first1 = false;
            sb.Append(kv.Key).Append('=').Append(kv.Value);
        }
        sb.Append(AuthSalt); // 末尾追加盐(无 & 分隔)
        using var md5 = System.Security.Cryptography.MD5.Create();
        var bytes = md5.ComputeHash(System.Text.Encoding.UTF8.GetBytes(sb.ToString()));
        var outSb = new System.Text.StringBuilder();
        foreach (var b in bytes) outSb.Append(b.ToString("x2"));
        return outSb.ToString();
    }

    public static string RandStr(int len) => string.Create(len, _rng, (buf, r) => { for (int i = 0; i < len; i++) buf[i] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKlMNOPQRSTUVWXYZ0123456789"[r.Next(62)]; });

    private static long _seqId = 0;
    public static string NextSeqId() => Interlocked.Increment(ref _seqId).ToString();

    // ===== live 签名 (纯 MD5, 已用 HAR 真实值验证) =====
    // xs()/ne(): yspsdkinput(rnd) = md5( 按 String.localeCompare 排序拼接 body 的 k=v, 无盐 )
    // 关键: 排序必须用 localeCompare(类 JS localeCompare), 不能用 Ordinal!
    //       app_version / appVer 等键在两种排序下顺序不同, 用 Ordinal 会算错 rnd。
    //       (get_live_info 调用 xs() 时 body 尚未写入 rand_str/signature, 故二者天然不参与)
    private static readonly StringComparer XsComparer =
        StringComparer.Create(System.Globalization.CultureInfo.GetCultureInfo("en-US"), System.Globalization.CompareOptions.None);
    public static string ComputeLiveSdkInput(Dictionary<string, string> fields)
    {
        var d = new SortedDictionary<string, string>(XsComparer);
        foreach (var kv in fields)
            if (kv.Key != "rand_str" && kv.Key != "signature") d[kv.Key] = kv.Value;
        var sb = new System.Text.StringBuilder();
        bool first2 = true;
        foreach (var kv in d)
        {
            if (!first2) sb.Append('&'); else first2 = false;
            sb.Append(kv.Key).Append('=').Append(kv.Value);
        }
        return Md5Hex(sb.ToString());
    }
    // au(): body.signature = md5( 默认排序(Ordinal)拼接 body 的 k=v(含 rand_str, 排除 signature) + LiveSaltTc )
    public static string ComputeLiveBodySignature(Dictionary<string, string> fields)
    {
        var d = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var kv in fields) if (kv.Key != "signature") d[kv.Key] = kv.Value;
        var sb = new System.Text.StringBuilder();
        bool first3 = true;
        foreach (var kv in d)
        {
            if (!first3) sb.Append('&'); else first3 = false;
            sb.Append(kv.Key).Append('=').Append(kv.Value);
        }
        sb.Append(LiveSaltTc); // 末尾追加盐 Tc(无 & 分隔)
        return Md5Hex(sb.ToString());
    }
    static string Md5Hex(string s)
    {
        using var md5 = System.Security.Cryptography.MD5.Create();
        var b = md5.ComputeHash(System.Text.Encoding.UTF8.GetBytes(s));
        var sb = new System.Text.StringBuilder();
        foreach (var x in b) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    // ★ kvcollect 心跳: 与 auth 共用同盐 AuthSalt. 找到 BossId/Pwd 与 ftime/progid/durl 等即可.
    public const string KvBossId = "99150";  // 9+9150(原值),源码 BossId 前会拼 "9"
    public const string KvPwd = "1999332929"; // 心跳固定口令
    public const string KvUrl = "https://aatc-api.yangshipin.cn/kvcollect";

    /// <summary>
    /// 计算 kvcollect 签名: md5( 字母序拼接 k=v&... + AuthSalt )。与 auth 共用盐 n@7QKk%YeSjfw%22。
    /// </summary>
    public static string ComputeKvCollectSignature(Dictionary<string, string> fields)
    {
        var d = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var kv in fields) if (kv.Key != "signature") d[kv.Key] = kv.Value;
        var sb = new System.Text.StringBuilder();
        bool first3 = true;
        foreach (var kv in d)
        {
            if (!first3) sb.Append('&'); else first3 = false;
            sb.Append(kv.Key).Append('=').Append(kv.Value);
        }
        sb.Append(AuthSalt);
        return Md5Hex(sb.ToString());
    }

    /// <summary>
    /// 发送一次 kvcollect 心跳. 成功: 200 + {"code":0}; 失败: 返回错误信息.
    /// </summary>
    public static async Task<(int code, string body)> SendKvCollectAsync(string livepid, string durl)
    {
        try
        {
            var ftime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            var rand = "abcdefghij".Substring(0, 10); // 10 字符随机串
            var fields = new Dictionary<string, string>
            {
                ["BossId"] = KvBossId,
                ["Pwd"] = KvPwd,
                ["ftime"] = ftime,
                ["progid"] = livepid,         // 与 livepid 同值
                ["viewid"] = livepid,
                ["livepid"] = livepid,
                ["durl"] = durl,
                ["fplayerver"] = "189",
                ["platform"] = "5910204",
                ["appver"] = "1.1.11",
                ["guid"] = Guid,
                ["devtype"] = Ua,
                ["switch"] = "fhd",
                ["defn"] = "fhd",
                ["cmd"] = "263",
                ["iqq"] = "",
                ["nettype"] = "4g",
                ["url"] = durl,
                ["rand_str"] = rand,
            };
            fields["signature"] = ComputeKvCollectSignature(fields);
            var json = System.Text.Json.JsonSerializer.Serialize(fields);

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            var req = new HttpRequestMessage(HttpMethod.Post, KvUrl) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") };
            req.Headers.TryAddWithoutValidation("Referer", "https://yangshipin.cn/");
            req.Headers.TryAddWithoutValidation("User-Agent", Ua);
            req.Headers.TryAddWithoutValidation("Origin", "https://yangshipin.cn");
            var resp = await http.SendAsync(req);
            var body2 = await resp.Content.ReadAsStringAsync();
            return ((int)resp.StatusCode, body2);
        }
        catch (Exception ex) { return (0, ex.Message); }
    }

    public static List<TvChannel> Channels { get; } = new()
    {
        // ★ 2026-09-04: 全量回灌鸿蒙权威列表 旧 ArkWeb 版/.../common/ChannelList.ets
        //   (id/name/pid/cnlId 逐一与其一致; cnlId 决定清晰度档位, 不得再用旧值)
        // CCTV 组
        new() { Id="cctv1",Name="CCTV-1 综合",Pid="600001859",CnlId="2024078203"},
        new() { Id="cctv2",Name="CCTV-2 财经",Pid="600001800",CnlId="2024075403"},
        new() { Id="cctv3",Name="CCTV-3 综艺",Pid="600001801",CnlId="2024068503"},
        new() { Id="cctv4",Name="CCTV-4 中文国际",Pid="600001814",CnlId="2029797103"},
        new() { Id="cctv5",Name="CCTV-5 体育",Pid="600001818",CnlId="2024078403"},
        new() { Id="cctv5p",Name="CCTV-5+ 赛事",Pid="600001817",CnlId="2024078003"},
        new() { Id="cctv6",Name="CCTV-6 电影",Pid="600108442",CnlId="2013693901"},
        new() { Id="cctv7",Name="CCTV-7 军事",Pid="600004092",CnlId="2024072003"},
        new() { Id="cctv8",Name="CCTV-8 电视剧",Pid="600001803",CnlId="2029793003"},
        new() { Id="cctv9",Name="CCTV-9 纪录",Pid="600004078",CnlId="2024078603"},
        new() { Id="cctv10",Name="CCTV-10 科教",Pid="600001805",CnlId="2024078703"},
        new() { Id="cctv11",Name="CCTV-11 戏曲",Pid="600001806",CnlId="2027248703"},
        new() { Id="cctv12",Name="CCTV-12 社会与法",Pid="600001807",CnlId="2027248803"},
        new() { Id="cctv13",Name="CCTV-13 新闻",Pid="600001811",CnlId="2029797203"},
        new() { Id="cctv14",Name="CCTV-14 少儿",Pid="600001809",CnlId="2027248903"},
        new() { Id="cctv15",Name="CCTV-15 音乐",Pid="600001815",CnlId="2027249003"},
        new() { Id="cctv16",Name="CCTV-16 奥林匹克",Pid="600098637",CnlId="2027249103"},
        new() { Id="cctv16k",Name="CCTV-16(4K)",Pid="600099502",CnlId="2027249303"},
        new() { Id="cctv17",Name="CCTV-17 农业",Pid="600001810",CnlId="2027249403"},
        new() { Id="cctv4k",Name="CCTV-4K 超高清",Pid="600002264",CnlId="2029810303"},
        new() { Id="cctv8k",Name="CCTV-8K",Pid="600156816",CnlId="2026774121"},
        new() { Id="cetv1",Name="中国教育1台",Pid="600171827",CnlId="2022823801"},
        new() { Id="cgne",Name="CGN英文台",Pid="600014550",CnlId="2024181703"},
        // 卫视频道组
        new() { Id="jsws",Name="江苏卫视",Pid="600002521",CnlId="2024171103"},
        new() { Id="hnws",Name="湖南卫视",Pid="600002475",CnlId="2024054803"},
        new() { Id="zjws",Name="浙江卫视",Pid="600002520",CnlId="2024054703"},
        new() { Id="bjws",Name="北京卫视",Pid="600002309",CnlId="2024052703"},
        new() { Id="dfws",Name="东方卫视",Pid="600002483",CnlId="2024054503"},
        new() { Id="henws",Name="河南卫视",Pid="600002525",CnlId="2029797303"},
        new() { Id="hebws",Name="河北卫视",Pid="600002493",CnlId="2024171503"},
        new() { Id="ahws",Name="安徽卫视",Pid="600002532",CnlId="2024171403"},
        new() { Id="tjws",Name="天津卫视",Pid="600152137",CnlId="2019927003"},
        new() { Id="sdws",Name="山东卫视",Pid="600002513",CnlId="2029787903"},
        new() { Id="sxws",Name="山西卫视",Pid="600190407",CnlId="2025560803"},
        new() { Id="dnws",Name="东南卫视",Pid="600002484",CnlId="2024061503"},
        new() { Id="hbws",Name="湖北卫视",Pid="600002508",CnlId="2024171203"},
        new() { Id="jxws",Name="江西卫视",Pid="600002503",CnlId="2024061703"},
        new() { Id="shxws",Name="陕西卫视",Pid="600190400",CnlId="2029795103"},
        new() { Id="lnws",Name="辽宁卫视",Pid="600002505",CnlId="2024171303"},
        new() { Id="jlws",Name="吉林卫视",Pid="600190405",CnlId="2025561503"},
        new() { Id="hebs",Name="黑龙江卫视",Pid="600002498",CnlId="2029797003"},
        new() { Id="ynws",Name="云南卫视",Pid="600190402",CnlId="2025561303"},
        new() { Id="gzws",Name="贵州卫视",Pid="600002490",CnlId="2024061603"},
        new() { Id="scws",Name="四川卫视",Pid="600002516",CnlId="2024061403"},
        new() { Id="cqws",Name="重庆卫视",Pid="600002531",CnlId="2024061103"},
        new() { Id="hainanws",Name="海南卫视",Pid="600002506",CnlId="2024055603"},
        new() { Id="gdws",Name="广东卫视",Pid="600002485",CnlId="2024060903"},
        new() { Id="gxws",Name="广西卫视",Pid="600002509",CnlId="2024060703"},
        new() { Id="szws",Name="深圳卫视",Pid="600002481",CnlId="2024061303"},
        new() { Id="nmgws",Name="内蒙古卫视",Pid="600190401",CnlId="2025561203"},
        new() { Id="gansuws",Name="甘肃卫视",Pid="600190408",CnlId="2025561703"},
        new() { Id="qhws",Name="青海卫视",Pid="600190406",CnlId="2025559103"},
        new() { Id="xzws",Name="西藏卫视",Pid="600190403",CnlId="2025558003"},
        new() { Id="xinjiangws",Name="新疆卫视",Pid="600152138",CnlId="2019927403"},
        new() { Id="ningxiaws",Name="宁夏卫视",Pid="600190737",CnlId="2025608503"},
    };

    public class ApiException : Exception
    {
        public int StatusCode { get; }
        public ApiException(int code, string msg) : base(msg) { StatusCode = code; }
    }

    void DebugLog(string msg)
    {
        // 调试日志已注释（如需恢复，移除以下注释符号）
        // try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "player-debug.log"), $"[{DateTime.Now:HH:mm:ss.fff}] [API] {msg}\n"); } catch { }
    }

#if LEGACY_WASMTIME
    // ★★ 遗留路径 (无调用点, 保留供分析/回溯):
    //   C# 侧用 Wasmtime 跑 keygen_bg.wasm 做 get_token_rnd / get_signature, 全程走 HTTP。
    //   现役路径是 MainWindow.FetchViaPostMessage() —— 签名改由页面内 keygen_bg.wasm 完成(见 player.html),
    //   因此 Wasmtime 包 + WasmSigner 已从工程中移除(省 ~9.3MB 发布体积)。
    //   需要恢复: csproj 加回 <PackageReference Include="Wasmtime" Version="20.0.2" />、
    //   加 <DefineConstants>$(DefineConstants);LEGACY_WASMTIME</DefineConstants>,
    //   并把 legacy/WasmSigner.cs 移回项目根目录。
    public async Task<string?> FetchM3u8UrlAsync(WasmSigner signer, TvChannel ch)
    {
        DebugLog($"=== 开始获取 {ch.Name} (pid={ch.Pid}, cnlid={ch.CnlId}) ===");

        var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();

        // ====== 第 1 步: POST player-api/auth 获取 token + ts ======
        // ★ 关键修复 (401 根因): auth 签名必须用官方 su() 的盐化 MD5, 不能用 wasm 的 get_signature!
        //   signature = md5( sorted(appid,guid,pid,rand_str) 拼接 + AuthSalt )
        var randStr = RandStr(10);  // 真实浏览器 auth rand_str 是独立随机 10 字符串
        var authSig = ComputeAuthSignature(ch.Pid, Guid, randStr);

        var authBody = $"pid={ch.Pid}&guid={Guid}&appid=ysp_pc&rand_str={randStr}&signature={authSig}";
        DebugLog($"[AUTH] POST player-api/auth body: {authBody}");
        DebugLog($"[AUTH] signature={authSig}, rand_str={randStr}");

        var seqId = 1;
        var reqId1 = "999999" + RandStr(6) + ts;
        var (authStatus, authText) = await PostForm($"{ProxyBaseUrl}/auth",
            authBody, seqId, reqId1);
        DebugLog($"[AUTH] 响应 HTTP {authStatus}: {(string.IsNullOrEmpty(authText) ? "(空)" : authText[..Math.Min(250, authText.Length)])}");

        if (authStatus == 401)
        {
            DebugLog("[AUTH] 401! HttpClient 的 TLS 指纹被检测");
            throw new ApiException(401, "auth HTTP 401 — C# HttpClient 不支持浏览器 TLS 指纹");
        }
        if (authStatus != 200 || string.IsNullOrEmpty(authText))
            throw new ApiException(authStatus, $"auth HTTP {authStatus}");

        JsonNode? authJson = null;
        try { authJson = JsonNode.Parse(authText); } catch { }
        if (authJson?["code"]?.ToString() != "0")
            throw new ApiException(0, $"auth code != 0: {authText?[..Math.Min(200, authText.Length)]}");

        var yspToken = authJson["data"]?["token"]?.ToString();
        var authTs = authJson["data"]?["ts"]?.ToString() ?? ts;
        if (string.IsNullOrEmpty(yspToken))
            throw new ApiException(0, "auth 响应无 token");
        DebugLog($"[AUTH] token 前20: {yspToken[..Math.Min(20, yspToken.Length)]}..., ts={authTs}");

        // ====== 第 1.5 步: GET /web/open/token 获取 sessionToken (用于 sig2) ======
        // ★ 关键修复 (20401 根因): sig2 的 wasm get_signature 必须用 sessionToken,
        //   而 /auth 返回的 yspToken 是 authToken, 仅作网关层 yspplayertoken 校验!
        //   二者是不同体系的 token, 混用 → openapi_signature 错 → 20401 防盗链校验失败。
        var tsMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
        signer.SetState(new YspState { Guid = Guid, Yspappid = YspAppId }, fresh: true); // 实例化 wasm 以调 get_token_rnd
        var rndVal = signer.GetTokenRnd();
        var openUrl = $"{ProxyBaseUrl}/open-token?yspappid={YspAppId}&guid={Guid}&vappid={VappId}&vsecret={Vsecret}&raw=1&version=v1&ts={tsMs}&rnd={rndVal}";
        DebugLog($"[OPEN-TOKEN] GET {openUrl}");
        var (otStatus, otText) = await GetOpenToken(openUrl);
        DebugLog($"[OPEN-TOKEN] 响应 HTTP {otStatus}: {(string.IsNullOrEmpty(otText) ? "(空)" : otText[..Math.Min(200, otText.Length)])}");
        string? sessionToken = null;
        if (otStatus == 200 && !string.IsNullOrEmpty(otText))
        {
            try { var oj = JsonNode.Parse(otText); sessionToken = oj?["data"]?["token"]?.ToString(); } catch { }
        }
        if (string.IsNullOrEmpty(sessionToken))
            throw new ApiException(otStatus, $"open/token 失败: {otText?[..Math.Min(150, otText.Length)]}");
        DebugLog($"[OPEN-TOKEN] sessionToken 前20: {sessionToken[..Math.Min(20, sessionToken.Length)]}...");

        // ====== 第 2 步: POST get_live_info ======
        // ★ 已验证: yspsdkinput(rnd) 与 body.signature 都是纯 MD5, 不需要 wasm!
        //   - yspsdkinput = md5( localeCompare 排序 body 的 k=v, 排除 rand_str/signature, 无盐 ) → ComputeLiveSdkInput
        //   - body.signature = md5( 默认排序(Ordinal) body 的 k=v(含 rand_str) + LiveSaltTc ) → ComputeLiveBodySignature
        //   - yspsdksign 的 openapi_signature 仍由 wasm get_signature 产出 (本步保留)
        //   注意: ComputeLiveSdkInput 用 localeCompare 排序, ComputeLiveBodySignature 用 Ordinal 排序, 二者不同!
        var randStrLive = RandStr(10);
        var fields = new Dictionary<string, string> {
            ["cnlid"] = ch.CnlId, ["livepid"] = ch.Pid, ["stream"] = "2",
            ["guid"] = Guid, ["cKey"] = LiveCKey, ["adjust"] = "1", ["sphttps"] = "1",
            ["platform"] = "5910204", ["cmd"] = "2", ["encryptVer"] = "8.1",
            ["dtype"] = "1", ["devid"] = "devid", ["otype"] = "ojson",
            ["appVer"] = "V1.0.0", ["app_version"] = "V1.0.0",
            ["channel"] = "ysp_tx", ["defn"] = "fhd", ["rand_str"] = randStrLive
        };
        var rnd2 = ComputeLiveSdkInput(fields);           // = yspsdkinput (ne, 无盐)
        var bodySig = ComputeLiveBodySignature(fields);   // = body.signature (au + Tc)

        // yspsdksign 的 openapi_signature 由 wasm get_signature 产出,
        // ★ 关键修复: token 必须用 /web/open/token 返回的 sessionToken, 而非 /auth 的 authToken!
        //   (authToken 仅作网关层 yspplayertoken 校验; sessionToken 才是服务器校验 sig2 的密钥)
        var seqId2 = 2;
        var reqId2 = "999999" + RandStr(6) + authTs;
        var fullInput2 = $"{rnd2}-{Guid}-{seqId2}-{reqId2}";
        var state = new YspState { Guid = Guid, Pid = ch.Pid, Ts = authTs, Token = sessionToken, Input = fullInput2 };
        signer.SetState(state, fresh: true);   // 重新实例化 wasm, 确保用 sessionToken 算 sig2
        var sig2 = signer.GetSignature();                 // = openapi_signature (wasm, 用 sessionToken)
        var openapiSig = $"{sig2}-{rnd2}-{Guid}-{seqId2}-{reqId2}";

        DebugLog($"[LIVE] rnd(yspsdkinput)={rnd2}");
        DebugLog($"[LIVE] body.signature={bodySig}");
        DebugLog($"[LIVE] yspsdksign={openapiSig}");
        DebugLog($"[LIVE] seqid={seqId2}, reqId={reqId2}");

        var bodyJ = new JsonObject {
            ["cnlid"] = ch.CnlId, ["livepid"] = ch.Pid, ["stream"] = "2",
            ["guid"] = Guid, ["cKey"] = LiveCKey, ["adjust"] = 1, ["sphttps"] = "1",
            ["platform"] = "5910204", ["cmd"] = "2", ["encryptVer"] = "8.1",
            ["dtype"] = "1", ["devid"] = "devid", ["otype"] = "ojson",
            ["appVer"] = "V1.0.0", ["app_version"] = "V1.0.0",
            ["channel"] = "ysp_tx", ["defn"] = "fhd",
            ["rand_str"] = randStrLive, ["signature"] = bodySig
        };

        // ★ 动态生成 yspticket: 复刻官方 _c(livepid, ts, cnlid, guid, yspappid, appVer)
        //   - ts 用认证返回的 authTs (秒), 同时作为 wasm _time/PCG 种子
        //   - 失败自动回退到硬编码 YspTicket, 不影响其它流程
        var yspticket = GenerateYspTicket(ch.Pid, authTs, ch.CnlId);

        var (liveStatus, liveText) = await PostJson($"{ProxyBaseUrl}/get-live-info",
            bodyJ.ToJsonString(), yspToken, rnd2, openapiSig, reqId2, seqId2, yspticket);
        DebugLog($"[LIVE] 响应 HTTP {liveStatus}: {(string.IsNullOrEmpty(liveText) ? "(空)" : liveText[..Math.Min(300, liveText.Length)])}");

        if (liveStatus == 401) throw new ApiException(401, "get_live_info HTTP 401 — 可能缺 cKey/yspticket");
        if (liveStatus != 200 || string.IsNullOrEmpty(liveText)) throw new ApiException(liveStatus, $"get_live_info HTTP {liveStatus}");

        JsonNode? jn = null;
        try { jn = JsonNode.Parse(liveText); } catch { throw new ApiException(liveStatus, "响应非JSON: " + liveText[..Math.Min(liveText.Length, 100)]); }
        var vurl = jn?["data"]?["playurl"]?.ToString() ?? jn?["data"]?["vurl"]?.ToString();
        var ext = jn?["data"]?["extended_param"]?.ToString() ?? "";
        return vurl != null ? vurl + ext : null;
    }
#endif // LEGACY_WASMTIME

    async Task<(int status, string? body)> GetOpenToken(string url)
    {
        try
        {
            using var r = new HttpRequestMessage(HttpMethod.Get, url);
            r.Headers.TryAddWithoutValidation("User-Agent", Ua);
            r.Headers.TryAddWithoutValidation("Referer", "https://yangshipin.cn/");
            r.Headers.TryAddWithoutValidation("Origin", "https://yangshipin.cn");
            r.Headers.TryAddWithoutValidation("Accept", "*/*");
            var resp = await _http.SendAsync(r);
            var respText = await resp.Content.ReadAsStringAsync();
            return ((int)resp.StatusCode, respText);
        }
        catch (Exception ex) { return (0, ex.Message); }
    }

    async Task<(int status, string? body)> PostForm(string url, string body, int nseq, string reqId)
    {
        try
        {
            using var r = new HttpRequestMessage(HttpMethod.Post, url);
            SetHdrs(r);
            r.Headers.TryAddWithoutValidation("yspappid", YspAppId);
            // ★ 对齐真实浏览器: auth 请求只发 yspappid + 标准浏览器头, 不带 Cookie/request-id/seqid
            //   (HAR 实测浏览器 auth 请求无 Cookie; 多带这些头反而可能触发 APISIX 风控)
            var content = new StringContent(body, System.Text.Encoding.UTF8);
            content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/x-www-form-urlencoded");
            r.Content = content;

            // 日志已注释
            /*
            try {
                var sb = new StringBuilder();
                sb.AppendLine($"[OUT] POST {url}");
                foreach (var h in r.Headers) sb.AppendLine($" H: {h.Key}: {string.Join(";", h.Value)}");
                foreach (var h in r.Content.Headers) sb.AppendLine($" C: {h.Key}: {string.Join(";", h.Value)}");
                sb.AppendLine($" BODY: {body}");
                DebugLog(sb.ToString());
            } catch { }
            */

            var resp = await _http.SendAsync(r);
            var respText = await resp.Content.ReadAsStringAsync();
            DebugLog($"[IN] HTTP {(int)resp.StatusCode} from {url}: {(string.IsNullOrEmpty(respText)?"(empty)":respText[..Math.Min(300, respText.Length)])}");
            return ((int)resp.StatusCode, respText);
        }
        catch (Exception ex) { return (0, ex.Message); }
    }

    /// <summary>
    /// 动态生成 yspticket —— 复刻官方 _c(livepid, ts, cnlid, guid, yspappid, appVer) + RJq7sO71JF.wasm。
    /// 通过 Node 运行 gen_yspticket.cjs (已验证可独立产出正确 62 字节 token)。
    /// 任何异常/缺失都会回退到硬编码的 YspTicket, 绝不阻断其它流程。
    /// </summary>
    public string GenerateYspTicket(string livepid, string ts, string cnlid)
    {
        try
        {
            var baseDir = AppContext.BaseDirectory;
            var wasmPath = Path.Combine(baseDir, "RJq7sO71JF.wasm");
            var scriptPath = Path.Combine(baseDir, "gen_yspticket.cjs");
            if (!File.Exists(wasmPath) || !File.Exists(scriptPath))
            {
                DebugLog("[YSPTICKET] 缺少 RJq7sO71JF.wasm / gen_yspticket.cjs, 回退硬编码值");
                return YspTicket;
            }
            // _time 种子 = 认证返回的 ts (秒), 与 _c 第2参数保持一致
            var seed = ts;
            var psi = new ProcessStartInfo
            {
                FileName = "node",
                Arguments = $"\"{scriptPath}\" \"{livepid}\" \"{ts}\" \"{cnlid}\" \"{Guid}\" \"{YspAppId}\" \"V1.0.0\" \"{seed}\" \"{wasmPath}\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi);
            if (p == null) { DebugLog("[YSPTICKET] 无法启动 node 进程, 回退硬编码值"); return YspTicket; }
            var outp = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(15000);
            var errp = p.StandardError.ReadToEnd().Trim();
            if (p.ExitCode != 0 || string.IsNullOrEmpty(outp))
            {
                DebugLog($"[YSPTICKET] node 生成失败 (exit={p.ExitCode}): {errp}");
                return YspTicket;
            }
            DebugLog($"[YSPTICKET] 动态生成成功, {outp.Length / 2} 字节: {outp[..Math.Min(48, outp.Length)]}...");
            return outp;
        }
        catch (Exception ex)
        {
            DebugLog($"[YSPTICKET] 异常, 回退硬编码值: {ex.Message}");
            return YspTicket;
        }
    }

    async Task<(int status, string? body)> PostJson(string url, string body, string token, string rnd, string openapiSig, string reqId, int nseq, string yspticket)
    {
        try
        {
            using var r = new HttpRequestMessage(HttpMethod.Post, url);
            SetHdrs(r);
            r.Headers.TryAddWithoutValidation("yspappid", YspAppId);
            r.Headers.TryAddWithoutValidation("yspplayertoken", token);
            r.Headers.TryAddWithoutValidation("yspsdkinput", rnd);
            r.Headers.TryAddWithoutValidation("yspsdksign", openapiSig);
            r.Headers.TryAddWithoutValidation("yspticket", yspticket);
            r.Headers.TryAddWithoutValidation("request-id", reqId);
            r.Headers.TryAddWithoutValidation("seqid", nseq.ToString());
            r.Headers.TryAddWithoutValidation("Cookie", Cookie + $" nseqId={nseq}; nrequest-id={reqId}");
            var jsonContent = new StringContent(body, System.Text.Encoding.UTF8);
            jsonContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            r.Content = jsonContent;

            // 日志已注释
            /*
            try {
                var sb = new StringBuilder();
                sb.AppendLine($"[OUT] POST {url}");
                foreach (var h in r.Headers) sb.AppendLine($" H: {h.Key}: {string.Join(";", h.Value)}");
                foreach (var h in r.Content.Headers) sb.AppendLine($" C: {h.Key}: {string.Join(";", h.Value)}");
                sb.AppendLine($" BODY: {body}");
                DebugLog(sb.ToString());
            } catch { }
            */

            var resp = await _http.SendAsync(r);
            var respText = await resp.Content.ReadAsStringAsync();
            DebugLog($"[IN] HTTP {(int)resp.StatusCode} from {url}: {(string.IsNullOrEmpty(respText)?"(empty)":respText[..Math.Min(300, respText.Length)])}");
            return ((int)resp.StatusCode, respText);
        }
        catch (Exception ex) { return (0, ex.Message); }
    }

    static void SetHdrs(HttpRequestMessage r)
    {
        // ★ 关键: 完全模拟浏览器真实请求头
        // APISIX 通过这些 header 识别"是不是真浏览器", 缺一个就 401
        r.Headers.TryAddWithoutValidation("User-Agent", Ua);
        r.Headers.TryAddWithoutValidation("Referer", "https://yangshipin.cn/");
        r.Headers.TryAddWithoutValidation("Origin", "https://yangshipin.cn");
        r.Headers.TryAddWithoutValidation("accept", "application/json, text/plain, */*");
        r.Headers.TryAddWithoutValidation("accept-encoding", "gzip, deflate, br");
        r.Headers.TryAddWithoutValidation("accept-language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7,en-GB;q=0.6");
        r.Headers.TryAddWithoutValidation("cache-control", "no-cache");
        r.Headers.TryAddWithoutValidation("pragma", "no-cache");
        r.Headers.TryAddWithoutValidation("priority", "u=1, i");
        r.Headers.TryAddWithoutValidation("sec-ch-ua", "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\"");
        r.Headers.TryAddWithoutValidation("sec-ch-ua-mobile", "?0");
        r.Headers.TryAddWithoutValidation("sec-ch-ua-platform", "\"Windows\"");
        r.Headers.TryAddWithoutValidation("sec-fetch-dest", "empty");
        r.Headers.TryAddWithoutValidation("sec-fetch-mode", "cors");
        r.Headers.TryAddWithoutValidation("sec-fetch-site", "same-site");
    }
}