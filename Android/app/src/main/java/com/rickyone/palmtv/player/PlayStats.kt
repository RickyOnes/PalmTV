package com.rickyone.palmtv.player

/**
 * ★★ 2026-10-04（用户实测电视端"取流换台超慢、画面卡跳严重"，而**电视无法接 adb** 拿日志）★★
 *
 * 一个极小的"运行统计"单例：把**取流耗时**（[com.rickyone.palmtv.MainViewModel] 量、`YspAndroidLive.resolve` 那段）放到这里，
 * 由 **TV 界面的诊断浮层**（遥控「菜单」键切换，见 `ui/tv/TvHomeScreen.kt`）读到屏幕上显示 ——
 * 这样用户不用 adb 也能把关键数字念给我们。
 *
 * ★★★ 2026-10-22：**删掉"分片解密速率"** ★★★
 *   原来的 `decryptBytes` / `decryptMs` / `decryptKbps` 由已删除的 `CmgDataSource` 写入；
 *   CMG 解密链路整体移除后**没有任何写入方** ⇒ 浮层上会一直显示"解密 0KB/s"，
 *   反而误导排障（用户会以为"解密跟不上"）。判"生产端跟不上 vs 解码/渲染跟不上"现在靠
 *   **缓冲余量**（浮层里那一项，见 `TvHomeScreen` 的注释），够用 ⇒ 这一组统计直接删除，别再加回来。
 *
 * ⚠️ 只放统计，不放业务状态；读写跨线程用 `@Volatile` 兜住（写 = 取流线程，读 = UI 线程）。
 */
object PlayStats {

    /** 最近一次取流总耗时（ms；`MainViewModel.resolveUrl()` 写；0 = 还没取过） */
    @Volatile
    var resolveMs: Long = 0

    /* 2026-10-27: CMG 解密链路恢复（只服务 8 个 ChinaDRM 台）=> 统计重新有写入方（CmgDataSource）。 */
    /** 最近一次分片解密的字节数（CmgDataSource 写） */
    @Volatile
    var decryptBytes: Int = 0
    /** 最近一次分片解密耗时（ms；0 = 还没解过） */
    @Volatile
    var decryptMs: Long = 0
}
