# 性能测量

**整理日期：2026-11-12。** 本文汇总编译延迟、与 SBCL 的
运行性能对照，以及能解释优化收益的专项测量。数据对应各节注明的工作负载和
实现阶段，不随代码更新；不同实验的绝对时间不能直接拼接比较。

编译器自身的迭代成本和生成程序的运行成本分别衡量。六模块 Lisp 到 KIR 的
编译墙钟约为 7 秒；cl-bench 的较大差距集中在浮点、大整数、多维数组和部分
流、序列操作。局部函数分析、浮点拆箱和对象标量替换在适用的代码模式中能显著
减少指令和分配，但专项结果不能代替完整 cl-bench 对照。

## 测量方法

成对实验在同一台机器上使用相同输入，预热后交替运行基线与候选，报告中位数，
必要时附范围。各组实验分别说明堆大小、runtime 构建方式和计时边界。旧测量未
完整记录处理器、操作系统及工具链版本，因此适合解释同组变化，不宜用作跨机器
的绝对性能基准。

编译延迟使用 [bench-compiler.py](../../tools/bench-compiler.py)：

```sh
tools/bootstrap.sh
python3 tools/bench-compiler.py --warmup 1 --runs 5
```

它测量五个模块加构建程序的六模块批次，固定 8 GiB 堆。墙钟包含 image 初始化
和 Lisp 源码到 KIR，不含 Cranelift 编译、对象文件生成和系统链接。完整构建的
耗时需另外测量。流程和优化计划见
[编译延迟与迭代效率](../design/compiler-performance.md)。

运行性能使用 [cl-bench 驱动](../../tools/bench.sh) 和专用基准：

```sh
BENCH_BUDGET=1 BENCH_TIMEOUT=30 tools/bench.sh
python3 tools/bench-game.py
tools/bench-fe-read.sh
sbcl --script bench/compare.lisp
```

`bench.sh` 的预算控制重复次数，超时覆盖初始化和准备过程，不能把超时上限当成
单轮耗时。`bench-fe-read.sh` 分别测原生 READ 和 Eclector CST 读入，解释结果时
须区分两种工作。`bench/compare.lisp` 使用默认优化级别、没有类型声明；kiln
侧经 `tools/test.sh` 运行并取 AOT 输出。几纳秒级操作只适合比较数量级。

剖析采用 kiln 的 CPU、分配采样器和 perf，接口见
[性能分析器](../design/debugging.md)。`KILN_PROFILE=cpu` 或 `alloc` 启用
采样，`KILN_PROFILE_OUT` 指定 folded 栈文件。CPU 样本受 poll 点分布影响；
分配样本按分配量归因，不是精确对象数或存活量。没有命中样本不等于零分配。
包含时间与自身时间不能相加。

硬件计数使用 `instructions:u`、`cycles:u`，专项实验只覆盖基准函数入口至
返回的 Lisp 线程，排除进程启动和驱动准备。AOT 可用 `KILN_FUNCTION_MAP`
映射 Lisp 名称，JIT 可用 `KILN_PERF_MAP=1`。使用 gdb 抽样时，每个样本应
单独 attach；进程暂停期间连续读栈只会重复同一个瞬间。

## 编译延迟

### 六模块批次

2026-11-11 的不可变函数别名分析实验使用冻结的相同源码和模块清单，两版各
预热一次，再按前、后、后、前的顺序运行两轮，每版四个独立进程样本。测量批次
未检测到其他构建或基准负载。编译程序采用自举 AOT 可执行文件及 dev runtime。

| 指标 | 基线 | 启用别名分析 |
|---|---:|---:|
| 墙钟中位数 | 7.161 s | 7.148 s |
| 墙钟范围 | 7.015–7.337 s | 7.097–7.196 s |
| 前端阶段合计中位数 | 3.794 s | 3.781 s |
| 降级阶段合计中位数 | 2.271 s | 2.288 s |
| KIR 输出阶段合计中位数 | 0.640 s | 0.628 s |
| 峰值 RSS 中位数 | 2799.1 MiB | 2823.8 MiB |

