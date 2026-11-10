package com.rickyone.palmtv.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/**
 * ★★★★★ 央视频**安卓平台**取流（2026-10-07）★★★★★
 *
 * ★ 2026-10-22 起这是央视频**唯一**的取流链（原来的 web/PC 平台链 `StreamResolver` 已删除 ——
 *   它给出的是 CMG 加密流，端上已无解密核）。这条链路换来三件事：
 *   1. **时移 / 回看**（带 `playbacktime`；web/PC 平台返回的 `_web.m3u8` 恒 404，安卓平台正常）；
 *   2. **明文流**（`encrypt=0`）⇒ 播放端**不触发 CMG 解密**（上层要把它标成 `plain`）；
 *   3. 一次性 GET + 一个 cKey，**不需要** auth / openToken / yspsdksign / get_live_info 那一串。
 *
 * 参数与真机逐字对齐（`re/ysp-android-capture/captures/app-fresh-ckey.json`），并已实测：
 * 直播 / 时移 -10min / 回看 -1h / 回看 -4h 全部 `iretcode=0`，回看拉流 `200` + `#EXTM3U`。
 *
 * ★ 2026-10-22：cKey 已改**纯自研**（`libpalmtv.so`）⇒ **任何 ABI 都能用**（不再限定 arm64）；
 *   失败时 [resolve] 返回 null，并把**上游原因**写进 [lastError]（上层据此走"版权停播/无信号"统一回退）。
 *   ⚠️ 失败后**没有任何回落链路**（web/PC 那条是 CMG 加密流，端上解不了）。
 *
 * ⚠️ 清单里可能带非标准 `#EXT-X-KEY:METHOD=SM4-CBC`（CCTV-11~17 等）—— **分片是明文**，
 *   由播放端 `PlainHlsDataSource` 剔掉那一行即可，**不要**据此判"该频道不可播"。
 */
object YspAndroidLive {

    private const val TAG = "YspAndroidLive"
    private const val HOST = "https://liveinfo.ysp.cctv.cn/"

    /** ★ 2026-10-21：全局最小请求间隔（毫秒）。
     *  服务端对连续 `liveinfo` 会回 `iretcode=32`（连正常直播也一起被拒），实测 5 秒内 6 条就触发。 */
    private const val REQ_MIN_GAP_MS = 900L
    @Volatile
    private var lastReqAtMs = 0L

    /** ★ 2026-10-21：`iretcode=32` 的**最大尝试次数**（含首次）。
     *  实测 32 是间歇性的（跨秒/瞬时），单次成功概率约 50%，3 次后 ≈ 87%，且最坏只多花 0.5 秒。 */
    private const val MAX_ATTEMPTS = 3

    /** ★ 2026-10-21：**频道级"疑似无权限"缓存**（仅 60 秒）。
     *  ⚠️ 早前误判为"该频道无权限"并设 10 分钟，实测发现 `iretcode=32` 是**间歇性**的
     *  （同一频道、同一套参数，前一条 32、后一条就 0）⇒ 更像"fntick 与到达时刻跨秒"。
     *  因此这里只做**短时冷却**（避免刚失败就立刻再撞），并且失败会**短间隔重试 3 次**。 */
    private const val REJECT_TTL_MS = 60 * 1000L
    private val rejectedUntil = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /** 该频道是否近期被判"无权限"（供上层决定是否直接走老链路/直接提示）。 */
    fun isRejected(cnlid: String): Boolean =
        (rejectedUntil[cnlid] ?: 0L) > System.currentTimeMillis()

    /* ------------------------------------------------------------------ */
    /* ★★ 2026-10-22：把"失败原因"带出这一层 ★★                            */
    /*   原来只返回 null，上层只能自己编一句"取流失败（上游未返回播放地址）" ⇒  */
    /*   ① CCTV-10 的 `iretcode=12 应版权方要求…` 被吞掉，走不到"版权"分支 ⇒  */
    /*      不回退、状态栏卡在"取流中…"（用户实测）；                       */
    /*   ② DRM 频道（SM4-CBC）也说不清原因。                                */
    /* ------------------------------------------------------------------ */

    /** 最近一次失败的可读原因（空 = 没有失败）。上层直接拿它当异常文案。 */
    @Volatile
    var lastError: String? = null
        private set

    /** 最近一次的 `iretcode`（0 = 成功；12 = 版权停播；32 = 权限/时效）。 */
    @Volatile
    var lastIretcode: Int = 0
        private set

    /** 自检时是否发现"非标准 DRM 加密"（本端没有对应密钥）。 */
    @Volatile
    private var lastDrmHit = false

    /**
     * 清单里出现了**ExoPlayer 不认识的 `#EXT-X-KEY` METHOD**？
     *
     * 实测（2026-10-22）：CCTV-11~17（13 除外）/ CCTV-4K 的清单带
     * `#EXT-X-KEY:METHOD=SM4-CBC,KEYFORMAT="urn:uuid:3d5e6d35-…"`（ps2h/sm4c 元数据），
     * ExoPlayer 只认 NONE / AES-128 / SAMPLE-AES* ⇒ `PARSING_MANIFEST_MALFORMED`。
     * ⚠️ 但**分片是明文 TS**，这行只是多贴的封条 ⇒ **只用于日志**（自检不再据此判死），
     * 真正处理它的是播放端 `PlainHlsDataSource`（剔掉该行）。
     *
     * @return 非标准 METHOD（如 `SM4-CBC`）；全部标准则返回 null。
     */
    private fun unsupportedKeyMethod(playlist: String): String? {
        val ok = setOf("NONE", "AES-128", "SAMPLE-AES", "SAMPLE-AES-CENC", "SAMPLE-AES-CTR")
        for (line in playlist.lineSequence()) {
            if (!line.startsWith("#EXT-X-KEY", ignoreCase = true)) continue
            val m = Regex("METHOD=([^,\\s]+)", RegexOption.IGNORE_CASE).find(line)?.groupValues?.get(1)
                ?: continue
            if (m.uppercase() !in ok) return m
        }
        return null
    }

