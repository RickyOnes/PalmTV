package com.rickyone.palmtv.native

/**
 * `libpalmtv.so` 的**唯一加载点**（[SelfCKey] / [JstvSign] 两个门面共用）。
 *
 * ★ 2026-10-22：so 名从 `libcmgjni.so` 改为 **`libpalmtv.so`** —— CMG 解密核已完全退出
 *   Android 构建（源码仍在 `common/native`，只是不编进这个库），旧名字会误导人以为还带解密。
 *   同时**两个 so 合并成一个**：原来 `libyspckey.so`（自研 cKey）现在也在同一个库里。
 *
 * ★★ 2026-10-01 实测踩坑（首次装机必崩）★★
 *   门面此前只声明了 `external fun`，但**全工程没有一处 `System.loadLibrary`** ⇒ 真机首启：
 *     java.lang.UnsatisfiedLinkError: No implementation found for int
 *       com.rickyone.palmtv.native.CmgNative.nInit(...) - is the library loaded, e.g. System.loadLibrary?
 *   ⚠️ 区分两种报错（省排查时间）：**dlopen 失败**会说 `dlopen failed: ...`（so 本身/依赖有问题，比如
 *      架构不匹配、依赖的其它 .so 缺失）；上面那句只说明"**根本没人加载过**"。
 *
 * ★ 这里**刻意不抛异常**：它可能在 `Application.onCreate` 里被调用，抛出去就是"一启动就崩 + 系统弹窗"（实测）；
 *   而 `SelfCKey.available` / `JstvSign.signQuery` 本来就设计成"失败返回 false/空串、上层记日志 + 提示"
 *   ⇒ 让它们拿到 false 更符合原设计（与鸿蒙 `bootSequence` 的"native 起不来就提示、不闪退"一致）。
 */
internal object NativeLib {

    private const val NAME = "palmtv"

    private const val NOT_TRIED = 0
    private const val OK = 1
    private const val BAD = 2

    @Volatile
    private var state = NOT_TRIED

    /** 加载失败原因（成功时保持 null）。 */
    @Volatile
    var error: String? = null
        private set

    /** 幂等加载；成功返回 true。失败时 [error] 里有 `异常类: 消息`，**不再抛**。 */
    @Synchronized
    fun ensureLoaded(): Boolean {
        if (state == OK) return true
        if (state == BAD) return false
        return try {
            System.loadLibrary(NAME)
            state = OK
            true
        } catch (t: Throwable) {          // UnsatisfiedLinkError / SecurityException …
            state = BAD
            error = "${t.javaClass.simpleName}: ${t.message}"
            false
        }
    }
}
