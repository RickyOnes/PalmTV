package com.rickyone.palmtv.player

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Config
import com.rickyone.palmtv.data.Log
import com.rickyone.palmtv.data.YspAndroidCKey
import com.rickyone.palmtv.data.YspAndroidLive
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

/**
 * ★ 2026-10-23 诊断工具（**只用于排查，不参与正常播放**）：把某频道首分片**解出一帧**存成 PNG。
 *
 * 目的：确认"绿屏"到底是
 *   · **码流被加密**（解出来的帧就是一片绿/花），还是
 *   · **我们播放链路的 bug**（码流正常，只是没画出来）。
 * 做法：取清单 → 下第一个分片 → `MediaMetadataRetriever` 抓一帧 → 存 `cacheDir/probe.png`
 *      （再 `adb shell run-as com.rickyone.palmtv cat cache/probe.png > x.png` 拉出来看）。
 *
 * 触发：`adb shell am start -n com.rickyone.palmtv/.MainActivity --es debug_id cctv11 --ez dump_frame true`
 */
object FrameProbe {

    private const val TAG = "FrameProbe"
    private const val MAX_SEG_BYTES = 6 * 1024 * 1024

    private fun headers(): Map<String, String> = mapOf(
        "User-Agent" to Config.UA,
        "Accept" to "*/*",
        "Origin" to Config.ORIGIN,
        "Referer" to Config.REFERER,
        "UID" to YspAndroidCKey.GUID
    )

    suspend fun dump(ctx: Context, ch: Channel) {
        try {
            val rp = YspAndroidLive.resolve(ctx, ch.cnlId, ch.pid, null)
            if (rp == null || rp.playUrl.isEmpty()) {
                Log.w("[$TAG] 取流失败 ⇒ 无法抓帧（${YspAndroidLive.lastError}）")
                return
            }
            val h = headers()
            val playlist = get(URI(rp.playUrl).toURL(), h, 64 * 1024)?.toString(Charsets.UTF_8)
            if (playlist == null) {
                Log.w("[$TAG] 清单拉取失败")
                return
            }
            val seg = playlist.lineSequence()
                .firstOrNull { it.isNotBlank() && !it.trimStart().startsWith("#") }?.trim()
            if (seg == null) {
                Log.w("[$TAG] 清单里没有分片")
                return
            }
            val segUrl = URI(rp.playUrl).resolve(seg).toString()
            val bytes = get(URI(segUrl).toURL(), h, MAX_SEG_BYTES) ?: return
            val ts = File(ctx.cacheDir, "probe.ts")
            ts.writeBytes(bytes)
            Log.i("[$TAG] 分片已存 ${ts.absolutePath} ${bytes.size} B")

            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(ts.absolutePath)
                var bmp: Bitmap? = null
                for (t in longArrayOf(0L, 500_000L, 1_000_000L, 2_000_000L)) {
                    bmp = mmr.getFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    if (bmp != null) break
                }
                if (bmp == null) {
                    Log.w("[$TAG] 抓帧失败（retriever 没给出帧）")
                    return
                }
                val png = File(ctx.cacheDir, "probe.png")
                png.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                Log.i("[$TAG] 帧已存 ${png.absolutePath} ${bmp.width}x${bmp.height} 平均色=${meanColor(bmp)}")
            } finally {
                runCatching { mmr.release() }
            }
        } catch (t: Throwable) {
            Log.w("[$TAG] 异常: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** 平均色 + 颜色种类数（"一片绿"的帧：绿分量高、种类少）。 */
    private fun meanColor(b: Bitmap): String {
        var r = 0L; var g = 0L; var bl = 0L; var n = 0L
        val stepX = (b.width / 32).coerceAtLeast(1)
        val stepY = (b.height / 18).coerceAtLeast(1)
        val set = HashSet<Int>()
        var y = 0
        while (y < b.height) {
            var x = 0
            while (x < b.width) {
                val c = b.getPixel(x, y)
                r += (c shr 16) and 0xff
                g += (c shr 8) and 0xff
                bl += c and 0xff
                n++
                set.add(c)
                x += stepX
            }
            y += stepY
        }
        if (n == 0L) return "?"
        return "R=${r / n} G=${g / n} B=${bl / n} 取样色数=${set.size}/$n"
    }

    private fun get(u: URL, hdrs: Map<String, String>, cap: Int): ByteArray? = try {
        val c = (u.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 12000
            hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
        }
        try {
            if (c.responseCode !in 200..299) {
                Log.w("[$TAG] HTTP ${c.responseCode} $u")
                null
            } else {
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(32 * 1024)
                c.inputStream.use { ins ->
                    while (out.size() < cap) {
                        val n = ins.read(buf)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                    }
                }
                out.toByteArray()
            }
        } finally {
            runCatching { c.disconnect() }
        }
    } catch (t: Throwable) {
        Log.w("[$TAG] 下载失败: ${t.javaClass.simpleName}: ${t.message}")
        null
    }
}
