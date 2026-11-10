package com.rickyone.palmtv.player

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.rickyone.palmtv.MainActivity
import com.rickyone.palmtv.data.Log

/**
 * ★★ 2026-10-02（用户实测："媒体卡片一直没生效"）—— 根因已定位 ★★
 *
 * 承载系统级媒体播控：通知栏常驻卡片、锁屏播放控件、蓝牙/有线耳机按键、快捷设置里的播放条。
 * 实现方式是最标准的 `MediaSessionService`（Media3）：
 *   · `onCreate` 用**全局唯一播放器**（[PlayerHolder]）建一个 `MediaSession` 并**注册给本服务**；
 *   · 卡片上的播放/暂停/停止直接作用在那个 ExoPlayer 上 ⇒ 界面通过既有监听器自然同步
 *     （`MainViewModel` 的 `onIsPlayingChanged` 更新 `UiState.playing`，控制条图标随之变化）；
 *   · 标题/封面来自 `PalmPlayer.play()` 里挂的 `MediaMetadata`（频道名 + 该频道台标）。
 *
 * ⚠️⚠️ **根因（别再踩）**：老代码只在 `onCreate` 里 `MediaSession.Builder(...).build()`，
 *   **从未把会话注册给服务**。而 Media3 的 `MediaSession.Builder.build()` **只做进程内 ID 去重**
 *   （`SESSION_ID_TO_SESSION_MAP`），**不会**调用 `addSession` —— Media3 源码 `MediaSession.java` 的原话是
 *   "把 Session 交给 `MediaSessionService`（例如在 Service 里调用 `addSession`）是**应用侧/Service 侧的职责**"。
 *   ⇒ 服务侧会话表为空 ⇒ `isSessionAdded()` 为假 ⇒ `MediaNotificationManager.shouldShowNotification()`
 *      直接返回 false ⇒ `removeNotification()`：**连一次通知刷新都不会发生、更不会进前台服务**。
 *      实测证据（MuMu）：播放中 `dumpsys activity services` 里 `startForegroundCount=0`、
 *      `dumpsys notification` 里该包**零条记录**，而卡片"永远不出现"。
 *   ⚠️ 迷惑点：系统里其实看得到"正在播放"（`dumpsys media_session` 有 `state=PLAYING`），因为那是
 *      **平台 MediaSession**（`MediaSessionImpl` 自己注册的）⇒ 耳机/蓝牙媒体键能工作，很容易误判成"卡片应该快了"。
 *   ✅ **修法：`onCreate` 里 `addSession(session)`（`onDestroy` 里 `removeSession` + `release`）。**
 *
 * 前台服务类型是 `mediaPlayback`（manifest 已声明 `FOREGROUND_SERVICE` +
 * `FOREGROUND_SERVICE_MEDIA_PLAYBACK`）。Media3 在"**会话已注册** 且 播放中（READY/BUFFERING 且
 * `playWhenReady`）"时会自行 `startForeground` ⇒ 系统不会把本服务杀掉。
 *
 * 生命周期与鸿蒙 `TvSession` 对齐（`Index.ets`：`onPageHide` 销毁、`onPageShow` 重建）：
 *   退后台时 `MainViewModel.onBackground()` 会调 [PlayerHolder.stopService] 收掉服务（卡片随之下线，
 *   不留"点了没反应"的失效按钮）；回前台起播时 `PlayerHolder.ensureService()` 再重建。
 */
class PlaybackService : MediaSessionService() {

    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        // ★ 2026-10-02：把播放器包一层 `ForwardingPlayer`，把卡片的"上一项/下一项"改成**真正切台**
        //   （裸 ExoPlayer 只有一个媒体项 ⇒ 那两个按钮是空操作，用户点了没反应）。
        val raw = PlayerHolder.get(this).player
        val bridged = object : androidx.media3.common.ForwardingPlayer(raw) {
            override fun seekToNextMediaItem() { PlayerHolder.switchChannel(1) }
            override fun seekToPreviousMediaItem() { PlayerHolder.switchChannel(-1) }
            override fun seekToNext() { PlayerHolder.switchChannel(1) }
            override fun seekToPrevious() { PlayerHolder.switchChannel(-1) }
        }
        val s = MediaSession.Builder(this, bridged)
            // 点卡片回到 App（而不是重开一个实例；MainActivity 是 singleTask）
            .setSessionActivity(
                PendingIntent.getActivity(
                    this, 0,
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
            .build()
        session = s
        // ★★ 关键一步：把会话注册给本服务 ★★（不做这一步 ⇒ 服务不知道有这个会话 ⇒ 永远没有卡片）
        addSession(s)
        Log.i("[session] 建立 MediaSession 并注册给服务（卡片标题=频道名、封面=台标，上一台/下一台=切台）")
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /**
     * 通知刷新回调 —— **只打日志（且只在"是否进前台"变化时打一次）**，通知实现仍交回库默认
     * （`DefaultMediaNotificationProvider`）。
     * ⚠️ 只能重写这个**两参数**版本：Media3 用 `defaultMethodCalled` 判断"应用是否自己实现了通知"，
     *    而置位动作在**单参数** `onUpdateNotification(session)` 的库默认实现里 —— 重写两参数版本并 `super`
     *    调用，仍会让库的版本执行（通知照旧由库负责）；一旦重写**单参数**版本，库就彻底不管通知了。
     * ⚠️ 本回调会被**高频**调用（每个分片/每次状态变化都可能来一次）⇒ 必须自己降噪，
     *    否则日志会被刷爆（实测每秒好几行）。
     */
    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        if (startInForegroundRequired != lastFgLogged) {
            lastFgLogged = startInForegroundRequired
            Log.i("[session] 播控通知：进前台服务=$startInForegroundRequired")
        }
        super.onUpdateNotification(session, startInForegroundRequired)
    }

    /** 上一次记录的"是否进前台"（只用于给 [onUpdateNotification] 降噪） */
    private var lastFgLogged = false

    /** 用户从最近任务里划掉 App：暂停播放并收工（不留后台播放／不占系统媒体卡片）。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i("[session] 任务被移除 ⇒ 暂停并停止播控服务")
        session?.player?.pause()
        stopSelf()
    }

    override fun onDestroy() {
        session?.let {
            removeSession(it)   // 从服务会话表移除（通知/前台随之收掉）
            it.release()        // 释放会话（⚠️ 不要 release player：它是全局共享的 PlayerHolder 实例）
        }
        session = null
        Log.i("[session] 播控服务销毁（卡片下线）")
        super.onDestroy()
    }
}
