using System;
using System.IO;

// ⚠️ 本工程各文件均为**全局命名空间**（MainWindow / PalmTVCore 都不带 namespace）
//   ⇒ 这里不要写 namespace，否则 MainWindow 里 `LogoPack` 会 CS0103。
/// <summary>
/// 台标包读取端（发布版用）。
///
/// ★ 为什么要有它：发布包里 79 张台标 PNG 以明文散文件存在（`logos\real\*.png`），
///   既零碎又一眼可抄。改为打包成单个 `logos.dat`（由 publish.ps1 生成），
///   运行时首次需要台标时解到**用户缓存目录**，再交给原来的 `ChannelTile.LoadLogo(path)` ——
///   这样播放/瓷砖代码一行不用改（路径仍是路径）。
///
/// 容器格式（小端）：
///   magic  "PLOGO1\n"（7 字节）
///   u32    count
///   重复 count 次： u16 nameLen, name(**UTF-8**，不含 .png), u32 dataLen, data
///
/// ★ 缓存策略（2026-09-30 明确 + 提速 + 加清理）：
///   目录 = `%LOCALAPPDATA%\WinPalmTV\logo-cache\&lt;长度hex&gt;-&lt;内容哈希&gt;\real`；
///   文件级"已存在且长度一致 ⇒ 跳过"。
///   ⇒ **同一份 logos.dat 开多少次、甚至重新解压到别的目录，都只做检查、不重写**；
///      只有**包内容真的变了**（换版本/换了台标）才会新开一份并整包解一次。
///      旧口径是"长度+mtime"⇒ 每次重新解压 ZIP 都要整包重解 79 张（首启慢 + 招杀软扫描），已改。
///   旧指纹目录由 <see cref="PruneOtherCaches"/> 顺手删掉（每份约 780 KB，不清会一直堆）。
///
/// ★★ 2026-09-30 修（发布版**全部**台标变文字的重大 bug）★★
///   现象：发布包点开全是文字台标（调试版正常），缓存目录里只有 64 张（共 79 张）。
///   根因：打包端当初用 **ASCII** 编码文件名，中文台标名（`广州电视` 等 15 个）变成 `????`，
///         而 `?` 是 **Windows 非法文件名字符** ⇒ 下面 `File.WriteAllBytes` 抛异常
///         （Illegal characters in path）⇒ 外层 `catch` 把 `_cacheDir` 置 null ⇒ **整包台标一起失效**。
///   修法：① 打包端改 UTF-8（也修好了那 15 个中文台标 —— 它们本来是"按频道名兜底"要用的）；
///         ② 这里**逐条** try/catch + 文件名净化 ⇒ 单条坏数据只丢它自己，绝不连累整包；
///         ③ 只要容器头正常就把 `_cacheDir` 交出去（能解多少算多少）。
///
/// ⚠️ 除此之外的失败一律**静默退化**为"文字台标"（返回 null），绝不影响播放。
/// </summary>
internal static class LogoPack
{
    const string FileName = "logos.dat";
    const string Magic = "PLOGO1\n";
    /// <summary>单条数据的合理上限（防坏长度导致超大分配）；台标实际都是几十 KB。</summary>
    const int MaxEntryBytes = 8 * 1024 * 1024;

    static string? _cacheDir;
    static bool _tried;

    /// <summary>解包后的台标目录（`...\logo-cache\&lt;包指纹&gt;\real`）；无 logos.dat 或失败时为 null。</summary>
    internal static string? CacheDir { get { Ensure(); return _cacheDir; } }

