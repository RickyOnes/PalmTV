package com.rickyone.palmtv.player

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.TransferListener
import com.rickyone.palmtv.data.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * ★★★ 2026-10-22：**清单清洗**（把"我们解不开的 `#EXT-X-KEY` 行"剔掉）★★★
 *
 * ## 为什么需要
 * 央视频部分频道的清单（直播 / 时移 / 回看都有）带一行**非标准加密声明**：
 * ```
 * #EXT-X-KEY:METHOD=SM4-CBC,VIDEOFORMAT="H.264",
 *            KEYFORMAT="urn:uuid:3d5e6d35-…",URI="data:…ps2h…"
 * ```
 * ExoPlayer 的 HLS 解析器只认 `NONE / AES-128 / SAMPLE-AES / SAMPLE-AES-CENC / SAMPLE-AES-CTR`
 * ⇒ 直接 `ParserException: Couldn't match METHOD=…` ⇒ `ERROR_CODE_PARSING_MANIFEST_MALFORMED`
 * ⇒ 播放器反复重建、永远不出画。
 *
 * **但这些频道是能播的**：分片本来就是**明文 MPEG-TS**（头 4 字节 `47 40 00 10`，历史上实测过；
 * 用户也确认官方 App 与旧 CMG 版本都能播）⇒ 那行 tag 对这条链路没有意义，属于"多贴了一张封条"。
 *
 * ## 历史对照（别重复踩）
 * 2026-10-07 的 `CmgDataSource.open` 里就有这段逻辑（"只剔非标准 METHOD 那一行，标准 AES 行原样保留"）；
 * 2026-10-22 删 CMG `CmgDataSource` 时**把它一起带走了** ⇒ 这些频道立刻变成"一进就报错"。
 * 所以现在把它作为**独立的 DataSource 包装**留下来，与解密/明文无关，只做"清单清洗"。
 *
 * ## 实现要点
 * - 我们拿到的地址**没有 `.m3u8` 后缀**（形如 `…/tcloud.cctv.com/<TOKEN>`）⇒ 不能用扩展名判断，
 *   改成 **peek 首 7 字节是否 `#EXTM3U`**；
 * - 清单很小（几 KB），整段读进内存改写；分片走**直通 + 预读的 7 字节回放**，不额外拷贝大块数据；
 * - 只删"不认识的 METHOD"整行，标准 `AES-128` 等**必须保留**（否则真加密的流会坏）。
 */
class PlainHlsDataSourceFactory(
    private val delegate: DefaultHttpDataSource.Factory
) : DataSource.Factory {

    override fun createDataSource(): DataSource = PlainHlsDataSource(delegate.createDataSource())

    /** 换台时要更新请求头 —— 与原来的 `DefaultHttpDataSource.Factory` 用法保持一致。 */
    fun setUserAgent(ua: String?): PlainHlsDataSourceFactory {
        delegate.setUserAgent(ua)
        return this
    }

    fun setDefaultRequestProperties(headers: Map<String, String>): PlainHlsDataSourceFactory {
        delegate.setDefaultRequestProperties(headers)
        return this
    }
}

/** 见 [PlainHlsDataSourceFactory] 的说明。 */
private class PlainHlsDataSource(private val upstream: DataSource) : DataSource {

    /** 清单改写后的正文（非清单请求时恒为 null）。 */
    private var playlist: ByteArrayInputStream? = null

    /** 非清单请求时，`open()` 里 peek 到的几个字节要先吐回去。 */
    private var pending: ByteArray? = null
    private var pendingPos = 0

    /** ⚠️ 必须**自己记住** uri/响应头：`DefaultHttpDataSource` 在 `close()` 之后这两个都会变 null，
     *  而 ExoPlayer 的 HLS 源会在 open 之后（甚至 close 之后）读 `getUri()` 来解析清单里的相对分片地址
     *  ⇒ 返回 null 就是 `Loader$UnexpectedLoaderException: Unexpected NullPointerException`（实测踩到）。 */
    private var selfUri: Uri? = null
    private var headers: Map<String, List<String>> = emptyMap()

