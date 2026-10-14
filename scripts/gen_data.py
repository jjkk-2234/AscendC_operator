#!/usr/bin/python3
# coding=utf-8
# ----------------------------------------------------------------------------------------------------------
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# This program is free software, you can redistribute it and/or modify it under the terms and conditions of
# CANN Open Software License Agreement Version 2.0 (the "License").
# Please refer to the License for details. You may not use this file except in compliance with the License.
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
# See LICENSE in the root of the software repository for the full text of the License.
# ----------------------------------------------------------------------------------------------------------
"""为 Per-Channel 反量化算子生成测试数据。

算子语义
--------
    y[m, n] = (float32(x[m, n]) - zero_point[n]) * scale[n]

    对称量化（默认）  : zero_point = 0  ->  y = float32(x) * scale
    非对称量化（可选）: 传 --zero-point，多一次减法

生成文件
--------
    input/input_x.bin        int32   , M*N 个元素      （裸二进制）
    input/input_scale.bin    float32 , N   个元素
    input/input_zp.bin       float32 , N   个元素      （仅 --zero-point 时生成）
    output/golden.bin        float32 , M*N 个元素
    output/shape.txt         M / N / dtype 等元信息，供 verify_result.py 读取

★ 精度对齐规则（与 kernel 一致，勿改）
--------------------------------------
    必须先转 float32 再乘：
        golden = x.astype(np.float32) * scale.astype(np.float32)
    不能"先乘整数再转" —— 那是完全不同的语义。
    kernel 侧对应：Cast(int32 -> float32, CAST_RINT) 然后 Mul。

用法示例
--------
    # 1) 官方口径：干净 shape，先验证"能算对"
    python3 scripts/gen_data.py

    # 2) 尾块 / 非对齐：N 是奇数（每行都不 32B 对齐），M 不被核数整除
    python3 scripts/gen_data.py --m 130 --n 33

    # 3) 精度边界：验证 int32 -> float32 在 2^24 附近的表现
    python3 scripts/gen_data.py --x-low -16777218 --x-high 16777218

    # 4) 非对称量化
    python3 scripts/gen_data.py --zero-point

运行算子时命令行参数必须与这里一致：
    ./build.sh run <M> <N> [tileLength] [l2] [db] [group]
    （等价于直接跑 ./build/dequant <M> <N> ...；可执行文件名来自 dequant.asc）
    ★ --m/--n 必须和 run 的前两个参数相同，否则 host 侧 ReadFile 会报"大小不符"
      并直接退出（报的是期望/实际字节数，容易误以为是数据文件坏了）。
    l2 / db / group 是三个正交开关：
      l2    非 0 = 关闭 xGm 的 L2 Cache
      db    非 0 = 启用双缓冲（x/y 各 2 份 buffer）
      group > 0 = 每批一次搬 group 行（GROUP 打包）
    ★ 建议先跑 group=1 验证 pitch/stride 推导是否正确（成本最低），再扫 group=2/4/8。
"""

import argparse
import os
import sys

import numpy as np

DEFAULT_M = 128
DEFAULT_N = 32


