# HarmonyOS 客户端

ArkTS / ArkUI，播放内核为原生 **AVPlayer + XComponent(SURFACE)**；
签名与解密由单个 N-API 原生模块提供。

## 目录

```
harmony/
├─ AppScope/                     应用级配置与图标
├─ build-profile.json5           产品 / 构建模式 / 签名（签名需自备，见下）
├─ entry/
│  ├─ build-profile.json5        native 构建参数（CMake、ABI）
│  └─ src/main/
│     ├─ module.json5            Ability、权限、后台音频模式
│     ├─ ets/
│     │  ├─ pages/Index.ets      唯一页面：状态栏 / 视频区 / 节目条 / 频道区 / 弹层
│     │  ├─ entryability/        应用生命周期
│     │  └─ common/              播放、取流、本地服务、节目单、播控、音频焦点
│     ├─ cpp/                    N-API 模块的 CMake 与类型声明
│     └─ resources/              字符串 / 颜色 / 图标（台标资产不随仓库）
└─ README.md
```

## 构建

1. DevEco Studio 打开 `harmony/`；
2. **File → Project Structure → Signing Configs** → 勾选 *Automatically generate signature*
   （签名材料需自备：仓库内 `signingConfigs` 只有占位，`Profile/` 目录不上传）；
3. Sync and Refresh Project → **Build → Build Hap(s)**；
4. 产物：`entry/build/<product>/outputs/<target>/entry-default-signed.hap`。

- 只想在真机上自测：产品选 `default`、构建模式选 `release`（混淆 + 调试签名，可 `hdc install`）。
- 对外分发：产品选 `release`（发布证书，只能走应用市场内测渠道，不能直接安装）。
- 若本机 JDK 为 25，命令行构建可加 `-Djava.version=21.0.5 -Djava.specification.version=21`（Gradle 侧同理）。

> 原生签名 / 解密实现与台标资产不在仓库内（见根目录 `NOTICE.md`），
> `ets/common/` 里对应的两个文件（签名参数生成、软解）需要自备。
