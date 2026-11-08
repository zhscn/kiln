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
| — | ANSI 补全：cl-bench 找到的缺口（`random`、`gentemp`、complex、位数组运算、`search` 的关键字、类的重定义、栈耗尽） | 这一批已补上，其余见“标准库和 ANSI 覆盖” |
| — | 性能：CLOS 运行时编译化、调用点上的变换、数值（见下文“性能”） | 进行中 |
| — | seal、WPO 和 AOT 交付（[positioning.md](design/positioning.md)） | 未开始 |
| — | 异步（[async.md](design/async.md)） | 未开始，ANSI 自举完成之前不做 |
| — | Rust 宿主模块（[rust-interop.md](design/rust-interop.md)）、编辑器（[editor.md](design/editor.md)） | 设计草案 |

## 当前优先级

1. **性能**。kiln 编译自己比 SBCL 慢约 6 倍，库、数值和 CLOS 运行时比 SBCL 慢一到三个数量级（[performance.md](research/performance.md)）。编辑器的布局和装饰提供者也撑不起来。用内建的采样分析器定位，按“性能”一节的顺序做。
2. **M6 的剩余部分**：定义表和跳转到定义、who-calls，AOT 模块的依赖记录，打断正在运行的任务。它们是编辑器 IDE 阶段的前提。
3. **构建期初始化和 seal**：决定 seal 的语义和目标文件格式。

[modern-practices.md](research/modern-practices.md) 里各项的时机：

| 项 | 时机 | 理由 |
|---|---|---|
| 1 构建期初始化和堆快照 | 堆快照已做；seal 时写进目标文件 | 决定 seal 的语义和目标文件格式 |
| 2 依赖追踪 | image 里求值的部分已做；AOT 模块和定义表一起做 | 影响编译器的数据结构，越早定越好 |
| 内存模型 | 写多线程的 Lisp 代码之前 | 影响 runtime 和库的接口 |
| 5 并行编译和缓存 | 自举时间成为瓶颈时 | 机器码缓存只依赖确定性，现在就能做 |
| 3 内联缓存 | 性能优化阶段 | 不依赖 seal，开发期即可受益 |
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

1. **kiln 自己的 IR**（[ir.md](design/ir.md)）：原生结构对象（单个对象、O(1) 的类型检查、内联构造）和 KIR 的 `:switch` 已接入。CST → IR → KIR 路径可通过 `KILN_FRONTEND=ir` 选择，包含词法转换、闭包分析和降级；IR 前端已是默认，cross-client 的编译期求值也换成了 IR 求值器（`KILN_EVALUATOR=hir` 选旧的 HIR 求值器）；接下来移除旧编译路径、HIR 求值器及其依赖（Common-boot、Iconoclast、s-expression-syntax、parser.packrat、builder 协议）。
2. **调用点上的变换**：`find`、`position`、`member`、`assoc`、`typep` 等在参数和类型已知时，于编译期展开成循环或比较（相当于 SBCL 的 `deftransform` 和编译器宏）；对已知函数的 `&key` 调用，在编译期解析关键字。需要先让编译器调用编译器宏。`typep` 的复合类型（如 `(integer 0 10)`）在编译期展开成比较。
3. **CLOS 运行时编译化**：用原生 `compile` 把判别函数、有效方法、`make-instance` 的构造器编成机器码，替代解释执行的闭包。泛函调用本身在 cl-bench 上已和 SBCL 持平；`make-instance`（快路径之外）、`call-next-method`、定义类和方法（运行期编译）仍慢 9–40 倍，靠这一项。解释执行的路径保留。
4. **库的快速路径**：打印 fixnum 和字符串、`format` 的常见指令（编译期编译控制串，`formatter` 也随之正确）、字符串流的批量写入，绕开逐字符的泛函调用；`intern` 绕开 Parcl 的协议层；Salmagundi 剩下的协议开销。
5. **数值**：类型推导和浮点拆箱（局部推导出 double 之后不再装箱，算术内联；现在每次浮点运算都装箱并进 Rust，cl-bench 的浮点项慢几百倍）；bignum 的乘除法算法和实现要整个重看（慢到两三千倍）；多维数组绕开 Regalia 的通用路径。
6. **`dynamic-extent` 和逃逸分析**：`&rest` 列表、handler（现在在堆上分配）、闭包在栈上分配，同时减轻 GC。
7. **局部函数**：对不逃逸的局部函数做 lambda lifting，或者内联小的局部函数，免去闭包对象被 spill 后在循环里的搬移（Maclina 的主循环就是这样）。
8. inline 支持 `&optional`、`&key` 参数。
9. **分代 GC**：这一轮优化之后，自编译的分配量从约 250 GB 降到 99 GB，GC 停顿只占墙钟的 5.8%（7.3 秒），对编译器自身的收益缩到几秒，价值主要在降低峰值内存（GenImmix 不需要半个堆的复制预留）和分配密集的用户程序。下面是优化之前量的：已量过（[performance.md](research/performance.md) 的“GC”）：自举时 GC 停顿约占墙钟的 9%、worker 占 CPU 的 22%，复制的字节 93% 是反复复制的老对象，新对象只有约 1.1% 活过下一次回收（nursery 从 4 GiB 缩到 256 MiB 也不变）。估计分代后 GC 停顿从 31–39 秒降到 6–9 秒，扣掉写屏障净省墙钟的 4–6%。设计和实施步骤见 [gc.md](design/gc.md) 的“Generational GC plan”：先 GenCopy 验证屏障，再换 GenImmix；快照区同时改成 card table。另外两项不依赖分代、要改 MMTk 的：MMTk 写死的清零（约 2.5% 的 CPU），GC 并行度低（8 个线程平均只有约 3 个在干活，线程数不影响停顿）。
10. **无 header 的 cons**：cons 现在 24 字节，SBCL 是 16 字节。做法：所有 header 的低 3 位用保留的 tag `111`，任何 Lisp 值都不会长成 header，于是对象的第一个字不是 header 就是 cons（SBCL 遍历堆也是这样区分的）；forwarding bits 已在 side metadata，forwarding 指针写在偏移 0 覆盖 car 也没问题。难点是身份哈希：cons 没有 header 就没有地方存，改为按地址哈希，GC 确实移动了某张表的键时才标记这张表需要重新哈希（SBCL 的做法）。SemiSpace 下每次 GC 都移动全部对象，所以排在分代 GC 之后。先量 cons 在分配量里的占比（按 kind 统计分配字节数）。NIL 同时带 list tag 的技巧收益很小，不做。
11. **CLOS 调用点的内联缓存**，以及 `&rest` 泛函、方法组合不再分配参数列表。和第 3 项一起，建在 [specialization.md](design/specialization.md) 的统一框架上：先把现有的缓存（分派、`make-instance` 的 epoch、`typep` 表）改为经过统一的假设登记和失效，补上调用点 `typep` 缓存的过时问题，再做调用点特化（方法体内 `slot-value` 的置换向量、`make-instance` 的构造器对象）和生成代码；编译结果按顶层形式缓存也用同一套依赖。
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

