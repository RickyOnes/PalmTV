/**
 * ts_demux.h —— 轻量 MPEG-TS 解复用（不依赖 FFmpeg）
 *
 * 用途：从一段 TS 里把 ES 载荷中的 NALU 找出来（原地可写），
 *       再交给 cmg_runtime 解密。这是「TS 原地解密」路线的基础。
 *
 * 假设（与真实 CCTV 流一致，已在 gate0 验证）：
 *   - 包长 188；PAT/PMT 的单个 section 落在单个 TS 包内；
 *   - 目标 ES 为 AVC（type 1/5 需要解密）；PES 头长度由字节 8 给出。
 */
#ifndef TS_DEMUX_H
#define TS_DEMUX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint8_t* data;   /* NALU 起始（**不含** 00 00 01 startcode），指向入参 TS 缓冲内部 */
  size_t   len;    /* NALU 长度 */
  int      pid;    /* 所属 ES PID */
  int      nal_type;/* H.264 NAL type（data[0] & 0x1f） */
} ts_nalu_t;

/** 回调：返回 0 继续，非 0 提前终止（返回值原样作为 ts_demux_foreach_nalu 的结果）。 */
typedef int (*ts_nalu_cb)(void* user, ts_nalu_t* nalu);

/**
 * 遍历 TS 中所有 NALU。回调内可原地修改 nalu->data 指向的内容
 * （前提：修改长度不变 —— CMG 解密就是长度恒等的）。
 * @return 处理的 NALU 数（若回调提前终止则返回其返回值），<0 失败
 */
int ts_demux_foreach_nalu(uint8_t* ts, size_t len, ts_nalu_cb cb, void* user);

/** 该 PID 是否是 PAT（0）——便于调用方判断。 */
int ts_demux_is_pat(uint8_t* ts, size_t len);

#ifdef __cplusplus
}
#endif
#endif /* TS_DEMUX_H */
