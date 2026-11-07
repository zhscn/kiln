# 可借鉴的现代编译器实践

**日期**：2026-11。不随代码更新。

这里列出 seal（[positioning.md](../design/positioning.md)）和异步（[async.md](../design/async.md)）之外，值得在 kiln 上采用的做法，以及暂不采用的做法。每一项真正开工时，再在 `design/` 里写详细设计；排期见 [roadmap.md](../roadmap.md)。下文按编号称“第 N 项”。

## 筛选原则

- **只改实现技术、不改语言语义的优先**：程序仍然是 ANSI CL，用户看不到差别，只得到更快的代码、更好的诊断和更好的工具。
- **改语义的（私有扩展）从严**：只作为可选的库或实现包提供，核心语言不变。
- **利用 kiln 自己的结构**：开发期是 JIT 驱动的活 image，交付期 seal 后做 WPO，KIR 输出是确定的（[bootstrap.md](../design/bootstrap.md) 的“确定性”）。能把这几点串起来的做法收益最大。

## 1. 构建期初始化和堆快照

参考 GraalVM Native Image：封闭世界、points-to 分析、tree shaking，构建期执行类的初始化，再把得到的堆直接写进可执行文件。它是现有系统里和 seal 最接近的，而且已经大规模用于生产。

kiln 现在的 AOT 可执行文件只有代码和静态数据。每次启动都要重新执行各模块的顶层形式：建包、CLOS 自举、定义类和泛函。kernel 加 CLOS 加 compiler 模块，启动约 0.65 秒。

做法：
- seal 时在构建进程里执行完所有初始化，把可达的堆对象连同重定位信息写进目标文件的数据段。启动时映射进来，作为 MMTk 的不动区域（类似 SBCL core 的静态空间），不再执行顶层形式。
- 哪些初始化能放到构建期执行，要有明确规则。GraalVM 的教训是要能区分“构建期安全”和“必须运行期执行”的初始化：读环境变量、打开文件、取时间、取随机数种子都属于后者。kiln 可以用声明标出，没有标的默认放到构建期执行，遇到不能放的副作用就报错。
- 开发期也能用同一机制保存 image（相当于 `save-lisp-and-die`）。自举时也有用：编完前几个模块后存一个快照，后面的阶段从快照启动。

和已有设计的关系：反射式入口（`find-class`、`symbol-function` 等）的保留集合已经写在 [positioning.md](../design/positioning.md) 的 seal 语义里，可以直接参照 GraalVM 的 reachability metadata 来设计格式。

## 2. 依赖追踪和增量重编译

参考 rustc 的 query 系统和 Salsa：每次计算都记下读过的输入，输入变了就精确地让依赖它的结果失效。

传统 CL 实现在活 image 里有一个老问题：重定义宏、内联函数、`defstruct`、`defconstant`、类型声明之后，已经编好的使用者不会跟着更新。SBCL 只发一个警告，靠用户自己重新加载。

kiln 的做法：
- 编译每个函数时记录它的编译期依赖：展开过哪些宏（包括 compiler macro）、内联了哪些函数、用了哪些常量和 `defstruct` 布局、依赖哪些 `declaim`。
- 重定义某个定义时，按记录找出依赖者并重新编译（开发期在 JIT 里做），或者至少准确列出哪些代码过时了。
- 这些记录和 [debugging.md](../design/debugging.md) 的调试数据（定义记录、宏展开追踪）是同一类数据，格式要一起定。
- seal 时同一份依赖图还能用来判断哪些定义可以删掉。

这是“现代重写”最能直接改善开发体验的一项。

M6.4 已经做了在 image 里求值的定义这一部分：宏、内联函数、`setf` 展开器和常量（[dependencies.md](../design/dependencies.md)）。AOT 编出的模块还没有。

## 3. 开发期收集 profile，seal 时做 PGO

开发期运行在 JIT 上，正好可以顺带收集运行信息：
- 泛函调用点实际命中了哪些方法，是单态、少态还是多态；
- 分支的冷热和循环次数；
- 调用点上参数的实际类型（fixnum、double-float、某个类）。

seal 时把这些数据交给 WPO：
- 单态调用去虚化，再内联；少态调用生成按类判断的分支；
- 按热度布局代码，冷路径挪出去；
- 按观察到的类型特化，配合下面第 4 条的拆箱。

