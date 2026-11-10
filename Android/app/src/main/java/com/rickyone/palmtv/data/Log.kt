package com.rickyone.palmtv.data

import android.app.Application
import android.content.pm.ApplicationInfo
import android.util.Log as ALog

/**
 * 日志（对应鸿蒙 `common/Log.ets`）：
 *   · `i`（info）只在 debug 包输出 —— release 里静默（与鸿蒙 `BuildProfile.DEBUG` 同口径）；
 *   · `w`/`e` 始终输出（线上定位要靠它们）。
 * native 侧日志走 logcat tag `CMGDec`（`adb logcat -s CMGDec`）。
 */
object Log {

    private const val TAG = "PalmTV"

    @Volatile
    var verbose: Boolean = false
        private set

    fun init(app: Application) {
        // ★ 2026-10-08：定位"限速/绿屏/身份档位"期间曾临时置 true（便于在 release 包里看 `i` 级日志），
        //   现已恢复原状。⚠️ 排查期若再需要，改成 `verbose = true` 即可（发布前务必改回）。
        verbose = (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    fun i(msg: String) {
        if (verbose) ALog.i(TAG, msg)
    }

    fun w(msg: String) {
        ALog.w(TAG, msg)
    }

    fun e(msg: String) {
        ALog.e(TAG, msg)
    }

    fun e(msg: String, t: Throwable) {
        ALog.e(TAG, msg, t)
    }
}
