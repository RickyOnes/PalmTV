package com.rickyone.palmtv.player

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.util.LruCache
import com.rickyone.palmtv.data.Channel
import com.rickyone.palmtv.data.Log

/**
 * 应用内图片资源（**台标 + 播放控件图标 + 应用图标**）—— 全部来自**一个** `assets/palmres.dat`。
 *
 * ★★ 2026-10-01（用户要求"打包后文件数量不要太多"）★★
 *   原来台标是 79 个散装 PNG（直接把 `windows/logos/real` 挂成 assets）、控件图标是 8 个
 *   `res/drawable/ic_player_*.png` ⇒ APK 里近 90 个图片文件。现在由构建脚本的 `packPalmRes`
 *   任务把它们打进**单个容器**，运行时按索引解码（**不落盘、不复制到 filesDir**）。
 *
 * 容器格式（与 `app/build.gradle.kts` 的 `packPalmRes`、鸿蒙侧 `palmres.dat` 一致；整数**大端**）：
 * ```
 * magic "PALMRES1\n"（9 字节）
 * u32   条目数
 * 重复：u16 名称长度 + 名称(UTF-8，如 `logo/cctv1`、`ui/play`、`app/icon`)
 *       + u32 数据长度 + 数据(原始 PNG)
 * ```
 * 命名空间：`logo/`（79 张台标，名字 = 频道 id 或中文名，即 [Channel.logoNames]）、
 * `ui/`（play/pause/sound_on/sound_off/fullscreen/window/locked/unlock）、`app/icon`。
 *
 * ⚠️ 注释里**不要**写形如 `real` + `/` + `*.png` 的路径（Kotlin 块注释可嵌套，会编译报
 * `Unclosed comment`，实测踩过）。
 */
object Logos {

    /** 资产文件名（构建产物；见 `packPalmRes`） */
    const val FILE = "palmres.dat"

    private const val MAGIC = "PALMRES1\n"

    /** 名称 → PNG 原始字节。整包 ~0.9 MB，**一次读进内存**（避免每次随机读文件，简单且够快）。 */
    @Volatile
    private var pack: Map<String, ByteArray>? = null

    /** 已解码位图缓存（台标 + 控件图标共用；上限 64 张，够一个分组 + 控件） */
    private val cache = LruCache<String, Bitmap>(64)

    private fun ensurePack(context: Context): Map<String, ByteArray> {
        pack?.let { return it }
        synchronized(this) {
            pack?.let { return it }
            val map = try {
                context.assets.open(FILE).use { parse(it.readBytes()) }
            } catch (e: Exception) {
                // 老包/构建脚本没跑：退化为空表 ⇒ 台标变文字、控件图标不显示（不崩）
                Log.w("[res] 打不开 $FILE: ${e.javaClass.simpleName}: ${e.message}")
                emptyMap()
            }
            Log.i("[res] $FILE 载入 ${map.size} 项")
            pack = map
            return map
        }
    }

    /** 解析容器（见类注释的格式说明）。任何越界/魔数不对 ⇒ 返回空表（不抛）。 */
    private fun parse(b: ByteArray): Map<String, ByteArray> {
        if (b.size < 13 || String(b, 0, MAGIC.length, Charsets.US_ASCII) != MAGIC) {
            Log.w("[res] $FILE 魔数/长度不对（${b.size} 字节）")
            return emptyMap()
        }
        val out = HashMap<String, ByteArray>()
        var p = MAGIC.length
        fun u16(): Int {
            val v = ((b[p].toInt() and 0xFF) shl 8) or (b[p + 1].toInt() and 0xFF); p += 2; return v
        }
        fun u32(): Int {
            val v = ((b[p].toInt() and 0xFF) shl 24) or ((b[p + 1].toInt() and 0xFF) shl 16) or
                ((b[p + 2].toInt() and 0xFF) shl 8) or (b[p + 3].toInt() and 0xFF)
            p += 4
            return v
        }
        try {
            val count = u32()
            repeat(count) {
                val n = u16()
                val name = String(b, p, n, Charsets.UTF_8); p += n
                val len = u32()
                out[name] = b.copyOfRange(p, p + len); p += len
            }
        } catch (e: Exception) {
            Log.w("[res] $FILE 解析中断（已读 ${out.size} 项）: ${e.message}")
        }
        return out
    }

    /** 取任意条目原始字节（如 `ui/play`、`app/icon`）；没有返回 null。 */
    fun bytes(context: Context, name: String): ByteArray? = ensurePack(context)[name]

