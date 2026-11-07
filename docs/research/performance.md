# 性能测量

**日期**：2026-11。数字是当时的测量，不随代码更新；同一张表里的前后对比是在同一台机器上测的。要做的优化见 [roadmap.md](../roadmap.md) 的“性能”。

结论：kiln 生成的基础代码（调用、闭包、fixnum 算术、控制流）已经和 SBCL 相当，差距在 Lisp 语义层：库的通用实现、CLOS 的运行时（解释执行的有效方法、完整的初始化协议、运行期定义类和方法）、`&rest`/`&key` 的分配、浮点装箱和 bignum、多维数组。SBCL 快在它的前端（Lisp 语义层的变换和类型推导），而不是通用中端。

## 测量方法

`bench/compare.lisp` 是一组可移植的 CL 代码，在 kiln 和 SBCL 上运行同样的操作，输出每次操作的纳秒数：
- kiln：复制成 `clos-*.lisp` 交给 `tools/test.sh`，取 AOT 的输出；
- SBCL：`sbcl --script bench/compare.lisp`，默认优化级别，没有类型声明。

几纳秒的项目只能看数量级，SBCL 那边的计时器分辨率是微秒。

剖析的工具：
- kiln 自己的采样分析器和分配分析器（`KILN_PROFILE`，[debugging.md](../design/debugging.md) 的“性能分析器”）；`KILN_FUNCTION_MAP` 给 perf 报告的 AOT 函数换上 Lisp 的名字。
- perf：`kernel.perf_event_paranoid` 为 2 时，只有软件事件（`-e cpu-clock`）能用；设为 1 后，硬件事件和 `-g` 都能用。kiln 的 AOT 代码有帧指针，`perf report --children` 能给出包含时间。
- kiln-cg 的 JIT 设了 `KILN_PERF_MAP=1` 时写出 perf map，perf 能显示 JIT 函数的名字。
- AOT 程序有帧指针，gdb 能回溯。每次 attach 一次 gdb 抽一个调用栈；在同一次 gdb 会话里连续抽样时，进程一直停着，得到的其实是同一个瞬间。
- 函数的标签带名字（[lowering.md](../design/lowering.md)）；标签里没有名字的，从 KIR 里“把哪个函数对象存进哪个符号”可以对回全局函数名。

## 和 SBCL 的对比（`bench/compare.lisp`）

### 编译器生成的基础代码：和 SBCL 持平

| 操作 | kiln (ns) | SBCL (ns) | 倍数 |
|---|---|---|---|
| 普通调用（1 个参数） | 2.4 | 2 | 1.2× |
| `&optional` 调用 | 3.5 | 4 | 0.9× |
| 闭包调用 | 3.9 | 4 | 1.0× |
| 特殊变量绑定 | 3.8 | 3 | 1.3× |
| `cons` | 3.2 | 3 | 1.1× |
| 未声明类型的 `+`（fixnum） | 3.0 | 3 | 1.0× |
| `fib 20` | 52 µs | 75 µs | 0.7× |
| fixnum 求和循环（1000 次） | 1.6 µs | 3.0 µs | 0.5× |

调用约定、寄存器分配、fixnum 算术和控制流已经和 SBCL 相当。GVN、LICM 这类通用的 SSA 优化 Cranelift 已经在做，再加一层通用中端，改变不了这里的数字，也解决不了下面的差距。

### 库和运行时：差距所在

