/**
 * CctvConfig.ets —— 与央视频**无关取流**的少量常量（现在只服务 EPG）。
 *
 * ★★★ 2026-11-07：随「自研 cKey + 安卓平台 liveinfo」改造做了裁剪 ★★★
 *   取流所需的一切常量都搬去各自该在的地方了（不是"删掉"，而是"归位"）：
 *     · 平台号 / 版本串 / guid        → `common/SelfCKey.ets`（YSP_PLATFORM / YSP_CKEY_VER / YSP_GUID）
 *     · liveinfo 的固定参数与 UA      → `common/YspLive.ets`
 *     · 江苏台的主机 / Referer / UA   → `common/JiangsuTv.ets`
 *   随 Web/PC 取流链（`StreamResolver` + `ProxySigner` + `NativeSigner`）一起**删除**的常量：
 *     Guid（PC 侧 `mra3u75l_…`）、VappId、Vsecret、Cookie
 *   ⇒ 现在只剩 EPG（`capi.yangshipin.cn`）还需要的两个。
 */

/** 央视频 PC/H5 侧的 appid（EPG 接口要求带） */
export const YspAppId: string = 'YOUR_APP_ID';

/** 浏览器式 UA（EPG 接口按它做网关白名单） */
export const Ua: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