阶段数据先在每次运行内对模块求和，再取中位数；阶段不含启动时间，各阶段的
中位数之和也不等于墙钟中位数。时间范围重叠，未观察到整体编译延迟变化。
独立分配剖析中，别名分析归因分配约 22.02 MiB，占总样本的 0.8%；100 微秒
间隔的 CPU 采样中，其包含权重约为 0.74%。生成程序的收益见下文专项测量。

### Reader 的分配与协议成本

2026-11-10 的 reader 实验比较字符输入、token 缓冲和 CST 索引路径优化前后。
同一六模块输入，固定 8 GiB 堆，各预热一次、测量五次，测量时没有外部 C++
构建负载。

| 指标 | 基线 | 优化后 |
|---|---:|---:|
| 编译墙钟中位数 | 6.855 s | 6.466 s |
| 墙钟范围 | 6.838–6.966 s | 6.432–6.552 s |
| 峰值 RSS 中位数 | 2,887,868 KiB | 2,830,248 KiB |
| 总分配归因 | 2881.1 MB | 2821.4 MB |
| `read-token` 调用链分配归因 | 297.6 MB | 259.2 MB |
| cons 索引表分配归因 | 11.5 MB | 6.6 MB |

墙钟下降约 5.7%，分配减少约 56.9 MiB。字符读取的槽分派自身样本占比从
1.76% 降至 0.06%。结果支持在 reader 热路径中减少逐字符协议调用、复用有界
的 token 暂存空间，以及共享只读的 CST 子 cons 索引。具体输入和前端设计见
[I/O](../design/io.md) 与[前端](../design/front-end.md)。这些数据属于独立实验，
不能把其墙钟与上一张表相减来估算后续改动的成本。

## 和 SBCL 的对比

### cl-bench 全量扫描

2026-11-12 使用以下命令扫描全部 74 个项目；kiln 从当前源码重新构建，
Rust 后端和 runtime 使用 release 配置，基准程序由 SBCL 上的 kiln 前端交叉编译为
KIR，再经 Cranelift 生成 AOT 可执行文件。SBCL 也在同轮重新测量。

```sh
BENCH_BUDGET=1 BENCH_TIMEOUT=30 tools/bench.sh
```

测量机器为 AMD Ryzen 9 7940HS（8 核、16 线程），Fedora Linux 45，
Linux 7.3.3-300.fc45.x86_64；工具链为 Rust 1.99.1、SBCL 2.6.10-1.fc45。
kiln 使用默认的 1 GiB SemiSpace 堆、最多 8 个 GC 线程和驱动设置的 1 GiB
Lisp 栈；SBCL 使用驱动设置的 8 GiB dynamic-space 上限。两边保留基准源码的
优化声明，未额外覆盖编译策略。测量在桌面环境运行，未隔离 CPU。

每项在准备完成后计时，执行到原基准的次数上限或累计达到 1 秒；单轮超过预算
仍会执行完。每格是这一个计时区间的每轮均值，不是多个独立进程的中位数。
kiln 每项独立进程，30 秒超时包含启动和准备；CLOS 项目会先在同一进程执行
其前置项目，以建立所需的类、方法与实例。SBCL 按原顺序在同一进程运行全部项目。
随机数据由各实现生成，未固定跨实现相同的随机序列。

kiln 的 66 项得到耗时，6 项超时；两边的 `compiler`、`load-fasl` 均因驱动
不支持而跳过，SBCL 另外按基准声明跳过 `walk-list/mess`。可配对的 65 项中，
kiln/SBCL 耗时比的中位数为 **4.30×**。这只是已配对项目的分布摘要，未包含
超时项，也没有按工作量加权，不能解释成整个实现的总体性能倍数。

下表覆盖全部项目，单位为毫秒/轮，倍数为 kiln 耗时除以 SBCL 耗时，低于 1
表示 kiln 在该项扫描中耗时更少。`超时` 表示 kiln 进程超过 30 秒，不能将
30 秒换算为每轮耗时；`跳过` 表示该实现未运行该项。