| 操作 | kiln (ns) | SBCL (ns) | 倍数 | 原因 |
|---|---|---|---|---|
| `(format nil "~a" i)` | 13373 | 30 | 446× | Invistra、Incless 每一步都是泛函，每个字符经过 Gray stream 协议 |
| `princ-to-string` 一个 fixnum | 11816 | 30 | 394× | 同上 |
| `find` 一个字符（100 个字符的字符串） | 2290 | 10 | 229× | 序列函数的通用实现：每次解析关键字参数，逐元素经 `funcall` 比较（原文写作 Consecution，但 Consecution 还没有接入，是 kernel 的 `sequences.lisp`） |
| `make-instance`（2 个 initarg） | 1189 | 10 | 119× | 每次都按 initarg 走完整的初始化协议；SBCL 有预编译的构造器（PCL 的 ctor）。kiln 只缓存了初始化计划 |
| `defstruct` 的构造函数 | 546 | 7 | 78× | 本该是一次分配加几次写入，现在走 CLOS 实例的路径 |
| `read-from-string` | 43401 | 400 | 109× | Eclector 加 CLOS 流 |
| 双精度浮点求和（1000 次） | 203 µs | 7 µs | 29× | 每次运算都装箱，再经 `kiln_rt_number_op` 进 Rust；SBCL 也装箱，但运算是内联的 |
| `member :test #'equal` | 306 | 13 | 24× | 带关键字时走通用路径（不带关键字的已经改成两个参数的专用函数） |
| `typep x '(integer 0 10)` | 13.6 | 1 | 14× | 运行期解释类型说明符；SBCL 在编译期展开成比较 |
| `intern` 已有的符号 | 338 | 30 | 11× | Parcl 的协议层 |
| `call-next-method` | 98 | 9 | 11× | 有效方法是解释执行的闭包，每次分配参数列表 |
| `handler-case`（不发出信号） | 73 | 9 | 8× | 建立 handler 要在堆上分配；SBCL 在栈上 |
| `sort` 20 个 fixnum | 2922 | 440 | 6.6× | 序列函数的通用实现，比较函数经 `funcall` |
| `&key` 调用（1 个关键字） | 31 | 5 | 6.2× | 运行期扫描关键字列表 |
| `gethash` / `(setf gethash)`（eq） | 19 / 21 | 3 / 5 | 4–6× | Salmagundi 的协议层（泛函、客户端对象） |
| `gethash`（equal，字符串键） | 85 | 21 | 4.0× | 同上 |
| 泛函调用（单态 / 3 个类的多态） | 14 / 22 | 5 / 5 | 3–4× | 分派闭包和缓存表 |
| `slot-value` / 访问器 | 22 / 11 | 5 / 4 | 3–5× | 按槽位置的缓存，没有内联到调用点 |
| `catch`/`throw` | 34 | 7 | 4.9× | |
| `&rest`（3 个参数） | 39 | 24 | 1.6× | |
| `defstruct` 的访问器 | 3.4 | 2 | 1.7× | |

自举时编译器主要在做上表后半部分的事：泛函分派、槽访问、`make-instance`、哈希表、`&rest`、`&key`（见下文自举的 profile）。kiln 编译自己比 SBCL 慢 6 倍左右，原因就在这里。GC 占的约 13%，也主要来自这些地方的分配：`&rest` 列表、浮点装箱、初始化时的 initarg 列表、堆上的 handler。所以只换 GC 解决不了根本问题。

## cl-bench

`tools/bench.sh` 在 kiln（AOT，五个模块，release 版的 runtime）和 SBCL（`sbcl --script`，默认优化级别）上运行 cl-bench（`bench/README.md`），每项至多运行 2 秒；kiln 上每项单独一个进程，超时 120 秒。毫秒每次：

| 组 | 项目 | kiln | SBCL | 倍数 |
|---|---|---|---|---|
| 调用和控制流 | tak / trtak / takl | 0.15 / 0.15 / 1.14 | 0.11 / 0.12 / 0.79 | 1.3–1.4× |
| | fib | 0.60 | 0.76 | 0.8× |
| | ackermann | 769 | 649 | 1.2× |
| | richards | 52 | 38 | 1.4× |
| | stak（特殊变量） | 0.69 | 0.38 | 1.8× |
| | ctak（`catch`/`throw`） | 0.48 | 0.08 | 5.7× |
| cons 和符号 | boyer / deriv / dderiv | 5.6 / 3.0 / 3.3 | 3.9 / 1.8 / 1.9 | 1.5–1.7× |
| | destructive / div2 | 1.5 / 1.3–1.5 | 0.6 / 0.9–1.1 | 1.3–2.7× |
| | traverse / triangle | 37 / 52 | 13 / 23 | 2.2–2.9× |
| | sum-permutations | 267 | 31 | 8.7× |
| 浮点 | fft | 110 | 0.13 | 826× |
| | mandelbrot/dfloat | 6.9 | 0.010 | 691× |
| | frpoly/float | 10.8 | 0.93 | 12× |
| 数组 | puzzle | 120 | 0.71 | 168× |
| | 1d / 2d / 3d-arrays | 556 / 21143 / 61517 | 7.5 / 92 / 256 | 74–240× |
| bignum 和有理数 | bignum/elem-100-1000 / 1000-100 | 4325 / 66578 | 20 / 21 | 222× / 3216× |
| | bignum/elem-10000-1 | 超时 | 12 | — |
| | pari / pi-decimal / pi-atan | 95–2581 | 0.6–25 | 32–103× |
| | fib-ratio / pi-ratios | 0.39 / 407 | 0.006 / 190 | 65× / 2.1× |
| | crc40（40 位整数） | 191 | 78 | 2.5× |
| 打印和流 | fprint/ugly / pretty | 50 / 107 | 0.38 / 1.7 | 133× / 62× |
| | slurp-lines（`read-line`） | 5177 | 17 | 303× |
| | deflate-file | 16 | 0.18 | 90× |
| 字符串 | bench-strings / fill-strings/adjustable | 5532 / 17472 | 340 / 483 | 16× / 36× |
| | string-concat（`with-output-to-string`） | 超时 | 4594 | — |
| GC | boehm-gc | 3980 | 256 | 16× |
| CLOS | simple-instantiate | 8.1 | 0.22 | 37× |
| | eql-specialized-fib | 114 | 16 | 7× |

