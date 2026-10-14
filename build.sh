#!/bin/bash
# ============================================================================
# dequant_asc —— 编译 / 造数 / 运行 / 校验 / 采集
#
#   ./build.sh build [sim]                  cmake 编译（默认上板；sim = 仿真模式）
#   ./build.sh gen   M N                    生成 input/ 与 output/golden.bin
#   ./build.sh run   M N [tile] [l2] [db] [group]   运行算子 -> output/output.bin
#   ./build.sh verify                       校验 output.bin 与 golden.bin
#   ./build.sh prof  M N [tile] [l2] [db] [group] [sim]   采集性能；参数顺序同 run
#   ./build.sh clean                        删除 build/
#
# 例：
#   ./build.sh build
#   ./build.sh gen 128 32 && ./build.sh run 128 32 && ./build.sh verify
#   ./build.sh run  1024 1024 1024 0 0 1      # 【更新】group=1，验证 pitch 是否推导正确
#   ./build.sh run  1024 1024 1024 0 0 8      # 【更新】group=8，GROUP 打包
#   ./build.sh run  1024 1024 1024 0 1 0      # l2=0 db=1 group=0 -> 双缓冲
#   ./build.sh prof 1024 1024 1024 0 0 8 sim  # 仿真采集 GROUP 版
#
# 注：
#   * 【更新】第 6 个参数 group：0 = 不用 GROUP 版（默认）；>0 = 每批搬 group 行
#   * run 会自动按 build 时记录的模式（build/.mode）决定要不要设仿真库路径
#   * "ASC Simulator enabled" 那行是 cmake 无条件打印的，不能当仿真库存在与否的判据
#   * prof 会把 tile/l2/db/group 原样转发给程序（以前只转发 M N，导致双缓冲测不到）
#   * 上板 prof 带 --aic-metrics=Roofline,Default；仿真不带（用默认 PipeUtilization）
# ============================================================================
set -e
cd "$(dirname "$0")"

BIN=build/dequant
ARCH=dav-2201

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

# 仿真库真实目录：现查（cmake 硬编码的 tools/simulator/ 在部分 CANN 版本上不存在）
sim_lib() {
    local so
    so=$(find "${ASCEND_HOME_PATH:-/usr/local/Ascend}" -name libruntime_camodel.so 2>/dev/null | head -1)
    [ -n "$so" ] || die "找不到 libruntime_camodel.so，检查 CANN 安装"
    dirname "$so"
}

case "${1:-help}" in
build)
    MODE="${2:-npu}"
    [ "$MODE" = sim ] || [ "$MODE" = npu ] || die "build 的第二参数只能是 sim 或 npu"
    [ -n "$ASCEND_HOME_PATH" ] || echo "[WARN] ASCEND_HOME_PATH 为空，请先 source set_env.sh"
    # cmake 缓存会记住上次的 RUN_MODE，换了模式必须清
    if [ -f build/.mode ] && [ "$(cat build/.mode)" != "$MODE" ]; then
        info "RUN_MODE 由 $(cat build/.mode) 变为 $MODE，清掉 build/"
        rm -rf build
    fi
    cmake -S . -B build -DCMAKE_ASC_RUN_MODE="$MODE" -DCMAKE_ASC_ARCHITECTURES="$ARCH"
    cmake --build build -j
    mkdir -p build && echo "$MODE" > build/.mode
    info "产物 $BIN（模式 $MODE）"
    ;;

gen)
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh gen M N"
    python3 scripts/gen_data.py --m "$2" --n "$3"
    ;;

run)
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh run M N [tileLength] [l2_cache] [double_buffer]"
    [ -x "$BIN" ] || die "可执行文件不存在，先 ./build.sh build"
    if [ "$(cat build/.mode 2>/dev/null)" = sim ]; then
        export LD_LIBRARY_PATH="$(sim_lib):${LD_LIBRARY_PATH}"
        info "仿真模式，LD_LIBRARY_PATH 已加 $(sim_lib)"
    fi
    "./$BIN" "${@:2}"
    ;;

