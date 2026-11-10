# Windows 客户端

C# / WPF，播放内核 **LibVLC**（随包携带，无需 WebView2 运行时）。

## 目录

```
windows/
├─ MainWindow.xaml(.cs)        主窗口：频道墙、状态栏、节目条、控制栏、全屏与手势
├─ EpgOverlayWindow.xaml(.cs)  节目单弹层（10 天 / 回看 / 箭头滚动）
├─ IptvSourceWindow.xaml(.cs)  自定义 IPTV 源编辑
├─ DisclaimerWindow.xaml(.cs)  首启免责声明
├─ EpgClient.cs                节目单拉取与解码
├─ LocalDecryptServer.cs       进程内本地中转（清单改写 + 分片解密）
├─ LogoPack.cs                 台标容器（运行期解到缓存）
├─ IptvChannels.cs             自定义源（m3u）读写
├─ PalmTVCore.cs               原生模块的 P/Invoke 声明
└─ publish.ps1                 单文件发布脚本
```

## 构建

```powershell
powershell -File windows\publish.ps1
```

产物：仓库根目录 `PalmTV-release.zip`（解压后双击 `WinPalmTV.exe`）。

- 需要 **.NET 10 SDK**；LibVLC 由 NuGet 包补齐并在发布时裁剪。
- 台标源（`windows/logos/`）与原生实现不在仓库内，见根目录 `NOTICE.md`；
  `publish.ps1` 在缺少台标源时会直接失败（避免发出“只有文字台标”的包）。
