package com.rickyone.palmtv.data

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit

/** 鉴权类错误（token 过期 / 被拒）：调用方应"清 auth 缓存 + 立即重试"，**不要**当网络抖动退避 */
class AuthExpiredException(message: String) : IOException(message)

/**
 * HTTP 客户端 —— 进程内单例（与鸿蒙 `StreamResolver.httpOf()` 同策略：反复 create/destroy 会丢连接池）。
 *
 * ★ 错误分类（照抄鸿蒙 `reqText`，**不要合并**）：
 *   · 401/403        → [AuthExpiredException]（"鉴权失效…"）⇒ 上层立刻作废 token 重试
 *   · 响应体为空      → IOException（含"网络"关键词）⇒ 上层按网络类重试 + 中文提示
 *   · 非 JSON        → IOException（网关/劫持）
 */
object Http {

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    /** 供播放器的 DataSource 复用（不要另建客户端，否则连接池/预热都白做） */
    fun newRequest(url: String, headers: Map<String, String>): Request =
        Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }.build()

    fun getText(url: String, headers: Map<String, String>, timeoutMs: Long): String =
        exec(newRequest(url, headers), timeoutMs)

    fun postForm(url: String, headers: Map<String, String>, form: String, timeoutMs: Long): String {
        val req = Request.Builder()
            .url(url)
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .post(form.toRequestBody(null))
            .build()
        return exec(req, timeoutMs)
    }

    fun postJson(url: String, headers: Map<String, String>, json: String, timeoutMs: Long): String {
        val req = Request.Builder()
            .url(url)
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .post(json.toRequestBody(null))
            .build()
        return exec(req, timeoutMs)
    }

    /** 取二进制（EPG protobuf 用） */
    fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Long): ByteArray {
        client.newBuilder().readTimeout(timeoutMs, TimeUnit.MILLISECONDS).build()
            .newCall(newRequest(url, headers)).execute().use { resp ->
                if (resp.code == 401 || resp.code == 403) {
                    throw AuthExpiredException("鉴权失效（HTTP ${resp.code}，token 已过期或被拒）")
                }
                val body = resp.body ?: throw IOException("网络无响应（HTTP ${resp.code}，响应为空）")
                val bytes = body.bytes()
                if (bytes.isEmpty()) throw IOException("网络无响应（HTTP ${resp.code}，响应为空）")
                return bytes
            }
    }

    /**
     * ★★ 2026-10-02（用户实测：香港卫视 / 金鹰卡通这类**慢源**在安卓被判"无信号"，鸿蒙却播得出来）★★
     *   **预检专用**取数：只回答"源到底有没有响应"，**不把非 2xx / 空响应当异常** ——
     *   `getText` 的语义是"取流失败"（401/403 抛 [AuthExpiredException]、空响应抛 IOException），
     *   而预检要的是"源活不活"，判据完全不同，**不要复用**（复用就是这次的 bug 之一）。
     *   · 网络层失败（连不上 / 超时）仍抛 IOException ⇒ 调用方按"不可达"判死。
     *   · 连接与读取都按传入超时（鸿蒙 `probeIptvSource` 也是 connectTimeout + readTimeout 各给一份）。
     *   · 只窥探前 64 KB（`peekBody` 不消费响应体）⇒ 就算对方返回的是几 MB 的分片也不会整段读下来。
     *  @return HTTP 状态码 to 窥探到的响应体字节数
     */
    fun probeGet(url: String, headers: Map<String, String>, timeoutMs: Long): Pair<Int, Int> {
        val c = client.newBuilder()
            .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .build()
        c.newCall(newRequest(url, headers)).execute().use { resp ->
            val len = try {
                resp.peekBody(64L * 1024L).bytes().size
            } catch (e: Exception) {
                0
            }
            return resp.code to len
        }
    }

    private fun exec(req: Request, timeoutMs: Long): String {
        val c = if (timeoutMs > 0) {
            client.newBuilder().readTimeout(timeoutMs, TimeUnit.MILLISECONDS).build()
        } else client
        c.newCall(req).execute().use { resp: Response ->
            // ★ 鉴权类先判：与"网络抖动"是**完全不同的处理路径**
            if (resp.code == 401 || resp.code == 403) {
                throw AuthExpiredException("鉴权失效（HTTP ${resp.code}，token 已过期或被拒）")
            }
            val text = resp.body?.string().orEmpty()
            if (text.isBlank()) {
                throw IOException("网络无响应（HTTP ${resp.code}，响应为空）")
            }
            return text
        }
    }
}
