package com.rickyone.palmtv.data


/**
 * EPG 节目单 —— 接口与解码与鸿蒙 `Index.ets` + `ProxyEpg.ets` 完全一致。
 *
 * 接口：`GET https://capi.yangshipin.cn/api/yspepg/program/{pid}/{yyyyMMdd}`（**protobuf** 响应）
 * 字段表（实测）：[1] id  [2] title  [3] start 秒  [4] end 秒  [5]/[6] "HH:mm" 兜底  [7] 时长
 *                [9] 恒为 "1"（与回看无关）
 *                ★ [10] **官方"是否可回看"标志**：`"1"` 可回看 / `"2"` 不可回看
 *
 * ## ★★★ [10] 的实证（2026-10-22，`re/epg/epg-list.py`）
 * CCTV-1 20261021 共 37 条，其中 5 条 `[10]="2"`：
 * ```
 * 13:07-13:54  [10]=2  人世间第56集
 * 13:54-14:42  [10]=2  人世间第57集
 * 14:42-15:30  [10]=2  人世间第58集          ← 官方 App 截图里确实没有「回看」按钮
 * 20:58-21:01  [10]=2  前情提要-伟大的长征-19/60（版权原因不可回看）
 * 21:01-21:49  [10]=2  伟大的长征19/60（版权原因不可回看）
 * ```
 * 与官方 App 的 UI 完全对应 ⇒ **判断"能否回看"必须用这个字段，不能只看"是否已播完"**。
 * （此前只按 `end < now` 判断 ⇒ 会给不可回看的节目显示「回看」按钮，点了必然失败。）
 */
object Epg {

    data class Item(
        val id: String,
        val title: String,
        /** epoch 秒（>0）；否则退化为 "HH:mm" 字符串 */
        val start: Long,
        val end: Long,
        val startHm: String,
        val endHm: String,
        /** ★ 官方是否允许回看（protobuf 字段 [10] == "1"）。缺字段时按"允许"处理 */
        val replayable: Boolean = true,
        /** 该节目所属日期（yyyyMMdd），用于跨天回看定位 */
        val ymd: String = ""
    )

    /** 拉取（失败自动重试 3 次，退避 2s/4s；失败抛错由上层显示文案） */
    suspend fun fetch(pid: String, ymd: String): List<Item> {
        val url = "${Config.HOST_CAPI}/api/yspepg/program/$pid/$ymd"
        val headers = mapOf(
            "User-Agent" to Config.UA,
            "yspappid" to Config.YSP_APP_ID,
            "Accept" to "*/*"
        )
        val bytes = Http.getBytes(url, headers, Config.TIMEOUT_EPG_MS)
        return decode(bytes, ymd)
    }

    /** ★ 2026-10-22：过去 [pastDays] 天 + 今天 + 未来 [futureDays] 天，串成一个长节目单。
     *  单天失败只跳过那一天（不整段失败），保证"其它天能看"。 */
    suspend fun fetchRange(pid: String, pastDays: Int = 6, futureDays: Int = 3): List<Item> {
        val fmt = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd")
        val today = java.time.LocalDate.now()
        val all = ArrayList<Item>()
        for (d in -pastDays..futureDays) {
            val ymd = today.plusDays(d.toLong()).format(fmt)
            try {
                all.addAll(fetch(pid, ymd))
            } catch (_: Throwable) {
                // 单天失败忽略：过去太久的日期服务端可能无数据
            }
        }
        return all.sortedBy { it.start }
    }

    /** ★ 2026-10-22：把长节目单按日期分组（供"日期选择行"用）。返回 (yyyyMMdd, 该天节目) */
    fun groupByDay(items: List<Item>): List<Pair<String, List<Item>>> =
        items.filter { it.ymd.isNotEmpty() }.groupBy { it.ymd }.toSortedMap().map { (k, v) ->
            k to v.sortedBy { it.start }
        }

    // ------------------------------------------------------------------
    // protobuf 解码（照 ProxyEpg.ets 移植；不要用第三方 protobuf 库）
    // ------------------------------------------------------------------