| 项目 | 组 | kiln ms/轮 | SBCL ms/轮 | kiln/SBCL |
|---|---|---:|---:|---:|
| `compiler` | misc | 跳过 | 跳过 | — |
| `load-fasl` | misc | 跳过 | 跳过 | — |
| `sum-permutations` | misc | 245.921 | 32.335 | 7.61× |
| `walk-list/seq` | misc | 0.109 | 0.040 | 2.73× |
| `walk-list/mess` | misc | 1.486 | 跳过 | — |
| `boyer` | gabriel | 5.264 | 3.867 | 1.36× |
| `browse` | gabriel | 14.550 | 5.600 | 2.60× |
| `dderiv` | gabriel | 3.012 | 1.940 | 1.55× |
| `deriv` | gabriel | 2.760 | 1.717 | 1.61× |
| `destructive` | gabriel | 1.355 | 0.610 | 2.22× |
| `div2-test-1` | gabriel | 1.383 | 0.880 | 1.57× |
| `div2-test-2` | gabriel | 1.555 | 1.135 | 1.37× |
| `fft` | gabriel | 43.087 | 0.133 | 324.0× |
| `frpoly/fixnum` | gabriel | 1.040 | 0.750 | 1.39× |
| `frpoly/bignum` | gabriel | 12.782 | 2.333 | 5.48× |
| `frpoly/float` | gabriel | 11.616 | 1.060 | 11.0× |
| `puzzle` | gabriel | 151.213 | 0.753 | 200.8× |
| `tak` | gabriel | 0.196 | 0.127 | 1.54× |
| `ctak` | gabriel | 0.461 | 0.087 | 5.30× |
| `trtak` | gabriel | 0.192 | 0.127 | 1.51× |
| `takl` | gabriel | 1.923 | 0.870 | 2.21× |
| `stak` | gabriel | 0.739 | 0.420 | 1.76× |
| `fprint/ugly` | gabriel | 19.018 | 0.435 | 43.7× |
| `fprint/pretty` | gabriel | 54.117 | 1.900 | 28.5× |
| `traverse` | gabriel | 23.160 | 13.700 | 1.69× |
| `triangle` | gabriel | 55.031 | 24.001 | 2.29× |
| `richards` | misc | 43.438 | 39.801 | 1.09× |
| `factorial` | math | 0.224 | 0.057 | 3.93× |
| `fib` | math | 0.801 | 0.720 | 1.11× |
| `fib-ratio` | math | 0.423 | 0.006 | 70.5× |
| `ackermann` | math | 1017.316 | 659.023 | 1.54× |
| `mandelbrot/complex` | math | 18.144 | 0.910 | 19.9× |
| `mandelbrot/dfloat` | math | 4.301 | 0.010 | 430.1× |
| `mrg32k3a` | math | 1462.487 | 5.000 | 292.5× |
| `crc40` | math | 151.475 | 80.504 | 1.88× |
| `bignum/elem-100-1000` | bignum | 4462.295 | 11.700 | 381.4× |
| `bignum/elem-1000-100` | bignum | 超时 | 14.000 | — |
| `bignum/elem-10000-1` | bignum | 超时 | 11.200 | — |
| `bignum/pari-100-10` | bignum | 102.728 | 2.400 | 42.8× |
| `bignum/pari-200-5` | bignum | 633.232 | 9.100 | 69.6× |
| `pi-decimal/small` | bignum | 42.224 | 1.200 | 35.2× |
| `pi-decimal/big` | bignum | 2703.992 | 24.001 | 112.7× |
| `pi-atan` | bignum | 50.068 | 0.530 | 94.5× |
| `pi-ratios` | bignum | 423.565 | 130.505 | 3.25× |
| `htable-string-small` | hash | 22.785 | 4.500 | 5.06× |
| `htable-string-large` | hash | 12.249 | 1.250 | 9.80× |
| `htable-string-fair` | hash | 超时 | 171.256 | — |
| `htable-mixbag` | hash | 22.309 | 30.001 | 0.74× |
| `htable-fixnum` | hash | 300.038 | 149.755 | 2.00× |
| `htable-equalp-numbers` | hash | 21.944 | 3.501 | 6.27× |
| `htable-sparse` | hash | 2.403 | 1.000 | 2.40× |
| `htable-set+remove` | hash | 10.761 | 2.500 | 4.30× |
| `sxhash-string-small` | hash | 30.488 | 2.750 | 11.1× |
| `sxhash-string-large` | hash | 0.596 | 65.752 | 0.0091× |
| `sxhash-fixnum` | hash | 8.167 | 4.500 | 1.81× |
| `slurp-lines` | gc | 1926.511 | 17.267 | 111.6× |
| `boehm-gc` | gc | 391.328 | 251.008 | 1.56× |
| `deflate-file` | misc | 4.755 | 0.180 | 26.4× |
| `1d-arrays` | sequence | 182.379 | 7.750 | 23.5× |
| `2d-arrays` | sequence | 21882.096 | 96.004 | 227.9× |
| `3d-arrays` | sequence | 超时 | 263.009 | — |
| `bitvectors` | sequence | 超时 | 41.668 | — |
| `bench-strings` | sequence | 1562.116 | 355.679 | 4.39× |
| `fill-strings/adjustable` | sequence | 8873.257 | 471.017 | 18.8× |
| `string-concat` | sequence | 超时 | 4552.162 | — |
| `search-sequence` | sequence | 2354.215 | 66.002 | 35.7× |
| `CLOS/defclass` | clos | 201.541 | 108.004 | 1.87× |
| `CLOS/defmethod` | clos | 175.302 | 189.507 | 0.93× |
| `CLOS/instantiate` | clos | 879.475 | 57.752 | 15.2× |
| `CLOS/simple-instantiate` | clos | 1.022 | 0.230 | 4.44× |
| `CLOS/methodcalls` | clos | 183.424 | 1066.038 | 0.17× |
| `CLOS/method+after` | clos | 208.829 | 89.803 | 2.33× |
| `CLOS/complex-methods` | clos | 30.376 | 22.401 | 1.36× |
| `eql-specialized-fib` | clos | 69.708 | 16.001 | 4.36× |

