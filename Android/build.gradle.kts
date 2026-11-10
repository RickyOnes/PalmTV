// 根构建脚本：只声明插件版本，具体配置在 app/build.gradle.kts
// ★ 2026-10-01：Kotlin 2.0.21 → **2.2.10**。原因：Media3 1.11.1 依赖 kotlin-stdlib 2.2.10，
//   而 Kotlin 2.0.21 的编译器读不了 2.2 的元数据 ⇒ 构建直接报
//     "module was compiled with an incompatible version of Kotlin ... metadata is 2.2.0, expected 2.0.0"。
//   ⚠️ `kotlin.plugin.compose` 必须与 Kotlin **同版本**（Compose 编译器随 Kotlin 发布）。
plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.2.10" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.10" apply false
}
