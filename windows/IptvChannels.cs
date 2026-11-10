using PalmTVDesktop;
using System;
using System.Collections.Generic;
using System.IO;

/// <summary>
/// IPTV 地方台清单（**两处来源**，合并顺序 = 内置在前、用户新增追加到最后）：
///
///   ① **用户自定义** —— `%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`
///      （关于页「添加 / 编辑自定义源…」写这里；也可用记事本直接改）
///   ② **内置清单**   —— 本文件的 <see cref="BuiltIn"/> 表（15 条）
///
/// ★★ 2026-09-30：内置清单**从外置 m3u 文件移进代码**（用户要求"同步鸿蒙逻辑"）★★
///   · 鸿蒙那边一直是内置在 `ChannelList.ets` 的 `Channels[]` 里，而桌面要随包带一个 `iptv-local.m3u`
///     ⇒ 现在两端都是"代码即清单"：包内少一个文件，两端逻辑一致（`common\channels\iptv-local.m3u` 已删）。
///   · ⚠️ **改一处必须改另一处**：`IptvChannels.BuiltIn`（C#）⇄ `ChannelList.ets` 里 `src:'iptv'` 那组，
///     **内容与顺序都要一致**（顺序决定 id，台标按 id 挂，错位就串台）。
///   · `id` 由**位置**决定（`iptv-0` … `iptv-14`），与鸿蒙 `iptv-N` 一一对应 ⇒ 两端高亮/记忆/台标口径一致。
///
/// ★ 为什么用户条目不放 exe 同目录：装到 Program Files 时那里**没有写权限**；
///   放 %LOCALAPPDATA% 既能保存、升级/重装也不丢，且不污染安装目录。
/// ★ **用户新增的源排在所有内置地方台之后**（用户实测要求：原来插在江苏台后面，看着像把内置台挤散了）；
///   同 URL 时**内置胜出**（重复添加内置源会被忽略）。分组由 `TvChannel.Group` 依 `Src` 推导 ⇒ Src="iptv" → 地方台。
/// ★ 这些源是**明文 HLS 直链**（无 CMG 加密、无需签名）⇒ 播放时 VLC 直接吃，
///   既不经过解密代理(18899)，也不经过 Go 代理的签名链路。
///
/// 失败一律静默（返回空列表），绝不影响其它频道。
/// </summary>
internal static class IptvChannels
{
    const string FileName = "iptv-local.m3u";

    /// <summary>用户自定义清单路径（可写；关于页编辑的就是它）。</summary>
    internal static string UserPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinPalmTV", FileName);