本轮差距最大的已完成项目为 `mandelbrot/dfloat`（430.1×）、
`bignum/elem-100-1000`（381.4×）、`fft`（324.0×）、`mrg32k3a`（292.5×）、
`2d-arrays`（227.9×）和 `puzzle`（200.8×）。`1d-arrays` 为 23.5×，
`search-sequence` 为 35.7×；一维访问和常量搜索特化的专项实验见下一节。
多维数组、大整数及部分浮点、流和序列操作仍有明显差距。

短项目需要结合总计时理解：SBCL 的 `mandelbrot/dfloat` 执行 100 轮，
总计时仅约 1 ms，因此其倍数只适合判断数量级。CLOS 项目包含运行期编译、
首次调用和缓存建立的成本；`CLOS/methodcalls` 在 SBCL 中只完成一轮、kiln
完成五轮，不能把本表直接当作预热后的泛函分派吞吐量。

`sxhash-string-large` 的输入是 4096 字符字符串。kiln 的字符串 `sxhash`
按默认预算只混入前 10 个字符及长度，因而本项耗时很低；这种采样策略不能代表
完整字符串遍历速度。相同前后缀、差异在中间的 `htable-string-fair` 在 kiln
中仍超时，说明散列分布与哈希表负载也需要一起考察。

### 库路径的成对测量

以下均使用 release runtime、固定 4 GiB 堆；表中每组只比较同一实验的前后版本。
单位为毫秒/轮，初始化和准备过程不计入数组基准时间。