    static void Ensure()
    {
        if (_tried) return;
        _tried = true;
        try
        {
            var dat = Path.Combine(AppContext.BaseDirectory, FileName);
            if (!File.Exists(dat)) return;      // 调试期：直接读散图，走原有路径

            // ★ 缓存指纹 = **长度 + 内容哈希**（★ 2026-09-30 从"长度+最后写入时间"改过来）。
            //   为什么必须改：**重新解压同一个 ZIP**（内容一模一样，只有 mtime 变了）在旧口径下也算"换包"
            //   ⇒ 首启要整包重解 79 张 PNG（还招一次杀软扫描）—— 用户实测"首次运行太慢"就是这个。
            //   现在只有**内容真的变了**才换目录；同一份包反复解压/装到多台机器都是直接命中缓存。
            //   （780 KB 哈希 ≈ 2 ms，比解包省得多。）
            var fi = new FileInfo(dat);
            var stamp = $"{fi.Length:x}-{Fingerprint(dat)}";
            var root = CacheRoot;
            var dir = Path.Combine(root, stamp, "real");

            using var fs = File.OpenRead(dat);
            using var br = new BinaryReader(fs);
            var magic = new string(br.ReadChars(Magic.Length));
            if (magic != Magic) return;         // 格式不符 ⇒ 放弃（退化为文字台标）

            int count = br.ReadInt32();
            if (count <= 0 || count > 4096) return;

            // ★ 容器头校验通过后才建目录 + 清理：坏包不会留下空目录
            Directory.CreateDirectory(dir);
            PruneOtherCaches(root, stamp);      // ★ 只留当前指纹那份（换包会新开一份，不清就一直堆）
            for (int i = 0; i < count; i++)
            {
                /* ★ 2026-09-30：**逐条**隔离 —— 任何一条坏数据（长度越界 / 文件名非法 / 磁盘写失败）
                   都只跳过它自己。原来整包共用一个 try ⇒ 第 65 条（第一个中文名）一抛，
                   前面已解出的 64 张也全部作废（_cacheDir 被置 null）。 */
                try
                {
                    int nameLen = br.ReadUInt16();
                    var name = System.Text.Encoding.UTF8.GetString(br.ReadBytes(nameLen));
                    name = SafeFileName(name);
                    int dataLen = br.ReadInt32();
                    if (dataLen <= 0 || dataLen > MaxEntryBytes) continue;
                    var data = br.ReadBytes(dataLen);
                    if (data.Length != dataLen) continue;          // 读到文件尾 ⇒ 这条不完整
                    var outp = Path.Combine(dir, name + ".png");
                    // 已存在且长度一致就跳过（同一指纹下重复启动不必重写）
                    if (File.Exists(outp) && new FileInfo(outp).Length == dataLen) continue;
                    File.WriteAllBytes(outp, data);
                }
                catch { /* 跳过这一条 */ }
            }
            _cacheDir = dir;                      // ★ 能解多少算多少（不再因一条失败丢掉全部）
        }
        catch { _cacheDir = null; }
    }

    /// <summary>把包里的名字净化成**合法文件名**：剔除 Windows 非法字符（`? * : " &lt; &gt; | \ /`）与控制符，
    /// 空则给个 "logo"。这一步是 2026-09-30 那次 bug 的兜底防线。</summary>
    static string SafeFileName(string name)
    {
        if (string.IsNullOrEmpty(name)) return "logo";
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new System.Text.StringBuilder(name.Length);
        foreach (var c in name)
        {
            if (c < ' ') continue;
            sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
        }
        var s = sb.ToString().Trim().TrimEnd('.');
        return s.Length == 0 ? "logo" : s;
    }

    /// <summary>包内容指纹 = SHA-256 前 8 字节（16 个 hex）。用于缓存目录名
    /// `&lt;长度hex&gt;-&lt;指纹&gt;`（两段都是 hex ⇒ 仍满足 <see cref="PruneOtherCaches"/> 的"是不是我们建的"判据）。
    /// 只用来**判断包变没变**，不是安全用途。</summary>
    static string Fingerprint(string path)
    {
        using var fs = File.OpenRead(path);
        using var sha = System.Security.Cryptography.SHA256.Create();
        var h = sha.ComputeHash(fs);
        var sb = new System.Text.StringBuilder(16);
        for (int i = 0; i < 8; i++) sb.Append(h[i].ToString("x2"));
        return sb.ToString();
    }

    /// <summary>缓存根：`%LOCALAPPDATA%\WinPalmTV\logo-cache`（每个指纹一个子目录，各含 `real\*.png`）。
    /// ⚠️ 按**用户**存放（与安装位置无关）⇒ 绿色包/安装包/换盘都不用重解；删掉也会自动重建。</summary>
    static string CacheRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "WinPalmTV", "logo-cache");

    /// <summary>★ 2026-09-30：删掉**其它指纹**的缓存目录，只留 <paramref name="keep"/> 这一份。
    ///   为什么：每换一次包（重新解压后 logos.dat 的 mtime 就变了）都会新开一份 ~780 KB 的缓存，
    ///   旧的不清就一直堆（用户实测问到"这些目录是每次生成的吗"）。
    ///   ⚠️ 只管**我们自己生成的**目录名（`&lt;长度hex&gt;-&lt;mtimehex&gt;`），别的名字一律不碰；
    ///      删除失败（被另一个实例的 WPF 占着 / 无权限）全部忽略 —— 顶多留到下次再删，绝不影响台标显示。</summary>
    static void PruneOtherCaches(string root, string keep)
    {
        try
        {
            foreach (var d in Directory.GetDirectories(root))
            {
                var n = Path.GetFileName(d);
                if (n == keep) continue;
                int dash = n.IndexOf('-');
                if (dash <= 0 || dash == n.Length - 1) continue;
                if (!IsHex(n, 0, dash) || !IsHex(n, dash + 1, n.Length - dash - 1)) continue;
                try { Directory.Delete(d, true); } catch { }
            }
        }
        catch { }
    }

    static bool IsHex(string s, int start, int len)
    {
        for (int i = start; i < start + len; i++)
            if (!char.IsAsciiHexDigit(s[i])) return false;
        return true;
    }
}