结论：
- **调用、控制流、cons、符号**和 SBCL 在同一个量级（1.3–2.9×），和上面的对比一致。例外是 `catch`/`throw`（5.7×，和上表的 4.9× 相符）。
- **数值是最大的差距**：浮点每次运算都装箱，再进 Rust；bignum 慢到两三千倍，乘除法的算法和实现要整个重看；多维数组走 Regalia 的通用路径。
- **打印、读行、字符串流**慢一到两个数量级，原因同上表。

**补上 ANSI 缺口之后**（2026-11：`random`、`gentemp`、complex、位数组运算、`search` 的全部关键字、类的重定义、栈耗尽的 `storage-condition`）新跑起来的项目：

| 组 | 项目 | kiln | SBCL | 倍数 |
|---|---|---|---|---|
| gabriel | browse | 23 | 4.9 | 4.7× |
| 数值 | mandelbrot/complex | 21 | 0.89 | 23× |
| | mrg32k3a（double 运算） | 1462 | 5.2 | 281× |
| 哈希表 | htable-mixbag / fixnum / equalp-numbers / sparse | 52 / 691 / 27 / 4.1 | 32 / 89 / 3.5 / 0.75 | 1.6–7.7× |
| | htable-string-small / large / set+remove | 52 / 40 / 35 | 4.3 / 1.3 / 1.5 | 12–32× |
| | htable-string-fair | 超时 | 149 | — |
| | sxhash-string-small / sxhash-fixnum | 152 / 455 | 2.3 / 4.8 | 67× / 96× |
| | sxhash-string-large | 7.4 | 59 | 0.1×（kiln 只哈希前 64 个字符） |
| 序列 | bitvectors（位数组运算逐位 `row-major-aref`） | 超时 | 40 | — |
| | search-sequence（`search` 逐个 `elt`） | 106914 | 62 | 1724× |
| CLOS | defclass / defmethod（运行期 `compile`） | 872 / 1733 | 98 / 183 | 9× |
| | instantiate / method+after | 2009 / 755 | 51 / 83 | 39× / 9× |
| | methodcalls / complex-methods | 211 / 18 | 205 / 20 | 1.0× / 0.9× |

- CLOS 的泛函调用（methodcalls、complex-methods）已经和 SBCL 持平，判别闭包的缓存表起了作用（[clos.md](../design/clos.md)）；`make-instance`（instantiate、simple-instantiate 30–40×）和定义类、方法（运行期编译）是差距所在，对应 [roadmap.md](../roadmap.md) 性能计划的第 3 项。
- `sxhash` 和字符串键的哈希表慢在哈希函数本身：`sxhash` 走 Salmagundi 的累加闭包（这之后哈希表本身改成了开放寻址，见下文“自举的速度”），没有 `equal-hash` 那样的快路径。
- bitvectors、search-sequence 是新补的函数用了最朴素的实现，属于性能计划里调用点变换和库快速路径的工作。
- CLOS 组的后几项依赖前面几项定义的类和方法（cl-bench 在同一个 image 里按顺序运行），`tools/bench.sh` 让它们在同一个进程里先运行前面的项目。
- 递归很深的 walk-list/mess 仍要 1 GiB 的栈；栈不够时现在发出 `kiln.sys:stack-exhausted`。SBCL 跳过这一项。
- compiler、load-fasl 需要 `compile-file`，harness 不运行。

## 自举的速度

kiln 编译自己的五个模块（一个阶段，见 [bootstrap.md](../design/bootstrap.md)）：

