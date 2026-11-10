using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace PalmTVDesktop;

/// <summary>
/// 全屏居中节目单弹层（对齐安卓 `EpgSheet`）。
///
/// · 日期范围：**前 6 天 + 今天 + 后 3 天**（共 10 天），与鸿蒙/安卓一致；
/// · 条目状态：`▶` 正在播出（红）/ `↺` 可回看（正常色）/ `·` 不可回看（灰）/ `◷` 未播出（灰）；
/// · 点击可回看条目 ⇒ 触发 <see cref="ReplayRequested"/>，由主窗口起播 VOD。
/// </summary>
public partial class EpgOverlayWindow : Window
{
    readonly TvChannel _ch;
    /// <summary>
    /// ★ 2026-11-06（用户要求：与安卓同款）：主窗口**当前正在回看**的那一档（null = 直播中）。
    /// 用途：这一行标"红粗 + 回看中"，并且当列表里存在"回看中"时，
    /// 正在直播那档退为**绿色「直播中」**（不再抢红粗，对齐安卓 `EpgModal` 的 `liveSecondary`）。
    /// </summary>
    readonly EpgProgram? _replayProg;
    DateTime _day = DateTime.Today;
    /// <summary>"正在播出"那一行（打开时滚动定位到它，居中显示）。</summary>
    Border? _curRow;
    /// <summary>★ 2026-11-06："正在回看"那一行 —— 定位优先级高于"正在播出"。</summary>
    Border? _replayRow;

    /// <summary>用户点了某条可回看节目（主窗口负责起播 + 关闭本窗口）。</summary>
    internal event Action<EpgProgram, TvChannel>? ReplayRequested;

    // ⚠️ 必须是 internal：参数 `EpgProgram` 是 internal 类型（public 构造器会报 CS0051 可访问性不一致）。
    //    本窗口只在 `MainWindow.ShowEpgOverlay()` 里用代码创建，不靠 XAML 实例化 ⇒ internal 完全够用。
    internal EpgOverlayWindow(TvChannel ch, EpgProgram? replayProg = null)
    {
        InitializeComponent();
        _ch = ch;
        _replayProg = replayProg;
        TitleText.Text = $"{ch.Name} · 节目单";

        /* ★★ 2026-11-06（用户要求：跨天回看时要自动定位到那一天）★★
         *   原来 `_day` 恒为**今天** ⇒ 正在回看昨天的节目，打开弹层看到的却是今天的节目单，
         *   「回看中」那一行根本不在列表里。⇒ 有回看时，日期默认跟着**回看节目所属的那一天**走。
         *   ⚠️ 只接受日期条范围内的（-6 ~ +3 天，2026-11-10 与鸿蒙/安卓对齐为"前 6 后 3"），
         *      越界就留在今天，避免"打开了却没这一天"。 */
        if (replayProg != null && !string.IsNullOrEmpty(replayProg.Day)
            && DateTime.TryParseExact(replayProg.Day, "yyyyMMdd", null,
                   System.Globalization.DateTimeStyles.None, out var rday))
        {
            var d = rday.Date;
            if (d >= DateTime.Today.AddDays(-6) && d <= DateTime.Today.AddDays(3)) _day = d;
        }

        BuildDayBar();

        Loaded += async (_, _) =>
        {
            /* ★ 2026-11-06：用户反馈"节目单弹窗这么大？"⇒ 不再铺满主窗口。
             *   改为**居中、最大 980×720、且不超过主窗口 85%**（与安卓居中弹层同观感）。 */
            if (Owner != null)
            {
                // ★ 2026-11-06：再缩小 35%（用户要求"变窄点"）——980 → 640 宽
                double w = Math.Min(640, Owner.ActualWidth * 0.55);
                double h = Math.Min(560, Owner.ActualHeight * 0.8);
                Width = w; Height = h;
                Left = Owner.Left + (Owner.ActualWidth - w) / 2;
                Top = Owner.Top + (Owner.ActualHeight - h) / 2;
            }
            await LoadDayAsync();
        };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        // 点空白处关闭（点在 Border 内部时不关）
        MouseLeftButtonUp += (_, e) => { if (ReferenceEquals(e.OriginalSource, this)) Close(); };
        // 关窗时停掉"悬停连续滚动"的定时器，避免它继续跑
        Closed += (_, _) => StopHoverScroll();
    }

