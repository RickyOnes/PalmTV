/**
 * LocalDecryptServer.ets —— 本地解密代理（方案 B 的核心）
 *
 * 目的：让 AVPlayer **只看到明文 TS**，完全不需要 ArkWeb / slim。
 *
 * 链路：
 *   ArkTS 拿到远端 m3u8（带一次性令牌）
 *     → AVPlayer 播放 http://127.0.0.1:18899/local.m3u8?u=<远端m3u8>
 *     → 本服务 /local.m3u8 拉取远端 playlist，把每个分片 URL 改写成 /local-seg?u=<分片URL>
 *     → AVPlayer 请求 /local-seg
 *     → 本服务下载原始 TS → CmgNative.decryptTsAsync()（**原地**解密，跑在 native work 线程）→ 返回明文 TS
 *
 * 端口固定 **18899**（早期 WebView 方案用的 18888 ArktsProxy 已删除，此处不再有冲突）。
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { CmgNative } from './CmgNative';
import { fetchRemote } from './TvHttp';

const TS_MIME = 'video/mp2t';
const M3U8_MIME = 'application/vnd.apple.mpegurl';

/**
 * ★ 判断该流是否为「明文流」（**不需要** CMG 解密）。
 *
 * 背景（真机实测 + 内部文档 §11.3/§14）：CCTV-6（pid=600108442，cnlId=2013693901）的 m3u8
 * 来自 `mobilelive-play-4.ysp.cctv.cn`，其 TS **本身未加密**（内部文档原话：
 * "仅 CCTV-6 能播 —— CCTV-6（mobilelive-play 源）流不加密；其他频道需 CMG 解密"）。
 * 原版走 CMG 的 JS 层、由它自己决定是否改动帧；我们这条 native 链路是**无条件解密**
 * 每个 type-1/5 NALU ⇒ 对明文流会把帧改坏 ⇒ 表现为"CCTV-6 不能正常播放"。
 *
 * 判据（任一命中即视为明文流）：
 *   ① CDN host 含 `mobilelive`（`mobilelive-play-4.ysp.cctv.cn`）
 *   ② URL 含 `m3u8_with_time_tag`（官方对该源使用的标记，CCTV-6 的 URL 里就有）
 */
function isNoDecryptUrl(url: string): boolean {
  const u: string = url.toLowerCase();
  return u.indexOf('mobilelive') >= 0 || u.indexOf('m3u8_with_time_tag') >= 0;
}

export interface SegStat {
  /** 已向播放器返回的分片总数（= 真解密 + 明文直通 + 缓存命中） */
  total: number;
  /** 真正调用过 native 解密的分片数（**不含**缓存命中；命中不再计入，避免指标失真） */
  decrypted: number;
  /** 缓存命中次数（已解密/明文缓存 + 已下载未解密缓存） */
  cacheHits: number;
  failed: number;
  lastMaPcs: number;
}

/** ★ 换台提速：playlist 缓存条目 */
interface PlCacheEntry {
  body: string;
  at: number;
}

/** ★ 换台提速：分片（已解密）缓存条目 */
interface SegCacheEntry {
  data: Uint8Array;
  at: number;
}

/**
 * 本地解密代理。
 * - 只需 `start()` 一次；之后 AVPlayer 用 `LocalDecryptServer.localPlaylistUrl(remote)` 取地址。
 */
export class LocalDecryptServer {
  private static readonly PORT: number = 18899;
  private server: socket.TCPSocketServer | null = null;
  private stat: SegStat = { total: 0, decrypted: 0, cacheHits: 0, failed: 0, lastMaPcs: 0 };
  /**
   * ★★ 换台提速（gate5）★★
   * playlist 缓存：AVPlayer 起播时会多次拉 playlist，缓存 3s（≈ 直播分片周期）即可命中。
   * 分片缓存：**已解密**的分片直接复用 ⇒ 免下载、免解密；保留最近 12 片。
   */
  private plCache: Map<string, PlCacheEntry> = new Map();
  private segCache: Map<string, SegCacheEntry> = new Map();
  /** ★ 原始（未解密）分片缓存：预热只做"并行下载"，解密留给播放器按需触发 ⇒ 首帧更快 */
  private rawCache: Map<string, SegCacheEntry> = new Map();
  /** ★ playlist 日志限流：每个 playlist key 最多打印 N 次（避免 HLS 刷新刷屏） */
  private plLogCount: Map<string, number> = new Map();
  /** ★ 调试开关：0 = 全部静默，1 = 只打首次，2 = 打前 2 次（默认），999 = 全打 */
  private static readonly PL_LOG_MAX: number = 2;
  /** 分片缓存键的插入顺序（超量时淘汰最早的） */
  private segOrder: string[] = [];
  private rawOrder: string[] = [];
  /** 分片缓存上限与有效期 */
  private static readonly SEG_CACHE_MAX: number = 12;
  private static readonly RAW_CACHE_MAX: number = 6;
  private static readonly SEG_TTL_MS: number = 120000;
  private static readonly PL_TTL_MS: number = 2000;
  /** 上一分片结束时的累计"未解帧数"（native 的 unchanged 是累计值，做差得本片值） */
  private lastUnchanged: number = 0;
  /** 上一分片结束时的累计"帧内重试次数"（同上，做差得本片值） */
  private lastRetries: number = 0;
  /** 上一分片结束时的累计"被跳过的短 type-1/5 NALU 数"（同上） */
  private lastShort: number = 0;
  /** 上一分片结束时的累计"被解成错误内容的帧数"（同上） */
  private lastBad: number = 0;
  /** ★ 新增：playlist 请求的 in-flight 去重（避免 prewarm 与 AVPlayer 重复下载同一份 m3u8） */
  private plInflight: Map<string, Promise<string>> = new Map();
  /** ★ 新增：prewarm 世代号（换台时让上一台的预热任务自动放弃） */
  private prewarmGen: number = 0;
  /**
   * ★★ 缓存键兜底（2026-09-16）★★
   *   live playlist 正常都有 `#EXT-X-MEDIA-SEQUENCE`，分片身份键 = `pid#mediaSequence+序号`。
   *   万一某次 playlist **缺**这个标签，mediaSeq 会恒为 0 ⇒ 刷新后的第 0/1/2 片与**上一轮**同键
   *   ⇒ 会把旧明文当新片返回（画面卡住/回放旧片）。这里用自增世代号给键加盐：
   *   同一份 playlist 内键稳定（缓存仍能命中），**跨刷新**必然换键（宁可失效，绝不返回错片）。
   */
  private plGen: number = 0;
  /** ★ 新增：分片下载的 in-flight 去重（prewarm 与 AVPlayer 并发请求同一分片时共享） */
  private segInflight: Map<string, Promise<Uint8Array | null>> = new Map();

