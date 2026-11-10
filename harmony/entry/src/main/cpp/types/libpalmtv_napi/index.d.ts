/**
 * libpalmtv_napi.so 的 TS 类型声明（对应 common/native/src/palmtv_napi.c）
 *
 * 模块内容（2026-11-08 起）：
 *   · 自研 cKey —— `yspSelfGenCKey`（`common/native/src/ysp_ckey_self.c`）
 *   · 江苏台签名 —— `jstv*`（`common/native/src/jstv_sign.c`）
 *   · ChinaDRM 8 个加密台的 sm4c 分片解密 —— `yspSm4*`（`common/native/src/sm4c.c`）
 * CMG 解密与 Web/PC 取流签名（yspSign*）**已从鸿蒙移除**，不再有对应接口。
 */

/* ===================================================================================
 * 自研 cKey（迭代③）：央视频「安卓平台」格式，`--01` + base64url 共 682 字符
 *
 * 算法：TEA 链（16 轮 / 大端 64 位块）+ BKDR131 尾部摘要 + XOR16 + 私有 base64（末两位 "_-"）
 * 详见 `docs/ysp-ckey/01-算法定稿.md`；与安卓 `libpalmtv.so`、桌面 `PalmTVCore.dll` 同一份 C 源。
 * =================================================================================== */

/**
 * 生成一枚 cKey。
 * @param tsSec 秒级时间戳（**必须与请求参数 `fntick` 同一秒**，服务端校验时效）
 * @param cnlid 频道/节目号（10 位数字；长度不符则沿用载荷模板里的值）
 * @param guid  设备 id（32 位 hex；**必须与 HTTP 请求参数 `guid` 完全一致**，服务端交叉校验载荷内那份）
 * @returns cKey 字符串；失败返回空串（调用方据此报错，**没有兜底链路**）
 */
export const yspSelfGenCKey: (tsSec: number, cnlid: string, guid: string) => string;

/** 自研 cKey 实现的版本串（日志/灰度判断用的哪套实现） */
export const yspSelfVersion: () => string;

/* ===================================================================================
 * ChinaDRM(sm4c) 分片解密 —— 8 个加密台（CCTV-4K/11/12/14/15/16/16+/17）
 *
 * 移植自安卓 `Sm4C.kt`（规则见 `docs/ysp-ckey/ref/drm/HANDOFF.md` §1/§3）：
 *   标准 SM4-CBC；按台密钥（pid 决定）；IV 优先取 PSSH 显式 IV，否则 hex(contentID 前 8 字符)；
 *   每个 slice NAL(type 1/5) 从第 32 字节起解，**先去 EPB 再解**，加密长度 = 16×⌊(L−1)/16⌋。
 * =================================================================================== */

/**
 * 解密一个 HLS 分片（MPEG-TS），**返回一个新的 ArrayBuffer**。
 *
 * ⚠️ 不要把返回值当成"可选优化"：native 与 ArkTS **不共享同一块内存**（真机实测：
 *   native 说解完了、ArkTS 侧字节没变 ⇒ 播放器拿到密文 ⇒ prepare 超时）。
 *   `undefined` = 不是 sm4c（明文台），此时用入参原样转发。
 *
 * @param data 分片原始字节（**不会被修改**）
 * @param pid  频道 pid（决定台密钥；空串 = 兜底 key）
 * @returns 解密后的新 buffer；`undefined` = 不是 sm4c
 */
export const yspSm4Decrypt: (data: ArrayBuffer | Uint8Array, pid: string) => ArrayBuffer | undefined;

/** 最近一次 `yspSm4Decrypt` 解出的 slice 数（0 = 不是 sm4c） */
export const yspSm4LastSlices: () => number;

/** 最近一次 sm4c 结论（"非 TS" / "sm4c 解密 N slice（…）"，日志用） */
export const yspSm4LastReason: () => string;

/** sm4c 实现版本串 */
export const yspSm4Version: () => string;

/* ===================================================================================
 * 江苏台（荔枝 TV / live.jstv.com）取流签名
 *
 *     txTime   = Unix 秒的小写 8 位十六进制
 *     txSecret = md5hex(KEY + streamId + txTime)
 * ★ 只有 KEY 留在 .so 里；host / path / Referer / UA 在 `common/JiangsuTv.ets`。
 * 该流**不加密**（TS 明文直通），所以这里只有签名，没有解密。
 * =================================================================================== */

/**
 * 生成上游地址的签名查询串 `txSecret=<32hex>&txTime=<8hex>`（不含前导 `?`）。
 * @param streamId 荔枝 TV 流 ID（如 'jswspro'）
 * @param unixSec  Unix 秒（`Math.floor(Date.now()/1000)`）
 * @returns 失败返回空串（用 jstvSignLastError() 取原因）
 */
export const jstvSignQuery: (streamId: string, unixSec: number) => string;

/** 小写 8 位十六进制 txTime（自检用，等价于 C# `ToString("x8")`） */
export const jstvTxTime: (unixSec: number) => string;

/** 纯 MD5 hex（自检/与 C# 对拍用） */
export const jstvMd5Hex: (s: string) => string;

/** 江苏台签名模块版本串 */
export const jstvSignVersion: () => string;

/** 最近一次江苏台签名错误 */
export const jstvSignLastError: () => string;
