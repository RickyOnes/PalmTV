/**
 * palmtv_jni.c —— Android 侧**唯一**的 native 绑定层（产出 `libpalmtv.so`）
 *
 * ★★★ 2026-10-31：只保留「Android 端真正用到」的两件事 ★★★
 *   本工程 Android 端只有两条取流链：
 *     · 央视频「安卓平台」链（cKey 自算）—— 分片是**明文**或 **sm4c（SM4-CBC）**，
 *       sm4c 由 Kotlin 的 `player/Sm4C.kt` 用**按台密钥**解密，不经过 native；
 *     · 江苏荔枝 / 外部 IPTV —— 明文直连。
 *   ⇒ 原生侧只需：
 *     · `SelfCKey`  —— 自研 cKey（`common/native/src/ysp_ckey_self.c`，纯 C）
 *     · `JstvSign`  —— 江苏台 txSecret 签名（`common/native/src/jstv_sign.c`，纯 C + MD5）
 *
 * ★ 2026-10-31 已从本 so 移除（源码仍在 `common/`，桌面/鸿蒙照旧编）：
 *     · `CmgNative`（CMG 解密核：cmg_runtime / cmg_env / ts_demux / cmg_c + wasm-rt）
 *       —— 8 个加密台已由 sm4c 解密，CMG 兜底无实际价值（移动端 cKey 链不会给 CMG 变体）；
 *     · `YspSign`（Web/PC 取流链签名：ysp_sign / ysp_keygen / ysp_rjq / ysp_aes）
 *       —— 那条链在 Android 上已整体删除（见 `MainViewModel` 的注释）。
 *   连带的 `nDlopenRaw`（裸 dlopen 官方 .so 的诊断入口）也一并移除：它只服务于 CMG 诊断。
 *
 * 设计约束：
 *   · 只做"字符串进出 + 串行化"，算法全在 `common/native`（三端单一源）；
 *   · 输出串全是 ASCII（base64/hex/数字），`NewStringUTF` 安全；
 *   · 失败返回空串/NULL，**不抛**（由 Kotlin 侧转成明确异常，见 `SelfCKey` / `JstvSign`）。
 */
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jstv_sign.h"

/* 实现在 common/native/src/ysp_ckey_self.c（纯 C、无第三方依赖） */
extern int ysp_self_gen_ckey(char* out, int cap, long long ts_sec, const char* cnlid,
                             const char* guid);

/* ------------------------------------------------------------------ */
/* 串行化：两个实现都是纯函数，但共用 dup/new 辅助与静态错误串 ⇒ 统一加锁 */
/* ------------------------------------------------------------------ */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define OUT_CAP 2048

static char* dup_utf8(JNIEnv* env, jstring s) {
  if (s == NULL) return NULL;
  const char* p = (*env)->GetStringUTFChars(env, s, NULL);
  if (p == NULL) return NULL;
  char* out = strdup(p);
  (*env)->ReleaseStringUTFChars(env, s, p);
  return out;
}

static jstring new_ascii(JNIEnv* env, const char* s) {
  return (*env)->NewStringUTF(env, s == NULL ? "" : s);
}

/* ------------------------------------------------------------------ */
/* com.rickyone.palmtv.native.JstvSign                                  */
/* ------------------------------------------------------------------ */

JNIEXPORT jstring JNICALL
Java_com_rickyone_palmtv_native_JstvSign_nSignQuery(JNIEnv* env, jobject thiz,
                                                    jstring streamId, jlong unixSec) {
  (void)thiz;
  char out[256];
  char* s = dup_utf8(env, streamId);
  pthread_mutex_lock(&g_lock);
  int rc = jstv_sign_query(s, (long long)unixSec, out, sizeof(out));
  pthread_mutex_unlock(&g_lock);
  free(s);
  return new_ascii(env, rc == 0 ? out : "");
}

JNIEXPORT jstring JNICALL
Java_com_rickyone_palmtv_native_JstvSign_nVersion(JNIEnv* env, jobject thiz) {
  (void)thiz;
  return new_ascii(env, jstv_sign_version());
}

/* ------------------------------------------------------------------ */
/* com.rickyone.palmtv.native.SelfCKey                                  */
/* ------------------------------------------------------------------ */

JNIEXPORT jstring JNICALL
Java_com_rickyone_palmtv_native_SelfCKey_nativeGen(JNIEnv* env, jclass cls,
                                                   jlong ts_sec, jstring jcnlid,
                                                   jstring jguid) {
  char out[768];
  int n;
  (void)cls;

  char* cnlid = dup_utf8(env, jcnlid);
  char* guid = dup_utf8(env, jguid);

  pthread_mutex_lock(&g_lock);
  n = ysp_self_gen_ckey(out, (int)sizeof(out), (long long)ts_sec, cnlid, guid);
  pthread_mutex_unlock(&g_lock);

  free(cnlid);
  free(guid);

  if (n <= 0) return NULL;
  return (*env)->NewStringUTF(env, out);
}

/** 自研 cKey 实现的版本号（供日志/灰度判断用的是哪套实现） */
JNIEXPORT jint JNICALL
Java_com_rickyone_palmtv_native_SelfCKey_nativeVersion(JNIEnv* env, jclass cls) {
  (void)env; (void)cls;
  return 1;
}
