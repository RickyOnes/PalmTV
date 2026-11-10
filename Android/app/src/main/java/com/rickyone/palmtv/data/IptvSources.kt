package com.rickyone.palmtv.data

import java.net.URI

/**
 * 自定义 IPTV 源 —— **逐条对齐桌面端** `windows/IptvChannels.cs` + `IptvSourceWindow.xaml.cs`
 * （鸿蒙无此机制；桌面端是基准）。
 *
 * ★★ 2026-10-02（用户反馈"安卓自定义源问题没解决，要同步桌面端逻辑"）★★
 *   原来只移植了 **UI 外壳**：存 SharedPreferences 里的私有 JSON、无校验、无去重 ⇒ 桌面端那套核心逻辑全缺。
 *   现在补齐（每条都能在桌面代码里找到对应）：
 *     · **持久化 = m3u 文本**（同名同格式，见 [toM3u]/[parseM3u]）⇒ 两端内容可直接互拷；
 *     · 解析只认 `#EXTINF` 配对的 URL 行、跳过 `#` 注释、**自动剥离 `(720p)` 之类后缀**
 *       （桌面 `LoadFile` 的正则 `\s*\((?:\d{3,4}p)\)\s*$`）；
 *     · 校验 URL 必填且必须 `http://`/`https://`（桌面 `Validate()` 的两条）；
 *     · 空名 ⇒ **取域名**（桌面 `new Uri(url).Host`，取不到才用 "IPTV"）；
 *     · 同 URL 去重（添加时提示"该地址已在列表里。"）；
 *     · 并表时**内置优先**：用户条目与内置 15 条同 URL 则不重复加入（桌面 `Load()` 的 `seen` 集合）。
 */
object IptvSources {

    data class Entry(val name: String, val url: String)

    /** 桌面 `Validate()`：URL 必填 + 必须 http(s)。返回 null 表示通过，否则是给用户看的中文错误。 */
    fun validateUrl(url: String): String? {
        val u = url.trim()
        return when {
            u.isEmpty() -> "请填写播放地址。"
            !u.startsWith("http://", ignoreCase = true) && !u.startsWith("https://", ignoreCase = true) ->
                "播放地址需以 http:// 或 https:// 开头。"
            else -> null
        }
    }

    /** 空名 ⇒ 取域名（桌面 `new Uri(url).Host`）；取不到就用 "IPTV" */
    fun nameOrHost(name: String, url: String): String {
        val n = name.trim()
        if (n.isNotEmpty()) {
            return n
        }
        return try {
            URI(url.trim()).host?.takeIf { it.isNotEmpty() } ?: "IPTV"
        } catch (e: Exception) {
            "IPTV"
        }
    }

    private val QUALITY_SUFFIX = Regex("""\s*\(\d{3,4}[pP]\)\s*$""")

    /** 剥离 `(720p)` / `(1080P)` 之类清晰度后缀（桌面 `LoadFile` 同规则） */
    fun stripQuality(name: String): String = QUALITY_SUFFIX.replace(name, "").trim()

    /** 解析 m3u 文本（桌面 `IptvChannels.LoadFile` 同规则：只认 `#EXTINF` + 地址行配对） */
    fun parseM3u(text: String): List<Entry> {
        val out = ArrayList<Entry>()
        var pending: String? = null
        for (raw in text.split('\n')) {
            val line = raw.trim().trimEnd('\r')
            if (line.isEmpty()) {
                continue
            }
            when {
                line.startsWith("#EXTM3U", ignoreCase = true) -> {}      // 头，忽略
                line.startsWith("#EXTINF", ignoreCase = true) -> {
                    val i = line.indexOf(',')
                    pending = if (i >= 0) line.substring(i + 1).trim() else ""
                }
                line.startsWith("#") -> {}                               // #EXTVLCOPT 等一律忽略
                pending == null -> {}                                    // 没有配对 EXTINF 的裸 URL 跳过（桌面同）
                else -> {
                    val nm = stripQuality(pending).ifEmpty { "IPTV" }
                    out.add(Entry(nm, line))
                    pending = null
                }
            }
        }
        return out
    }

    /** 生成 m3u 文本（与桌面 `IptvChannels.SaveFile` 同格式，含同样的自述注释头） */
    fun toM3u(entries: List<Entry>): String = buildString {
        append("#EXTM3U\n")
        append("# 掌上电视 自定义 IPTV 源（由「关于 → 添加 / 编辑自定义源…」维护；也可用文本编辑器直接改）\n")
        append("# 格式：#EXTINF:-1,频道名  换行  http://.../xxx.m3u8\n")
        append("# ⚠️ 内置的地方台不在本文件里，这里只放你自己加的源。\n")
        entries.forEach { e ->
            append("#EXTINF:-1,").append(e.name).append('\n')
            append(e.url).append('\n')
        }
    }

    /**
     * 解析成 Channel（id = `iptv-u<序号>`，序号**只对保留下来的条目**递增 ⇒ 与桌面 id 口径一致）。
     * @param builtInUrls 内置 IPTV 台的地址集合：命中的用户条目会被跳过（**内置优先**，桌面 `seen` 同义）
     */
    fun toChannels(entries: List<Entry>, builtInUrls: Set<String> = emptySet()): List<Channel> {
        val out = ArrayList<Channel>()
        var n = 0
        for (e in entries) {
            val url = e.url.trim()
            if (url.isEmpty()) {
                continue
            }
            if (builtInUrls.any { it.equals(url, ignoreCase = true) }) {
                continue                                        // 与内置同 URL ⇒ 不加（避免出现两条同一频道）
            }
            if (out.any { it.streamId.equals(url, ignoreCase = true) }) {
                continue                                        // 用户内部同 URL 去重（桌面 seen 集合）
            }
            out.add(
                Channel(
                    id = "iptv-u$n",
                    name = nameOrHost(e.name, url),
                    pid = "",
                    cnlId = "",
                    group = Channel.Group.LOCAL,
                    src = Channel.Src.IPTV,
                    streamId = url
                )
            )
            n++
        }
        return out
    }
}
