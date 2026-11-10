package com.rickyone.palmtv.data

/**
 * 取流所需常量 —— 与鸿蒙 `common/CctvConfig.ets` **逐字一致**（改一处必须三端同改）。
 *
 * ★ 这里只放"现行 native 取流链路真正用到"的常量；签名盐值在 [Signer] 内部。
 */
object Config {

    // ===== 应用与设备标识 =====
    const val YSP_APP_ID = "YOUR_APP_ID"
    const val GUID = "mra3u75l_jdrj8csvhkk"
    const val VAPP_ID = "59306155"
    const val V_SECRET = "b42702bf7309a179d102f3d51b1add2fda0bc7ada64cb801"

    // ===== 请求头 =====
    const val UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    const val COOKIE =
        "guid=mra3u75l_jdrj8csvhkk; versionName=99.99.99; versionCode=999999; vplatform=109; " +
            "platformVersion=Chrome; deviceModel=150; newLogin=1; pc_version=1.1.16; ysp_uinfo_pc="

    // ===== 域名 =====
    const val HOST_PLAYER = "https://player-api.yangshipin.cn"
    const val HOST_H5 = "https://h5access.yangshipin.cn"
    const val HOST_CAPI = "https://capi.yangshipin.cn"
    const val REFERER = "https://yangshipin.cn/"
    const val ORIGIN = "https://yangshipin.cn"

    /** 取流参数固定值（与鸿蒙 `resolve()` 里那串一致） */
    const val PLATFORM = "5910204"
    const val APP_VER = "V1.0.0"

    /**
     * ★★ 2026-10-04（用户真机实测：创维电视 Android 8.1 / 32 位 / 4K）★★ **取流画质（`defn`）**。
     *
     * 为什么做成变量：电视端解密只有 ~1MB/s（同一份包在 MuMu x86_64 上是 ~2.6MB/s），
     * 1080p 大约要 500KB/s ⇒ 余量很小，**偶尔就会 buffering、画面不流畅**。
     * 把 `defn` 降一档（`fhd` 1080p → `hd` 720p）能同时减轻 **网络 / 解密 / 硬解码** 三处压力，
     * 这是慢电视上最有效也最"正当"的一招（比压缩画面取巧强）。
     *
     * 取值（上游口径）：`fhd` = 超清（默认，1080p）、`hd` = 高清（720p）、`sd` = 标清。
     * ⚠️ 运行期由 `Prefs.videoDefn` 覆盖（VM 启动时读一次），TV 界面里按**菜单键显示诊断后再按 OK** 可切换。
     * ⚠️ 只影响**央视频链路**（本地/IPTV 直连台是固定流，改它没用）。
     */
    var defn: String = "fhd"

    /** ⚠️ 2026-10-04 真机结论：上游**不认** `defn=hd`（切过去就 `get-live-info 无 playurl`）⇒
     *  画质开关与持久化**全部撤掉**，这里恒为 `fhd`（保留字段只为少动 `StreamResolver`）。 */

    // ===== 关于页 / 免责声明（三端逐字一致）=====
    const val CONTACT_EMAIL = "162004332@qq.com"
    const val CONTACT_LABEL = "举报 / 联系："
    /** 改声明正文必须升这个版本号 ⇒ 老用户升级后会再弹一次（与桌面/鸿蒙同口径） */
    const val DISC_VERSION = "disc_v2"

    // ===== 超时（对齐鸿蒙：取流 10~12s、EPG 8s、清单/分片由播放器自己管） =====
    const val TIMEOUT_AUTH_MS = 10_000L
    const val TIMEOUT_LIVE_MS = 12_000L
    const val TIMEOUT_TOKEN_MS = 10_000L

    /** CCTV-4K 超高清的 pid（它的清单刷新需要单独参数，见 CmgDataSource） */
    const val PID_CCTV4K = "600002264"

    const val TIMEOUT_EPG_MS = 8_000L
    const val TIMEOUT_FETCH_MS = 15_000L
}
