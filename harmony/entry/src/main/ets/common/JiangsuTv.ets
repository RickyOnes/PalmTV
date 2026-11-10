/**
 * JiangsuTv.ets —— 江苏电视台（荔枝 TV / live.jstv.com）「本地」频道
 *
 * 来源：桌面版 `D:\TV\IPTVPlayer\IptvPlayerMpv\Services\JiangsuTvProxyService.cs`
 *   （那份 C# 是一个本地 HTTP 代理：`/live?channel=x` 换签名后的 m3u8、`/ts/<b64url>` 转发分片）
 *   ⇒ 这里做**等价拆分**（不新增本地端口）：
 *     · **签名（唯一需要藏的 KEY）→ native**（`native/src/jstv_sign.c` → `libpalmtv_napi.so`）
 *     · **HTTP 转发 → 复用已有的 LocalProxyServer（127.0.0.1:18899）**，
 *       新增两条路由 `/jstv.m3u8`（改写播放列表）与 `/jstv-seg`（明文分片直通）
 *
 * ★★ 与央视频（ysp）链路的**本质区别** ★★
 *   - **不需要 auth / 签名 / get_live_info**：上游地址只靠 `txSecret` 就成立；
 *   - **流不加密**：TS 是明文的 ⇒ 代理**只转发、不解密**；
 *   - **必须有 Referer / UA**：CDN 会校验来源页（C# 里固定带 `https://live.jstv.com/`），
 *     而 AVPlayer 只会请求我们本地地址 ⇒ 这几个头只能由本地代理发出去。
 */
import palmtv from 'libpalmtv_napi.so';
import { Log } from './Log';

/** 上游主机（= C# 的 TargetHost） */
export const JSTV_ORIGIN: string = 'https://litchi-play-encrypted-site.jstv.com';

/** 上游要求的来源页（= C# 的 Referer） */
export const JSTV_REFERER: string = 'https://live.jstv.com/';

/** 上游要求的 UA（= C# 的 UserAgent，普通桌面 Chrome） */
export const JSTV_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/** 一个江苏台（= C# 里 `Channels` 表的元素） */
export interface JstvChannel {
  /** 荔枝 TV 流 ID（同时是上游 URL 的最后一段），如 'jszypro' */
  streamId: string;
  /** 频道名 */
  name: string;
  /** 上游路径前缀：点播直播 '/applive/'、4K '/4klive/' */
  path: string;
}

/**
 * 江苏台频道表（源自 C# `JiangsuTvProxyService.Channels`，顺序保持原样）。
 *
 * ★ 2026-09-19（用户要求）：**移除了 `jswspro`（江苏卫视）** —— 它与卫视组的 `jsws` 同名同源频道重复。
 *   这是本表与 C# 源表**唯一**的差异；上游本身可用，只是不再出现在 App 的频道列表里。
 * ⚠️ 新增/改名时同步两处：本表 + `ChannelList.ets` 的 local 组（那里的 id 用 streamId，台标见 CHANNEL_ICONS）。
 */
export const JSTV_CHANNELS: JstvChannel[] = [
  { streamId: 'jsws4kpro', name: '江苏卫视4K', path: '/4klive/' },
  { streamId: 'jszypro',   name: '江苏综艺',   path: '/applive/' },
  { streamId: 'jsyspro',   name: '江苏影视',   path: '/applive/' },
  { streamId: 'jscspro',   name: '江苏城市',   path: '/applive/' },
  { streamId: 'jsxwpro',   name: '江苏新闻',   path: '/applive/' },
  { streamId: 'jsjypro',   name: '江苏教育',   path: '/applive/' },
  { streamId: 'jsxxpro',   name: '江苏休闲',   path: '/applive/' },
  { streamId: 'jsgjpro',   name: '江苏国际',   path: '/applive/' },
  { streamId: 'ymktpro',   name: '优漫卡通',   path: '/applive/' }
];

/** 按 streamId 查频道（找不到返回 undefined） */
export function jstvFind(streamId: string): JstvChannel | undefined {
  for (const c of JSTV_CHANNELS) {
    if (c.streamId === streamId) {
      return c;
    }
  }
  return undefined;
}

/**
 * 上游 m3u8 地址（含一次性签名）。
 *
 * `https://{host}{path}{streamId}.m3u8?txSecret=<md5>&txTime=<hex8>`
 * 签名由 native 计算（KEY 不进 ArkTS）。**每次调用都会重新签名**（txTime = 当前秒）。
 *
 * @returns 失败（native 返回空串）时返回 `''` ⇒ 调用方应回 502
 */
export function jstvUpstreamUrl(ch: JstvChannel): string {
  const sec: number = Math.floor(Date.now() / 1000);
  /* ★ 防御：万一装的是**旧版 .so**（没有 jstv* 接口），这里会抛 TypeError；
   *   捕获后返回空串，让上层回 502 并打一条明确日志，而不是把异常抛穿到 HTTP 层。 */
  try {
    const q: string = palmtv.jstvSignQuery(ch.streamId, sec);
    if (q.length === 0) {
      Log.e(`[Jstv] 签名失败 ${ch.streamId}: ${palmtv.jstvSignLastError()}`);
      return '';
    }
    return `${JSTV_ORIGIN}${ch.path}${ch.streamId}.m3u8?${q}`;
  } catch (e) {
    Log.e(`[Jstv] 调用 jstvSignQuery 异常（.so 是否已重新编译？）: ${(e as Error).message}`);
    return '';
  }
}

/** 上游请求头（每一次上游请求都必须带，否则 CDN 可能回 403） */
export function jstvHeaders(): Record<string, string> {
  const h: Record<string, string> = {
    'Referer': JSTV_REFERER,
    'User-Agent': JSTV_USER_AGENT,
    'Accept': '*/*'
  };
  return h;
}