def parse_args():
    p = argparse.ArgumentParser(
        description="为 Per-Channel 反量化算子生成测试数据",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--m", type=int, default=DEFAULT_M, help="行数 M，默认 %d" % DEFAULT_M)
    p.add_argument("--n", type=int, default=DEFAULT_N,
                   help="通道数 N（= scale 的长度），默认 %d。取奇数可测非对齐" % DEFAULT_N)
    p.add_argument("--seed", type=int, default=0, help="随机种子（可复现），默认 0")
    p.add_argument("--x-low", type=int, default=-2048, help="int32 输入下界，默认 -2048")
    p.add_argument("--x-high", type=int, default=2047, help="int32 输入上界，默认 2047")
    p.add_argument("--scale-low", type=float, default=1e-4, help="scale 下界，默认 1e-4")
    p.add_argument("--scale-high", type=float, default=1e-2, help="scale 上界，默认 1e-2")
    p.add_argument("--zero-point", action="store_true",
                   help="生成非对称量化数据（多一个 zp[n]），默认关闭")
    p.add_argument("--out-dir", default=".", help="输出根目录，默认当前目录")
    return p.parse_args()


def main():
    args = parse_args()
    if args.m <= 0 or args.n <= 0:
        print("[ERROR] --m / --n 必须为正整数")
        return 1
    if args.x_low >= args.x_high:
        print("[ERROR] --x-low 必须小于 --x-high")
        return 1
    if args.scale_low <= 0 or args.scale_high <= args.scale_low:
        print("[ERROR] 要求 0 < --scale-low < --scale-high（scale 必须为正）")
        return 1

    rng = np.random.default_rng(args.seed)
    M, N = args.m, args.n

    # ---------------------------------------------------------------- 生成
    # int32 数据：用 randint（闭区间），范围由 --x-low/--x-high 控制
    x = rng.integers(args.x_low, args.x_high + 1, size=(M, N), dtype=np.int32)
    # scale：[N] 个正浮点，逐通道
    scale = rng.uniform(args.scale_low, args.scale_high, size=(N,)).astype(np.float32)
    # zero point：[N]，非对称量化时用
    if args.zero_point:
        zp = rng.integers(args.x_low // 4, args.x_high // 4 + 1, size=(N,)).astype(np.float32)
    else:
        zp = np.zeros((N,), dtype=np.float32)

    # ---------------------------------------------------------------- golden
    # ★ 顺序：先转 float32，再减 zp，再乘 scale（与 kernel 的 Cast -> Sub -> Mul 一致）
    xf = x.astype(np.float32)
    golden = (xf - zp[np.newaxis, :]) * scale[np.newaxis, :]
    golden = golden.astype(np.float32)

    # ---------------------------------------------------------------- 落盘
    in_dir = os.path.join(args.out_dir, "input")
    out_dir = os.path.join(args.out_dir, "output")
    os.makedirs(in_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)

    x.tofile(os.path.join(in_dir, "input_x.bin"))
    scale.tofile(os.path.join(in_dir, "input_scale.bin"))
    if args.zero_point:
        zp.tofile(os.path.join(in_dir, "input_zp.bin"))
    golden.tofile(os.path.join(out_dir, "golden.bin"))

    with open(os.path.join(out_dir, "shape.txt"), "w") as f:
        f.write("m=%d\n" % M)
        f.write("n=%d\n" % N)
        f.write("dtype=int32\n")            # 输入 x 的 dtype
        f.write("out_dtype=float32\n")      # 输出 y 的 dtype
        f.write("zero_point=%d\n" % (1 if args.zero_point else 0))

    # ---------------------------------------------------------------- 报告
    print("M=%d, N=%d, zero_point=%s, seed=%d" % (M, N, args.zero_point, args.seed))
    print("  x      : int32   [%d, %d]  %d 字节   (32B 对齐: %s)"
          % (M, N, x.nbytes, "是" if (N * 4) % 32 == 0 else "否 -> 每行都非对齐"))
    print("  scale  : float32 [%d]      %d 字节" % (N, scale.nbytes))
    print("  golden : float32 [%d, %d]  %d 字节" % (M, N, golden.nbytes))
    print("  x 实测范围 : [%d, %d]" % (x.min(), x.max()))
    print("  golden 范围: [%.6g, %.6g]" % (golden.min(), golden.max()))

    # 打印前 2 行前 6 列，便于手工核对"广播是否对"
    # 核对方法：同一行的 golden/x 应恒等于该列的 scale（逐通道语义）；
    #           不同行的**同一列**用的是同一个 scale。
    print("\n  手工核对（前 2 行 × 前 6 列）:")
    k = min(6, N)
    print("    scale[0:%d] = %s" % (k, np.array2string(scale[:k], precision=6)))
    for r in range(min(2, M)):
        print("    ---- row %d ----" % r)
        print("      x      = %s" % np.array2string(x[r, :k]))
        print("      golden = %s" % np.array2string(golden[r, :k], precision=6))
        with np.errstate(divide="ignore", invalid="ignore"):
            ratio = np.where(x[r, :k] != 0, golden[r, :k] / x[r, :k].astype(np.float32), np.nan)
        print("      golden/x = %s   <- 应等于上面的 scale（x=0 处为 nan）"
              % np.array2string(ratio, precision=6))
    print("  → 每行的 golden/x 都应等于 scale，且与其它行无关（逐通道）")

    print("\n已生成:")
    print("  %s/input_x.bin" % in_dir)
    print("  %s/input_scale.bin" % in_dir)
    if args.zero_point:
        print("  %s/input_zp.bin" % in_dir)
    print("  %s/golden.bin" % out_dir)
    print("  %s/shape.txt" % out_dir)
    print("\n下一步：./build.sh run %d %d" % (M, N))
    if args.zero_point:
        print("  ⚠️ 已生成 input_zp.bin，但当前 dequant.asc 只实现了对称量化（y = x*scale），")
        print("     尚未做 (x - zp) —— 直接验证会失败。要用请先在 kernel 里加一次 Sub。")
    # ★ 非对齐提示：verify_result.py 的归因规则里有一条"错误分布较散 ⇒ 先查非对齐路径"，
    #   这里提前告诉用户本次数据是不是非对齐用例，免得看到报错一头雾水。
    if (N * 4) % 32 != 0:
        print("  ℹ️ 本次 N=%d ⇒ 每行 %d 字节不是 32B 的倍数（非对齐用例）。" % (N, N * 4))
        print("     这是**故意**的：用于覆盖 DataCopyPad 的尾块/补齐路径。")
        print("     若结果错误，优先查行步长 pitch 是否按 (actualTileLength*4+31)/32*32 算的。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