    /** ★ 真机抓包的 UA —— 必须是它（服务端按 UA/平台交叉校验；实测 `qqlive` 可过）。 */
    private const val UA = "qqlive"

    /** 设备能力描述（真机抓包值）。⚠️ 抓包里这串曾被换行折行，实测**带折行也能过** ⇒ 说明服务端不严校验；
     *  这里用**清洗过的单行**版本（干净且更安全）。 */
    private const val SPVCODE =
        "MSgzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MHwzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MCk7" +
            "MigzMDoxNDQwLDYwOjEwODAsOTA6NzIwLDEyMDo3MjB8MzA6MTQ0MCw2MDoxMDgwLDkwOjcyMCwxMjA6NzIwKQ=="

    /** estid（真机 est 文件内容）—— 官方客户端身份字段之一，实测与本项目自算的 cKey 搭配可过。 */
    private const val ESTID =
        "zg+Ym3rNTnD6DWvhotJfotqgIWJ4Ihv5ouS3Ht1hDVeVyxYbTsD6Htm5HtDjIhAjHai="

    /** ★★★★★ 2026-10-07（笔记 §17.32）：**直播也走本链路** —— 用"时移 [LIVE_SHIFT_SEC] 秒"的方式。★★★★★
     *
     * 实测（`scripts/159-playback-now.py`）：
     * ```
     * 不带 playbacktime        → 服务端给"直播 CDN"地址（hlslive*-cdn / live-dtocnc-cdn）
     *                            ⇒ 我们的 cKey 拿到的 token 被 CDN **403**（那是官方客户端的"档位"问题）
     * playbacktime = now-20s   → 服务端给 **tlivecloud-playback-cdn** 地址
     *                            ⇒ **清单 200 + 首个分片 206（真 MPEG-TS）**，且 `encrypt=0` = **明文**
     * playbacktime = now-60s / now-5min → 同样 200/206 ✓
     * ```
     * ⇒ 于是"直播"以**时移 20 秒**请求本链路即可：既是明文、又不需要 CMG 解密核；
     *   代价只是比真·直播**晚约 20 秒**（IPTV 场景可接受，且老链路本来也有缓冲延迟）。
     * ⚠️ 偏移量的**实测边界**（`scripts/160-shift-bisect.py`）：`Δ ≤ 8s` 时服务端仍给"直播 CDN"（403），
     *   **`Δ = 9s` 起就给 playback CDN（200）** —— 该边界与清单的 `#EXT-X-TARGETDURATION:12` 结构性相关
     *   （要等**至少一个完整分片**落地）。这里取 **10 秒**（边界 + 1 秒余量）。
     * ⚠️ 若某天失效，本链路的自检会失败并**自动回落**老链路。
     * ⚠️ 与"节目单回看"的区别：回看传的是**节目开始时刻**，这里传的是"现在 - LIVE_SHIFT_SEC"。 */
    private const val LIVE_SHIFT_SEC = 10L

    /** ★ 2026-10-23：命中"受保护变体"（清单带 `METHOD=SM4-CBC`）时**最多再重取几次**。
     *  实测同一个频道会在 `live-dtocnc-cdn`（明文）与 `hlsliveali-cdn`（加密）之间随机落点 ⇒ 重取能换到明文。 */
    private const val DRM_RETRY_MAX = 2

    /**
     * 与抓包逐字一致的固定参数（会随请求动态替换：`cKey`/`fntick`/`guid`/`cnlid`/`livepid`/`randnum`/
     * `flowid`，回看再追加 `playbacktime`）。
     * ⚠️ `stream=3`（web 链路是 2）、`sdtfrom=v5028`（凭据包里是 v5082 —— **请求体用 5028、cKey 里用 5082**，别搞反）。
     */
    /* ★ 2026-10-22：**`spdrm` 必须是 2**（声明"支持 DRM"）。
     *   实测把它改成 0（= 不支持 DRM）⇒ 服务端直接 `iretcode=57 版权限制无法播放，请升级至最新版本`
     *   ⇒ 这是"客户端能力声明"，不是开关。
     *
     * ★★★ 2026-10-23（抓帧实测，结论已两次修正，以本次为准）★★★
     *   同一个频道，服务端会**随机**给两种变体（按落点 CDN 区分）：
     *     · `live-dtocnc-cdn` / `mobilelive*-cdn`：清单带 `#EXT-QQHLS-*` 标签，**明文**，正常出画；
     *     · `hlsliveali-cdn`：清单带 `#EXT-X-KEY:METHOD=SM4-CBC`（ChinaDRM，`enschma":"sm4c"`），
     *       **视频切片是密文** —— 用系统解码器抓帧实测：整帧纯绿 `R=0 G=134 B=0`、576 采样仅 5 种颜色；
     *       同一流程 CCTV-13 抓帧是正常画面 `R=76 G=76 B=80 / 511 种颜色`。
     *   ⇒ 所以"绿屏"= 命中了加密变体，**不是**我们的播放/解析问题；
     *     `PlainHlsDataSource` 剔掉 KEY 行只能让清单解析通过，密文照样解不出画面。
     *   ⇒ 对策：**重取直到拿到明文变体**（见 self-check 里的 `DRM_RETRY_MAX` 分支）。 */
    private val BASE = linkedMapOf(
        "spacode" to "23", "app_version" to "305030", "spwm" to "2", "hevclv" to "26",
        "platform" to YspAndroidCKey.PLATFORM, "sdtfrom" to "v5028", "stream" to "3",
        "sphttps" to "0", "spdynamicrange" to "1", "refer_pageId" to "page_tv_500102",
        "wxopenid" to "", "spdemuxer" to "14", "spvcode" to SPVCODE, "sphdrfps" to "60",
        "qq" to "", "defnsrc" to "3", "estid" to ESTID,
        // ★★ 2026-11-04 实验结论（已回退）：`defn` 改成 `4k` 请求 4K 档，服务端**仍然回 `fhd`**
        //   （实测 `取流 OK defn=fhd` + `videoSize=1920x1080`）。
        //   ⇒ **不是我们没请求，是服务端不给这个身份 4K**（我们的 cKey 是 575 档，官方 682 档；
        //     历史结论：档位决定服务端签发的 token 质量/速率，见 `.codebuddy/memory` 的 cKey 系列笔记）。
        //   ⇒ 所以"CCTV-4K 我们只能看 1080p"是**档位限制**，不是参数写错。别再改这个值。
        "appVer" to YspAndroidCKey.CKEY_VER, "defn" to "auto", "encryptVer" to "4.2",
        "spdrm" to "2", "pageId" to "page_tv_500102", "newnettype" to "1",
        "spflvaudio" to "1", "adjust" to "1", "vip_status" to "0", "spflv" to "1",
        "uhd_flag" to "4", "cmd" to "2", "otype" to "json", "caplv" to "1"
    )

