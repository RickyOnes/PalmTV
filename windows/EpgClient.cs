using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace PalmTVDesktop;

/// <summary>
/// 一条节目单记录。字段与安卓 `Epg.Item` 对齐（`Android/.../data/Epg.kt`）。
/// ★ 2026-11-06：从 `MainWindow` 的嵌套类型提为顶层类型，供 <see cref="EpgClient"/> 构造。
/// </summary>
internal record EpgProgram
{
    public string StartTime { get; init; } = "";
    public string EndTime { get; init; } = "";
    public string Title { get; init; } = "";
    /// <summary>官方 program_id（8 位数字），回看时作为 `program_id` 参数。</summary>
    public string Id { get; init; } = "";
    /// <summary>节目开始/结束的 **epoch 秒**（回看/时移的 playbacktime 就取它）。</summary>
    public long StartEpoch { get; init; }
    public long EndEpoch { get; init; }
    /// <summary>官方"可回看"标志（protobuf 字段 10）：只有明确为不可回看时才是 false。</summary>
    public bool Replayable { get; init; } = true;
    public string Day { get; init; } = "";
    /// <summary>
    /// 是否已经播完（可回看）——终端用户视角。
    /// ★ 2026-11-06：**不能只看 <see cref="EndEpoch"/>**。8K 等频道的 protobuf 里只带
    ///   `HH:mm` 字符串（字段 5/6）、不带 epoch（字段 3/4）⇒ `EndEpoch == 0` ⇒ 原来直接返回 false
    ///   ⇒ 全部条目被当成"尚未播出"（全灰），用户看不到"正在播/已播完"的区别。
    ///   这里加 `HH:mm` 兜底，与 <see cref="IsCurrent"/> 同一套跨零点归一化。
    /// </summary>
    /// <summary>这条记录是不是"今天"的节目单（<see cref="Day"/> 是拉取时请求的 `yyyyMMdd`）。</summary>
    public bool IsToday
    {
        get
        {
            if (string.IsNullOrEmpty(Day)) return true;                 // 老数据没带日期 ⇒ 按今天处理
            return Day == DateTime.Now.ToString("yyyyMMdd");
        }
    }