| 时间点 | 一个阶段 | 说明 |
|---|---|---|
| kernel 的交叉编译刚能在 kiln 上跑 | kernel 超过一小时 | Clostrophilia 未命中时重建整个自动机（N³），packrat 的 `parse` 在运行期重新解析和编译，输出不缓冲 |
| 修完上面三处 | kernel 38 秒 | |
| 哈希表、分派单项缓存、GC 设置 | kernel 17 秒，kernel 加 CLOS 约 7.7 分钟（JIT） | SBCL：kernel 1.8 秒，CLOS 25.6 秒 |
| 五个模块第一次都能编 | 约 40 分钟（五个模块合计） | co-clos 约 7 分钟，co-compiler 约 15 分钟（8 GiB 堆） |
| 第一次完整 profile | 845 秒 | |
| 第一轮优化（`if` 直接分支、闭包变量用到时再读、Iconoclast 的 `set-slot`、初始化计划、类名 `typep` 缓存、`member`/`assoc`、`logand` 等） | 525 秒 | CLOS 模块约 268 → 148 秒；完整自举约 30 → 19 分钟 |
| 第二轮（判别闭包的缓存表、`slot-value` 和类名 `typep` 的全局缓存、名字不用 `format` 生成、文件流批量写入） | 321 秒 | kernel 7 秒、CLOS 88 秒、frontend 3 秒、eval 28 秒、compiler 193 秒；完整自举约 12 分钟。SBCL 编同样的五个模块约 50 秒，kiln 慢 6 倍左右（最初是 11 倍） |
| 加上调试信息 | 339 秒 | 生成的代码不变，没有变慢 |
| 依赖追踪（M6.4）、cl-bench 那一批 ANSI 补全和函数入口的栈检查之后 | 365 秒 | 这期间没有单独计时，三者各占多少不清楚 |
| 性能第一批：静态对象的身份哈希写进 header（`%slot` 缓存给槽名做哈希，原来每次进 runtime）、EQL 分派命中移到表头、Iconoclast 的 walker 按类的计划遍历且只在子节点变了时写槽、Salmagundi 的桶数取 2 的幂 | 314 秒 | 定位用的是 `KILN_FUNCTION_MAP` 加 perf |
| 性能第二批：`make-instance` 的快路径 | 306 秒 | |
| 性能第三批：`call-next-method` 按缓存的槽位置读方法函数、单参数泛函的缓存项直接读槽、哈希表改成开放寻址、`replace` 直接复制向量 | 293 秒 | SBCL 编同样的五个模块约 50 秒 |
| `typep` 按 stamp 缓存只取决于类的答案（`or`、`and`、`not` 和非常量的类名，不只是常量类名的调用点） | 改动前后背靠背 367 → 341 秒（约 −7%） | 机器上同时有别的任务（负载 4–7），绝对值比上一行慢，只能看前后之比（同一次完整自举里 stage1 406 秒、stage2 312 秒，做的是同样的事，可见噪声之大）。profile 里 `typep` 一族（包含时间）从约 14% 降到约 3%，原来 11% 来自 Iconoclast walker 的 `(typep ast '(or ...))`；一次命中的 `typep` 约 18–26 ns，原来 `or` 约 90 ns |
| AST 和 KIR：降级前对每个顶层形式只遍历一次 AST，记下被 `setq` 的变量、被嵌套函数退出的 `block`/`tagbody`、静态环境大小和 `load-time-value`（原来每个 `let` 绑定都重新遍历它的作用域）；Iconoclast 的 `compute-ast-info` 五次遍历并成一次；AST 子节点按类的计划取、遍历不用哈希表；KIR 的变量、块和槽用简单向量而不是每个名字 intern 一个关键字；打印 KIR 时各个形式共用一个字符串 | 334 → 228 秒 | 同一时段在同一台机器上前后对比（机器上有别的负载，墙钟时间有 ±5% 的波动），用户态指令数少了 39%（5.33 → 3.23 万亿）。分开看：一次遍历 −31%，子节点计划 −0.7%，KIR 名字 −3.8%（试过 defstruct，比关键字还慢），共用打印字符串 −8.4% |
| 性能第四批（和上面两行同时开发）：符号的静态数据名按模块缓存、`mangle` 对不用转义的名字原样返回；单下标的 `aref` 对字符串也内联，慢路径不再建 `&rest` 列表；POSIX 文件流的 `write-string` 分块编码；字符串输出流写字符不再经过 `(setf stream-file-position)` 的方法，并有自己的 `write-string`；`replace` 经由可调整向量的原生存储复制 | 约 310 → 249 秒 | 单独测的（kiln0，机器较空） |
| 有效方法按展开的参数调用：标准方法组合的 `progn`、`multiple-value-prog1`、`call-method`、`make-method` 由有 fast function 的方法组成时，变成接受展开参数的闭包（原来只有单独一个 `call-method` 才行，一个具体方法加一个默认方法就要把参数建成列表、解释执行有效方法） | 和下一行一起测 | |
| 上面四项合并之后，再加 GC 统计和去掉 `kiln_rt_alloc` 的重复清零（统一测量，机器空闲） | **125 秒** | 各模块：kernel 3.7 秒、CLOS 40.7 秒、frontend 1.6 秒、eval 12.4 秒、compiler 66.2 秒。SBCL 编同样的五个模块 47.5 秒（kernel 1.1、CLOS 12.6、frontend 0.4、eval 4.0、compiler 29.4），差距约 2.6 倍（本轮开始时约 6.8 倍）。GC：24 次回收，停顿 7.3 秒（墙钟的 5.8%），分配 99 GB，复制 6.3 GB，GC 线程 18 秒（CPU 的 13%） |

