/**
 * YspLive.ets —— 央视频「安卓平台」取流（**自研 cKey → liveinfo → 明文 HLS**）
 *
 * ★★★ 2026-11-07：**鸿蒙从此只有这一条央视频取流链路** ★★★
 *
 * 参照实现（三端同参数，改一处必须改另外两处）：
 *   · 安卓：`Android/app/src/main/java/com/rickyone/palmtv/data/YspAndroidLive.kt`
 *   · 桌面：`windows/YspAndroidLive.cs`
 *
 * 为什么换掉原来的 Web/PC 链路（`StreamResolver`，已删除）：
 *   1. 那条链给的是 **CMG 加密**流（`encrypt=2`）⇒ 端上必须带 CMG 解密核；
 *      本链路响应 `encrypt=0` ⇒ **明文**，AVPlayer 直接吃，**不需要任何解密**；
 *   2. 那条链要 auth → openToken → yspsdksign → get_live_info 四步、且依赖 wasm2c 签名核；
 *      本链路只要 **一个 cKey + 一次 GET**；
 *   3. 本链路**天然支持时移/回看**（带 `playbacktime`）。
 *
 * ★ 四条硬约束（与安卓逐条对齐，别改）：
 *   1. `defn` 传 `auto`；`spdrm` **必须 2**（声明支持 DRM，改成 0 会 `iretcode=57 版权限制`）；
 *   2. `stream=3`、`sdtfrom=v5028`（请求参数），而 cKey 载荷内的 sdtfrom 是 `v5082` —— 别搞反；
 *   3. cKey 的 `ts` 与请求参数 `fntick` **必须同一秒**；`guid` 也必须与载荷内一致；
 *   4. 全局最小请求间隔 900ms（服务端 5 秒 6 条即触发 `iretcode=32` 限流）。
 *
 * ★ 8 个 ChinaDRM 台（CCTV-4K/11/12/14/15/16/16K/17）的分片是 **SM4-CBC 密文**：
 *   2026-11-08 起鸿蒙也有 sm4c（`common/native/src/sm4c.c`，从安卓 `Sm4C.kt` 移植），
 *   由 `LocalProxyServer` 在分片落地前就地解密 ⇒ **这 8 个台与其它台一样可直接播**。
 *   其余台（含 CCTV-1..13、各卫视）分片本来就是明文。
 *
 * ★ 回看/时移：`resolveFrom()`（带 `playbacktime` + `endtime`），与直播同一套 cKey。
 */
import { http } from '@kit.NetworkKit';
import { SelfCKey, YSP_GUID, YSP_PLATFORM, YSP_CKEY_VER } from './SelfCKey';
import { Sm4C } from './Sm4C';
import { Log } from './Log';

/** 取流接口主机（与安卓/桌面同一个：移动端 liveinfo，**不是** player-api） */
const HOST: string = 'https://liveinfo.ysp.cctv.cn/';

/** 请求 UA —— 必须是它（服务端按 UA/平台交叉校验；实测 `qqlive` 可过） */
const UA: string = 'qqlive';

/** 设备能力描述（真机抓包值，单行清洗版） */
const SPVCODE: string =
  'MSgzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MHwzMDoyMTYwLDYwOjIxNjAsOTA6MTQ0MCwxMjA6MTQ0MCk7' +
  'MigzMDoxNDQwLDYwOjEwODAsOTA6NzIwLDEyMDo3MjB8MzA6MTQ0MCw2MDoxMDgwLDkwOjcyMCwxMjA6NzIwKQ==';

/** estid（真机 est 文件内容）—— 官方客户端身份字段之一 */
const ESTID: string = 'zg+Ym3rNTnD6DWvhotJfotqgIWJ4Ihv5ouS3Ht1hDVeVyxYbTsD6Htm5HtDjIhAjHai=';

/**
 * 直播"退时移"的秒数。
 *
 * 实测边界（`scripts/160-shift-bisect.py`）：Δ ≤ 8s 服务端仍给**直播 CDN**（我们的 token 会被 CDN 403），
 * **Δ = 9s 起**给 playback CDN（200 + 明文）。取 10 = 边界 + 1 秒余量。
 */
const LIVE_SHIFT_SEC: number = 10;

/** `iretcode=32`（票据时序）/ `12`（偶发版权）都跨秒重算 cKey 重试；含首次最多 3 次 */
const MAX_ATTEMPTS: number = 3;

/** 全局最小请求间隔（ms）—— 服务端 5 秒 6 条即限流，连正常直播一起被拒 */
const REQ_MIN_GAP_MS: number = 900;