    public bool IsPast
    {
        get
        {
            if (EndEpoch > 0) return DateTimeOffset.UtcNow.ToUnixTimeSeconds() >= EndEpoch;
            /* ★★ 2026-11-06（用户报"每天的同一时段都显示红粗字"的同源问题）★★
             *   纯 `HH:mm` 的数据没有绝对时间 ⇒ **必须先用日期判**：
             *     过去的日期 ⇒ 必然已播完；未来的日期 ⇒ 必然没播过。 */
            if (!IsToday) return Day.CompareTo(DateTime.Now.ToString("yyyyMMdd")) < 0;
            if (EndMinutes <= 0) return false;              // 时间缺失 ⇒ 不判定
            var now = DateTime.Now;
            int n = now.Hour * 60 + now.Minute;
            int s = StartMinutes, e = EndMinutes;
            if (e < s) e += 24 * 60;                        // 跨零点
            if (n < s && e >= 24 * 60) n += 24 * 60;        // 凌晨时段归一化
            return n >= e;
        }
    }
    public string Display => string.IsNullOrEmpty(StartTime) ? Title : $"{StartTime}-{EndTime}  {Title}";
    public int StartMinutes => ParseMin(StartTime);
    public int EndMinutes => ParseMin(EndTime);
    public bool IsCurrent
    {
        get
        {
            /* ★★ 2026-11-06（用户："每天的同一时段都显示红粗字？这不正常呢"）★★
             *   原来只比 `HH:mm` —— 任何一天里"当前钟点落在 [开始,结束)"的那一档都会被判为"正在播出"
             *   ⇒ 打开**11-05** 的节目单，今天 10:31~11:11 的节目也被标红加粗。
             *   有 epoch 时直接用绝对时间（天然带日期）；只有纯 `HH:mm` 的老数据才退回钟点比较，
             *   **且必须限定"今天"**。 */
            if (StartEpoch > 0 && EndEpoch > StartEpoch)
            {
                long nowSec = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                return nowSec >= StartEpoch && nowSec < EndEpoch;
            }
            if (!IsToday) return false;          // 历史/未来日期 ⇒ 不可能"正在播出"
            var now = DateTime.Now;
            int n = now.Hour * 60 + now.Minute;
            int s = StartMinutes, e = EndMinutes;
            /* ★★ 2026-11-06 修（用户报 CCTV-4K/8K 节目单里多条同时标红）★★
             *   4K/8K 的节目单里有大量**零长度占位节目**（"4K宣传片""4K节目预告"等，
             *   形如 `08:56-08:56`）。原来写成 `if (e <= s) e += 24*60`，
             *   `e == s` 也被当成"跨凌晨"⇒ 时长变 24 小时 ⇒ 该条目**恒为正在播** ⇒ 一片红。
             *   现在：只有 `e < s`（真的跨零点）才 +24h；`e == s` 是零长度，永远不算正在播。 */
            if (e < s) e += 24 * 60;
            else if (e == s) return false;
            if (n < s && e >= 24 * 60) n += 24 * 60;  // 凌晨时段归一化
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

/// <summary>
/// 央视频节目单（EPG）客户端 —— **直连 capi，protobuf 解码**。
///
/// 与安卓 `Android/app/src/main/java/com/rickyone/palmtv/data/Epg.kt` 逐字段对齐：
/// ```
/// GET https://capi.yangshipin.cn/api/yspepg/program/{pid}/{yyyyMMdd}
/// headers: 应用标识头 + Accept: */*、UA
/// 响应：application/octet-stream（**protobuf，不是 JSON**）
/// ```
///
/// ★★ 2026-11-06：原来这里是打 `127.0.0.1:18888/capi/...`，靠 Go 代理把 protobuf 转 JSON。
///   proxy 移除后该请求永远失败 ⇒ 节目单/现在播/接下来**全部为空**（用户报的"节目单不显示"）。
///   现在改成直连 + 本地手写 varint 解码（不引第三方 protobuf 库，和安卓一样只解需要的字段）。
///
/// protobuf 结构（实测，与 `Epg.kt` 注释一致）：
/// ```
/// 顶层 repeated 字段 2 = 节目 message
///   1  string  program_id（8 位数字，回看时当 program_id 用）
///   2  string  title
///   3  varint  start（epoch 秒）
///   4  varint  end  （epoch 秒）
///   5  string  "HH:mm"（start 兜底）
///   6  string  "HH:mm"（end 兜底）
///   10 string  replayFlag："1" 可回看 / "2" 不可（版权）
/// ```
/// </summary>
internal static class EpgClient
{
    const string Host = "https://capi.yangshipin.cn";
    const string AppId = "YOUR_APP_ID";
    const string Ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";

    static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AutomaticDecompression = System.Net.DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(8),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    { Timeout = TimeSpan.FromSeconds(8) };

    /// <summary>拉某天（默认今天）的节目单；失败返回空列表（调用方沿用缓存）。</summary>
    internal static async Task<List<EpgProgram>> FetchAsync(string pid, DateTime? day = null)
    {
        var list = new List<EpgProgram>();
        if (string.IsNullOrEmpty(pid)) return list;
        try
        {
            var ymd = (day ?? DateTime.Now).ToString("yyyyMMdd");
            using var req = new HttpRequestMessage(
                HttpMethod.Get, $"{Host}/api/yspepg/program/{pid}/{ymd}");
            req.Headers.TryAddWithoutValidation("User-Agent", Ua);
            req.Headers.TryAddWithoutValidation("yspappid", AppId);
            req.Headers.TryAddWithoutValidation("Accept", "*/*");
            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return list;
            var bytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            return Decode(bytes, ymd);
        }
        catch { return list; }
    }

    // ------------------------------------------------------------------
    // protobuf 手写解码（只解需要的字段；遇到未知字段跳过而不是整条丢弃）
    // ------------------------------------------------------------------

    static List<EpgProgram> Decode(byte[] data, string ymd)
    {
        var outList = new List<EpgProgram>();
        int off = 0;
        while (off < data.Length)
        {
            var (tag, tn) = ReadVarint(data, off);
            if (tn == 0) break;
            off += tn;
            int fnum = (int)(tag >> 3);
            int wire = (int)(tag & 0x7);
            if (wire == 0)
            {
                var (_, n) = ReadVarint(data, off);
                off += n;
            }
            else if (wire == 2)
            {
                var (lenL, ln) = ReadVarint(data, off);
                off += ln;
                int len = (int)lenL;
                if (len < 0 || off + len > data.Length) break;
                if (fnum == 2)
                {
                    var item = ParseProgram(data, off, len, ymd);
                    if (item != null) outList.Add(item);
                }
                off += len;
            }
            else break;
        }
        return outList;
    }

    static EpgProgram? ParseProgram(byte[] b, int baseOff, int len, string ymd)
    {
        string id = "", title = "", startHm = "", endHm = "", replayFlag = "";
        long startSec = 0, endSec = 0;
        int off = baseOff, end = baseOff + len;
        while (off < end)
        {
            var (tag, tn) = ReadVarint(b, off);
            if (tn == 0) break;
            off += tn;
            int fnum = (int)(tag >> 3);
            int wire = (int)(tag & 0x7);
            if (wire == 0)
            {
                var (v, n) = ReadVarint(b, off);
                off += n;
                if (fnum == 3) startSec = (long)v;
                else if (fnum == 4) endSec = (long)v;
            }
            else if (wire == 2)
            {
                var (lenL, ln) = ReadVarint(b, off);
                off += ln;
                int slen = (int)lenL;
                if (slen < 0 || off + slen > end) break;
                var s = Encoding.UTF8.GetString(b, off, slen);
                off += slen;
                switch (fnum)
                {
                    case 1: id = s; break;
                    case 2: title = s; break;
                    case 5: startHm = s; break;
                    case 6: endHm = s; break;
                    case 10: replayFlag = s; break;   // ★ 官方"可回看"标志
                }
            }
            else if (wire == 1) off += 8;   // 未知字段：跳过
            else if (wire == 5) off += 4;
            else break;
        }
        if (string.IsNullOrEmpty(title)) return null;
        // 缺字段按"允许回看"处理（老数据兼容）；只有明确 "2" 才禁用
        return new EpgProgram
        {
            Id = id,
            Title = title,
            StartEpoch = startSec,
            EndEpoch = endSec,
            StartTime = startSec > 0 ? Hhmm(startSec) : startHm,
            EndTime = endSec > 0 ? Hhmm(endSec) : endHm,
            Replayable = replayFlag != "2",
            Day = ymd,
        };
    }

    static string Hhmm(long epochSec) =>
        DateTimeOffset.FromUnixTimeSeconds(epochSec).ToLocalTime().ToString("HH:mm");

    static (ulong value, int len) ReadVarint(byte[] d, int off)
    {
        ulong result = 0;
        int shift = 0, n = 0;
        while (off + n < d.Length)
        {
            byte b = d[off + n];
            n++;
            result |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return (result, n);
            shift += 7;
            if (shift > 63) break;
        }
        return (0, 0);
    }
}