    /// <summary>
    /// ★★ 内置地方台（2026-09-30 从 `common\channels\iptv-local.m3u` 移进来）★★
    ///   · 与鸿蒙 `ChannelList.ets` 的 `src:'iptv'` 组**逐条、按序**对齐（那边是权威源：用户维护在那里）。
    ///   · `id` = `iptv-` + 下标（本表顺序）⇒ 与鸿蒙 `iptv-0` … `iptv-14` 相同。
    ///   · ⚠️ **不要为了"整齐"重排顺序** —— id 会整体错位（台标/高亮串台）。
    ///   · 名称不含清晰度后缀（原 m3u 的 `(720p)` 在迁入时已去掉，与鸿蒙口径一致）。
    /// </summary>
    static readonly (string name, string url)[] BuiltIn =
    {
        ("广州电视",   "https://tencentplaybusiness.gztv.com/live/zonghes.m3u8"),
        ("广州新闻",   "https://tencentplay.gztv.com/live/nanguodushi.m3u8?txSecret=550af55c0ea34ce492748481415b6dfa&txTime=1903e7b17de"),
        ("哈尔滨电影", "https://stream.hrbtv.net/yspd/playlist.m3u8"),
        ("哈尔滨综合", "https://stream.hrbtv.net/xwzh/playlist.m3u8?_upt=ef41dd531755913594"),
        ("吉林都市",   "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/7e8474e6daea44ccaa5aa2300191439e/index.m3u8"),
        ("吉林乡村",   "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/3ffc4824dce54b92be185555923ce382/index.m3u8"),
        ("吉林生活",   "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/0a76740c72b74fabae611845aa21e06a/index.m3u8"),
        ("吉林影视",   "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/906341e6f19b4c4bacdc89941eb85d12/index.m3u8"),
        ("农林卫视",   "http://124.116.183.146:9901/tsfile/live/1004_1.m3u8"),
        ("山东教育",   "https://test1.live.sdetv.com.cn/live/dianshizhibo/playlist.m3u8"),
        ("四平综合",   "http://stream2.jlntv.cn/sptv/sd/live.m3u8?_upt=f27750421743154598"),
        ("通化新闻",   "http://lsfb.avap.jilintv.cn/zqvk7vpj/channel/43ea5771aa44421591f9dfd2b71f1b9b/index.m3u8"),
        ("赤峰综合",   "http://play1-qk.nmtv.cn/live/1735546697341033.m3u8"),
        ("香港卫视",   "https://hkstv.tv/api/m3u8-proxy?url=http%3A%2F%2Fwebcast.hkstv.tv%2Flivestream%2Fmutfysrq%2Fplaylist.m3u8"),
        ("金鹰卡通",   "http://59.39.89.130:60901/tsfile/live/0125_25.m3u8?key=txiptv&playlive=1&authid=0"),
    };

    /// <summary>最近一次载入的**总数**（供启动日志/关于页）。</summary>
    internal static int LastCount { get; private set; }

    /// <summary>最近一次载入中来自**用户自定义**文件的条数。</summary>
    internal static int LastUserCount { get; private set; }

    /// <summary>合并载入（**内置在前 + 用户新增追加到最后**，按 URL 去重）。</summary>
    internal static List<TvChannel> Load()
    {
        var list = new List<TvChannel>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ① 内置 15 台在前。
        //    ★★ 2026-09-30（用户要求）：**用户新增的源排到最后** —— 原来用户条目在最前，
        //       于是"关于页加的那两个源"会插在江苏台与内置地方台之间，看着像把内置台挤散了。
        //       现在顺序 = 江苏台(jstv，另一处并入) → 内置 IPTV 15 台 → 用户新增。
        //    ★ id = `iptv-<下标>`（与鸿蒙 `iptv-N` 对齐；用户条目也顶不掉它 ⇒ 台标不会串）。
        for (int i = 0; i < BuiltIn.Length; i++)
        {
            var (name, url) = BuiltIn[i];
            if (seen.Add(url)) list.Add(Make("iptv-" + i, name, url));
        }

        // ② 用户自定义**追加到最后**（同 URL 时以**内置**为准：重复添加内置源没有意义，直接忽略）。
        //    ★ id 用 `iptv-u<序号>` 独立命名空间（与内置不冲突）。
        int ui = 0;
        foreach (var e in LoadFile(UserPath))
        {
            if (seen.Add(e.url)) list.Add(Make("iptv-u" + ui++, e.name, e.url));
        }
        LastUserCount = ui;

        LastCount = list.Count;
        return list;
    }

    /// <summary>只读**用户自定义**条目（给编辑对话框用）。</summary>
    internal static List<(string name, string url)> LoadUser() => LoadFile(UserPath);

