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
    /// <summary>
    /// 取流来源：<c>"ysp"</c>（默认，走 auth/签名/get_live_info 链路）
    /// 或 <c>"jstv"</c>（地方台：江苏电视台/荔枝 TV，直连 + 现算签名，**流是明文**）。
    /// </summary>
    public string Src { get; init; } = "ysp";
    /// <summary>地方台的上游流 ID（仅 <see cref="Src"/> == "jstv" 时有值）</summary>
    public string StreamId { get; init; } = "";

    /// <summary>
    /// 频道分组（用于列表分区显示）：<c>cctv</c> / <c>satellite</c> / <c>local</c>。
    /// ★ 地方台由 <see cref="Src"/> 判定；其余按既有 id 前缀推断（与频道表的原有分组一致）。
    /// </summary>
    public string Group =>
        Src == "iptv" ? "local"      // ★ IPTV 地方台：**隐式分组** —— 复用"地方台"tab，但来源与 jstv 不同
        : Src == "jstv" ? "local"
        : (Id.StartsWith("cctv", StringComparison.Ordinal)
           || Id.StartsWith("cetv", StringComparison.Ordinal)
           || Id.StartsWith("cgne", StringComparison.Ordinal)) ? "cctv"
        : "satellite";

    public override string ToString() => Name;
}