/** 清单自检超时（ms）：空清单 = 该台此刻没信号，几百毫秒就能判出来，别让播放器干等 */
const PL_PROBE_TIMEOUT_MS: number = 6000;

/** "加密台暂不支持"的错误标识（`Index` 用 `indexOf` 判它 ⇒ 走统一的无信号/回退提示） */
export const ENC_CHANNEL_ERR: string = '加密频道（暂不支持）';

/** 取流结果 */
export interface YspPlayInfo {
  /** 上游**明文** m3u8 地址（带一次性 token） */
  url: string;
  /** CDN 要求的 `UID`（必须与 cKey 载荷里的 guid 一致） */
  guid: string;
  /** 本次 cKey 绑定（并在请求里使用）的 cnlid */
  cnlid: string;
  /** 服务端回的档位（日志用） */
  defn: string;
  /** 实际起播时刻（秒；直播为 0） */
  playbackStart: number;
  /** 本次请求带的 `playbacktime`（0 = 直播） */
  playback: number;
  /** 自检时已经拉到的**清单文本**（交给本地代理做 playlist 缓存，省一次 CDN 往返） */
  playlist: string;
}

let lastReqAt: number = 0;
let lastErr: string = '';
let lastIret: number = 0;

/** 最近一次取流失败的可读原因（上层直接拿它做用户文案/排错） */
export function lastResolveError(): string {
  return lastErr;
}

/** 最近一次服务端 `iretcode`（0 = 成功；12 = 版权停播；32 = 权限/时效） */
export function lastIretcode(): number {
  return lastIret;
}

/* ---------------- HTTP ---------------- */

let sharedHttp: http.HttpRequest | null = null;

function httpOf(): http.HttpRequest {
  if (sharedHttp === null) {
    sharedHttp = http.createHttp();
  }
  return sharedHttp;
}

/** GET 文本（失败抛错，由调用方兜住） */
async function getText(url: string, headers: Record<string, string>, timeoutMs: number): Promise<string> {
  const resp = await httpOf().request(url, {
    method: http.RequestMethod.GET,
    header: headers,
    expectDataType: http.HttpDataType.STRING,
    connectTimeout: timeoutMs,
    readTimeout: timeoutMs
  });
  if (resp.responseCode < 200 || resp.responseCode >= 300) {
    throw new Error(`HTTP ${resp.responseCode}`);
  }
  const r = resp.result;
  return typeof r === 'string' ? r as string : '';
}

function cdnHeaders(guid: string): Record<string, string> {
  const h: Record<string, string> = {
    'User-Agent': UA,
    'UID': guid,
    'Accept': '*/*'
  };
  return h;
}

/**
 * 清单自检：能拿到 `#EXTM3U` 才算"这条地址可用"。
 * @returns 清单文本（失败返回 `''`，原因写进 lastErr 日志）
 */
async function probePlaylist(url: string, guid: string): Promise<string> {
  try {
    const text: string = await getText(url, cdnHeaders(guid), PL_PROBE_TIMEOUT_MS);
    if (text.indexOf('#EXTM3U') < 0) {
      Log.w(`[YspLive] 自检：清单不含 #EXTM3U ⇒ 判不可用 ${url.substring(0, 100)}…`);
      return '';
    }
    /* ★★ 8 个 ChinaDRM 台（CCTV-4K/11/12/14/15/16/16K/17）的清单带 `METHOD=SM4-CBC`，
     *   分片是 SM4 密文 —— 由**本地代理**取回后调 `common/Sm4C.ets`（C 实现）就地解密。
     *   ⚠️ 这里只做一件事：确认 native 的 sm4c 真的在。**不在就别装作能播**（否则是绿屏/假缓冲），
     *     直接判不可播，让上层走统一的"无信号 → 回退原台"。 */
    if (text.indexOf('METHOD=SM4-CBC') >= 0) {
      if (!Sm4C.available()) {
        Log.e('[YspLive] 该台是 ChinaDRM( sm4c ) 加密台，但 native sm4c 不可用 ⇒ 判为不可播');
        lastErr = ENC_CHANNEL_ERR;
        return '';
      }
      Log.i('[YspLive] 该台是 ChinaDRM( sm4c ) 加密台 ⇒ 由本地代理 sm4c 解密');
    }
    const segs: number = text.split('\n').filter((l: string) => l.length > 0 && !l.startsWith('#')).length;
    if (segs === 0) {
      Log.w(`[YspLive] 自检：清单没有分片（该台此刻可能没信号）`);
      return '';
    }
    Log.i(`[YspLive] 自检通过：清单 ${text.length}B / 分片 ${segs} 条`);
    return text;
  } catch (e) {
    Log.w(`[YspLive] 自检拉清单失败: ${(e as Error).message}`);
    return '';
  }
}

