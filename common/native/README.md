# 原生模块（占位）

三端共用的原生模块：**取流签名** + **加密流解密**（C 语言，编译为各端各自的动态库）。

```
native/
├─ CMakeLists.txt     构建配置（不公开的源条目已注释，按需放开）
├─ include/           对外头文件（接口声明）
└─ src/               实现未公开（见 src/README.md）
```

## 接入方式

| 端 | 产物 | 桥接 |
|---|---|---|
| Windows | `PalmTVCore.dll` | `windows/PalmTVCore.cs`（P/Invoke 声明） |
| Android | `libpalmtv_napi.so` | `Android/.../native/NativeLib.kt`（JNI） |
| HarmonyOS | `libpalmtv_napi.so` | `harmony/entry/src/main/cpp/types/libpalmtv_napi/index.d.ts` |

## 编译（以鸿蒙为例）

```bash
# 在 entry/src/main/cpp 下由 DevEco 的 CMake 工具链自动编译
# 产物：entry/build/<product>/intermediates/libs/<abi>/libpalmtv_napi.so
```

> ⚠️ 本仓库不含实现，`src/` 为空时链接会失败——这是预期的，见仓库根 `NOTICE.md`。