    /// <summary>
    /// ★ 2026-11-10（用户要求，三端统一）：**"正在看的那天"**（`yyyyMMdd`）——
    /// 回看 ⇒ 正在回看那档所属的日期；直播/时移 ⇒ 今天。该 TAB 始终红粗。
    /// </summary>
    string WatchDayYmd()
    {
        if (_replayProg == null) return DateTime.Today.ToString("yyyyMMdd");
        if (!string.IsNullOrEmpty(_replayProg.Day)) return _replayProg.Day;
        if (_replayProg.StartEpoch > 0)
            return DateTimeOffset.FromUnixTimeSeconds(_replayProg.StartEpoch).LocalDateTime.ToString("yyyyMMdd");
        return DateTime.Today.ToString("yyyyMMdd");
    }

    void BuildDayBar()
    {
        DayBar.Children.Clear();
        Button? activeBtn = null;
        string watchDay = WatchDayYmd();
        for (int d = -6; d <= 3; d++)   // ★ 与鸿蒙/安卓统一：前 6 天 + 今天 + 后 3 天 = 10 天
        {
            var day = DateTime.Today.AddDays(d);
            bool active = day.Date == _day.Date;
            string ymd = day.ToString("yyyyMMdd");
            bool isWatch = ymd == watchDay;
            /* ★ 2026-11-10（用户要求，三端统一）：TAB 配色优先级
             *   ① 正在看的那天 ⇒ 红（离开该 TAB 也保持红）；
             *   ② 当前选中、但不是正在看的那天 ⇒ 紫（#A78BFA）；
             *   ③ 今天（既不是观看日、也没被选中）⇒ 绿（跨天回看时"今天"不再抢红）；
             *   ④ 其余 ⇒ 灰。 */
            Color fg = isWatch ? Color.FromRgb(0xFF, 0x4C, 0x4C)
                     : active ? Color.FromRgb(0xA7, 0x8B, 0xFA)
                     : d == 0 ? Color.FromRgb(0x4C, 0xAF, 0x50)
                     : Color.FromRgb(0xA8, 0xB6, 0xC8);
            // 底色只在"选中"时给一层同色微光（红=正在看 / 紫=只是选中），其余保持深蓝底
            Color bg = !active ? Color.FromRgb(0x1E, 0x2B, 0x45)
                     : isWatch ? Color.FromRgb(0x4A, 0x1B, 0x24)
                     : Color.FromRgb(0x2A, 0x1B, 0x45);
            var btn = new Button
            {
                Content = d == 0 ? "今天" : day.ToString("MM-dd"),
                Width = 62,
                Height = 26,
                Margin = new Thickness(0, 0, 6, 0),
                Cursor = Cursors.Hand,
                Foreground = new SolidColorBrush(fg),
                Background = new SolidColorBrush(bg),
                BorderThickness = new Thickness(0),
                FontSize = 12,
                FontWeight = (isWatch || active) ? FontWeights.Bold : FontWeights.Normal,
            };
            btn.Click += async (_, _) =>
            {
                _day = day;
                BuildDayBar();
                await LoadDayAsync();
            };
            if (active) activeBtn = btn;
            DayBar.Children.Add(btn);
        }

        /* ★★ 2026-11-10（用户反馈："日期 TAB 不能左右滚动并需要自动居中"）★★
         *   原来日期条固定停在最左边：选中「6 天前」时高亮根本不在视野里，看起来像"只有今天+未来"。
         *   ⇒ 建完按钮后把选中那一天**滚到日期条中间**（等布局完成再算，否则 ActualWidth 还是 0）。 */
        var ab = activeBtn;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                if (ab == null) return;
                double x = ab.TranslatePoint(new Point(0, 0), DayBar).X;
                double target = x - DayScroller.ViewportWidth / 2 + ab.ActualWidth / 2;
                DayScroller.ScrollToHorizontalOffset(Math.Max(0, target));
            }
            catch
            {
                try { ab?.BringIntoView(); } catch { /* 忽略 */ }
            }
        }), System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>日期条左右箭头：单击按"一屏的 60%"翻页；悬停时用小步长连续滚（见 HoverArrow_Enter）。</summary>
    void ScrollDayBar(int dir, double stepOverride = 0)
    {
        double step = stepOverride > 0 ? stepOverride : Math.Max(120, DayScroller.ViewportWidth * 0.6);
        double max = Math.Max(0, DayScroller.ExtentWidth - DayScroller.ViewportWidth);
        double target = Math.Max(0, Math.Min(max, DayScroller.HorizontalOffset + dir * step));
        DayScroller.ScrollToHorizontalOffset(target);
    }

    /// <summary>节目列表上下箭头：单击滚 3 行；悬停时小步长连续滚。</summary>
    void ScrollProgram(int dir, double stepOverride = 0)
    {
        double step = stepOverride > 0 ? stepOverride : 84;
        double max = Math.Max(0, ProgScroll.ExtentHeight - ProgScroll.ViewportHeight);
        double target = Math.Max(0, Math.Min(max, ProgScroll.VerticalOffset + dir * step));
        ProgScroll.ScrollToVerticalOffset(target);
    }

    void BtnDayLeft_Click(object sender, RoutedEventArgs e) => ScrollDayBar(-1);
    void BtnDayRight_Click(object sender, RoutedEventArgs e) => ScrollDayBar(1);
    void BtnProgUp_Click(object sender, RoutedEventArgs e) => ScrollProgram(-1);
    void BtnProgDown_Click(object sender, RoutedEventArgs e) => ScrollProgram(1);

    /* ★★ 2026-11-10（用户："移除滚动条，用上下左右箭头表示，鼠标放在上面照样能滚动就行"）★★
     *   悬停 → 每 90ms 滚一小步，松手（移开）即停；单击仍然是一次翻页。
     *   四个箭头都在 XAML 里挂了 MouseEnter/MouseLeave，方向由 `Tag`（-1 / +1）给出。 */
    System.Windows.Threading.DispatcherTimer? _hoverTimer;
    int _hoverDir;
    bool _hoverVertical;

    void HoverArrow_Enter(object sender, MouseEventArgs e)
    {
        if (sender is not FrameworkElement fe) return;
        if (fe.Tag is not string tag || !int.TryParse(tag, out int dir) || dir == 0) return;
        // 上下箭头 ⇒ 滚节目列表；◀▶ ⇒ 滚日期条（按控件名区分，避免再加一套 Tag）
        bool vertical = fe.Name == "BtnProgUp" || fe.Name == "BtnProgDown";
        StopHoverScroll();
        _hoverDir = dir;
        _hoverVertical = vertical;
        _hoverTimer = new System.Windows.Threading.DispatcherTimer
        { Interval = TimeSpan.FromMilliseconds(90) };
        _hoverTimer.Tick += (_, _) =>
        {
            if (_hoverVertical) ScrollProgram(_hoverDir, 30);
            else ScrollDayBar(_hoverDir, 44);
        };
        _hoverTimer.Start();
    }

    void HoverArrow_Leave(object sender, MouseEventArgs e) => StopHoverScroll();

    void StopHoverScroll()
    {
        try { _hoverTimer?.Stop(); } catch { /* 忽略 */ }
        _hoverTimer = null;
    }

    /// <summary>滚轮落在日期条上 ⇒ 转成**横向**滚动（否则 WPF 会把它当纵向、一行都滚不动）。</summary>
    void DayBar_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        double max = Math.Max(0, DayScroller.ExtentWidth - DayScroller.ViewportWidth);
        if (max <= 0) return;   // 不需要滚 ⇒ 事件照常往外传
        double target = Math.Max(0, Math.Min(max, DayScroller.HorizontalOffset - e.Delta));
        if (Math.Abs(target - DayScroller.HorizontalOffset) < 0.5) return;
        DayScroller.ScrollToHorizontalOffset(target);
        e.Handled = true;
    }

    /// <summary>
    /// 这一行是不是**正在回看**的那一档（与安卓 `isReplaying` 同口径：
    /// "回看的起点"落在该条目的 [start-5s, end) 内 —— 5 秒容差是为了吸收节目单与 playbacktime 的边界误差）。
    /// </summary>
    bool InReplay(EpgProgram p)
    {
        if (_replayProg == null) return false;
        long start = _replayProg.StartEpoch;
        if (start <= 0) return false;
        long pStart = p.StartEpoch;
        if (pStart <= 0) return false;
        long pEnd = p.EndEpoch > pStart ? p.EndEpoch : pStart + 1800;   // 与主窗口起播时的兜底一致
        return start >= pStart - 5 && start < pEnd;
    }

    async System.Threading.Tasks.Task LoadDayAsync()
    {
        ProgList.Children.Clear();
        _curRow = null;
        _replayRow = null;
        ProgList.Children.Add(new TextBlock
        {
            Text = "加载中…",
            Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x99, 0xAA)),
            FontSize = 12,
            Margin = new Thickness(2, 6, 0, 0),
        });
        var list = await EpgClient.FetchAsync(_ch.Pid, _day);
        ProgList.Children.Clear();

        if (list.Count == 0)
        {
            ProgList.Children.Add(new TextBlock
            {
                Text = "（这一天没有节目数据）",
                Foreground = new SolidColorBrush(Color.FromRgb(0x88, 0x99, 0xAA)),
                FontSize = 12,
                Margin = new Thickness(2, 6, 0, 0),
            });
            return;
        }

        /* ★★ 2026-11-06：**按"S 位置"兜底判定已播** ★★
         *   日志证明 `IsPast` 在数据侧是 true（epoch 正常），但用户看到的还是一片 `◷`。
         *   与其依赖单个字段的解析结果，不如用"当前节目在列表中的位置"做兜底：
         *   当前节目之前的条目一定是已播过的（节目单是按时间升序返回的）。 */
        int curIdx = list.FindIndex(x => x.IsCurrent);
        /* ★ 2026-11-06（与安卓同款）：处于回看/时移时，正在直播那档**退为绿色「直播」**，
         *   否则两处都是红粗，看不出主次。
         * ★ 2026-11-10（用户实测）：判据必须是**"当前是否在回看/时移"（全局 `_replayProg != null`）**，
         *   不能是"这一天的列表里有没有回看中" —— 跨天回看（回看昨天那档、人在今天的日期 TAB）时
         *   原来会退回红粗，用户要求同样是绿字。 */
        bool hasReplay = _replayProg != null;
        for (int i = 0; i < list.Count; i++)
            ProgList.Children.Add(BuildRow(list[i], i, curIdx, hasReplay));

        /* ★★ 2026-11-06：**打开时把"当前那档"定位到中间**（对齐安卓）★★
         *   一天 30~60 条，如果不定位，用户看到的是 00:00 那几条，还要自己往下翻。
         *   ★ 回看中优先（那才是用户此刻在看的东西），其次才是"正在播出"。 */
        var anchor = _replayRow ?? _curRow;
        if (anchor != null)
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    double y = anchor.TranslatePoint(new Point(0, 0), ProgList).Y;
                    double target = y - ProgScroll.ViewportHeight / 2 + anchor.ActualHeight / 2;
                    ProgScroll.ScrollToVerticalOffset(Math.Max(0, target));
                }
                catch { anchor.BringIntoView(); }
            }), System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }

    /// <summary>关闭按钮（右上角 ✕）。</summary>
    void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    /* ★★ 2026-11-06（用户要求：与安卓 `EpgModal` 同款）★★
     *   · 正在回看的那档 ⇒ **红字加粗 + 右侧「回看中」**（点它无效，已经在这儿了）；
     *   · 正在直播那档 ⇒ 右侧「直播中」；**处于回看/时移时改成绿色常规字 + 文案「直播」**
     *     （`liveSecondary`），否则保持红粗 —— 两处都红就看不出主次；
     *   · 其它已播完可回看 ⇒ 右侧「回看」蓝色小标；不可回看 ⇒ 灰。
     *   颜色取安卓同款：#FF4C4C（热）/ #4CAF50（绿）/ #2F6BFF（蓝）。 */
    Border BuildRow(EpgProgram p, int index, int curIndex, bool hasReplay)
    {
        // ★ 位置兜底：当前节目之前的都算"已播过"（即使 IsPast 字段算不出来）
        bool past = p.IsPast || (curIndex >= 0 && index < curIndex);
        bool inReplay = InReplay(p);
        bool liveOnAir = p.IsCurrent;
        bool liveSecondary = liveOnAir && hasReplay;
        bool canReplay = past && p.Replayable && !inReplay && !liveOnAir;

        var brHot = new SolidColorBrush(Color.FromRgb(0xFF, 0x4C, 0x4C));     // 回看中 / 正在直播（无回看时）
        var brGreen = new SolidColorBrush(Color.FromRgb(0x4C, 0xAF, 0x50));   // 直播中（有回看时，次要）
        var brNormal = new SolidColorBrush(Color.FromRgb(0xE0, 0xE6, 0xF0));  // 可回看
        var brDim = new SolidColorBrush(Color.FromRgb(0x6B, 0x7A, 0x8F));     // 不可回看 / 未播
        var brBlue = new SolidColorBrush(Color.FromRgb(0x2F, 0x6B, 0xFF));    // 「回看」小标

        bool isHot = inReplay || (liveOnAir && !liveSecondary);
        string prefix = inReplay || liveOnAir ? "▶ "
                      : past ? (p.Replayable ? "↺ " : "· ") : "◷ ";

        var tb = new TextBlock
        {
            Text = prefix + p.Display,
            /* ★ 2026-11-10（用户要求，三端统一）：
             *   回看中 ⇒ 红粗；回看/时移期间正在直播那档 ⇒ **整行绿粗**（不能只有右边「直播」两个字变绿）；
             *   直播（未回看）⇒ 红粗；可回看 ⇒ 正常白；其余 ⇒ 灰。 */
            Foreground = inReplay ? brHot
                       : liveOnAir ? (liveSecondary ? brGreen : brHot)
                       : canReplay ? brNormal : brDim,
            FontSize = 13,
            FontWeight = (inReplay || liveOnAir) ? FontWeights.Bold : FontWeights.Normal,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(tb);

        // ---- 右侧状态标（顺序与安卓一致：回看中 > 直播中 > 回看）----
        FrameworkElement? status = null;
        if (inReplay)
            status = new TextBlock { Text = "回看中", Foreground = brHot, FontSize = 12, FontWeight = FontWeights.Bold };
        else if (liveOnAir)
            status = new TextBlock
            {
                // ★ 2026-11-10（用户要求）：回看/时移期间，这一档写「直播」（你已经不在看直播），
                //   否则仍写「直播中」；两种都是**粗体**（绿粗/红粗），与整行保持一致。
                Text = liveSecondary ? "直播" : "直播中",
                Foreground = liveSecondary ? brGreen : brHot,
                FontSize = 12,
                FontWeight = FontWeights.Bold,
            };
        else if (canReplay)
            status = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 3, 8, 3),
                Child = new TextBlock { Text = "回看", Foreground = brBlue, FontSize = 11 },
            };

        if (status != null)
        {
            status.VerticalAlignment = VerticalAlignment.Center;
            status.Margin = new Thickness(8, 0, 0, 0);
            Grid.SetColumn(status, 1);
            grid.Children.Add(status);
        }

        var row = new Border
        {
            Child = grid,
            Padding = new Thickness(6, 5, 6, 5),
            CornerRadius = new CornerRadius(4),
            Background = Brushes.Transparent,
            // （下一页的 ScrollViewer 定位需要它）
            Tag = inReplay ? "replay" : liveOnAir ? "cur" : null,
            Cursor = canReplay ? Cursors.Hand : Cursors.Arrow,
            ToolTip = inReplay ? "正在回看该节目"
                    : liveOnAir ? "正在直播"
                    : canReplay ? "点击回看"
                    : p.IsPast ? "该节目不可回看（版权限制）"
                    : "尚未播出",
        };

        if (inReplay) _replayRow = row;
        else if (liveOnAir) _curRow = row;

        if (canReplay)
        {
            row.MouseEnter += (_, _) => row.Background = new SolidColorBrush(Color.FromRgb(0x24, 0x33, 0x52));
            row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
            row.MouseLeftButtonUp += (_, _) => ReplayRequested?.Invoke(p, _ch);
        }
        return row;
    }
}
