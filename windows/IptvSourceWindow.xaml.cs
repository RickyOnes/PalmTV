using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Windows;

namespace PalmTVDesktop;

/// <summary>
/// ★ 2026-09-29：「自定义 IPTV 源」编辑窗（关于页入口）。
///
/// 数据落在 `%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`（见 <see cref="IptvChannels.UserPath"/>）——
/// 安装到 Program Files 时 exe 同目录**不可写**，所以用户条目必须放用户目录；内置清单只读。
/// 保存后调用方（<see cref="MainWindow"/>）会重新载入频道列表，**不需要重启**。
///
/// ★★ 2026-10-02（用户实测反馈）★★
///   ① 「点更新选中后要**马上**更新列表，而不是等'保存并生效'」——
///      老实现靠 `Row.ToString()` 显示，而 `ObservableCollection` **只在整项替换时**通知，
///      **对象属性变更不会重绘**（老代码注释里写着这个坑，还打了个"替换对象"的补丁，但显示仍不跟手）。
///      现在用正规做法：<see cref="Row"/> 实现 `INotifyPropertyChanged` + 组合属性 `Text`
///      ⇒ 任何字段变更都**立刻**重绘，「更新选中」当场可见。
///   ② **列表行带序号**（`1. 频道名    地址`）+ 选中蓝底白字 / 未选中浅灰 / 单行省略 —— 与移动端同款。
///   ③ **新增「从 m3u 文本导入」**（<see cref="IptvChannels.ParseM3uText"/>，与安卓/鸿蒙同一套解析规则）。
///   ④ 每次操作都回一句执（[!:_flash]）：已添加第 N 条 / 已更新第 N 条 / 已删除第 N 条 / 已导入 N 条（跳过 M 条重复）。
///      ⚠️ 回执里带**"尚未保存"**：列表当场变了，但落盘要等「保存并生效」（避免用户误以为已经存了）。
/// </summary>
public partial class IptvSourceWindow : Window
{
    /// <summary>
    /// 列表行。
    /// ⚠️ 必须实现 `INotifyPropertyChanged`：WPF 的 `ListBox` 对**对象属性变更**不会自动刷新
    ///   （只对集合的增 / 删 / 替换有反应）⇒ 老实现用 `ToString()` + "整项替换"绕过，代价是"改完看不出来"。
    ///   [Text] 是**组合**出来的显示文本，任一字段一动就 `Raise(nameof(Text))`。
    /// ⚠️⚠️ **属性必须是 `public`**：WPF 数据绑定（XAML 里的 `{Binding Text}`）只认公共属性 ——
    ///   写成 `internal` 时绑定**静默失败**（列表整块空白，但 UIA 里能看到列表项存在），
    ///   2026-10-02 就是这么踩的（改成 `INotifyPropertyChanged` + DataTemplate 后列表变空）。
    ///   `ToString()` 保留给 UIA / 无障碍 / 调试看（显示与 [Text] 一致）。
    /// </summary>
    public sealed class Row : INotifyPropertyChanged
    {
        int _index;
        string _name = "";
        string _url = "";

        /// <summary>行号（1 起；增删后由 <see cref="Renumber"/> 重排）—— 与移动端列表的 "1. " 序号同款。</summary>
        public int Index { get => _index; set { _index = value; Raise(nameof(Text)); } }

        public string Name { get => _name; set { _name = value; Raise(nameof(Text)); } }

        public string Url { get => _url; set { _url = value; Raise(nameof(Text)); } }

        /// <summary>列表行文本：`1. 频道名    地址`（单行；超长由 XAML 里的 TextTrimming 省略）。</summary>
        public string Text => Index + ". " + (Name.Length == 0 ? "(未命名)" : Name) + "    " + Url;

        public override string ToString() => Text;

        public event PropertyChangedEventHandler? PropertyChanged;

