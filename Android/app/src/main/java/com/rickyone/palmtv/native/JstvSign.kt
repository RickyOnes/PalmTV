package com.rickyone.palmtv.native

/**
 * 江苏台（荔枝 TV / live.jstv.com）签名 —— 纯计算，KEY 在 native 里（`jstv_sign.c`）。
 *
 * 上游地址：`https://litchi-play-encrypted-site.jstv.com{path}{streamId}.m3u8?txSecret=<32hex>&txTime=<8hex>`
 *   txTime   = Unix 秒的小写 8 位十六进制
 *   txSecret = md5hex(KEY + streamId + txTime)
 * ★ 该路流**是明文的**（不解密），但 CDN 校验 Referer/UA ⇒ 请求必须带 `JiangsuTv.headers()`。
 * ★ 2026-10-22：与自研 cKey **编在同一个 `libpalmtv.so` 里**，加载点统一走 [NativeLib]。
 */
object JstvSign {

    /** 签名器是否可用（= `libpalmtv.so` 能否加载）。 */
    val available: Boolean get() = NativeLib.ensureLoaded()

    private external fun nSignQuery(streamId: String, unixSec: Long): String

    /** 返回 `txSecret=<32hex>&txTime=<8hex>`（不含前导 `?`）；失败返回空串。 */
    fun signQuery(streamId: String, unixSec: Long): String =
        if (NativeLib.ensureLoaded()) nSignQuery(streamId, unixSec) else ""
}
