using System;
using System.Collections.Generic;

namespace PalmTVDesktop;

/// <summary>
/// 江苏荔枝（live.jstv.com）取流 —— **2026-11-05 起不再依赖 `proxy.exe`**。
///
/// 原来这条由 Go 代理做三件事：① 算 `txSecret`；② 带上游要求的 Referer/UA 拉清单；③ 把清单里的
/// 分片地址改写成 `/jstv-seg?u=`（再转发一遍）。现在：
///   · ① 由 <see cref="PalmTVCore.JstvSignQuery"/>（`jstv_sign.c`，与代理原来用的是同一把 KEY）；
///   · ②③ 交给 <see cref="LocalDecryptServer"/> —— 它本来就在做"拉上游清单 → 改写分片地址 →
///     逐片转发"，只是要按 host 换成江苏的 Referer（见那边的 `ApplyUpstreamHeaders`）。
///
/// 上游规则（与 `windows/proxy/main.go` 的 jstv 段逐条一致）：
/// ```
/// https://{host}{path}{streamId}.m3u8?txSecret=<md5>&txTime=<8位hex>
///   txTime   = 当前秒的低 32 位，小写十六进制、左补 0 到 8 位
///   txSecret = md5(KEY + streamId + txTime)，小写
/// ```
/// ⚠️ 上游 CDN 对 **HTTP/2** 返回 403、对 HTTP/1.1 正常（2026-11-05 实测）——
///   `LocalDecryptServer` 的 HttpClient 默认就是 h1（没开 h2），所以这里天然避开。
/// </summary>
internal static class JstvLive
{
    const string Host = "litchi-play-encrypted-site.jstv.com";

    /// <summary>streamId → 上游路径前缀（`/4klive/` 是 4K 直播，其余是 applive）。
    /// ⚠️ 增删台时三处必须同步：本表、`PlayerService.Channels` 的 `Src="jstv"` 那批、鸿蒙 `JiangsuTv.JSTV_CHANNELS`。</summary>
    internal static readonly Dictionary<string, string> PathByStream = new()
    {
        ["jsws4kpro"] = "/4klive/",
        ["jszypro"] = "/applive/",
        ["jsyspro"] = "/applive/",
        ["jscspro"] = "/applive/",
        ["jsxwpro"] = "/applive/",
        ["jsjypro"] = "/applive/",
        ["jsxxpro"] = "/applive/",
        ["jsgjpro"] = "/applive/",
        ["ymktpro"] = "/applive/",
    };

    internal static bool IsJstv(string streamId) =>
        !string.IsNullOrEmpty(streamId) && PathByStream.ContainsKey(streamId);

    /// <summary>
    /// 拼出带签名的上游 m3u8 地址。签名失败（原生库未加载/key 缺失）返回 null。
    /// </summary>
    internal static string? UpstreamUrl(string streamId)
    {
        if (!PathByStream.TryGetValue(streamId ?? "", out var path)) return null;
        var q = PalmTVCore.JstvSignQuery(streamId, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        if (string.IsNullOrEmpty(q)) return null;
        return $"https://{Host}{path}{streamId}.m3u8?{q}";
    }
}
