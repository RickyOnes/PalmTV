/**
 * CctvHttp - 远端**二进制**资源下载（当前只服务于本地解密代理拉取 m3u8 / TS 分片）。
 *
 * ★ 2026-09-15 清理：早期那套基于 Go 代理 base 的 JSON/表单请求原语
 *   （`requestHttp` / `getText` / `postForm` / `postJson` / `buildUrl` / `HttpResult`）
 *   只被已删除的 ProxyClient / ProxyLauncher 使用 ⇒ 一并移除。
 *   取流链路的 HTTP 现在在 `YspLive.ets`（liveinfo）内部自带，本文件只服务本地代理。
 */
import { http } from '@kit.NetworkKit';

/**
 * 直接下载远端**二进制**资源（拉取加密的 m3u8 / TS 分片）。
 *
 * ★ 必须用 `HttpDataType.ARRAY_BUFFER`：用 STRING 会把二进制当 UTF-8 文本解码而损坏数据。
 * ★ 也不要给 TS 分片设置 `Accept-Encoding: gzip`（鸿蒙 http 默认不发，保持即可）。
 */
/** ★ 2026-09-18（优化 D-1）：进程内单例客户端（原来每次 `createHttp()` + `destroy()`，白费且丢连接上下文） */
let sharedHttp: http.HttpRequest | null = null;

function httpOf(): http.HttpRequest {
  if (sharedHttp === null) {
    sharedHttp = http.createHttp();
  }
  return sharedHttp;
}

export async function fetchRemote(url: string, accept: string, timeoutMs: number = 15000): Promise<Uint8Array> {
  return fetchRemoteWith(url, accept, {}, timeoutMs);
}

/**
 * ★ 2026-09-19 新增：带**自定义请求头**的下载（江苏台 CDN 要求 Referer / UA）。
 *
 * 与 `fetchRemote` 唯一的区别就是请求头：前者只有 `Accept`，这里允许附带任意头
 * （典型：`{ 'Referer': 'https://live.jstv.com/', 'User-Agent': 'Mozilla/5.0 …' }`）。
 * 其余（单例客户端、ARRAY_BUFFER、超时、2xx 校验）完全一致。
 */
export async function fetchRemoteWith(url: string, accept: string,
  headers: Record<string, string>, timeoutMs: number = 15000): Promise<Uint8Array> {
  const client: http.HttpRequest = httpOf();   /* ★ D-1：复用单例（不再每次创建/销毁） */
  {
    const h: Record<string, string> = { 'Accept': accept };
    for (const k of Object.keys(headers)) {
      h[k] = headers[k];
    }
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: h,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error('HTTP ' + resp.responseCode);
    }
    const r = resp.result;
    if (r instanceof ArrayBuffer) {
      return new Uint8Array(r as ArrayBuffer);
    }
    // 兜底：极少数情况下仍返回字符串
    const s = String(r);
    const u8 = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      u8[i] = s.charCodeAt(i) & 0xff;
    }
    return u8;
  }
}
