# 调试信息

本文是编译器产出的调试数据和 runtime 的帧接口。工具、编辑器和 agent 怎样使用它们见 [backend-protocol.md](backend-protocol.md)；参考过的系统（LispWorks、Emacs、Racket、Clordane）见 [debugging-references.md](../research/debugging-references.md)。

## 目标

- backtrace：每一帧显示函数名、源文件、当前调用在源码中的位置。
- 帧检查：每一帧显示变量的值。
- **不影响生成的代码**：调试信息只是附加的表。代码和没有调试信息时完全相同，所以自举和性能都不受影响。
- 跳转到定义、who-calls、按文件列出定义、重定义警告、宏展开查看器、单步执行：数据格式由编译器定，界面以后做。这些数据要在 KIR 和 ABI 里留出位置，以后再改代价很大。

## 函数的调试信息对象

每个编译出的函数带一个 Lisp 对象（`lower.lisp` 构造，作为常量放进模块）：

```
#(NAME FILE START END VARIABLES)
```

- `NAME`：backtrace 显示的名字。
- `FILE`：源文件名（编译时的名字），`compile` 编的函数为 NIL。
- `START`、`END`：函数所在顶层形式在文件中的范围。函数自己的 CST 不可靠：宏展开生成的 `lambda`（`defun` 的展开）的 CST 是 `cst:reconstruct` 造的，范围是宏调用形式的一部分。
- `VARIABLES`：变量名的 simple-vector。闭包会赋值的变量放在 cell 里，记作 `(:cell 名字)`。

名字的规则（参照 SBCL 的写法）：

| 来源 | 名字 |
|---|---|
| `defun`、`defgeneric` 定义的函数 | 函数名，如 `foo`、`(setf foo)` |
| `defmethod` | `(method foo :around (integer t))` |
| `defmacro`、`define-compiler-macro` | `(macro-function m)`、`(compiler-macro m)` |
| `flet`、`labels` | `(flet g :in 外层名字)` |
| `lambda` | `(lambda :in 外层名字)` |
| 顶层形式的代码 | `(:top-level-form)` |

- 外层名字是包含它的函数的名字。直接位于顶层形式中的 `lambda`，外层名字是该定义的名字：`(defvar *x* (lambda ...))` 中的是 `(lambda :in (defvar *x*))`。
- 定义的名字由 `front.lisp` 的 `definition-name` 在宏展开之前从形式算出：上表中的定义宏有专门的规则；其他 CL 包里以 `DEF` 开头的宏，取 `(宏名 名字)`。原生 `eval` 在展开定义宏之前记下它（[eval-compile.md](eval-compile.md)）。
- 展开结果里的定义优先于外层的定义。例如 `defstruct` 展开出的访问函数用自己的名字。
- 这是下文定义记录（dspec）的一个子集，只用于命名。依赖追踪也用它命名定义（[dependencies.md](dependencies.md)）。

## KIR 里的调试数据

```
(func "名字"
  (vars (v obj) (v12 obj 3) ...)     ; 第三项：变量名在 VARIABLES 中的下标
  (slots ...)
  (debug (data "kiln_vector_7" 5))   ; 调试信息对象（静态常量）
  ;; 或 (debug-ref "kiln_literals" 偏移)：存放该对象的字，用于装进运行中 image 的代码
  (block ...))
(call-lisp v0 nv ENTRY (...) H (loc 起始 结束))  ; 可选：调用形式在文件中的范围
(call-rt "名字" (...) (...) H (loc 起始 结束))
```

- 源码范围取自调用形式（`application-ast`）的 CST。宏展开生成的调用没有自己的范围，就用外层调用的范围。
- 只有绑定源码变量的 KIR 变量才带下标。源码变量指名字在顶层形式（宏展开之前、按原样写出的形式）中出现过的变量，不要求有源码位置，所以 `eval` 编出的代码也有变量名。不带下标的有：
  - 编译器的临时变量；
  - 宏引入的变量：名字不出现在形式中。它们对调试没有用；而且 Common-macros 这类宏库的包在宿主和 kiln 上名字不同，写进 KIR 两边就不一致了；
  - 局部函数对象；
  - 退出用的令牌。
- 文件名和位置都写进了 KIR，所以 SBCL 和 kiln 读同一个文件时必须得到相同的名字和偏移（[front-end.md](front-end.md) 的“确定性”）。

## kiln-cg：变量在哪里

调试信息只在调用点上有意义：除了正在执行的那一帧，每一帧都停在一次调用上，而正在执行的帧是 runtime 或 debugger 自己。