profile 可以存成文件随项目提交，和 Go、Rust 的 PGO 一样，构建结果仍然确定。

运行期的部分：CLOS 调用点加内联缓存。Clostrophilia 的 stamp 分派（[clos.md](../design/clos.md)）已经提供了 stamp，调用点缓存“stamp 对应的方法函数”，未命中时才走分派自动机。这个改动不依赖 seal，开发期就能提速。

## 4. 中端：逃逸分析、分配消除和拆箱

CL 代码的性能损失有很大一部分来自堆分配：`&rest` 列表、闭包、装箱的浮点数、`multiple-value-list`、只用一次的临时 cons 和向量。

参考 HotSpot C2 和 Graal 的逃逸分析和 scalar replacement，以及 LuaJIT 的 allocation sinking：
- 在 KIR（或者 KIR 之前的一层 SSA 中端）上做逃逸分析。不逃逸的对象拆成局部变量，只在逃逸路径上才真正分配（sinking）。
- 浮点数和 `(unsigned-byte 64)` 在函数内部保持拆箱，只在跨调用、写进堆的时候装箱。
- `&rest` 参数只被 `apply` 或 `dolist` 使用时，不再分配列表。

这些都在 kiln 自己的中端里做，Cranelift 只负责机器相关的优化。GC 规则（[gc.md](../design/gc.md)）要随之明确：拆箱的值不进栈图，内部指针仍然不允许。

## 5. 并行编译和内容寻址缓存

- kiln-cg 已经按函数并行调用 Cranelift（所有核，`KILN_CG_THREADS` 可改）：五个模块约 15 秒，峰值内存约 9.5 GB。剩下的是 KIR 的读入和 CLIF 的构造，它们仍是单线程的，内存也主要花在这里（整个程序的 KIR 和 CLIF 同时在内存里）。
- 因为 KIR 是确定的，kiln-cg 的输出也只取决于 KIR（[codegen.md](../design/codegen.md) 的“确定性”），每个函数的 KIR 加上编译选项和 ABI 指纹（[abi-policy.md](../design/abi-policy.md)）可以算出哈希，作为机器码缓存的键（思路同 Bazel、Nix、Unison）。重复编译（测试、自举、开发期重新加载）直接命中缓存。
- Lisp 侧的前端在一个模块之内是顺序的（顶层形式会改变编译期环境），但模块之间、以及展开完成之后的降级（`lower.lisp`）可以并行。这需要 kiln 先支持多线程的 Lisp 代码，见下面的内存模型。

## 6. 诊断和工具协议

- **结构化诊断**：CST 带着源码位置，可以给出 rustc 风格的报错：源码片段、标出范围、说明、修复建议。不要再只输出 `; caught WARNING` 加形式的打印。诊断用对象表示（condition 类加位置信息），打印只是其中一种呈现方式。
- **LSP 和 DAP**：在 SLIME/SLY（swank）之外，提供 Language Server Protocol 和 Debug Adapter Protocol 的服务端，让不依赖 Emacs 的编辑器也能用上 image 内的补全、跳转、调用者查询和调试。服务端用 Lisp 写，作为库运行在 image 里。
- **DWARF**：AOT 和 JIT 的代码都输出 DWARF 行号表和 CFI，让 gdb、perf、rr 能直接显示 Lisp 函数名和源码位置（JIT 走 GDB 的 JIT 接口）。现在调试要靠 perf map 加帧指针手工走栈。

## 7. 测试方法

- **差分测试**：kiln 和 SBCL 跑同一程序比较输出，M5 的 KIR 比对就是一种。可以扩展成随机生成程序（参考 Csmith 和 YARPGen，生成没有未定义行为的 CL 子集），分别在 SBCL、kiln 的 JIT 和 AOT 上运行，比较结果。
- **编译器 fuzzing**：对 reader、前端、`lower.lisp` 做覆盖率引导的 fuzzing，找崩溃和不变量被破坏的情况。
- **GC 验证**：在现有 gc-stress（小堆、频繁的移动式 GC）的基础上，加一个验证模式：每次 GC 前后遍历堆，检查每个指针都指向合法对象、栈图覆盖了所有活着的值。
- **确定性**：自举的 KIR 逐字节比对已经保证了编译器的确定性，要作为 CI 的常规检查保留下来。