    /** 取台标；找不到返回 null（调用方显示文字台标）。
     *  候选顺序与桌面 `ResolveLogoPath` 同：**先按频道 id，再按中文名**（[Channel.logoNames]）。 */
    fun load(context: Context, ch: Channel): Bitmap? {
        for (name in ch.logoNames) {
            val key = "logo/$name"
            cache.get(key)?.let { return it }
            val data = bytes(context, key) ?: continue
            val bmp = BitmapFactory.decodeByteArray(data, 0, data.size) ?: continue
            cache.put(key, bmp)
            return bmp
        }
        Log.i("[logo] 缺图: ${ch.id} / ${ch.name}")
        return null
    }

    /** 取台标原始 PNG 字节（媒体播控卡片的封面用；避免为了传封面把图落盘）。 */
    fun logoBytes(context: Context, ch: Channel): ByteArray? {
        for (name in ch.logoNames) bytes(context, "logo/$name")?.let { return it }
        return null
    }

    /**
     * ★★ 2026-10-02（用户实测安卓媒体卡片观感：台标被当整卡背景放大 + 裁切）★★
     *   给系统一张**为卡片尺寸准备的图**：**16:9 白底 + 居中台标**（而不是原始透明方图）。
     *
     * 为什么要自己合成，而不是把原始台标直接交给系统：
     *   · **Android 13+ 的快捷设置媒体卡会把 artwork 铺成整张卡片的背景**（标题/按钮叠在上面）
     *     ⇒ 原始方图会被放大并居中裁切，出现用户截图里"台标被切掉、标题压在图上"的观感；
     *   · 先合成一张**比例合适**的图（16:9），台标只占画面高度约 **38%** 且居中
     *     ⇒ 系统再按卡片比例（约 2.4:1）裁一刀也裁不到台标本体。
     *
     * ⚠️ 底色必须是**白**（与鸿蒙 `TvSession.buildSquareCover` 的"不透明白底方块"同思路）：
     *   我们的台标是"**深色字 + 透明底**"（如 `cctv14.png` = 黑字 + 红 C）⇒ 深色底上几乎看不见。
     *   **第一版我用了 #141414，主机合成预览里台标全黑、实测不可用**，别再来一次。
     *   系统会在卡片上叠一层暗色 scrim（用户截图里可见）⇒ 白底最终呈现为浅色卡，白字标题依旧可读。
     *
     * 尺寸 960×540：artwork 要经 Binder 交给 SystemUI（通知 extras）⇒ 别做大图（PNG 约 20~40 KB）。
     * 失败（缺图/OOM）返回 null ⇒ 调用方退回 [logoBytes]（功能不受影响）。
     */
    fun artworkBytes(context: Context, ch: Channel): ByteArray? {
        val logo = load(context, ch) ?: return null
        return try {
            val w = 960
            val h = 540
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            // ⚠️ 白底（不是深色）：台标是深色字 + 透明底，深底等于看不见（见函数注释里的实测）
            c.drawColor(0xFFFFFFFF.toInt())
            val side = (h * 0.38f).toInt()             // 台标只占 38% 高 ⇒ 抗系统裁切
            val scale = side.toFloat() / maxOf(logo.width, logo.height)
            val dw = (logo.width * scale).toInt()
            val dh = (logo.height * scale).toInt()
            c.drawBitmap(
                logo, null,
                Rect((w - dw) / 2, (h - dh) / 2, (w + dw) / 2, (h + dh) / 2),
                Paint().apply {
                    isFilterBitmap = true
                    isAntiAlias = true
                }
            )
            val out = java.io.ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            bmp.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.w("[logo] 生成卡片背景图失败（回退原始台标）: ${e.message}")
            null
        }
    }

    /** 播放控件图标（`play` / `pause` / `sound_on` / `sound_off` / `fullscreen` / `window` / `locked` / `unlock`） */
    fun ui(context: Context, name: String): Bitmap? = decodeCached(context, "ui/$name")

    /** `app/…` 命名空间（应用图标 `icon`、版权图标 `copyright` 等）。
     *  ★ 2026-10-02：新增 —— 关于页「版权人」后面的小图标走这里，**不额外占 APK 文件数**。
     *  ⚠️ 注释里不要写"斜杠紧跟星号"的通配写法：**Kotlin 的块注释可以嵌套**，那一对字符会把注释
     *     再开一层 ⇒ 编译报 `Unclosed comment`（本行注释就是这么踩出来的，别再写）。 */
    fun app(context: Context, name: String): Bitmap? = decodeCached(context, "app/$name")

    /** 应用图标（`app/icon`）—— 给媒体播控卡片当封面。
     *  ⚠️ App 自己的 launcher 图标仍然必须是真资源（`R.mipmap.ic_launcher`），系统只认它。 */
    fun appIcon(context: Context): Bitmap? = decodeCached(context, "app/icon")

    private fun decodeCached(context: Context, key: String): Bitmap? {
        cache.get(key)?.let { return it }
        val data = bytes(context, key) ?: return null
        val bmp = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
        cache.put(key, bmp)
        return bmp
    }
}
