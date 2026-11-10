# 未公开的实现（占位说明）

本仓库是**应用层源码**。为了让工程结构完整、便于阅读，以下实现**没有随仓库分发**，
仓库内以“接口 / 构建配置 / 说明文件”的形式占位。补齐后才能编译出可运行包。

| 位置 | 原有内容 | 当前形态 |
|---|---|---|
| `common/native/src/` | 取流签名、加密流解密的原生实现（C） | 仅有 `README.md` 说明各模块职责；`CMakeLists.txt` 中相关条目已注释 |
| `harmony/entry/src/main/ets/common/`（两个文件） | 签名参数生成、加密流软解（SM4-CBC） | 未包含 |
| `Android/.../data/`（两个文件） | 请求签名、签名参数生成 | 未包含 |
| `Android/.../native/`（一个文件） | 签名的原生绑定 | 未包含 |
| `Android/.../player/`（三个文件） | 加密流解密与数据源 | 未包含 |
| `windows/Sm4C.cs` | 加密流软解（SM4-CBC） | 未包含 |
| 各端平台凭据（应用标识 / 设备标识 / 密钥） | 真实取值 | 已替换为 `YOUR_*` 占位 |

另外，**台标与打包资产**（`harmony/entry/src/main/resources/rawfile/`、`windows/logos/`）不随仓库分发。

> 说明：缺少上述文件时，`dotnet build` / `gradle` / DevEco 会在对应引用处报“找不到符号”——这是**预期**的，
> 不是仓库损坏。只想使用请看 README 的「下载」一节。
