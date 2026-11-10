using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace PalmTVDesktop;

/// <summary>
/// 央视频「安卓平台」取流链路（2026-11-05 从安卓端 <c>data/YspAndroidLive.kt</c> 移植）。
///
/// **为什么桌面也要换到这条链**：
///   · Web/PC 链路的加密台给的是 **CMG 加密**，而 CMG 解密核已从桌面移除；
///   · 安卓链路给的分片是 **sm4c**（8 个台）或明文，前者由 <see cref="Sm4C"/> 在本地代理解密；
///   · 同时这条链**天然支持回看 / 时移**（`playbacktime`），而 Web/PC 链路给不出。
///
/// **三条硬约束（与安卓逐条对齐，别改）**：
///   1. `defn` 传 `auto`；`spdrm` **必须 2**（声明支持 DRM），改成 0 会 `iretcode=57 版权限制`；
///   2. `stream=3`、`sdtfrom=v5028`（请求体），而 cKey 内部的 sdtfrom 是 `v5082` —— 两者不同，别搞反；
///   3. cKey 的 `ts` 与请求参数 `fntick` **必须同一秒**（服务端校验时效），`guid` 也必须与载荷内一致。
/// </summary>
internal static class YspAndroidLive
{
    const string Host = "https://liveinfo.ysp.cctv.cn/";
    const string Ua = "qqlive";
    const string Platform = "4330303";              // 安卓平台号（服务端按它区分 web/安卓）
    const string CkeyVer = "V8.26.1034.0171";

    /// <summary>设备标识。★ 必须与 HTTP 参数 `guid` 完全一致（服务端交叉校验载荷内那份）。</summary>
    internal const string Guid = "YOUR_DEVICE_GUID";

    /// <summary>设备能力描述（真机抓包值，单行清洗版）。</summary>
    const string Spvcode =
        "MSgzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MHwzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MCk7" +
        "MigzMDoxNDQwLDYwOjEwODAsOTA6NzIwLDEyMDo3MjB8MzA6MTQ0MCw2MDoxMDgwLDkwOjcyMCwxMjA6NzIwKQ==";

    /// <summary>estid（真机 est 文件内容）。</summary>
    const string Estid = "zg+Ym3rNTnD6DWvhotJfotqgIWJ4Ihv5ouS3Ht1hDVeVyxYbTsD6Htm5HtDjIhAjHai=";

    /// <summary>
    /// 直播统一以"时移 N 秒"请求。
    /// 实测边界（`re/work` 里 160 号脚本）：Δ≤8s 服务端仍给直播 CDN（我们的 token 会被 CDN 403）；
    /// Δ=9s 起给 playback CDN（200 + 明文）。取 10 = 边界 + 1 秒余量。
    /// </summary>
    internal const long LiveShiftSec = 10;

    /// <summary>`iretcode=32`（票据时序不符）是间歇性的：跨秒重算 cKey 再试。</summary>
    const int MaxAttempts = 3;

    internal sealed record Result(string Url, string Defn, long PlaybackStart);

    static readonly HttpClient Http = new(new HttpClientHandler
    {
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
    })
    { Timeout = TimeSpan.FromSeconds(12) };

    /// <summary>最近一次失败原因（上层显示/排错用）。</summary>
    internal static string? LastError { get; private set; }

    /// <summary>最近一次服务端 iretcode（0 = 成功）。</summary>
    internal static int LastIretcode { get; private set; }