845 秒那次的 profile（按模块统计自身时间）：

| 部分 | 占比 |
|---|---|
| clos 模块（分派、slot 访问、实例初始化、哈希表） | 约 45% |
| kernel 模块（`member`、`typep`、`logand` 等） | 约 27% |
| GC（MMTk 工作线程） | 约 17% |
| compiler 模块自己的代码 | 约 3% |
| Maclina 的字节码 VM | 约 1%（包含时间 14%，几乎都是它调用的原生函数：parser.packrat 的规则） |

所以换成原生 `compile` 几乎不会让自举变快：字节码只是一层很薄的胶水。HIR 求值器的参数解析器改用原生编译后，一个阶段反而从 321 秒变成 357 秒（每个只运行几次，编译时间占主导）。

321 秒之后剩下的热点（CLOS 阶段）：GC 约 13%；kernel 的函数约 21%，比较分散；Salmagundi 哈希表约 5%；`append` 方法组合（Iconoclast 的 `slot-designators`，walker 每访问一个节点调用一次）约 5%；`&rest` 泛函每次调用分配参数列表。

其他观察：
- 试过 Immix（`MMTK_PLAN=Immix`）：比 SemiSpace 慢约 5%。
- MMTk 的 debug assertions 检查每次 side metadata 访问，GC 曾占约三分之一的时间，dev 构建里对 mmtk 关掉了。
- compiler 模块在 2 GiB 堆（SemiSpace，可用一半）下跑了 51 分钟后内存不足：存活数据接近半堆时几乎一直在 GC。
- kiln0：`kiln-cg` 编六个 KIR 约 15 秒，峰值内存约 9.5 GB；可执行文件约 120 MB；启动（各模块的顶层初始化）约 0.65 秒。stage1 峰值 RSS 约 9 GB（8 GiB 堆）。
- kiln 上编 `co-compile`（约 100 行）：最初 AOT 程序连启动 12 秒（SBCL 不到 1 秒），修掉自动机重建等之后 2.3 秒。

## GC

kiln0 编译五个模块（一个自举阶段），SemiSpace，固定 8 GiB 堆（每个半区 4 GiB），GC 线程 8 个，debug 构建的 runtime（MMTk 是 opt-level 2、关掉 debug assertions），`KILN_GC_STATS`（[gc.md](../design/gc.md)）。测量时机器上还有别的任务在跑（load 4–18），同一个程序的墙钟时间在 380–460 秒之间波动，所以下面只比较 GC 自己的量；单次运行里 mutator 时间的差别看不出 3% 以下的变化。

### 基本数字

| 量 | 值 |
|---|---|
| 回收次数 | 66 |
| 分配总量 | 约 250 GB（255 560 MiB），约 600 MB/s |
| 每次回收后的存活量 | 平均 490 MiB，最多 1.24 GiB；kernel 和 CLOS 阶段 30–700 MiB，编译 compiler 模块时从 100 MiB 涨到 1.2 GiB |
| 复制总量 | 32 GB，分配量的 12.7% |
| 停顿 | 合计 31–39 秒（三次运行；墙钟的 8.5–9%），平均 0.46–0.59 秒，最长 2.2–2.8 秒 |
| GC worker 的 CPU | 89–109 秒，整个进程 CPU 的 21–23%（perf 的采样也是 21.5%） |
| static root | 108 401 个 |
| 峰值 RSS | 约 10 GB |

停顿和存活量成正比，约 1.1 秒每 GB：存活 100 MiB 时 0.19 秒，500 MiB 时约 0.9 秒，1.2 GiB 时 1.6 秒，个别回收到 3 秒。

### 复制的几乎全是老对象

`KILN_GC_AGES=1` 把每次复制的字节分成“上次回收之后分配的”（young，nursery GC 要复制的）和“上次回收复制过的”（old，分代 plan 不再复制的）：

| 运行 | 回收间隔 | 回收次数 | young | old |
|---|---|---|---|---|
| 五个模块 | 约 4 GiB | 66 | 2.2 GB | 28.5 GB（93%） |
| kernel 加 CLOS | 约 4 GiB | 18 | 809 MiB | 4.1 GB |
| kernel 加 CLOS，每分配 256 MiB 回收一次（`MMTK_STRESS_FACTOR`） | 256 MiB | 282 | 842 MiB | 72.8 GB |