    data class Result(
        val playUrl: String,
        val iretcode: Int,
        val defn: String,
        /** 服务端回的 `playback.playbackstart`（= 实际起播时刻，秒）；仅回看/时移有。 */
        val playbackStart: Long
    )

    /**
     * 取流。
     * @param ctx 任意 Context（内部取 applicationContext）
     * @param playbackTime 秒级时刻；**null = 直播**，非 null = 时移/回看（从该时刻起播）
     * @return 成功返回 [Result]；不可用/失败返回 null（**不抛**，交由上层回落）
     */
    suspend fun resolve(
        ctx: android.content.Context,
        cnlid: String,
        livepid: String,
        playbackTime: Long? = null,
        /** ★ 2026-10-08：**真直播被拒时是否退"时移 LIVE_SHIFT_SEC 秒"**（见 self-check 处的级联注释）。
         *  递归兜底时传 false，避免"时移也被拒 → 再退时移"的死循环。 */
        shiftFallback: Boolean = true,
        /** ★ 2026-10-21：内部重试序号（0 = 首次）。`iretcode=32` 是**间歇性**的，最多试 [MAX_ATTEMPTS] 次。 */
        attempt: Int = 0,
        /** ★ 2026-10-21：改用**官方 `.so`** 算 cKey（自研 cKey 被服务端抽样拒绝时的兜底）。 */
        officialCkey: Boolean = false,
        /** ★ 2026-10-23：**"受保护变体"重取计数**（见 self-check 里的 DRM 分支）。 */
        drmRetry: Int = 0,
        /** ★★★ 2026-10-27（三端同步）：该频道是否属于 8 个 ChinaDRM 加密台（`Channel.needsCmg`）。
         *  · false ⇒ 拿不到明文就如实报错（原来行为）；
         *  · true  ⇒ **加密流也照收**，交给 `CmgDataSource` 用 CMG 解密（`plainChannel=false`）。 */
        needCmg: Boolean = false,
        /**
         * ★ 2026-11-03：回看/时移的**结束时刻**（秒）。
         *   带上它 ⇒ 服务端返回**整段 VOD 清单**（`#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST`），
         *   而不是只有 5 片的滚动窗口。实测：5 片 → 302 片（整档节目）。
         */
        endTime: Long? = null
    ): Result? = withContext(Dispatchers.IO) {
        try {
            // 每次尝试都重置失败原因（递归重试时以**最后一次**的结论为准）
            lastError = null
            lastIretcode = 0
            lastDrmHit = false
            // ★★★★★ 2026-10-21：节流 + 短冷却 ★★★★★
            //   `iretcode=32` 实测是**间歇性**的（同参数前一条 32、后一条 0），既与"跨秒"有关，
            //   也会被短时间连发放大 ⇒ 首次尝试前保证 ≥900ms 间隔，内部重试只等 250ms。
            // 短时冷却（刚失败过就先别再撞；只有首次尝试才检查）
            if (attempt == 0 && isRejected(cnlid)) {
                Log.i("[$TAG] $cnlid 刚失败过（冷却 ${REJECT_TTL_MS / 1000}s）⇒ 跳过本条链路")
                lastError = "该频道刚被服务端拒绝，请稍后再试"
                return@withContext null
            }
            // 全局节流只作用于**首次尝试**；内部重试间隔由 250ms 控制（避免把重试也拖成 900ms）
            if (attempt == 0) {
                val gap0 = REQ_MIN_GAP_MS - (System.currentTimeMillis() - lastReqAtMs)
                if (gap0 > 0) kotlinx.coroutines.delay(gap0)
            }
            lastReqAtMs = System.currentTimeMillis()
            val tStart = System.currentTimeMillis()
            val nowSec = System.currentTimeMillis() / 1000
            // ★ cKey 的 ts 与请求的 fntick 必须"同一时刻"（服务端校验时效）
            val ck = YspAndroidCKey.genCKey(ctx, nowSec, cnlid)
                ?: return@withContext null

            val q = LinkedHashMap<String, String>()
            q.putAll(BASE)
            q["cKey"] = ck
            q["fntick"] = nowSec.toString()
            q["guid"] = YspAndroidCKey.GUID
            q["cnlid"] = cnlid
            q["livepid"] = livepid
            q["randnum"] = "%.16f".format(kotlin.random.Random.nextDouble())
            q["flowid"] = UUID.randomUUID().toString() +
                System.currentTimeMillis() + "_" + YspAndroidCKey.PLATFORM
            // ★★★ 2026-10-08：**优先真·直播**（不带 playbacktime）—— 因为 cKey 现在带了官方签名
            //   （见 `OfficialPkgContext` + manifest 的 `<queries>`），服务端会给"直播 CDN"地址且**可用**。
            //   只有在真直播自检失败时，才退到"时移 LIVE_SHIFT_SEC 秒"（见下面 self-check 处的级联）。
            if (playbackTime != null) q["playbacktime"] = playbackTime.toString()

            val url = HOST + "?" + q.entries.joinToString("&") {
                URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8")
            }
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = Config.TIMEOUT_FETCH_MS.toInt()
                readTimeout = Config.TIMEOUT_FETCH_MS.toInt()
                setRequestProperty("User-Agent", UA)
                setRequestProperty("UID", YspAndroidCKey.GUID)
            }
            val text = try {
                conn.inputStream.bufferedReader().use { it.readText() }
            } finally {
                runCatching { conn.disconnect() }
            }
            val o = JSONObject(text)
            val code = o.optInt("iretcode", -1)
            val detail = o.optInt("iretdetailcode", 0)
            // ⚠️⚠️ **实测（2026-10-07，MuMu）这个端点的响应是"扁平"的 —— 没有 `data` 包裹**：
            //   {"iretcode":0,"errinfo":"success!","encrypt":0,"defn":"fhd","cnlid":…,
            //    "playback":{…},"playurl":"http://…m3u8?…"}
            //   最初写成 `data.playurl` ⇒ `iretcode=0` 却拿不到地址（Python 探针用的是全文正则，所以没暴露这个坑）。
            //   这里**先根后 data**双取，兼容两种形态。
            val data = o.optJSONObject("data") ?: o
            val playRaw = data.optString("playurl")
                .ifEmpty { o.optString("playurl") }
                .replace("\\u0026", "&")
            /* ★★★★★ 2026-11-03（回看/时移体验的关键）：**给清单 URL 追加 `endtime`** ★★★★★
             *   抓包对比实证（`re/work/range-probe.py`，同一个 token 只改参数）：
             *     · 只带 `starttime`            ⇒ 5 个分片（滚动窗口 ≈10s），播完要等下一片 ⇒ 周期性卡；
             *     · 再带 `endtime=起始+600`     ⇒ **302 个分片**，且返回
             *       `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST` ⇒ **整段点播流**，可连续播、可拖动。
             *   ⇒ 回看/时移一律带上 `endtime`（= 该节目的结束时刻，追到直播沿就用"现在"）。
             *   ⚠️ 只在有时移(playbackTime)时加：直播链路加它会变成"从某时刻到某时刻的点播"，语义就错了。 */
            val play = if (playbackTime != null && endTime != null &&
                endTime > playbackTime + 5 && !playRaw.contains("endtime=", true)
            ) {
                playRaw + (if (playRaw.contains('?')) "&" else "?") + "endtime=$endTime"
            } else {
                playRaw
            }
            val defn = data.optString("defn").ifEmpty { o.optString("defn") }
            val pbStart = (o.optJSONObject("playback") ?: data.optJSONObject("playback"))
                ?.optLong("playbackstart", 0L) ?: 0L
            if (code != 0 || play.isEmpty()) {
                // ⚠️ 把原始响应打出来：`iretcode=0 但 playurl 空` 时只有它能定位（字段改名/结构变化/被代理改写）
                Log.w(
                    "[$TAG] 取流失败 iretcode=$code detail=$detail cnlid=$cnlid pb=$playbackTime" +
                        " bodyLen=${text.length} body=${text.take(320)}"
                )
                // ★ 2026-10-22：把上游 `errinfo`（如"应版权方要求，暂停提供直播信号…"）带出去 ——
                //   上层靠它走"版权停播 ⇒ 回退原台 + 统一提示"分支（原来只编了句通用文案，用户实测不回退）。
                lastIretcode = code
                lastError = o.optString("errinfo").trim()
                    .ifEmpty { "取流失败（iretcode=$code）" }
                // ★★★★★ 2026-10-21：**iretcode=32 重试一次** ★★★★★
                //   现象：冷启动后第一个请求偶发 32（`detail=-10 权限验证失败`），紧接着的请求就正常。
                //   成因：cKey 里的 fntick 与请求的 fntick 取自同一个秒值，但**跨秒**或服务端时钟有偏差时
                //        会被判"票据过期/时序不符"。
                //   做法：等一下（跨过秒边界）→ **重新生成 cKey**（新 fntick）→ 同参数重试一次。
                //   ⚠️ 只重试一次（retry32=false 防死循环）；回看/时移同样适用。
                // ★★ 2026-10-22：**`12` 也是间歇性的，必须一起重试** ★★
                //   实测：CCTV-8 偶发 12（同一频道隔一秒再请求就 0）⇒ 上一版把 12 当"确定性版权停播"、
                //   一次就判死 ⇒ 用户实测"CCTV-8 也被判死了"。真·版权停播（CCTV-10）会**连续**返回 12，
                //   重试只是多花 ~0.5 秒（内部 3 次），不影响最终结论，但能救回瞬时误判。
                if (code == 32 || code == 12) {
                    // ★★★ 2026-10-22：**兜底机制已全部删除** ★★★
                    //   原来这里是三段兜底（自研 cKey → 官方 .so 的 cKey → 上层老 CMG 链路）。
                    //   现在只有自研一条：32 就跨秒重算重试，重试用尽如实报错，不再偷偷换链路。
                    if (attempt < MAX_ATTEMPTS - 1) {
                        kotlinx.coroutines.delay(250)    // 只为跨过秒边界；不叠加全局节流
                        Log.i(
                            "[$TAG] iretcode=32（detail=$detail）⇒ 第 ${attempt + 2}/$MAX_ATTEMPTS 次尝试" +
                                " cnlid=$cnlid pb=$playbackTime"
                        )
                        return@withContext resolve(
                            ctx, cnlid, livepid, playbackTime, shiftFallback, attempt + 1,
                            endTime = endTime
                        )
                    }
                    rejectedUntil[cnlid] = System.currentTimeMillis() + REJECT_TTL_MS
                    Log.w("[$TAG] $cnlid 连续 ${MAX_ATTEMPTS} 次 32 ⇒ 冷却 ${REJECT_TTL_MS / 1000}s")
                }
                return@withContext null
            }
            // ★★★ 安全闸：新链路拿到的地址**必须自检"真的能播"**才交给播放器 ★★★
            //   为什么必须有：本链路是"接管"性质的（成功就顶掉原来的 web/PC 链路）。
            //   2026-10-07 实测踩过：cKey + liveinfo 全成功、`encrypt=0` 也对，但**分片被 CDN 403**
            //   ⇒ 播放器起不来，反而比"用老链路"更差（用户当场发现"改完不能播了"）。
            //   ⇒ 自检（清单 2xx 且含 #EXTM3U + 首个分片 2xx）不过就返回 null，由上层静默回落老链路。
            //   ⚠️ 回看/时移（playbackTime != null）时老链路**给不出回看**，所以那时不能静默回落，要抛错。
            // ★★★★★ 2026-10-21（用户质问"为什么自检带宽闸"）★★★★★
            //   结论：**去掉**。理由：
            //   ① 那个"52 KB/s 限速"是 **575 档 cKey**（无官方签名）时代的产物；现在用 682 档，
            //      实测带宽 4000+ KB/s（见历史日志），这道闸只会**误杀 + 每次换台多花 1.5 秒**。
            //   ② 官方 App 取流时**不做任何带宽探测**，拿到地址直接播 —— 要达到同样的响应速度就不能有它。
            //   只保留"清单 2xx 且含 #EXTM3U + 首个分片 2xx（Range 2KB）"这个**廉价**自检。
            if (!probePlayable(play, checkRate = false, pid = livepid)) {
                // ★★ 2026-10-22：区分"**用户真要回看**"与"**直播内部的时移兜底**" ★★
                //   内部兜底那次调用也带 `playbackTime`，但 `shiftFallback=false`。
                //   ⚠️ 曾在这里一律按"回看"写原因 ⇒ 直播频道被判成"回看不可用" ⇒ 上层
                //      `backToLive()` 再拉一次直播 ⇒ **无限循环**（用户实测 CCTV-11 反复刷屏）。
                val userReplay = playbackTime != null && shiftFallback
                lastError = if (userReplay) "回看不可用（CDN 拒绝）" else "播放地址不可用（CDN 拒绝）"
                Log.w(
                    "[$TAG] 自检未通过（清单/首个分片不可播）pb=$playbackTime drmTag=$lastDrmHit" +
                        " userReplay=$userReplay ⇒ ${lastError}"
                )
                // ★★★★★ 2026-10-08 级联：**真直播被拒** ⇒ 退"时移 LIVE_SHIFT_SEC 秒"
                //   （走 `tlivecloud-playback-cdn`，不挑档位、且是明文）。
                if (shiftFallback) {
                    Log.w("[$TAG] 真直播不可播 ⇒ 退时移 ${LIVE_SHIFT_SEC}s 再试（明文兜底）")
                    // ★ 2026-10-22：兜底失败时**别用它自己的原因覆盖直播那次** ——
                    //   实测 CCTV-8 的时移请求会偶发 `iretcode=12`，覆盖后用户看到的是"版权停播"，
                    //   而它的直播流其实是好的（重试就能播）。
                    val liveReason = lastError
                    val r = resolve(ctx, cnlid, livepid, nowSec - LIVE_SHIFT_SEC, false)
                    if (r == null) lastError = liveReason ?: lastError
                    return@withContext r
                }
                return@withContext null
            }
            /* ★★ 2026-10-23：命中"**受保护变体**"就重取（换节点）★★
             *   实测：同一频道会在两种变体间随机落点 ——
             *     · `live-dtocnc-cdn`：清单带 `#EXT-QQHLS-*`，**明文**，正常出画；
             *     · `hlsliveali-cdn`：清单带 `#EXT-X-KEY:METHOD=SM4-CBC`，**视频切片是密文**
             *       （抓帧实测整帧纯绿 `R=0 G=134 B=0`、576 采样只有 5 种颜色）。
             *   ⇒ 重新请求一次（新 randnum/flowid，通常换到另一个节点）；仍拿不到明文就如实报错，
             *     不让用户对着绿屏干等。 */
            if (false && lastDrmHit) {   // 2026-10-27: 这些台分片本就是明文（KEY 行是假声明）=> 不再因此放弃
                if (drmRetry < DRM_RETRY_MAX) {
                    Log.w("[$TAG] 命中**受保护变体**（SM4 清单）⇒ 换节点重取 第 ${drmRetry + 2}/${DRM_RETRY_MAX + 1} 次")
                    kotlinx.coroutines.delay(300)
                    return@withContext resolve(
                        ctx, cnlid, livepid, playbackTime, shiftFallback, attempt, officialCkey,
                        drmRetry + 1, needCmg
                    )
                }
                // ★★★ 2026-10-27（三端同步）★★★
                //   原来是"连试 N 次都拿到 SM4 密文 ⇒ 报错不让播"（因为那时没有解密核）。
                //   现在 CMG 解密核回来了：这 8 个 ChinaDRM 台**就该走加密流**，
                //   直接交给 `CmgDataSource`（`plainChannel=false` ⇒ 边取边解）⇒ 不再报错。
                if (!needCmg) {
                    Log.w("[$TAG] 连续 ${DRM_RETRY_MAX + 1} 次都拿到受保护变体 ⇒ 该台暂不可播")
                    lastError = "该频道暂时只下发加密流，请稍后再试"
                    return@withContext null
                }
                Log.i("[$TAG] $cnlid 属于 ChinaDRM 频道 ⇒ 收下加密流，交给 CMG 解密")
            }
            Log.i(
                "[$TAG] 取流 OK defn=$defn pb=$playbackTime start=$pbStart" +
                    " 耗时=${System.currentTimeMillis() - tStart}ms url=${play.take(110)}"
            )
            Result(play, code, defn, pbStart)
        } catch (t: Throwable) {
            Log.w("[$TAG] 取流异常: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    /* ==================================================================
     * ★ 自检：新链路拿到的地址**必须真的能播**才允许"接管"播放
     * ----------------------------------------------------------------
     * 判据 = 清单 2xx 且含 `#EXTM3U`，**并且**首个分片 2xx。
     * 为什么必须验到分片：2026-10-07 实测（MuMu）出现过"**清单 200、分片 403**"的组合 ——
     * 只验清单会误判为成功，然后播放器起不来，白白把好的老链路顶掉。
     * 头必须与播放器**同一套**（`PalmPlayer.yspHeaders()`），否则自检结论对播放器不成立。
     * ================================================================== */
    /**
     * ★★★★ 2026-10-08 临时诊断：**变体定位 stub**（定位完删掉）★★★★
     *
     * 现象：设备侧拉直播分片只有 **1958 字节**（头部像 TS、内容是 `fffd` 填充），
     * 而 PC 上拉同一类 URL 是 **2 MB 真 TS** ⇒ 差异在"设备侧的请求属性"。
     * 这里对同一个 `segUrl` 用不同属性各拉一次，**判据 = Content-Length / 前 8 字节**：
     * 拿到 MB 级 + `47400010…` 的那种，就是我们要的属性组合。
     */
    /** ★ 2026-10-08：变体探测**已完成使命**（结论：设备侧任何头都能拿到真 TS 头，但**整段被限速**到 ~52 KB/s）⇒ 关。 */
    private const val PROBE_VARIANTS = false

    /** ★ 带宽闸：低于这个速率（KB/s）就判定本链路不可用 ⇒ 由上层级联退"时移 10 秒"。
     *  依据：5 秒一个分片 ≈ 2.2 MB ⇒ 需要 ≥450 KB/s；这里取 **120** 作为最低可用线。
     *  ⚠️ 2026-10-21：原值 150 + 512KB/4s 采样 ⇒ **每次换台多花最多 4 秒**（用户实测"换台慢"），
     *     现降为 192KB/1.5s、阈值 120（仍能识别历史上那种 52 KB/s 的限速档，但不再拖慢正常换台）。 */
    private const val MIN_LIVE_KBPS = 120

    /** 带宽闸的采样上限：最多读这么多字节或 [RATE_PROBE_MS] 毫秒，谁先到。 */
    private const val RATE_PROBE_BYTES = 192 * 1024L
    private const val RATE_PROBE_MS = 1_500L

    @Volatile
    private var variantsProbed = false

    private fun probeVariants(segUrl: String, base: Map<String, String>, playUrl: String) {
        Log.i("[$TAG] 变体探测开始 seg=${segUrl.take(90)}  清单=${playUrl.take(60)}")
        fun one(tag: String, hdrs: Map<String, String>) {
            Log.i("[$TAG] 变体 $tag ⇒ ${httpProbe(segUrl, hdrs)}")
        }
        one("① 现状（带 UID，无 Range）", base)
        one("② +Range: bytes=0-", base + ("Range" to "bytes=0-"))
        one("③ +Range: bytes=0-2047", base + ("Range" to "bytes=0-2047"))
        one("④ 去 UID", base - "UID")
        one("⑤ 仅 User-Agent", mapOf("User-Agent" to Config.UA))
        one("⑥ +Connection: close", base + ("Connection" to "close"))
        one("⑦ 去 UID + Range 0-2047", (base - "UID") + ("Range" to "bytes=0-2047"))
        // 另外：**把 token 段去掉**的形式（历史实测那种是 206 真 TS）——对比一下
        runCatching {
            val u = java.net.URI(segUrl)
            val path = u.path.trimEnd('/')
            val name = path.substringAfterLast('/')
            val alt = u.scheme + "://" + u.host + "/" + name + (u.query?.let { "?" + it } ?: "")
            Log.i("[$TAG] 变体 ⑧ 去 token 段 ${alt.take(120)} ⇒ ${httpProbe(alt, base)}")
        }
    }

    /**
     * ★★★★★ 2026-10-08：**带宽闸** —— 实测分片下载速率（KB/s）★★★★★
     *
     * 为什么要它：实测直播 CDN 给我们的 token **被限速到 ~52 KB/s**（2.24 MB/43 s），
     * 而"5 秒一个分片 ≈ 2.2 MB"要求 ≥450 KB/s ⇒ 播放器永远追不上。
     * 只验"清单 200 + 首个分片 206"（2 KB 范围请求）**根本发现不了**这个问题
     * （又一次"自检 ≠ 播放器"），所以必须**真下一小段并计时**。
     *
     * 实现：最多读 `RATE_PROBE_BYTES`(512 KB) 或 `RATE_PROBE_MS`(4 s) 谁先到；
     * 返回 0 = 读不到（当作"不判死"，让后续逻辑照旧处理）。
     */
    private fun measureRateKbps(url: String, hdrs: Map<String, String>): Int {
        val t0 = System.currentTimeMillis()
        var kbps = 0
        try {
            val c = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8_000
                readTimeout = 8_000
                hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
            }
            try {
                if (c.responseCode in 200..299) {
                    var n = 0L
                    val buf = ByteArray(64 * 1024)
                    c.inputStream.use { ins ->
                        while (n < RATE_PROBE_BYTES) {
                            val r = ins.read(buf)
                            if (r <= 0) break
                            n += r
                            if (System.currentTimeMillis() - t0 >= RATE_PROBE_MS) break
                        }
                    }
                    val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1)
                    kbps = ((n / 1024.0) / (ms / 1000.0)).toInt()
                }
            } finally {
                runCatching { c.disconnect() }
            }
        } catch (t: Throwable) {
            Log.i("[$TAG] 带宽闸异常（不判死）: ${t.javaClass.simpleName}: ${t.message}")
        }
        return kbps
    }

