# 路线图

计划、进度和还没做的事都在这里。系统现在的样子见 `design/`，各设计文档末尾的“待定问题”是尚未决定的设计问题，这里不重复。

## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | SBCL 生成 KIR，kiln-cg 用 Cranelift 编译，定下调用约定、context、非局部退出（[abi.md](design/abi.md)） | 完成 |
| M1 | 对象表示、MMTk 移动式 GC、精确栈图、多栈段和跨栈展开（[gc.md](design/gc.md)） | 完成 |
| M2 | Common-boot 前端、Clostrum 编译期环境、全部特殊操作符的降级（[front-end.md](design/front-end.md)、[lowering.md](design/lowering.md)） | 完成 |
| M3 | kernel：数值塔、Unicode 字符和字符串、`typep`、序列函数、多模块（[kernel.md](design/kernel.md)） | 完成 |
| M4 | CLOS 引导和依赖 CLOS 的库：condition、哈希表、包、ctype、数组、结构、流、文件、打印、FORMAT、LOOP、reader（[clos.md](design/clos.md)、[stdlib.md](design/stdlib.md)、[io.md](design/io.md)） | 完成 |
| M5 | 运行期 `eval`/`compile`/`load` 和 REPL；编译器在 kiln 上运行；自举闭合（kiln0 和 kiln1 逐字节相同）；原生 `compile`（[eval-compile.md](design/eval-compile.md)、[bootstrap.md](design/bootstrap.md)） | 完成 |
| M6 | image 开发体验：堆快照（[heap-image.md](design/heap-image.md)）、原生 `eval`/`load`、帧的调试信息（[debugging.md](design/debugging.md)）、后端协议（[backend-protocol.md](design/backend-protocol.md)）、依赖追踪（[dependencies.md](design/dependencies.md)） | 前四项完成；剩下 AOT 模块的依赖和定义表、REPL 中断、SLYNK/Swank 接入 |
| — | ANSI 补全：cl-bench 找到的缺口已补上；`ansi-test` 全部 24 组已跑通（21,708 / 21,876 = 99.2%，另跳过 77 项，见“标准库和 ANSI 覆盖”），持续补齐剩余缺口 | 进行中 |
| — | 性能：自编译与基础代码生成已与 SBCL 持平（单阶段 5.0 s vs 4.63 s）；剩余编译器深度优化与库快路径见下文“性能” | 阶段一完成 |
| — | seal、WPO 和 AOT 交付（[positioning.md](design/positioning.md)） | 未开始 |
| — | 异步（[async.md](design/async.md)） | 未开始，ANSI 自举完成之前不做 |
| — | Rust 宿主模块（[rust-interop.md](design/rust-interop.md)）、编辑器（[editor.md](design/editor.md)） | 设计草案 |

## 当前优先级

1. **ANSI 标准覆盖度（`ansi-test`）**。此前性能优化的主要目标是加快 kiln 自身的构建效率；现在自编译单阶段已从 845 秒降到 **5.0 秒**（SBCL 编同一份代码 4.63 秒），编译器自身和基础代码生成与 SBCL 差距已经很小。重心转向接入 `ansi-test` 测试套件，以同一套测试下 SBCL 的行为为参照，按模块逐项修复语义差异和缺失功能（见下文“标准库和 ANSI 覆盖”），为后续运行 ASDF/UIOP 和第三方库打底。
2. **编译器自身的深度优化与库快路径**（见“性能”一节）：剩余性能差距集中在编译器的 Lisp 语义层优化（局部类型推导与浮点拆箱、不逃逸局部函数的 lambda lifting、高阶函数调用点展开与编译器宏、`dynamic-extent` 栈上分配）以及标准库协议层快路径（流/FORMAT/打印、bignum、多维数组、运行期 CLOS 编译化）。
3. **M6 的剩余部分**：定义表和跳转到定义、who-calls，AOT 模块的依赖记录，打断正在运行的任务。它们是编辑器 IDE 阶段的前提。
4. **构建期初始化和 seal**：决定 seal 的语义和目标文件格式。

[modern-practices.md](research/modern-practices.md) 里各项的时机：

