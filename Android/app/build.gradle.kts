// ⚠️ 这两个 import 必须放最上面：Kotlin DSL 里 `java` 会被解析成 **JavaPluginExtension**
//   （source set 那个 `java`）⇒ 直接写 `java.io.ByteArrayOutputStream` 会报 `Unresolved reference: io`（实测踩过）。
import java.io.BufferedOutputStream
import java.io.DataOutputStream
// ★ 2026-10-02：签名配置要读 `keystore.properties`（同样必须 import，理由见上面两行 —— 我这次又踩了一遍 ✗）
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

/** 生成的 assets 目录：单个 `palmres.dat` 放这里（见文件末尾的 `packPalmRes` 任务）。
 *  ⚠️ 必须在 `android {}` **之前**声明 —— 下面 `sourceSets` 里要引用它。 */
val palmResOutDir: Provider<Directory> = layout.buildDirectory.dir("generated/palmres")

android {
    namespace = "com.rickyone.palmtv"
    // ★ 2026-10-01：35 → **36**。原因：Media3 1.11.1 的 AAR 元数据要求"依赖方 compileSdk ≥ 36"
    //   （`checkDebugAarMetadata` 会直接 fail），而它正是修掉四平综合那条 IPTV 流
    //   `IllegalStateException @ SampleQueue.sampleMetadata` 的版本。
    //   ⚠️ targetSdk 仍保持 35（不主动 opt-in 新运行时行为）；AGP 8.7.3 的"最高推荐 35"只是警告，
    //      已在 gradle.properties 打开 `android.suppressUnsupportedCompileSdk=36`。
    compileSdk = 36

    defaultConfig {
        /* ★★ 2026-10-02（用户实测：**不能与鸿蒙版同时安装** ⇒ 包名必须与鸿蒙 bundleName 区分开）★★
         *   经过：为了让"安装包看起来像 com.RickyOne.PalmTV"，这里一度改成**与鸿蒙 `bundleName` 完全相同**
         *   的 `com.RickyOne.PalmTV` ⇒ 同一台手机上两个包标识一模一样 ⇒ **装不了第二个** ✗（安卓侧还必须
         *   全小写：Android 包名约定/上架要求都是小写，大写虽然能装但属非规范写法）。
         *   ⇒ 改回**全小写** `com.rickyone.palmtv`：与鸿蒙 `com.RickyOne.PalmTV` **是不同的字符串** ⇒ 可共存 ✓。
         *   ⚠️ **只动 `applicationId`、不动 `namespace`**：Kotlin 包名（`com.rickyone.palmtv`）是
         *     `libcmgjni.so` 里 `Java_com_rickyone_palmtv_native_*` 这些 JNI 符号的一部分，改了要同步改
         *     native 源码与 CMake ⇒ 风险大且没必要（`namespace`=代码/R 类 与 `applicationId`=安装标识本就可不同）。
         *   ⚠️ 从 `com.RickyOne.PalmTV` 那版换回来 ⇒ 手机里那版要**手动卸载**（它是另一个应用，不会自动替换）。
         *   ⚠️ 更早的 `com.rickyone.palmtv` 老包数据（自定义源 `files/iptv-local.m3u`）在重装后也**不继承**，
         *     需要就先用「从 m3u 文本导入」把清单搬过去。 */
        // ★★ 2026-10-08：「身份档位」变体验证用 —— 允许用 `-PpalmtvAppId=…` 临时改安装标识。
        //   背景（笔记 §17.36）：服务端按 cKey 里的"身份"判"速率档"；我们 628（混合身份）只有 51 KB/s，
        //   官方 682 是 13,920 KB/s。唯一没试的杠杆 = **包名真的等于官方包名**（身份自洽）。
        //   ⚠️ 变体包与官方 app **不能共存**（同一 applicationId）⇒ 只能在"临时卸载官方 app"时验证。
        //   ⚠️ 正常出包**不要**传这个参数（默认仍是 com.rickyone.palmtv）。
        applicationId = (project.findProperty("palmtvAppId") as String?) ?: "com.rickyone.palmtv"
        minSdk = 24
        targetSdk = 35
        /* ★ 2026-11-10：版本号三端统一为 **3.11.10**。
         *   versionCode 与鸿蒙 `app.json5` 的约定一致（major*1e6 + minor*1e3 + patch）
         *   ⇒ 3.11.10 = **3011010**（2.0.0 曾是 2000000）。 */
        versionCode = 3011010
        versionName = "3.11.10"

        // ★ 手机端出 arm64；★ 2026-10-01 追加 x86_64 以便在 **MuMu 模拟器**（x86_64，Android 15）里原生运行：
        //   本模块的 C 核是纯 C（`-DANDROID_STL=none`），编 x86_64 无任何依赖问题；
        //   代价只有多一份很小的 `.so`（真机仍然用 arm64-v8a，多出来的那份不会被加载）。
        //
        // ★★ 2026-10-04（用户实测：**创维电视 U 盘安装报"应用未安装"**）★★ 追加 **armeabi-v7a**：
        //   现象：电视上"允许未知来源"已开、安装器也读出了 APK（图标 + 大小都显示了）⇒ 却报"应用未安装" ✗
        //   ⇒ 这不是权限问题，是**包校验**被拒；而**创维/酷开等电视绝大多数是 32 位 ARM 系统**
        //     （芯片是 64 位，但 system userland 是 32 位）⇒ 我们只有 arm64-v8a / x86_64 两份 `.so`，
        //     在那种机器上**没有一份能加载** ⇒ PackageManager 直接判 `INSTALL_FAILED_NO_MATCHING_ABIS`
        //     （各家安装器统一显示成"应用未安装"）。
        //   ⇒ 现在三份都带：`arm64-v8a`（手机/TV 主流）、`armeabi-v7a`（32 位电视/老盒子）、`x86_64`（MuMu 模拟器）。
        //     ⚠️ 代价：多一份约 0.5 MB 的 32 位 `.so`（不会被 64 位设备加载，纯粹为兼容老机器）。
        //     ⚠️ 32 位 ARM 只是"能编出来"，**本机没有 32 位 ARM 设备可验证运行时** —— 首次真机验证靠电视实测；
        //        若老电视上出现解密/播放异常，先怀疑这里（wasm2c 运行时在 32 位宿主上的指针宽度假设）。
        //   ⇒ 正式发版若要"只留 arm64"，删掉这两行里的其他项再出包即可（或用 `splits.abi` 拆包）。
        /* ★★ 2026-10-07（央视频「安卓平台」cKey）：允许临时收窄 ABI ★★
         *   新增的 `jniLibs/arm64-v8a/libckeygenerator.so` 是**官方 APK 里的预编译 arm64 .so**
         *   （没有 x86_64/armeabi-v7a 版本）。而 PackageManager 只按 `primaryCpuAbi` 挑一个 lib 目录
         *   ⇒ 若 APK 里同时存在 `lib/x86_64/`，在 MuMu 上 primaryCpuAbi 会被定成 x86_64，
         *     那个 arm64 的 .so **根本不会被解出来**，`System.loadLibrary` 必失败。
         *   而官方 app 之所以能在 MuMu 跑，正是因为它的 APK **只有 arm64** ⇒ primaryCpuAbi=arm64-v8a
         *   ⇒ 进程整个跑在 MuMu 的 Houdini(原生桥) 之下。
         *   ⇒ 本地用 MuMu 验证时这样出包：`-PpalmtvAbi=arm64-v8a`（正式包不带这个参数，仍是三 ABI）。 */
        val abiOverride = (project.findProperty("palmtvAbi") as String?)
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
        ndk {
            abiFilters += (abiOverride ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64"))
        }
        externalNativeBuild {
            cmake {
                // ★ 本模块源全是 C ⇒ 不要 C++ 运行时（与鸿蒙的 -DOHOS_STL=none 同思路）
                // ★★ 2026-10-04（用户实测：创维电视 Android 8.1 / 32 位 CPU 上"画面卡跳严重"）★★
                //   加 `-DANDROID_ARM_NEON=ON`：NDK 对 armeabi-v7a 默认只开 VFPv3（**不含 NEON**），
                //   于是 clang 不会为 CMG 解密/AES 那些循环做 NEON 自动向量化 ✗ ⇒ 解密吞吐上不去 ⇒ 卡跳。
                //   ⚠️ 安全性：minSdk 24（Android 7.0）的设备**全部**支持 NEON（Tegra 2 那种无 NEON 的老古董
                //     早就够不到这个 minSdk）⇒ 开它没有兼容风险。
                //   ⚠️⚠️ **2026-10-04 回退（用户真机实测）**：开了 `-O3` + NEON 之后，32 位电视从
                //   "能播但闪" 变成 **"一直缓冲、根本播不出来"** ✗ ⇒ 立刻收回保守配置：
                //     · 优化级别回 **`-O2`**（`-O3` 会做更激进的别名/向量化推断）；
                //     · **去掉 NEON**（未在 32 位 ARM 上验证过，收益不明、风险不明）；
                //     · 另外加 **`-fno-strict-aliasing`** —— wasm2c 生成的代码大量用 `(u32*)`/`(f32*)`
                //       这种"类型双关"，属于严格别名规则的经典违例；在 arm64/x86_64 上侥幸没事，
                //       32 位 ARM 上被误优化的概率明显更高 ⇒ 显式关掉别名假设（这三条都是"先保正确性"）。
                //   ⚠️ 结论：**没在真机 32 位 ARM 上验证过的编译优化，不要往 TV 包里加**。
                arguments += listOf("-DANDROID_STL=none")
                cFlags += listOf("-O2", "-fno-strict-aliasing")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    /* ★★ 2026-10-02（1.2.0 发布）：**正式包必须签名**才能安装/分发 ★★
     *   密钥与口令**都不入库**（见仓库根 `.gitignore` 的 keystore 规则）：
     *     `Android/keystore/palmtv-release.jks`  —— 生成一次后**务必备份**（丢了就无法覆盖升级）
     *     `Android/keystore.properties`         —— storeFile / storePassword / keyAlias / keyPassword
     *   两份都在 ⇒ 用 release 密钥签名；缺任一份 ⇒ **回退到 debug 签名**（保证 `assembleRelease`
     *   在这种机器上也能出包，不会因为缺密钥而编不过 —— 但那种包**只能本地验证**，不要对外分发）。 */
    signingConfigs {
        create("release") {
            val ksFile = rootProject.file("keystore.properties")
            val p = Properties().apply { if (ksFile.exists()) ksFile.inputStream().use { load(it) } }
            val storePath = p.getProperty("storeFile")
            if (!storePath.isNullOrEmpty()) {
                storeFile = rootProject.file(storePath)
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            } else {
                /* 回退：debug 密钥（**仅本地验证**，不要分发）。
                 * ⚠️ 2026-10-02 踩过：`keystore.properties` 若被写成 **带 BOM 的 UTF-8**（PowerShell 5 的
                 *   `Set-Content -Encoding utf8` 就会），第一个键名会变成 `\uFEFFstoreFile` ⇒
                 *   `getProperty("storeFile")` 返回 null ⇒ 这里报 "path may not be null or empty string"。
                 *   写文件请用**无 BOM**（`[IO.File]::WriteAllLines(..., UTF8Encoding($false))`）。 */
                logger.warn("[PalmTV] 未找到可用的 keystore.properties ⇒ 用 debug 密钥签名（仅供本地验证，请勿分发）")
                storeFile = File(System.getProperty("user.home"), ".android/debug.keystore")
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    /* ★★ 2026-10-02（出 1.2.0 正式包时踩到）★★ release 变体会跑 `lintVitalAnalyzeRelease`，
     *   而它需要**额外**依赖 `com.android.tools.lint:lint-gradle:31.7.3` —— 本机构建一直带 `--offline`，
     *   该依赖不在缓存里 ⇒ `assembleRelease` 直接失败（`No cached version ... available for offline mode`）✗。
     *   两个选择：① 联网跑一次把它缓存下来；② 关掉 release 的 lint 检查。
     *   ⇒ 取 ②：debug 变体已在跑 lint，而 release 既不开混淆也不改代码（只换签名/包名）⇒ 收益极低，
     *     关掉可保证**离线也能出正式包**（发布流程不依赖网络）。 */
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // ★ 2026-11-03：`src/main/baseline-prof.txt` 里声明了 Sm4C 的解密热方法 ⇒ 安装时 AOT 编译，
            //   抵消"App 启动后第一片分片解密要 1.5s（ART 冷执行）"的问题（debug 包不适用 AOT，只在 release 生效）。
            // ★ 不开启 R8/ProGuard：三端同类工程都靠"不混淆"换稳定性（Media3/Compose 反射较多），
            //   包体差异可接受；真要开混淆必须先跑一遍真机回归（台标/解密/播控都吃反射）。
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/*.kotlin_module"
        )
        /* ★ 2026-10-12 实验记录（已回退）：曾试过 `jniLibs { useLegacyPackaging = true }`
         *   把 native 库**解压**出来（对齐官方 app 的 `/data/app/…/lib/arm64/` 形态），
         *   用来排查"变体包 628 vs 官方 682 差 43 字符"——**实测无效**（cKey 仍是 628，见 HANDOFF §9.6-H5）。
         *   ⇒ 已恢复 AGP 默认（`extractNativeLibs=false`，库以 `base.apk!/lib/arm64-v8a/…` 形式加载）。 */
    }

    // ★★ 资产：图片全部合并成**一个** `assets/palmres.dat`（2026-10-01，用户要求"打包后文件数不要太多"）★★
    //   原来把 `windows/logos/real` 那 79 张 PNG 直接挂成 assets ⇒ APK 里躺着 79 个散图 + 8 个 drawable 控件图。
    //   现在由 [packPalmRes] 任务把 **79 张台标 + 8 个播放控件图标 + 应用图标 + 版权图标** 打成**单个容器文件**。
    //
    // ★★★ 2026-10-22：**不再挂 `common/assets`** ★★★
    //   那里只有 CMG 解密核的三件套（`eb_prog.bin` 378 KB / `reloc_table.bin` 40 KB / `CMGPlayer.json`），
    //   而解密核已不编进 Android 包、也没有任何代码读它们（`CmgAssets.kt` 已删）⇒ 白白占 ~420 KB。
    //   ⚠️ 那三个文件**不要从仓库删**（桌面/鸿蒙的 `cmg_rt_init` 还要用），只是不进安卓包。
    //   ⇒ 现在 APK 的 assets 里**只有** `palmres.dat` 一个文件。
    //   ⚠️ 输出到 `build/generated/`，**不往仓库里写文件**（避免脏 git 工作区）。
    sourceSets["main"].assets.srcDir(palmResOutDir)

    // ★★ 2026-10-07：**首个手放预编译 .so**（央视频安卓平台 cKey 用）
    //   路径与目录名必须与官方 APK 一致 —— `libckeygenerator.so` 的 JNI 导出符号是
    //     Java_com_tencent_qqlive_tvkplayer_vinfo_ckey_CKeyFacade_GenCKey
    //   所以宿主类的**包名/类名也必须**是 com.tencent.qqlive.tvkplayer.vinfo.ckey.CKeyFacade
    //   （影子类见 src/main/java/com/tencent/qqlive/tvkplayer/vinfo/ckey/）。
    //   ⚠️ 只有 arm64-v8a 一份；`armeabi-v7a`/`x86_64` 上该功能自动降级（见 YspAndroidCKey.available）。
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
}

// ======================================================================
// ★★ 台标 / 控件图标 / 应用图标 ⇒ 单个 `palmres.dat` ★★
// ----------------------------------------------------------------------
// 容器格式（与运行时 `player/Logos.kt`、鸿蒙侧 `palmres.dat` **完全一致**，整数一律**大端**）：
//     magic "PALMRES1\n"（9 字节）
//     u32   条目数
//     重复：u16 名称长度 + 名称(UTF-8，不带扩展名，如 `logo/cctv1`、`ui/play`、`app/icon`)
//           + u32 数据长度 + 数据(原始 PNG 字节)
// 参考实现：桌面端 `windows/publish.ps1` 的 `PLOGO1`（同一思路，仅多了命名空间前缀）。
// ======================================================================
val packPalmRes = tasks.register("packPalmRes") {
    description = "把台标/播放控件图标/应用图标打包成单个 palmres.dat"
    group = "build"

    val repo = project.rootDir.parentFile                     // d:/PalmTV
    val logosDir = File(repo, "windows/logos/real")           // 79 张台标（三端同一批图）
    val mediaDir = File(repo, "harmony/entry/src/main/resources/base/media")  // 控件图标原件（鸿蒙 media/）
    val appIcon = File(project.projectDir, "src/main/res/mipmap-xxxhdpi/ic_launcher.png")
    // ★ 2026-10-02（用户要求）：关于页「版权人：飘渺峰」后面的小图标 ——
    //   源是仓库根的 `版权.ico`（Windows 图标格式，Android 解不了 ✗），已用 `版权.ico` 转出 48×48 PNG
    //   放在仓库根 `copyright.png`（非 ASCII 文件名在 Gradle/Kotlin 里容易出问题，所以用英文名）。
    val copyrightPng = File(repo, "copyright.png")
    // 鸿蒙文件名 → Android 侧的语义名（鸿蒙那张"播放"图标文件名是历史拼写 `plyay.png`，别改成 play.png）
    val ctrl = linkedMapOf(
        "plyay" to "play",
        "pause" to "pause",
        "player_sound_on" to "sound_on",
        "player_sound_off" to "sound_off",
        "fullscreen" to "fullscreen",
        "window" to "window",
        "locked" to "locked",
        "unlock" to "unlock"
    )

    inputs.dir(logosDir).withPropertyName("logos")
    inputs.dir(mediaDir).withPropertyName("media")
    inputs.file(appIcon).withPropertyName("appIcon")
    inputs.file(copyrightPng).withPropertyName("copyrightPng")
    outputs.dir(palmResOutDir).withPropertyName("palmRes")

    doLast {
        val entries = LinkedHashMap<String, ByteArray>()
        logosDir.listFiles { f -> f.isFile && f.extension.equals("png", true) }
            ?.sortedBy { it.name }
            ?.forEach { entries["logo/" + it.nameWithoutExtension] = it.readBytes() }
        ctrl.forEach { (src, dst) ->
            val f = File(mediaDir, "$src.png")
            if (f.isFile) entries["ui/$dst"] = f.readBytes()
            else logger.warn("[packPalmRes] 缺少控件图标: $f")
        }
        entries["app/icon"] = appIcon.readBytes()
        // ★ 2026-10-02：版权图标（关于页用）。缺失只告警不失败 —— 老环境/没放图时应用照常跑（只是不显示图标）
        if (copyrightPng.isFile) entries["app/copyright"] = copyrightPng.readBytes()
        else logger.warn("[packPalmRes] 缺少版权图标（关于页会不显示）: $copyrightPng")

        val out = File(palmResOutDir.get().asFile, "palmres.dat")
        out.parentFile.mkdirs()
        DataOutputStream(BufferedOutputStream(out.outputStream())).use { o ->
            o.write("PALMRES1\n".toByteArray(Charsets.US_ASCII))
            o.writeInt(entries.size)
            entries.forEach { (name, data) ->
                val nb = name.toByteArray(Charsets.UTF_8)
                o.writeShort(nb.size)
                o.write(nb)
                o.writeInt(data.size)
                o.write(data)
            }
        }
        val logoCount = entries.keys.count { it.startsWith("logo/") }
        logger.lifecycle(
            "[packPalmRes] ${out.name}: ${entries.size} 项（台标 $logoCount + 控件 ${ctrl.size} + 应用图标 1）" +
                "，${out.length() / 1024} KB → ${out.absolutePath}"
        )
    }
}

// 让 assets 合并（以及任何构建）之前先产出 palmres.dat
tasks.named("preBuild") { dependsOn(packPalmRes) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }
    .configureEach { dependsOn(packPalmRes) }

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // ★★ 播放器：Media3 (ExoPlayer)，**不做第二套兜底** ★★
    //   HLS + TS 是它的本命；CMG 解密由我们自己的 DataSource「边取边解」，不跑本地 HTTP 服务。
    //   ★ 2026-10-01：1.4.1 → **1.11.1**（最新稳定，2026-09-10）。原因：四平综合那条 IPTV 流会稳定触发
    //     `IllegalStateException @ SampleQueue.sampleMetadata`（→ `ExoPlayerImplInternal: Playback error`,
    //     在 App 里表现为"播放异常，正在恢复(1/3)"）；而 **1.11.0 的 ExoPlayer 修复条目正是
    //     "修复一个时序相关的并发 Bug，可能导致 IllegalStateException / IndexOutOfBoundsException"**。
    //     顺带白拿 1.9.0 的"卡死播放检测"、1.8.0 的"首个错误被误判为持久异常导致无法恢复"等修复。
    val media3 = "1.11.1"
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-exoplayer-hls:$media3")
    implementation("androidx.media3:media3-ui:$media3")
    implementation("androidx.media3:media3-common:$media3")
    // ★ 2026-10-01（用户要求）：**媒体播控卡片** —— 通知栏 / 锁屏 / 耳机按钮上的播放控制（含频道名封面）。
    //   由 `MediaSessionService` 承载（系统媒体卡片的标准做法）⇒ 见 `player/PlaybackService.kt`。
    implementation("androidx.media3:media3-session:$media3")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
