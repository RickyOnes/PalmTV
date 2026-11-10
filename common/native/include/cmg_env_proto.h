/*
 * cmg_env_proto.h —— **仅供桌面 DLL 构建使用**的前置声明 shim（编译期 `-include`，不改 hmnative 共享源码）
 *
 * 背景（2026-09-20 实测）：`cmg_runtime.c` 调用了 `cmg_env.c` 里的三个内部函数，
 * 但**这三个函数在任何头文件里都没有声明**：
 *
 *     env_set_clock_real(int on)          ← cmg_rt_set_clock_real() 调用
 *     env_set_clock_offset_ms(f64 off)    ← cmg_rt_set_server_time() 调用
 *     env_local_now_ms(void) -> f64       ← cmg_rt_set_server_time() 调用
 *
 * GCC/clang 在 C11 下按"隐式 int"处理 ⇒ **`env_local_now_ms()` 的 f64 返回值会被截断成 int**，
 * `env_set_clock_offset_ms` 的 double 参数也会被按 int 传 ⇒ 服务器时间对齐能力必然算错。
 *
 * 实际影响面：只有 `cmg_rt_set_server_time()` 受影响（本 App 未启用该能力）；
 * `cmgSetClockMode(1)`（直播必须的真实墙钟）走的是 void 返回的 `env_set_clock_real` ⇒ 无害。
 * 鸿蒙侧同理，所以那边一直没暴露 —— 但既然要三端共用，这里就补干净，
 * **并且绝不去动 `D:\TV\hmnative\` 的源码**（那是三端单一源，只能从构建侧修）。
 *
 * ⚠️ 类型必须与 `cmg_env.c` 里的定义逐字一致（`f64` 在该工程里就是 double）。
 */
#ifndef CMG_ENV_PROTO_SHIM_H
#define CMG_ENV_PROTO_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

void env_set_clock_real(int on);
void env_set_clock_offset_ms(double off);
double env_local_now_ms(void);

#ifdef __cplusplus
}
#endif

#endif /* CMG_ENV_PROTO_SHIM_H */