| 项 | 时机 | 理由 |
|---|---|---|
| 1 构建期初始化和堆快照 | 堆快照已做；seal 时写进目标文件 | 决定 seal 的语义和目标文件格式 |
| 2 依赖追踪 | image 里求值的部分已做；AOT 模块和定义表一起做 | 影响编译器的数据结构，越早定越好 |
| 内存模型 | 写多线程的 Lisp 代码之前 | 影响 runtime 和库的接口 |
| 5 并行编译和缓存 | 顶层原生产物缓存已接入；并行编译待做 | 前端和降级仍重放编译期效果，原生产物按 KIR、literal 和依赖版本匹配 |
| 3 内联缓存 | 常量槽名、常量类名构造器的调用点已接入 | 原生编译器载入后，热点构造器可晋升为机器码；泛函按 PCL 的路线优化判别函数本身；见 [specialization.md](design/specialization.md) |
| 3 PGO、4 逃逸分析和拆箱 | seal 和 WPO 实现时 | 需要中端 |
| 6 诊断、LSP、DWARF | ANSI 覆盖基本完成后 | 面向用户 |
| 7 测试方法 | 随时，按需加 | 差分测试的基础设施已经有了 |
| 8 内建的性能分析器 | 已做 | |
| 9 image 和源码的同步 | 和定义表一起 | 同一组数据；编辑器的 IDE 阶段需要 |
| 11 项目工具和包管理 | ANSI 补全和性能之后；先让 ASDF/UIOP 在 kiln 上运行 | 生态的库都依赖 ASDF |
| 12 格式化器和 linter | ANSI 覆盖基本完成、有外部用户之前 | 面向用户 |
| 13 内容寻址的定义 | 做机器码缓存或定义表时 | 改变缓存和依赖追踪的键 |
| 10 记录与回放 | fiber 和系统接口定下之后 | 要求非确定性都经过可记录的入口 |
| 14 扩展的能力沙箱 | 编辑器发行版 | 依赖 seal 的扩展点声明 |

## 性能

按收益排。SBCL 快在 Lisp 语义层的变换和类型推导，不在通用中端，所以这里没有“加一层通用 SSA 优化”。