/// <summary>
/// 频道网格里的一块"台标瓷砖"（UI 用，支持变更通知以驱动在播/选中高亮）。
/// </summary>
public class ChannelTile : System.ComponentModel.INotifyPropertyChanged
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";

    /// <summary>
    /// 无台标时圈内显示的**完整频道名**。
    /// ★★ 2026-10-02（用户："自定义频道在本地生成文本台标后，要显示全部频道名，而不是现在的一个"）★★
    ///   原来放的是 `ShortLabel`（空格前一段 / 首字）⇒ 圆圈里就一个字，看不出是哪个台；现在给全名，
    ///   字号按"圆内可用宽 ≈ 0.85×内径"反推（见 <see cref="FallbackFontSize"/>，与安卓/鸿蒙同一套数）。
    /// </summary>
    public string FallbackText { get; init; } = "";

    /// <summary>台标瓷砖的**内部圆直径**（外径 72 − 边框 2×2；改外径必须同步改这里，见 `MainWindow.xaml` 的注释）</summary>
    public const double RingInner = 68;

    /// <summary>最多显示几行：≤4 字一行，其余两行</summary>
    public int LineCount => FallbackText.Length <= 4 ? 1 : 2;

    /// <summary>每行字数（用来反推字号）</summary>
    int PerLine => FallbackText.Length <= 4 ? System.Math.Max(FallbackText.Length, 1)
                                           : (FallbackText.Length + 1) / 2;

    /// <summary>
    /// 无台标时圈内文字的字号：依据"圆内可用宽 ≈ 0.85×内径"反推。
    /// ⚠️ 与安卓 `ChannelTile`、鸿蒙 `tileFontSize` 是**同一套数**，改一处要三端一起改：
    ///   n ≤ 4 ⇒ 单行，字号 = min(0.85/n, 0.30) × 内径；
    ///   n ≥ 5 ⇒ 两行（每行 ⌈n/2⌉ 字），字号 = min(0.85/⌈n/2⌉, 0.22) × 内径。
    /// </summary>
    public double FallbackFontSize =>
        System.Math.Min(0.85 / PerLine, LineCount <= 1 ? 0.30 : 0.22) * RingInner;

    /// <summary>文字块最大高度 = 行数 × 行高（配合 <c>TextTrimming</c> 实现"最多两行、超出省略"）</summary>
    public double FallbackMaxHeight =>
        System.Math.Ceiling(FallbackFontSize * 1.35 * LineCount);
    /// <summary>台标图片：**预载并已 Freeze** 的 ImageSource；null = 没有图标 ⇒ UI 退化为文字瓷砖</summary>
    public System.Windows.Media.ImageSource? Logo { get; init; }
    public bool HasLogo => Logo != null;
    public TvChannel? Channel { get; init; }

    /// <summary>
    /// 台标加载缓存：`BitmapCacheOption.OnLoad` **一次性读入内存** + `Freeze()`（冻结后可跨元素/多次绑定复用，不持有文件句柄）。
    /// ★★ 不要退回 `Image.Source="{Binding 文件路径}"` 的写法 ★★ —— 那样由 WPF 的 ImageSourceConverter 走
    ///    **懒加载/全局影像缓存**，实测在**重建列表（切换 tab）后图片不再显示**（首屏正常、切一次就全空）。
    ///    显式预载 + Freeze 可彻底避开这条路径。
    /// </summary>
    static readonly Dictionary<string, System.Windows.Media.ImageSource?> _logoSrcCache = new();
    public static System.Windows.Media.ImageSource? LoadLogo(string absPath)
    {
        if (string.IsNullOrEmpty(absPath)) return null;
        if (_logoSrcCache.TryGetValue(absPath, out var hit)) return hit;
        System.Windows.Media.ImageSource? img = null;
        try
        {
            var bi = new System.Windows.Media.Imaging.BitmapImage();
            bi.BeginInit();
            bi.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;          // 立即解码，随即释放文件流
            bi.CreateOptions = System.Windows.Media.Imaging.BitmapCreateOptions.IgnoreImageCache; // 绕开 WPF 全局影像缓存
            bi.UriSource = new Uri(absPath, UriKind.Absolute);
            bi.EndInit();
            bi.Freeze();                                                                      // 冻结 = 可安全复用/跨线程
            img = TrimTransparentBorder(bi);                                                  // ★ 只裁「全透明」边（见下方规则）
        }
        catch { }
        _logoSrcCache[absPath] = img;
        return img;
    }

    /// <summary>
    /// 裁掉四周**全透明**的边，返回裁好的图（失败/无可裁则原样返回）。
    /// ★★ 规则只能裁「透明」（alpha&lt;16），**绝不能连"接近纯白"一起裁** ★★ —— 这是两次踩坑的分界：
    ///   · 只裁透明（当前）：央视/卫视台标的透明留白被裁掉 ⇒ **可见图案变大**（宽幅台标可达 +10~20%），
    ///     且不碰任何不透明像素 ⇒ 台名、图案一个像素都不丢。
    ///   · 连白边一起裁（曾用过，用户实测"整体感觉都很差了"）：九个地方台是 **144×100 的白底卡片，
    ///     台名就印在卡片底部**；把白边裁掉等于把图案按比例放大 ⇒ 台名被推到图片下缘，
    ///     而圆的底部可用宽度只有 ~57% ⇒ 台名两端被圆边切掉。
    ///   ⇒ 结论：**透明留白可以裁，白色留白不能裁**。只裁不缩，绝不变形。
    /// </summary>
    static System.Windows.Media.ImageSource TrimTransparentBorder(System.Windows.Media.Imaging.BitmapSource src)
    {
        int w = src.PixelWidth, h = src.PixelHeight;
        if (w < 8 || h < 8) return src;
        System.Windows.Media.Imaging.BitmapSource bgra = src.Format == System.Windows.Media.PixelFormats.Bgra32
            ? src
            : new System.Windows.Media.Imaging.FormatConvertedBitmap(src, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        int stride = w * 4;
        var buf = new byte[(long)stride * h];
        bgra.CopyPixels(buf, stride, 0);

        // 空白 = 全透明 或 接近纯白（白底卡片的白边）；直接扫一遍求包围盒（144×100 量级，开销可忽略）
        int x0 = w, x1 = -1, y0 = h, y1 = -1;
        for (int y = 0; y < h; y++)
        {
            int baseIdx = y * stride;
            for (int x = 0; x < w; x++)
            {
                int i = baseIdx + x * 4;
                byte a = buf[i + 3];
                if (a < 16) continue;                     // ★ 只有"全透明"才算可裁的空白（白色留白必须保留）
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
            }
        }
        if (x1 < x0 || y1 < y0) return src;                       // 整张都是空白 ⇒ 不裁
        // 留 1px 余量，避免紧贴边缘
        x0 = Math.Max(0, x0 - 1); y0 = Math.Max(0, y0 - 1);
        x1 = Math.Min(w - 1, x1 + 1); y1 = Math.Min(h - 1, y1 + 1);
        int nw = x1 - x0 + 1, nh = y1 - y0 + 1;
        if (nw >= w && nh >= h) return src;                        // 没有可裁的边
        var cropped = new System.Windows.Media.Imaging.CroppedBitmap(bgra,
            new System.Windows.Int32Rect(x0, y0, nw, nh));
        cropped.Freeze();
        return cropped;
    }

    bool _isPlaying;
    bool _isSelected;
    /// <summary>在播（红外圈 + 红字加粗）</summary>
    public bool IsPlaying
    {
        get => _isPlaying;
        set { if (_isPlaying != value) { _isPlaying = value; Raise(nameof(IsPlaying)); } }
    }
    /// <summary>当前选中（青圈）</summary>
    public bool IsSelected
    {
        get => _isSelected;
        set { if (_isSelected != value) { _isSelected = value; Raise(nameof(IsSelected)); } }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    void Raise(string n) => PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(n));
    public override string ToString() => Name;
}

