using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace PalmTVDesktop;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        AppDomain.CurrentDomain.UnhandledException += (s, args) =>
        {
            LogError("AppDomain.UnhandledException", args.ExceptionObject as Exception);
        };
        DispatcherUnhandledException += (s, args) =>
        {
            LogError("DispatcherUnhandledException", args.Exception);
            args.Handled = false; // 不吞, 让程序崩出可见错误
        };
        base.OnStartup(e);
    }

    static void LogError(string source, Exception? ex)
    {
        try
        {
            var msg = $"[{DateTime.Now:HH:mm:ss.fff}] [{source}] {ex}\n";
            File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "player-crash.log"), msg);
        }
        catch { }
    }
}