verify)
    [ -f output/output.bin ] || die "缺 output/output.bin，先 ./build.sh run"
    python3 scripts/verify_result.py ./output/output.bin ./output/golden.bin
    ;;

prof)
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh prof M N [tileLength] [l2_cache] [double_buffer] [sim|npu]"
    [ -x "$BIN" ] || die "可执行文件不存在，先 ./build.sh build"

    # ---- 参数解析：前 5 个和 run 完全一致，末尾可选 sim/npu ----
    #   prof M N [tile] [l2] [db] [sim]
    #   $2  $3  $4     $5   $6   $7
    #   ★ sim 放在最后：因为它和 db 都是"可选位置参数"，只能靠取值区分。
    #     约定 sim/npu 这两个字面量不会被当成 tile/l2/db 用（它们都是数字）。
    MODE=npu
    ARGS=()                                   # 转发给可执行文件的参数（不含程序名）
    for a in "${@:2}"; do
        if [ "$a" = "sim" ] || [ "$a" = "npu" ]; then
            MODE="$a"
        else
            ARGS+=("$a")
        fi
    done
    [ ${#ARGS[@]} -ge 2 ] || die "至少要给 M 和 N"

    # ★ 关键：把收到的全部位置参数原样转发给程序。
    #   原来只转发 "$2" "$3" ⇒ 后面传的 l2_cache / double_buffer 根本到不了 main，
    #   程序里 double_buffer 一直是 false ⇒ 采到的永远是基线 kernel（"以为测了其实没测"）。
    #   参考：dequant.asc 的 main 用 argv[1..5] = M N tileLength l2_cache double_buffer
    #
    # ---- 上板：--aic-metrics=Roofline,Default ----
    #     - Roofline **必须显式传**：不传 --aic-metrics 时只采 Default，Roofline 采不到
    #       （user_guide.md:128「未配置 --aic-metrics，默认采集 Default，Roofline…将无法采集」）
    #     - Roofline 与 Default **已绑定**（user_guide.md:87），所以显式带上 Default 只是
    #       把「7 项 metric CSV 照旧」写明白，不会多花采集时间
    #     - 产出：原来的 7 个 metric CSV + visualize_data.bin（Roofline/热力图/流水图都在这）
    #     - Vector 算子的 Roofline 有 4 个视图（表 5）：
    #         GM/L2 视图、Vector 内存单元视图、Vector 内存通路视图、Vector Pipeline 视图
    #   仿真：不传 --aic-metrics（默认 PipeUtilization；显式传它会关掉 ResourceConflictRatio
    #         也就是丢掉 set/wait 连线）。Roofline 是上板(msOpProf)专属，仿真侧不采集。
    #   其他可选：--aic-metrics=Memory,MemoryL0 只采某几项；
    #             --kernel-name=<mangled 名> 多 kernel 时只采一个；
    #             --replay-mode=application 保留 L2（默认 kernel 模式会清 L2 再重放）
    # 参考：msopprof/docs/zh/user_guide/msopprof_user_guide.md:87,128,318
    if [ "$MODE" = sim ]; then
        export LD_LIBRARY_PATH="$(sim_lib):${LD_LIBRARY_PATH}"
        info "仿真采集（默认 PipeUtilization；Roofline 仅上板支持）"
        info "  转发参数: ${ARGS[*]}"
        msopprof simulator --output=./sim_out "./$BIN" "${ARGS[@]}"
    else
        info "上板采集（Roofline + Default）"
        info "  转发参数: ${ARGS[*]}"
        msopprof --aic-metrics=Roofline,Default --output=./prof "./$BIN" "${ARGS[@]}"
    fi
    info "产物目录："
    ls -d ./sim_out/OPPROF_* ./prof/OPPROF_* 2>/dev/null || true
    ;;

clean)
    rm -rf build
    info "已删除 build/"
    ;;

help|*)
    # 打印文件顶部的用法注释：从第 2 行到 "set " 那一行（不含），再去掉注释符
    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//; s/^=\{5,\}$//'
    ;;
esac
