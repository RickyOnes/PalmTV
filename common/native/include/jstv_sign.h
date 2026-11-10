/**
 * jstv_sign.h —— 江苏电视台（荔枝 TV / live.jstv.com）直播取流签名
 *
 * 来源：桌面版 IPTV 播放器的 `Services/JiangsuTvProxyService.cs`（荔枝台本地代理）
 *   txTime   = Unix 秒的小写 8 位十六进制（C# `ToString("x8")`）
 *   txSecret = md5hex(KEY + streamId + txTime)
 *   最终上游地址 = https://litchi-play-encrypted-site.jstv.com{path}{streamId}.m3u8
 *                     ?txSecret=<32hex>&txTime=<8hex>
 *
 * ★ 只有 KEY 是"秘密"（`7cSrbhisZe2tF3N3ZGPN`，2026-10-22 轮换；旧值已全部 403）⇒ 放 native，ArkTS 侧看不到。
 *   其余（host / path / Referer / UA）都在 `entry/src/main/ets/common/JiangsuTv.ets`。
 *
 * 纯字符串运算 + MD5（RFC 1321），**无网络、无状态** ⇒ 可在 PC 上直接单测。
 */
#ifndef JSTV_SIGN_H
#define JSTV_SIGN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 生成签名查询串 `txSecret=<32hex>&txTime=<8hex>`（**不含**前导 `?`）。
 *
 * @param stream_id 荔枝 TV 流 ID（如 "jswspro"、"jsws4kpro"）
 * @param unix_sec  Unix 秒（txTime 的十进制来源）
 * @param out       输出缓冲（建议 ≥ 96 字节）
 * @param cap       缓冲容量
 * @return 0 成功；<0 失败（用 jstv_sign_last_error() 取原因）
 */
int jstv_sign_query(const char* stream_id, long long unix_sec, char* out, size_t cap);

/** 小写 8 位十六进制 txTime（= Unix 秒的低 32 位，与 C# `ToString("x8")` 一致） */
int jstv_tx_time(long long unix_sec, char* out, size_t cap);

/** 纯 MD5 hex（小写，32 字符）。用于离线与 C#/Node 对拍。 */
int jstv_md5_hex(const char* s, char* out, size_t cap);

/** 模块版本串（形如 "jstv 1.0"） */
const char* jstv_sign_version(void);

/** 最近一次错误描述（空串 = 无错） */
const char* jstv_sign_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* JSTV_SIGN_H */