        void Raise(string prop) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));
    }

    readonly ObservableCollection<Row> _rows = new();

    /// <summary>最近一次**操作成功**的回执（如"✓ 已更新第 2 条：CCTV-2"）；换选中行会清掉它。</summary>
    string _flash = "";

    internal IptvSourceWindow()
    {
        InitializeComponent();
        foreach (var (name, url) in IptvChannels.LoadUser()) _rows.Add(new Row { Name = name, Url = url });
        Renumber();
        SourceList.ItemsSource = _rows;
        UpdateHint();
    }

    /// <summary>重排行号（增删之后调用）—— 序号显示在列表行文本里，必须与真实下标一致。</summary>
    void Renumber()
    {
        for (int i = 0; i < _rows.Count; i++) _rows[i].Index = i + 1;
    }

    /* ★ 2026-09-29：详细说明都放在这里（关于页只留"一句提示 + 按钮"，见 MainWindow.xaml）。 */
    string Summary() =>
        $"当前 {_rows.Count} 条自定义源。\n" +
        "· 支持 m3u8 / ts 直播直链；保存后立即生效，无需重启\n" +
        "· 自定义源写入用户目录（不改安装目录），升级 / 重装都不会丢\n" +
        $"· 也可用记事本直接编辑：{IptvChannels.UserPath}";

    /// <summary>刷新底部提示：**操作回执优先**（让用户马上知道刚才那一下生效了），否则显示汇总。</summary>
    void UpdateHint() => HintText.Text = _flash.Length > 0 ? _flash : Summary();

    /// <summary>校验输入框；名称为空时自动取域名。</summary>
    bool Validate(out string name, out string url)
    {
        name = NameBox.Text.Trim();
        url = UrlBox.Text.Trim();
        if (url.Length == 0)
        {
            MessageBox.Show(this, "请填写播放地址。", "自定义 IPTV 源", MessageBoxButton.OK, MessageBoxImage.Information);
            return false;
        }
        if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show(this, "播放地址需以 http:// 或 https:// 开头。", "自定义 IPTV 源",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return false;
        }
        if (name.Length == 0)
        {
            try { name = new Uri(url).Host; } catch { name = "IPTV"; }
        }
        return true;
    }

    void Add_Click(object sender, RoutedEventArgs e)
    {
        if (!Validate(out var name, out var url)) return;
        if (_rows.Any(r => string.Equals(r.Url, url, StringComparison.OrdinalIgnoreCase)))
        {
            MessageBox.Show(this, "该地址已在列表里。", "自定义 IPTV 源", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        _rows.Add(new Row { Name = name, Url = url });
        Renumber();
        // ★ 与移动端一致：新增后**选中它**（列表高亮 + 输入框清空）⇒ 用户一眼看到加在第几行
        SourceList.SelectedIndex = _rows.Count - 1;
        SourceList.ScrollIntoView(_rows[^1]);
        NameBox.Text = "";
        UrlBox.Text = "";
        _flash = $"✓ 已添加第 {_rows.Count} 条：{name}（共 {_rows.Count} 条，尚未保存）";
        UpdateHint();
    }

    void Update_Click(object sender, RoutedEventArgs e)
    {
        if (SourceList.SelectedItem is not Row sel)
        {
            MessageBox.Show(this, "请先在列表里选中要修改的那条。", "自定义 IPTV 源",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (!Validate(out var name, out var url)) return;
        // ★ 与移动端一致：更新时也要防"改成列表里已有的地址"
        if (_rows.Any(r => !ReferenceEquals(r, sel) &&
                           string.Equals(r.Url, url, StringComparison.OrdinalIgnoreCase)))
        {
            MessageBox.Show(this, "该地址已在列表里。", "自定义 IPTV 源", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        sel.Name = name;   // ★ 属性变更 ⇒ INotifyPropertyChanged ⇒ 列表**当场**重绘（不用等"保存并生效"）
        sel.Url = url;
        _flash = $"✓ 已更新第 {sel.Index} 条：{name}（共 {_rows.Count} 条，尚未保存）";
        UpdateHint();
    }

    void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (SourceList.SelectedItem is not Row sel)
        {
            MessageBox.Show(this, "请先在列表里选中要删除的那条。", "自定义 IPTV 源",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        int no = sel.Index;
        string who = sel.Name;
        _rows.Remove(sel);
        Renumber();
        NameBox.Text = "";
        UrlBox.Text = "";
        _flash = $"✓ 已删除第 {no} 条：{who}（剩 {_rows.Count} 条，尚未保存）";
        UpdateHint();
    }

    void SourceList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (SourceList.SelectedItem is Row sel)
        {
            NameBox.Text = sel.Name;
            UrlBox.Text = sel.Url;
            // ★ 换了一行 ⇒ 上一条操作回执失效（与移动端"点列表清提示"同口径）
            _flash = "";
            UpdateHint();
        }
    }

    /* ================= ★★ 2026-10-02：从 m3u 文本导入（与安卓/鸿蒙同功能） ★★ ================= */

    void ImportToggle_Click(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        bool show = ImportPanel.Visibility != Visibility.Visible;
        ImportPanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        ImportToggle.Text = show ? "粘贴 m3u 文本（#EXTINF:-1,频道名 换行 地址）" : "从 m3u 文本导入 ▾";
        if (show) ImportBox.Focus();
    }

    void ImportDo_Click(object sender, RoutedEventArgs e)
    {
        var parsed = IptvChannels.ParseM3uText(ImportBox.Text);
        if (parsed.Count == 0)
        {
            MessageBox.Show(this, "没解析到条目（需要 #EXTINF:-1,频道名 与地址各占一行）。", "自定义 IPTV 源",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        int added = 0, dup = 0;
        foreach (var (name, url) in parsed)
        {
            if (_rows.Any(r => string.Equals(r.Url, url, StringComparison.OrdinalIgnoreCase))) { dup++; continue; }
            _rows.Add(new Row { Name = name, Url = url });
            added++;
        }
        Renumber();
        ImportBox.Text = "";
        ImportClose_Click(sender, e);   // 导完就收起来（与移动端一致）
        _flash = added > 0
            ? $"✓ 已导入 {added} 条" + (dup > 0 ? $"（跳过 {dup} 条重复）" : "") + $"（共 {_rows.Count} 条，尚未保存）"
            : $"没有新增：{dup} 条地址都已在列表里。";
        UpdateHint();
    }

    void ImportClose_Click(object sender, RoutedEventArgs e)
    {
        ImportPanel.Visibility = Visibility.Collapsed;
        ImportToggle.Text = "从 m3u 文本导入 ▾";
    }

    void Save_Click(object sender, RoutedEventArgs e)
    {
        var list = _rows.Select(r => (r.Name, r.Url)).ToList();
        if (!IptvChannels.SaveUser(list))
        {
            MessageBox.Show(this, $"保存失败（目录不可写？）：\n{IptvChannels.UserPath}", "自定义 IPTV 源",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        DialogResult = true;
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
