# Android 客户端

Kotlin + Jetpack Compose，播放内核 **Media3 (ExoPlayer)**。
手机与电视（Android TV / 电视盒子）**同一个包**：运行时按输入方式自动切换触摸界面 / 遥控器界面。

## 目录

```
app/src/main/java/com/rickyone/palmtv/
├─ MainActivity.kt        入口；竖屏 / 横屏 / 全屏切换
├─ MainViewModel.kt       播放状态机（取流 → 起播 → 自愈 → 前后台）、节目单调度
├─ PalmTvApp.kt           应用初始化
├─ data/                  频道清单、节目单、HTTP、自定义源、偏好
├─ player/                Media3 封装：数据源、播放器、播放统计、台标
├─ ui/                    Compose 界面：手机版 / 电视版 / 节目单 / 关于
└─ native/                原生库桥接
app/src/main/cpp/         CMake 配置（原生模块）
```

## 构建

```powershell
cd Android
.\gradlew.bat assembleRelease
```

产物：`app/build/outputs/apk/release/app-release.apk`（含 `arm64-v8a` / `armeabi-v7a` / `x86_64`）。

- **签名**：`keystore.properties` + 密钥库需自备；缺失时会回退 debug 签名（仅供本地验证）。
- **JDK**：若本机是 JDK 25，Gradle 内嵌 Kotlin 会解析失败，可加参数
  `-Djava.version=21.0.5 -Djava.specification.version=21`。

> 原生签名 / 解密实现不在仓库内（见根目录 `NOTICE.md`），缺文件时编译会在对应引用处报错，属预期。