    /**
     * ★★★★ 2026-10-08 临时诊断：**把整段分片下完并计时** ★★★★
     * 为什么必须做：先前"只读 64 字节"的变体探测证明**响应头与首块都正常**，但那**不代表整段能下完**。
     * 播放器的请求被取消（`interrupted`）+ 14 秒都等不到视频尺寸 ⇒ 最可能就是**整段下载极慢/卡住**。
     * 判据：实际读取字节数 + 耗时（3.5 MB 正常应 <2 s）。
     */
    private fun fullDownloadProbe(url: String, hdrs: Map<String, String>): String {
        val t0 = System.currentTimeMillis()
        return try {
            val c = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 10_000
                readTimeout = 60_000
                hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
            }
            try {
                val code = c.responseCode
                val cl = c.getHeaderField("Content-Length") ?: "-"
                var n = 0L
                val buf = ByteArray(64 * 1024)
                if (code in 200..299) {
                    c.inputStream.use { ins ->
                        while (true) {
                            val r = ins.read(buf)
                            if (r <= 0) break
                            n += r
                        }
                    }
                }
                "code=$code CL=$cl 实际读=$n 耗时=${System.currentTimeMillis() - t0}ms"
            } finally {
                runCatching { c.disconnect() }
            }
        } catch (t: Throwable) {
            "${t.javaClass.simpleName}: ${t.message} 耗时=${System.currentTimeMillis() - t0}ms"
        }
    }

    /** 只读头部信息（前 64 字节 + `Content-Length`），**不把整个分片读进来**（2 MB 也没关系，我们只读 64 B）。 */
    private fun httpProbe(url: String, hdrs: Map<String, String>): String = try {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 8000
            hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
        }
        try {
            val code = c.responseCode
            val cl = c.getHeaderField("Content-Length") ?: "-"
            val buf = ByteArray(64)
            var n = -1
            if (code in 200..299) {
                val ins = c.inputStream
                n = ins.read(buf)
            }
            val head = (0 until maxOf(n, 0)).take(8).joinToString("") { "%02x".format(buf[it]) }
            "code=$code CL=$cl 首读=$n head=$head"
        } finally {
            runCatching { c.disconnect() }
        }
    } catch (t: Throwable) {
        "${t.javaClass.simpleName}: ${t.message}"
    }

    /**
     * 自检：清单可读 + 无"我们解不开的 DRM" + 首个分片可下（可选带宽闸）。
     *
     * ★ 2026-10-22：从**表达式体**改成**块体** —— 因为要加"DRM 判死"这条提前返回，
     *   而表达式体（`= try { … }`）里**不能用 `return`**（编译报 "Returns are prohibited"）。
     */
    private fun probePlayable(playUrl: String, checkRate: Boolean = true, pid: String = ""): Boolean {
        val h = mapOf(
            "User-Agent" to Config.UA,
            "Accept" to "*/*",
            "Origin" to Config.ORIGIN,
            "Referer" to Config.REFERER,
            "Accept-Language" to "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
            // ★★ 2026-10-08：**必须与播放器同一套头**（否则自检结论对播放器不成立）——
            //   尤其是 `UID`（官方 CDN 请求带它；缺它会"清单 200、分片 403"）。
            "UID" to YspAndroidCKey.GUID
        )
        return try {
            val (pc, pv, m3u8) = httpGet(playUrl, h)
            if (m3u8 == null || !m3u8.contains("#EXTM3U")) {
                Log.w("[$TAG] 自检：清单不可用 code=$pc server=$pv url=${playUrl.take(260)}")
                return false
            }
            // ★ 2026-11-03：这里是**唯一能在 setMediaItem 之前**知道窗口大小的时机
            //   （清单全文就在手上）⇒ 登记给 `PlaylistWindow`，播放器起播时直接用。
            //   否则要等到**第二次** prepare 才能用上自适应偏移（第一次只能用兜底值）。
            if (pid.isNotEmpty()) {
                com.rickyone.palmtv.player.PlaylistWindow.rememberFromManifest(pid, m3u8)
            }
            // ★★★★ 2026-10-22：清单里的**非标准 `#EXT-X-KEY`** —— **只记录，不判死** ★★★★
            //   CCTV-11~17（13 除外）/ CCTV-4K 的清单带 `#EXT-X-KEY:METHOD=SM4-CBC`，
            //   ExoPlayer 不认 ⇒ `PARSING_MANIFEST_MALFORMED` ⇒ "播放异常，正在恢复(1/3)"。
            //   ⚠️ 但**分片其实是明文 TS**（官方 App / 旧 CMG 版本都能播；历史 `CmgDataSource.open`
            //   就是"只剔非标准 METHOD 那一行"）。⇒ 现在由播放端的 `PlainHlsDataSource` 清洗清单，
            //   这里只打一行日志，**不能**再判"这条链路不可用"（否则整批频道被判死，用户实测踩过）。
            val badMethod = unsupportedKeyMethod(m3u8)
            if (badMethod != null) {
                lastDrmHit = true
                Log.w(
                    "[$TAG] 自检：清单带非标准加密 METHOD=$badMethod ⇒ 播放端会剔掉该 tag（分片是明文）"
                )
            }
            val seg = m3u8.lineSequence()
                .firstOrNull { it.isNotBlank() && !it.trimStart().startsWith("#") }
            if (seg == null) {
                Log.w("[$TAG] 自检：清单里没有分片；清单头=${m3u8.take(300)}")
                return false
            }
            val segUrl = java.net.URI(playUrl).resolve(seg.trim()).toString()
            // ★★★★ 2026-10-08 临时诊断：**变体定位 stub** ★★★★
            //   只在**每次进程**第一次自检时跑一遍，避免刷屏/打扰（`PROBE_VARIANTS` 默认关）。
            if (PROBE_VARIANTS && !variantsProbed) {
                variantsProbed = true
                probeVariants(segUrl, h, playUrl)
            }
            val (sc, sv, sb) = httpGet(segUrl, h + ("Range" to "bytes=0-2047"))
            // ★★★★★ 2026-10-08（**带宽闸**，`checkRate` 默认已关）★★★★★
            //   历史：575 档 cKey 时直播 CDN 被限速 ~52 KB/s ⇒ 必须实测速率；682 档后实测 4000+ KB/s
            //   ⇒ 2026-10-21 起默认关闭（只会误杀 + 每次换台多花 1.5 秒），保留参数供排查。
            val kbps = if (checkRate) measureRateKbps(segUrl, h) else -1
            val rateOk = if (!checkRate) true else !(kbps in 1 until MIN_LIVE_KBPS)
            if (sb == null) {
                // ★ 关键诊断：分片被拒时，把**清单前几行**（含 #EXT-X-KEY / 分片命名）一起打出来 ——
                //   直播链路的坑就在这一层（清单 200、分片 403），光看错误码定位不了。
                Log.w(
                    "[$TAG] 自检：**首个分片不可用** code=$sc server=$sv\n" +
                        "       分片 URL=${segUrl.take(260)}\n" +
                        "       清单头=${m3u8.take(420).replace("\n", " | ")}"
                )
                return false
            }
            if (!rateOk) {
                Log.w("[$TAG] 自检：**带宽不足**（实测 $kbps KB/s < $MIN_LIVE_KBPS KB/s）⇒ 本链路判不可用")
                return false
            }
            Log.i("[$TAG] 自检通过：清单 $pc/$pv，分片 $sc/$sv，带宽 $kbps KB/s")
            if (lastDrmHit) {
                // 带 DRM 标记的清单才多打日志（含全文），便于对比"明文变体"的差异
                Log.i("[$TAG] 清单全文=${m3u8.take(600).replace("\n", " | ")}")
            }
            dumpSegmentFingerprint(segUrl, h)
            true
        } catch (t: Throwable) {
            Log.w("[$TAG] 自检异常: ${t.javaClass.simpleName}: ${t.message}")
            false
        }
    }

    /**
     * ★ 2026-10-23 诊断：分片头 2 KB 的"形态指纹"。
     *
     * 用途：区分"**TS 结构完好、但视频 ES 被加密**"（解码器只会吐绿屏/黑屏）与
     *       "TS 本身就是密文"（解析器直接报错）。判据：
     *   · `sync` = 每 188 字节处 0x47 的命中数（TS 完好 ⇒ ≈ 11/11）；
     *   · `start` = `00 00 01` 起始码命中数（H.264 ES 未加密 ⇒ 有 SPS/PPS/IDR）；
     *   · `nal` = 起始码后 1 字节低 5 位（7=SPS、8=PPS、5=IDR）。
     * 若 `sync` 满而 `start` 几乎为 0 ⇒ **视频载荷被加密**（该台需要解密，我们目前没有密钥）。
     */
    private fun dumpSegmentFingerprint(url: String, hdrs: Map<String, String>) {
        try {
            val c = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
                setRequestProperty("Range", "bytes=0-2047")
            }
            try {
                val buf = ByteArray(2048)
                var n = 0
                c.inputStream.use { ins ->
                    while (n < buf.size) {
                        val r = ins.read(buf, n, buf.size - n)
                        if (r <= 0) break
                        n += r
                    }
                }
                if (n <= 0) return
                var sync = 0
                var pkts = 0
                var i = 0
                while (i < n) { pkts++; if (buf[i].toInt() and 0xff == 0x47) sync++; i += 188 }
                var start = 0
                val nals = StringBuilder()
                for (j in 0 until n - 4) {
                    if (buf[j].toInt() == 0 && buf[j + 1].toInt() == 0 && buf[j + 2].toInt() == 1) {
                        start++
                        if (nals.length < 24) {
                            nals.append((buf[j + 3].toInt() and 0x1f)).append(' ')
                        }
                    }
                }
                val head = (0 until minOf(8, n)).joinToString("") { "%02x".format(buf[it]) }
                // ★ 再判"切片载荷是否被加密"：取第一个 IDR(5) 之后的 1.2KB，统计
                //   ① 00 00 03（H.264 防竞争字节，明文必有）② 零字节占比 ③ 字节熵（密文≈8.0）
                var idrStart = -1
                for (j in 0 until n - 4) {
                    if (buf[j].toInt() == 0 && buf[j + 1].toInt() == 0 && buf[j + 2].toInt() == 1 &&
                        (buf[j + 3].toInt() and 0x1f) == 5
                    ) {
                        idrStart = j + 3
                        break
                    }
                }
                var emp = 0
                var zeros = 0
                var total = 0
                var entropy = 0.0
                if (idrStart >= 0) {
                    val end = minOf(n, idrStart + 1200)
                    val hist = IntArray(256)
                    var k = idrStart
                    while (k < end) {
                        val v = buf[k].toInt() and 0xff
                        hist[v]++
                        if (v == 0) zeros++
                        total++
                        if (k >= idrStart + 2 && buf[k - 2].toInt() == 0 &&
                            buf[k - 1].toInt() == 0 && v == 3
                        ) emp++
                        k++
                    }
                    if (total > 0) {
                        for (h in hist) {
                            if (h > 0) {
                                val p = h.toDouble() / total
                                entropy -= p * kotlin.math.log2(p)
                            }
                        }
                    }
                }
                Log.i(
                    "[$TAG] 分片指纹：head=$head len=$n ts包=$pkts sync=$sync 起始码=$start nal=[$nals] " +
                        "IDR载荷: 00_00_03=$emp 零字节=${if (total > 0) zeros * 100 / total else -1}% " +
                        "熵=${String.format("%.2f", entropy)}"
                )
            } finally {
                runCatching { c.disconnect() }
            }
        } catch (t: Throwable) {
            Log.w("[$TAG] 分片指纹失败: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** GET：返回 (status, Server 头, 文本或 null)。非 2xx / 异常都不抛。 */
    private fun httpGet(url: String, hdrs: Map<String, String>): Triple<Int, String, String?> = try {
        val c = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = Config.TIMEOUT_FETCH_MS.toInt()
            readTimeout = Config.TIMEOUT_FETCH_MS.toInt()
            hdrs.forEach { (k, v) -> setRequestProperty(k, v) }
        }
        try {
            val code = c.responseCode
            val srv = c.getHeaderField("Server") ?: ""
            val body = if (code in 200..299) c.inputStream.bufferedReader().use { it.readText() } else null
            Triple(code, srv, body)
        } finally {
            runCatching { c.disconnect() }
        }
    } catch (t: Throwable) {
        Triple(-1, t.javaClass.simpleName, null)
    }
}