| 实验 | 项目 | 基线 | 优化后 |
|---|---|---:|---:|
| SXHASH 原生路径 | fixnum | 127.487 | 7.327 |
| SXHASH 原生路径 | small string | 77.096 | 30.801 |
| SXHASH 原生路径 | large string | 3.425 | 0.856 |
| 一维数组存储访问特化 | FFT | 124.318 | 47.217 |
| 一维数组存储访问特化 | 1d-arrays | 747.859 | 289.411 |
| 一维数组存储访问特化 | 2d-arrays | 20097.209 | 20482.718 |
| 常量短模式 SEARCH 展开 | 1d-arrays | 275.857 | 185.287 |

SXHASH 使用 `BENCH_BUDGET=3`，每版两个进程、每进程每项四轮；large string
输入为该预算下的 64 字符工作负载。数组访问实验使用 `BENCH_BUDGET=10`，
每版两个进程，FFT、1d、2d 每进程分别为 30、4、1 轮。两组都按前、后、后、前
交替运行。一维特化改善了 FFT 和一维数组，二维数组未受益；二维项目样本较少，
1.9% 的时间差不足以认定回退。

SEARCH 实验使用 `BENCH_SELECT=1d-arrays BENCH_BUDGET=2`，预热后交替
取每版四个样本，范围为 271.432–279.639 ms 和 182.469–187.574 ms。
它比较通用原生序列路径与常量模式 `(4 5 6)` 展开，时间下降 32.8%，归因分配
从 48.18 MiB 降至 2.45 MiB。这说明保留数组事实能消除通用序列协议的成本，
适用范围仍受输入类型和模式是否已知约束。

### CLOS 调用

2026-11-09 的 [compare.lisp](../../bench/compare.lisp) AOT 测量取三次中位数：
单态泛函调用约 6.3 ns，三个类的多态调用约 9.3 ns，`call-next-method`
约 9.6 ns；同组 SBCL 的 `call-next-method` 约 9 ns。常量槽名的
`slot-value` 在调用点缓存实验中从 24.7 ns 降至 9.9 ns，与访问器方法的
10.4 ns 相近。这些结果适用于分派和槽访问路径，不能代表实例构造、初始化或
整个 CLOS 协议的成本。

### Benchmarks Game 的单线程程序

2026-11-12 使用仓库内的 Computer Language Benchmarks Game SBCL 提交，
选取单线程、无需 SBCL 专用底层接口的版本进行诊断规模对比。源码版本与固定
输入见 [bench/README.md](../../bench/README.md)，可用以下命令重现：

```sh
python3 tools/bench-game.py
```

机器、Rust 和 SBCL 版本与本节 cl-bench 扫描相同。kiln 使用 release runtime，
只链接 kernel、CLOS 和基准模块；SBCL 先用 `compile-file` 生成 FASL。
驱动只在生成的源码副本中将 SBCL 命令行参数访问替换为固定参数列表，再调用
`main`，保留算法和优化声明。kiln 固定 1 GiB SemiSpace 堆、1 GiB Lisp 栈；
SBCL 的 dynamic-space 上限为 8 GiB。

每项丢弃一对预热进程，再交替顺序测量三对独立进程，报告各实现墙钟中位数。
墙钟覆盖整个进程的启动、模块或 FASL 加载、计算和 I/O，不含编译与链接；
每个进程最多运行 30 秒。每对输出在计时结束后逐字节比较，只有输出一致的
项目才报告倍数。此处不是预热后的纯计算吞吐量，也不能与网站上的不同输入、
不同程序及并行版本的数字直接比较。

| 项目 | 输入 | kiln s | SBCL s | kiln/SBCL |
|---|---|---:|---:|---:|
| `binarytrees` | 深度 14 | 0.199463 | 0.069805 | 2.86× |
| `fannkuchredux` | n = 9 | 1.643583 | 0.034508 | 47.63× |
| `fasta` | n = 100000 | 7.448295 | 0.039877 | 186.78× |
| `pidigits` | 1000 位 | 8.032321 | 0.092739 | 86.61× |
| `spectralnorm` | n = 500 | 5.378219 | 0.044684 | 120.36× |

