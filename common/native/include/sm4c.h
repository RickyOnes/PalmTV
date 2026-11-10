/**
 * sm4c.h —— 央视频 ChinaDRM(sm4c) 分片解密（8 个加密台）
 *
 * 实现在 `src/sm4c.c`（从安卓 `Sm4C.kt` 逐行移植）；规则见
 * `docs/ysp-ckey/ref/drm/HANDOFF.md` §1/§3。
 *
 * ```c
 * int n = sm4c_try_decrypt(buf, len, "600001806");
 * // n > 0 ⇒ 已就地解密 n 个 slice；n == 0 ⇒ 不是 sm4c（data 未被修改，可当明文继续用）
 * ```
 * ⚠️ 这个函数是**就地**改写；鸿蒙 N-API 那边**不能**把 ArkTS 的 buffer 直接传进来
 *   （实测 native 改了、ArkTS 侧看不到）⇒ `palmtv_napi.c` 里先 memcpy 一份再解，
 *   并把结果作为**新 ArrayBuffer** 返回。
 */
#ifndef PALMTV_SM4C_H
#define PALMTV_SM4C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 尝试按 sm4c 规则**就地**解密一个 HLS 分片（MPEG-TS）。
 *
 * @param data 分片字节（就地修改）
 * @param len  字节数
 * @param pid  频道 pid（决定用哪把台密钥；空/未知 ⇒ 用兜底 key，行为同安卓）
 * @return 解密的 slice 数；**0 = 不是 sm4c（data 未被修改）**
 */
int sm4c_try_decrypt(uint8_t* data, int len, const char* pid);

/** 最近一次调用的结论（日志用；不是 sm4c 时会写原因，如 "非 TS"） */
const char* sm4c_last_reason(void);

/** 最近一次 `sm4c_try_decrypt` 解出的 slice 数（0 = 不是 sm4c） */
int sm4c_last_slices(void);

/** 实现版本串（日志/灰度用） */
const char* sm4c_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PALMTV_SM4C_H */