    /** 读 varint：返回 (值, 消耗字节数)。用乘法累加，避免 32 位左移溢出成负数 */
    private fun readVarint(b: ByteArray, start: Int): Pair<Long, Int> {
        var v = 0L
        var s = 0
        var i = start
        while (i < b.size) {
            val x = b[i].toInt() and 0xFF
            v += (x and 0x7F).toLong() * (1L shl s)
            if (x < 0x80) return v to (i - start + 1)
            s += 7
            if (s > 56) break
            i++
        }
        return 0L to 0
    }

    private fun decode(data: ByteArray, ymd: String = ""): List<Item> {
        val out = ArrayList<Item>()
        var off = 0
        while (off < data.size) {
            val (tag, tn) = readVarint(data, off)
            if (tn == 0) break
            off += tn
            val fnum = (tag shr 3).toInt()
            when ((tag and 0x7).toInt()) {
                0 -> { // varint
                    val (_, n) = readVarint(data, off); off += n
                }
                2 -> { // length-delimited
                    val (lenL, ln) = readVarint(data, off); off += ln
                    val len = lenL.toInt()
                    if (len < 0 || off + len > data.size) break
                    val sub = data.copyOfRange(off, off + len)
                    off += len
                    if (fnum == 2) {
                        val item = parseProgram(sub, ymd)
                        if (item != null) out.add(item)
                    }
                }
                else -> break
            }
        }
        return out
    }

    private fun parseProgram(b: ByteArray, ymd: String = ""): Item? {
        var id = ""
        var title = ""
        var startSec = 0L
        var endSec = 0L
        var startHm = ""
        var endHm = ""
        var replayFlag = ""
        var off = 0
        while (off < b.size) {
            val (tag, tn) = readVarint(b, off)
            if (tn == 0) break
            off += tn
            val fnum = (tag shr 3).toInt()
            when ((tag and 0x7).toInt()) {
                0 -> {
                    val (v, n) = readVarint(b, off); off += n
                    when (fnum) {
                        3 -> startSec = v
                        4 -> endSec = v
                    }
                }
                2 -> {
                    val (lenL, ln) = readVarint(b, off); off += ln
                    val len = lenL.toInt()
                    if (len < 0 || off + len > b.size) break
                    val s = String(b, off, len, Charsets.UTF_8)
                    off += len
                    when (fnum) {
                        1 -> id = s
                        2 -> title = s
                        5 -> startHm = s
                        6 -> endHm = s
                        10 -> replayFlag = s   // ★ 官方"可回看"标志："1" 可 / "2" 不可
                    }
                }
                1 -> off += 8    // 未知字段：跳过而不是丢整条
                5 -> off += 4
                else -> return null
            }
        }
        if (title.isEmpty()) return null
        // 缺字段时按"允许"处理（老数据兼容）；只有明确为 "2" 才禁用回看
        return Item(id, title, startSec, endSec, startHm, endHm,
            replayable = replayFlag != "2", ymd = ymd)
    }

    /** 时间格式 HH:mm（epoch 秒优先，其次 "HH:mm" 兜底） */
    fun hhmm(it: Item, isStart: Boolean): String {
        val sec = if (isStart) it.start else it.end
        if (sec > 0) {
            val cal = java.util.Calendar.getInstance()
            cal.timeInMillis = sec * 1000
            val h = cal.get(java.util.Calendar.HOUR_OF_DAY)
            val m = cal.get(java.util.Calendar.MINUTE)
            return (if (h < 10) "0$h" else "$h") + ":" + (if (m < 10) "0$m" else "$m")
        }
        val hm = if (isStart) it.startHm else it.endHm
        return if (hm.isNotEmpty()) hm else "--:--"
    }

    /** 今天 yyyyMMdd（接口要求） */
    fun todayYmd(): String {
        val c = java.util.Calendar.getInstance()
        val y = c.get(java.util.Calendar.YEAR)
        val m = c.get(java.util.Calendar.MONTH) + 1
        val d = c.get(java.util.Calendar.DAY_OF_MONTH)
        return String.format("%04d%02d%02d", y, m, d)
    }

    /** 当前正在播出的下标（-1 = 没有）；[nowSec] 传本地时间秒 */
    fun indexOfNow(items: List<Item>, nowSec: Long): Int =
        items.indexOfFirst { it.start > 0 && it.end > 0 && nowSec in it.start until it.end }

    /** 顺手记录 native 版本，便于日志核对（调用一次即可） */
    fun nativeTag(): String = "plain"   // ★ 2026-10-22：CMG 已移除，如实标注明文链路
}