其余项目保留实际状态，不计入性能倍数：

| 项目 | 源码或输入 | 状态与原因 |
|---|---|---|
| `nbody` | `nbody.sbcl`，100000 步 | 编译失败：typed-vector `defstruct` 的位置构造器宏展开出现槽布局参数数目不匹配 |
| `knucleotide` | `knucleotide.sbcl-2.sbcl`，FASTA n = 100000 | 运行失败：源码用 `schar` 访问 `read-line` 的结果，kiln 返回的行字符串不是 simple-string，触发类型错误 |
| `revcomp` | `revcomp.sbcl`，FASTA n = 100000 | 编译失败：KIR 常量发射尚不支持 256 元素的 `(unsigned-byte 8)` 特化数组 |
| `mandelbrot` | 仓库内的 SBCL 版本 | 未测：依赖 SBCL VOP/SIMD 或底层线程接口 |
| `regexredux` | `regexredux.sbcl-4.sbcl` | 未测：依赖尚未接入 kiln 的 CL-PPCRE |

`knucleotide` 和 `revcomp` 的输入由 SBCL 的 FASTA 程序生成，两边使用相同的
文件字节。上述兼容性失败会使驱动在完成其他项目后以非零状态退出。

binary-trees 的差距相对较小；数组密集的 fannkuch-redux、浮点数组密集的
spectral-norm、字符串生成与输出的 FASTA，以及大整数 pi-digits 仍有明显差距。
这些项目没有剖析归因，因此不能单凭墙钟把差距归结为某一项前端优化缺失。

## 生成代码的专项测量

下列基准使用 Cranelift speed 优化、release runtime 和固定 4 GiB 堆，前后源码
一致。每个实验独立交替测量，硬件事件没有复用。指令数单位为百万条，分配单位
为 MiB；“未命中”表示分配采样器没有记录到该基准的样本。

| 基准及优化边界 | 指令：基线 → 优化后 | 分配：基线 → 优化后 |
|---|---:|---:|
| [double-tree](../../bench/double-tree.lisp)：表达式内双精度拆箱 | 1861.9 → 43.324 | 45.78 → 15.28 |
| double-tree：在表达式拆箱基础上保留局部原始双精度值 | 43.324 → 23.000 | 15.28 → 未命中 |
| [scalar-cons](../../bench/scalar-cons.lisp)：字段访问型 cons 标量替换 | 73.989 → 22.000 | 22.90 → 未命中 |
| [static-recursive-functions](../../bench/static-recursive-functions.lisp)：无捕获递归函数的静态环境 | 158.977 → 117.000 | 45.80 → 未命中 |
| [lifted-local-functions](../../bench/lifted-local-functions.lisp)：固定参数局部函数提升 | 367.618 → 292.000 | 76.29 → 未命中 |
| [lifted-optional-functions](../../bench/lifted-optional-functions.lisp)：可选参数局部函数提升 | 176.987 → 152.000 | 22.90 → 未命中 |
| [function-alias-calls](../../bench/function-alias-calls.lisp)：不可变函数别名的直接调用 | 329.973 → 198.000 | 45.77 → 未命中 |

双精度基准执行百万次稳定递推 `(+ (* value .5d0) (* value .5d0))`，初值为
`1.25d0`。表达式拆箱消除中间运算的装箱；局部值拆箱进一步消除循环更新的
装箱，返回时仍需一个 16 字节浮点对象。该结果适用于未捕获、声明为双精度的
局部变量，不能外推到参数、捕获变量或通用数值路径。

cons 基准访问可证明不逃逸对象的字段。标量替换依赖别名、赋值和捕获分析；
被保存到堆中、交给未知回调或被闭包捕获的对象仍需保留可观察的对象身份。

