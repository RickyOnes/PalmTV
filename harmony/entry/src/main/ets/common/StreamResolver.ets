/**
 * StreamResolver.ets —— 频道 → 可播放 m3u8 的完整取流编排（gate4）
 *
 * 链路：
 *   1) auth            POST https://player-api.yangshipin.cn/v1/player/auth     （本地 MD5 签名）
 *   2) 三链并行        genTokenRnd（native）→ openToken（GET h5access）
 *                      genCKey    （native）→ sdkInput/bodySig（本地 MD5）
 *                      genYspTicket（native）
 *   3) genSignature（native）→ yspsdksign
 *   4) get_live_info   POST https://player-api.yangshipin.cn/v1/player/get_live_info
 *   5) m3u8 = playurl + extended_param  ⇒ 交给 LocalDecryptServer.localPlaylistUrl()
 *
 * ★ 4 个签名函数全部**原生实现**（gate3，见 `NativeSigner.ets`）：
 *   keygen_bg.wasm / RJq7sO71JF.wasm 经 wasm2c 转 C 编入 libcmg_napi.so，
 *   cKey 由 `ckey_core.ts` 纯计算完成 ⇒ **不再需要隐藏 Web / wasm 运行时**。
 */
import { http } from '@kit.NetworkKit';
import { computeSign } from './ProxySigner';
import { YspAppId, Guid, VappId, Vsecret, Ua, Cookie } from './TvConfig';
import { TvChannel } from './ChannelList';

/** 4 个签名函数的抽象（现行实现为原生：`NativeSigner`） */
export interface WasmSigner {
  /** → tokenRnd 字符串（失败抛错） */
  genTokenRnd(guid: string, token: string, tsMs: string): Promise<string>;
  /** → cKey 字符串 */
  genCKey(cnlId: string, tsSec: string, appVer: string, guid: string, platform: string, docUrl: string): Promise<string>;
  /** → yspTicket 字符串 */
  genYspTicket(pid: string, authTs: string, cnlId: string, guid: string, yspAppId: string, appVer: string): Promise<string>;
  /** → signature 字符串 */
  genSignature(pid: string, guid: string, seqId: string, reqId: string, sessionToken: string,
    tsMs: string, yspSdkInput: string): Promise<string>;
}

/** 取流阶段（给 UI 显示进度用） */
export type ResolvePhase = 'auth' | 'sign' | 'token' | 'liveinfo';

export interface ResolveOptions {
  /** 进度回调（UI 显示"正在鉴权/签名/取流…"） */
  onPhase?: (p: ResolvePhase) => void;
  /** 32 位随机串（不传则内部生成） */
  randStr?: string;
}

/** 随机串（与原版一致：62 字符集） */
export function genRandStr(n: number): string {
  const cs: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let s: string = '';
  for (let i = 0; i < n; i++) {
    s += cs.charAt(Math.floor(Math.random() * cs.length));
  }
  return s;
}

function joinUrl(base: string, path: string): string {
  return base + path;
}

/** 直连官方域名（与桌面版一致；不再经本地 Go/Arkts 代理） */
const HOST_PLAYER = 'https://player-api.yangshipin.cn';
const HOST_H5 = 'https://h5access.yangshipin.cn';

/**
 * ★★ 启动预热 DNS/TLS（对齐原版 `[warmDns]`）★★
 *   原理：http 栈是按 host 建连的 —— 启动时对每个会用到的域名各发一个**廉价请求**，
 *   DNS 解析 + TLS 握手就在后台完成了；首次取流时省掉这两次往返（原版启动日志里
 *   就是先 warmDns 五个域名，再开始预热鉴权 ⇒ 我们照做）。
 *   失败全部忽略：预热只影响速度，不影响任何功能。
 */
