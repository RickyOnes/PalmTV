# PalmTV · 鸿蒙版（HarmonyOS NEXT）

原生鸿蒙播放器：**ArkTS + 原生 AVPlayer**，不依赖 ArkWeb / hls.js。

## 数据流

```
远端 m3u8（含一次性令牌）
  │
  ├─(1) ArkTS 解析频道 → 取流（auth → 签名 → sessionToken → 播放地址）
  ▼
AVPlayer ──播放──► http://127.0.0.1:18899/local.m3u8?u=<远端 m3u8>
  │
  │  ┌────────────────────────────────────────────────────────┐
  └─►│ /local.m3u8 : 拉远端播放列表，把分片改写为 /local-seg   │
     │ /local-seg  : 下载原始分片 → native 处理 → 返回明文     │
     └────────────────────────────────────────────────────────┘
                              │
                              ▼
                libcmg_napi.so（不在本仓库内）
```

**AVPlayer 只看到可直接解码的分片**；媒体处理全部在 native 层完成。

## 工程结构

```
harmony/
├─ AppScope/                 应用级配置与图标
├─ build-profile.json5       签名与产品配置
├─ oh-package.json5
└─ entry/
   ├─ build-profile.json5    externalNativeOptions → src/main/cpp/CMakeLists.txt
   ├─ oh-package.json5       本地依赖 "libcmg_napi.so"
   └─ src/main/
      ├─ module.json5        Ability / 权限 / 后台模式
      ├─ ets/                业务代码
      │  ├─ entryability/    生命周期
      │  ├─ pages/Index.ets  播放页（布局 / 频道网格 / EPG / 手势 / 控制条 / 状态机）
      │  └─ common/          取流、播放会话、音频焦点、本地服务、频道表
      ├─ cpp/types/libcmg_napi/   native 模块的 TS 类型声明
      └─ resources/          字符串 / 颜色 / 图标
```

## 构建

1. DevEco Studio → **Open** 本目录（`harmony/`）。
2. Project Structure → Signing Configs → 勾选 **Automatically generate signature**。
   > 注意：自动签名只写 `signingConfigs` 数组，**不会**补 `products[*].signingConfig`；本工程已在
   > `build-profile.json5` 里补好 `"signingConfig": "default"`，缺少它会产出 `-unsigned.hap`。
3. Sync and Refresh Project → Build Hap(s)。

## ⚠️ 本仓库不包含的部分

本仓库是**应用外壳**。要让工程真正编译/运行，你还需要自备：

| 缺什么 | 说明 |
|---|---|
| `entry/src/main/cpp/CMakeLists.txt` | 构建 native 模块的脚本（不在仓库内） |
| native 内核源码 | 产出 `libcmg_napi.so` 的全部 `.c/.h` |
| `entry/src/main/resources/rawfile/` | 运行时资产 |
| `entry/src/main/ets/common/取流配置(私有)` | 应用/设备标识（仓库内为 `TvConfig.ets` 占位版） |
| `entry/src/main/ets/common/ProxySigner.ets` | 请求签名实现 |
| `entry/src/main/ets/common/ckey_core.ts` | 取流参数生成实现 |

`cpp/types/libcmg_napi/index.d.ts` 保留了 native 模块的**完整接口声明**，可据此了解外壳与内核的边界。

## 已知的 native 编译要点（若你自备内核）

- 必须 `-std=gnu11` + `-D_GNU_SOURCE=1`：ohos 的 musl 头文件按特性宏严格门控，纯 ISO 模式下
  `CLOCK_REALTIME`、`siginfo_t`、`struct sigaction` 等全部"未声明"。
  ⚠️ CMake 中**后写的 `-std` 会覆盖** DevEco 默认的 `-std=gnu11`。
- wasm 运行时的 `GUARD_PAGES` 模式在 ohos 上不可用（大块 `mmap` 保留映射会"假成功"）⇒
  改用纯软件边界检查。
- native 日志必须走 hilog：App 进程的 stdout/stderr **不进** hilog，`fprintf` 打的东西看不到。

## 同步与维护

本目录是**上游开发树的一份公开快照**，请勿在此目录里做功能开发（会被下次同步覆盖）。
同步前先备份本文件，或用下面的排除参数跳过它。

```powershell
robocopy <上游开发树> <本目录> /E ^
  /XD oh_modules build .hvigor .idea .preview node_modules .cmgtest .cxx .clangd rawfile ^
  /XF namecache.json local.properties README.md HANDOFF.md *.rar *.bak *.log *.hap
```

同步后**务必**先看 `git status`：

- `/rawfile/` 与 `entry/src/main/cpp/CMakeLists.txt` 不应出现（前者是运行时资产，后者指向本地内核）；
- `entry/src/main/ets/common/` 下的取流配置、签名实现、cKey 实现不应出现（见上一节表格）；
- 频道图标若被覆盖成上游版本，需要重新替换为**自绘占位图**。

> 一条原则：**上游有的、仓库里没有的东西，不要用 `git add -f` 硬塞进来。**