静态递归环境基准保留每轮两次调用及函数身份检查。固定参数提升基准则以互相
递归的两个局部函数共享可写计数 cell 和迭代偏移量，每轮四次调用；提升后共享
cell 仍存在，收益来自避免每轮构造函数环境。可选参数基准覆盖默认值和显式
传参两条递归路径，不测量消除 rest 列表或关键字解析的收益。

函数别名基准分别运行命名函数和匿名 lambda 的百万次循环，每轮经两级不可变
别名调用两次。局部函数保持独立入口；直接调用同时启用参数、返回值摘要和整数
特化，所以收益包含调用、类型传播及闭包分配消除。周期中位数从 68.718 百万降
至 34.362 百万，范围分别为 68.540–69.108 百万和 34.077–34.536 百万。
赋值过的函数变量、控制流合并后的函数身份和未知目标的高阶调用不在该实验范围。

这些基准有意隔离特定代码模式，指令和分配的大幅减少说明优化机制有效；实际
程序还包含类型未知的路径、库调用和其他工作，收益需由应用基准单独确认。

## GC

本节保留分配清理前的历史编译工作负载，用于说明对象寿命和 SemiSpace 的复制
成本。它分配约 250 GB，和上文约 7 秒的六模块编译不是同一工作负载，不能据此
预测当前编译的 GC 占比或分代收益。

测量使用 kiln0 编译五个模块、固定 8 GiB SemiSpace 堆（每半区 4 GiB）、八个
GC 线程和 dev runtime；MMTk 为 opt-level 2，关闭 debug assertions。
机器另有负载，墙钟在 380–460 秒波动，因此主要比较 GC 自身的量。

| 指标 | 测量值 |
|---|---:|
| 分配总量 | 255,560 MiB |
| 回收次数 | 66 |
| 回收后存活量 | 平均 490 MiB，最大 1.24 GiB |
| 复制总量 | 约 32 GB |
| 总停顿 | 31–39 s |
| GC worker CPU 时间 | 89–109 s |
| static root 数量 | 108,401 |
| 峰值 RSS | 约 9.9 GB |

`KILN_GC_AGES=1` 的年龄归因显示，上次回收后新分配对象的复制量约为 2.2 GB，
重复复制老对象约为 28.5 GB，占归因复制量的 93%。kernel 加 CLOS 的对照中，
将回收间隔从约 4 GiB 缩至 256 MiB，新对象复制量仅从 809 MiB 变为 842 MiB。
这支持临时对象寿命很短的判断，是考虑分代收集的依据。具体设计见
[GC](../design/gc.md)，尚不能把复制量的下降直接换算为已实现的分代加速比。

| GC 线程数 | 总停顿 | worker CPU |
|---|---:|---:|
| 4 | 36.8 s | 93 s |
| 8 | 31–39 s | 89–109 s |
| 16 | 35.5 s | 118 s |

增加线程没有显示稳定的停顿收益，指针链限制了可并行工作。固定堆增至 12 GiB
时，回收次数为 42，总停顿 25.4 s，worker CPU 为 71 s，峰值 RSS 增至
14.8 GB。这个工作负载中，扩大堆以更多内存换取较少的重复复制。

## 启动、快照和体积

以下是 2026-11 较早加载配置的测量，表示模块初始化与快照映射的差别。

| 程序 | 正常启动 | 从快照启动 | 快照大小 |
|---|---:|---:|---:|
| kernel + CLOS | 0.23 s | 0.04 s | 3.4 MB |
| kernel + CLOS + 前端 + eval + 编译器 | 0.74 s | 0.10 s | 8.9 MB |

时间包括测试程序本身和两次原生 `compile`。快照通过私有、写时复制的 `mmap`
映射；完整编译会话的堆内容更多，不能用这里的快照大小估算，例如编译测试使用
的编译器快照约 360 MB。

同一时期 strip 后的可执行文件，kernel 加 CLOS 为 26 MB，加编译器为 69 MB；
含调试信息的 kiln1 为 77 MB。约 8 MB 的差额包含函数记录、调用点数据和调试
信息对象。这些体积取决于加载内容及元数据配置，交付时的裁剪需另行测量。