- 编译器宏：编译期的 `define-compiler-macro` 被忽略，运行期只记在 plist 上（宿主库的除外）。
- 全局符号宏：image 里的编译器看不到 `define-symbol-macro`。
- `defclass` 定义的访问函数在文件末尾被报成未定义函数。
- 字面数据里未 intern 的符号，名字里带宿主的 gensym 计数时，两边的 KIR 可能不同。
- 中端放在哪里（直接在 KIR 上，还是 AST 和 KIR 之间新加一层 SSA IR）待定，见 [modern-practices.md](research/modern-practices.md)。

### 运行期的 `eval`/`compile`

- `compile-file` 和 FASL。
- 运行期的 `defstruct`（结构布局没有传给 image 里的编译器）。
- `defsetf` 长形式在 image 里求值时出错（[eval-compile.md](design/eval-compile.md)），要在 vendor 的 Common-macros 上打补丁。
- `compile` 的前端开销：每次新建 session。
- `compile` 编出的函数名是 `(lambda)`；`load` 的函数没有文件和位置。

### CLOS

- 泛函的重定义（`defgeneric` 改 lambda list 等）。
- 过时实例只在分派时更新：`slot-value` 在更新之前读的是旧布局，类名 `typep` 的调用点缓存给出旧类的结果。
- 重定义结构后，inline 的访问器在已编译的调用者里不变（依赖追踪不覆盖 AOT 模块）。
- `make-instance` 改成泛函；快路径之外的构造器。
- `change-class` 调用 `update-instance-for-different-class`。
- 长形式 `define-method-combination` 产生任意代码时的支持（可以用原生 `compile`）。
- 局部冻结（sealed class、sealed generic function）是否要做，待定（[abi-policy.md](design/abi-policy.md)）。

### 标准库和 ANSI 覆盖

与 CL 不一致的行为：
- `print`（编译器原语）：AOT 模块里先打印对象再换行，不经过 `*standard-output*`、`print-object` 和打印变量。要等测试的期望输出统一迁移。
- `formatter`：运行期解释控制串，返回 NIL 而不是剩余的参数。
- `y-or-n-p`：一次无效回答之后会多提示一次；`clear-input` 对 POSIX 流不起作用。
- 序列函数对非 simple 向量返回 simple 向量；很多序列函数先转成列表。
- `change-class` 见上文。
- pathname：没有 host 对象，名字里不能用反斜杠转义，`directory` 不解析符号链接，编译器不支持 pathname 常量。
- 没有时区，所以没有 `decode-universal-time`、`get-decoded-time`。
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
- 内联缓存、编译后的 CLOS 分派等优化的假设也作为依赖记录（`(:class c)` 一类），见 [specialization.md](design/specialization.md)。
- `defun` 不清除名字上的宏函数，“宏改成函数”的重定义不起作用。

### 堆快照和 seal

- seal：构建期执行初始化，把快照写进目标文件的数据段；区分构建期和运行期初始化的规则（读环境变量、打开文件、取时间等必须在运行期）。
- seal 的语义（[positioning.md](design/positioning.md)）、反射入口的保留集合、tree shaking、调试信息的裁剪。
- 交付物的体积：慢路径和报错路径挪到共享的桩函数，共享 undefined-function 对象，静态符号只保留需要反射的名字，压缩栈图和调用点表。体积要像性能一样有基准。

### 构建和依赖

- 向 Iconoclast 和 Common-boot 的作者确认许可证，评估 builder-protocol 的 LGPLv3 对静态链接的影响。
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