- 在调用期间仍然活着、需要栈图的值，cranelift-frontend 都放在栈槽里：每个这样的值在整个生命期内占一个槽，值定义之后立即存入，槽列在调用的栈图里，GC 也会更新它（[gc.md](gc.md)）。所以每个调用点上，活着的 Lisp 变量都可以在一个已知的栈槽里找到，不需要处理寄存器。
- kiln-cg 在 `FunctionBuilder::finalize` 之后（这时已经插入了存槽指令）分析 IR：
  1. 值的标签：KIR 变量带下标时，每次赋给它的 SSA 值都记上这个下标。SSA 构造产生的块参数，如果所有传入值的标签都相同，就继承这些标签。取最小不动点，结果与遍历顺序无关。
  2. 槽中的值：沿支配树深度优先遍历，维护“槽 → 最近一次存入的值”，带撤销日志。一个槽只有在其中的值死亡之后才会被复用，在调用点活着的值一定定义在调用点的支配者中，所以在支配序上离调用点最近的那次存入，就是调用期间槽里的值。
  3. 每个调用指令用 srcloc 标上调用序号。编译完成后，按返回地址找到序号，再取帧布局中各槽相对 SP 的偏移。
  4. 只保留出现在该调用点栈图里的偏移，和 GC 看到的一致。
- 变量的值是调用时的值。调用之后不再用到的变量已经死亡，不显示，和优化编译的调试器一样。

## 运行期的表

每个函数一条记录（`kiln_rt::debug::FuncDebugRecord`，48 字节）：

| 字段 | 内容 |
|---|---|
| 代码起始地址 | |
| 代码长度 | |
| 调试信息对象 | 对象本身，或存放它的字的地址（标志位 0）；0 表示没有 |
| 标志 | |
| 调用点数据 | 地址和长度 |

- 调用点数据是变长整数序列，按返回地址递增排列。每个调用点依次是：返回偏移；起始 + 1（0 表示没有源码范围）；结束（有起始时才有）；变量个数；每个变量的名字下标和槽偏移（字）。只记有源码范围或有变量的调用点。
- 记录的来源：AOT 的模块信息；JIT 运行的程序在 `register_code` 里；装进运行中 image 的代码在 `code::register` 里，它保留一份副本，堆快照保存它。
- 记录在启动时只是追加进表，第一次查找时才排序，所以不增加启动时间。
- 查找：按返回地址二分查找函数，再顺序解码它的调用点。
- seal 时可以整个去掉，或者只留函数名。

## 走栈

`kiln_rt_frame(ctx, op, a, b)`：

- 帧用句柄表示：它所调用的那一帧的帧指针。句柄 + 8 处是返回地址，在本帧的函数里；句柄 + 16 是调用时的 SP。句柄是对齐的地址，在 Lisp 里就是 fixnum。
- 走栈的方式和 GC 相同：沿帧指针链，先走当前栈段，再走挂起的栈段。只返回返回地址落在有记录的函数里的帧。
- 不分配内存。帧列表填进 Lisp 传入的 simple-vector，放不下时 Lisp 换一个更大的向量重试。

## Lisp 接口（`kiln.sys`，`lisp/target/clos/debug.lisp`）

| 函数 | |
|---|---|
| `(frame-list)` | 栈上 Lisp 帧的句柄，由内向外，第一个是调用者的帧 |
| `(frame-name f)` | 函数的名字 |
| `(frame-source f)` | 文件名，当前调用的起止位置（没有时取函数的范围） |
| `(frame-variables f)` | `((名字 . 值) ...)`，cell 中的变量取 cell 的内容 |
| `(frame-pc f)` | 返回地址和在函数中的偏移 |
| `(source-line file pos)` | 行（从 1 起）和列（从 0 起） |
| `(print-frame f stream &key variables)`、`(print-backtrace &key stream frames count variables)` | |
| `(exit &optional code)` | 结束进程 |

**默认的 debugger**：打印 condition 的报告，以及 `invoke-debugger` 之外的帧（最多 30 帧，带变量），然后以状态 1 退出。环境变量 `KILN_BACKTRACE=0` 时不打印 backtrace。打印本身出错时，退回只打印 condition 的类和槽。

## 性能分析器

`rust/kiln-rt/src/profile.rs`、`lisp/target/clos/profile.lisp`。用的是已有的两样零件：poll 点和函数的调试信息，不需要在信号处理里走栈。

- **CPU 模式**：一个定时器线程按间隔（默认 1 ms，实际时间）累加 tick，并对被分析的 context 请求 poll（设置 `poll_flag`，抬高 `stack_limit`）。下一个 poll 点（函数入口、循环头）进入 `kiln_rt_poll`，沿帧指针链记下栈上各帧所在的函数（最多 256 帧，跨过栈段），权重是上次采样以来的 tick 数。所以一次很长的 runtime 调用（bignum 运算等）按它的时长计在调用它的 Lisp 帧上，不会因为中间没有 poll 点而少算。偏差是 safepoint 偏差：样本落在 poll 点，而不是精确的指令上。
- **分配模式**：分配的慢路径（bump 分配器的缓冲用完，或者大对象）记录栈，权重是上次采样以来分配的字节数。编译出的代码内联分配，只在缓冲用完时进入 runtime，所以这是按缓冲大小（几十 KB）的采样。
- 样本按栈聚合，记的是各帧函数的起始地址；Lisp 经 `kiln_rt_frame` 的 PROFILE 操作读出，按调试信息对象取名字，不分配。
- **Lisp 接口**（`kiln.sys`）：`start-profiler`（`:mode :cpu`/`:alloc`，`:interval` 微秒）、`stop-profiler`、`profile-samples`（`(权重 . 函数名列表)`，最内层在前）、`profile-report`（按自身权重和按在栈上的总权重各列一张表）、`write-folded-stacks`（火焰图工具的 folded 格式）、`with-profiling`。
- **整个程序**：`KILN_PROFILE=cpu[:微秒]` 或 `alloc` 在启动时开始采样，程序结束（正常结束或 `exit`）时把 folded 栈写到 `KILN_PROFILE_OUT`（默认 `kiln-profile.folded`），并在标准错误上打印摘要。不用改程序就能分析编译器自己。程序自己调用 `start-profiler` 时，之前的样本被丢弃。
- **外部 profiler**：`KILN_FUNCTION_MAP=路径` 在启动时写出每个函数的起始地址（十六进制）和名字，一行一个，用来给 perf 等报告的 AOT 函数（它们只看到 KIR 标签）换上 Lisp 的名字。JIT 用 `KILN_PERF_MAP=1`（[codegen.md](codegen.md)）。

