package com.rickyone.palmtv.player

/**
 * ★★★★★ 2026-11-03：**清单窗口登记处**（按频道 pid 记：分片时长 + 片数）★★★★★
 *
 * 为什么需要单独一个单例：
 *   · 取流阶段（`YspAndroidLive.resolve` → `probePlayable`）**本来就拿到了清单全文**，
 *     是唯一能在 `player.setMediaItem()` **之前**知道窗口大小的时机；
 *   · 而 `LiveConfiguration.targetOffsetMs` 只在 prepare 时读一次 —— 起播之后再学到就晚了
 *     （要等到下一次 prepare 才生效）。
 *   ⇒ 在取流时就算好并登记到这里，`PalmPlayer` 起播时直接读。
 *
 * 实测窗口（2026-11-03）：CCTV-3 = 3 片 × 4.68s ≈ 14s；8K ≈ 6~10s；4K ≈ 24s；回看 VOD = 整档。
 *   偏移大于窗口的后果（CCTV-3 实测）：播放位置被钉在窗口最老端 ⇒ 每 4~5 秒滚一次就重置位置 ⇒
 *   "经常缓冲中"。所以**必须按真实窗口算偏移**，不能写死一个数。
 */
object PlaylistWindow {

    /** pid -> [分片时长 ms, 片数] */
    private val byPid = java.util.concurrent.ConcurrentHashMap<String, LongArray>()

    fun remember(pid: String, segMs: Long, count: Int) {
        if (pid.isEmpty() || segMs <= 0 || count <= 0) return
        byPid[pid] = longArrayOf(segMs, count.toLong())
    }

    /** 真实窗口长度（毫秒）；未知返回 0 */
    fun windowMs(pid: String): Long {
        val v = byPid[pid] ?: return 0L
        return v[0] * v[1]
    }

    /** 分片时长（毫秒）；未知返回 0 */
    fun segMs(pid: String): Long = byPid[pid]?.get(0) ?: 0L

    /** 从清单文本里解析并登记；返回是否成功
     *  ★ 2026-11-04：`segMs` 取**最大**分片时长（与 [CmgDataSource] 口径一致）。
     *    ⚠️ 试过改成平均值（理由："windowMs 应等于真实总长"）⇒ **缓冲变差**：
     *      平均值会算出更小的 offset，而窄窗口本来就只有 ~1.5 片库存。
     *      offset 宁大勿小；掉窗风险由 `cap = 窗口 − 1 片` 兜住。 */
    fun rememberFromManifest(pid: String, manifest: String): Boolean {
        if (pid.isEmpty() || !manifest.contains("#EXTM3U")) return false
        val durs = Regex("#EXTINF:\\s*([0-9]+(?:\\.[0-9]+)?)").findAll(manifest)
            .mapNotNull { it.groupValues[1].toDoubleOrNull() }.toList()
        val maxDur = durs.maxOrNull() ?: return false
        remember(pid, (maxDur * 1000).toLong(), durs.size)
        return true
    }
}
