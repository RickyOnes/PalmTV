using System.Windows;

namespace PalmTVDesktop;

/// <summary>
/// ★ 2026-09-29：首启「内容来源与免责声明」弹窗（与鸿蒙端 `Index.disclaimerModal()` 同口径）。
///
/// **两种模式**（由 <c>firstRun</c> 决定）：
///   · 首启流程（firstRun=true）：显示「不同意（退出）」+「我已阅读并同意」；
///     点同意 ⇒ `DialogResult=true`；点不同意或直接关窗 ⇒ 视为拒绝（调用方会退出应用）。
///   · 再次查看（firstRun=false，从关于页「查看完整声明」进入）：**不给"不同意"按钮** ——
///     那一步早已确认过了，再出现"不同意"逻辑上是错的；这里只有「关闭」，关掉不影响使用。
///
/// 声明正文与联系邮箱都取自 <see cref="MainWindow"/> 的常量（**单一来源**，别在这里另抄一份）。
/// 正文与鸿蒙 `DISCLAIMER_TEXT` / `CONTACT_EMAIL` 必须同步；改正文时两端一起升 `discVer`。
/// </summary>
public partial class DisclaimerWindow : Window
{
    readonly bool _firstRun;

    /// <param name="firstRun">true = 首启（含"不同意即退出"）；false = 已确认用户再次查看。</param>
    internal DisclaimerWindow(bool firstRun = true)
    {
        InitializeComponent();
        _firstRun = firstRun;
        TextBody.Text = MainWindow.DisclaimerText;
        ContactText.Text = MainWindow.ContactLabel + MainWindow.ContactEmail;
        if (!firstRun)
        {
            BtnRefuse.Visibility = Visibility.Collapsed;
            BtnAgree.Content = "关闭";
        }
    }

    void Agree_Click(object sender, RoutedEventArgs e)
    {
        if (_firstRun) DialogResult = true;   // 首启：记录"已同意"，继续启动
        else Close();                         // 再次查看：纯粹关窗（不改变任何状态）
    }

    void Refuse_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
