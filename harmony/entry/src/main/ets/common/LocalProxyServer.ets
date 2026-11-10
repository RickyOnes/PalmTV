/**
 * LocalProxyServer.ets —— 本地 HLS 转发代理（127.0.0.1:18899）
 *
 * ★★★ 2026-11-07：**只转发、不解密** ★★★
 *   原 `LocalDecryptServer` 里那套 CMG 原地解密（`CmgNative.decryptTsAsync`、两级优先级队列、
 *   "未解/重试/错帧/短片"统计、`rawCache`）**已整条删除** —— 因为取流链路已换成
 *   `YspLive`（安卓平台 + 自研 cKey），拿到的分片本来就是明文。
 *
 * 现在只剩三条**明文**链路，都需要本地代理（AVPlayer 带不了自定义头、也不改写清单）：
 *
 *   ┌ 央视频（`/ysp.m3u8` + `/ysp-seg`）
 *   │  上游 = `liveinfo` 返回的明文 playurl；CDN 要求 `User-Agent: qqlive` + `UID: <guid>`
 *   ├ 江苏台（`/jstv.m3u8` + `/jstv-seg`）
 *   │  上游地址由代理**现算签名**（`JiangsuTv.jstvUpstreamUrl`，txTime = 当前秒）；要求 Referer/UA
 *   └ IPTV（`src:'iptv'`）
 *      直链明文，**不经本代理**（播放器直接吃原始 URL）
 *
 * 端口固定 **18899**。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fetchRemoteWith } from './CctvHttp';
import { JstvChannel, jstvFind, jstvHeaders, jstvUpstreamUrl } from './JiangsuTv';
import { Sm4C } from './Sm4C';
import { Log } from './Log';

const TS_MIME = 'video/mp2t';
const M3U8_MIME = 'application/vnd.apple.mpegurl';

/** 播放统计（看门狗用 `total` 判断"有没有出片"） */
export interface SegStat {
  /** 已向播放器返回的分片总数（网络 + 缓存命中） */
  total: number;
  /** 缓存命中次数 */
  cacheHits: number;
  /** 上游拉取失败次数 */
  failed: number;
}

interface PlCacheEntry {
  body: string;
  at: number;
  /** 该条的缓存时长（回看/时移是**静态 VOD 清单** ⇒ 可以缓存很久，不必每 4s 重拉 300+ 行） */
  ttl: number;
}

interface SegCacheEntry {
  data: Uint8Array;
  at: number;
}

export class LocalProxyServer {
  private static readonly PORT: number = 18899;
  private server: socket.TCPSocketServer | null = null;
  private stat: SegStat = { total: 0, cacheHits: 0, failed: 0 };

  /** playlist 缓存（remote URL 或 `jstv|<streamId>` ⇒ 已改写成本地地址的清单） */
  private plCache: Map<string, PlCacheEntry> = new Map();
  /** 分片缓存（键 = 上游分片绝对 URL，天然带一次性令牌 ⇒ 不会错片） */
  private segCache: Map<string, SegCacheEntry> = new Map();
  private segOrder: string[] = [];
  private segCacheBytes: number = 0;

  private static readonly SEG_CACHE_MAX: number = 12;
  private static readonly SEG_TTL_MS: number = 120000;
  /** 分片缓存**按字节封顶**（江苏台 4K 单片 5~10MB ⇒ 只按条数会撑到上百 MB） */
  private static readonly SEG_CACHE_BYTES_MAX: number = 32 * 1024 * 1024;
  /** 央视频明文清单缓存 4s（≈ 一个分片周期，够播放器连拉两次命中） */
  private static readonly YSP_PL_TTL_MS: number = 4000;
  /** 回看/时移的清单是**静态 VOD**（`#EXT-X-ENDLIST`，实测 302 片）：缓存 30s */
  private static readonly VOD_PL_TTL_MS: number = 30000;
  /**
   * 是否剔除"非标准 METHOD"的 `#EXT-X-KEY`（`METHOD=SM4-CBC` 那行）。
   * ★ 2026-11-08 排查中的开关：安卓 ExoPlayer 遇到它必 `PARSING_MANIFEST_MALFORMED`，
   *   但鸿蒙 HiPlayer 未必；两种取值都实测一遍再定稿（当前先按"不剔"验证）。
   */
  private static readonly STRIP_NONSTD_KEY: boolean = true;
  /** 江苏台分片只有 ~2.6s ⇒ 清单只缓存 2.5s（否则给播放器的是过期的直播边沿） */
  private static readonly JSTV_PL_TTL_MS: number = 2500;
  /** 预热预下载的分片数（AVPlayer 要等前两片才出画） */
  private static readonly PREWARM_SEGS: number = 2;
  /** 同频道预热不重启的窗口（ms） */
  private static readonly PREWARM_SAME_KEY_MS: number = 12000;