新分配的对象只有约 1.1% 活过下一次回收，而且回收间隔从 4 GiB 缩到 256 MiB 时这个比例几乎不变（809 → 842 MiB）：编译器的临时对象寿命远短于 256 MiB 的分配量。所以 256 MiB 的 nursery 在整个自举里大约复制 2.5 GB（每次约 3 MB），而 SemiSpace 复制了 32 GB。

**分代的估计**：nursery GC 按现在的复制速度约 1.1 秒每 GB，晋升约 2.5 GB 合计约 3 秒；每次 nursery GC 还要扫描栈和 10 万个 static root，约 1000 次合计 1–2 秒；mature 空间涨到 1.2 GiB，8 GiB 堆里只需要几次 full GC，每次约 1–1.5 秒。合计 6–9 秒，现在是 31–39 秒，墙钟省约 25–30 秒（7% 左右），GC worker 的 CPU 省约 80 秒。写屏障要还回去 mutator 的 1–3%（4–11 秒）。净收益约为墙钟的 4–6%，GenImmix 还能把同样的堆的可用空间翻倍、RSS 降下来。设计见 [gc.md](../design/gc.md) 的“Generational GC plan”。

### GC 的并行度

| GC 线程 | 停顿 | worker CPU |
|---|---|---|
| 4 | 36.8 秒 | 93 秒 |
| 8（默认） | 31–39 秒 | 89–109 秒 |
| 16 | 35.5 秒 | 118 秒 |

线程数几乎不影响停顿：8 个线程时平均只有约 3 个在干活。按 20 毫秒分段统计 perf 样本里同时出现的 worker 数：只有 1 个 worker 的段 739 个，2 个 540，3 个 305，4–7 个合计 69，8 个全忙 531。只有一个 worker 的时段里，热点和全忙时一样（`trace_object`、side metadata、复制），不是调度开销，而是可做的工作窄：链表这种只能顺着一条指针链走的结构。试过：
- root 分包（static root 原来一个包十万个槽）：停顿不变（33.9 秒），说明瓶颈不在 root。保留了这个改动，它本身没有坏处。
- 把 MMTk worker 的本地缓存包数从 16 改成 1（强制把新包放进全局队列，唤醒空闲 worker）：停顿翻倍。不过所有改过 MMTk 源码的构建（用 `[patch]` 指向 MMTk 的副本）停顿都约 59 秒，连只改清零的那个也是，所以这个对比不可信，原因没查。

结论：GC 线程数没有可调的收益，4 个线程省约 10% 的 GC CPU、停顿略长。默认值不变。

### GC 时间花在哪里（perf，worker 的样本）

side metadata 的地址计算和读写（forwarding bits）约占 worker 时间的 25%，`trace_object` 14%，`copy` 7%，写 forwarding 指针时 MMTk 用 CAS 循环更新整个 header 字（`fetch_update`）约 7%，bump 分配约 5%，`object_bytes` 3%。forwarding bits 放在 side metadata 是因为 header 的低字节是 kind；如果像 roadmap 里无 header cons 的方案那样给 header 的低 3 位留出保留 tag，forwarding bits 就能放进 header，省掉这部分的大半。

### 清零

- MMTk 的空间取得新页时清零（kiln 用到的 plan 都写死了 `zeroed = true`），这是 mutator 线程上的 `memset`：约 1.9% 的样本（250 GB 的分配全部清零一遍），GC worker 上还有 0.6%（GC 复制的目标块也先清零，完全白做）。
- `kiln_rt_alloc` 原来在 MMTk 已经清零的内存上再清零一遍（不经内联快路径的分配：变长向量、大于 128 字节的对象）。去掉了；它在 perf 里只占 0.1% 左右，墙钟上量不出来。编译出的代码的内联快路径也逐字写零，同样多余（`lisp/lower.lisp` 的 `emit-alloc`），可以去掉。
- 反过来做（MMTk 不清零、只靠 kiln 自己清零）要改 MMTk 的 SemiSpace，收益估计是 CPU 的 2.5%、mutator 时间的约 2.4%。不值得为此维护 MMTk 的分支；换分代 plan 时 nursery 同样写死清零，到时候再看。

### 堆大小和触发策略

| 堆 | 回收次数 | 停顿 | worker CPU | 峰值 RSS |
|---|---|---|---|---|
| 固定 8 GiB | 66 | 31–39 秒 | 89–109 秒 | 9.9 GB |
| 固定 12 GiB | 42 | 25.4 秒 | 71 秒 | 14.8 GB |

