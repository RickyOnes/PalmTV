package com.rickyone.palmtv.data

import android.content.Context
import org.json.JSONArray
import java.io.File

/**
 * 本地设置 —— 对应鸿蒙 `preferences('palmtv')`。键名与鸿蒙保持一致（`disc`），方便"同一份口径"。
 *
 * ★★ 2026-10-02（用户要求"自定义 IPTV 源同步桌面端逻辑"）★★
 *   自定义源**不再存在 SharedPreferences 的私有 JSON 里**，改成**与桌面端同名同格式的 m3u 文件**：
 *     · 路径：`<应用私有目录>/files/iptv-local.m3u`（桌面端：`%LOCALAPPDATA%\WinPalmTV\iptv-local.m3u`）
 *     · 格式：`#EXTM3U` + 注释头 + `#EXTINF:-1,频道名` + 地址行（见 [IptvSources.toM3u]）⇒ 两端可直接互拷/粘贴；
 *     · 写文件是**原子替换**（先写 `.tmp` 再改名，与桌面 `File.Move(overwrite:true)` 同思路）⇒ 不会留半截文件；
 *       失败返回 false，由上层提示"保存失败（目录不可写？）"（桌面同提示）。
 *   ⚠️ 老版本把 JSON 存在 `iptv` 这个键里 ⇒ [loadCustomSources] 首次会**自动迁移**成 m3u 文件（不丢数据）。
 */
class Prefs(context: Context) {

    private val appCtx = context.applicationContext
    private val sp = appCtx.getSharedPreferences("palmtv", Context.MODE_PRIVATE)

    /** 自定义 IPTV 源文件（与桌面端同名同格式） */
    private val iptvFile = File(appCtx.filesDir, "iptv-local.m3u")

    /** 已同意的免责声明版本（不等于 [Config.DISC_VERSION] 时要重新弹） */
    var discAgreed: String
        get() = sp.getString(KEY_DISC, "") ?: ""
        set(v) = sp.edit().putString(KEY_DISC, v).apply()

    /** 上次播放的频道 id（下次启动续播） */
    var lastChannelId: String
        get() = sp.getString(KEY_LAST_CH, "") ?: ""
        set(v) = sp.edit().putString(KEY_LAST_CH, v).apply()

    // ⚠️ 2026-10-04：`videoDefn`（画质持久化）已删除 —— 上游不认降档参数，持久化只会让"重开 App"废掉 ✗。

    /** 音量（0..1，AVPlayer/VLC 同口径的“播放器内音量”） */
    var volume: Float
        get() = sp.getFloat(KEY_VOLUME, 1f)
        set(v) = sp.edit().putFloat(KEY_VOLUME, v).apply()

    /** 自定义源文件路径（关于页/编辑弹窗里给用户看，桌面端同款提示会显示它） */
    fun iptvFilePath(): String = iptvFile.absolutePath

    /** 只读用户自定义条目（内置 15 条在 [Channels] 里，不在此） */
    fun loadCustomSources(): List<IptvSources.Entry> {
        if (!iptvFile.isFile) {
            // ★ 一次性迁移：老版本存的是 SharedPreferences 里的 JSON 串
            val legacy = sp.getString(KEY_IPTV, "") ?: ""
            if (legacy.isNotBlank()) {
                val migrated = parseLegacyJson(legacy)
                if (migrated.isNotEmpty() && saveCustomSources(migrated)) {
                    Log.i("[iptv] 已把旧版 JSON 自定义源迁移为 m3u 文件（${migrated.size} 条）")
                    sp.edit().remove(KEY_IPTV).apply()
                }
                return migrated
            }
            return emptyList()
        }
        return try {
            IptvSources.parseM3u(iptvFile.readText())
        } catch (e: Exception) {
            Log.w("[iptv] 读自定义源文件失败（${iptvFile.name}）: ${e.message}")
            emptyList()
        }
    }

    /** 写 m3u 文件（原子替换）。@return 是否成功（失败由上层提示，别静默） */
    fun saveCustomSources(list: List<IptvSources.Entry>): Boolean = try {
        val tmp = File(iptvFile.absolutePath + ".tmp")
        tmp.writeText(IptvSources.toM3u(list))
        if (iptvFile.exists() && !iptvFile.delete()) {
            Log.w("[iptv] 旧文件删除失败（继续尝试改名）")
        }
        val ok = tmp.renameTo(iptvFile)
        if (!ok) {
            Log.w("[iptv] 改名失败：${tmp.absolutePath} → ${iptvFile.absolutePath}")
        }
        ok
    } catch (e: Exception) {
        Log.w("[iptv] 写自定义源文件失败: ${e.message}")
        false
    }

    /** 老版 JSON（`[{"name":..,"url":..}]`）→ Entry 列表；只用于迁移 */
    private fun parseLegacyJson(json: String): List<IptvSources.Entry> {
        val out = ArrayList<IptvSources.Entry>()
        try {
            val arr = JSONArray(json)
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val name = o.optString("name", "").trim()
                val url = o.optString("url", "").trim()
                if (url.isNotEmpty()) out.add(IptvSources.Entry(name, url))
            }
        } catch (e: Exception) {
            Log.w("[iptv] 旧版自定义源解析失败: ${e.message}")
        }
        return out
    }

    private companion object {
        const val KEY_DISC = "disc"
        const val KEY_LAST_CH = "lastCh"
        const val KEY_VOLUME = "volume"

        /** ⚠️ 仅用于**迁移**（新版自定义源在 `files/iptv-local.m3u` 里） */
        const val KEY_IPTV = "iptv"
    }
}
