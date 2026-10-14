# Per-Channel 反量化（Dequant）算子 —— 算法说明

> 目录：`tilelang算子开发/dequant_asc/`
> 目标：给"自己实现一版 Per-Channel 反量化"提供算法依据与设计边界
> 参考官方样例：`asc-devkit/examples/01_simd_cpp_api/04_advanced_api/03_quantization/dequant/`

---

## 🚀 快速上手（build.sh）

> 所有命令都在 `dequant_asc/` 目录下执行。首次使用先加执行权限。

```bash
cd tilelang算子开发/dequant_asc
chmod +x build.sh
./build.sh help          # 打印全部子命令
```

### 六个子命令

| 命令                                    | 作用                                          | 备注                             |
| ------------------------------------- | ------------------------------------------- | ------------------------------ |
| `./build.sh build [sim]`              | **cmake 编译**                                | 不带参数=上板；带 `sim`=仿真             |
| `./build.sh gen M N`                  | **生成测试数据** → `input/` + `output/golden.bin` | `M N` 必须与 `run` 一致             |
| `./build.sh run M N [tile] [l2] [db]` | 跑算子 → `output/output.bin`                   | 后三个可选，对应 host 的第 3/4/5 个参数     |
| `./build.sh verify`                   | **校验精度**                                    | 比对 `output.bin` 与 `golden.bin` |
| `./build.sh prof M N [sim] [kernel]`  | **采集性能数据**                                  | `kernel` 默认 `dequant_custom`   |
| `./build.sh clean`                    | 删除 `build/`                                 |                                |

### ① 上板：编译 → 造数 → 跑 → 校验

```bash
./build.sh build                     # cmake 上板编译（RUN_MODE=npu）
./build.sh gen   128 32              # 造 128×32 的数据
./build.sh run   128 32              # 跑算子
./build.sh verify                    # 期望输出 test pass!
```

一条龙（`&&` 串联，任一步失败就停）：

```bash
./build.sh build && ./build.sh gen 128 32 && ./build.sh run 128 32 && ./build.sh verify
```

### ② 仿真：编译 → 跑 → 校验（不需要 NPU 卡）

```bash
./build.sh build sim                 # RUN_MODE=sim（脚本会自动清掉旧 build）
./build.sh gen   128 32
./build.sh run   128 32              # 脚本自动 export LD_LIBRARY_PATH
./build.sh verify
```

### ③ 采集性能数据

```bash
./build.sh prof 128 32            # 上板：msopprof（Roofline + Default）
./build.sh prof 128 32 sim        # 仿真：msopprof simulator（默认 PipeUtilization）
```

| 模式 | 脚本实际传的 `--aic-metrics` | 产出 |
|---|---|---|
| **上板** | **`Roofline,Default`** | 7 个 metric CSV **+ `visualize_data.bin`**（Roofline / 热力图 / 流水图都在里面） |
| **仿真** | 不传（用默认） | `PipeUtilization`（且**不关闭** `ResourceConflictRatio`，保留 set/wait 连线） |

#### Roofline 为什么要显式传