SemiSpace 的 GC 时间约等于“回收次数 × 平均存活量”，堆加大一半，回收少三分之一，停顿省约 10 秒（墙钟 2.5%），代价是多 5 GB 内存。自举的默认堆（`KILN_BOOT_HEAP`）不变：分代 plan 会让堆大小不再重要。

### release 构建的 runtime

紧挨着跑的两次（load 约 2–3）：debug runtime 停顿 30.6 秒、worker CPU 89 秒、墙钟 344 秒；release runtime（`cargo build --release`，像 `tools/bench.sh` 那样链接）停顿 30.5 秒、worker CPU 88 秒、墙钟 333 秒。GC 的数字一样：dev 构建里 MMTk 和 kiln-rt 本来就是 opt-level 2，MMTk 的 debug assertions 也关了。墙钟差的 11 秒在 mutator 一侧（runtime 函数、debug assertions），在这台机器的噪声范围内。

## 读入的基准（`bench/fe-read.lisp`）

在 kiln（JIT）和 SBCL 上用同一份 Eclector 代码把 `lisp/target/kernel.lisp`（891 行，307 个形式）读一遍，单位毫秒（`tools/bench-fe-read.sh`）：

| 阶段 | `read` | CST 读取 | `read-line` |
|---|---|---|---|
| 开始 | 9379 | 9964 | 1441 |
| 自动机二分查找不再调用 runtime 的 `floor` | 4228 | 4559 | 545 |
| 哈希函数和 `subtypep` 的快速路径 | 3902 | 4119 | 230 |
| runtime 的分配快速路径 | 2229 | 2360 | 177 |
| EQL 特化调用的有效方法缓存 | 664 | 807 | 178 |
| `svref`/`length` 内联，自动机转移内联 | 493 | 615 | 131 |
| 展开调用的判别函数和快速方法函数 | 363 | 460 | 106 |
| 判别函数里的 EQL 缓存 | 161 | 253 | 108 |
| 内联分配，GC 扫描改为判断地址范围，256 MiB 堆 | 135 | 205 | 100 |
| inline 声明，`eql` 原语少调用 kernel | 120 | 187 | 68 |
| SBCL（同一份 Eclector；`read` 是 SBCL 自己的） | 0.7 | 6.3 | 0.0 |

最后 CST 读取约是 SBCL 的 30 倍，开始时是 1600 倍。在 493 ms 那一步的 profile 里，Lisp 代码约 55%（其中分派约 25%），GC 和分配约 37%。

CST 读取的耗时随堆大小（SemiSpace）：64 MiB 227 ms，256 MiB 203 ms，1 GiB 239 ms（首次访问新页面的缺页和清零抵消了 GC 次数减少的收益），`DynamicHeapSize`（32 MiB 到 4 GiB）261 ms。后来自举的存活数据变大，默认堆改成了 1 GiB。

## 泛函调用（`bench/gf.lisp`）

单次调用，微秒。“之前”是判别函数只按列表调用、EQL 特化每次重算的时候，“之后”是展开调用和 EQL 缓存（[clos.md](../design/clos.md)）：

| 调用（µs） | 之前 | 之后 |
|---|---|---|
| 普通函数 | 0.003 | 0.003 |
| 1 个参数，按类分派 | 0.089 | 0.037 |
| 1 个参数，fixnum | 0.128 | 0.039 |
| 2 个参数 | 0.107 | 0.035 |
| 读取器 / 写入器 | 0.035 / 0.046 | 0.020 / 0.022 |
| `call-next-method` | 0.128 | 0.112 |
| `:around` 加 `:before` | 0.203 | 0.153 |
| `&key` | 0.268 | 0.209 |
| EQL 特化 | 1.904 | 0.043 |

读一遍 `kernel.lisp`，`state-value` 原来有 42856 次未命中，现在是 0（`bench/gf-misses.lisp`）。`make-instance` 从 2.1 µs 降到约 1.0 µs（inline 声明、初始化计划）。

## 字节码 VM（Maclina）

`(fib 25)` 在 REPL 里由字节码执行（AOT 可执行文件），SBCL 的编译代码约 1 毫秒：

| 改动 | 秒 |
|---|---|
| eval 模块刚完成时 | 5.70 |
| 字节码存成 simple vector（原来是 Regalia 的 `(unsigned-byte 8)` 数组，`aref` 要经过几层泛函和 `typep`） | 1.90 |
| 结构的访问器不再是泛函 | 1.27 |
| `ash` 的 fixnum 快速路径 | 1.18 |
| `ceiling`、`round` 的 fixnum 快速路径（`(loop repeat n)` 用到 `ceiling`） | 0.81 |
| 访问器是 inline 函数，槽位置是常量 | 0.70 |
| `(eql x 常量)` 按 `eq` 降级；一个下标的 `aref` 就地读写 | 0.55 |