## 限制

- 闭包从静态环境读取的变量不显示：每次使用时才从函数对象里读，不在帧里。可以在调试信息中记下环境下标和变量名，再从帧的 `self` 读出来，但 `self` 也不一定活着。
- 出错那一帧的变量往往看不到：错误之后不再用到的变量已经死亡。要有一个调试优化级别：在 `(optimize (debug 2))` 下让所有变量活过出错路径上的调用（SBCL 的做法）。默认级别下不这样做，因为它会改变生成的代码。
- 源码位置是八位组偏移，行号要打开文件重新数（`source-line`）。

## 定义记录（dspec，格式已定，还没有实现）

参考 LispWorks 的 dspec 和 Emacs 的 `load-history`。Emacs 的教训是：不记位置、靠正则搜索找回来，宏生成的定义就很难找；kiln 有 CST，可以直接记位置。

- 名字采用 LispWorks 的规范形式 `(类 主名字 . 限定)`，用 `equal` 比较。符号单独出现时表示函数。
- 第一批类：`defun`、`defmacro`、`defgeneric`、`defmethod`（限定为方法限定符加特化列表）、`defclass`、`defstruct`、`define-condition`、`defvar`（`defparameter` 是别名）、`defconstant`、`deftype`、`defsetf`、`define-setf-expander`、`define-compiler-macro`、`define-method-combination`、`defpackage`。
- 位置：`(文件 起始偏移 结束偏移)`，取自顶层形式的 CST。子定义多一项父 dspec。文件用编译时的名字，交付期可以去掉。
- 记录点在顶层形式处理里：
  - 宏展开之前，按顶层形式的 car 查一张表算出 dspec。这张表相当于 LispWorks 的 form parser，用户可以扩展（名字待定，比如 `kiln:define-dspec-parser`）；表里没有的定义宏，按 `DEF` 前缀的默认规则处理。
  - 展开之后，结果里的 `defun` 等记为子定义，例如 `defstruct` 展开出的访问函数。
- KIR 模块加一个顶层条目 `(defs (dspec 位置) ...)`，dspec 是普通数据。模块初始化时，把这些记录装进 image 里的定义表。
- 同一个 dspec 被另一个文件重新定义时，载入时发出警告。这是重定义屏障（C4）的一部分；对哪些包报错、对哪些包只警告，可以配置。
- 局部函数复用函数标签的名字提示：`(flet g (defun f))` 写进函数的调试信息。
- seal 时，tree shaking 用定义表知道每个函数来自哪个定义。依赖追踪、重新载入文件、image 和源码的同步都用这张表。

## 宏展开的追踪（计划）

- Eclector 的 CST 加上 `cst:reconstruct`，已经能让展开结果里和原参数 `eq` 的部分回到源码位置。这和 LispWorks 的规则一样。
- 在两个地方发出“宏名、展开前的 CST、展开后的 CST”事件：顶层形式处理的宏展开，以及 `cb::convert` 的 `:around`（inline 展开已经挂在这里）。先做一个 `kiln:trace-expansions` 调试 kiln 自己。
- 展开结果里不来自原始源码的部分，标上生成它的宏的调用位置，这样源码位置至少能指到那个宏调用。
- 宏展开查看器（只看用户自己的宏的隐藏策略、逐步展开）建立在这个事件流上，参照 Racket 的 macro stepper。

## 单步和断点（计划）

- 不在机器码上打断点。Cranelift 不做去优化，机器码层面的断点很难做对。
- 按 Clordane 的方式在源码形式前后插入检查，但不默认插入：用户对某个函数要求单步时，用 JIT 重新编译一份带检查的版本，替换函数格里的入口，借助重定义屏障（C4）。检查先看 `ctx` 上的标志（和 poll 点共用），再看按 PC 取模的摘要位表，最后才查断点表；不在调试时开销只是一次标志检查。
- 需要源码位置、变量位置和交互式 debugger，这些都已经有了。
