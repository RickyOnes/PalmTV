package com.rickyone.palmtv

import android.app.Application
import com.rickyone.palmtv.data.Log

/**
 * 应用级初始化 —— 顺序**不能改**：
 *   ① 资产落盘 → ② `cmgInit` → ③ `setClockReal(true)`（直播/时移必需）→ ④ 签名器就绪
 *
 * ★★★ 2026-10-27（三端同步）：CMG 解密核**回来了，但只服务 8 个 ChinaDRM 加密台** ★★★
 *   其余频道走「移动端链路 + 自研 cKey」的明文流，不需要解密（见 `Channel.needsCmg`）。
 *   保留它的唯一原因：那 8 个台是 SM4-CBC 加密（ChinaDRM），设备证书绑定官方 App 签名指纹，
 *   自研做不出来 ⇒ 只能沿用 CMG。
 *
 * ⚠️ ③ 必须在 ② **之后**（与鸿蒙/桌面逐字一致）。
 */
class PalmTvApp : Application() {

    override fun onCreate() {
        super.onCreate()
        Log.init(this)
        // ④ 自研 cKey / 江苏台签名器（都是 libpalmtv.so 里的纯 C，随首次调用惰性就绪）
        Log.i("[app] 自研 cKey 可用=${com.rickyone.palmtv.native.SelfCKey.available}")
    }
}