剩下的开销：主循环本身约占三分之一，热点是循环头的一长串栈槽到栈槽的搬移：大约二十个值活过整个循环，主要是 VM 的局部函数（`spush`、`spop` 等）的闭包对象，它们都被 spill 了。对不逃逸的局部函数做 lambda lifting 或内联小的局部函数能解决，这对所有代码都有用。

## 原生 `compile`

在 AOT 可执行文件里测量，每次的毫秒数：

| | 原生 | Maclina |
|---|---|---|
| 编译 `(lambda (x) (* x x))` | 3.4 | 0.12 |
| 编译一个带 `loop` 的 lambda | 约 20 | 1.2 |
| 运行一百万次迭代的 `dotimes` | 2.2 | 1250 |

编译 `(lambda (x) (* x x))` 的 3.4 ms 中，前端 1.9 ms，降级 0.4 ms，打印 KIR 0.2 ms，kiln-cg 0.7 ms，新建 session 0.2 ms。`eval` 一个小形式用 Maclina 约 0.22 ms。登记新模块的表原来每次重排整张表（image 的几十万项），一次要 1.2 ms，改为追加后可以忽略。

## 启动、快照和体积

| 程序 | 正常启动 | 从快照启动 | 快照大小 |
|---|---|---|---|
| kernel + CLOS | 0.23 s | 0.04 s | 3.4 MB |
| kernel + CLOS + 前端 + eval + 编译器 | 0.74 s | 0.10 s | 8.9 MB |

从快照启动的时间里还包括测试程序本身的运行和两次原生 `compile`。映射快照用 `mmap`（私有、写时复制），没有反序列化。kiln 编译测试时用的编译器快照约 360 MB。

- eval 模块刚完成时，AOT 可执行文件启动 0.3 秒；JIT 7.7 秒，用来编译所有模块。CLOS 模块的 KIR 曾有 45 MB，debug 构建下 JIT 启动 32 秒，顶层形式分块和并行生成机器码之后约 10 秒（读入 KIR 2 秒，构造 CLIF 3 秒，生成机器码 3 秒，运行 2 秒）。
- 加上 compiler 模块后 KIR 约 100 MB，可执行文件约 120 MB。
- strip 后：kernel 加 CLOS 26 MB，加上编译器 69 MB；加上调试信息之后 kiln1 是 77 MB。增加的 8 MB 中，函数记录（约 3.1 万个函数，每个 48 字节）1.5 MB，调用点数据 1.8 MB，其余是调试信息对象。

## I/O

接入流和 FORMAT 时：往字符串流或文件写一个字符要 1 ms 左右，`format` 一次 10 ms。泛函调用本身约 0.5 µs，慢在字符串输出流平方级的增长、可调数组的增长走完整的 `make-array`、每个字符都调用的 `check-character-stream` 里的 `subtypep`、Invistra 每次重新解析控制串。修掉之后往文件写一个字符约 30 µs，`format` 一次 0.3–0.7 ms，`princ-to-string` 约 0.4 ms。上面对比表里的 `format` 是这之后的数字。

## 测量时发现的问题

- **浮点解码函数缺失（已修复）**：kiln 原来没有 CLHS 12.2 的 `integer-decode-float`、`decode-float`、`scale-float`、`float-sign`、`float-digits`、`float-precision`、`float-radix`。kiln 的 Quaviver 替身（`lisp/target/clos/quaviver.lisp`）当时也只支持以 10 为底。Invistra 的 `~F` 在舍入遇到恰好是 5 的那一位时，要用以 2 为底的精确表示来判断，于是报错。现在这些函数按位实现在 kernel 里，以 2 为底时用 `integer-decode-float`。测试 `tests/m4/clos-float-decode`，结果和 SBCL 一致。非规格化数 kiln 打印成最短的等价形式（`5.0d-324`），SBCL 打印成 `4.9406564584124654d-324`。
- **Invistra 的舍入 bug（上游，未修）**：`(format nil "~,1f" 0.05f0)` 和 `(format nil "~,1f" 0.05d0)` 给出 `"0.0"`，应该是 `"0.1"`：两者的精确值都略大于 0.05。在 SBCL 上配原版 Quaviver 运行 Invistra，结果也一样，所以不是 kiln 的问题（vendor/README.md）。