    override fun open(dataSpec: DataSpec): Long {
        playlist?.close()
        playlist = null
        pending = null
        pendingPos = 0
        selfUri = dataSpec.uri

        val length = upstream.open(dataSpec)
        headers = runCatching { upstream.responseHeaders }.getOrDefault(emptyMap())
        // peek 前 7 字节判断是不是清单（"#EXTM3U"）
        val head = ByteArray(7)
        var got = 0
        while (got < head.size) {
            val n = upstream.read(head, got, head.size - got)
            if (n <= 0) break
            got += n
        }
        val isPlaylist = got == head.size && String(head, Charsets.UTF_8) == "#EXTM3U"
        if (!isPlaylist) {
            // 分片：把 peek 的字节还回去，后续全部直通
            pending = if (got > 0) head.copyOf(got) else null
            return length
        }

        // 清单：读完 → 清洗 → 以内存流的长度作为长度
        val buf = ByteArrayOutputStream(64 * 1024)
        buf.write(head, 0, got)
        val tmp = ByteArray(16 * 1024)
        while (true) {
            val n = upstream.read(tmp, 0, tmp.size)
            if (n <= 0) break
            buf.write(tmp, 0, n)
        }
        upstream.close()
        val text = String(buf.toByteArray(), Charsets.UTF_8)
        val cleaned = HlsPlaylistCleaner.stripUnsupportedKeys(text)
        if (cleaned != text) {
            Log.i("[hls] 清单已清洗：剔掉 ${HlsPlaylistCleaner.countUnsupportedKeys(text)} 行不支持的 #EXT-X-KEY")
        }
        val bytes = cleaned.toByteArray(Charsets.UTF_8)
        playlist = ByteArrayInputStream(bytes)
        return bytes.size.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        playlist?.let { return it.read(buffer, offset, length) }
        pending?.let { p ->
            if (pendingPos < p.size) {
                val n = minOf(length, p.size - pendingPos)
                System.arraycopy(p, pendingPos, buffer, offset, n)
                pendingPos += n
                if (pendingPos >= p.size) pending = null
                return n
            }
            pending = null
        }
        return upstream.read(buffer, offset, length)
    }

    override fun getUri(): Uri? = selfUri

    /** `DataSource` 接口成员（Media3 用它做诊断/DRM 判定）；用 open 时缓存的副本。 */
    override fun getResponseHeaders(): Map<String, List<String>> = headers

    /** 带宽/耗时统计直接挂到上游 HTTP 源上（我们这层只改写清单正文，没有自己的统计）。 */
    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun close() {
        playlist?.close()
        playlist = null
        pending = null
        pendingPos = 0
        upstream.close()
    }
}

/** 清单清洗规则（纯函数，方便单测/日志）。 */
object HlsPlaylistCleaner {

    /** ExoPlayer 认识（`DefaultHlsPlaylistParser` 的 METHOD 白名单）。 */
    private val SUPPORTED = setOf(
        "NONE", "AES-128", "SAMPLE-AES", "SAMPLE-AES-CENC", "SAMPLE-AES-CTR"
    )

    private val METHOD = Regex("METHOD=([^,\\s]+)", RegexOption.IGNORE_CASE)

    private fun unsupported(line: String): Boolean {
        if (!line.trimStart().startsWith("#EXT-X-KEY", ignoreCase = true)) return false
        val m = METHOD.find(line)?.groupValues?.get(1) ?: return false
        return m.uppercase() !in SUPPORTED
    }

    fun countUnsupportedKeys(playlist: String): Int =
        playlist.lineSequence().count { unsupported(it) }

    /**
     * 剔掉**非标准 METHOD** 的 `#EXT-X-KEY` 整行；其余行一字不改（含标准 AES-128）。
     * ⚠️ 分行时保留原换行风格：用 `split("\n")` 再补回 `\n`，避免把 `\r\n` 清单改成 `\n` 之外的意外差异。
     */
    fun stripUnsupportedKeys(playlist: String): String {
        if (!playlist.contains("#EXT-X-KEY", ignoreCase = true)) return playlist
        val sb = StringBuilder(playlist.length)
        var changed = false
        for (raw in playlist.split("\n")) {
            if (unsupported(raw)) {
                changed = true
                continue        // 丢掉这一行（注意：行尾的 \r 也随之丢掉）
            }
            sb.append(raw).append('\n')
        }
        if (!changed) return playlist
        // 去掉最后多加的一个换行（原清单通常以换行结尾，这里保持一致即可，播放器不敏感）
        return sb.toString()
    }
}
