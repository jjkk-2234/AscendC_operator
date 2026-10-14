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
"""校验 Per-Channel 反量化算子的输出。

shape / dtype 从 golden 同目录的 shape.txt 读取（由 gen_data.py 写入）。

用法
----
    python3 scripts/verify_result.py ./output/output.bin ./output/golden.bin
    python3 scripts/verify_result.py a.bin b.bin --strict          # 不允许任何不一致元素
    python3 scripts/verify_result.py a.bin b.bin --rtol 1e-5 --atol 1e-5
    python3 scripts/verify_result.py a.bin b.bin --max-print 5

失败时会额外给出"错在哪"的提示：
  * 错误集中在少数几列   -> 大概率 scale 的**通道索引**错了
  * 错误铺满所有行同列   -> 广播没生效（每行没有复用同一份 scale）
  * 错误集中在少数几行   -> 分核/尾块的**行边界**错了
  * 整片偏移 1 个元素    -> 搬运的长度或起始地址错了
"""

import argparse
import os
import sys

import numpy as np

DEFAULT_RTOL = 1e-6
DEFAULT_ATOL = 1e-5
DEFAULT_ERROR_TOL = 1e-4     # 允许不一致元素的比例（--strict 时忽略）


def read_meta(path):
    """从 shape.txt 读取 m / n / dtype 等元信息"""
    meta = {}
    if not os.path.isfile(path):
        return meta
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                meta[k.strip()] = v.strip()
    return meta


def load(path, dtype, expect_elems, tag):
    a = np.fromfile(path, dtype=dtype)
    if expect_elems is not None and a.size != expect_elems:
        print("[ERROR] %s 元素个数不一致：%s 有 %d 个，期望 %d 个"
              % (tag, path, a.size, expect_elems))
        print("        常见原因：output.bin 是上一次实验的残留，或 --m/--n 与运行时参数不一致")
        return None
    return a


def main():
    ap = argparse.ArgumentParser(description="校验 Per-Channel 反量化输出")
    ap.add_argument("actual", help="算子输出 output.bin")
    ap.add_argument("golden", help="参考结果 golden.bin")
    ap.add_argument("--rtol", type=float, default=DEFAULT_RTOL, help="相对容差")
    ap.add_argument("--atol", type=float, default=DEFAULT_ATOL, help="绝对容差")
    ap.add_argument("--strict", action="store_true", help="不允许任何不一致元素")
    ap.add_argument("--max-print", type=int, default=10, help="最多打印几个不一致元素")
    ap.add_argument("--m", type=int, default=None, help="显式指定 M（默认从 shape.txt 读）")
    ap.add_argument("--n", type=int, default=None, help="显式指定 N（默认从 shape.txt 读）")
    args = ap.parse_args()

    meta = read_meta(os.path.join(os.path.dirname(os.path.abspath(args.golden)), "shape.txt"))
    m = args.m if args.m is not None else int(meta.get("m", 0))
    n = args.n if args.n is not None else int(meta.get("n", 0))
    out_dtype = meta.get("out_dtype", "float32")
    dt = np.float16 if out_dtype in ("float16", "half") else np.float32

    if m <= 0 or n <= 0:
        print("[ERROR] 无法确定 M/N。请确认 golden 同目录下有 shape.txt，或用 --m/--n 显式指定")
        return 1

    print("-" * 64)
    print("M, N       : %d, %d      (共 %d 个元素)" % (m, n, m * n))
    print("输出 dtype : %s" % out_dtype)
    print("容差       : rtol=%g, atol=%g%s" % (args.rtol, args.atol, "  [strict]" if args.strict else ""))

    act = load(args.actual, dt, m * n, "output")
    ref = load(args.golden, dt, m * n, "golden")
    if act is None or ref is None:
        return 1

    # ------------------------------------------------------------------ 比对
    act64 = act.astype(np.float64)
    ref64 = ref.astype(np.float64)
    abs_diff = np.abs(act64 - ref64)
    denom = np.maximum(np.abs(act64), np.abs(ref64))
    with np.errstate(divide="ignore", invalid="ignore"):
        rel_diff = np.where(denom > 0, abs_diff / denom, 0.0)

    is_close = (abs_diff <= args.atol) | (rel_diff <= args.rtol)
    both_nan = np.isnan(act64) & np.isnan(ref64)
    is_close = is_close | both_nan
    bad = ~is_close
    err_num = int(bad.sum())

    print("max abs diff: %.6g" % float(abs_diff[~np.isnan(abs_diff)].max(initial=0.0)))
    print("max rel diff: %.6g" % float(np.nanmax(rel_diff, initial=0.0)))
    print("不一致元素  : %d / %d  (%.6f%%)" % (err_num, m * n, 100.0 * err_num / (m * n)))

    if err_num > 0:
        # 打印前几个
        idx = np.argwhere(bad).reshape(-1)[:args.max_print]
        print("\n前 %d 个不一致元素：" % len(idx))
        for k in idx:
            r, c = divmod(int(k), n)
            print("  idx=%-8d (%4d, %4d)  actual=%-14.7g golden=%-14.7g rdiff=%.3g"
                  % (k, r, c, act64[k], ref64[k], rel_diff[k]))

        # ------------------------------------------------------------- 归因提示
        bad2d = bad.reshape(m, n)
        col_cnt = bad2d.sum(axis=0)
        row_cnt = bad2d.sum(axis=1)
        nz_cols = int((col_cnt > 0).sum())
        nz_rows = int((row_cnt > 0).sum())
        print("\n错误分布：涉及 %d/%d 列, %d/%d 行" % (nz_cols, n, nz_rows, m))
        if nz_cols <= max(1, n // 10) and nz_rows > m // 2:
            print("  → 错误集中在少数列且铺满所有行：**scale 的通道索引可能错了**")
        elif nz_rows <= max(1, m // 10):
            print("  → 错误集中在少数行：**分核 / 尾块的行边界可能错了**")
        elif nz_cols == n and nz_rows == m:
            print("  → 全片都错：**广播可能没生效**（每行没有复用同一份 scale），"
                  "或搬运长度 / 起始地址错了")
        else:
            print("  → 分布较散：先查非对齐路径（N 不是 8 的倍数时必须用 DataCopyPad）")

    # ------------------------------------------------------------------ 判定
    if args.strict:
        ok = (err_num == 0)
    else:
        ok = (err_num <= (m * n) * DEFAULT_ERROR_TOL)

    print("-" * 64)
    if ok:
        print("test pass!")
        return 0
    print("[ERROR] result error")
    return 1


if __name__ == "__main__":
    sys.exit(main())
