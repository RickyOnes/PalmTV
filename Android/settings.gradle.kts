// PalmTV Android（手机端）—— 工程入口
//
// ★ 三端共用 `common/native`（纯 C11 + POSIX）：
//   桌面 → windows\PalmTVCore.dll（MinGW）｜鸿蒙 → libcmg_napi.so（NDK clang）
//   Android → libcmgjni.so（NDK clang，本目录 app/src/main/cpp/CMakeLists.txt）
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "PalmTV"
include(":app")