/* ---------------- 请求构造 ---------------- */

function genFlowId(): string {
  const s: string = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c: string): string => {
    const r: number = Math.floor(Math.random() * 16);
    const v: number = c === 'x' ? r : ((r & 0x3) | 0x8);
    return v.toString(16);
  });
  return `${s}${Date.now()}_${YSP_PLATFORM}`;
}

/** 固定参数（与安卓抓包逐字一致；顺序也保持一致，便于和抓包对比） */
const BASE: string[][] = [
  ['spacode', '23'], ['app_version', '305030'], ['spwm', '2'], ['hevclv', '26'],
  ['platform', YSP_PLATFORM], ['sdtfrom', 'v5028'], ['stream', '3'],
  ['sphttps', '0'], ['spdynamicrange', '1'], ['refer_pageId', 'page_tv_500102'],
  ['wxopenid', ''], ['spdemuxer', '14'], ['spvcode', SPVCODE], ['sphdrfps', '60'],
  ['qq', ''], ['defnsrc', '3'], ['estid', ESTID],
  ['appVer', YSP_CKEY_VER], ['defn', 'auto'], ['encryptVer', '4.2'],
  ['spdrm', '2'], ['pageId', 'page_tv_500102'], ['newnettype', '1'],
  ['spflvaudio', '1'], ['adjust', '1'], ['vip_status', '0'], ['spflv', '1'],
  ['uhd_flag', '4'], ['cmd', '2'], ['otype', 'json'], ['caplv', '1']
];

/**
 * 单次取流（不做节流/重试，内部用）。
 * @param playbackTime 秒级时刻；`0` = 直播（不带该参数）
 * @param endTime      回看/时移的结束时刻；带上它服务端返回**整段 VOD 清单**（可连续播），
 *                     不带就只给 ~5 片滚动窗口（会周期性卡）。直播传 0。
 */