  /** playlist 请求的 in-flight 去重 */
  private plInflight: Map<string, Promise<string>> = new Map();
  /** 分片下载的 in-flight 去重 */
  private segInflight: Map<string, Promise<Uint8Array | null>> = new Map();
  /** 江苏台 playlist 的 in-flight 去重 */
  private jstvPlInflight: Map<string, Promise<string | null>> = new Map();
  /** 预热世代号（换台/退后台让旧预热自弃） */
  private prewarmGen: number = 0;
  private prewarmKey: string = '';
  private prewarmKeyAt: number = 0;
  /** 播放器已请求过的分片键（预热避让，别重复下载） */
  private playerAsked: Set<string> = new Set<string>();
  /** 退后台挂起标记 */
  private suspended: boolean = false;

  /**
   * 启动服务（幂等；最多重试 3 次）。
   * ★ 这是播放链路的**单点**：起不来就必然播不了（端口被占 / 网络栈重启后原 listen 可能失效）。
   */
  async start(): Promise<void> {
    if (this.server) {
      return;
    }
    let lastErr: string = '';
    let srv: socket.TCPSocketServer | null = null;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        srv = socket.constructTCPSocketServerInstance();
        srv.on('connect', (client: socket.TCPSocketConnection) => {
          this.handle(client);
        });
        srv.on('error', (err: BusinessError) => {
          Log.e(`[LocalProxy] server error: ${err.message} ⇒ 标记为未启动`);
          this.server = null;
        });
        const addr: socket.NetAddress = {
          address: '127.0.0.1',
          port: LocalProxyServer.PORT
        } as socket.NetAddress;
        await srv.listen(addr);
        this.server = srv;
        Log.i(`[LocalProxy] 已监听 127.0.0.1:${LocalProxyServer.PORT}` +
          (attempt > 1 ? `（第 ${attempt} 次尝试成功）` : ''));
        return;
      } catch (e) {
        const err = e as BusinessError;
        lastErr = `${err.code ?? ''} ${err.message}`;
        Log.w(`[LocalProxy] 监听失败(第 ${attempt}/3 次): ${lastErr}`);
        if (srv !== null) {
          try {
            await srv.close();
          } catch (e2) {
            // 忽略：本来就没起来
          }
          srv = null;
        }
        if (attempt < 3) {
          await new Promise<void>((ok: () => void) => { setTimeout(() => { ok(); }, 400); });
        }
      }
    }
    throw new Error(`本地代理启动失败(已重试 3 次): ${lastErr}`);
  }

  /** 播放前确保服务在跑（失败只告警：真的起不来时播放器自己会报错） */
  async ensureStarted(): Promise<void> {
    if (this.server !== null) {
      return;
    }
    try {
      await this.start();
    } catch (e) {
      Log.e(`[LocalProxy] ensureStarted 失败: ${(e as Error).message}`);
    }
  }

  async stop(): Promise<void> {
    if (this.server) {
      try {
        await this.server.close();
      } catch (e) {
        // ignore
      }
      this.server = null;
    }
  }

  getStat(): SegStat {
    return this.stat;
  }

  /** 作废进行中的预热（退后台 / 换台） */
  abortPrewarm(): void {
    const g: number = ++this.prewarmGen;
    Log.i(`[LocalProxy] 已作废进行中的预热（prewarmGen=${g}）`);
  }

  /** 退后台挂起：不再转发任何数据（播放器此时也不需要），回前台立即恢复 */
  setSuspended(on: boolean): void {
    if (this.suspended === on) {
      return;
    }
    this.suspended = on;
    if (!on) {
      this.prewarmKey = '';
    }
    Log.i(`[LocalProxy] ${on ? '已挂起：后台不再转发' : '已恢复：可正常服务'}`);
  }

  /* ---------------- 交给 AVPlayer 的本地地址 ---------------- */

  /** 江苏台（荔枝 TV）：只带 streamId，**上游签名由代理现算**（重试/回前台复用不会用到过期签名） */
  static jstvPlaylistUrl(streamId: string): string {
    return `http://127.0.0.1:${LocalProxyServer.PORT}/jstv.m3u8?ch=${encodeURIComponent(streamId)}`;
  }

  /**
   * 央视频明文链路：只转发、不解密。
   * @param remote 明文 m3u8 上游地址（`YspLive.resolveLive()` 返回的 `url`）
   * @param guid   CDN 的 `UID`（必须与 cKey 载荷里的 guid 一致）
   */
  static yspPlaylistUrl(remote: string, guid: string): string {
    return `http://127.0.0.1:${LocalProxyServer.PORT}/ysp.m3u8` +
      `?u=${encodeURIComponent(remote)}&g=${encodeURIComponent(guid)}`;
  }

  /* ---------------- 内部工具 ---------------- */

  private static enc(): util.TextEncoder {
    return new util.TextEncoder();
  }

  private static dec(buf: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(buf);
  }

  /** 该 `#EXT-X-KEY` 行是否是播放器认识的 METHOD（标准值才允许透传） */
  private static isStandardKeyLine(line: string): boolean {
    const t: string = line.toUpperCase();
    const ok: string[] = ['METHOD=NONE', 'METHOD=AES-128', 'METHOD=SAMPLE-AES',
      'METHOD=SAMPLE-AES-CENC', 'METHOD=SAMPLE-AES-CTR'];
    for (const m of ok) {
      if (t.indexOf(m) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 从上游 playurl 里取 `pid=`（ChinaDRM 台密钥按 pid 选；取不到就空串 = 兜底 key） */
  private static pidOf(url: string): string {
    const q: number = url.indexOf('?');
    if (q < 0) {
      return '';
    }
    for (const kv of url.substring(q + 1).split('&')) {
      const i: number = kv.indexOf('=');
      if (i > 0 && kv.substring(0, i) === 'pid') {
        return kv.substring(i + 1);
      }
    }
    return '';
  }

  private static dropKey(order: string[], key: string): void {
    const i: number = order.indexOf(key);
    if (i >= 0) {
      order.splice(i, 1);
    }
  }

  private param(query: string, key: string): string {
    if (!query) {
      return '';
    }
    for (const kv of query.split('&')) {
      const i = kv.indexOf('=');
      if (i > 0 && kv.substring(0, i) === key) {
        try {
          return decodeURIComponent(kv.substring(i + 1));
        } catch (e) {
          return kv.substring(i + 1);
        }
      }
    }
    return '';
  }

  /** 相对路径转绝对（不依赖全局 URL 类） */
  private absUrl(base: string, rel: string): string {
    if (rel.startsWith('http://') || rel.startsWith('https://')) {
      return rel;
    }
    const schemeEnd = base.indexOf('://');
    const hostEnd = base.indexOf('/', schemeEnd + 3);
    const origin = hostEnd < 0 ? base : base.substring(0, hostEnd);
    if (rel.startsWith('/')) {
      return origin + rel;
    }
    const i = base.lastIndexOf('/');
    const prefix = i < schemeEnd + 3 ? (origin + '/') : base.substring(0, i + 1);
    return prefix + rel;
  }

  private handle(client: socket.TCPSocketConnection): void {
    let buf: Uint8Array = new Uint8Array(0);
    let handling = false;
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (handling) {
        return;
      }
      const part = new Uint8Array(info.message);
      const merged = new Uint8Array(buf.length + part.length);
      merged.set(buf, 0);
      merged.set(part, buf.length);
      buf = merged;
      const text = LocalProxyServer.dec(buf);
      if (text.indexOf('\r\n\r\n') < 0) {
        return;
      }
      handling = true;
      const firstLine = text.split('\r\n')[0];
      this.route(client, firstLine).catch((e: Error) => {
        Log.e(`[LocalProxy] route 异常: ${e.message}`);
        this.respond(client, 500, 'text/plain', new Uint8Array(0));
      });
    });
    client.on('error', (err: BusinessError) => {
      Log.e(`[LocalProxy] conn error: ${err.message}`);
    });
  }

  private async route(client: socket.TCPSocketConnection, reqLine: string): Promise<void> {
    const parts = reqLine.split(' ');
    if (parts.length < 2) {
      this.respond(client, 400, 'text/plain', new Uint8Array(0));
      return;
    }
    const method = parts[0].toUpperCase();
    const target = parts[1];
    const qIdx = target.indexOf('?');
    const path = qIdx < 0 ? target : target.substring(0, qIdx);
    const query = qIdx < 0 ? '' : target.substring(qIdx + 1);
    const remote = this.param(query, 'u');
    const isHead = (method === 'HEAD');

    if (this.playerAsked.size > 64) {
      this.playerAsked.clear();
    }
    if (remote.length > 0) {
      this.playerAsked.add(remote);
    }
    /* ★ 2026-11-08 诊断：把**播放器真正请求的路径**打出来。
     *   排查"DRM 台 prepare 6 秒超时"时必须先知道它到底请求了什么（之前只能看到 /ysp-seg）。 */
    Log.i(`[LocalProxy] --> ${method} ${path}${query.length > 0 ? '?' + query.substring(0, 70) : ''}…`);

    if (path === '/health') {
      this.respond(client, 200, 'text/plain', isHead ? new Uint8Array(0)
        : LocalProxyServer.enc().encodeInto('ok'));
      return;
    }
    if (this.suspended) {
      this.respond(client, 503, 'text/plain', new Uint8Array(0));
      return;
    }

    /* ---------- 江苏台（荔枝 TV）---------- */
    if (path === '/jstv.m3u8') {
      if (isHead) {
        this.respond(client, 200, M3U8_MIME, new Uint8Array(0));
        return;
      }
      const body: string | null = await this.loadJstvPlaylist(this.param(query, 'ch'), remote);
      if (body === null) {
        Log.w(`[LocalProxy] /jstv.m3u8 失败(502)`);
        this.respond(client, 502, 'text/plain', new Uint8Array(0));
        return;
      }
      this.respond(client, 200, M3U8_MIME, LocalProxyServer.enc().encodeInto(body));
      return;
    }
    if (path === '/jstv-seg') {
      if (isHead) {
        this.respond(client, 200, TS_MIME, new Uint8Array(0));
        return;
      }
      if (!remote) {
        this.respond(client, 400, 'text/plain', new Uint8Array(0));
        return;
      }
      const data: Uint8Array | null = await this.cachedOrFetchSeg(remote, true, '', false, '');
      if (data === null) {
        this.stat.failed++;
        this.respond(client, 502, 'text/plain', new Uint8Array(0));
        return;
      }
      this.stat.total++;
      this.respond(client, 200, TS_MIME, data);
      return;
    }

    /* ---------- 央视频（安卓平台，明文）---------- */
    if (path === '/ysp.m3u8') {
      if (isHead) {
        this.respond(client, 200, M3U8_MIME, new Uint8Array(0));
        return;
      }
      if (!remote) {
        this.respond(client, 400, 'text/plain', new Uint8Array(0));
        return;
      }
      let body: string | null = null;
      try {
        body = await this.loadYspPlaylist(remote, this.param(query, 'g'));
      } catch (e) {
        Log.w(`[LocalProxy] /ysp.m3u8 失败: ${(e as Error).message}`);
        body = null;
      }
      if (body === null) {
        Log.w(`[LocalProxy] /ysp.m3u8 失败(502): ${remote.substring(0, 80)}…`);
        this.respond(client, 502, 'text/plain', new Uint8Array(0));
        return;
      }
      this.respond(client, 200, M3U8_MIME, LocalProxyServer.enc().encodeInto(body));
      return;
    }
    if (path === '/ysp-seg') {
      if (isHead) {
        this.respond(client, 200, TS_MIME, new Uint8Array(0));
        return;
      }
      if (!remote) {
        this.respond(client, 400, 'text/plain', new Uint8Array(0));
        return;
      }
      /* `e=1` = 该台是 ChinaDRM 加密流（清单带 METHOD=SM4-CBC），`p` = 频道 pid（决定台密钥） */
      const enc: boolean = this.param(query, 'e') === '1';
      if (this.param(query, 'p').length > 0 || enc) {
        Log.i(`[LocalProxy] /ysp-seg enc=${enc} pid=${this.param(query, 'p')} u=${remote.substring(remote.length - 40)}`);
      }
      const data: Uint8Array | null = await this.cachedOrFetchSeg(remote, false,
        this.param(query, 'g'), enc, this.param(query, 'p'));
      if (data === null) {
        this.stat.failed++;
        this.respond(client, 502, 'text/plain', new Uint8Array(0));
        return;
      }
      this.stat.total++;
      this.respond(client, 200, TS_MIME, data);
      return;
    }

    this.respond(client, 404, 'text/plain', new Uint8Array(0));
  }

  /* ---------------- 央视频明文链路 ---------------- */

  /** 央视频 CDN 要求的头（`UID` 必须与取流时的 guid 一致） */
  private static yspHeaders(guid: string): Record<string, string> {
    return { 'User-Agent': 'qqlive', 'UID': guid };
  }

  /** 拉上游 m3u8 → 改写成"本地可播"清单（失败返回 null ⇒ 路由回 502） */
  private async loadYspPlaylist(up: string, guid: string): Promise<string | null> {
    const cached: PlCacheEntry | undefined = this.plCache.get(up);
    if (cached !== undefined && Date.now() - cached.at < cached.ttl) {
      return cached.body;
    }
    const inflight: Promise<string> | undefined = this.plInflight.get(up);
    if (inflight !== undefined) {
      return inflight;
    }
    const p: Promise<string> = this.doLoadYspPlaylist(up, guid).finally(() => {
      this.plInflight.delete(up);
    });
    this.plInflight.set(up, p);
    return p;
  }

  private async doLoadYspPlaylist(up: string, guid: string): Promise<string> {
    let raw: Uint8Array | null = null;
    let lastErr: string = '';
    for (let k = 0; k < 3; k++) {
      try {
        raw = await fetchRemoteWith(up, M3U8_MIME, LocalProxyServer.yspHeaders(guid));
        break;
      } catch (e) {
        lastErr = (e as Error).message;
        Log.w(`[LocalProxy] 央视频 playlist 拉取失败(第 ${k + 1}/3 次): ${lastErr}`);
        if (k < 2) {
          await new Promise<void>((ok: () => void) => { setTimeout(() => { ok(); }, 300); });
        }
      }
    }
    if (raw === null) {
      throw new Error(`playlist 拉取失败: ${lastErr}`);
    }
    const text: string = LocalProxyServer.dec(raw);
    const body: string = this.rewriteYspPlaylist(text, up, guid);
    /* 回看/时移的清单带 `#EXT-X-ENDLIST`（整段 VOD，实测 302 片）⇒ 缓存久一点 */
    const ttl: number = text.indexOf('#EXT-X-ENDLIST') >= 0
      ? LocalProxyServer.VOD_PL_TTL_MS : LocalProxyServer.YSP_PL_TTL_MS;
    this.plCache.set(up, { body: body, at: Date.now(), ttl: ttl } as PlCacheEntry);
    return body;
  }

  /**
   * 改写央视频 m3u8：分片/子清单行 → 走本地代理。
   *
   * ★★ 2026-11-08 真机定位的两个**必须**改写点（都与安卓 `CmgDataSource` 同口径）★★
   *   ① **剔掉非标准 `#EXT-X-KEY`**：加密台的清单里有
   *      `#EXT-X-KEY:METHOD=SM4-CBC,…` —— 播放器只认 `NONE/AES-128/SAMPLE-AES/…`，
   *      遇到 SM4-CBC **清单解析直接失败**（安卓 ExoPlayer 是 `PARSING_MANIFEST_MALFORMED`，
   *      鸿蒙 AVPlayer 表现为**永远没有视频分辨率/不出画**）。既然我们自己在代理里解密，
   *      这行对本机毫无意义 ⇒ 删除。**标准 AES 行原样保留**（不改变上游语义）。
   *   ② **纠正 `#EXT-X-TARGETDURATION`**（安卓 2026-11-03 定位的"回看/4K 周期性卡顿"根因）：
   *      上游常写 12，而真实分片 2~5 秒 ⇒ 播放器按 12 秒才刷一次清单 ⇒ 永远慢几片 ⇒ 缓冲吃干再重取。
   *      按台取固定值（4K = 2，其余 = 4），与安卓 `want = if (pid == PID_CCTV4K) 2 else 4` 一致。
   * ★ 不裁片、不加 `#EXT-X-START`（裁片只会减小缓冲）。
   */
  private rewriteYspPlaylist(text: string, base: string, guid: string): string {
    /* ★ ChinaDRM 台（8 个）：清单带 `METHOD=SM4-CBC` ⇒ 分片要 sm4c 解密。
     *   加密标记与 pid 都写进分片 URL，`/ysp-seg` 据此就地解密（缓存里存明文）。 */
    const enc: boolean = text.indexOf('METHOD=SM4-CBC') >= 0;
    const pid: string = LocalProxyServer.pidOf(base);
    const g: string = '&g=' + encodeURIComponent(guid) +
      (enc ? `&e=1&p=${encodeURIComponent(pid)}` : '');
    const out: string[] = [];
    for (const rawLine of text.replace('\r\n', '\n').split('\n')) {
      const line: string = rawLine.replace('\r', '');
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#')) {
        if (LocalProxyServer.STRIP_NONSTD_KEY && line.startsWith('#EXT-X-KEY') &&
          !LocalProxyServer.isStandardKeyLine(line)) {
          Log.i('[LocalProxy] 剔除非标准 #EXT-X-KEY（播放器无法解析该 METHOD）：' +
            line.substring(0, 60) + '…');
          continue;
        }
        /* ★ 2026-11-08：**不再改写 `#EXT-X-TARGETDURATION`**（先原样透传）
         *   安卓那边改 TD 是为了 ExoPlayer 的"清单刷新间隔"；鸿蒙 HiPlayer 的刷新策略不同，
         *   而把 12/7 改成 2/4 会**违反 HLS 规范**（TD 必须 ≥ ⌈max EXTINF⌉，实测分片 4.9~6.6s）
         *   ⇒ 真机表现为 `PrepareAsync failed with error -17`（起不来）。先按上游原值透传。 */
        out.push(line);
        continue;
      }
      const abs: string = this.absUrl(base, line);
      if (line.indexOf('.m3u8') >= 0) {
        out.push(`/ysp.m3u8?u=${encodeURIComponent(abs)}${g}`);
      } else {
        out.push(`/ysp-seg?u=${encodeURIComponent(abs)}${g}`);
      }
    }
    return out.join('\n');
  }

  /* ---------------- 江苏台（荔枝 TV）链路 ---------------- */

  private async loadJstvPlaylist(streamId: string, upUrl: string): Promise<string | null> {
    const ck: string = 'jstv|' + (upUrl.length > 0 ? upUrl : streamId);
    const inflight: Promise<string | null> | undefined = this.jstvPlInflight.get(ck);
    if (inflight !== undefined) {
      return inflight;
    }
    const p: Promise<string | null> = this.doLoadJstvPlaylist(streamId, upUrl, ck).finally(() => {
      this.jstvPlInflight.delete(ck);
    });
    this.jstvPlInflight.set(ck, p);
    return p;
  }

  private async doLoadJstvPlaylist(streamId: string, upUrl: string, ck: string): Promise<string | null> {
    const c: PlCacheEntry | undefined = this.plCache.get(ck);
    if (c !== undefined && Date.now() - c.at < c.ttl) {
      return c.body;
    }
    let up: string = upUrl;
    if (up.length === 0) {
      const ch: JstvChannel | undefined = jstvFind(streamId);
      if (ch === undefined) {
        Log.w(`[LocalProxy] 江苏台未知频道: ${streamId}`);
        return null;
      }
      up = jstvUpstreamUrl(ch);   /* 现算签名（native） */
    }
    if (up.length === 0) {
      return null;
    }
    let raw: Uint8Array | null = null;
    let lastErr: string = '';
    for (let k = 0; k < 3; k++) {
      try {
        raw = await fetchRemoteWith(up, M3U8_MIME, jstvHeaders());
        break;
      } catch (e) {
        lastErr = (e as Error).message;
        Log.w(`[LocalProxy] 江苏台 playlist 拉取失败(第 ${k + 1}/3 次): ${lastErr}`);
        if (k < 2) {
          await new Promise<void>((ok: () => void) => { setTimeout(() => { ok(); }, 300); });
        }
      }
    }
    if (raw === null) {
      Log.w(`[LocalProxy] 江苏台 playlist 最终失败: ${lastErr}`);
      return null;
    }
    const body: string = this.rewriteJstvPlaylist(LocalProxyServer.dec(raw), up);
    this.plCache.set(ck, {
      body: body, at: Date.now(), ttl: LocalProxyServer.JSTV_PL_TTL_MS
    } as PlCacheEntry);
    let segLines: number = 0;
    for (const l of body.split('\n')) {
      if (l.indexOf('/jstv-seg?') === 0) {
        segLines++;
      }
    }
    Log.i(`[LocalProxy] 江苏台 playlist 改写完成 分片 ${segLines} 条`);
    return body;
  }

  /** 改写江苏台 m3u8：分片/子清单行 → 本地代理（原文转发，不解密） */
  private rewriteJstvPlaylist(text: string, base: string): string {
    const out: string[] = [];
    for (const rawLine of text.replace('\r\n', '\n').split('\n')) {
      const line: string = rawLine.replace('\r', '');
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#')) {
        out.push(line);
        continue;
      }
      const abs: string = this.absUrl(base, line);
      if (line.indexOf('.m3u8') >= 0) {
        out.push(`/jstv.m3u8?u=${encodeURIComponent(abs)}`);
      } else {
        out.push(`/jstv-seg?u=${encodeURIComponent(abs)}`);
      }
    }
    return out.join('\n');
  }

  /* ---------------- 分片下载 / 缓存 ---------------- */

  /**
   * 命中缓存直接返回；否则下载（in-flight 去重）+ **按需 sm4c 解密** + 写缓存。
   * @param enc true = 该台是 ChinaDRM 加密流（清单带 METHOD=SM4-CBC）
   * @param pid 频道 pid（sm4c 按台取密钥）
   */
  private async cachedOrFetchSeg(url: string, isJstv: boolean, guid: string,
    enc: boolean, pid: string): Promise<Uint8Array | null> {
    const hit: SegCacheEntry | undefined = this.cachedSeg(url);
    if (hit !== undefined) {
      this.stat.cacheHits++;
      Log.i(`[LocalProxy] ◀ 分片命中缓存 ${hit.data.length}B`);
      return hit.data;
    }
    const data: Uint8Array | null = await this.fetchSeg(url, isJstv, guid, enc, pid);
    if (data !== null) {
      this.putSeg(url, data);   /* ★ 缓存里放的是**解密后**的明文 */
    }
    return data;
  }

  /**
   * 下载上游分片（in-flight 去重），需要时**就地 sm4c 解密**。
   * @param guid 央视频 CDN 的 `UID`（= cKey 载荷里的 guid；江苏台传空串）
   * @param enc  是否 ChinaDRM 加密台（8 个：CCTV-4K/11/12/14/15/16/16+/17）
   * @param pid  频道 pid（sm4c 台密钥）
   */
  private async fetchSeg(url: string, isJstv: boolean, guid: string,
    enc: boolean, pid: string): Promise<Uint8Array | null> {
    const existing: Promise<Uint8Array | null> | undefined = this.segInflight.get(url);
    if (existing !== undefined) {
      Log.i(`[LocalProxy] 分片下载 in-flight 命中，复用同一请求`);
      return existing;
    }
    const p: Promise<Uint8Array | null> = (async (): Promise<Uint8Array | null> => {
      try {
        const headers: Record<string, string> = isJstv ? jstvHeaders()
          : LocalProxyServer.yspHeaders(guid);
        let data: Uint8Array = await fetchRemoteWith(url, TS_MIME, headers);
        if (enc) {
          /* ★ ChinaDRM：解出**新的字节数组**（C 实现，2~3MB 一片）。
           *   ⚠️ 必须用返回值替换 `data`：native 侧是**另一份内存**，
           *      原地改写 ArkTS 的 buffer 不保证可见（2026-11-08 真机实测，见 `Sm4C.ets` 头注释）。 */
          const t0: number = Date.now();
          const dec: Uint8Array | null = Sm4C.decrypt(data, pid);
          if (dec !== null) {
            data = dec;
            Log.i(`[LocalProxy] sm4c 解密 ${data.length}B 用时=${Date.now() - t0}ms（pid=${pid}）`);
          }
        }
        return data;
      } catch (e) {
        Log.w(`[LocalProxy] 分片下载失败: ${(e as Error).message}`);
        return null;
      }
    })().finally(() => {
      this.segInflight.delete(url);
    });
    this.segInflight.set(url, p);
    return p;
  }

  private cachedSeg(key: string): SegCacheEntry | undefined {
    const e: SegCacheEntry | undefined = this.segCache.get(key);
    if (e === undefined) {
      return undefined;
    }
    if (Date.now() - e.at > LocalProxyServer.SEG_TTL_MS) {
      this.segCache.delete(key);
      this.segCacheBytes -= e.data.length;
      if (this.segCacheBytes < 0) {
        this.segCacheBytes = 0;
      }
      LocalProxyServer.dropKey(this.segOrder, key);
      return undefined;
    }
    return e;
  }

  /** 分片缓存当前占用（诊断用） */
  getSegCacheInfo(): string {
    return `${this.segOrder.length}片/${Math.round(this.segCacheBytes / 1048576 * 10) / 10}MB`;
  }

  private putSeg(key: string, data: Uint8Array): void {
    const old: SegCacheEntry | undefined = this.segCache.get(key);
    if (old !== undefined) {
      this.segCacheBytes -= old.data.length;
    }
    LocalProxyServer.dropKey(this.segOrder, key);
    this.segCache.set(key, { data: data, at: Date.now() } as SegCacheEntry);
    this.segOrder.push(key);
    this.segCacheBytes += data.length;
    while (this.segOrder.length > LocalProxyServer.SEG_CACHE_MAX ||
      (this.segCacheBytes > LocalProxyServer.SEG_CACHE_BYTES_MAX && this.segOrder.length > 1)) {
      const oldKey: string = this.segOrder.shift() as string;
      const e: SegCacheEntry | undefined = this.segCache.get(oldKey);
      if (e !== undefined) {
        this.segCacheBytes -= e.data.length;
        this.segCache.delete(oldKey);
      }
    }
    if (this.segCacheBytes < 0) {
      this.segCacheBytes = 0;
    }
  }

  /* ---------------- 预热 ---------------- */

  /**
   * 央视频明文链路预热：清单（优先用取流阶段自检已拉到的那份）+ 头部 2 片。
   *
   * ★ 下载后（**加密台**就地 sm4c 解密，明文台原样）直接进 `segCache` ⇒ 播放器请求时 0ms 命中。
   * @param seedPlaylist 取流阶段自检时已拉到的清单文本（空 = 现拉）
   */
  async prewarmYsp(remote: string, guid: string, seedPlaylist: string = ''): Promise<void> {
    if (this.suspended || remote.length === 0) {
      return;
    }
    const key: string = 'ysp|' + remote;
    if (key === this.prewarmKey && Date.now() - this.prewarmKeyAt < LocalProxyServer.PREWARM_SAME_KEY_MS) {
      Log.i(`[LocalProxy] prewarmYsp 同频道已于 ${Date.now() - this.prewarmKeyAt}ms 前启动 ⇒ 沿用进度`);
      return;
    }
    this.prewarmKey = key;
    this.prewarmKeyAt = Date.now();
    const myGen: number = ++this.prewarmGen;
    const t0: number = Date.now();
    try {
      let body: string;
      if (seedPlaylist.length > 0) {
        body = this.rewriteYspPlaylist(seedPlaylist, remote, guid);
        const ttl: number = seedPlaylist.indexOf('#EXT-X-ENDLIST') >= 0
          ? LocalProxyServer.VOD_PL_TTL_MS : LocalProxyServer.YSP_PL_TTL_MS;
        this.plCache.set(remote, { body: body, at: Date.now(), ttl: ttl } as PlCacheEntry);
        Log.i(`[LocalProxy] prewarmYsp[gen=${myGen}] 复用自检清单 ${body.length}B`);
      } else {
        body = await this.loadYspPlaylist(remote, guid) as string;
      }
      if (myGen !== this.prewarmGen || this.suspended) {
        return;
      }
      /* 预热也要解密（8 个 ChinaDRM 台）。
       * ⚠️ 判定**不能**用 `body.indexOf('METHOD=SM4-CBC')` —— `rewriteYspPlaylist` 已经把那条
       *   非标准 `#EXT-X-KEY` **删掉**了（播放器解析不了），所以改写后的清单里没有这个串。
       *   ⇒ 改看我们自己打到分片 URL 上的加密标记 `&e=1`（2026-11-08 真机踩过：这里判成 false
       *     ⇒ 预热把**密文**塞进缓存 ⇒ 播放器永远拿不到明文 ⇒ 8 个台全黑）。 */
      const enc: boolean = body.indexOf('&e=1') >= 0;
      const pid: string = enc ? LocalProxyServer.pidOf(remote) : '';
      const urls: string[] = [];
      for (const line of body.split('\n')) {
        if (line.indexOf('/ysp-seg?') !== 0) {
          continue;
        }
        const u: string = this.param(line.substring(line.indexOf('?') + 1), 'u');
        if (u.length > 0 && urls.length < LocalProxyServer.PREWARM_SEGS) {
          urls.push(u);
        }
      }
      for (const u of urls) {
        if (this.suspended || myGen !== this.prewarmGen) {
          return;
        }
        if (this.playerAsked.has(u) || this.cachedSeg(u) !== undefined) {
          continue;
        }
        const data: Uint8Array | null = await this.fetchSeg(u, false, guid, enc, pid);
        if (data === null || this.suspended || myGen !== this.prewarmGen) {
          return;
        }
        this.putSeg(u, data);
        Log.i(`[LocalProxy] ★ prewarmYsp 已预下载分片 ${data.length}B（共 ${Date.now() - t0}ms）`);
      }
      Log.i(`[LocalProxy] prewarmYsp 完成：${Date.now() - t0}ms｜分片缓存 ${this.getSegCacheInfo()}`);
    } catch (e) {
      Log.w(`[LocalProxy] prewarmYsp 失败（不影响播放）: ${(e as Error).message}`);
    }
  }

  /** 江苏台预热：清单 + 头部 2 片（无解密） */
  async prewarmJstv(streamId: string): Promise<void> {
    if (this.suspended || streamId.length === 0) {
      return;
    }
    const key: string = 'jstv|' + streamId;
    if (key === this.prewarmKey && Date.now() - this.prewarmKeyAt < LocalProxyServer.PREWARM_SAME_KEY_MS) {
      return;
    }
    this.prewarmKey = key;
    this.prewarmKeyAt = Date.now();
    const myGen: number = ++this.prewarmGen;
    const t0: number = Date.now();
    try {
      const body: string | null = await this.loadJstvPlaylist(streamId, '');
      if (body === null || this.suspended || myGen !== this.prewarmGen) {
        return;
      }
      const urls: string[] = [];
      for (const line of body.split('\n')) {
        if (line.indexOf('/jstv-seg?') !== 0) {
          continue;
        }
        const u: string = this.param(line.substring(line.indexOf('?') + 1), 'u');
        if (u.length > 0 && urls.length < LocalProxyServer.PREWARM_SEGS) {
          urls.push(u);
        }
      }
      for (const u of urls) {
        if (this.suspended || myGen !== this.prewarmGen) {
          return;
        }
        if (this.playerAsked.has(u) || this.cachedSeg(u) !== undefined) {
          continue;
        }
        const data: Uint8Array | null = await this.fetchSeg(u, true, '', false, '');
        if (data === null || this.suspended || myGen !== this.prewarmGen) {
          return;
        }
        this.putSeg(u, data);
      }
      Log.i(`[LocalProxy] prewarmJstv ${streamId} 完成：${Date.now() - t0}ms｜分片缓存 ${this.getSegCacheInfo()}`);
    } catch (e) {
      Log.w(`[LocalProxy] prewarmJstv 失败（不影响播放）: ${(e as Error).message}`);
    }
  }

  /* ---------------- HTTP 响应 ---------------- */

  private respond(client: socket.TCPSocketConnection, code: number, mime: string, body: Uint8Array): void {
    const head = `HTTP/1.1 ${code} ${code === 200 ? 'OK' : 'ERR'}\r\n` +
      `Content-Type: ${mime}\r\n` +
      `Content-Length: ${body.length}\r\n` +
      `Access-Control-Allow-Origin: *\r\n` +
      `Cache-Control: no-store\r\n` +
      `Connection: close\r\n\r\n`;
    const headBytes = LocalProxyServer.enc().encodeInto(head);
    const all = new Uint8Array(headBytes.length + body.length);
    all.set(headBytes, 0);
    all.set(body, headBytes.length);
    client.send({ data: all.buffer as ArrayBuffer })
      .then(() => {
        client.close();
      })
      .catch((e: Error) => {
        Log.e(`[LocalProxy] send 失败: ${e.message}`);
        try {
          client.close();
        } catch (e2) {
          // ignore
        }
      });
  }
}