## 8. 内建的性能分析器

已实现，见 [debugging.md](../design/debugging.md) 的“性能分析器”。下面是当时的设想。

现在定位热点要靠 perf map 加帧指针手工走栈，AOT 程序要用 gdb 一次次 attach（[performance.md](performance.md) 的“测量方法”）。kiln 已经有两样现成的零件：每个函数都有的 poll 点（[abi.md](../design/abi.md)），和每一帧的调试信息（[debugging.md](../design/debugging.md)）。
- **采样分析器**：定时器只设置 ctx 上的一个标志，下一个 poll 点记录当前的 `frame-list`。不需要信号处理里走栈，结果直接带 Lisp 函数名和源码位置。
- **分配分析器**：每分配 N 字节采样一次调用栈。[performance.md](performance.md) 指出 GC 压力来自 `&rest` 列表、浮点装箱、initarg 列表、堆上的 handler，要回答的正是“谁在分配”。
- 结果经后端协议（[backend-protocol.md](../design/backend-protocol.md)）输出，也能导出成火焰图的格式。

这是性能工作（[performance.md](performance.md)）的第一步：没有它，优化只能靠猜。

## 9. image 和源码的同步

活 image 的老问题：image 里的定义和磁盘上的源码会悄悄分叉，比如在 REPL 里改了函数却没存回文件，或者文件改了却没重新载入。Smalltalk 一族用了几十年处理它，Pharo 的 Epicea 把对 image 的每一次修改记成日志，可以回放、查看、恢复。

kiln 的依赖追踪已经按定义记下了形式和 `*package*`（[dependencies.md](../design/dependencies.md)），再往前一步：
- 每次求值一个定义，记下它的来源：哪个文件的哪个位置，还是 REPL、后端协议的哪个任务；
- 列出“image 里和文件里不一致的定义”，IDE 里可以逐个写回文件或者重新载入；
- 存快照（[heap-image.md](../design/heap-image.md)）时提醒还没写回源码的修改；
- 修改日志本身可以回放，用来在新的 image 里重建一次会话。

这和定义表（[debugging.md](../design/debugging.md) 的“定义记录”）、重新载入文件时按定义对比（[roadmap.md](../roadmap.md)）用的是同一组数据，应该一起设计。

## 10. 记录与回放调试

参考 rr 和 Pernosco：记录一次运行的所有非确定性输入，之后确定性地重放，在重放中可以回到任意时刻。

kiln 的非确定性来源都有集中的入口：系统调用都经过 `kiln_rt_sys`，以后的 fiber 调度经过 Lisp 的调度器，定时器和抢占经过 poll 点。记录这些输入（系统调用的结果、调度的选择、poll 点上的事件），就能重放。配合帧的调试信息，可以从出错的地方往回找。

工作量不小，而且要求系统接口和调度器的设计留出记录点。等 fiber 和系统接口（[editor.md](../design/editor.md) 的“系统接口”）定下来再考虑；那时要确保所有的非确定性都经过可以记录的入口。

## 11. 统一的项目工具和包管理

CL 现在的组合是 ASDF、Quicklisp 加各种脚本，问题在于：
- **系统定义是要执行的代码**：`.asd` 是 Lisp 程序，要知道依赖就得先运行它，工具没法只“读”一个项目。
- **构建就是往当前 image 里载入**：编译顺序就是载入顺序，副作用互相渗透；增量编译只看 fasl 的时间戳，宏改了，用它的文件不会重编。
- **没有版本和锁文件**：Quicklisp 是每月一次的整体快照，没有版本约束，也没有按项目隔离的依赖。Qlot、CLPM、ocicl 都是社区补这个缺口的尝试。

现代语言的普及，工具的体验和语言本身一样重要（Cargo、Go 的 `go` 命令）。kiln 的编译单元也和 ASDF 的模型不一样：KIR 模块、按定义的依赖追踪（[dependencies.md](../design/dependencies.md)）、seal 和 WPO 的交付。ASDF 只懂“文件到 fasl 再载入”，用不上这些。kiln 自己的 `deps.lock` 和 `tools/*.sh` 已经是一个雏形。