1. **kiln 自己的 IR**（[ir.md](design/ir.md)）：原生结构对象（单个对象、O(1) 的类型检查、内联构造）和 KIR 的 `:switch` 已接入。CST → IR → KIR 是唯一的前端，cross-client 的编译期求值用 IR 求值器；旧的 Iconoclast 前端、HIR 求值器及其依赖（Common-boot、Iconoclast、s-expression-syntax、parser.packrat、builder 协议）已删除。剩下在内存里交接 KIR。
2. **调用点上的变换**：`member`/`assoc` 带常量 `:test`（`eq`/`eql`）、`append` 简化、复合 `typep`（fixnum 范围、`eql`、`member`、`not`/`or`/`and`）的内联展开、`multiple-value-bind`/`multiple-value-list` 的直接降级，以及带 `&optional`/`&key` 函数的 `inline`（调用点编译期解析关键字）已接入。剩下 `find`、`position` 等序列函数在参数和类型已知时展开成循环，以及让编译器调用编译器宏。
3. **CLOS 运行时编译化**：用原生 `compile` 把判别函数、有效方法、`make-instance` 的构造器编成机器码，替代解释执行的闭包。泛函调用本身在 cl-bench 上已和 SBCL 持平；`make-instance`（快路径之外）、`call-next-method`、定义类和方法（运行期编译）仍慢 9–40 倍，靠这一项。解释执行的路径保留。
4. **库的快速路径**：打印 fixnum 和字符串、`format` 的常见指令（编译期编译控制串，`formatter` 也随之正确）、字符串流的批量写入，绕开逐字符的泛函调用；`intern` 绕开 Parcl 的协议层；Salmagundi 剩下的协议开销。
5. **数值**：类型推导和浮点拆箱（局部推导出 double 之后不再装箱，算术内联；现在每次浮点运算都装箱并进 Rust，cl-bench 的浮点项慢几百倍）；bignum 的乘除法算法和实现要整个重看（慢到两三千倍）；多维数组绕开 Regalia 的通用路径。
6. **`dynamic-extent` 和逃逸分析**：`&rest` 列表、handler（现在在堆上分配）、闭包在栈上分配，同时减轻 GC。
7. **局部函数**：对不逃逸的局部函数做 lambda lifting，或者内联小的局部函数，免去闭包对象被 spill 后在循环里的搬移（Maclina 的主循环就是这样）。
8. **分代 GC**：这一轮优化之后，自编译的分配量从约 250 GB 降到 2.58 GB（8 GiB 自举堆下 0 次 GC），对编译器自身的收益已不再是瓶颈，价值主要在降低峰值内存（GenImmix 不需要半个堆的复制预留）和分配密集的用户程序。下面是优化之前量的：已量过（[performance.md](research/performance.md) 的“GC”）：自举时 GC 停顿约占墙钟的 9%、worker 占 CPU 的 22%，复制的字节 93% 是反复复制的老对象，新对象只有约 1.1% 活过下一次回收（nursery 从 4 GiB 缩到 256 MiB 也不变）。估计分代后 GC 停顿从 31–39 秒降到 6–9 秒，扣掉写屏障净省墙钟的 4–6%。设计和实施步骤见 [gc.md](design/gc.md) 的“Generational GC plan”：先 GenCopy 验证屏障，再换 GenImmix；快照区同时改成 card table。另外两项不依赖分代、要改 MMTk 的：MMTk 写死的清零（约 2.5% 的 CPU），GC 并行度低（8 个线程平均只有约 3 个在干活，线程数不影响停顿）。
10. **无 header 的 cons**：cons 现在 24 字节，SBCL 是 16 字节。做法：所有 header 的低 3 位用保留的 tag `111`，任何 Lisp 值都不会长成 header，于是对象的第一个字不是 header 就是 cons（SBCL 遍历堆也是这样区分的）；forwarding bits 已在 side metadata，forwarding 指针写在偏移 0 覆盖 car 也没问题。难点是身份哈希：cons 没有 header 就没有地方存，改为按地址哈希，GC 确实移动了某张表的键时才标记这张表需要重新哈希（SBCL 的做法）。SemiSpace 下每次 GC 都移动全部对象，所以排在分代 GC 之后。先量 cons 在分配量里的占比（按 kind 统计分配字节数）。NIL 同时带 list tag 的技巧收益很小，不做。
11. **CLOS 调用点的内联缓存**，以及 `&rest` 泛函、方法组合不再分配参数列表。统一的假设登记和失效框架（[specialization.md](design/specialization.md)）已经就位：现有的缓存（分派、`make-instance`、`typep` 表）都经过它，调用点 `typep` 缓存的过时问题已修掉，常量槽名的 `slot-value` 已经按对象 stamp 在调用点缓存槽位置（24.7 → 9.9 ns，和访问器方法相当）。常量类名 `make-instance` 的构造器对象和热点构造器的生成代码也已接入（未晋升的闭包路径 437 → 359 ns）。接下来按 PCL 的路线优化判别函数本身：按状态（单类、双类、caching）生成专门的判别函数，失效时整个换掉（`install-discriminating-function`），命中路径不检查任何版本。泛函调用点缓存试过一版：要先调选择器、再调有效方法，还要检查方法版本、判别函数身份和类变化版本，`bench/compare.lisp` 上单态 13.7 → 28.6 ns、多态 18.9 → 25.7 ns，已去掉。
    - 以后的方向：SICL 式的调用点内联（Strandh，*Call-site optimization for Common Lisp*：每个调用点有一段由 runtime 按被调函数状态重新生成的 snippet）。kiln 不改写机器码，对应做法是静态 cons 的 car 加上降级时生成在调用点里的守卫：读 car，比较被特化参数的 stamp，直接调用有效方法；失效改成推送式，由登记在 `(:methods gf)` 和类变化上的依赖者把 car 清成 NIL，命中路径不再检查版本。比 PCL 少一次调用，代价是降级和失效登记都要做细。等判别函数接近 SBCL 之后，再量它还能省多少。