  /**
   * 启动服务（幂等）。
   * ★★ 2026-09-16 加固：这是**单点**——本地代理起不来 ⇒ 整条播放链路不可用。
   *   原来只 `listen()` 一次、失败就直接抛给 bootSequence（此后永远不可用）。
   *   现在：最多重试 3 次（400ms 退避）；`error` 回调里把 server 置空，
   *   下次 playChannel 前的 `ensureStarted()` 会重新拉起。
   */
  async start(): Promise<void> {
    if (this.server) {
      return;
    }
    let lastErr: string = '';
    let srv: socket.TCPSocketServer | null = null;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        // ★ 鸿蒙没有 `new socket.TCPSocketServer()`：必须用工厂函数拿到实例
        srv = socket.constructTCPSocketServerInstance();
        srv.on('connect', (client: socket.TCPSocketConnection) => {
          this.handle(client);
        });
        srv.on('error', (err: BusinessError) => {
          // ★ 服务级错误（socket 被回收 / 网络栈重启）⇒ 置空，交给 ensureStarted 重建
          console.error(`[LocalDecrypt] server error: ${err.message} ⇒ 标记为未启动`);
          this.server = null;
        });
        // ★ listen() 收的是 NetAddress（不是裸端口号）
        const addr: socket.NetAddress = {
          address: '127.0.0.1',
          port: LocalDecryptServer.PORT
        } as socket.NetAddress;
        await srv.listen(addr);
        this.server = srv;
        console.info(`[LocalDecrypt] 已监听 127.0.0.1:${LocalDecryptServer.PORT}` +
          (attempt > 1 ? `（第 ${attempt} 次尝试成功）` : ''));
        return;
      } catch (e) {
        const err = e as BusinessError;
        lastErr = `${err.code ?? ''} ${err.message}`;
        console.warn(`[LocalDecrypt] 监听失败(第 ${attempt}/3 次): ${lastErr}`);
        /* 失败的那个实例要关掉，避免"重试 3 次留下 3 个半死实例" */
        if (srv !== null) {
          try {
            await srv.close();
          } catch (e2) {
            // 忽略：本来就没起来
          }
          srv = null;
        }
        if (attempt < 3) {
          await new Promise<void>((ok: () => void) => {
            setTimeout(() => { ok(); }, 400);
          });
        }
      }
    }
    throw new Error(`本地解密服务启动失败(已重试 3 次): ${lastErr}`);
  }

  /** 播放前确保服务在跑（失败只告警：真的起不来时播放器自己会报错） */
  async ensureStarted(): Promise<void> {
    if (this.server !== null) {
      return;
    }
    try {
      await this.start();
    } catch (e) {
      console.error(`[LocalDecrypt] ensureStarted 失败: ${(e as Error).message}`);
    }
  }

  /**
   * ★ 作废进行中的预热（退后台时调用）。
   *
   * 为什么需要：直播流在后台继续"下载 + 解密"**毫无意义**（m3u8 令牌/分片都会过期，
   * 回前台 ≤10s 才续播、>10s 直接重新取流）⇒ 退后台时把预热世代号推进一格，
   * 预热任务在每个 await 之后自检并放弃，不再占用带宽/CPU。
   * （播放器自身的分片请求由 `pause()` 自然停止 —— 我们没有任何主动下载了。）
   */
  abortPrewarm(): void {
    const g: number = ++this.prewarmGen;
    console.info(`[LocalDecrypt] 已作废进行中的预热（prewarmGen=${g}，退后台不再下载/解密）`);
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

  /**
   * 给 AVPlayer 用的本地 playlist 地址。
   * @param remoteM3u8 远端 m3u8（带一次性令牌）
   * @param chanKey    ★ 频道标识（cnlId）：**缓存键兜底**用 —— 万一远端 m3u8 的 query 里
   *                   没有 `pid`，退回用它，避免键退化成 URL/空值（那会导致缓存永不命中或错片）。
   */
  static localPlaylistUrl(remoteM3u8: string, chanKey: string = ''): string {
    const ck: string = chanKey.length > 0 ? `&ck=${encodeURIComponent(chanKey)}` : '';
    return `http://127.0.0.1:${LocalDecryptServer.PORT}/local.m3u8?u=${encodeURIComponent(remoteM3u8)}${ck}`;
  }

  // ---------------- 内部 ----------------

  private static enc(): util.TextEncoder {
    return new util.TextEncoder();
  }

  private static dec(buf: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeToString(buf);
  }

  private handle(client: socket.TCPSocketConnection): void {
    let buf: Uint8Array = new Uint8Array(0);
    let handling = false; // ★ 同一连接只处理一个请求（响应后即 close，防止分片重复路由）
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (handling) {
        return;
      }
      const part = new Uint8Array(info.message);
      const merged = new Uint8Array(buf.length + part.length);
      merged.set(buf, 0);
      merged.set(part, buf.length);
      buf = merged;
      const text = LocalDecryptServer.dec(buf);
      if (text.indexOf('\r\n\r\n') < 0) {
        return; // HTTP 头还没收完
      }
      handling = true;
      // 只取请求行（GET 无 body，无需等 Content-Length）
      const firstLine = text.split('\r\n')[0];
      this.route(client, firstLine).catch((e: Error) => {
        console.error(`[LocalDecrypt] route 异常: ${e.message}`);
        this.respond(client, 500, 'text/plain', new Uint8Array(0));
      });
    });
    client.on('error', (err: BusinessError) => {
      console.error(`[LocalDecrypt] conn error: ${err.message}`);
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
    /* ★ 缓存键：优先用 playlist 改写时塞进来的稳定键 `k`（pid + mediaSequence + 序号）；
     *   没有 k（旧地址/异常）时退化为按 URL 缓存，行为与旧版一致。 */
    const ck: string = this.param(query, 'k');
    const cacheKey: string = ck.length > 0 ? ck : remote;
    // HLS 拉流器常先发 HEAD 探测，这里只需给头（空 body），否则会被判 4xx 而放弃播放
    const isHead = (method === 'HEAD');

    if (path === '/health') {
      this.respond(client, 200, 'text/plain', isHead ? new Uint8Array(0) : LocalDecryptServer.enc().encodeInto('ok'));
      return;
    }
    if (!remote) {
      this.respond(client, 400, 'text/plain', new Uint8Array(0));
      return;
    }
    if (path === '/local.m3u8') {
      if (isHead) {
        this.respond(client, 200, M3U8_MIME, new Uint8Array(0));
        return;
      }
      /* ★ 换台提速：命中 playlist 缓存（2s 内）就直接回，省一次 CDN 往返 */
      const pl: PlCacheEntry | undefined = this.plCache.get(remote);
      if (pl !== undefined && Date.now() - pl.at < LocalDecryptServer.PL_TTL_MS) {
        this.respond(client, 200, M3U8_MIME, LocalDecryptServer.enc().encodeInto(pl.body));
        return;
      }
      const body = await this.buildLocalPlaylist(remote, this.param(query, 'ck'));
      this.respond(client, 200, M3U8_MIME, LocalDecryptServer.enc().encodeInto(body));
      return;
    }
    if (path === '/local-seg') {
      /* ★ 新增：请求入口时间戳（用于分析 AVPlayer 请求了哪些片、间隔多久） */
      const tReq: number = Date.now();
      console.info(`[LocalDecrypt] ▶ /local-seg 请求 k=${cacheKey} at ${tReq}`);
      if (isHead) {
        // 不下载分片：HEAD 只回报类型与长度未知
        this.respond(client, 200, TS_MIME, new Uint8Array(0));
        return;
      }
      /* ★★★ 明文流直通（raw=1）★★★ */
      if (this.param(query, 'raw') === '1') {
        const rawHit: SegCacheEntry | undefined = this.cachedSeg(cacheKey);
        if (rawHit !== undefined) {
          console.info(`[LocalDecrypt] seg（明文流）命中缓存 ${rawHit.data.length}B（提速）`);
          this.stat.total++;
          this.stat.cacheHits++;   /* ★ 命中缓存**不算解密**（2026-09-16 修：原计入 decrypted，指标失真） */
          console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=segCache(明文) 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
          this.respond(client, 200, TS_MIME, rawHit.data);
          return;
        }
        try {
          /* ★★★ 修复（2026-09-16）★★★
           *   原实现直接 fetchRemote，绕过了 fetchSegRaw 的 in-flight 去重
           *   ⇒ prewarm 与 AVPlayer 各下载一份同一分片，双倍带宽占用
           *   （日志铁证：gen=4 明文流频道全程无 "分片下载 in-flight 命中"）
           *   改为走 fetchSegRaw ⇒ 与加密流一致，共享同一份下载 Promise。 */
          const rawSeg: Uint8Array | null = await this.fetchSegRaw(remote);
          if (rawSeg === null) {
            throw new Error('fetchSegRaw 返回 null');
          }
          this.stat.total++;
          this.putSeg(cacheKey, rawSeg);
          console.info(`[LocalDecrypt] seg#${this.stat.total} 明文流直通(未解密) ${rawSeg.length}B`);
          console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=网络(明文) 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
          this.respond(client, 200, TS_MIME, rawSeg);
        } catch (e) {
          const err = e as Error;
          console.error(`[LocalDecrypt] 明文流分片下载失败: ${err.message}`);
          console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=502(明文) 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
          this.respond(client, 502, 'text/plain', new Uint8Array(0));
        }
        return;
      }
      /* ★★ 换台提速：命中"已解密分片"缓存 ⇒ 秒回（免下载 + 免解密）★★ */
      const hit: SegCacheEntry | undefined = this.cachedSeg(cacheKey);
      if (hit !== undefined) {
        console.info(`[LocalDecrypt] seg 命中缓存 ${hit.data.length}B（提速，key=${cacheKey}）`);
        this.stat.total++;
        this.stat.cacheHits++;   /* ★ 命中缓存不算解密 */
        console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=segCache 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
        this.respond(client, 200, TS_MIME, hit.data);
        return;
      }
      /* ★★ 命中"已下载未解密"缓存（预热只下载不预解）⇒ 立刻解密并返回 ★★ */
      const rawHit: SegCacheEntry | undefined = this.cachedRaw(cacheKey);
      if (rawHit !== undefined) {
        console.info(`[LocalDecrypt] seg 命中已下载缓存 ${rawHit.data.length}B ⇒ 立即解密`);
        /* ★ 解密已异步化（native work 线程 + 单锁串行）⇒ 不再阻塞 JS 线程 */
        const dec: Uint8Array | null = await this.decryptRaw(rawHit.data);
        if (dec !== null) {
          this.putSeg(cacheKey, dec);
          console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=rawCache(已解密) 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
          this.respond(client, 200, TS_MIME, dec);
          return;
        }
        console.warn(`[LocalDecrypt] 已下载缓存解密失败 ⇒ 丢弃该缓存并重新下载: k=${cacheKey}`);
        this.rawCache.delete(cacheKey);
      }
      const data = await this.decryptSegment(remote);
      if (data === null) {
        console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=502 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
        this.respond(client, 502, 'text/plain', new Uint8Array(0));
        return;
      }
      this.putSeg(cacheKey, data);
      console.info(`[LocalDecrypt] ◀ /local-seg 响应 k=${cacheKey} 来源=网络(已解密) 耗时=${Date.now() - tReq}ms at ${Date.now()}`);
      this.respond(client, 200, TS_MIME, data);
      return;
    }
    this.respond(client, 404, 'text/plain', new Uint8Array(0));
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

  /**
   * ★ playlist 构建入口（in-flight 去重）：
   *   prewarm 与 AVPlayer 的 /local.m3u8 请求几乎同时到达 ⇒ 两者都会 await fetchRemote，
   *   造成 CDN 被拉两次、plCache 被覆盖两次（日志里"playlist 改写完成"打两次即此）。
   *   这里用 map 让同 remote 的并发请求共享同一个 Promise。
   */
  private async buildLocalPlaylist(remote: string, chanKey: string = ''): Promise<string> {
    const existing: Promise<string> | undefined = this.plInflight.get(remote);
    if (existing !== undefined) {
      console.info(`[LocalDecrypt] playlist in-flight 命中，复用同一请求: ${remote.substring(0, 60)}…`);
      return existing;
    }
    const p: Promise<string> = this.doBuildLocalPlaylist(remote, chanKey).finally(() => {
      this.plInflight.delete(remote);
    });
    this.plInflight.set(remote, p);
    return p;
  }

  /**
   * playlist 实体：拉取远端 m3u8 → 裁片 → 改写分片地址 → 写 plCache。
   * 由 buildLocalPlaylist 统一加锁，外部不要直接调。
   */
  private async doBuildLocalPlaylist(remote: string, chanKey: string = ''): Promise<string> {
    let raw: Uint8Array | null = null;
    let lastErr: string = '';
    for (let k = 0; k < 3; k++) {
      try {
        raw = await fetchRemote(remote, M3U8_MIME);
        break;
      } catch (e) {
        const err = e as BusinessError;
        lastErr = err.message;
        console.warn(`[LocalDecrypt] playlist 拉取失败(第 ${k + 1}/3 次): ${lastErr}`);
        if (k < 2) {
          await new Promise<void>((resolve: () => void) => {
            setTimeout(() => { resolve(); }, 300);
          });
        }
      }
    }
    if (raw === null) {
      throw new Error(`playlist 拉取失败(已重试 3 次): ${lastErr}`);
    }
    const text = LocalDecryptServer.dec(raw);
    const noDec: boolean = isNoDecryptUrl(remote);
    if (noDec) {
      console.info(`[LocalDecrypt] 判定为明文流（不解密，原样透传）: ${remote.substring(0, 80)}`);
    }
    const lines = text.split('\n');
    let segCount = 0;
    let mediaSeq: number = 0;
    let hasSeq: boolean = false;
    for (const rawLine of lines) {
      const t: string = rawLine.replace('\r', '');
      if (t.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        const n: number = Number(t.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim());
        mediaSeq = Number.isFinite(n) ? n : 0;
        hasSeq = true;
      }
    }
    /* ★★ 缓存键的三层兜底（2026-09-16）★★
     *   正常：`pid#mediaSequence+序号`（pid 来自远端 m3u8 的 query）。
     *   ① 远端没带 pid ⇒ 用本地地址传下来的 `ck`（= 频道 cnlId，`localPlaylistUrl` 塞的）；
     *   ② 连 cnlId 都没有 ⇒ 用"playlist 世代号"（每份 playlist 一个独立命名空间，绝不跨片复用）；
     *   ③ playlist 缺 `#EXT-X-MEDIA-SEQUENCE` ⇒ 序号用世代号×100000 打底，
     *      宁可缓存不命中，**也绝不能把上一轮的同号分片当成新片返回**（那就是"错片"）。 */
    const qAt: number = remote.indexOf('?');
    let pidKey: string = qAt < 0 ? '' : this.param(remote.substring(qAt + 1), 'pid');
    if (pidKey.length === 0 && chanKey.length > 0) {
      pidKey = chanKey;
      console.warn(`[LocalDecrypt] playlist URL 无 pid ⇒ 缓存键改用频道标识 ck=${chanKey}`);
    }
    if (pidKey.length === 0) {
      pidKey = `pl${this.plGen++}`;
      console.warn('[LocalDecrypt] playlist URL 无 pid 且未带 ck ⇒ 缓存键退化为 playlist 世代编号（缓存不跨刷新复用）');
    }
    const seqBase: number = hasSeq ? mediaSeq : (this.plGen++ * 100000);
    if (!hasSeq) {
      console.warn('[LocalDecrypt] playlist 缺 #EXT-X-MEDIA-SEQUENCE ⇒ 分片键用世代号打底（防错片）');
    }

    const pre: string[] = [];
    const blocks: string[][] = [];
    let cur: string[] = [];
    for (const rawLine of lines) {
      const line: string = rawLine.replace('\r', '');
      if (line.length === 0) {
        continue;
      }
      if (line.startsWith('#')) {
        if (line.startsWith('#EXTINF')) {
          cur = [line];
        } else if (cur.length > 0) {
          cur.push(line);
        } else {
          pre.push(line);
        }
        continue;
      }
      cur.push(line);
      blocks.push(cur);
      cur = [];
    }

    /* ★★★ 起播提速：本地 playlist 只暴露最后 `KEEP_SEGMENTS` 片 ★★★
     *   **现行值 = 2**（实测定稿，见 `PalmTV/开发笔记` §3/§4）：
     *     - 3 片 ⇒ 播放器必然取 3 片（冷切 ~2.4s）；
     *     - 2 片 ⇒ 取 2 片（典型 **~1.8s**，已优于官方 App）；
     *     - **1 片不能播**（AVPlayer 需 ≥2 片建可 seek 时间轴）；
     *     - `0` = 不裁（回退用）。
     *   ⚠️ 曾试过"只给 1 片"⇒ 不能播放；播放器侧的起播水线也**改不了取片数**（已证伪，别重试）。 */
    const KEEP_SEGMENTS: number = 2;
    const isMediaPlaylist: boolean = text.indexOf('#EXTINF') >= 0;
    const dropN: number = (isMediaPlaylist && KEEP_SEGMENTS > 0)
      ? Math.max(0, blocks.length - KEEP_SEGMENTS) : 0;

    const out: string[] = [];
    for (const l of pre) {
      if (l.startsWith('#EXT-X-MEDIA-SEQUENCE:') && dropN > 0) {
        out.push(`#EXT-X-MEDIA-SEQUENCE:${mediaSeq + dropN}`);
      } else {
        out.push(l);
      }
    }
    /* ★★★ EXT-X-START 已**移除**（2026-09-16 定稿，不再是"待验证实验"）★★★
     *   原实现：`out.push('#EXT-X-START:TIME-OFFSET=0')` —— 意图是"从直播边缘起播"；
     *   实测在"只暴露最后 2 片"的形状下加不加**都不改变取片数**（都是 2 片），
     *   而它会让 AVPlayer 走"边缘优先"分支，可能与自身策略叠加出未定义行为
     *   ⇒ 去掉后完全按 playlist 顺序 + 播放器策略决定起播。 */

    for (let bi = 0; bi < blocks.length; bi++) {
      const blk: string[] = blocks[bi];
      const uri: string = blk[blk.length - 1];
      const key: string = `${pidKey}#${seqBase + bi}`;
      segCount++;
      if (bi < dropN) {
        continue;
      }
      for (let i = 0; i < blk.length - 1; i++) {
        out.push(blk[i]);
      }
      const abs: string = this.absUrl(remote, uri);
      if (uri.indexOf('.m3u8') >= 0) {
        out.push(`/local.m3u8?u=${encodeURIComponent(abs)}`);
      } else {
        out.push(`/local-seg?${noDec ? 'raw=1&' : ''}k=${encodeURIComponent(key)}&u=${encodeURIComponent(abs)}`);
      }
    }
    /* ★ 限流：每个频道（pidKey）最多打印 PL_LOG_MAX 次
 *   原因：HLS 直播每 2~4 秒刷新一次 playlist，每次都打印会刷屏。
 *   排障时如需完整日志，把 PL_LOG_MAX 改成 999 即可。 */
    const logKey: string = pidKey.length > 0 ? pidKey : remote;
    const cnt: number = this.plLogCount.get(logKey) ?? 0;
    this.plLogCount.set(logKey, cnt + 1);
    if (cnt < LocalDecryptServer.PL_LOG_MAX) {
      console.info(`[LocalDecrypt] playlist 改写完成，分片 ${segCount} 条` +
        (dropN > 0 ? `（裁掉前 ${dropN} 条，只留最后 ${KEEP_SEGMENTS} 条以促起播）` : '') +
        `｜键前缀=${pidKey} 起始序号=${seqBase}` +  (cnt > 0 ? `（第 ${cnt + 1} 次，后续静默）` : ''));
    }
    const body: string = out.join('\n');
    this.plCache.set(remote, { body: body, at: Date.now() } as PlCacheEntry);
    return body;
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

  /** 下载原始 TS 并原地解密（/local-seg 未命中缓存时走这里） */
  private async decryptSegment(remote: string): Promise<Uint8Array | null> {
    const raw: Uint8Array | null = await this.fetchSegRaw(remote);
    if (raw === null) {
      return null;
    }
    return this.decryptRaw(raw);
  }

  /**
   * 只下载原始 TS（预热用：可并行，把网络等待重叠起来）。
   * ★★★ 分片级 in-flight 去重（2026-09-16）★★★
   *   场景：prewarm 已在下载 seg#1，AVPlayer 的 /local-seg 请求也来下载 seg#1
   *   ⇒ 原实现发起两次 fetchRemote，两个请求抢带宽，各自慢一倍（实测 2450ms vs 408ms）。
   *   修复：同一 URL 的并发下载共享同一个 Promise，谁先发起谁干活、其他人复用结果。
   */
  private async fetchSegRaw(remote: string): Promise<Uint8Array | null> {
    const existing: Promise<Uint8Array | null> | undefined = this.segInflight.get(remote);
    if (existing !== undefined) {
      console.info(`[LocalDecrypt] 分片下载 in-flight 命中，复用同一请求: ${remote.substring(0, 60)}…`);
      return existing;
    }
    const p: Promise<Uint8Array | null> = (async (): Promise<Uint8Array | null> => {
      try {
        return await fetchRemote(remote, TS_MIME);
      } catch (e) {
        const err = e as Error;
        this.stat.failed++;
        console.warn(`[LocalDecrypt] 分片下载失败: ${err.message}`);
        return null;
      }
    })().finally(() => {
      this.segInflight.delete(remote);
    });
    this.segInflight.set(remote, p);
    return p;
  }

  /**
   * 解密原始 TS 并更新统计/日志（**异步**：解密在 native work 线程执行）。
   *
   * ★★ CMG 解密**有状态**，必须**顺序**调用：native 侧用一把全局互斥锁串行化，
   *   `CmgNative.decryptTsAsync` 再在 JS 侧排一条队列 ⇒ "并行下载 + 按序解密"仍然成立，
   *   但 **JS 线程不再被 0.3~0.7s 的解密阻塞**（UI/HTTP 服务/播放器请求可与之重叠）。
   *
   * ★★ 失败返回 `null`（2026-09-16 修）：原实现失败时把（可能已被半改写的）缓冲当明文返回
   *   ⇒ 解码器拿到错字节 ⇒ 花屏；现在交给上层回 502，由播放器/看门狗重试。
   */
  private async decryptRaw(raw: Uint8Array): Promise<Uint8Array | null> {
    try {
      this.stat.total++;
      const ab = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
      /* ★ 计时：解密耗时直接决定首播速度 ⇒ 必须量化（现在它是"等待"，不再阻塞 JS 线程） */
      const tDec: number = Date.now();
      const n: number = await CmgNative.decryptTsAsync(ab);
      const decMs: number = Date.now() - tDec;
      const st = CmgNative.stat();
      this.stat.lastMaPcs = st.lastMaPcs;
      if (n < 0) {
        this.stat.failed++;
        console.error(`[LocalDecrypt] 解密失败: ${n} (lastMaPcs=${st.lastMaPcs}) ⇒ 该片回 502 由播放器重试`);
        return null;
      }
      this.stat.decrypted++;
      // ★ 每个分片打一行，这是判断"解密是否解全"的关键指标：
      //   未解 = 本片内「输出与输入逐字节相同」的帧数（>0 说明有帧没解开 ⇒ 花屏/绿屏）；
      //   重启 = native 侧检测到 CMG 会话死亡并自动原地重启的次数（正常应为 0 或偶尔 1）。
      //   （时钟是**真实墙钟**（setClockReal），日志只影响耗时、不影响解密结果，可以放心打。）
      const un = st.unchanged - this.lastUnchanged;
      this.lastUnchanged = st.unchanged;
      const rt = st.retries - this.lastRetries;
      this.lastRetries = st.retries;
      const sn = st.shortNalus - this.lastShort;
      this.lastShort = st.shortNalus;
      const bd = st.badNalus - this.lastBad;
      this.lastBad = st.badNalus;
      //   未解 = 本片内「重试耗尽后仍与输入逐字节相同」的帧数 ⇒ **必须为 0**（>0 才会花屏）；
      //   重试 = 本片内「当帧检出衰减并整机重启重解」的次数 ⇒ 0~2 属正常（说明自愈生效、且没丢帧）；
      //   错帧 = 本片内「动了字节但 NAL 头不合法 = 被解成错误内容」的帧数 ⇒ 已当帧重解自愈；
      //          **>0 就是"大面积马赛克"的直接指纹**（这是本轮新加的判据，旧版本抓不到这种帧）；
      //   短片 = 本片内被跳过的"短 type-1/5 NALU"数（<64B）⇒ 绝大多数是密文里假起始码切出的**伪 NALU**；
      //          这个数明显 >0 就说明解复用还在切伪 NALU（不能靠放开长度过滤去解它们，实测会大面积花屏）；
      //   重启 = native 侧原地重启累计（含每 90 帧的定时预防重启）。
      console.info(`[LocalDecrypt] seg#${this.stat.total} nalu=${n} 解密=${decMs}ms 未解=${un} 重试=${rt} 错帧=${bd} 短片=${sn} ` +
        `重启=${st.restarts} reseeds=${st.reseeds} lastMaPcs=${st.lastMaPcs} at ${Date.now()}`);
      return new Uint8Array(ab);
    } catch (e) {
      this.stat.failed++;
      console.error(`[LocalDecrypt] 解密异常: ${(e as Error).message}`);
      return null;
    }
  }

  /**
   * 取缓存分片（含有效期判断）；未命中返回 undefined。
   * ★ 2026-09-16：过期时**同时**把它从淘汰队列里摘掉 —— 否则残留的旧键会在后续淘汰时
   *   误伤"同键的新条目"（同一 key 二次写入后，旧键被 shift 时 delete 掉的是新数据）。
   */
  private cachedSeg(remote: string): SegCacheEntry | undefined {
    const e: SegCacheEntry | undefined = this.segCache.get(remote);
    if (e === undefined) {
      return undefined;
    }
    if (Date.now() - e.at > LocalDecryptServer.SEG_TTL_MS) {
      this.segCache.delete(remote);
      LocalDecryptServer.dropKey(this.segOrder, remote);
      return undefined;
    }
    return e;
  }

  /** 写缓存分片（超过上限时淘汰最早的；同一 key 只保留**一个**队列位置） */
  private putSeg(remote: string, data: Uint8Array): void {
    LocalDecryptServer.dropKey(this.segOrder, remote);   /* ★ 去重：防"同键二次写入"把新条目淘汰掉 */
    this.segCache.set(remote, { data: data, at: Date.now() } as SegCacheEntry);
    this.segOrder.push(remote);
    while (this.segOrder.length > LocalDecryptServer.SEG_CACHE_MAX) {
      const old: string = this.segOrder.shift() as string;
      this.segCache.delete(old);
    }
    /* 已解密 ⇒ 原始副本就没用了，顺手释放（省内存） */
    this.rawCache.delete(remote);
    LocalDecryptServer.dropKey(this.rawOrder, remote);
  }

  /** 从淘汰队列里摘掉一个键（不存在则什么都不做） */
  private static dropKey(order: string[], key: string): void {
    const i: number = order.indexOf(key);
    if (i >= 0) {
      order.splice(i, 1);
    }
  }

  /** 取"已下载未解密"的分片 */
  private cachedRaw(remote: string): SegCacheEntry | undefined {
    const e: SegCacheEntry | undefined = this.rawCache.get(remote);
    if (e === undefined) {
      return undefined;
    }
    if (Date.now() - e.at > LocalDecryptServer.SEG_TTL_MS) {
      this.rawCache.delete(remote);
      LocalDecryptServer.dropKey(this.rawOrder, remote);
      return undefined;
    }
    return e;
  }

  /** 写"已下载未解密"的分片（超过上限淘汰最早的；同一 key 只保留一个队列位置） */
  private putRaw(remote: string, data: Uint8Array): void {
    LocalDecryptServer.dropKey(this.rawOrder, remote);
    this.rawCache.set(remote, { data: data, at: Date.now() } as SegCacheEntry);
    this.rawOrder.push(remote);
    while (this.rawOrder.length > LocalDecryptServer.RAW_CACHE_MAX) {
      const old: string = this.rawOrder.shift() as string;
      this.rawCache.delete(old);
    }
  }

  /**
   * ★★★ 换台提速：预热 playlist + **playlist 头部 2 片**（只下载、不预解密）★★★
   *
   *   要点（都是实测结论，别改回去）：
   *   1) 预热**头部**（不是尾部）：AVPlayer 是按 playlist 顺序从第一片开始请求的
   *      （日志铁证：取尾部时 seg#1 耗时 870ms 走网络、seg#2 327ms 命中 rawCache）；
   *   2) 只**下载**、不预解密：解密有状态且（原先）阻塞 JS 线程，
   *      若预热顺手解密会把播放器"自己那片"的解密排在后面（历史实测 +1.2s）；
   *      现在解密已异步化，但"谁先请求谁先解"依然是更优的临界路径；
   *   3) 逐片下载、下完立即写 rawCache（不等 Promise.all），播放器请求可提前命中；
   *   4) **世代号**：快速切台时旧预热的每个 await 之后都会自检并放弃，
   *      避免"切到 CCTV-2，但 prewarm 还在下 CCTV-6 的分片"。
   *
   * @param chanKey 频道标识（cnlId）：与 `localPlaylistUrl` 的 `ck` 一致，保证缓存键相同
   */
  async prewarm(remoteM3u8: string, chanKey: string = ''): Promise<void> {
    const myGen: number = ++this.prewarmGen;
    /* ★ 更简单：切台时清空所有频道的日志计数（保证每次切台都有日志） */
    this.plLogCount.clear();
    try {
      const t0: number = Date.now();
      console.info(`[LocalDecrypt] prewarm[gen=${myGen}] 开始`);
      const body: string = await this.buildLocalPlaylist(remoteM3u8, chanKey);
      if (myGen !== this.prewarmGen) {
        console.info(`[LocalDecrypt] prewarm[gen=${myGen}] 被新台取代 ⇒ 放弃（在 playlist 之后）`);
        return;
      }
      const tPl: number = Date.now();
      const us: string[] = [];
      const ks: string[] = [];
      for (const line of body.split('\n')) {
        if (line.indexOf('/local-seg?') !== 0) {
          continue;
        }
        const q: string = line.substring(line.indexOf('?') + 1);
        const u: string = this.param(q, 'u');
        const k: string = this.param(q, 'k');
        if (u.length > 0) {
          us.push(u);
          ks.push(k.length > 0 ? k : u);
        }
      }
      /* ★★★ 修正（2026-09-16）★★★
       *   原实现取"最后 N 片"，但 AVPlayer 是**按 playlist 顺序从第一片开始**请求的
       *   ⇒ prewarm 必须预热 **playlist 头部**，否则 AVPlayer 首片永远走"下载+解密"全流程。
       *   （日志铁证：seg#1 耗时 870ms 来源=网络，seg#2 耗时 327ms 来源=rawCache） */
      const prewarmCount: number = Math.min(2, us.length);
      const tailU: string[] = us.slice(0, prewarmCount);
      const tailK: string[] = ks.slice(0, prewarmCount);
      const todoU: string[] = [];
      const todoK: string[] = [];
      for (let i = 0; i < tailK.length; i++) {
        if (this.cachedSeg(tailK[i]) === undefined && this.cachedRaw(tailK[i]) === undefined) {
          todoU.push(tailU[i]);
          todoK.push(tailK[i]);
        }
      }
      if (todoU.length === 0) {
        console.info(`[LocalDecrypt] prewarm[gen=${myGen}] playlist ${body.length}B，分片已有缓存 ⇒ 无需下载` +
          `（playlist 用时 ${tPl - t0}ms）`);
        return;
      }
      console.info(`[LocalDecrypt] prewarm[gen=${myGen}] playlist ${body.length}B 用时 ${tPl - t0}ms ⇒ 下载 ${todoU.length} 片`);
      /* ★ 逐个下载、下载完一片立即写缓存：
       *   AVPlayer 的 /local-seg 请求只要在 prewarm 完成前到达，就能命中 rawCache
       *   （而不是等到 Promise.all 全部完成才写入） */
      const tasks: Promise<void>[] = todoU.map(async (u: string, i: number): Promise<void> => {
        const raw: Uint8Array | null = await this.fetchSegRaw(u);
        if (raw === null || myGen !== this.prewarmGen) {
          return;
        }
        if (isNoDecryptUrl(u)) {
          this.putSeg(todoK[i], raw);
        } else {
          this.putRaw(todoK[i], raw);
        }
      });
      await Promise.all(tasks);
      const tDl: number = Date.now();   // ★ 修正：在 await 之后取
      if (myGen !== this.prewarmGen) {
        console.info(`[LocalDecrypt] prewarm[gen=${myGen}] 被新台取代 ⇒ 放弃（在下载之后）`);
        return;
      }
      console.info(`[LocalDecrypt] prewarm[gen=${myGen}] 完成：playlist ${tPl - t0}ms，` +
        `下载 ${tDl - tPl}ms，共 ${Date.now() - t0}ms`);
    } catch (e) {
      const err = e as Error;
      console.warn(`[LocalDecrypt] prewarm[gen=${myGen}] 失败（不影响播放）: ${err.message}`);
    }
  }

  private respond(client: socket.TCPSocketConnection, code: number, mime: string, body: Uint8Array): void {
    const head = `HTTP/1.1 ${code} ${code === 200 ? 'OK' : 'ERR'}\r\n` +
      `Content-Type: ${mime}\r\n` +
      `Content-Length: ${body.length}\r\n` +
      `Access-Control-Allow-Origin: *\r\n` +
      `Cache-Control: no-store\r\n` +
      `Connection: close\r\n\r\n`;
    const headBytes = LocalDecryptServer.enc().encodeInto(head);
    const all = new Uint8Array(headBytes.length + body.length);
    all.set(headBytes, 0);
    all.set(body, headBytes.length);
    client.send({ data: all.buffer as ArrayBuffer })
      .then(() => {
        client.close();
      })
      .catch((e: Error) => {
        console.error(`[LocalDecrypt] send 失败: ${e.message}`);
        try {
          client.close();
        } catch (e2) {
          // ignore
        }
      });
  }
}
