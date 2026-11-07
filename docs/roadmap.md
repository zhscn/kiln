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
| — | 性能：CLOS 运行时编译化、调用点上的变换（见下文“性能”） | 下一步 |
| — | seal、WPO 和 AOT 交付（[positioning.md](design/positioning.md)） | 未开始 |
| — | 异步（[async.md](design/async.md)） | 未开始，ANSI 自举完成之前不做 |
| — | Rust 宿主模块（[rust-interop.md](design/rust-interop.md)）、编辑器（[editor.md](design/editor.md)） | 设计草案 |

## 当前优先级

1. **性能**。kiln 编译自己比 SBCL 慢约 6 倍，库和 CLOS 运行时比 SBCL 慢一到两个数量级（[performance.md](research/performance.md)）。编辑器的布局和装饰提供者也撑不起来。先做内建的性能分析器，再按“性能”一节的顺序做。
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
| 8 内建的性能分析器 | 性能工作的第一步 | poll 点和帧的调试信息已经有了 |
| 9 image 和源码的同步 | 和定义表一起 | 同一组数据；编辑器的 IDE 阶段需要 |
| 11 项目工具、12 格式化器和 linter | ANSI 覆盖基本完成、有外部用户之前 | 面向用户 |
| 13 内容寻址的定义 | 做机器码缓存或定义表时 | 改变缓存和依赖追踪的键 |
| 10 记录与回放 | fiber 和系统接口定下之后 | 要求非确定性都经过可记录的入口 |
| 14 扩展的能力沙箱 | 编辑器发行版 | 依赖 seal 的扩展点声明 |

## 性能

按收益排。SBCL 快在 Lisp 语义层的变换和类型推导，不在通用中端，所以这里没有“加一层通用 SSA 优化”。

1. **`defstruct` 直接分配**：构造函数和访问器直接编成内联的分配和读写，不经过 CLOS。改动小，收益大。
2. **调用点上的变换**：`find`、`position`、`member`、`assoc`、`typep` 等在参数和类型已知时，于编译期展开成循环或比较（相当于 SBCL 的 `deftransform` 和编译器宏）；对已知函数的 `&key` 调用，在编译期解析关键字。需要先让编译器调用编译器宏。`typep` 的复合类型（如 `(integer 0 10)`）在编译期展开成比较。
3. **CLOS 运行时编译化**：用原生 `compile` 把判别函数、有效方法、`make-instance` 的构造器编成机器码，替代解释执行的闭包。`call-next-method`、`make-instance`、泛函调用、`slot-value` 都靠这个，对自举提速最多。解释执行的路径保留。
4. **库的快速路径**：打印 fixnum 和字符串、`format` 的常见指令（编译期编译控制串，`formatter` 也随之正确）、字符串流的批量写入，绕开逐字符的泛函调用；`intern` 绕开 Parcl 的协议层；Salmagundi 剩下的协议开销。
5. **类型推导和浮点拆箱**：局部推导出 double 之后不再装箱，算术内联。现在每次浮点运算都装箱并进 Rust。
6. **`dynamic-extent` 和逃逸分析**：`&rest` 列表、handler（现在在堆上分配）、闭包在栈上分配，同时减轻 GC。
7. **局部函数**：对不逃逸的局部函数做 lambda lifting，或者内联小的局部函数，免去闭包对象被 spill 后在循环里的搬移（Maclina 的主循环就是这样）。
8. inline 支持 `&optional`、`&key` 参数。
9. **GC**：分代 GC 需要写屏障；Immix 的大堆配置。
10. **CLOS 调用点的内联缓存**，以及 `&rest` 泛函、方法组合不再分配参数列表。
11. **kiln-cg**：并行构造 CLIF（现在需要 `&mut Module`），减少整个程序的 KIR 和 CLIF 同时在内存里（kiln0 链接时峰值约 9.5 GB）；以 KIR 哈希为键的机器码缓存。
12. **自举**：模块之间存快照，后面的阶段从快照开始。