    /// <summary>
    /// 覆盖写入用户自定义清单（`entries` 为空 ⇒ 删除该文件）。
    /// 先写临时文件再替换 ⇒ 中途失败也不会留下半截清单（下次启动会读到坏文件）。
    /// </summary>
    internal static bool SaveUser(List<(string name, string url)> entries)
    {
        try
        {
            if (entries.Count == 0)
            {
                if (File.Exists(UserPath)) File.Delete(UserPath);
                return true;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(UserPath)!);
            var tmp = UserPath + ".tmp";
            var lines = new List<string>
            {
                "#EXTM3U",
                "# PalmTV 自定义 IPTV 源（由「关于 → 添加 / 编辑自定义源…」维护；也可用记事本直接改）",
                "# 格式：#EXTINF:-1,频道名  换行  http://.../xxx.m3u8",
                "# ⚠️ 内置的 15 个地方台**不在本文件里**（已内置在程序代码中），这里只放你自己加的源。",
            };
            foreach (var (name, url) in entries)
            {
                lines.Add($"#EXTINF:-1,{name}");
                lines.Add(url);
            }
            File.WriteAllLines(tmp, lines, new System.Text.UTF8Encoding(false));
            File.Move(tmp, UserPath, overwrite: true);
            return true;
        }
        catch { return false; }
    }

    static TvChannel Make(string id, string name, string url) => new()
    {
        Id = id,                  // 内置 = `iptv-<下标>`（与鸿蒙一致）；用户 = `iptv-u<序号>`
        Name = name,
        Src = "iptv",             // ★ 决定分组(→local) 与播放分派
        StreamId = url,           // ★ 原始直链 URL 存在 StreamId
    };

    /// <summary>读取并解析一个 m3u **文件**（不存在 / 读失败 ⇒ 空列表）。</summary>
    static List<(string name, string url)> LoadFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return new List<(string name, string url)>();
            return ParseLines(File.ReadAllLines(path));
        }
        catch { /* 静默：载入失败不影响其它频道 */ }
        return new List<(string name, string url)>();
    }

    /// <summary>
    /// ★★ 2026-10-02（用户要求"从 m3u 文本导入功能桌面端也请增加"）★★
    /// 解析**粘贴进来的 m3u 文本**（编辑窗「从 m3u 文本导入」）。
    ///
    /// 与**文件**解析共用同一段 [ParseLines] ⇒ 规则永远一致；也与移动端
    /// （安卓 `IptvSources.parseM3u` / 鸿蒙 `IptvSources.parseM3u`）**逐条一致**：
    ///   `#EXTINF:-1,频道名` + 下一行地址；其它 `#` 指令忽略；没有配对 EXTINF 的裸 URL 跳过；
    ///   名称去掉尾部清晰度后缀 ` (720p)`；空名兜底 "IPTV"。
    /// ⚠️ 只解析、**不做去重**（去重是调用方的事：内置优先 + 列表内互斥，与 `Load()` 同口径）。
    /// </summary>
    internal static List<(string name, string url)> ParseM3uText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return new List<(string name, string url)>();
        // 统一换行后再切行：从网页/记事本拷出来的多半是 CRLF，也有纯 CR 的老文件
        return ParseLines(text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'));
    }

    /// <summary>解析 m3u 行序列（**文件与粘贴文本共用这一段**，保证两处规则永不跑偏）。</summary>
    static List<(string name, string url)> ParseLines(IEnumerable<string> lines)
    {
        var list = new List<(string name, string url)>();
        string? pendingName = null;
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("#EXTM3U", StringComparison.OrdinalIgnoreCase)) continue;

            // #EXTINF:-1,名称   /  #EXTINF:0,名称   —— 取**第一个逗号**之后的部分，兼容两种时长写法
            if (line.StartsWith("#EXTINF", StringComparison.OrdinalIgnoreCase))
            {
                var i = line.IndexOf(',');
                pendingName = i >= 0 ? line[(i + 1)..].Trim() : "";
                continue;
            }
            if (line.StartsWith("#")) continue;      // 其它指令（#EXTVLCOPT 等）忽略
            if (pendingName == null) continue;       // 没有配对 EXTINF 的裸 URL 跳过

            // 去掉名称尾部的清晰度后缀，如 "广州电视 (720p)" → "广州电视"
            var name = System.Text.RegularExpressions.Regex
                .Replace(pendingName, @"\s*\((?:\d{3,4}p)\)\s*$", "").Trim();
            if (name.Length == 0) name = "IPTV";

            list.Add((name, line));
            pendingName = null;
        }
        return list;
    }
}
