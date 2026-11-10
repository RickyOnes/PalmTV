package com.rickyone.palmtv.player

import android.content.Context
import android.content.Intent
import com.rickyone.palmtv.data.Log

/**
 * 进程内唯一的播放器持有者 —— 让**界面**与**媒体播控服务**用同一个 ExoPlayer 实例。
 *
 * ★★ 2026-10-01（用户要求增加媒体播控卡片）★★
 *   系统媒体卡片（通知栏 / 锁屏 / 耳机按键 / 快捷设置里的播放控件）的标准做法是
 *   `MediaSession` + `MediaSessionService`，而 `MediaSession` 必须绑定**正在用的那个**播放器实例。
 *   本工程界面（`MainViewModel`）直接驱动的就是 `PalmPlayer`，两者在**同一进程**：
 *   ⇒ 用一个进程内单例把实例共享出去即可，无需 Binder / 无需把播放控制改成 `MediaController`，
 *     界面侧零改动（控制条、换台、手势音量全部照旧走 `PalmPlayer.player`）。
 *
 * ⚠️ 服务与界面**必须**用同一个实例：若各建一个 ExoPlayer，媒体卡片的播放/暂停会作用在"另一个"
 *    播放器上（界面没反应），而且两个播放器同时出声。
 */
object PlayerHolder {

    @Volatile
    private var instance: PalmPlayer? = null

    /** 取（必要时创建）全局唯一播放器。 */
    fun get(context: Context): PalmPlayer {
        instance?.let { return it }
        synchronized(this) {
            instance?.let { return it }
            val p = PalmPlayer(context.applicationContext)
            instance = p
            Log.i("[player] 创建全局唯一 ExoPlayer（界面与播控服务共用）")
            return p
        }
    }

    /**
     * ★★★★★ 2026-10-31：**只有真正退出时才释放**（正常路径不要调）★★★★★
     *
     * 事故：`MainViewModel.onCleared()` 里曾调 `player.release()`，而 `player` 是本单例持有的
     * **全局唯一实例**。按返回键 → Activity 结束 → `onCleared` → 全局播放器被释放；
     * 再次打开时 [get] 返回的仍是那个**已释放**的实例 ⇒ ExoPlayer 内部线程已死，
     * 之后每次 `setMediaItem` 都抛
     * `IllegalStateException: Handler sending message to a Handler on a dead thread`
     * ⇒ 分片一个都不请求 ⇒ 看门狗死循环 ⇒ **只能杀进程重开**（用户实测现象）。
     * ⇒ 播放器生命周期归本单例：界面销毁只 `stop()`，绝不 `release()`。
     */
    fun release() {
        synchronized(this) {
            instance?.release()
            instance = null
        }
    }

    /** 确保媒体播控服务已启动（**起播前**调用；幂等 —— 对已运行的服务再 `startService` 无副作用）。
     *  用 `startService` 而**不是** `startForegroundService`：此刻 App 在前台，
     *  由 Media3 自己在"会话已注册 + 播放中"时提升为前台服务（否则会踩"5 秒内没 startForeground"崩溃）。
     *  ⚠️ 这里**不能**用"只启动一次"的布尔标记缓存：退后台时我们会 [stopService] 收掉它，
     *     缓存住就会出现"回前台后卡片再也起不来"（2026-10-02 的坑，原本那个 `serviceStarted` 已删）。 */
    fun ensureService(context: Context) {
        try {
            context.startService(Intent(context, PlaybackService::class.java))
            Log.i("[session] 播控服务已启动/已在运行（通知栏·锁屏·耳机媒体卡片）")
        } catch (e: Exception) {
            Log.w("[session] 启动媒体播控服务失败: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** 收掉媒体播控服务（连带通知卡片）。**退后台时**调用 —— 与鸿蒙"退后台即销毁媒体卡"同语义
     *  （`Index.ets` 的 `onPageHide` → `TvSession.destroy()`）：避免留一张"点了没反应"的失效卡片。
     *  ⚠️ 只收服务，**不碰播放器**：暂停/停流是 `MainViewModel.onBackground()` 的职责。 */
    fun stopService(context: Context) {
        try {
            context.stopService(Intent(context, PlaybackService::class.java))
            Log.i("[session] 播控服务已停止（卡片随之下线）")
        } catch (e: Exception) {
            Log.w("[session] 停止媒体播控服务失败: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * ★ 2026-10-02：**播控卡片的"上一台/下一台"钩子**（由 `MainViewModel` 注册）。
     *
     * 为什么需要：Media3 的默认卡片会给出「跳转到上一项／下一项」两个按钮（它们映射到
     * `Player.seekToNext/PreviousMediaItem`），而我们的播放器**只有一条直播流、列表里就一个媒体项**
     * ⇒ 这两个按钮按下去是**空操作**（用户看到的就是"点了没反应"的死按钮）。
     * 播控服务把它包装成 [androidx.media3.common.ForwardingPlayer] 拦下这两个命令，转成**真正切台**
     * （与鸿蒙 `TvSession` 的 `onNextChannel/onPrevChannel` 同语义 —— 那边也是切上/下一台）。
     *
     * ⚠️ 回调在**主线程**（播放器的 application looper）上执行，与 UI 线程一致，可直接驱动界面。
     */
    @Volatile
    var onSwitchChannel: ((Int) -> Unit)? = null

    /** 由播控卡片/耳机按键触发的切台（offset = ±1）。没有注册钩子时什么都不做。 */
    fun switchChannel(offset: Int) {
        val hook = onSwitchChannel
        if (hook == null) {
            Log.w("[session] 播控切台 ${offset}：界面未注册钩子（忽略）")
            return
        }
        hook.invoke(offset)
    }
}