非局部退出如果在 profile 里显得贵，可以把编译期已知目标、只跨少数几层的退出改走返回值通道（[swift-abi.md](research/swift-abi.md)），不需要改 ABI。

## 还没做的事

### runtime 和 GC

- 写屏障（生成代码里写指针的地方和 runtime 修改堆对象的地方都要检查 log bit）。有了它才能用分代 plan，堆快照区也能用 card table 免去每次 GC 的全区扫描。
- 栈溢出：把 guard page 上的 SIGSEGV 转成 `storage-condition`，context 里加 stack limit（C2）。
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

- 类、泛函、结构的重定义，以及过时实例的更新（`update-instance-for-redefined-class`）。现在过时实例的“更新”是报错。
- `make-instance` 改成泛函；预编译的构造器。
- `change-class` 调用 `update-instance-for-different-class`。
- 长形式 `define-method-combination` 产生任意代码时的支持（可以用原生 `compile`）。
- 局部冻结（sealed class、sealed generic function）是否要做，待定（[abi-policy.md](design/abi-policy.md)）。

### 标准库和 ANSI 覆盖

与 CL 不一致的行为：
- `print`（编译器原语）：AOT 模块里先打印对象再换行，不经过 `*standard-output*`、`print-object` 和打印变量。要等测试的期望输出统一迁移。
- `formatter`：运行期解释控制串，返回 NIL 而不是剩余的参数。
- `y-or-n-p`：一次无效回答之后会多提示一次；`clear-input` 对 POSIX 流不起作用。
- `complexp` 总是 NIL；`complex`、`random-state` 只是没有实例的内建类。
- 序列函数对非 simple 向量返回 simple 向量；很多序列函数先转成列表。
- `equalp` 不比较结构的槽。
- `change-class` 见上文。
- pathname：没有 host 对象，名字里不能用反斜杠转义，`directory` 不解析符号链接，编译器不支持 pathname 常量。
- 没有时区，所以没有 `decode-universal-time`、`get-decoded-time`。
- `function-lambda-expression` 总是返回 NIL。
- Inravina 的右边距规则和 SBCL 差一列。
- Invistra 的 `~,1f` 舍入问题（上游）。

还没有的功能：
- complex；浮点的 trap、NaN 和无穷的读写。
- Unicode 的大小写和分类表（现在只覆盖 Latin-1）；`base-string`。
- 弱哈希表。
- 位数组运算（`bit-and` 等）。
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
- 采样分析器和分配分析器（poll 点上记录 `frame-list`）。

### 依赖追踪

- AOT 模块的依赖记录：KIR 里记下每个函数的依赖，模块初始化时装进同一张表，和定义表一起做。
- 重新载入文件：先读完整个文件，读失败就什么都不改；按定义名对应新旧顶层形式，只求值变了的，只是位置变了的只更新调试信息，消失的定义报告出来。
- 编译中用到还是“可能过时”的宏时，就地先更新它（现在只有循环依赖时会遇到）。
- 内联缓存、编译后的 CLOS 分派等优化的假设也作为依赖记录（`(:class c)` 一类）。
- `defun` 不清除名字上的宏函数，“宏改成函数”的重定义不起作用。

### 堆快照和 seal

- seal：构建期执行初始化，把快照写进目标文件的数据段；区分构建期和运行期初始化的规则（读环境变量、打开文件、取时间等必须在运行期）。
- seal 的语义（[positioning.md](design/positioning.md)）、反射入口的保留集合、tree shaking、调试信息的裁剪。
- 交付物的体积：慢路径和报错路径挪到共享的桩函数，共享 undefined-function 对象，静态符号只保留需要反射的名字，压缩栈图和调用点表。体积要像性能一样有基准。

### 构建和依赖

- 向 Iconoclast 和 Common-boot 的作者确认许可证，评估 builder-protocol 的 LGPLv3 对静态链接的影响。
- 确定性检查（KIR 逐字节比较）放进 CI。

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