12. **kiln-cg**：并行构造 CLIF（现在需要 `&mut Module`），减少整个程序的 KIR 和 CLIF 同时在内存里（kiln0 链接时峰值约 9.5 GB）；以 KIR 哈希为键的机器码缓存。
13. **其他库的快路径**：`sxhash`、字符串键的哈希表、`search`、位数组运算、`read-line` 和字符串流。
14. **自举**：模块之间存快照，后面的阶段从快照开始。

非局部退出如果在 profile 里显得贵，可以把编译期已知目标、只跨少数几层的退出改走返回值通道（[swift-abi.md](research/swift-abi.md)），不需要改 ABI。

## 还没做的事

### runtime 和 GC

- 写屏障（生成代码里写指针的地方和 runtime 修改堆对象的地方都要检查 log bit）。有了它才能用分代 plan，堆快照区也能用 card table 免去每次 GC 的全区扫描。
- 栈耗尽只在函数入口检查，Rust 代码自身的深递归不在检查范围内。
- 多 mutator 的 safepoint 协议：poll 标志加上等待所有 mutator 到达 safepoint。poll 慢路径的其他用途（REPL 中断、重定义屏障、抢占）也都还没接上（C4）。
- C6：`in-lisp`/`in-native` 状态切换和 FFI trampoline；runtime 回调进 Lisp 的路径（压入新的栈段即可）。
- TLS 表固定 4096 项，要能扩容。
- 运行期编出的代码不回收。
- 位置无关的可执行文件（PIE），到时堆快照要带重定位信息。
- C8 第 3 项（新栈上 signal、旧栈上的 handler）的测试。
- ABI 指纹（[abi-policy.md](design/abi-policy.md)）。
- 把栈图、调用点表、调试记录合并成统一的调用点描述符。
- 分别生成的目标文件之间的链接（共享定义用 weak 链接、launcher 汇总多个模块信息），以及 image 里增量加载 AOT 模块。

### 编译器

- **局部类型推导与拆箱**：`ir-node` 和 `ir-var` 上已有 `type` 槽，但尚未做正向类型传播与区间分析；同一分支内已确认类型的变量仍会重复生成 tag 检查，`double-float` 在函数内每次运算仍在堆上装箱并调用 Rust runtime，已知元素类型的 `aref`/`length`/序列操作也还没按推导类型特化。
- **局部函数的 lambda lifting 与多调用点小函数内联**：目前 `analyze-ir` 只内联无可选参数、仅调用一次的局部函数；多次调用但不逃逸的局部函数若捕获外层变量，仍会分配闭包并在循环头 spill。
- **编译器宏与高阶序列函数展开**：编译期的 `define-compiler-macro` 被忽略，运行期只记在 plist 上（宿主库的除外）；`find`、`position`、`sort`、`map` 等高阶调用点尚未在编译期展开成内联循环（`funcall` 比较函数和运行期解析关键字参数仍是开销来源）。
- **逃逸分析与 `dynamic-extent`**：`&rest` 列表、跨函数退出令牌、`handler-case` / `handler-bind` 的 handler 闭包和条目仍在堆上分配；带 `&key` 的全局函数尚未生成固定位置参数的内部入口。
- `defclass` 定义的访问函数在文件末尾被报成未定义函数。
- 字面数据里未 intern 的符号，名字里带宿主的 gensym 计数时，两边的 KIR 可能不同。
- 中端放在哪里（直接在 `ir-node` 上做类型推导与变换，还是在 IR 和 KIR 之间新加一层）待定，见 [modern-practices.md](research/modern-practices.md)。

### 运行期的 `eval`/`compile`

- `compile-file` 和 FASL。
- `defsetf` 长形式在 image 里求值时出错（[eval-compile.md](design/eval-compile.md)），要在 vendor 的 Common-macros 上打补丁。
- `compile` 的前端开销：每次新建 session。
- `compile` 编出的函数名是 `(lambda)`；`load` 的函数没有文件和位置。

### CLOS

