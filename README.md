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

### 参数速查表（一次说清 6 个位置参数）

`run` / `prof` 的参数**完全一致**（`prof` 在末尾多一个可选的 `sim`）：

```bash
./build.sh run  <M> <N> [tileLength] [l2] [db] [group]
                  $1  $2      $3        $4   $5    $6
# 等价于直接跑：./build/dequant <M> <N> [tileLength] [l2] [db] [group]
```

| 位置 | 参数 | 默认 | 含义 |
|---|---|---|---|
| 1 | `M` | 1024 | 行数 |
| 2 | `N` | 1024 | 列数（= scale 长度） |
| 3 | `tileLength` | `min(2048,N)` 向上取整到 8 | 列方向一个 tile 的元素数 |
| 4 | **`l2`** | 0 | **非 0 = 关闭 `xGm` 的 L2 Cache**（L2 优化开关） |
| 5 | **`db`** | 0 | 非 0 = 启用**双缓冲**（Ping/Pong，x/y 各 2 份） |
| 6 | **`group`** | 0 | **0 = 不用 GROUP 版**；>0 = 每批一次搬 `group` 行 |

**`l2` / `db` / `group` 是三个正交开关** ⇒ 可以任意组合，共 8 种配置。程序每次启动都会打印实际走的路径：

```
[MODE] group+double_buffer (group=8 行/批, 2 份 buffer)  |  x 不走 L2
```

> ⚠️ `l2` 的语义**变过**：早期它是"选一个叫 `dequant_custom_l2_cache` 的 kernel"（那个 kernel 只是再调一次 `Process2()`，**完全没有 L2 优化**，是空壳，现已删除）；现在是纯开关，位置不变。

### 七个子命令

| 命令 | 作用 | 备注 |
|---|---|---|
| `./build.sh build [sim]` | **cmake 编译**（性能版） | 不带参数=上板；带 `sim`=仿真 |
| `./build.sh gen M N` | **生成测试数据** → `input/` + `output/golden.bin` | `M N` 必须与 `run` 一致 |
| `./build.sh run M N [tile] [l2] [db] [group]` | 跑算子 → `output/output.bin` | 参数见上表 |
| `./build.sh verify` | **校验精度** | 比对 `output.bin` 与 `golden.bin` |
| `./build.sh prof M N [tile] [l2] [db] [group] [sim]` | **采集性能数据** | `sim` 放**最后**（它和数字参数靠取值区分） |
| **`./build.sh san M N [tile] [l2] [db] [group] [tools]`** | **msSanitizer 内存/同步检测** | 用**独立目录 `build-san/`**，不影响 `build/`；`tools` 默认 `memcheck` |
| `./build.sh clean` | 删除 `build/`（**不动 `build-san/`**） | |

### ⓪ 内存/同步异常检测（msSanitizer，可选）

**平时完全不用管它** —— `ENABLE_SANITIZER` 默认 `OFF`，`build`/`run`/`prof` 一点都不受影响。
只在怀疑**越界踩踏 / 脏读 / 数据竞争 / 同步不配对**时才跑：

```bash
./build.sh san 8175 7775 2048 0 1 8                      # memcheck（默认）
./build.sh san 8175 7775 2048 0 1 8 memcheck,initcheck   # 多个子工具
```

| 子工具 | 抓什么 |
|---|---|
| `memcheck` | **非法读写、非对齐访问、多核踩踏、内存泄漏** ← 查 UB 越界靠它 |
| `initcheck` | 未初始化内存的**脏读** |
| `racecheck` | 核内 / 核间**数据竞争** |
| `synccheck` | set/wait 不配对导致的**同步失败** |

**报错能直接定位到源码行**：

```
====== ERROR: illegal read of size 224
======    at 0x12c0c0015000 on GM in dequant_custom
======    in block aiv(0) on device 0
======    #0 .../kernel_operator_data_copy_impl.h :58:9
======    #3 dequant.asc:452:9          ← ★ 你的源码行
```

**为什么用独立目录而不是开关同一个 `build/`**：
`ENABLE_SANITIZER` 是 CMake 缓存变量，**开关一变就得清缓存**（否则会"以为开了其实跑的旧的"）。
独立 `build-san/` ⇒ 一次配置长期共存，**开关切换零成本**，只是多占磁盘。

**两个必须知道的约束**：

