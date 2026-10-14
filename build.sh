#!/bin/bash
# ============================================================================
# dequant_asc —— 编译 / 造数 / 运行 / 校验 / 采集
#
#   ./build.sh build [sim]                  cmake 编译（默认上板；sim = 仿真模式）
#   ./build.sh gen   M N                    生成 input/ 与 output/golden.bin
#   ./build.sh run   M N [tile] [l2] [db] [group]   运行算子 -> output/output.bin
#   ./build.sh verify                       校验 output.bin 与 golden.bin
#   ./build.sh prof  M N [tile] [l2] [db] [group] [sim]   采集性能；参数顺序同 run
#   ./build.sh san   M N [tile] [l2] [db] [group] [tools]  msSanitizer 内存/同步检测
#   ./build.sh clean                        删除 build/（不动 build-san/）
#
# 例：
#   ./build.sh build
#   ./build.sh gen 128 32 && ./build.sh run 128 32 && ./build.sh verify
#   ./build.sh run  1024 1024 1024 0 0 0      # baseline
#   ./build.sh run  1024 1024 1024 0 1 0      # 双缓冲（l2=0 db=1 group=0）
#   ./build.sh run  1024 1024 1024 0 0 1      # group=1，验证 pitch/stride 推导是否正确
#   ./build.sh run  1024 1024 1024 0 0 8      # group=8，GROUP 打包
#   ./build.sh run  1024 1024 1024 0 1 8      # group+双缓冲（推荐组合）
#   ./build.sh run  1024 1024 1024 1 1 8      # ★ 上面基础上 + 关闭 x 的 L2 Cache
#   ./build.sh prof 8175 7775 2048 0 1 8      # 采集 group+db
#   ./build.sh prof 8175 7775 2048 1 1 8      # 采集 group+db+L2 优化（对比上一行）
#   ./build.sh san  8175 7775 2048 0 1 8      # ★ msSanitizer 检测（独立 build-san/，不影响 build/）
#   ./build.sh san  8175 7775 2048 0 1 8 memcheck,initcheck   # 指定子工具
#
# 注：
#   * 【更新】第 4 个参数 l2：0 = x 正常走 L2（默认）；**非 0 = 关闭 xGm 的 L2 Cache**
#       （语义已变：原来是"选一个空壳 kernel"，现在是 L2 优化开关，对所有模式生效）
#   * 【更新】第 6 个参数 group：0 = 不用 GROUP 版（默认）；>0 = 每批搬 group 行
#   * run 会自动按 build 时记录的模式（build/.mode）决定要不要设仿真库路径
#   * "ASC Simulator enabled" 那行是 cmake 无条件打印的，不能当仿真库存在与否的判据
#   * prof 会把 tile/l2/db/group 原样转发给程序（以前只转发 M N，导致双缓冲测不到）
#   * 上板 prof 带 --aic-metrics=Roofline,Default；仿真不带（用默认 PipeUtilization）
#   * 【更新】san 用**独立目录 build-san/**，所以开/关 sanitizer 都不需要清缓存，
#       也不会污染 build/。代价是首次要单独编一次（之后增量）。
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
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh run M N [tileLength] [l2] [db] [group]"
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
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh prof M N [tileLength] [l2] [db] [group] [sim|npu]"
    [ -x "$BIN" ] || die "可执行文件不存在，先 ./build.sh build"

    # ---- 参数解析：前 6 个和 run 完全一致，末尾可选 sim/npu ----
    #   prof M N [tile] [l2] [db] [group] [sim]
    #   $2  $3  $4     $5   $6   $7      $8
    #   ★ sim 放在最后：因为它和数字参数都是"可选位置参数"，只能靠取值区分。
    #     sim/npu 是字面量、其它参数都是数字 ⇒ 从任意位置都能识别，
    #     但**约定写在最后**才不会和 group 混淆。
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
    #   原来只转发 "$2" "$3" ⇒ 后面传的 l2 / double_buffer / group 根本到不了 main，
    #   程序里它们一直是默认值（0）⇒ 采到的永远是基线 kernel（"以为测了其实没测"）。
    #   参考：dequant.asc 的 main 用 argv[1..6] = M N tileLength l2 db group
    #   脚本打印 [INFO] 转发参数: ...，程序打印 [MODE] ...，两者互为印证。
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

san)
    # ------------------------------------------------------------------
    # msSanitizer 检测（独立目录 build-san/，不影响 build/）
    #
    # 设计要点：
    #   ① 默认 OFF：ENABLE_SANITIZER 是 CMake 缓存变量，**平时编译完全不传它** ⇒ 零影响。
    #      只有走到这个分支才 -DENABLE_SANITIZER=ON。
    #   ② **独立 build 目录**：这是"不想每次都开"的关键 ——
    #      如果复用 build/，开关一变就得 rm -rf 清缓存（否则 cmake 缓存里 RUN_MODE/
    #      编译选项混在一起，很容易"以为开了其实跑的旧的"）。
    #      独立目录 ⇒ 一次配置长期共存，开关切换零成本，只是多占一点磁盘。
    #   ③ sanitizer 不能用 -O0（ai_core_operator_compilation.md:114），
    #      CMakeLists 里已兜底把 CMAKE_BUILD_TYPE 设成 RelWithDebInfo。
    #   ④ ⚠️ 开 sanitizer 后 GlobalTensor 强制走 L2，SetL2CacheHint 失效
    #      ⇒ 这个二进制**不能用来测 l2=1 的收益**，只用来查内存/同步问题。
    # ------------------------------------------------------------------
    [ -n "$2" ] && [ -n "$3" ] || die "用法: ./build.sh san M N [tile] [l2] [db] [group] [tools]"
    SAN_DIR=build-san
    SAN_BIN="$SAN_DIR/dequant"

    # 参数：前 6 个同 run；末尾可选一个子工具列表（含字母即视为工具名）
    MODE=npu
    SAN_TOOLS=memcheck
    ARGS=()
    for a in "${@:2}"; do
        case "$a" in
            *[!0-9]*)  SAN_TOOLS="$a" ;;    # 含非数字 ⇒ 当成子工具列表
            *)         ARGS+=("$a") ;;
        esac
    done
    [ ${#ARGS[@]} -ge 2 ] || die "至少要给 M 和 N"

    # 首次配置时才 configure；之后靠 cmake 增量（改 CMakeLists 会自动重新 configure）
    if [ ! -f "$SAN_DIR/CMakeCache.txt" ]; then
        info "首次配置 $SAN_DIR（ENABLE_SANITIZER=ON）"
        cmake -S . -B "$SAN_DIR" -DCMAKE_ASC_RUN_MODE="$MODE" \
              -DCMAKE_ASC_ARCHITECTURES="$ARCH" -DENABLE_SANITIZER=ON
    fi
    cmake --build "$SAN_DIR" -j
    [ -x "$SAN_BIN" ] || die "编译产物不存在：$SAN_BIN"

    info "msSanitizer --tool=$SAN_TOOLS"
    info "  程序参数: ${ARGS[*]}"
    info "  ⚠️ 此二进制 GlobalTensor 强制走 L2，SetL2CacheHint 失效（不能用来测 l2=1 的收益）"
    mssanitizer "--tool=$SAN_TOOLS" "./$SAN_BIN" "${ARGS[@]}"
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
