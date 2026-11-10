/**
 * ysp_sign.h —— 央视频取流签名（gate3）原生实现
 *
 * 把原先只在 WebView JS 里跑的 4 个「wasm 计算」搬到 native（鸿蒙 NAPI）：
 *   1) tokenRnd    : keygen_bg.wasm#get_token_rnd   （Rust/wasm-bindgen）
 *   2) signature   : keygen_bg.wasm#get_signature   （同上）
 *   3) yspticket   : ★ 2026-09-29 起为**常量密钥流**（逆向所得，原 RJq7sO71JF.wasm 已不再需要）
 *   4) cKey        : ❌ 不是 wasm（官方 webpack fb15 的纯 JS 密码学模块）——待办
 *
 * keygen_bg.wasm 已用 wabt wasm2c 转成 C（thirdparty/ysp/keygen_c.c），host import 桩的语义
 * 逐条对齐既有可运行实现（CCTVPlayer/legacy/WasmSigner.cs:41-55 + player.html:786-819）。
 * yspticket 的 wasm2c 产物（thirdparty/ysp/rjq_c.c，11.6 MB）已于 2026-09-29 删除；
 * 逆向结论与验证见 `re/rjq/notes.md`，回退开关为 `-DYSP_RJQ_USE_WASM=1`。
 *
 * 约定（与 cmg_runtime 一致）：
 *   - 全部返回 int：0 = 成功，<0 = 失败（错误详情见 ysp_sign_last_error()）
 *   - 输出一律是 ASCII 串（hex / 数字），不涉及编码问题
 */
#ifndef YSP_SIGN_H
#define YSP_SIGN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 初始化（装载两个 wasm 实例）。可重复调用（幂等）。返回 0 = 成功 */
int ysp_sign_init(void);

/** 释放（进程退出前调用；不调用也无害） */
void ysp_sign_uninit(void);

/** 最近一次错误（永不返回 NULL） */
const char* ysp_sign_last_error(void);

/** 版本串（用于日志确认 native 已生效） */
const char* ysp_sign_version(void);

/**
 * tokenRnd ← keygen_bg.wasm#get_token_rnd
 * @param guid   设备 guid
 * @param token  auth 响应的 token
 * @param ts_ms  毫秒时间戳字符串（String(Date.now())）
 * @return 0 成功；out 收 32 位 hex
 */
int ysp_gen_token_rnd(const char* guid, const char* token, const char* ts_ms,
                      char* out, size_t out_cap);

/**
 * signature ← keygen_bg.wasm#get_signature
 * 内部按官方拼 input：`ysp_sdk_input + "-" + guid + "-" + seq_id + "-" + req_id`
 * （对齐 player.html:886）
 * @return 0 成功；out 收 32 位 hex
 */
int ysp_gen_signature(const char* pid, const char* guid, const char* seq_id,
                      const char* req_id, const char* session_token,
                      const char* ts_ms, const char* ysp_sdk_input,
                      char* out, size_t out_cap);

/**
 * yspticket —— **常量密钥流实现**（2026-09-29 起，不再需要 wasm）
 *   明文 = `pid & ts & guid & yspappid &` + 10 个随机字母数字（恰好 62 字节）
 *   密文 = 明文 XOR 恒定密钥流（= AES-128-CTR，key/IV 为模块常量）
 * ⚠️ 随机尾缀由本地 PRNG 生成：**线上实测服务端不校验尾缀**（见 re/rjq/notes.md §1.5）。
 *    排障/复现可用环境变量 `YSP_TICKET_TAIL`（10 字符）固定它。
 * @return 0 成功；out 收 124 位**小写** hex（62 字节）
 */
int ysp_gen_yspticket(const char* pid, const char* ts_sec, const char* cnl_id,
                      const char* guid, const char* ysp_app_id, const char* app_ver,
                      char* out, size_t out_cap);

/**
 * cKey（占位：尚未原生实现）
 * 官方 cKey 由 webpack 模块 fb15（ts_module_body.js，内联 CryptoJS 风格库）算出，
 * 与任何 wasm 无关。移植需要把该 JS 密码学手工重写成 C —— 见 README。
 * 当前直接返回 -2（未实现），调用方应据此降级/跳过。
 */
int ysp_gen_ckey(const char* cnl_id, const char* ts_sec, const char* app_ver,
                 const char* guid, const char* platform, const char* doc_url,
                 char* out, size_t out_cap);

/** 诊断：keygen 实例是否就绪 / RJq 实例是否就绪 */
int ysp_sign_ready(void);

#ifdef __cplusplus
}
#endif

#endif /* YSP_SIGN_H */