public class TvApiClient
{
    // ★ 2026-11-05：`_http` 已删除（Web/PC 取流链路整体移除）
    public const string Ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";

    // ★ 本地 Go 代理 (Chrome TLS 指纹), C# → localhost:18888 → player-api.yangshipin.cn
    public string ProxyBaseUrl { get; set; } = "http://127.0.0.1:18888";
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
        // ===== 地方台（地方频道组）=====
        // ★ 2026-09-20：与鸿蒙版 `harmony/.../common/JiangsuTv.ets` + `ChannelList.ets` 的 local 组**同名同序**。
        //   这几路**不走央视频**：没有 pid/cnlId，也不需要 auth/签名/get_live_info ——
        //   上游地址只靠一次 `txSecret`（md5，签名在代理侧 `proxy/main.go`，现算），且**上游 TS 是明文的**。
        //   取流走本地代理：`http://127.0.0.1:18888/jstv.m3u8?ch=<streamId>`（代理带 Referer/UA 转发分片）。
        //   ⚠️ 增删台时三处必须同步：本表、`proxy/main.go` 的 jstvPath、鸿蒙 `JiangsuTv.JSTV_CHANNELS`。
        new() { Id="jsws4kpro",Name="江苏卫视4K",Src="jstv",StreamId="jsws4kpro"},
        new() { Id="jszypro",  Name="江苏综艺",  Src="jstv",StreamId="jszypro"},
        new() { Id="jsyspro",  Name="江苏影视",  Src="jstv",StreamId="jsyspro"},
        new() { Id="jscspro",  Name="江苏城市",  Src="jstv",StreamId="jscspro"},
        new() { Id="jsxwpro",  Name="江苏新闻",  Src="jstv",StreamId="jsxwpro"},
        new() { Id="jsjypro",  Name="江苏教育",  Src="jstv",StreamId="jsjypro"},
        new() { Id="jsxxpro",  Name="江苏休闲",  Src="jstv",StreamId="jsxxpro"},
        new() { Id="jsgjpro",  Name="江苏国际",  Src="jstv",StreamId="jsgjpro"},
        new() { Id="ymktpro",  Name="优漫卡通",  Src="jstv",StreamId="ymktpro"},
    };

    public class ApiException : Exception
    {
        public int StatusCode { get; }
        public ApiException(int code, string msg) : base(msg) { StatusCode = code; }
    }

}