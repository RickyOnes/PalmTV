# CMakeLists.txt —— 鸿蒙侧 native 模块（产出 libpalmtv_napi.so）
#
# ★★★ 2026-11-07：**鸿蒙端只剩"自研 cKey + 江苏台签名"** ★★★
#
#   与安卓 `Android/app/src/main/cpp/CMakeLists.txt`、桌面 `common/build/build-palmtv-core.ps1`
#   用**同一份 C 核**（`common/native/src`），只是绑定层不同（这里是 N-API，安卓是 JNI，桌面是 P/Invoke）：
#     · `ysp_ckey_self.c` —— 央视频「安卓平台」cKey（TEA 链 + BKDR131 + XOR16 + 私有 base64）
#     · `jstv_sign.c`     —— 江苏荔枝 txSecret（MD5）
#     · `sm4c.c`          —— **ChinaDRM 8 个加密台**的分片解密（2026-11-08 从安卓 `Sm4C.kt` 移植为 C）
#
#   ★ 2026-11-07 一并移出鸿蒙编译（**源文件仍在 `common/`，属技术留存，不要再往这里加**）：
#     · CMG 解密核：`cmg_runtime` / `ts_demux` / `cmg_env` / `cmg_debug_stubs` / `cmg_c` + wasm-rt
#     · Web/PC 取流链签名：`ysp_sign` / `ysp_keygen` / `ysp_rjq` / `ysp_aes` + `keygen_c`
#   原因：鸿蒙已改走"自研 cKey → liveinfo（`platform=4330303`）→ **明文** HLS"，
#     既不需要 CMG 解密，也不再需要 auth / openToken / yspsdksign 那串 Web/PC 签名。
#
# ★ 本文件引用**本仓库内**的公共核（`common\native`），三端共用同一份源码：
#   harmony/entry/src/main/cpp/  →  ../../../../../common/native/
#         ..                = main
#         ../..             = src
#         ../../..          = entry
#         ../../../..       = harmony
#         ../../../../..    = <仓库根>
#   ⇒ 换机器 / 换目录 / 别人 clone 之后路径依然成立（不依赖任何仓库外目录）。
#
# 如需改为其他位置，可在 DevEco 的 CMake 参数里覆盖：
#   -DPALMTV_NATIVE_DIR=<绝对路径>

cmake_minimum_required(VERSION 3.5.0)
project(palmtv_napi C)

set(CMAKE_C_STANDARD 11)

# ---------- 定位公共核 ----------
if(NOT DEFINED PALMTV_NATIVE_DIR)
  set(PALMTV_NATIVE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../common/native)
endif()
if(NOT EXISTS ${PALMTV_NATIVE_DIR}/src/ysp_ckey_self.c)
  message(FATAL_ERROR
    "找不到公共核: ${PALMTV_NATIVE_DIR}\n"
    "请确认 common/native/ 存在，或用 -DPALMTV_NATIVE_DIR=<绝对路径> 指定。")
endif()
get_filename_component(PALMTV_NATIVE_DIR ${PALMTV_NATIVE_DIR} ABSOLUTE)

message(STATUS "PALMTV_NATIVE_DIR = ${PALMTV_NATIVE_DIR}")

# ---------- 源文件（只有 5 个） ----------
set(PALMTV_SOURCES
  # N-API 模块入口（注册 yspSelfGenCKey / yspSm4Decrypt / jstv*）
  ${PALMTV_NATIVE_DIR}/src/palmtv_napi.c
  # ★ 自研 cKey（迭代③，纯 C 零依赖；与安卓/桌面同一份）
  ${PALMTV_NATIVE_DIR}/src/ysp_ckey_self.c
  # 江苏台（荔枝 TV）txSecret 签名（纯 C + MD5）
  ${PALMTV_NATIVE_DIR}/src/jstv_sign.c
  ${PALMTV_NATIVE_DIR}/src/jstv_napi.c
  # ★ ChinaDRM(sm4c) 分片解密：CCTV-4K/11/12/14/15/16/16+/17 这 8 个台的 TS 分片
  ${PALMTV_NATIVE_DIR}/src/sm4c.c
)

# ---------- 目标 ----------
add_library(palmtv_napi SHARED ${PALMTV_SOURCES})

target_include_directories(palmtv_napi PRIVATE
  ${PALMTV_NATIVE_DIR}/include
  ${PALMTV_NATIVE_DIR}/src
)

# ★★ 必须定义 _GNU_SOURCE ★★
#   ohos 的 musl sysroot 头文件按特性宏严格门控：`-std=c11`（纯 ISO）下 clang 不定义
#   _POSIX_C_SOURCE/_DEFAULT_SOURCE ⇒ POSIX 符号全部"未声明"。这里用 gnu11 + 显式宏双保险。
target_compile_definitions(palmtv_napi PRIVATE
  PALMTV_WITH_NAPI=1
  NDEBUG=1
  _GNU_SOURCE=1
)

# ⚠️ 不要把 `-std=c11` 放在这里：它会覆盖 DevEco 默认的 `-std=gnu11`（后写的生效）。
target_compile_options(palmtv_napi PRIVATE
  -std=gnu11
  -fvisibility=hidden
  -Wno-unused -Wno-int-conversion
)

# cKey / sm4c 都是 CPU 密集的纯计算，固定 -O2（不受 debug 构建的 -O0 影响）：
#   · cKey：每次换台/重试算一次（56 轮 TEA）
#   · sm4c：**每个加密分片 2~3 MB**，-O0 会慢 5~10 倍（播放线程直接卡）
set_source_files_properties(
  ${PALMTV_NATIVE_DIR}/src/ysp_ckey_self.c
  ${PALMTV_NATIVE_DIR}/src/sm4c.c
  PROPERTIES COMPILE_OPTIONS "-O2"
)

# 链接 N-API（鸿蒙 SDK 提供）
find_library(ace_napi_lib ace_napi.z)
if(NOT ace_napi_lib)
  message(FATAL_ERROR "找不到 libace_napi.z.so —— 请在 DevEco 里配置好 HarmonyOS SDK")
endif()
target_link_libraries(palmtv_napi PUBLIC ${ace_napi_lib})
