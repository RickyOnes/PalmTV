/**
 * libcmg_napi.so 的 TS 类型声明。
 *
 * ⚠️ 公开仓库只提供**接口声明**，不含 native 实现：
 *    `entry/src/main/cpp/CMakeLists.txt` 与内核源码不在本仓库内。
 *    本地开发请把内核放到工程外，并用 `-DCMG_NATIVE_DIR=<绝对路径>` 指过去。
 */

/** 运行时统计 */
export interface CmgStat {
  /** 累计处理帧数 */
  frames: number;
  /** 最近一帧的取指数（诊断用：数值极小说明这一步没有真正执行） */
  lastMaPcs: number;
  /** 累计「输出与输入逐字节相同」（即未生效）的帧数 */
  unchanged: number;
  /** 会话续期（重播前置序列）次数 */
  reseeds: number;
  /** 会话重建次数（正常自愈；持续增长说明这段时间不稳定） */
  restarts: number;
  /** 帧内重试次数（当帧自愈，不丢帧） */
  retries: number;
  /** 被跳过的过短 NALU 累计数 */
  shortNalus: number;
  /** 输出异常（NAL 头不合法）的帧数 */
  badNalus: number;
  /** 1 = 下一帧仍会走首帧前置序列 */
  firstPending: number;
}

/**
 * 诊断抓取：把最近 `ring` 个分片的输入/输出与元信息写入 `dir`（滚动覆盖）。`ring <= 0` 关闭。
 * @param dir  目录（必须已存在）
 * @param ring 保留分片数
 */
export const cmgSetCapture: (dir: string, ring: number) => number;

/**
 * 时钟模式：1 = 真实墙钟（**直播必须**）；0 = 确定性虚拟钟（离线回归用）。
 * 直播场景下密钥派生依赖实时时间，必须与真实时间一致。
 */
export const cmgSetClockMode: (real: number) => number;

/**
 * 用服务器时间（毫秒）对齐内部时钟。偏移 ±1 天以上会被忽略。
 * 本 App 未启用（保留能力）：仅当设备时间不准导致异常时才需要打开。
 */
export const cmgSetServerTime: (ms: number) => number;

/**
 * 初始化。
 * @param tag        媒体 tagId
 * @param url        activeURL，**必须是完整 URL**（参与密钥派生）
 * @param assetsDir  资产目录；不传则按内置候选路径查找（桌面用）
 * @returns 0 成功，<0 失败（用 cmgLastError() 取详情）
 */
export const cmgInit: (tag: string, url: string, assetsDir?: string) => number;

/**
 * 原地处理单个 NALU。
 * @param buf ArrayBuffer（**会被原地修改**）
 * @returns 输出长度（正常 == 输入长度），<0 失败
 */
export const cmgDecryptNalu: (buf: ArrayBuffer) => number;

/**
 * 原地处理一整段 TS（内部走 PAT→PMT→PES→NALU）。
 * @param buf ArrayBuffer（**会被原地修改**）
 * @returns 处理的 NALU 数，<0 失败
 */
export const cmgDecryptTs: (buf: ArrayBuffer) => number;

/**
 * `cmgDecryptTs` 的**异步**版：在 N-API work 线程执行。
 * 同步版单分片要数百毫秒，期间 JS 线程停摆（UI 不重绘、本地 HTTP 不收发）⇒ 周期性卡顿。
 * 异步版用一把全局互斥锁把处理串行化（会话有状态，不能真并行），语义与同步版一致。
 *
 * ⚠️ Promise 落地前，调用方不得改写 `buf`（原地处理、长度不变）。
 *
 * @param buf ArrayBuffer（**会被原地修改**）
 * @returns Promise<number>：处理的 NALU 数，<0 失败
 */
export const cmgDecryptTsAsync: (buf: ArrayBuffer) => Promise<number>;

/** 取统计（见 CmgStat） */
export const cmgGetStat: () => CmgStat;

/** 释放运行时 */
export const cmgUninit: () => void;

/** 版本串 */
export const cmgVersion: () => string;

/** 最近一次错误描述 */
export const cmgLastError: () => string;

/* ===================================================================================
 * 取流签名（同属 libcmg_napi.so）
 * =================================================================================== */

/** 初始化签名器。0 = 成功 */
export const yspSignInit: () => number;

/** 32 位 hex；失败返回空串（用 yspSignLastError() 取原因） */
export const yspGenTokenRnd: (guid: string, token: string, tsMs: string) => string;

/**
 * 32 位 hex。
 * @param tsMs String(Date.now())
 */
export const yspGenSignature: (pid: string, guid: string, seqId: string, reqId: string,
  sessionToken: string, tsMs: string, yspSdkInput: string) => string;

/** 124 位 hex（62 字节） */
export const yspGenYspTicket: (pid: string, authTs: string, cnlId: string, guid: string,
  yspAppId: string, appVer: string) => string;

/** ⚠️ 尚未原生实现 ⇒ 当前恒返回空串（该值在 ArkTS 侧由 `ckey_core` 提供，不在本仓库） */
export const yspGenCKey: (cnlId: string, tsSec: string, appVer: string, guid: string,
  platform: string, docUrl: string) => string;

/** 签名模块版本串 */
export const yspSignVersion: () => string;

/** 最近一次签名错误 */
export const yspSignLastError: () => string;