export function warmDns(): void {
  const hosts: string[] = [
    'https://player-api.yangshipin.cn/robots.txt',
    'https://h5access.yangshipin.cn/robots.txt',
    'https://capi.yangshipin.cn/robots.txt',
    'https://hlslive-tx-cdn.ysp.cctv.cn/robots.txt',
    'https://live-dtocnc-cdn.ysp.cctv.cn/robots.txt',
    'https://mobilelive-play.ysp.cctv.cn/robots.txt'
  ];
  for (const u of hosts) {
    reqText(u, http.RequestMethod.GET, { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' }, '', 3000)
      .then(() => { /* 预热完成（不关心状态码） */ })
      .catch(() => { /* 预热失败：忽略 */ });
  }
  console.info(`[StreamResolver] warmDns 已发起 ${hosts.length} 个域名预热`);
}

/** 发请求并取文本（二进制响应自动解码） */
async function reqText(url: string, method: http.RequestMethod, headers: Record<string, string>,
  body: string, timeoutMs: number): Promise<string> {
  const client = http.createHttp();
  try {
    const opt: http.HttpRequestOptions = {
      method: method,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs
    };
    if (body.length > 0) {
      opt.extraData = body;
    }
    const resp = await client.request(url, opt);
    const r = resp.result;
    /* ⚠️ 变量名不能用 `body`：本函数的**参数**就叫 `body`（请求体），
     *   同作用域再声明 `let body` 会触发
     *   `Block-scoped variable 'body' used before its declaration` ✗（真机编译报过）。 */
    let respBody: string = '';
    if (typeof r === 'string') {
      respBody = r;
    } else if (r instanceof ArrayBuffer) {
      respBody = new util_TextDecoderShim().decode(r);
    } else {
      respBody = `${r}`;
    }
    /* ★★ 鉴权类先判（2026-09-16 修）★★
     *   真机日志（长后台回来后第一次取流）：`get-live-info … HTTP 401，响应为空`。
     *   这**不是网络问题**，而是**token 已被服务端作废**（我们的 auth 缓存比服务端 TTL 长），
     *   处理方式也完全不同：上层应"清 auth 缓存 + **立即**重试"，而不是当网络抖动退避 1.5s、
     *   更不该给用户显示"网络信号差"。⇒ 这里单独抛出 `鉴权失效（HTTP 4xx）`，让上层分类。 */
    if (resp.responseCode === 401 || resp.responseCode === 403) {
      throw new Error(`鉴权失效（HTTP ${resp.responseCode}，token 已过期或被拒）`);
    }
    /* ★★ 空响应必须归类为"网络类错误"★★
     *   真机症状（2026-09-15，断网→立刻恢复网络）：http 栈返回**空 body**，
     *   旧代码直接把它丢给 JSON.parse ⇒ 报 `Unexpected Text in JSON: Empty Text` ✗
     *   —— 既不含网络关键词（重试/中文提示判定失败），用户也完全看不懂。
     *   ⇒ 这里统一抛出含"网络"关键词的错误，交由上层重试 + 中文提示。 */
    if (respBody.trim().length === 0) {
      throw new Error(`网络无响应（HTTP ${resp.responseCode}，响应为空）`);
    }
    return respBody;
  } finally {
    client.destroy();
  }
}

/** 简单的 UTF-8 解码（避免为一个函数引入 util 依赖的版本差异） */
class util_TextDecoderShim {
  decode(buf: ArrayBuffer): string {
    const u = new Uint8Array(buf);
    let s = '';
    for (let i = 0; i < u.length; i++) {
      s += String.fromCharCode(u[i]);
    }
    return s;
  }
}

/**
 * 解析 JSON 响应。
 * ★ 不用裸 `JSON.parse`：切网/被网关拦截时会拿到空串或 HTML 错误页，
 *   裸 parse 报出的 `Unexpected Text in JSON: …` 对用户无意义、也无法归类为网络错误。
 */
function jsonAsObj(text: string): Record<string, Object> {
  const t: string = text.trim();
  if (t.length === 0) {
    throw new Error('网络无响应（服务端返回空内容）');
  }
  try {
    return JSON.parse(t) as Record<string, Object>;
  } catch (e) {
    throw new Error('网络响应异常（非 JSON，可能被网关/劫持拦截）: ' + t.substring(0, 120));
  }
}

/** ★ 换台提速：auth 结果缓存条目 */
interface CachedAuth {
  pair: TokenPair;
  at: number;
}

export interface StreamResult {
  /** 可直接交给 LocalDecryptServer.localPlaylistUrl() 的远端 m3u8 */
  m3u8: string;
  playUrl: string;
  /** auth token（心跳/重试用） */
  token: string;
}

export class StreamResolver {
  /**
   * ★★ auth token 缓存有效期（2026-09-16：**120s → 50s**，实测标定）★★
   *
   * 为什么改小：真机日志显示**服务端的 token 生命周期比 120s 短**——
   *   `17:05:09` 用 **55s** 前的 token 取流通过；`17:04:01` / `17:05:34` 用
   *   **80~82s** 前的 token ⇒ `get_live_info` 直接 `HTTP 401`（空 body，网关层拒绝）。
   *   即"长后台/长时间不用后回来，第一次取流几乎必 401"，白等一轮重试。
   * ⇒ 缓存压到 50s（落在实测边界以内），auth 只 ~150ms、且只在"换台/重拉"时发生，
   *   代价可忽略；配合 `invalidateAuth()`（长后台回前台主动作废）与 401 的即时重试，
   *   这个 401 从"每次必现"变成"基本不出现"。
   */
  private static readonly AUTH_TTL_MS: number = 50000;
  private signer: WasmSigner;
  /**
   * ★★ 换台提速（gate5）：auth token 缓存（key = pid）。
   *   auth 是纯网络往返（本地 MD5 签名），每次换台都要花 80~150ms；
   *   而 token 是**会话级**的（官方播放器同样长期复用）⇒ 缓存（见 `AUTH_TTL_MS`，50s）。
   *   安全兜底：`get_live_info` 失败（含网络异常/401）时会**立即失效**该缓存，
   *   下次会重新 auth，不会一直卡在坏 token 上。
   */
  private authCache: Map<string, CachedAuth> = new Map();

  constructor(signer: WasmSigner) {
    this.signer = signer;
  }

  /**
   * ★ 主动作废某个频道（或全部）的 auth 缓存（2026-09-16 新增）。
   *
   * 用途：**长后台回前台要重新取流时**先调它 —— 日志实测"后台 >60s 回来第一次
   * `get-live_info` 必然 401（空 body）"，因为服务端的 token 生命周期比我们缓存的 120s 短：
   *   `17:04:01` 用 82s 前的 token ⇒ **401**；`17:05:09` 用 55s 前的 token ⇒ 通过。
   * ⇒ 与其发一次注定失败的请求再靠 401 兜底，不如直接作废、一次做对（auth 仅 ~150ms）。
   */
  invalidateAuth(pid: string): void {
    if (pid.length > 0) {
      if (this.authCache.delete(pid)) {
        console.info(`[StreamResolver] 已主动作废 auth 缓存 pid=${pid}`);
      }
      return;
    }
    this.authCache.clear();
    console.info('[StreamResolver] 已主动作废全部 auth 缓存');
  }

  /** 步骤 1：auth（本地 MD5 签名，无需 wasm） */
  async auth(pid: string, randStr: string): Promise<TokenPair> {
    const cached: CachedAuth | undefined = this.authCache.get(pid);
    if (cached !== undefined && Date.now() - cached.at < StreamResolver.AUTH_TTL_MS) {
      console.info('[StreamResolver] auth 命中缓存（省一次网络往返）');
      return cached.pair;
    }
    const fields: Record<string, string> = {
      'appid': 'ysp_pc',
      'guid': Guid,
      'pid': pid,
      'rand_str': randStr
    };
    const signature: string = computeSign('auth', fields);
    const seqId: string = String(Date.now() % 100000000);
    const ts: string = String(Date.now());
    const reqId: string = '999999' + genRandStr(10) + ts;
    const headers: Record<string, string> = {
      // ★★ 2026-09-15 真机实测根因 ★★
      //   auth 只带 UA/yspappid/seqid/request-id/Cookie 时，player-api 直接回
      //   {"code":10012,"msg":"请求异常","data":{"code":-1}} —— 这是 APISIX 网关在业务逻辑**之前**
      //   的拒绝（响应里没有 token/ts，data 只有一个 code:-1），判定依据就是**浏览器式请求头**。
      //   早期已跑通的实现（桌面版 MainWindow.xaml.cs）都固定带 Referer/Origin/Accept；
      //   TLS 指纹两边同为 ArkTS http 栈（一样）⇒ 差别只在头。
      'User-Agent': Ua,
      'Accept': 'application/json, text/plain, */*',
      'Origin': 'https://yangshipin.cn',
      'Referer': 'https://yangshipin.cn/',
      'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'yspappid': YspAppId,
      'seqid': seqId,
      'request-id': reqId,
      'Cookie': Cookie + ' nseqId=' + seqId + '; nrequest-id=' + reqId,
      'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'
    };
    const form: string = 'pid=' + encodeURIComponent(pid) +
      '&guid=' + encodeURIComponent(Guid) +
      '&appid=ysp_pc' +
      '&rand_str=' + encodeURIComponent(randStr) +
      '&signature=' + encodeURIComponent(signature);
    const text: string = await reqText(joinUrl(HOST_PLAYER, '/v1/player/auth'),
      http.RequestMethod.POST, headers, form, 10000);
    const obj = jsonAsObj(text);
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const token = data['token'] as string;
    if (!token) {
      throw new Error('auth 无 token: ' + text.substring(0, 160));
    }
    const pair: TokenPair = { token: token, authTs: String(data['ts'] ?? '') } as TokenPair;
    this.authCache.set(pid, { pair: pair, at: Date.now() } as CachedAuth);
    return pair;
  }

  /**
   * 完整取流：返回可直接播放的远端 m3u8。
   * 抛错信息会带阶段前缀（auth/open-token/sign/get-live-info），便于 UI 显示与排查。
   */
  async resolve(ch: TvChannel, opt?: ResolveOptions): Promise<StreamResult> {
    const randStr: string = (opt !== undefined && opt.randStr !== undefined) ? opt.randStr : genRandStr(10);
    const phase = (p: ResolvePhase) => {
      if (opt !== undefined && opt.onPhase !== undefined) {
        opt.onPhase(p);
      }
    };

    // ---------- 1) auth ----------
    phase('auth');
    const a: TokenPair = await this.auth(ch.pid, randStr);

    // ---------- 2) 三链并行 ----------
    phase('sign');
    const tsSec: string = String(Math.floor(Date.now() / 1000));
    const docUrl: string = 'https://yangshipin.cn/tv/home?pid=' + ch.pid;
    const cKeyP: Promise<string> = this.signer.genCKey(ch.cnlId, tsSec, 'V1.0.0', Guid, '5910204', docUrl);
    const ticketP: Promise<string> = this.signer.genYspTicket(ch.pid, a.authTs, ch.cnlId, Guid, YspAppId, 'V1.0.0');
    let sessionTokenP: Promise<string> = Promise.resolve('');
    {
      const tokenRnd: string = await this.signer.genTokenRnd(Guid, a.token, String(Date.now()));
      phase('token');
      sessionTokenP = this.openToken(tokenRnd);
    }

    const cKey: string = await cKeyP;
    const sdkFields: Record<string, string> = {
      'cnlid': ch.cnlId,
      'livepid': ch.pid,
      'stream': '2',
      'guid': Guid,
      'cKey': cKey,
      'adjust': '1',
      'sphttps': '1',
      'platform': '5910204',
      'cmd': '2',
      'encryptVer': '8.1',
      'dtype': '1',
      'devid': 'devid',
      'otype': 'ojson',
      'appVer': 'V1.0.0',
      'app_version': 'V1.0.0',
      'channel': 'ysp_tx',
      'defn': 'fhd',
      'rand_str': randStr
    };
    const yspSdkInput: string = computeSign('sdkInput', sdkFields);
    const bodySig: string = computeSign('bodySig', sdkFields);

    const yspTicket: string = await ticketP;
    const sessionToken: string = await sessionTokenP;

    // ---------- 3) sig2 ----------
    const seqId2: string = String(Date.now() % 100000000);
    const ts2: string = String(Date.now());
    const reqId2: string = '999999' + genRandStr(10) + ts2;
    const sig2: string = await this.signer.genSignature(ch.pid, Guid, seqId2, reqId2, sessionToken, ts2, yspSdkInput);
    const yspSdkSign: string = sig2 + '-' + yspSdkInput + '-' + Guid + '-' + seqId2 + '-' + reqId2;

    // ---------- 4) get_live_info ----------
    phase('liveinfo');
    const bodyJson: string = JSON.stringify({
      'cnlid': ch.cnlId,
      'livepid': ch.pid,
      'stream': '2',
      'guid': Guid,
      'cKey': cKey,
      'adjust': 1,
      'sphttps': '1',
      'platform': '5910204',
      'cmd': '2',
      'encryptVer': '8.1',
      'dtype': '1',
      'devid': 'devid',
      'otype': 'ojson',
      'appVer': 'V1.0.0',
      'app_version': 'V1.0.0',
      'channel': 'ysp_tx',
      'defn': 'fhd',
      'rand_str': randStr,
      'signature': bodySig
    });
    const headers: Record<string, string> = {
      'User-Agent': Ua,
      'Accept': 'application/json, text/plain, */*',
      'Origin': 'https://yangshipin.cn',
      'Referer': 'https://yangshipin.cn/',
      'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'Content-Type': 'application/json;charset=UTF-8',
      'yspappid': YspAppId,
      'yspplayertoken': a.token,
      'yspsdkinput': yspSdkInput,
      'yspsdksign': yspSdkSign,
      'yspticket': yspTicket,
      'request-id': reqId2,
      'seqid': seqId2,
      'Cookie': Cookie + ' nseqId=' + seqId2 + '; nrequest-id=' + reqId2
    };
    let text: string = '';
    try {
      text = await reqText(joinUrl(HOST_PLAYER, '/v1/player/get_live_info'),
        http.RequestMethod.POST, headers, bodyJson, 12000);
    } catch (e) {
      /* ★ 网络层异常：缓存的 token 可能已失效 ⇒ 立刻失效缓存，下次重新 auth */
      this.authCache.delete(ch.pid);
      const err = e as Error;
      throw new Error('get-live-info 请求失败: ' + err.message);
    }
    const obj = jsonAsObj(text);
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const playUrl = (data['playurl'] as string) ?? (data['vurl'] as string);
    if (!playUrl) {
      /* ★ 失败多半是 yspplayertoken 过期 ⇒ 失效缓存，用户再点一次就会重新 auth */
      this.authCache.delete(ch.pid);
      throw new Error('get-live-info 无 playurl: ' + text.substring(0, 200));
    }
    const extended: string = (data['extended_param'] as string) ?? '';
    return { m3u8: playUrl + extended, playUrl: playUrl, token: a.token } as StreamResult;
  }

  /**
   * openToken：tokenRnd → sessionToken（每次现取，不可缓存）。
   * ★ 只吃 tokenRnd：旧版还传了 token/authTs 但函数内从未使用（清理时移除）。
   */
  private async openToken(tokenRnd: string): Promise<string> {
    const ts: string = String(Date.now());
    const q: string = 'yspappid=' + encodeURIComponent(YspAppId) +
      '&guid=' + encodeURIComponent(Guid) +
      '&vappid=' + encodeURIComponent(VappId) +
      '&vsecret=' + encodeURIComponent(Vsecret) +
      '&raw=1&version=v1' +
      '&ts=' + encodeURIComponent(ts) +
      '&rnd=' + encodeURIComponent(tokenRnd);
    const headers: Record<string, string> = {
      'User-Agent': Ua,
      'Referer': 'https://yangshipin.cn/',
      'Origin': 'https://yangshipin.cn',
      'Accept': '*/*'
    };
    const text: string = await reqText(joinUrl(HOST_H5, '/web/open/token?' + q),
      http.RequestMethod.GET, headers, '', 10000);
    const obj = jsonAsObj(text);
    const data = (obj['data'] ?? {}) as Record<string, Object>;
    const st = data['token'] as string;
    if (!st) {
      throw new Error('open-token 无 token: ' + text.substring(0, 160));
    }
    return st;
  }
}

export interface TokenPair {
  token: string;
  authTs: string;
}