| 结论 | 出处 |
|---|---|
| **不传 `--aic-metrics` 时，Roofline / KernelScale / TimelineDetail / Occupancy 都采不到**（默认只采 `Default`） | [user_guide.md:128](<msopprof/docs/zh/user_guide/msopprof_user_guide.md#L128>) |
| **Roofline 与 Default 已绑定**，使能 Roofline 即同时启用 Roofline 和 Default 模式 | [user_guide.md:87](<msopprof/docs/zh/user_guide/msopprof_user_guide.md#L87>) |
| Roofline 是**上板（msOpProf）专属**，仿真指南里只有 `visualize_data.bin`、无 Roofline | [msopprof_simulator_user_guide.md:387](<msopprof/docs/zh/user_guide/msopprof_simulator_user_guide.md#L387>) |

因为已绑定，所以写 `Roofline,Default` 只是把"7 项 CSV 照旧"写明白，**不会多花采集时间**。

#### dequant 能拿到哪几个 Roofline 视图（Vector 算子）

| 视图类型 | Vector 算子 |
|---|---|
| GM/L2 视图 | ✅ |
| **Vector 内存单元视图** | ✅ |
| **Vector 内存通路视图** | ✅ |
| **Vector Pipeline 视图** | ✅ |
| Cube 内存单元 / 通路 / Pipeline 视图 | ✗（Cube 算子才有） |

> 出处：[表 5 Atlas A2/A3 支持 Roofline 视图情况列表](<msopprof/docs/zh/user_guide/msopprof_user_guide.md#L347>)
> （910B3 = Atlas A2 系列；`OpBasicInfo.csv` 里 `Op Type=vector` 已确认本算子是 Vector 算子）

**怎么看**：把 `visualize_data.bin` 导入 **MindStudio Insight** → 详情（Details）→ Roofline。
横轴是计算强度、纵轴是性能，**屋顶线**是理论上限，**实际坐标点离屋顶线的距离就是可优化空间** ——
它直接回答"这个算子到底受限于带宽还是受限于算力"。

#### 别踩的坑

⚠️ **别传 `--aic-metrics=PipeUtilization`** —— 那会把采集**限制成单一指标**（上板就只剩 `OpBasicInfo.csv` + `PipeUtilization.csv` 两个文件）；仿真下它还会**关掉** `ResourceConflictRatio`，丢掉 set/wait 连线。

需要时自己加：

```bash
--aic-metrics=Roofline,Memory,MemoryL0   # Roofline + 只要某几项
--aic-metrics=Memory,MemoryL0            # 不要 Roofline 时（逗号分隔）
--kernel-name=<mangled 名>               # 多 kernel 时只采一个（nm 取）
--replay-mode=application                # 保留 L2（默认 kernel 模式会清 L2 再重放）
```

采集产物：

```
prof/OPPROF_<时间戳>_<串>/
└── device0/...
    ├── OpBasicInfo.csv          ← 算子基础信息（Block Dim、Task Duration、Op Type）
    ├── PipeUtilization.csv      ← 各流水线耗时/占比（最常看）
    ├── Memory.csv               ← 主存/UB 读写带宽与实际搬运量
    ├── ...（共 7 个 metric CSV）
    └── visualize_data.bin       ← ★ 导入 MindStudio Insight 看 Roofline / 热力图 / 流水图
```

**先看 `OpBasicInfo.csv` 的 `Task Duration(us)`（端到端），再看 `PipeUtilization.csv` 的这几列**：
`aiv_mte2_time(us)`、`aiv_mte3_time(us)`、`aiv_vec_time(us)`、`aiv_scalar_time(us)`、`aiv_mte2_active_bw(GB/s)`；
最后算一次 **`Σ(各流水线) / aiv_time`**（≈1.0 = 串行 / **>1.2 才有重叠**）。

### 脚本帮你处理掉的 3 个坑

| 坑 | 脚本怎么处理 |
|---|---|
| **换 RUN_MODE 后 cmake 缓存作祟** | 用 `build/.mode` 记录，模式变了自动 `rm -rf build` 再 configure |
| **仿真库路径不对**（cmake 里硬编码 `tools/simulator/`，部分 CANN 版本实际在 `<arch>-linux/simulator/`） | `run`/`prof` 用 `find` 现查 `libruntime_camodel.so` 并 export `LD_LIBRARY_PATH` |
| **`run` 忘了设仿真库路径** | `run` 读 `build/.mode`，自动判断要不要加 |

### 三个必须知道的注意点

**1. `M N` 两处必须一致**
`gen M N` 与 `run M N` 的数字要相同。不一致时 host 侧 `ReadFile` 会直接报错退出：

```
[ERROR] 读取 ./input/input_x.bin 失败或大小不符：期望 16384 字节，实际 4194304 字节
```

**2. `tileLength` 有硬约束**（host 里已校验并会报错退出）

| 约束 | 原因 |
|---|---|
| 必须是 **8 的倍数**（`tileLength*4 % 32 == 0`） | `LocalMemAllocator` 的 bump 分配**不做 32B 取整**，长度不对齐会让后面所有 tensor 起点错位，`DataCopyPad` 直接违规 |
| `4 个 buffer × 4B × tileLength ≤ UB` | A2/A3 的 UB = 192 KB ⇒ `tileLength ≤ 12288`（运行时用 `GetCoreMemSize` 查，不硬编码） |

**3. `prof` 要独占卡**
别人在跑会污染 L2 与带宽，采到的数不可用。另外：**仿真与上板的核数不同**（本机实测：上板 `GetCoreNumAiv()`=40、仿真=48），
所以**两边的性能数据不能直接横比**；本算子的 host 目前还没开放 `coreNum` 命令行参数（`run` 的 `tile/l2/db` 是它的第 3/4/5 个参数）。

---

## 一、这个算子解决什么问题

### 1.1 为什么要反量化

量化推理里，**计算用整数（int8/int16/int32），累加用 int32**，但最终结果要变回浮点。原因：

| 环节 | 做法 | 为什么 |
|---|---|---|
| 存/传 | `int8`（1 字节） | 省带宽、省显存 |
| 算 | `int8 × int8 → int32` 累加 | 整数乘法快、无精度漂移（int32 累加不丢位） |
| **出** | **反量化回 float** | 后续算子要浮点 |

所以反量化（dequant）就是**量化（quant）的逆运算**，作用是**把"整数域的结果"映射回"浮点域"**。

### 1.2 量化与反量化的数学关系

给定一个浮点张量 $x$ 和缩放因子 $s > 0$：

$$
\underbrace{x_q = \text{round}\!\left(\frac{x}{s}\right)}_{\text{量化}}\qquad
\underbrace{\hat{x} = x_q \cdot s}_{\text{反量化}}
$$

**关键点**：量化是**有损**的（round 引入误差），而反量化是**无损**的（纯乘加）。所以

$$
\hat{x} \ne x \quad\text{但}\quad \text{dequant}(\text{quant}(x)) = \hat{x}\ \text{是确定值}
$$

⇒ **反量化的 golden 唯一确定，不存在"允许多大误差"的设计自由度**（除了浮点本身的舍入）。

---

## 二、三种粒度：per-tensor / per-channel / per-group

这是本算子的**核心概念**。"粒度"决定 $s$ 有几个、怎么映射到张量元素上。

### 2.1 数学定义

设输入 $x_q \in \mathbb{Z}^{M \times N}$（`int32`，$M$ 行 $N$ 列）：

| 粒度 | 公式 | $s$ 的形状 | 含义 |
|---|---|---|---|
| **Per-Tensor** | $\hat{x}_{m,n} = x_{m,n}\cdot s$ | **标量** | 整个张量共用一个 $s$ |
| **Per-Channel** | $\hat{x}_{m,n} = x_{m,n}\cdot s_{n}$ | **$[N]$** | **每一列（通道）一个 $s$** |
| **Per-Group** | $\hat{x}_{m,n} = x_{m,n}\cdot s_{g},\; g=\lfloor n/G \rfloor$ | $[\lceil N/G\rceil]$ | 每 $G$ 个通道一组共用一个 $s$ |

**本算子做的是 Per-Channel**（$s$ 沿 **最后一维 N**，即"输出通道"方向）。

### 2.2 为什么 per-channel 更常见

不同通道的数值分布差异很大（比如某个卷积核的权重范围是 $10^{-3}$，另一个是 $10^{-1}$）。

- **per-tensor**：$s$ 要覆盖全体 ⇒ 小通道被"压扁"⇒ 量化误差大
- **per-channel**：每个通道用自己的 $s$ ⇒ **动态范围利用率高、精度好**，代价只是多存 $N$ 个浮点数

### 2.3 对称 / 非对称

| 类型                  | 公式                            | $s$ 计算                                   | offset               |               |            |
| ------------------- | ----------------------------- | ---------------------------------------- | -------------------- | ------------- | ---------- |
| **对称**（symmetric）   | $\hat{x} = x_q \cdot s$       | $s = \dfrac{\max                         | x                    | }{2^{b-1}-1}$ | 无（隐含零点为 0） |
| **非对称**（asymmetric） | $\hat{x} = (x_q - z) \cdot s$ | $s = \dfrac{x_{\max}-x_{\min}}{2^{b}-1}$ | $z$ = 零点（zero point） |               |            |

**官方样例是"对称 + 无 offset"**（[dequant.asc:139](../../asc-devkit/examples/01_simd_cpp_api/04_advanced_api/03_quantization/dequant/dequant.asc) 里 `DequantizeConfig{PER_CHANNEL, false, 1}`，第二个字段 `hasOffset = false`）。

> **设计选择**：建议**两版都做**——
> - 对称版：`y = x * scale` （简单，先跑通）
> - 非对称版：`y = (x - zp) * scale` （多一个 `Sub`，多一个广播张量，**更接近真实算子**）

---

## 三、广播语义（本算子的难点所在）

### 3.1 形状推导

```
输入  x_q    : [M, N]        int32
参数  scale  : [1, N]        float32
输出  y      : [M, N]        float32
```

`scale` 的 `[N]` 要"扩展"到 `[M, N]`，即**每一行都用同一份 $s$**：

$$
\hat{x}_{m,n} = x_{m,n}\cdot s_{0,n}\qquad \forall m \in [0,M),\ n\in[0,N)
$$

**下标映射**（这是"广播"的形式化定义）：

$$
\text{out}[i_0,\dots,i_{k-1}] = f\bigl(\text{inA}[\text{mapA}(\vec{i})],\ \text{inB}[\text{mapB}(\vec{i})]\bigr),\qquad
\text{mapB}(m,n) = (0,\ n)
$$

### 3.2 广播还是"逐元素"吗？

**判据不是形状，而是"输出元素之间有没有依赖"**：

| 类别 | 下标关系 | 依赖 | data-parallel |
|---|---|---|---|
| 纯逐元素 | `out[i] = f(a[i], b[i])` | 无 | ✅ |
| **广播** | `out[i] = f(a[map_a(i)], b[map_b(i)])` | **无** | ✅ **仍然是** |
| Reduce/Scan | `out[i]` 依赖其它 `out[j]` | **有** | ❌ |

⇒ **Per-Channel Dequant 是"逐元素 + 输入下标映射"**：
- **并行性上**：每个输出独立 ⇒ 可以纯数据并行（和 add 一样好切核）
- **访存上**：**不再是 1:1** ⇒ 这才是要和 add 区别对待的地方（见 §5）

（框架口径也把它归为 elementwise：PyTorch 的 `TensorIterator` 就是统一处理 elementwise + broadcast 的。）

### 3.3 广播在 UB 里怎么落地（两种策略）

要算 `Mul`，两个操作数的**布局必须一致**。可行的做法：

| 策略 | 做法 | UB 开销 | 评价 |
|---|---|---|---|
| **A. 物理广播** | 把 `scale[N]` 在 UB 里**复制 M 份**，得到 `[M,N]` | $M\cdot N \cdot 4$ B | ❌ 与 x 同量级，白吃 UB |
| **B. 分块复用（推荐）** | 按行/按块处理，每块只取对应的 $s$ 段 | 只要 $N\cdot 4$ B | ✅ **常驻 + 复用** |
| **C. 硬件广播读** | 用 `DataCopyExtParams{blockCount=M, srcStride=?}` 在**搬运时就重复读**同一段 GM | $M\cdot N\cdot 4$ B | ⚠️ 省了 UB 内复制，但 UB 仍占满 |

**结论：选 B。** `scale` 全流程**只从 GM 搬一次**、常驻 UB，之后每行复用。
这正好是"广播算子"的通用优化手法：**把"重复读"变成"读一次 + 常驻"**。

---

## 四、数据类型与精度

### 4.1 输入输出组合

| 输入 | 输出 | 说明 |
|---|---|---|
| **int32** | **float32** | 官方样例的组合，**最直接**（`Cast` 一次到位） |
| int32 | float16 | ⚠️ **需要两步**：int32 → float32 → float16（精度/指令支持都要确认） |
| int8 / int16 | float16 | 常见真实场景，但**本目录先按官方口径做 int32** |
| int32 | bfloat16 | 同上，两步转 |

**建议第一步只做 `int32 → float32`**（官方口径），把广播、尾块、流水跑通，再扩 dtype。

### 4.2 精度陷阱

| 陷阱 | 说明 |
|---|---|
| **int32 → float32 不是无损** | int32 有 31 位有效位，float32 尾数只有 24 位 ⇒ **大整数会丢低位**。若 $x_q$ 超过 $2^{24}$，`Cast` 就丢精度 |
| **fp16 输出要小心** | $x_q \cdot s$ 若超出 fp16 范围（65504）⇒ inf |
| **累加顺序** | 本算子没有累加 ⇒ **无累加误差**。这是它比 reduce 类算子"好写"的地方 |
| **NaN/Inf 传播** | scale 为 0/NaN 时结果如何？**对齐 PyTorch 即可**（`0 * inf = nan`） |

**结论**：本算子的精度风险**只有一处** —— `Cast(int32→float32)` 的位宽丢失。golden 用同样的 float32 计算即可规避（见 §8）。

---

## 五、访存分析（决定性能特征）

### 5.1 数据量

| 方向 | 数据量 | 流水 |
|---|---|---|
| 读 | $M\cdot N\cdot 4$ B（x_q，int32） | MTE2 |
| 读 | $N\cdot 4$ B（scale，**只一次**） | MTE2（可忽略） |
| 写 | $M\cdot N\cdot \text{sizeof(dst)}$ B（y） | MTE3 |

**读:写 比值**：

| 输出类型 | 读:写 | 对比 add |
|---|---|---|
| **float32** | **1 : 1** | ← **和 add 的 2:1 不同** |
| float16 | **2 : 1** | 同 add |

> ★ **这是本算子最值得观察的一点**：
> - 出 float32 时 `T_MTE2 : T_MTE3 ≈ 1:1`（甚至因为写更贵而 **MTE3 反而更长**）
> - 出 float16 时回到 2:1
>
> **同一个算子、只换输出 dtype，瓶颈结构就翻转** —— 这是"为什么要做这个算子"的最好理由（你在 add 里看到的是稳定的 2:1）。

### 5.2 与 add 的定位对比

| | add | **per-channel dequant** |
|---|---|---|
| 输入个数 | 2（同 shape） | 1 + 1 广播参数 |
| 访存比（读:写） | **2:1** | **1:1**（出 fp32） |
| 广播 | 无 | **有（最后一维）** |
| 类型转换 | 无 | **有（Cast）** |
| 算术强度 | 极低（1 次加法） | 低（1 次乘 + 1 次转） |
| 瓶颈 | MTE2 | **待测**（预期 MTE2/MTE3 接近） |

### 5.3 算术强度估算

每字节的运算量：

$$
\text{intensity} = \frac{M\cdot N \times (\text{1 Cast} + \text{1 Mul})}{M\cdot N\times(4+4)}
= \frac{2\ \text{ops}}{8\ \text{B}} = 0.25\ \text{ops/B}
$$

⇒ **必然是 memory-bound**（Vector 单元远吃不满），所以**所有优化都应该投向搬运**，而不是计算。

---

## 六、算法分解为逐元素 API 链

把 §2.3 的公式拆成 AscendC 基础 API：

```cpp
// 目标：dst[m,n] = float32(src[m,n]) * scale[n]

// 1) 类型转换（逐元素）
Cast(dstFp32Tile, srcInt32Tile, RoundMode::CAST_NONE, tileElems);

// 2) 乘法（逐元素，第二操作数需要已经是广播后的布局）
Mul(dstFp32Tile, dstFp32Tile, scaleBroadcastTile, tileElems);

// —— 非对称版再多一步 ——
// Sub(tmpTile, srcFp32Tile, zeroPointTile, tileElems);   // 或先 Sub 后 Mul
```

### 6.1 API 清单（本算子会用到）

| API | 作用 | 备注 |
|---|---|---|
| `DataCopy` / `DataCopyPad` | GM ↔ UB | 尾块/非对齐必须用 `DataCopyPad` |
| `Cast` | int32 → float32 | 有舍入模式参数 |
| `Mul` | 逐元素乘 | 两操作数布局必须一致 |
| `Sub` | 逐元素减 | 仅非对称版需要 |
| `Duplicate` | 标量填充 | 构造全 0 offset（官方样例用它造 offset） |
| `Brcb` / `Copy` 的 stride 模式 | **构造广播布局** | ⚠️ 语义需查各自 README 后定 |

### 6.2 广播落地：三种实现路线（按推荐度）

| 路线 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **① 按行循环** | 外层循环 M 行，每行 `Mul(row, row, scaleTile)` | scale 只占 $N\cdot4$ B；逻辑最直白 | 行数多时标量开销大（每行一次 Mul 的 repeat 开销） |
| **② 块内重复构造** | 把 `scale` 在 UB 内按块重复到与 tile 同高，再一次 `Mul` | 一次 Mul 算完，指令少 | 需要重复构造的机制（`Brcb`/`Copy` stride），UB 多占 |
| **③ 搬运期广播** | `DataCopyExtParams` 用 `blockCount=M` + 重复读同一段 GM | 少一步 UB 内构造 | ⚠️ 需验证 stride 语义；UB 仍占满 |

**建议**：**先做 ①**（最短路径跑通精度），再用 profiling 判断"标量开销是否成为瓶颈"，需要时换 ②。

---

## 七、分核、尾块与非对齐

### 7.1 分核策略（切 M 行）

```
M 行按核数均分：
  baseRows  = M / coreNum
  remainder = M % coreNum          ← 前 remainder 个核多分 1 行
  startRow(blockIdx) = blockIdx*baseRows + min(blockIdx, remainder)
  rows(blockIdx)     = baseRows + (blockIdx < remainder ? 1 : 0)
```

**为什么不切 N**：`scale` 沿 N 分布，切 N 会让每个核拿到不完整的 scale 段 ⇒ 广播边界变复杂。**切 M 时 scale 全量可见，零成本**。

### 7.2 尾块

三种尾块要分清楚（**这是最容易错的地方**）：

| 尾块来源 | 现象 | 处理 |
|---|---|---|
| **行尾块** | M 不被 coreNum 整除 ⇒ 有的核少几行 | 上面公式已覆盖 |
| **列尾块** | N 不是 32B/sizeof 的整数倍 ⇒ 一行不足整除 | `DataCopyPad` + 列尾单独处理 |
| **整块尾块** | 一个核内的 tile 数 × tileRows ≠ rows | 最后一个 tile 用 `Min()` 收缩 |

**对齐换算**（float32 下 32B = **8 个元素**）：

```
N 对齐长度 = ceil(N / 8) * 8
若 N != 对齐长度 ⇒ 必须 DataCopyPad，且 Mul 的元素数只能用真实 N（多算的部分是脏数据）
```

### 7.3 为什么本算子"天生有非对齐"

赛题/官方样例都强调这点。原因：**N 是"通道数"，工程上常取 3/5/7/64/96/128…**，其中奇数通道（如 3、5、7）会让每行字节数不是 32B 的整数倍 ⇒ **每一行都非对齐**，不只是最后一块。

---

## 八、参考实现（Golden）

### 8.1 PyTorch 侧

```python
import torch

def dequant_per_channel(x_int32: torch.Tensor,   # [M, N] int32
                        scale: torch.Tensor,      # [N] or [1, N] float32
                        zero_point=None) -> torch.Tensor:
    x = x_int32.to(torch.float32)                # ★ 先转，和 kernel 一致
    if zero_point is not None:
        x = x - zero_point.to(torch.float32)      # 非对称版
    return x * scale.to(torch.float32)            # 广播自动生效
```

### 8.2 三个必须对齐的点

| 点 | 要求 |
|---|---|
| **转换顺序** | kernel 是"先 Cast 再 Sub/Mul"，golden 必须同序（否则 int 域做减法会溢出语义不同） |
| **转换精度** | 双方都用 float32 中间量 ⇒ golden 与 kernel 误差只剩浮点舍入 |
| **广播形状** | golden 用 `scale[None, :]` 显式广播，避免形状不同却"碰巧对" |

### 8.3 验证容差

| 输出 dtype | rtol | atol |
|---|---|---|
| float32 | 1e-6 | 1e-6 |
| float16 | 1e-3 | 1e-3 |

**注意**：因为是纯乘加、无累加，**误差应该比 add 更小**（add 也只有 1 次加法）。若验证失败，几乎一定是**广播映射错了**，而不是精度问题 —— 先去查 `scale` 的下标是否错位。

---

## 九、与官方样例的关系：能抄什么、必须改什么

官方 `dequant.asc`（`03_quantization/dequant/`）是**最简示范**，不是性能骨架：

| 官方做法 | 能不能抄 | 说明 |
|---|---|---|
| 公式与 `PER_CHANNEL` 语义 | ✅ **抄** | 这是算子定义 |
| `[128,32] × [1,32]` 的形状 | ✅ 抄作**最小测试用例** | 太小，不能当性能基准 |
| `AscendDequant` / `Dequantize` 高阶 API | ⚠️ **可选** | 一行调完，但你就练不到基础 API |
| `TQue` 深度 = **1**（单缓冲） | ❌ **要改** | 官方是单缓冲，**没有流水** |
| `NUM_BLOCKS = 1`（单核） | ❌ **要改** | 必须多核切分 |
| 无尾块处理 | ❌ **要补** | 官方 shape 正好整除 |
| `Duplicate(offset, 0, ...)` 造 0 offset | ✅ 抄 | 走 3510 接口时需要 |

**官方源码里的关键参数**（已核对）：

```cpp
struct VecTiling { uint32_t m; uint32_t n; uint32_t calCount; uint32_t sharedTmpBufferSize; };
// m=128, n=32, calCount=32 ← scale 的元素个数
pipe->InitBuffer(inQueueX,          1, dataSize * sizeof(int32_t));   // 深度 1
pipe->InitBuffer(inQueueDeqScale,   1, scaleSize * sizeof(scaleT));
pipe->InitBuffer(outQueue,          1, dataSize * sizeof(dstT));
AscendDequant(dst, src, scale, {rowLen, colLen, scaleSize});          // A2/A3
```

---

## 十、多级优化路线（建议的 `SCENARIO` 分级）

| Case | 内容 | 观察指标 | 预期 |
|---|---|---|---|
| **0** | 单核 + 单缓冲 + 高阶 API 基准 | `Task Duration` | 起点 |
| **1** | 多核切 M 行 | `aiv_time` | 掉约 `coreNum` 倍 |
| **2** | 基础 API 手写（`Cast`+`Mul`）+ 大搬运粒度 | `mte2_active_bw` | 带宽上升 |
| **3** | **双缓冲**（Ping/Pong） | `Σ(流水)/T` | 从 ~1 → **1.2+** |
| **4** | **`scale` 常驻 UB**（只搬一次）+ 广播路线 ② | `aiv_mte2_time` | 减少重复读 |
| **5** | `L2` bypass（`x` 只读一次） | `aiv_mte2_time` | 抄官方 Case 5 |

**判据回顾**（前几轮已确认）：
- `Σ(各流水线时间) / aiv_time`：**≈1.0 串行 / >1.2 真重叠**
- 对比实验必须**仿真与上板用同一个 `coreNum`**（仿真默认 48、上板 40）

---

## 十一、实现检查清单（写完对照打勾）

- [ ] `scale` 只从 GM 搬 **1 次**，常驻 UB 复用（而非每行重读）
- [ ] 广播下标映射正确：`scale` 用 **N 向**索引，**M 向不参与**
- [ ] `Mul`/`Sub` 的元素数用**真实 N**，不是 32B 对齐后的长度
- [ ] 尾块：行尾块（M%coreNum）、列尾块（N%8）、块内尾块 三者都覆盖
- [ ] 非对齐行用 `DataCopyPad`（N 为奇数时**每一行**都非对齐）
- [ ] dtype：先 `int32 → float32`；扩 fp16 时确认"两步转换"
- [ ] `coreNum`、`blockLength` 打印出来，仿真/上板两侧一致
- [ ] golden 用 float32 同序计算，`--strict` 验证一次
- [ ] 采一次 `PipeUtilization`，算 `Σ/T`（判断双缓冲是否生效）
- [ ] 出 fp32 时确认 `T_MTE2 : T_MTE3` 是否真的从 2:1 变成 ~1:1

---

## 十二、待验证的问题（写代码前先搞清）

| # | 问题 | 怎么验证 |
|---|---|---|
| 1 | int32 → float32 的 `Cast` 在 2201 上是否单指令支持 | 查基础 API 文档的 dtype 支持表 |
| 2 | `int32 → float16` 是否必须两步 | 同上；必要时用 fp32 中转 |
| 3 | `Brcb` 的确切语义（一个 block → 几个 block？） | 读 `03_basic_api/01_memory_vector_compute/brcb/README.md` |
| 4 | `DataCopyExtParams` 里 `srcStride=0` 是否等价"重复读同一段" | 小 shape 实验：故意设 0，看结果是否每行相同 |
| 5 | 按行循环的 `Mul` 标量开销有多大 | profiling 看 `aiv_scalar_ratio` + `scalar_wait_ib_time` |
| 6 | 官方 `AscendDequant` 在 2201 上是否比手写更快 | 同一 shape 各跑一次对比 |

**以上第 3、4 条直接决定"广播走哪条路线"，建议先做掉。**

---

## 十三、参考

| 内容 | 位置 |
|---|---|
| 官方 Dequant 样例 | `asc-devkit/examples/01_simd_cpp_api/04_advanced_api/03_quantization/dequant/` |
| 同目录 quant / antiquant | `.../03_quantization/{quant,antiquant}/` |
| 值域与广播 API | `.../03_basic_api/01_memory_vector_compute/{brcb,duplicate}/` |
| 多级优化的骨架样板 | `.../05_best_practices/00_vector_compute/add_high_performance/` |
| TQue 范式样板 | `.../00_introduction/01_add/add_tpipe_tque/`（本地副本：`../add_asc/add_tpipe_tque/`） |
| `Dequantize` 接口文档 | `asc-devkit/docs/zh/api/SIMD-API/adv_api/quantization/Dequantize.md` |
| 流水线判读方法 | `../add_asc/add_pipeline_learn/PIPELINE_ANALYSIS.md` |
