/**
 * TvConfig —— 取流所需的应用/设备标识常量（公开版为占位值）。
 *
 * ⚠️ 本文件在公开仓库中只保留**结构**：真实取值属于账号侧配置，不随仓库分发。
 *    本地开发时请填入自己的取值，或从私有分支取回完整文件。
 *
 * 说明：Ua / Cookie 只是把客户端伪装成桌面浏览器的常规请求头；
 *      桌面版对应实现见 `desktop/PlayerService.cs`。
 */

// ===== 应用与设备标识 =====
export const YspAppId: string = '';            // 平台方为应用分配的 appId
export const Guid: string = '';                // 本机设备标识（随机会话标识）
export const VappId: string = '';              // 取 sessionToken 用的 vappid
export const Vsecret: string = '';             // 取 sessionToken 用的 vsecret

// ===== 请求头 =====
export const Ua: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';
export const Cookie: string =
  `guid=${Guid}; versionName=99.99.99; versionCode=999999; vplatform=109; platformVersion=Chrome; ` +
  `deviceModel=150; newLogin=1; pc_version=1.1.16; ysp_uinfo_pc=`;
