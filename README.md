# PalmTV —— 双端直播播放器

> **桌面版**（C# / WPF / WebView2） + **鸿蒙版**（ArkTS / 原生 AVPlayer）
>
> 一个把「频道列表 → 取流 → 本地中转 → 播放」整条链路做成**纯净、长期、无间断**的跨端播放器工程。
> 两端共用同一套取流编排思路，但**播放内核完全不同**（见下方对比）。

---

## ⚠️ 声明

- 本项目仅供 **技术研究 / 学习客户端架构** 使用。使用者须遵守所在地区法律法规及上游平台的服务条款，
  不得用于侵权传播、商业转售或规避付费内容。
- 本仓库**不含**任何受版权保护的媒体内容，也**不含**完整可运行所需的全部组件（见「五、本仓库不包含的部分」）。
- 仓库内所有图标均为**自绘占位图**，与任何电视台/平台无关。

---

## 一、两个版本对比

|  | **桌面版** — `desktop/` | **鸿蒙版** — `harmony/` |
|---|---|---|
| 平台 | Windows 10/11 (x64) | HarmonyOS NEXT |
| UI | C# / WPF | ArkTS / ArkUI |
| 播放内核 | WebView2 内的 Web 播放器（`hls.js`） | **原生 AVPlayer** + `XComponent(SURFACE)` |
| 媒体处理位置 | 页面内 JavaScript | **native N-API 模块**（`libcmg_napi.so`） |
| 本地中转 | Go 反向代理进程 `127.0.0.1:18888` | ArkTS 本地 HTTP 服务 `127.0.0.1:18899` |
| 取流签名 | `desktop/PlayerService.cs` | `harmony/.../common/NativeSigner.ets` |
| 状态 | 可用（需自备「五」所列组件） | 可用（需自备「五」所列组件） |

**两端共同能力**

- 内置 **55 个直播频道**（含 4K / 8K 频道位），频道网格 + 分组
- **EPG 节目单**：状态栏滚动「正在 / 即将」，弹层展示全天节目
- **手势**：左侧上下调亮度、右侧上下调音量
- **播放状态机**：首播看门狗、错误自愈（重取流 / 重建播放器）、后台零重建
- **播控中心**：媒体卡片标题 + 封面（鸿蒙侧为原生 `AVSession`）
- **音频焦点**：来电 / 其它应用抢焦点打断处理；退后台归还焦点
- **前后台治理**：退后台不下载不处理、回前台按需恢复；长后台自动作废登录态重取
- 屏幕常亮、静音/音量持久、全屏与锁屏控件、频道切换预取

---

## 二、架构

两端都是「**播放器只看到可直接播放的数据**」这一条思路：

```
       远端播放列表（含一次性令牌）
              │
              ├─(1) 客户端解析频道 → 取流（auth → 签名 → sessionToken → 播放地址）
              ▼
       ┌───────────────────────────────────────────────┐
       │  播放器（Web 播放器 / 原生 AVPlayer）          │
       │        ▲                                       │
       │        │ 明文分片                              │
       │  ┌─────┴─────────────────────────────────────┐ │
       └─►│ 本地中转服务（127.0.0.1）                  │ │
          │  /local.m3u8 : 拉远端播放列表并改写分片路径│ │
          │  /local-seg  : 下载分片 → 处理 → 返回      │ │
          └───────────────────┬───────────────────────┘ │
                              ▼                         │
                    媒体处理模块（不在本仓库）  ◄─────────┘
```

- **桌面版**：页面内 Web 播放器 + Go 反代。反代负责同源托管播放页、转发媒体请求、EPG 与取流接口。
- **鸿蒙版**：原生 AVPlayer + ArkTS 本地服务。媒体处理在 native 完成，JS 线程不被阻塞（异步 + 串行化）。

---

## 三、目录结构

