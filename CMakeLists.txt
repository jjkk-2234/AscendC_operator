# ----------------------------------------------------------------------------------------------------------
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# This program is free software, you can redistribute it and/or modify it under the terms and conditions of
# CANN Open Software License Agreement Version 2.0 (the "License").
# Please refer to the License for details. You may not use this file except in compliance with the License.
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
# See LICENSE in the root of the software repository for the full text of the License.
# ----------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# dequant_asc —— Per-Channel 反量化（y = (float(x) - zp) * scale[n]）
#
# 一次只编一个源文件，改下面「★ 选择源文件」那一行即可。
# 可执行文件名 = 源文件名去掉 .asc
#
# 常用流程（在 build/ 里即可，三个便捷 target 的工作目录都已切好）：
#   cd dequant_asc && mkdir -p build && cd build
#   cmake ..                 # RUN_MODE 默认 npu、架构默认 dav-2201，普通编译不用传参数
#   make -j
#   make gen                 # 生成测试数据（用同一组 RUN_M/RUN_N，保证与运行参数一致）
#   make run                 # 运行算子
#   make verify              # 校验精度
#
# 改 shape 只需一处：
#   make gen run verify RUN_M=130 RUN_N=33
#
# 仿真编译（必须清缓存）：
#   rm -rf build && mkdir -p build && cd build
#   cmake -DCMAKE_ASC_RUN_MODE=sim ..
#   make -j
#   # ⚠️ "-- ASC Simulator enabled: ..." 这行是**无条件打印**的，不能当验证点。
#   #    真正的验证：find $ASCEND_HOME_PATH -name libruntime_camodel.so
#   #    运行前 export LD_LIBRARY_PATH=<找到的目录>（编译期 RPATH 不足以覆盖间接依赖）
# ---------------------------------------------------------------------------

cmake_minimum_required(VERSION 3.16)

set(CMAKE_ASC_RUN_MODE "npu" CACHE STRING "Run mode: npu, cpu, sim")
set(CMAKE_ASC_ARCHITECTURES "dav-2201" CACHE STRING "NPU architecture: dav-2201, dav-3510")

# ===========================================================================
# ★ 选择源文件（每次只编一个，改这一行即可）
# ===========================================================================
set(DEQ_SRC "dequant.asc")
# ===========================================================================

find_package(ASC REQUIRED)

project(kernel_samples LANGUAGES ASC CXX)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${DEQ_SRC}")
    message(FATAL_ERROR
        "找不到源文件 '${DEQ_SRC}'（查找目录：${CMAKE_CURRENT_SOURCE_DIR}）\n"
        "请先创建该 .asc 文件，或把上面「★ 选择源文件」改成已有的文件名。")
endif()

# 可执行文件名 = 源文件名去掉 .asc
get_filename_component(DEQ_NAME "${DEQ_SRC}" NAME_WE)

message(STATUS "==========================================================")
message(STATUS "  源文件     : ${DEQ_SRC}")
message(STATUS "  可执行文件 : ${DEQ_NAME}")
message(STATUS "  运行模式   : ${CMAKE_ASC_RUN_MODE}")
message(STATUS "  架构       : ${CMAKE_ASC_ARCHITECTURES}")
message(STATUS "==========================================================")

add_executable(${DEQ_NAME} ${DEQ_SRC})

target_compile_options(${DEQ_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:ASC>:--npu-arch=${CMAKE_ASC_ARCHITECTURES}>
    $<$<COMPILE_LANGUAGE:ASC>:-g>
)

# ---------------------------------------------------------------------------
# ★ platform_ascendc 的依赖（host 侧用 GetCoreNumAiv() 查核数）
# ---------------------------------------------------------------------------
# 本算子的 host main 需要：
#     #include "tiling/platform/platform_ascendc.h"
#     platform_ascendc::PlatformAscendCManager::GetInstance()->GetCoreNumAiv()
#
# 而 find_package(ASC) 自带的默认库只有 ascendc_runtime/ascendcl/runtime/register/...
# （见 asc-devkit/cmake/asc/asc_modules/FindASC.cmake:22-36），**不含 platform**，
# 所以这段 -I / -L / -l 不能省。
#
# 报错特征：
#   fatal error: 'tiling/platform/platform_ascendc.h' file not found      -> 缺 -I
#   undefined reference to platform_ascendc::PlatformAscendCManager::...  -> 缺 -lplatform
#
# ⚠️ 不要照抄官方 add_high_performance 的 CMakeLists —— 它没有这段，因为它的 .asc
#    根本不 include platform_ascendc.h（核数来自编译期宏 SCENARIO -> splitM）。
# ---------------------------------------------------------------------------
if(DEFINED ENV{ASCEND_HOME_PATH})
    set(ASCEND_DIR "$ENV{ASCEND_HOME_PATH}")
else()
    set(ASCEND_DIR "/usr/local/Ascend/ascend-toolkit/latest")
endif()

if(CMAKE_SYSTEM_PROCESSOR)
    set(ASCEND_LINUX_DIR "${ASCEND_DIR}/${CMAKE_SYSTEM_PROCESSOR}-linux")
else()
    set(ASCEND_LINUX_DIR "${ASCEND_DIR}/aarch64-linux")
endif()

target_include_directories(${DEQ_NAME} PRIVATE
    "${ASCEND_DIR}/asc/include"
    "${ASCEND_LINUX_DIR}/asc/include"
    "${ASCEND_DIR}/include"
    "${ASCEND_LINUX_DIR}/include"
)

target_link_directories(${DEQ_NAME} PRIVATE
    "${ASCEND_DIR}/lib64"
    "${ASCEND_LINUX_DIR}/lib64"
)

target_link_libraries(${DEQ_NAME} PRIVATE
    platform
    tiling_api
    register
    m
    dl
)

# ---------------------------------------------------------------------------
# 便捷 target：gen / run / verify
#
# 程序用相对路径读写 ./input/ 与 ./output/，所以必须在源码目录下运行；
# 用 ${CMAKE_COMMAND} -E chdir 显式切工作目录。
#
# ★ RUN_M / RUN_N 同时喂给 gen_data.py 和算子，避免"数据与运行参数不一致"这个经典坑。
# ---------------------------------------------------------------------------
set(RUN_M    "128" CACHE STRING "运行时 M（行数）")
set(RUN_N    "32"  CACHE STRING "运行时 N（通道数，= scale 长度）")
set(RUN_CORE "0"   CACHE STRING "运行时 coreNum；0 = 取平台值 GetCoreNumAiv()")

# 生成测试数据（与 run 用同一组 M/N）
add_custom_target(gen
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_SOURCE_DIR}
            python3 scripts/gen_data.py --m ${RUN_M} --n ${RUN_N}
    COMMENT "生成 input/ 与 output/golden.bin（M=${RUN_M}, N=${RUN_N}）"
)

# 运行算子
add_custom_target(run
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_SOURCE_DIR}
            $<TARGET_FILE:${DEQ_NAME}> ${RUN_M} ${RUN_N} ${RUN_CORE}
    DEPENDS ${DEQ_NAME}
    COMMENT "运行 ${DEQ_NAME} ${RUN_M} ${RUN_N} ${RUN_CORE}（工作目录 = 源码根目录）"
)

# 校验精度
add_custom_target(verify
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_SOURCE_DIR}
            python3 scripts/verify_result.py ./output/output.bin ./output/golden.bin
    COMMENT "校验 ./output/output.bin 与 ./output/golden.bin"
)