| 约束 | 说明 |
|---|---|
| **不能用 `-O0`** | [ai_core_operator_compilation.md:114](<asc-devkit/docs/zh/guide/programming_guide/compilation_and_execution/operator_compilation/ai_core_operator_compilation.md#L114>)：sanitizer 必须配 `-g` 且**不能在 `-O0` 场景下使用** ⇒ CMakeLists 里已兜底把 `CMAKE_BUILD_TYPE` 设成 `RelWithDebInfo` |
| **⚠️ 与 L2 优化冲突** | 同一条出处：开启后 **GlobalTensor 强制走 L2，`SetL2CacheHint` 失效** ⇒ **`l2=1` 的收益必须用不带 sanitizer 的 `build/` 来测**；`build-san/` 只用来查内存/同步问题 |

**为什么需要它**：`LocalMemAllocator::Alloc()` **没有任何边界检查**（就是一句 `head_ += ...`），
所以 UB 越界里有很大一类是**静默错**（踩到相邻 tensor、不报错、结果随机错）——
`CheckUbBudget` 是 Host 端的提前防线，msSanitizer 是上板后的兜底验证。

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

**读 Roofline 要同时看两个东西**（只看标签会漏判）：

| 读什么 | 含义 |
|---|---|
| **达成率**（百分比） | 提升了多少 —— 优化有效的直接证据 |
| **分类标签**（如 `latency bound: memory caused`） | 当前受限于什么 —— **决定下一步做什么** |

> 本项目实测：双缓冲让达成率 **30% → 46%**（1.53×），但标签**仍是 `latency bound`** ——
> 说明"有提升"和"离开延迟受限"是两件事，后者需要把剩下的 54% 也补上。

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
    ├── Memory.csv               ← 主存/UB 读写带宽、实际搬运量、MTE2/MTE3 指令数
    ├── L2Cache.csv              ← L2 读写命中率（验 L2 优化必看）
    ├── ...（共 7 个 metric CSV）
    └── visualize_data.bin       ← ★ 导入 MindStudio Insight 看 Roofline / 热力图 / 流水图
```

**先看 `OpBasicInfo.csv` 的 `Task Duration(us)`（端到端）**，再看这几组：

| 指标 | 在哪个 CSV | 看什么 |
|---|---|---|
| `aiv_mte2_time` / `aiv_mte3_time` / `aiv_vec_time` / `aiv_scalar_time` | PipeUtilization | 谁的 ratio 接近 1.0 ⇒ 谁是真瓶颈 |
| 上面 4 个之和 ÷ `aiv_time` | 自己算 | **≈1.0 = 串行；>1.2 才有重叠** |
| `GM_to_UB_datas` / `read_main_memory_datas` | Memory | 实际搬了多少字节（**注意它只跟 N 有关、与 M 无关**） |
| `GM_to_UB_bw_usage_rate` | Memory | 带宽利用率；**很小 ⇒ 不是带宽受限，是延迟/固定开销** |
| `aiv_mte2_instructions` | Memory | **搬运笔数** —— 验 GROUP 是否生效的唯一硬指标 |
| `aiv_read_hit_rate` / `aiv_write_hit_rate` | L2Cache | 验 L2 CacheMode 是否生效 |

---

### ④ 一步步的优化过程（本项目的实际路径）

> 每步都给出**配置、实测数据、验证指标**，方便复现与对照。
> 所有数字都来自 910B3（dav-2201，40 AIV），`Task Duration(us)` 取 40 核平均。

#### Step 0｜先"能算对"，再谈快慢

目标只有一个：`./build.sh verify` 输出 `test pass!`。
这一版的实现是 **`i` 在外、`j` 在内**，`sLocal` 在每个 `(i, j)` 都重搬一次：

```cpp
for (i = 0; i < singleCoreM; i++)          // 行
    for (j = 0; j < loopCount; j++)        // 列 tile
        DataCopyPad(sLocal, sGm[j*tileLength], ...);   // ← 每行都重搬！
```

#### Step 1｜`scale` 常驻：把 `s` 的搬运提到外层（换序）

**发现的问题**：`sGm` 只有 `N` 个元素、全核共用，却在内层循环里**被每行重搬一次**。

```
read_main = x(26 行 × 4KB = 104KB) + s(26 行 × 4KB ≈ 100KB) = 205.3 KB
                                     ↑ s 的真实数据只有 4 KB，搬了 26 次
```

**做法**：把 `i`/`j` 两层循环**换序**（`j` 提到外层），`s` 的搬运自然落到 `j` 层、`i` 层之上 ⇒ 每个 `j` 只搬一次。
`x` 和 `s` 的**生命周期不同**（`x` 每行轮换、`s` 每个 `j` 才换）⇒ 必须用**独立的 event id**，且 `s` 的 `V_MTE2` 释放要放在 `i` 循环**之后**。

| 指标 | Step 0 | Step 1 | 变化 |
|---|---|---|---|
| `Task Duration` | 131.76 μs | **16.76 μs** | **−87%** |
| `read_main_memory_datas` | 205.3 KB | **107.8 KB** | **−47.5%**（预测 −48%，吻合 ✓） |
| `aiv_mte2_time` (ratio) | 125.08 (0.977) | 11.08 (0.760) | −91% |
| `aiv_vec_time` | 1.46 μs | **1.46 μs** | **不变** ← 最干净的对照证据 |
| `Σ(4 流水)/aiv_time` | 1.280 | 1.451 | 重叠度 ↑ |
| `GM_to_UB_bw_usage_rate` | 0.687% | **3.148%** | 4.6× |

> **验证指标**：`read_main_memory_datas` 应精确减半；`aiv_vec_time` **必须一点不变**（计算量没动，变了就说明测错了）。
>
> **⚠️ 一个诚实的存疑**：时间降幅（7.9×）**远大于**读量降幅（2×）。同一份旧代码在大 shape（8175×7775）下只快 2%（742 → 725 μs）⇒ 小 shape 的额外收益来自一个**与 shape 无关的 ~115 μs 常数项**（旧版指令级数据里 `BAR` 占 VECTOR 55%，是唯一线索），**原因未查清**。所以小 shape 的 7.9× 不宜当作优化效果的基准，**大 shape 才是真实负载**。

#### Step 2｜双缓冲（Ping/Pong）：消掉串行链

**发现的问题**：单缓冲下 `x_copy → V(算) → y_copy → x_copy(下一轮)` 是一条**串行链**，搬运和计算无法重叠。
Roofline 判定 **`latency bound: memory caused`** ⇒ 瓶颈是**延迟**，不是带宽 ⇒ 该做的是**增加在飞笔数**。

**做法**：`xLocal` / `yLocal` 各 2 份，按 `i & 1` 轮转，每份一个独立 event id；
`sLocal` **仍只 1 份**（循环内只读，双份没意义）。

| 指标 | 大 shape baseline | 大 shape 双缓冲 | 变化 |
|---|---|---|---|
| `Task Duration` | 725.39 μs | **484.23 μs** | **−33.2%** |
| `aiv_mte2_time` (ratio) | 595.37 (0.832) | 464.70 (**0.967**) | −21.9% |
| `aiv_mte3_time` (ratio) | 475.87 (0.665) | 378.38 (0.787) | −20.5% |
| `aiv_vec_time` | 81.10 μs | **81.09 μs** | **不变** ✓ |
| `Σ(4 流水)/aiv_time` | 1.644 | **2.002** | 重叠度 ↑ |
| **Roofline 达成率** | **30%** | **46%** | **1.53×**（与时间比 1.498× 一致） |
| 搬运字节 | 6435.6 KB | 6435.6 KB | **不变**（排除"少搬了"） |

> 小 shape（1015²）同样受益：16.76 → **12.24 μs**（−27%）。
>
> **验证指标**：`Σ(4)/aiv_time` 上升 + `aiv_vec_time` 不变 + 搬运字节不变 ⇒ 三者同时成立才是"纯流水线收益"。
>
> **关键读数**：双缓冲后 `aiv_mte2_time / aiv_time = 0.967` ⇒ **`aiv_time` ≈ MTE2 自身耗时** ⇒ 重叠空间已吃干净，
> **再叠双缓冲无用**，只能减少 MTE2 自己要干的活 ⇒ 进入 Step 3。

#### Step 3｜GROUP 打包：把 MTE2 的「笔数」除下去

**发现的问题**：`aiv_mte2_time` 464.70 μs、搬运 6255 KB/核、**笔数 ≈ 818/核** ⇒ 平均每次 **0.568 μs 搬 7.6 KB**。
`GM_to_UB_bw_usage_rate` 只有 3.8% ⇒ 每次搬运的**固定开销**（延迟）主导。

**做法**：用 `DataCopyExtParams` 的 `blockCount` + `srcStride` **让硬件一次搬 `group` 行**，`i` 循环从 MTE2 路径上消失：

```cpp
DataCopyExtParams xp{
    (uint16_t)rows,                        // blockCount = 本批行数
    actualTileLength * 4,                  // blockLen   单位【字节】
    (N - actualTileLength) * 4,             // srcStride  单位【字节】← GM 侧，跳掉行内剩余列
    0,                                     // dstStride  单位【32B】← UB 侧，0 = 紧凑排列
    0                                      // rsv
};
DataCopyPad(xLocal, xGm[row0 * N + sOffset], xp, xPadParams);
```

```bash
./build.sh run  1024 1024 1024 0 0 1      # group=1：先验证 pitch/stride 推导是否正确（成本最低）
./build.sh run  1024 1024 1024 0 0 8      # group=8
./build.sh prof 8175 7775 2048 0 0 8
```

> **验证指标**：`Memory.csv` 的 **`aiv_mte2_instructions`** 应约等于原来的 1/group（**这是唯一能证明 GROUP 生效的硬指标**），
> 同时 `verify` 必须仍 pass（防 `pitch` 算错）。
>
> **状态**：代码已就绪（`ProcessGroup` / `ProcessGroup_DoubleBuffer`），**性能数据待采**。

#### Step 4｜L2 CacheMode：只关 `xGm` 一个

**发现的问题**：`x` 每核读一遍自己的行、**全算子只读一次**（248 MB 纯流式），却和需要复用的数据一起走 L2 ⇒
把有效数据冲掉（且 L2 换出旧数据时要先写回 GM、占用带宽）。
旁证：实测 L2 **写**命中率只有 **27.1%**（读 54.8%）—— 正是被流式读冲刷的典型特征。

**做法**：在 `Init()` 里加一行，**只关 `xGm`**：

```cpp
xGm.SetL2CacheHint(AscendC::CacheMode::CACHE_MODE_DISABLE);
// sGm / yGm 故意保持默认 CACHE_MODE_NORMAL：
//   s 被 40 个核反复读 ⇒ 正是"需要重复读取"的数据
//   y 只写一次，但官方 add 样例里输出 z 也保持 NORMAL（写命中 L2 有收益）
```

依据：[l2_cache_mode_config.md:35](<asc-devkit/docs/zh/guide/operator_practice/simd_operator_optimization/memory_access/l2_cache_mode_config.md#L35>)
「对于只访问一次的数据设置其访问状态为不进入 L2 Cache，避免一次性访问的数据替换有效数据」；
API 见 [SetL2CacheHint.md](<asc-devkit/docs/zh/api/SIMD-API/basic_api/data_structures/GlobalTensor/SetL2CacheHint.md#L81>)（**A2 系列支持** ✓）。

```bash
./build.sh prof 8175 7775 2048 0 1 8      # 基准：group+db
./build.sh prof 8175 7775 2048 1 1 8      # 加上 L2 优化
```

> **验证指标**：`L2Cache.csv` 的 `aiv_write_hit_rate(%)`（现在 27.1）应**上升**；
> `aiv_read_hit_rate(%)`、`aiv_total_hit_rate(%)` 看好坏。
> 同时看 `Memory.csv` 的 `aiv_gm_to_ub_bw(GB/s)`（和官方给的关注项一致）。
>
> **⚠️ 编译期坑**：用 `--sanitizer` 时 GlobalTensor 会**强制走 L2**，本接口失效
> （[ai_core_operator_compilation.md:114](<asc-devkit/docs/zh/guide/programming_guide/compilation_and_execution/operator_compilation/ai_core_operator_compilation.md#L114>)）⇒ 别在 sanitizer 下测这项。
>
> **状态**：代码已就绪，**性能数据待采**。

#### 优化路径汇总

| 阶段 | 配置（`run M N tile l2 db group`） | 大 shape Duration | 关键证据 |
|---|---|---|---|
| Step 0 baseline | `0 0 0`（旧版 i 外 j 内） | 742 μs（旧码） | `read_main` 205 KB（s 重复读） |
| Step 1 scale 常驻 | `0 0 0`（换序后） | 725.39 μs | `read_main` 107.8 KB（−47.5%） |
| Step 2 双缓冲 | `0 1 0` | **484.23 μs** | `Σ/T` 1.644→2.002；达成率 30%→46% |
| Step 3 GROUP | `0 0 8` / `0 1 8` | 待采 | 看 `aiv_mte2_instructions` ÷8 |
| Step 4 L2 | `1 1 8` | 待采 | 看 `L2Cache.csv` 写命中率 ↑ |

**还有一个"不能做"的优化方向**（避免走弯路）：

| 想法 | 为什么不要 |
|---|---|
| 把 `Vec` 利用率提到 50% | 本算子算术强度只有 ~0.25 op/Byte（**访存型**），`aiv_vec_time` 是算量决定的常数、几乎压不动 ⇒ **50% 等价于把 `aiv_time` 压到 `vec/0.5`，需要 MTE2 再快 2~3× 而它已 0.967** ⇒ 不可达。**融合后续算子**才是唯一实质途径 |
| `scale` 换 half / bf16 | 大 shape 下 s 只占搬运量的 **0.5%** ⇒ 没必要 |
| 把 `Cast`+`Mul` 合成一条 | 两者**同属 VECTOR 流水**，融合后 `aiv_time` 和 `vec_time` 同时降 ⇒ **利用率不变**，只省延迟。而且 per-channel + float32 没有可用的融合指令（`CastDequant` 只支持 int32→half + per-tensor scale） |

---

### ⑤ tile 参数对齐 与 UB 校验函数设计

> 这一节是代码里最容易踩坑、也最需要在 README 里说清的部分。

#### 5-1 为什么 `tileLength` 必须是 8 的倍数

```cpp
// CheckUbBudget() 里
if (tileLength == 0u || (tileLength * 4) % 32u != 0u) return -1;
```

本算子所有 buffer 的元素类型都是 **4B**（`int32_t` / `float`）⇒ **8 个元素 = 32B**，所以"8 的倍数"就是"32B 对齐"。

**根因**：`LocalMemAllocator` 是 **bump 分配器且不做任何取整**
（[kernel_tensor_impl.h:1804](<asc-devkit/impl/basic_api/kernel_tensor_impl.h#L1804>)：`head_ += sizeof(T)*tileSize`）⇒
只要**某一个** buffer 的长度不是 32B 的倍数，**它后面所有 tensor 的起始地址就全部错位**，
而 `DataCopyPad` 要求 **UB 目的地址 32B 对齐**（[DataCopyPad_GMToUB.md:115](<asc-devkit/docs/zh/api/SIMD-API/basic_api/memory_vector_compute/data_move/DataCopyPad_GMToUB.md#L115>)）⇒ 直接违规。

**Host 侧的兜底**：`main` 里先把 `tileLength` 收窄（`min(8192)` + 向上取整到 8），再由 `CheckUbBudget` 校验；
命令行**显式传入**非 8 倍数时会被拒绝并打印原因。

#### 5-2 `pitch` 与 `actualTileLength`：尾块只补到 32B，**不补到 `tileLength`**

这是 GROUP 版最容易算错的地方：

```cpp
uint32_t pitch = (actualTileLength * 4 + 31) / 32 * 32 / 4;   // 行步长（元素）
```

**`DataCopyPad` 的补齐粒度是 32 字节，不是 `tileLength`**
（[DataCopyPad_GMToUB.md:61](<asc-devkit/docs/zh/api/SIMD-API/basic_api/memory_vector_compute/data_move/DataCopyPad_GMToUB.md#L61>)：
「当每个搬运的数据块长度非 32 字节对齐时，每一个数据块都需要填充数据至 32 字节对齐」）。

```
N = 7775, tileLength = 2048
  tile 0/1/2 : actualTileLength = 2048  →  pitch = 2048   （相等，紧凑）
  tile 3     : actualTileLength = 1631  →  pitch = 1632   （1631*4=6524B 补到 6528B）
```

| 用途 | 用哪个 | 为什么 |
|---|---|---|
| **行首偏移**（`xLocal[r * pitch]`） | **`pitch`** | UB 里每行**物理上**占 1632 个元素的位置 |
| **计算长度**（`Cast/Mul` 的 `count`） | **`actualTileLength`** | 多算会读到补齐的 dummy（且会越界读 `sLocal`） |

**算错的症状很好认**：
- 用 `actualTileLength` 当偏移 ⇒ 每行少走 1 个元素 ⇒ **从第 2 行起整体错位 4 字节**
- **`pitch` 一定是 32B 的倍数** ⇒ 每行起点天然 32B 对齐 ⇒ 逐行 `Cast`/`Mul` 合法

**验证方法**：先跑 `group=1`（`rows` 恒为 1，但 `pitch`/`stride` 的推导同样生效）⇒ 成本最低地暴露错误。

#### 5-3 `srcStride` / `dstStride` 的**单位是相反的**

单位跟着**它跨越的那一端的内存**走：**GM 侧 = 1 字节**（可任意字节寻址）、**UB 侧 = 32B**（硬件访问粒度是 DataBlock）。

| 方向 | `srcStride` 管的 | `dstStride` 管的 |
|---|---|---|
| **搬入** GM→UB | **GM** ⇒ **字节** | **UB** ⇒ **32B** |
| **搬出** UB→GM | **UB** ⇒ **32B** | **GM** ⇒ **字节** |

```cpp
// 搬入：GM 侧跳掉行内剩余列（字节） / UB 侧紧凑（32B 单位，0）
xCopyParams.srcStride = (N - actualTileLength) * sizeof(int32_t);
xCopyParams.dstStride = 0;

// 搬出：UB 侧跳掉补齐的 dummy（32B 单位） / GM 侧跳掉行内剩余列（字节）
yCopyParams.srcStride = (pitch - actualTileLength) / 8;      // ÷8 = 字节 → 32B
yCopyParams.dstStride = (N - actualTileLength) * sizeof(float);
```

**⚠️ 另一个 2201 特有的限制**：`DataCopyExtParams` 的 `srcStride`/`dstStride` 在 **A2 系列是 `uint32_t`（无符号）**，
只有 3510/51xx 才是 `int64_t`（可负）⇒ **文档里 `srcStride = -blockLen`（"重复搬同一块"）在 2201 上用不了**
（[kernel_struct_data_copy.h:215-233](<asc-devkit/include/basic_api/kernel_struct_data_copy.h#L215>)）。

#### 5-4 `CheckUbBudget()`：把 5 个 kernel / 4 种模式的校验收敛到一处

**为什么需要它**：4 种模式的 buffer 个数和"每个 x/y buffer 装几行"都不同，散在 `main` 里写很容易漏算一格；
而算错的后果是**静默 UB 越界**（编得过、跑得动、结果随机错，bump 分配器不做边界检查）。

**units 公式**（逐个 `Alloc` 数出来的）：

```
units = 2 * xyCopies * rowsPerBuf + 1 + xcastUnits
         ↑ x 和 y 各一组              │   └ baseline 独占的 xcastLocal
                                      └ sLocal 常驻（只 1 份，不随 group 放大）
  xyCopies   = doubleBuffer ? 2 : 1     （双缓冲把 x、y 各复制一份）
  rowsPerBuf = group > 0 ? group : 1    （group 版每个 x/y buffer 装 group 行）
  xcastUnits = (group==0 && !doubleBuffer) ? 1 : 0
```

| 模式 | kernel → 方法 | 实际 Alloc | **units** |
|---|---|---|---|
| baseline | `dequant_custom` → `Process2()` | x · **xcastLocal** · s · y | **4** |
| double_buffer | → `ProcessDoubleBuffer()` | xPing · xPong · s · yPing · yPong | **5** |
| group | → `ProcessGroup(group)` | x(group行) · s · y(group行) | **2g+1** |
| group+double_buffer | → `ProcessGroup_DoubleBuffer(group)` | xPing/xPong · s · yPing/yPong | **4g+1** |

**两处最容易算错的地方**：

1. **`sLocal` 始终只占 1 份、且只占 `tileLength`**（循环内只读、常驻，**不随 group 放大**）⇒ 它是 `+1`，**不是 `*rowsPerBuf`**
2. **baseline 的 `Process1`/`Process2` 比其它三个模式多一个 `xcastLocal`**（早期给 `Cast` 用的中间缓冲，
   后面几版都改成 `Cast` 直接落 `yLocal` 了）⇒ baseline 单独 `+1`，否则**少算 1/4 的 UB**

**第二项校验：容量**

```cpp
needBytes = units × tileLength × 4B  ≤  UB 容量
// UB 容量用 GetCoreMemSize(CoreMemType::UB, ...) 运行时取，不硬编码 192KB（换芯片才对）
```

失败时会打印**当前模式下的可调上限**，照改命令行参数即可：

```
[ERROR] UB 不够（模式 group+double_buffer）：需要 270336 B，UB 只有 196608 B
        按当前参数，上限约： tileLength <= 1489
                             group      <= 2
```

---

### 脚本帮你处理掉的 3 个坑

| 坑 | 脚本怎么处理 |
|---|---|
| **换 RUN_MODE 后 cmake 缓存作祟** | 用 `build/.mode` 记录，模式变了自动 `rm -rf build` 再 configure |
| **仿真库路径不对**（cmake 里硬编码 `tools/simulator/`，部分 CANN 版本实际在 `<arch>-linux/simulator/`） | `run`/`prof` 用 `find` 现查 `libruntime_camodel.so` 并 export `LD_LIBRARY_PATH` |
| **`prof` 只转发前两个参数**（→ 双缓冲/GROUP 永远测不到） | 遍历 `${@:2}` 全量转发，并打印 `[INFO] 转发参数: ...` 与程序的 `[MODE]` 互为印证 |

### 四个必须知道的注意点

**1. `M N` 两处必须一致**
`gen M N` 与 `run M N` 的数字要相同。不一致时 host 侧 `ReadFile` 会直接报错退出：

```
[ERROR] 读取 ./input/input_x.bin 失败或大小不符：期望 16384 字节，实际 4194304 字节
```

**2. `tileLength` / `group` 有硬约束**（`CheckUbBudget` 会校验并报错退出，见 ⑤ 节）

| 约束 | 原因 |
|---|---|
| `tileLength` 必须是 **8 的倍数** | bump 分配不做 32B 取整 ⇒ 后面 tensor 起点错位 ⇒ `DataCopyPad` 违规 |
| `units × tileLength × 4B ≤ UB` | `units` 随模式变（4 / 5 / 2g+1 / 4g+1），见 ⑤-4 |

**3. `prof` 要独占卡**
别人在跑会污染 L2 与带宽，采到的数不可用。另外：**仿真与上板的核数不同**（本机实测：上板 `GetCoreNumAiv()`=40、仿真=48），
所以**两边的性能数据不能直接横比**；本算子的 host 没有开放 `coreNum` 参数（核数由 `GetCoreNumAiv()` 决定）。

**4. `dequant_custom` 的 baseline 走的是 `Process2()`（不是 `Process1()`）**
`Process1()` 目前**没有任何 kernel 调用它**（死代码）。做 baseline 对照时留意别拿错版本。

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

**以 `scripts/verify_result.py` 里的常量为准**（改脚本时同步改这里，别两处各写一套）：

| 常量 | 值 | 位置 |
|---|---|---|
| `DEFAULT_RTOL` | `1e-6` | `verify_result.py` |
| `DEFAULT_ATOL` | **`1e-5`** | `verify_result.py` |
| `DEFAULT_ERROR_TOL` | `1e-4`（允许不一致元素的比例；`--strict` 时忽略） | `verify_result.py` |

判定规则：`abs_diff <= atol` **或** `rel_diff <= rtol` 即算通过（两者取或）。
命令行可覆盖：`--rtol` / `--atol` / `--strict`（不允许任何不一致元素）。

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

## 十、多级优化路线（原始规划 vs 实际执行）

> ⚠️ 这一节是**动手前的规划**。实际执行顺序和实测数据见前面的 **【④ 一步步的优化过程】**，
> 两者不一致的地方以 ④ 为准（规划里的 Case 编号保留，方便对照当初的设想与现实的差距）。

| Case | 当初的规划 | 观察指标 | **实际结果** |
|---|---|---|---|
| **0** | 单核 + 单缓冲 + 高阶 API 基准 | `Task Duration` | — 直接上了多核 + 基础 API |
| **1** | 多核切 M 行 | `aiv_time` | ✅ 已做（`GetCoreNumAiv()`，上板 40 / 仿真 48） |
| **2** | 基础 API 手写（`Cast`+`Mul`）+ 大搬运粒度 | `mte2_active_bw` | ✅ 已做；但**粒度不是瓶颈**，`bw_usage_rate` 只有 3% |
| **3** | **双缓冲**（Ping/Pong） | `Σ(流水)/T` | ✅ 已做：`Σ/T` 1.644 → **2.002**，大 shape **−33.2%** |
| **4** | **`scale` 常驻 UB**（只搬一次） | `aiv_mte2_time` | ✅ 已做（**换序**实现）：`read_main` 205 → **107.8 KB** |
| **5** | `L2` bypass（`x` 只读一次） | `aiv_mte2_time` | ✅ 代码已就绪（`l2=1`），**数据待采** |
| — | *（规划外）* **GROUP 打包多行** | `aiv_mte2_instructions` | ✅ 代码已就绪（`group=N`），**数据待采** |

**判据回顾**：
- `Σ(各流水线时间) / aiv_time`：**≈1.0 串行 / >1.2 真重叠**；上限 = `Σ(4条) / max(单条)`
- **Roofline 达成率**：优化有效的量化证据（实测 30% → 46%）
- ⚠️ 对比实验**仿真与上板不能横比**：核数不同（48 vs 40），且 host **没有开放 `coreNum` 参数**（由 `GetCoreNumAiv()` 决定）

---

## 十一、实现检查清单（写完对照打勾）

- [ ] `scale` 只从 GM 搬 **1 次**，常驻 UB 复用（而非每行重读）
- [ ] 广播下标映射正确：`scale` 用 **N 向**索引，**M 向不参与**
- [ ] `Mul`/`Sub` 的元素数用**真实 N**，不是 32B 对齐后的长度
- [ ] 尾块：行尾块（M%coreNum）、列尾块（N%8）、块内尾块 三者都覆盖
- [ ] 非对齐行用 `DataCopyPad`（N 为奇数时**每一行**都非对齐）
- [ ] dtype：先 `int32 → float32`；扩 fp16 时确认"两步转换"
- [ ] golden 用 float32 同序计算，`--strict` 验证一次

**搬运 / 对齐（GROUP 版重点，详见 ⑤ 节）**

- [ ] `tileLength` 是 **8 的倍数**（由 `CheckUbBudget` 校验）
- [ ] 行首偏移用 **`pitch`** = `(actualTileLength*4+31)/32*32/4`
- [ ] 计算长度用 **`actualTileLength`**（与 `pitch` **必须分开**）
- [ ] 搬入 `srcStride` 单位＝**字节**；搬出 `srcStride` 单位＝**32B**（`/8` 换算）
- [ ] **先跑 `group=1` 验证 `pitch`/`stride` 推导**，再扫 `group=2/4/8`
- [ ] `units × tileLength × 4B ≤ UB`（`units` 随模式是 4 / 5 / 2g+1 / 4g+1）

**同步 / 性能**

- [ ] **flag 收支配平**：预置数 = 排空数；`SetFlag<V_MTE2>` 的释放要等**本 j 所有行**都算完
- [ ] 采一次 `PipeUtilization`，算 `Σ/T`（判断双缓冲是否生效）
- [ ] 采一次 `Memory.csv` 的 `aiv_mte2_instructions`（判断 GROUP 是否生效）
- [ ] `l2=1` / `l2=0` 各采一次，比 `L2Cache.csv` 的写命中率

---

## 十二、技术问题账（已验证 / 仍待验证）

### 12.1 已在本项目中验证（有实测或源码/文档依据）

| # | 问题 | 结论 |
|---|---|---|
| 1 | `int32 → float32` 的 `Cast` 在 2201 上是否支持 | ✅ **支持**，5 种 `RoundMode` 可用；选 `CAST_RINT`（与 PyTorch `.astype` 一致）。`uint32→float` **不支持** ⇒ 输入必须按 `int32_t` 处理 |
| 2 | `int32 → float16` 是否必须两步 | ✅ 必须两步（`CastDequant` 只支持 `int32→half` + **per-tensor** scale，per-channel 用不了） |
| 3 | `Brcb` 的确切语义 | ✅ 方向**相反**（1 个元素 → 1 个 32B DataBlock）⇒ 不能用来做 per-channel 广播 |
| 4 | `DataCopyExtParams` 的 stride 语义 | ✅ `srcStride` 在 GM 侧＝**字节**；`dstStride` 在 UB 侧＝**32B**（搬出时相反）。**A2 系列两者都是 `uint32_t`（无符号）⇒ 不能填负值**（`srcStride=-blockLen` 那招 2201 用不了） |
| 5 | 按行循环的 `Mul` 标量开销 | ✅ 可忽略：`aiv_scalar_time` 只有 1.1 μs（相对 `aiv_time` ≈ 0.8%） |
| 6 | `scale` 重复读的成本 | ✅ 精确可测：`read_main` 205.3 → 107.8 KB（**−47.5%**），与"每行重搬 N 个元素"的预测吻合 |
| 7 | 双缓冲是否有效 | ✅ 有效：`Σ/T` 1.644 → 2.002；大 shape **−33.2%**，且 `aiv_vec_time` 与搬运字节都不变（排除干扰） |
| 8 | `tileLength` 是否必须 32B 对齐 | ✅ 必须（8 的倍数）。bump 分配不做取整 ⇒ 后面 tensor 起点全错位 ⇒ `DataCopyPad` 违规 |
| 9 | 尾块的补齐粒度 | ✅ `DataCopyPad` **只补到 32B**，不补到 `tileLength` ⇒ 行步长要用 `pitch`、计算长度用 `actualTileLength` |
| 10 | 非对齐 N（`N%8!=0`）能否跑通 | ✅ 能。`N=7775`（tile 3 的 `actualTileLength=1631`）已实测通过，`blockCount=1` 平铺搬法**不需要行对齐**，`rightPadding=0` 即可 |

### 12.2 仍待验证 / 未查清

| # | 问题 | 怎么验证 |
|---|---|---|
| 1 | **GROUP 的实际收益**（笔数 ÷group 后时间降多少） | 采 `group=8`，看 `aiv_mte2_instructions` 是否 ÷8、`Task Duration` 降多少 |
| 2 | **L2 CacheMode 的实际收益** | `l2=1` vs `l2=0` 同 shape 各采一次，看 `L2Cache.csv` 写命中率 |
| 3 | **旧代码小 shape 的 ~115 μs 常数项是什么** | 旧版指令级数据里 `BAR` 占 VECTOR 55%。用 `core0.veccore0_code_exe.csv`（含源码行号）定位那 3 条 `BAR` 的来源 |
| 4 | **`Process1()` 是否还需要** | 它当前无任何 kernel 调用（死代码）。确认无人依赖后删除 |
| 5 | `aiv_mte2_time` 是否含 flag 等待 | 从指令级 cycles（49082）与 `aiv_mte2_time`（125 μs ≈ 225000 cycles）不一致可推断**含等待**，但需查 PMU 定义确认 |

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
