package com.rickyone.palmtv.data

import com.rickyone.palmtv.native.JstvSign

/**
 * 江苏台（荔枝 TV / live.jstv.com）—— 与鸿蒙 `common/JiangsuTv.ets` 一致。
 *
 * 与央视频链路的本质差别：
 *   · 不需要 auth / 签名 / get_live_info：上游地址只靠 `txSecret` 就成立；
 *   · **流是明文的**（不解密，播放器直吃）；
 *   · CDN 校验 Referer / UA ⇒ 每次请求都必须带 [headers]。
 */
object JiangsuTv {

    const val ORIGIN = "https://litchi-play-encrypted-site.jstv.com"
    const val REFERER = "https://live.jstv.com/"
    const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    data class Entry(val streamId: String, val name: String, val path: String)

    /** 频道表（源自桌面 `JiangsuTvProxyService.Channels`；**不含 jswspro**，理由见 ChannelList 注释） */
    val CHANNELS: List<Entry> = listOf(
        Entry("jsws4kpro", "江苏卫视4K", "/4klive/"),
        Entry("jszypro", "江苏综艺", "/applive/"),
        Entry("jsyspro", "江苏影视", "/applive/"),
        Entry("jscspro", "江苏城市", "/applive/"),
        Entry("jsxwpro", "江苏新闻", "/applive/"),
        Entry("jsjypro", "江苏教育", "/applive/"),
        Entry("jsxxpro", "江苏休闲", "/applive/"),
        Entry("jsgjpro", "江苏国际", "/applive/"),
        Entry("ymktpro", "优漫卡通", "/applive/")
    )

    fun find(streamId: String): Entry? = CHANNELS.firstOrNull { it.streamId == streamId }

    /** 上游 m3u8（含一次性签名）；签名失败返回 "" */
    fun upstreamUrl(ch: Channel): String {
        val e = find(ch.streamId) ?: return ""
        val sec = System.currentTimeMillis() / 1000
        val q = JstvSign.signQuery(e.streamId, sec)
        if (q.isEmpty()) return ""
        return "$ORIGIN${e.path}${e.streamId}.m3u8?$q"
    }

    /** 上游请求头（每次上游请求都要带，否则 CDN 可能 403） */
    fun headers(): Map<String, String> = mapOf(
        "Referer" to REFERER,
        "User-Agent" to USER_AGENT,
        "Accept" to "*/*"
    )
}