计划（先让 ASDF 和 UIOP 在 kiln 上运行，再做 Cargo 式的工具；一个 image 一个版本、最小版本选择）见 [roadmap.md](../roadmap.md) 的“项目工具和包管理”。

## 12. 统一的格式化器和带修复建议的 linter

参考 gofmt、rustfmt、clippy。Eclector 读出的 CST 带源码位置，如果再保留注释，就能做一个“唯一正确格式”的格式化器，省掉风格的争论。缩进规则以 Emacs 的 lisp-mode 为基准，宏的缩进由宏自己声明。linter 输出结构化的诊断加自动修复（“诊断和工具协议”），经 LSP 或后端协议交给编辑器和 agent。linter 的规则可以利用活 image 里的知识（宏的真实展开、函数的真实签名），比纯静态分析准确。

## 13. 内容寻址的定义

参考 Unison：每个定义按规范化的形式算出哈希，作为它的身份。kiln 不改变语言模型，只在实现层面借用：
- 编译缓存可以跨会话、跨机器复用（“并行编译和内容寻址缓存”）；
- 依赖追踪判断“有没有变”时直接比较哈希（[dependencies.md](../design/dependencies.md) 现在比较的是 KIR 和 literal）；
- 改名、移动文件不影响缓存和依赖。

规范化要去掉的东西：源码位置、gensym 的编号、局部变量的名字（调试信息另存）。

## 14. 扩展的能力沙箱

参考 object-capability 的做法和 VS Code 的工作区信任。编辑器的扩展来自第三方，发行版里可以按能力限制它们：文件系统、网络、子进程、修改核心定义。seal 时声明的扩展点（[editor.md](../design/editor.md) 的“扩展模型和 seal”）是天然的边界：扩展只能拿到被授予的能力对象，核心只在声明的扩展点上调用扩展代码。属于发行期的工作。

## 暂不采用

- **投机优化和去优化（deopt、OSR）**：这是 HotSpot 和 V8 性能的核心，但 Cranelift 不支持去优化（没有帧状态和重建解释器帧的机制），自己做的成本很高。kiln 用第 3 条的思路，开发期收集、seal 时静态利用，可以拿到单态内联的大部分收益，又不需要运行期投机。等有了明确的性能瓶颈再重新评估。
- **渐进类型和静态类型检查（类似 Coalton）**：它是语言扩展，适合作为第三方库，不进核心。kiln 能做的是让编译器的类型推导结果对工具可见（第 6 条的诊断里报告推导出的类型冲突），不引入新的语法。
- **e-graph 和超级优化**：Cranelift 已经用 aegraph 做中端的等价改写。kiln 和 SBCL 的差距在 Lisp 语义层（[performance.md](performance.md)），不在这里。
- **另造一套编译期求值（类似 Zig 的 comptime）**：CL 的宏和 `eval-when` 已经更通用。

## 移到别处的部分

- 多线程的内存模型：[runtime-constraints.md](../design/runtime-constraints.md) 的“待定：内存模型”。
- 异步只作为实现扩展、不改变语言：[async.md](../design/async.md) 的“异步不改变语言”。
- 各项的优先级和时机：[roadmap.md](../roadmap.md)。

## 待定问题

- 堆快照的格式：直接用目标文件的数据段加重定位，还是单独的 image 文件（可以 mmap、可以共享）？两种都要支持吗？M6.1 先做了后者：单独的文件或接在可执行文件末尾，映射在固定地址，不需要重定位（[heap-image.md](../design/heap-image.md)）。seal 时写进数据段的做法还没定。
- 依赖追踪的粒度：到函数，还是到顶层形式？重定义时是自动重新编译依赖者，还是只报告、由用户确认？M6.4 的决定：粒度是定义形式；只替换定义的那类定义（`defun`、`defmacro`、`defmethod` 等）自动重新求值，其他的只报告（[dependencies.md](../design/dependencies.md)）。
- profile 数据的格式和稳定性：源码改动之后，旧的 profile 怎么对应到新代码（按定义名加调用点的源码位置）？
- 中端放在哪里：直接在 KIR 上做，还是在 AST 和 KIR 之间新加一层 SSA IR？