async function resolveOnce(cnlid: string, livepid: string, playbackTime: number,
  endTime: number): Promise<YspPlayInfo | null> {
  /* ★ 每次请求前清零：网络类失败时 `lastIret` 必须保持 0，否则会误触发"32/12 跨秒重试" */
  lastIret = 0;
  const nowSec: number = Math.floor(Date.now() / 1000);
  /* ★ cKey 的 ts 与请求的 fntick 必须同一秒（服务端校验时效） */
  const ck: string = SelfCKey.gen(nowSec, cnlid, YSP_GUID);
  if (ck.length === 0) {
    lastErr = 'cKey 生成失败';
    return null;
  }

  const parts: string[] = [];
  const add = (k: string, v: string): void => {
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
  };
  for (const kv of BASE) {
    add(kv[0], kv[1]);
  }
  /* 动态参数 */
  add('cKey', ck);
  add('fntick', String(nowSec));
  add('guid', YSP_GUID);
  add('cnlid', cnlid);
  add('livepid', livepid);
  add('randnum', Math.random().toFixed(16));
  add('flowid', genFlowId());
  if (playbackTime > 0) {
    add('playbacktime', String(playbackTime));
  }
  const url: string = HOST + '?' + parts.join('&');

  let text: string = '';
  try {
    text = await getText(url, cdnHeaders(YSP_GUID), 12000);
  } catch (e) {
    lastErr = `取流请求失败: ${(e as Error).message}`;
    Log.w(`[YspLive] 请求异常 cnlid=${cnlid} pb=${playbackTime}: ${lastErr}`);
    return null;
  }

  try {
    const o = JSON.parse(text) as Record<string, Object>;
    /* 兼容 number / 字符串两种形态（服务端历史上两种都出现过） */
    const codeRaw: Object | undefined = o['iretcode'];
    const code: number = typeof codeRaw === 'number' ? codeRaw as number
      : (typeof codeRaw === 'string' ? Number(codeRaw as string) : -1);
    const detRaw: Object | undefined = o['iretdetailcode'];
    const detail: number = typeof detRaw === 'number' ? detRaw as number
      : (typeof detRaw === 'string' ? Number(detRaw as string) : 0);
    lastIret = Number.isFinite(code) ? code : -1;
    /* ⚠️ 响应是**扁平**的（没有 data 包裹）：先根、后 data 双取以兼容两种形态 */
    const data: Record<string, Object> =
      (o['data'] !== undefined && o['data'] !== null && typeof o['data'] === 'object')
        ? o['data'] as Record<string, Object> : o;
    let play: string = typeof data['playurl'] === 'string' ? data['playurl'] as string : '';
    if (play.length === 0 && typeof o['playurl'] === 'string') {
      play = o['playurl'] as string;
    }
    play = play.replace(/\\u0026/g, '&');
    const defn: string = typeof data['defn'] === 'string' ? data['defn'] as string
      : (typeof o['defn'] === 'string' ? o['defn'] as string : '');
    let pbStart: number = 0;
    const pbObj = o['playback'];
    if (pbObj !== undefined && pbObj !== null && typeof pbObj === 'object') {
      const pbn: Object | undefined = (pbObj as Record<string, Object>)['playbackstart'];
      if (typeof pbn === 'number') {
        pbStart = pbn as number;
      }
    }

    if (code !== 0 || play.length === 0) {
      const errinfo: string = typeof o['errinfo'] === 'string' ? (o['errinfo'] as string).trim() : '';
      lastErr = errinfo.length > 0 ? errinfo : `取流失败（iretcode=${code}）`;
      Log.w(`[YspLive] 取流失败 iretcode=${code} detail=${detail} cnlid=${cnlid} pb=${playbackTime} ` +
        `body=${text.substring(0, 320)}`);
      return null;
    }

    /* ★ 回看/时移追加 endtime ⇒ 服务端给整段 VOD 清单（否则只有 ~5 片滚动窗口，会周期性卡） */
    if (playbackTime > 0 && endTime > playbackTime + 5 && play.indexOf('endtime=') < 0) {
      play = play + (play.indexOf('?') >= 0 ? '&' : '?') + 'endtime=' + endTime;
    }

    Log.i(`[YspLive] 取流 OK defn=${defn} pb=${playbackTime} start=${pbStart} ` +
      `url=${play.substring(0, 110)}`);
    return {
      url: play,
      guid: YSP_GUID,
      cnlid: cnlid,
      defn: defn,
      playbackStart: pbStart,
      playback: playbackTime,
      playlist: ''
    } as YspPlayInfo;
  } catch (e) {
    lastErr = `响应解析失败: ${(e as Error).message}`;
    Log.w(`[YspLive] 解析失败: ${lastErr} body=${text.substring(0, 240)}`);
    return null;
  }
}

/** 带节流 + 跨秒重试的单次取流 */
async function resolveWithRetry(cnlid: string, livepid: string, playbackTime: number,
  endTime: number, attempt: number): Promise<YspPlayInfo | null> {
  if (attempt === 0) {
    const gap: number = REQ_MIN_GAP_MS - (Date.now() - lastReqAt);
    if (gap > 0) {
      await new Promise<void>((ok: () => void) => { setTimeout(() => { ok(); }, gap); });
    }
  }
  lastReqAt = Date.now();
  const r: YspPlayInfo | null = await resolveOnce(cnlid, livepid, playbackTime, endTime);
  if (r !== null) {
    return r;
  }
  /* ★ 32（票据时序）与 12（版权，可能瞬时）都跨秒重算 cKey 再试 —— 安卓实测二者都是间歇性的 */
  if ((lastIret === 32 || lastIret === 12) && attempt + 1 < MAX_ATTEMPTS) {
    await new Promise<void>((ok: () => void) => { setTimeout(() => { ok(); }, 250); });
    Log.i(`[YspLive] iretcode=${lastIret} ⇒ 第 ${attempt + 2}/${MAX_ATTEMPTS} 次尝试`);
    return resolveWithRetry(cnlid, livepid, playbackTime, endTime, attempt + 1);
  }
  return null;
}

/**
 * **回看 / 时移**取流（2026-11-08 新增）：从指定时刻起播。
 *
 * 与安卓 `playReplayFrom` 同参数：
 *   · `playbackTime` = 起播时刻（epoch 秒）；回看 = 节目开始时刻，时移 = now − 300
 *   · `endTime`      = 结束时刻；**必须带**，否则服务端只给 ~5 片滚动窗口（会周期性卡），
 *                      带上才返回整段 VOD 清单（`#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST`）
 * ⚠️ 回看**不做**"退时移"兜底（本来就是时移请求），失败就是失败，由上层提示。
 */
