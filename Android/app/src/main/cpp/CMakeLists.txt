# CMakeLists.txt —— Android 侧 native 模块（产出 `libpalmtv.so`）
#
# ★★★ 2026-10-31：**只剩自研 cKey + 江苏台签名** ★★★
#
#   本工程 Android 端现在只有两条取流链：
#     · 央视频「安卓平台」链（cKey 自算）—— 分片是明文或 **sm4c（SM4-CBC，纯 Kotlin 解）**
#     · 江苏荔枝 / 外部 IPTV —— 明文直连
#   ⇒ native 侧只需要两个纯 C 实现：
#       `ysp_ckey_self.c`（自研 cKey，迭代③）
#       `jstv_sign.c`    （江苏台 txSecret，MD5）
#     外加唯一绑定层 `palmtv_jni.c`。
#
#   2026-10-31 一并移出 Android 编译（源码仍保留在 `common/`，桌面/鸿蒙照旧）：
#     · CMG 解密核：`cmg_runtime.c` / `ts_demux.c` / `cmg_env.c` / `cmg_debug_stubs.c`
#       + wasm2c 的 `cmg_c.c` + `wasm-rt`；
#     · Web/PC 取流链签名器：`ysp_sign.c` / `ysp_keygen.c` / `ysp_rjq.c` / `ysp_aes.c`
#       + `common/thirdparty/ysp/keygen_c.c`。
#   理由：8 个加密台的解密已由 Kotlin 的 `player/Sm4C.kt`（按台密钥）完成；
#        web/PC 链（`data/StreamResolver.kt`）与 CMG 兜底都已删除，端上不再需要它们。
#
#   ⚠️ 源清单同步点（三端）：① `common/native/CMakeLists.txt`
#      ② `harmony/entry/src/main/cpp/CMakeLists.txt` ③ `common/build/verify-native-ohos.ps1`
#      ④ `common/build/build-palmtv-core.ps1` ⑤ **本文件**。
#      但 ⑤ 是**子集**（只有 cKey + 江苏签名），改 ①②③④ 时**不要**把 cmg/ysp_* 源加回本文件。

cmake_minimum_required(VERSION 3.22.1)
project(palmtv C)

set(CMAKE_C_STANDARD 11)

# 仓库根：Android/app/src/main/cpp → ../../../../../ = <repo>
get_filename_component(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../.. ABSOLUTE)
set(NATIVE_DIR ${REPO_ROOT}/common/native)

if(NOT EXISTS ${NATIVE_DIR}/src/ysp_ckey_self.c)
  message(FATAL_ERROR "找不到公共核: ${NATIVE_DIR}/src/ysp_ckey_self.c（Android/ 必须放在仓库根下）")
endif()

add_library(palmtv SHARED
  # ---- 唯一绑定层（JNI：江苏签名 + 自研 cKey）----
  ${CMAKE_CURRENT_SOURCE_DIR}/palmtv_jni.c
  # ---- 自研 cKey（迭代③，纯 C：TEA 链 + BKDR131 + XOR16 + 私有 base64）----
  ${NATIVE_DIR}/src/ysp_ckey_self.c
  # ---- 江苏台（荔枝 TV）txSecret 签名（纯 C + MD5）----
  ${NATIVE_DIR}/src/jstv_sign.c
)

target_include_directories(palmtv PRIVATE
  ${NATIVE_DIR}/include
  ${NATIVE_DIR}/src
)

target_compile_definitions(palmtv PRIVATE
  NDEBUG=1
  _GNU_SOURCE=1
)

target_compile_options(palmtv PRIVATE
  -std=gnu11
  -fvisibility=hidden
  # 只导出 JNIEXPORT 那几个符号；其余全隐藏 ⇒ so 更小、符号表更干净
  -ffunction-sections
  -fdata-sections
  # 保守优化级别（沿用 2026-10-04 的结论：32 位 ARM 电视上先保正确性）
  -O2
  -fno-strict-aliasing
)

target_link_options(palmtv PRIVATE -Wl,--gc-sections)
