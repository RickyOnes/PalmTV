using System;
using System.IO;

namespace PalmTVDesktop;

/// <summary>
/// "上次播放的台"本地存储 —— 启动时自动续播（没记录则 CCTV-1）。
///
/// 存的是**频道 Id**（如 `cctv1`）而不是名字：名字会随台标/措辞微调，Id 是稳定的主键
/// （`PlayerService.TvApiClient.Channels` 里每个台都有 `Id`）。
///
/// 路径：`%LOCALAPPDATA%\WinPalmTV\last-channel.txt`（与 `disclaimer.txt` 同目录）。
/// ★ 2026-11-06 新增：用户要求"打开 APP 直接播上次的台"。
/// </summary>
internal static class LastChannelStore
{
    internal const string DefaultChannelId = "cctv1";   // CCTV-1 综合

    static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinPalmTV");

    static string FilePath => Path.Combine(Dir, "last-channel.txt");

    /// <summary>读上次的频道 Id；没有/读失败返回 null（调用方回落到 <see cref="DefaultChannelId"/>）。</summary>
    internal static string? Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return null;
            var s = File.ReadAllText(FilePath).Trim();
            return string.IsNullOrEmpty(s) ? null : s;
        }
        catch { return null; }
    }

    /// <summary>记录频道 Id。写失败静默（不影响播放）。</summary>
    internal static void Save(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return;
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, id.Trim());
        }
        catch { }
    }
}