- 泛函的重定义（`defgeneric` 改 lambda list 等）。
- 过时实例只在分派时更新：`slot-value` 在更新之前读的是旧布局（类名 `typep` 的调用点缓存已在统一框架里修掉）。
- 重定义结构后，inline 的访问器在已编译的调用者里不变（依赖追踪不覆盖 AOT 模块）。
- 快路径之外的 `make-instance` 构造器性能。
- 长形式 `define-method-combination` 产生任意代码时的支持（可以用原生 `compile`）。
- 局部冻结（sealed class、sealed generic function）是否要做，待定（[abi-policy.md](design/abi-policy.md)）。

### 标准库和 ANSI 覆盖

`ansi-test`（`tools/ansi-test.sh`）全部 24 个测试组已无崩溃跑通，当前实际执行用例的通过率为 **21,708 / 21,876（99.2%）**。共注册 21,953 项，另有 77 项因关闭 note 而跳过；跳过项不计入通过数或通过率的分母。测试套件根据未知声明告警启用 `DECLARATION.4–11`，检查声明名与类型名的冲突。关闭的 note 与 SBCL 一致：`:nil-vectors-are-strings` 和 `:open-if-exists-new-version-no-error`。

| 测试组 | 通过 | 失败 | 跳过 | 总计 | 通过率 | 主要未通过原因 |
|---|---:|---:|---:|---:|---:|---|
| `symbols` | 1141 | 3 | 1 | 1145 | 99.7% | 尚未实现的标准函数、宏和动态变量汇总 |
| `eval-and-compile` | 322 | 4 | 0 | 326 | 98.8% | `compile-file` 和缺失的标准宏（`step`、`time`、`trace`、`untrace`） |
| `data-and-control-flow` | 1420 | 6 | 2 | 1428 | 99.6% | 宏 lambda list、字符类型、常量定义和多值列表边界 |
| `iteration` | 840 | 3 | 0 | 843 | 99.6% | `loop` 的少量边界语法 |
| `objects` | 845 | 17 | 0 | 862 | 98.0% | 长方法组合、`change-class` 和初始化边界 |
| `conditions` | 671 | 2 | 0 | 673 | 99.7% | `MAKE-CONDITION.3/4`（SBCL 同样失败） |
| `cons` | 1882 | 0 | 0 | 1882 | 100.0% | — |
| `types-and-classes` | 620 | 1 | 6 | 627 | 99.8% | complex 分量升级争议、`deftype` 环境、数组 `type-of` 精度 |
| `arrays` | 1356 | 0 | 0 | 1356 | 100.0% | `adjust-array` 与 displaced 数组边界 |
| `hash-tables` | 166 | 0 | 1 | 167 | 100.0% | — |
| `packages` | 499 | 0 | 1 | 500 | 100.0% | — |
| `numbers` | 1434 | 9 | 1 | 1444 | 99.4% | 复数幂与反三角函数、浮点异常和带符号零 |
| `sequences` | 3283 | 1 | 3 | 3287 | 100.0% | `MAP.48`（SBCL 同样失败） |
| `structures` | 1392 | 2 | 0 | 1394 | 99.9% | `:type` 列表/向量结构的少量选项组合 |
| `strings` | 464 | 0 | 45 | 509 | 100.0% | — |
| `characters` | 259 | 0 | 0 | 259 | 100.0% | — |
| `pathnames` | 199 | 16 | 0 | 215 | 92.6% | 逻辑路径名（logical pathname）、`wild-pathname-p` 细节 |
| `files` | 82 | 5 | 0 | 87 | 94.3% | `directory` 通配符、`file-author`、`probe-file`/`truename` 错误类型 |
| `streams` | 785 | 4 | 14 | 803 | 99.5% | `echo-stream`/`two-way-stream`/`concatenated-stream` 边界、`open` 的 `:if-exists` 组合 |
| `printer` | 2443 | 0 | 3 | 2446 | 100.0% | — |
| `reader` | 665 | 8 | 0 | 673 | 98.8% | `*read-suppress*` 下的语法检查、`read-preserving-whitespace` 边界 |
| `system-construction` | 49 | 28 | 0 | 77 | 63.6% | `compile-file`、`compile-file-pathname` 和编译文件绑定 |
| `environment` | 153 | 57 | 0 | 210 | 72.9% | `describe`、`disassemble`、`trace`、`time`、`room`、`dribble`、`ed` |
| `misc` | 738 | 2 | 0 | 740 | 99.7% | `step`/`trace` 边界 |
| **合计** | **21708** | **168** | **77** | **21953** | **99.2%** | |

