# CMakeLists.txt —— （历史）gate1 CMG 解密 N-API 模块
#
# ★★★ 2026-11-07：**本文件已不是任何一端的构建入口，仅作技术留存** ★★★
#   鸿蒙现行入口 = `harmony/entry/src/main/cpp/CMakeLists.txt`，只编
#   `palmtv_napi.c` / `ysp_ckey_self.c` / `jstv_sign.c` / `jstv_napi.c` → `libpalmtv_napi.so`。
#   下面这份 CMG 源清单（cmg_* + ysp_* + thirdparty）**三端都不再编译**；
#   需要复现历史 CMG 能力时再用它 add_subdirectory 单独构建。
#
# 桌面验证（不需要 N-API，用 ctest）：
#   gcc -O2 -std=c11 -Iinclude -Isrc -I../thirdparty/cmg -I../thirdparty/wasm-rt \
#       -o ctest.exe src/ctest_main.c src/cmg_runtime.c src/ts_demux.c \
#       src/cmg_debug_stubs.c src/cmg_env.c \
#       ../thirdparty/cmg/cmg_c.c ../thirdparty/wasm-rt/wasm-rt-impl.c \
#       ../thirdparty/wasm-rt/wasm-rt-mem-impl.c -lm

cmake_minimum_required(VERSION 3.5.0)
project(cmg_napi C)

set(NATIVE_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(HMNATIVE_DIR ${NATIVE_DIR}/..)

set(CMG_SOURCES
  ${NATIVE_DIR}/src/cmg_napi.c
  ${NATIVE_DIR}/src/cmg_runtime.c
  ${NATIVE_DIR}/src/ts_demux.c
  ${NATIVE_DIR}/src/cmg_env.c
  ${NATIVE_DIR}/src/cmg_debug_stubs.c
  # ---- gate3 签名（keygen_bg.wasm + RJq7sO71JF.wasm，wasm2c 产物）----
  ${NATIVE_DIR}/src/ysp_napi.c
  ${NATIVE_DIR}/src/ysp_sign.c
  ${NATIVE_DIR}/src/ysp_keygen.c
  ${NATIVE_DIR}/src/ysp_rjq.c
  ${NATIVE_DIR}/src/ysp_aes.c
  # ---- 江苏台（荔枝 TV）取流签名：MD5 + txSecret（纯计算，无 wasm）----
  ${NATIVE_DIR}/src/jstv_sign.c
  ${NATIVE_DIR}/src/jstv_napi.c
  ${HMNATIVE_DIR}/thirdparty/cmg/cmg_c.c
  ${HMNATIVE_DIR}/thirdparty/ysp/keygen_c.c
  # ★ 2026-09-29：`thirdparty/ysp/rjq_c.c`（11.6 MB，RJq7sO71JF.wasm 的 wasm2c 产物）
  #   **已从源清单移除并删除文件** —— yspticket 改为常量密钥流实现（见 `src/ysp_rjq.c` 文件头）。
  #   需要回退 wasm 路径时：定义 `-DYSP_RJQ_USE_WASM=1` 并把 rjq_c.c 恢复（原始 .wasm 仍在
  #   `thirdparty/ysp/wasm-src/`，可用 wabt wasm2c 重新生成）。
  ${HMNATIVE_DIR}/thirdparty/wasm-rt/wasm-rt-impl.c
  ${HMNATIVE_DIR}/thirdparty/wasm-rt/wasm-rt-mem-impl.c
)

add_library(cmg_napi SHARED ${CMG_SOURCES})

target_include_directories(cmg_napi PRIVATE
  ${NATIVE_DIR}/include
  ${NATIVE_DIR}/src
  ${HMNATIVE_DIR}/thirdparty/cmg
  ${HMNATIVE_DIR}/thirdparty/ysp
  ${HMNATIVE_DIR}/thirdparty/wasm-rt
)

# 启用 N-API 绑定（桌面 ctest 时不加此定义，cmg_napi.c 会自动空置）
target_compile_definitions(cmg_napi PRIVATE CMG_WITH_NAPI=1 PALMTV_WITH_NAPI=1)

# cmg_c.c 是 wasm2c 产物，需要放宽告警；优化等级与 gate0 保持一致（-O2）
target_compile_options(cmg_napi PRIVATE -O2 -std=c11 -Wno-unused -Wno-implicit-fallthrough)

# 鸿蒙会注入 libace_napi.z.so 等；如未自动链接可显式：
# target_link_libraries(cmg_napi PUBLIC libace_napi.z.so)
