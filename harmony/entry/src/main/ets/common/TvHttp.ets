/**
 * TvHttp - 远端**二进制**资源下载（当前只服务于本地解密代理拉取 m3u8 / TS 分片）。
 *
 * ★ 2026-09-15 清理：早期那套基于 Go 代理 base 的 JSON/表单请求原语
 *   （`requestHttp` / `getText` / `postForm` / `postJson` / `buildUrl` / `HttpResult`）
 *   只被已删除的 ProxyClient / ProxyLauncher 使用 ⇒ 一并移除。
 *   取流链路的 HTTP 现在都在 `StreamResolver.ets` 内部完成。
 */
import { http } from '@kit.NetworkKit';

/**
 * 直接下载远端**二进制**资源（拉取加密的 m3u8 / TS 分片）。
 *
 * ★ 必须用 `HttpDataType.ARRAY_BUFFER`：用 STRING 会把二进制当 UTF-8 文本解码而损坏数据。
 * ★ 也不要给 TS 分片设置 `Accept-Encoding: gzip`（鸿蒙 http 默认不发，保持即可）。
 */
export async function fetchRemote(url: string, accept: string, timeoutMs: number = 15000): Promise<Uint8Array> {
  const client = http.createHttp();
  try {
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: { 'Accept': accept },
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
  } finally {
    client.destroy();
  }
}