与 CL 不一致的行为：
- `print`（编译器原语）：AOT 模块里先打印对象再换行，不经过 `*standard-output*`、`print-object` 和打印变量。要等测试的期望输出统一迁移。
- `y-or-n-p`：一次无效回答之后会多提示一次；`clear-input` 对 POSIX 流不起作用。
- 序列函数对非 simple 向量返回 simple 向量。
- `change-class` 见上文。
- pathname：没有 host 对象，名字里不能用反斜杠转义，`directory` 不解析符号链接，编译器不支持 pathname 常量。
- `function-lambda-expression` 总是返回 NIL。
- Inravina 的右边距规则和 SBCL 差一列。
- Invistra 的 `~,1f` 舍入问题（上游）。

还没有的功能：
- ctype 的 complex 部分（`subtypep` 不懂 complex 类型）；浮点的 trap、NaN 和无穷的读写。
- Unicode 的大小写和分类表（现在只覆盖 Latin-1）；`base-string`。
- 弱哈希表。
- 位数组运算（`bit-and` 等）、`search` 的快速路径：现在逐位、逐个 `elt`，非常慢。
- 真正的 Quaviver（现在是替身）；Consecution、Constrictor。
- 标准流的输出缓冲（要和 runtime 直接写 fd 的输出协调）。
- 包冲突时更多的 restart；`do-symbols` 对有 use 列表的包是平方复杂度。
- 条件记录源码形式（`with-current-source-form` 现在是 `progn`）。
- 运行期 reader 的 `#.`：原来因为没有运行期 `eval` 而报错，`eval` 有了以后是否接上，需要确认。

### 调试和工具

- 定义表（dspec 和位置）、跳转到定义、who-calls、重定义警告（[debugging.md](design/debugging.md) 的定义记录）。
- 宏展开的事件流和查看器。
- 单步和断点；从帧返回、重新执行帧。
- 调试优化级别：`(optimize (debug 2))` 下让变量活过出错路径上的调用。
- 闭包从静态环境读的变量在帧里显示。
- 后端协议：打断正在运行的任务、流式输出；SLYNK/Swank、LSP、DAP 接在它上面。
- DWARF 行号表和 CFI，JIT 走 GDB 的 JIT 接口。

### 依赖追踪

- AOT 模块的依赖记录：KIR 里记下每个函数的依赖，模块初始化时装进同一张表，和定义表一起做。
- 重新载入文件：先读完整个文件，读失败就什么都不改；按定义名对应新旧顶层形式，只求值变了的，只是位置变了的只更新调试信息，消失的定义报告出来。
- 编译中用到还是“可能过时”的宏时，就地先更新它（现在只有循环依赖时会遇到）。
- 内联缓存、编译后的 CLOS 分派等优化的假设作为依赖记录（`(:class c)` 一类）：假设的键和版本格已经实现，`change-assumption` 也把键交给同一个钩子（[specialization.md](design/specialization.md)）；还没有编译期特化去记录它们。
- `defun` 不清除名字上的宏函数，“宏改成函数”的重定义不起作用。

### 堆快照和 seal

- seal：构建期执行初始化，把快照写进目标文件的数据段；区分构建期和运行期初始化的规则（读环境变量、打开文件、取时间等必须在运行期）。
- seal 的语义（[positioning.md](design/positioning.md)）、反射入口的保留集合、tree shaking、调试信息的裁剪。
- 交付物的体积：慢路径和报错路径挪到共享的桩函数，共享 undefined-function 对象，静态符号只保留需要反射的名字，压缩栈图和调用点表。体积要像性能一样有基准。

### 构建和依赖

- 确认 kiln 用到的、没有许可证文件的 SICL 模块的许可证。
- 确定性检查（KIR 逐字节比较）放进 CI。

## 项目工具和包管理

问题分析见 [modern-practices.md](research/modern-practices.md) 第 11 项。时间上排在 ANSI 补全和性能之后。

**两层：先兼容 ASDF，再做自己的工具。**