export async function resolveFrom(cnlid: string, livepid: string, playbackTime: number,
  endTime: number): Promise<YspPlayInfo | null> {
  lastErr = '';
  lastIret = 0;
  const r: YspPlayInfo | null = await resolveWithRetry(cnlid, livepid, playbackTime, endTime, 0);
  if (r === null) {
    return null;
  }
  const pl: string = await probePlaylist(r.url, r.guid);
  if (pl.length === 0) {
    if (lastErr.indexOf('加密频道') < 0) {
      lastErr = '回看地址不可用（CDN 拒绝）';
    }
    return null;
  }
  r.playlist = pl;
  return r;
}

/**
 * 取流（**直播优先**）：先要"真直播"，清单不可用再退"时移 `LIVE_SHIFT_SEC` 秒"。
 *
 * @param cnlid 频道 cnlId（10 位数字）
 * @param livepid 频道 pid
 * @returns 成功 = 明文 playurl + 自检清单；失败 = `null`（原因见 `lastResolveError()`）
 */
export async function resolveLive(cnlid: string, livepid: string): Promise<YspPlayInfo | null> {
  lastErr = '';
  lastIret = 0;

  let r: YspPlayInfo | null = await resolveWithRetry(cnlid, livepid, 0, 0, 0);
  if (r !== null) {
    const pl: string = await probePlaylist(r.url, r.guid);
    if (pl.length > 0) {
      r.playlist = pl;
      return r;
    }
    /* ★ 加密台：真直播、时移都是同一套 SM4 密文 ⇒ 不必再退时移（省一次往返，也避免"重试风暴"） */
    if (lastErr.indexOf('加密频道') >= 0) {
      return null;
    }
    Log.w(`[YspLive] 真直播地址不可播 ⇒ 退时移 ${LIVE_SHIFT_SEC}s`);
  } else {
    Log.w(`[YspLive] 真直播取流失败（${lastErr}）⇒ 退时移 ${LIVE_SHIFT_SEC}s`);
  }

  const liveReason: string = lastErr;
  const pb: number = Math.floor(Date.now() / 1000) - LIVE_SHIFT_SEC;
  r = await resolveWithRetry(cnlid, livepid, pb, 0, 0);
  if (r === null) {
    /* 时移失败时不要用它自己的原因覆盖直播那次（安卓同样处理：时移偶发 12，直播其实是好的） */
    lastErr = liveReason.length > 0 ? liveReason : lastErr;
    return null;
  }
  const pl2: string = await probePlaylist(r.url, r.guid);
  if (pl2.length === 0) {
    if (lastErr.indexOf('加密频道') < 0) {
      lastErr = '播放地址不可用（CDN 拒绝）';
    }
    return null;
  }
  r.playlist = pl2;
  return r;
}

/**
 * DNS/TLS 预热（对齐原版 `[warmDns]`）：启动时对会用到的域名各发一个廉价请求，
 * 把 DNS 解析 + 握手在后台做掉。**失败全部忽略**（只影响速度）。
 */
export function warmDns(): void {
  const urls: string[] = [
    'https://liveinfo.ysp.cctv.cn/robots.txt',
    'https://capi.yangshipin.cn/robots.txt',
    'https://hlslive-tx-cdn.ysp.cctv.cn/robots.txt',
    'https://live-dtocnc-cdn.ysp.cctv.cn/robots.txt',
    'https://mobilelive-play.ysp.cctv.cn/robots.txt',
    'https://tlivecloud-playback-cdn.ysp.cctv.cn/robots.txt'
  ];
  for (const u of urls) {
    getText(u, { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' }, 4000)
      .then(() => {})
      .catch(() => {});
  }
  Log.i(`[YspLive] warmDns 已发 ${urls.length} 个`);
}

/** 预热某个 CDN 主机（拿到 playurl 后调用；失败忽略，去重） */
const warmedHosts: Set<string> = new Set<string>();

export function warmHostOf(url: string): void {
  const i: number = url.indexOf('://');
  if (i < 0) {
    return;
  }
  const j: number = url.indexOf('/', i + 3);
  const origin: string = j < 0 ? url : url.substring(0, j);
  if (origin.length === 0 || warmedHosts.has(origin)) {
    return;
  }
  warmedHosts.add(origin);
  getText(origin + '/robots.txt', { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' }, 4000)
    .then(() => { Log.i(`[YspLive] 主机预热完成 ${origin}`); })
    .catch(() => {
      warmedHosts.delete(origin);   /* 失败要放回，否则该主机永不重试 */
    });
}