```
PalmTV/
├─ desktop/                      桌面版（C# / WPF / WebView2）
│  ├─ PalmTV.Desktop.csproj      单文件自包含发布（win-x64）
│  ├─ App.xaml(.cs)
│  ├─ MainWindow.xaml(.cs)       主窗口 / 频道列表 / 全屏 / 右键菜单 / EPG
│  ├─ PlayerService.cs           取流编排与请求签名
│  ├─ publish.ps1                发布脚本
│  └─ TV.png / tv-icon.ico       自绘占位图标
│
├─ proxy/                        Go 本地服务（桌面版用）
│  ├─ go.mod / go.sum
│  ├─ build.ps1                  校验注入串 → go build → 覆盖可执行文件
│  └─ verify_inject.cjs          注入脚本的 JS 语法校验
│
├─ harmony/                      鸿蒙版（ArkTS / 原生 AVPlayer）
│  ├─ AppScope/                  应用级配置与图标
│  ├─ build-profile.json5        签名与产品配置
│  ├─ README.md                  鸿蒙侧构建说明
│  └─ entry/
│     ├─ build-profile.json5     externalNativeOptions
│     ├─ oh-package.json5        本地依赖 libcmg_napi.so
│     └─ src/main/
│        ├─ module.json5         Ability / 权限 / 后台模式
│        ├─ ets/                 业务代码（播放页 / 取流 / 会话 / 音频焦点 / 本地服务）
│        ├─ cpp/types/           native 模块的 TS 类型声明
│        └─ resources/           字符串 / 颜色 / 占位图标
│
├─ README.md / README.en.md
└─ LICENSE
```

---

## 四、构建与运行

### 桌面版

**依赖**：.NET 10 SDK、Go 1.2x、Node.js、WebView2 Runtime（用户机）

```powershell
# 1) 本地服务（改动 proxy/ 后必须走 build.ps1，它会先做 JS 语法校验）
cd proxy; .\build.ps1

# 2) 客户端
cd ..\desktop; dotnet build -c Debug

# 3) 发布（单文件自包含）
dotnet publish -c Release
```

> `dotnet build` 是增量构建，**不会**复制 `player.html`（按时间戳 `PreserveNewest`）。
> 改完需要手动复制到运行目录；`dotnet publish` 不受影响。
>
> 运行目录：`desktop/bin/<Configuration>/net10.0-windows/win-x64/`。

### 鸿蒙版

用 DevEco Studio 打开 `harmony/`，详见 [`harmony/README.md`](./harmony/README.md)。

要点：
1. Project Structure → Signing Configs → 勾选 **Automatically generate signature**。
   自动签名只写 `signingConfigs`，**不会**补 `products[*].signingConfig`（本工程已补好）。
2. Sync and Refresh Project → Build Hap(s)，确认产物是 `entry-default-signed.hap`。

---

## 五、本仓库不包含的部分

本仓库是**应用外壳**：可读、可作为客户端架构参考，但**不能直接编译/运行**。
要让两端真正跑起来，你需要自备下列组件：

| 组件 | 位置 | 说明 |
|---|---|---|
| 桌面侧播放页 | `desktop/player.html` | Web 播放器页面（媒体请求改写、播放控制、页面侧注入） |
| 桌面侧设备票据生成 | `desktop/gen_yspticket.cjs` | 与 `desktop/legacy/`（历史实现） |
| 桌面侧本地服务实现 | `proxy/main.go` | Go 反代与托管逻辑 |
| 鸿蒙侧 native 构建脚本 | `harmony/entry/src/main/cpp/CMakeLists.txt` | 产出 `libcmg_napi.so` |
| 鸿蒙侧 native 内核源码 | — | 实现 `index.d.ts` 里声明的全部接口 |
| 鸿蒙侧运行时资产 | `harmony/entry/src/main/resources/rawfile/` | 运行时装载所需文件 |
| 鸿蒙侧签名实现 | `harmony/.../common/ProxySigner.ets` | 请求签名 |
| 鸿蒙侧取流参数生成 | `harmony/.../common/ckey_core.ts` | 详见 `TvConfig.ets` 占位说明 |
| 应用标识配置 | `harmony/.../common/TvConfig.ets` | 仓库内为**占位值** |

> 缺失文件均已写入 `.gitignore`，本地开发时它们照常存在，只是不随仓库分发。

---

## 六、诊断

| 端 | 日志位置 |
|---|---|
| 桌面版 | 运行目录下的 `player-debug.log`（页面 `postMessage`）、`proxy.log`（Go 进程） |
| 鸿蒙版 | hilog；在 DevEco Log 窗口按 tag 过滤 |

排错顺序建议：先看本地服务是否起来（端口是否在听），再看播放页/播放器是否拿到了播放列表，
最后才看媒体处理模块的统计输出。

---

## 七、贡献

1. 改 `proxy/` 下的注入与托管逻辑后，**务必**跑 `proxy/build.ps1`（内含 JS 语法校验）；
   裸 `go build` 跳过校验，语法错误会让整页脚本解析失败，症状是「播放器初始化失败」。
2. 改鸿蒙侧 `player.html` 之类被缓存的部署产物时，记得同步提升部署版本号。
3. 提交前请确认没有把「五」表中列出的组件带进仓库。

## 八、许可

见 [LICENSE](./LICENSE)。