1. **ASDF 和 UIOP 在 kiln 上运行**：生态里几乎所有库都依赖它们，这一步绕不过去。UIOP 要移植一小块实现相关的代码（文件系统、进程、环境变量），本身也是一次 ANSI 完整性的检验。里程碑是“Quicklisp 上常用的库能在 kiln 上编译通过”，排在 ANSI 补全之后、项目工具之前。
2. **kiln 的项目工具**，类似 Cargo：
   - **清单是声明式的数据**，读它不需要执行任何代码；工作区。
   - **子命令**：`new`、`build`、`test`、`bench`、`run`、`repl`、`seal`；`build --release` 就是 seal 加 AOT。
   - **兼容 `.asd`**：常见的 `defsystem` 写法（components、`:depends-on`、`:serial`）直接当数据读；少数要执行代码的，退回到在单独的构建 image 里运行 ASDF。
   - **构建缓存**以 KIR 的内容哈希为键，键里带上它依赖的宏、内联函数的哈希，比时间戳准确，也能跨机器共享。
   - 构建期执行的代码（宏、构建脚本）以后放进能力沙箱。
   - **Rust 宿主 crate**：清单里声明，开发时编成动态库载入活 image，交付时和 launcher 一起生成一个 staticlib 静态链接（[rust-interop.md](design/rust-interop.md) 的“静态链接的构建”）。

**包管理：**

- **一个 image 里同一个库只有一个版本**：CL 的包名是全局的，不能像 Cargo 那样让两个版本共存（包局部昵称不解决这个）。解析器给每个库只选一个版本。
- **解析用最小版本选择（MVS，Go modules 的算法）**：简单、结果确定，不需要 SAT 求解，和锁文件配合好。CL 的库很少严格遵守语义化版本，MVS 对此比较宽容。
- **来源**：先用“git URL 加 commit”，锁文件记内容哈希（`deps.lock` 现在就是这样）；Quicklisp 的 dist 当作一个可读的索引。暂时不建中心仓库。
- **版本检查**：发布时按定义表比较两个版本导出的定义，判断版本号该怎么升，提示不兼容的修改。
- **二进制缓存**：KIR 产物按内容哈希缓存，键包括编译器版本和 ABI 指纹。
- **Rust 依赖**仍由 Cargo 管理，kiln 的锁文件只记下 Cargo 工作区和 `Cargo.lock` 的哈希。

## 编辑器

[editor.md](design/editor.md) 的分阶段计划：

| 阶段 | 内容 | 依赖的 kiln 功能 |
|---|---|---|
| 0 | kiln 侧的前提：帧调试信息和后端协议（已完成）、依赖追踪（已完成在 image 里求值的部分）、性能、系统接口（终端、poll/epoll、子进程、伪终端、定时器、inotify）、按上下文局部的变量、Rust 宿主模块 | M6 的后续各项、上文“性能”、[rust-interop.md](design/rust-interop.md) |
| 1 | 最小的 TUI 编辑器：buffer 和文本属性、命令循环、按键表、输入框、文件；显示管线的四段，装饰提供者先同步运行 | fiber 之前可以先用同一个栈上嵌套的命令循环 |
| 2 | kiln 的 IDE：REPL、可塑的 inspector、debugger、跳转到定义、调用者查询、image 和源码的同步，都走后端协议；用它开发 kiln 自己 | debugger、依赖追踪、定义表 |
| 3 | 异步任务（提供者超时转异步、语言服务器、子进程）、渲染分离；GUI 前端（Rust 的平台层、文字服务和渲染器，声明式动画） | fiber、内存模型、Rust 宿主模块 |
| 4 | 发行版：部分 seal、扩展点声明、Maclina 执行扩展、体积优化 | seal、tree shaking |

Rust 宿主模块不依赖通用的 C FFI，也不依赖 fiber，可以先做；通用的 C FFI 排在后面，建在它上面。

## 不再计划的

- 远程 JIT 模式（SBCL 端编译、经 socket 发给运行中的 kiln）：kiln 自己能编译之后不再需要。
- 早期的 CLIF 文本交换格式：换成了 KIR（[codegen.md](design/codegen.md)）。