    /// <summary>
    /// 取流。
    /// </summary>
    /// <param name="cnlid">频道 cnlId（数字串）</param>
    /// <param name="livepid">频道 livepid</param>
    /// <param name="playbackTime">秒级时刻；**null = 直播**，非 null = 时移/回看</param>
    /// <param name="endTime">回看/时移的结束时刻；带上它服务端返回**整段 VOD 清单**（可连续播），
    ///   不带就只给 ~5 片滚动窗口（会周期性卡）。直播传 null。</param>
    /// <param name="log">日志回调</param>
    internal static async Task<Result?> ResolveAsync(
        string cnlid, string livepid, long? playbackTime, long? endTime,
        Action<string>? log = null, int attempt = 0)
    {
        LastError = null;
        LastIretcode = 0;
        long nowSec = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // ★ cKey 的 ts 与请求的 fntick 必须同一秒
        string? ck = PalmTVCore.GenCKeyAndroid(cnlid, nowSec, Guid);
        if (string.IsNullOrEmpty(ck))
        {
            LastError = "cKey 生成失败";
            log?.Invoke($"[android-live] cKey 生成失败（原生）：{PalmTVCore.LastSignError}");
            return null;
        }

        var q = new List<KeyValuePair<string, string>>
        {
            // ---- 固定参数（与安卓抓包逐字一致）----
            new("spacode", "23"), new("app_version", "305030"), new("spwm", "2"), new("hevclv", "26"),
            new("platform", Platform), new("sdtfrom", "v5028"), new("stream", "3"),
            new("sphttps", "0"), new("spdynamicrange", "1"), new("refer_pageId", "page_tv_500102"),
            new("wxopenid", ""), new("spdemuxer", "14"), new("spvcode", Spvcode), new("sphdrfps", "60"),
            new("qq", ""), new("defnsrc", "3"), new("estid", Estid),
            new("appVer", CkeyVer), new("defn", "auto"), new("encryptVer", "4.2"),
            new("spdrm", "2"), new("pageId", "page_tv_500102"), new("newnettype", "1"),
            new("spflvaudio", "1"), new("adjust", "1"), new("vip_status", "0"), new("spflv", "1"),
            new("uhd_flag", "4"), new("cmd", "2"), new("otype", "json"), new("caplv", "1"),
            // ---- 动态参数 ----
            new("cKey", ck),
            new("fntick", nowSec.ToString()),
            new("guid", Guid),
            new("cnlid", cnlid),
            new("livepid", livepid),
            new("randnum", Random.Shared.NextDouble().ToString("F16")),
            new("flowid", System.Guid.NewGuid().ToString("N") +
                          DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + "_" + Platform),
        };
        if (playbackTime.HasValue) q.Add(new("playbacktime", playbackTime.Value.ToString()));

        string url = Host + "?" + string.Join("&", q.ConvertAll(kv =>
            WebUtility.UrlEncode(kv.Key) + "=" + WebUtility.UrlEncode(kv.Value)));

        string text;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("User-Agent", Ua);
            req.Headers.TryAddWithoutValidation("UID", Guid);
            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            text = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            LastError = $"取流请求异常：{ex.GetType().Name}";
            log?.Invoke($"[android-live] 请求异常 {ex.GetType().Name}: {ex.Message}");
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            int code = root.TryGetProperty("iretcode", out var ce) && ce.TryGetInt32(out var cv) ? cv : -1;
            int detail = root.TryGetProperty("iretdetailcode", out var de) && de.TryGetInt32(out var dv) ? dv : 0;
            LastIretcode = code;

            // ⚠️ 响应是**扁平**的（没有 data 包裹）：「先根、后 data」双取以兼容两种形态。
            JsonElement data = root.TryGetProperty("data", out var de2) && de2.ValueKind == JsonValueKind.Object
                ? de2 : root;

            string playRaw = Str(data, "playurl");
            if (string.IsNullOrEmpty(playRaw)) playRaw = Str(root, "playurl");
            playRaw = playRaw.Replace("\\u0026", "&");

            string defn = Str(data, "defn");
            if (string.IsNullOrEmpty(defn)) defn = Str(root, "defn");

            long pbStart = 0;
            if (root.TryGetProperty("playback", out var pb) && pb.ValueKind == JsonValueKind.Object &&
                pb.TryGetProperty("playbackstart", out var ps) && ps.TryGetInt64(out var psv))
                pbStart = psv;

            if (code != 0 || string.IsNullOrEmpty(playRaw))
            {
                string errinfo = Str(root, "errinfo");
                LastError = string.IsNullOrEmpty(errinfo) ? $"取流失败（iretcode={code}）" : errinfo;
                log?.Invoke($"[android-live] 取流失败 iretcode={code} detail={detail} " +
                            $"cnlid={cnlid} pb={playbackTime} body={Trunc(text, 320)}");

                // 32（票据时序）与 12（版权，可能是瞬时）都跨秒重算一次；重试用尽如实报错
                if ((code == 32 || code == 12) && attempt + 1 < MaxAttempts)
                {
                    await Task.Delay(250).ConfigureAwait(false);
                    log?.Invoke($"[android-live] iretcode={code} ⇒ 第 {attempt + 2}/{MaxAttempts} 次尝试");
                    return await ResolveAsync(cnlid, livepid, playbackTime, endTime, log, attempt + 1)
                        .ConfigureAwait(false);
                }
                return null;
            }

            // ★ 回看/时移追加 endtime ⇒ 服务端给整段 VOD 清单（否则只有 ~5 片滚动窗口，会周期性卡）
            string play = playRaw;
            if (playbackTime.HasValue && endTime.HasValue &&
                endTime.Value > playbackTime.Value + 5 &&
                playRaw.IndexOf("endtime=", StringComparison.OrdinalIgnoreCase) < 0)
            {
                play = playRaw + (playRaw.Contains('?') ? "&" : "?") + "endtime=" + endTime.Value;
            }

            log?.Invoke($"[android-live] 取流 OK defn={defn} pb={playbackTime} start={pbStart} " +
                        $"url={Trunc(play, 110)}");
            return new Result(play, defn, pbStart);
        }
        catch (Exception ex)
        {
            LastError = $"响应解析失败：{ex.GetType().Name}";
            log?.Invoke($"[android-live] 解析失败 {ex.GetType().Name}: {ex.Message} body={Trunc(text, 240)}");
            return null;
        }
    }

    static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

    static string Trunc(string s, int n) => s.Length <= n ? s : s[..n];
}
