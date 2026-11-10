/**
 * cmg_runtime.h —— CMG 解密运行时（gate1 / N-API 模块的 C 内核）
 *
 * 把 gate0 在 tools/native_dec/main2.c 里验证过的解密流程封装成稳定 API：
 *   init（一次性） → decrypt_nalu / decrypt_ts（可重复） → uninit
 *
 * ★ 核心事实（2026-09-14 定案，别踩）：
 *   - 解密入口是 wasm 导出 `ma`（= `_CMG_jsdecLive8`），签名
 *     `(tagIdPtr, naluPtr, naluLen, urlLen)`，结果**原地写回** naluPtr。
 *   - `da`（`_CMG_UpdatePlayer`）只推进状态，**不解密**。
 *   - **首帧**需要前缀序列 `la → ka → ga → ea`（= jsdecLive7/6/2/0），
 *     后续帧**只调 `ma`**。每帧都跑前缀会破坏状态。
 *   - 诊断指纹：`ma` 取指 5 万~200 万条/帧 = 正常；恒定 2094 条 = 提前返回（输出=输入）。
 */
#ifndef CMG_RUNTIME_H
#define CMG_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmg_rt cmg_rt;

typedef struct {
  unsigned long frames;       /* 累计解密帧数 */
  unsigned long last_ma_pcs;  /* 最近一帧 ma 的 f51 取指数（见文件头"诊断指纹"） */
  unsigned long unchanged;    /* 输出与输入**逐字节相同**（= 该帧没被解密）的帧数 */
  unsigned long reseeds;      /* 重播前缀序列（会话续期）的次数 */
  unsigned long restarts;     /* 「初始化完成态」原地重启次数（会话死亡自愈） */
  unsigned long retries;      /* 帧内重试次数（衰减命中后当帧整机重启重解，不丢帧）*/
  unsigned long short_nalus;  /* 被跳过的短 type-1/5 NALU 数（伪 NALU 规模，见 ts_nalu_handler）*/
  unsigned long bad_nalus;    /* 「被解成错误内容」（改动≠0 但 NAL 头不合法）的帧数，已当帧重解自愈 */
  int           first_pending;/* 1 = 下一帧仍会走前缀序列 */
} cmg_rt_stat;

/**
 * 初始化运行时。
 * @param out         输出句柄
 * @param tag         媒体 tagId（如 "1788255533974"），非 NULL
 * @param url         activeURL，**必须是完整 43 字符 URL**（种子三要素之一），非 NULL
 * @param assets_dir 存放 eb_prog.bin / reloc_table.bin / CMGPlayer.json 的目录；
 *                    传 NULL 时按内置候选路径查找
 * @return 0 成功，<0 失败（用 cmg_rt_last_error() 取详情）
 */
int  cmg_rt_init(cmg_rt** out, const char* tag, const char* url, const char* assets_dir);

/** 释放运行时。可传 NULL。 */
void cmg_rt_uninit(cmg_rt* rt);

/**
 * 原地解密单个 NALU。
 * @param nalu 输入/输出缓冲（原地改写）
 * @param len  长度
 * @return 输出长度（正常 == len），<0 失败
 */
long cmg_rt_decrypt_nalu(cmg_rt* rt, uint8_t* nalu, size_t len);

/**
 * 原地解密一整段 TS（遍历 PES→NALU，对 type 1/5 调用 decrypt_nalu）。
 * @return 已解密的 NALU 数，<0 失败
 */
long cmg_rt_decrypt_ts(cmg_rt* rt, uint8_t* ts, size_t len);

/** 取统计信息。 */
void cmg_rt_get_stat(cmg_rt* rt, cmg_rt_stat* st);

/**
 * 诊断抓取：把最近 ring 个分片的**密文 + 明文 + 元信息**落盘（滚动覆盖），
 * 供在 PC 上用官方 gold 离线对拍同一条密文。dir 必须已存在；ring<=0 关闭。
 */
void cmg_rt_set_capture(const char* dir, int ring);

/**
 * 时钟模式：real=1 ⇒ 真实墙钟（**直播必须**，与官方 Date.now 一致）；
 *          real=0 ⇒ 确定性虚拟钟（离线 fixture 回归用）。
 * 实测（真机抓取分片 + 官方 gold 逐帧逐字节）：真实钟与官方 0 字节差异；
 * 虚拟钟(起点 1788873740818/+3ms，为旧 fixture 调的值)首帧差 1464 字节 ⇒ 直播会出马赛克。
 */
void cmg_rt_set_clock_real(int real);

/**
 * 用服务器时间对齐本机时钟（官方与原版鸿蒙都取 `https://csapi.yangshipin.cn/voapi/omsot/serverTime`）。
 * 偏差超过 ±1 天会被忽略（防解析错误）。只需在初始化后调用一次。
 */
void cmg_rt_set_server_time(double server_ms);

/**
 * 开始新分片 / 新 GOP：重播解密前缀序列（jsdecLive7→6→2→0），把 CMG 会话"续上"。
 * **每个 HLS 分片都调用一次最稳**（CMG 的 `ma` 有会话状态，连续解很多帧后会漂移：
 * 真机表现为"前几秒正常、之后逐渐花屏"，桌面实测同一分片第 ~108 条 NALU 起直接提前返回）。
 */
void cmg_rt_reseed(cmg_rt* rt);

/** 最近一次错误描述（线程不安全，仅调试用）。 */
const char* cmg_rt_last_error(void);

/** 版本串（便于排查部署的是哪一版）。 */
const char* cmg_rt_version(void);

#ifdef __cplusplus
}
#endif
#endif /* CMG_RUNTIME_H */
