# 调试信息

本文是编译器产出的调试数据和 runtime 的帧接口。工具、编辑器和 agent 怎样使用它们见 [backend-protocol.md](backend-protocol.md)；参考过的系统（LispWorks、Emacs、Racket、Clordane）见 [debugging-references.md](../research/debugging-references.md)。

## 目标

- backtrace：每一帧显示函数名、源文件、当前调用在源码中的位置。
- 帧检查：每一帧显示变量的值。
- **调试元数据**：函数名、调用位置和变量描述保存在模块附表中；单步观察点在请求插桩的词法范围内生成。
- 跳转到定义、who-calls、按文件列出定义、重定义警告、宏展开查看器：数据格式由编译器定，界面以后做。这些数据要在 KIR 和 ABI 里留出位置，以后再改代价很大。

## 函数跟踪

`trace` 和 `untrace` 接受全局函数名和 `(setf name)`，将调用参数、返回的全部值或非局部退出写到 `*trace-output*`。`(trace)` 返回当前跟踪的名字，`(untrace)` 取消全部跟踪。跟踪深度和报告期间的重入保护使用特殊变量，随动态环境恢复。

普通函数通过全局函数绑定的包装实现跟踪。定义变更通知会重新包装新定义，取消跟踪时恢复最新定义；已经编译的内联调用和此前取得的旧函数对象不经过这个包装。

泛函数保留原对象，在可调用入口包装判别函数。安装新的判别函数时更新记录中的实际目标，增删方法和分派缓存更新后仍能跟踪。指向同一泛函数的多个被跟踪名字共用入口记录，最后一个名字取消跟踪时恢复当前判别函数。输出函数和跟踪管理内部调用受重入保护，避免跟踪报告再次触发自身。

## 单步执行

`step` 保留调用点的词法环境、多值和非局部退出，并在其词法范围的函数调用中
插入观察点。函数及参数按原顺序求值，之后、实际调用之前报告
`kiln.sys:step-form-condition`。`step-form` 读取原始形式，`step-args` 读取参数值
列表。宏展开产生的调用也可以出现；词法范围以外的函数体保持其原有代码。

每个观察点先 signal 条件，再调用 `kiln.sys:*stepper-hook*`。钩子默认使用
`*query-io*` 的交互界面，I/S 进入调用，N 越过调用，O 跳出当前插桩调用，C/Q
继续到本次 STEP 结束，输入结束也按继续处理。程序化前端可以替换钩子，或将其
绑定为 NIL 后使用 condition handler；四个重启分别是 `step-into`、`step-next`、
`step-out` 和 `step-continue`，都在 `kiln.sys` 中。

越过和跳出保持参数求值时已经发生的副作用；跳出在回到上一层插桩调用后恢复
观察。钩子和条件处理期间暂时禁用步进，避免前端自己的调用再次暂停。正常完成
会 signal `step-finished-condition`；非局部退出依靠动态绑定恢复之前的步进状态。
嵌套 STEP 有独立的继续和跳出状态。

原生 IR 转换器和 Maclina 字节码编译器共用 `step-forms.lisp` 的包装形式，私有
编译标记分别控制插桩、原始调用和静默代码。局部宏展开器的编译保持静默，完成
通知也不产生额外的调用观察点。

## 编辑器调用

`ed` 把原始请求交给 `kiln.sys:*ed-functions*` 中的函数，按顺序调用直到有函数
返回非 NIL，然后以 T 作为唯一返回值。省略参数时传入 NIL；文件名、pathname 和
函数名由编辑器前端解释。回调的文件系统错误直接向调用者报告。

钩子列表初始为空，没有前端接受请求时报告错误。前端可以动态绑定此列表，或
在启动时登记编辑器入口；派发本身不依赖具体的编辑器应用。

## 反汇编

`disassemble` 接受函数对象、全局函数名、`(setf name)` 或 lambda 表达式，
将指令写到 `*standard-output*`，返回 NIL。lambda 表达式先通过当前的 `compile`
实现编译，检查已有函数不会替换其全局绑定。

原生函数按调试表登记的精确代码范围反汇编，覆盖 AOT 和运行期 JIT 代码；
泛函数和其他可调用实例跟随当前安装的可调用入口。runtime 使用 MIT 许可的
iced-x86 解码器和 Intel 格式输出地址、原始字节及 x86-64 指令。
未登记的入口和循环可调用链报告错误，不推测机器代码的长度。

Maclina 函数和闭包直接解码所属模块的字节码，范围由函数的入口位置和长度确定，
显示指令位置、助记符、长操作数标记和操作数；常量操作数使用模块内索引。

## 对象描述

`describe` 将对象和输出流交给可扩展的 `describe-object` 泛函数，并丢弃该方法返回的全部值。省略流或传 NIL 时使用 `*standard-output*`，T 使用 `*terminal-io*`，也可传入输出流。

默认方法报告对象的类型和按类型提供的信息：数组的维度、元素类型及可显示的内容，哈希表的测试与容量，符号的绑定状态，函数的编译和闭包信息，泛函数的方法数量，以及标准实例的槽值和未绑定状态。打印使用循环检测和有限的深度、长度，NIL 元素类型的数组只报告元数据。用户可以定义更具体的 `describe-object` 方法，接收的是实际输出流。

## 交互式对象检查

`inspect` 使用 `*standard-input*` 和 `*standard-output*`，显示 `describe` 的对象
信息及带编号的子部分。输入编号进入该部分，U 返回上层，R 重新显示，N/P 翻页，
H 或 ? 显示帮助，Q、E 或输入结束退出。每页默认显示 20 项；打印有深度和长度
限制，并检测循环引用。退出返回零个值。

cons 提供 car 和 cdr，数组按 row-major 索引提供元素，标准对象和结构提供槽。
符号、pathname、package 和哈希表提供相应的组成部分；哈希表的每项是持有原始
key 和 value 的 cons。未绑定槽和无法读取的 NIL 元素类型数组会显示状态，
进入这些部分不会读取无效值。

其他输入在全局词法环境中求值，结果写到输出流；读取和求值错误会报告后继续
接受命令。求值期间 `kiln.sys:*inspected*` 动态绑定为当前对象，可以用于检查
或修改它。嵌套检查和退出恢复原有的绑定。

## 函数的调试信息对象

每个编译出的函数带一个 Lisp 对象（`lower.lisp` 构造，作为常量放进模块）：

```
#(NAME FILE START END VARIABLES)
```

- `NAME`：backtrace 显示的名字。
- `FILE`：源文件名（编译时的名字），`compile` 编的函数为 NIL。
- `START`、`END`：函数所在顶层形式在文件中的范围。函数自己的 CST 不可靠：宏展开生成的 `lambda`（`defun` 的展开）的 CST 是 `cst:reconstruct` 造的，范围是宏调用形式的一部分。
- `VARIABLES`：变量名的 simple-vector。闭包会赋值的变量放在 cell 里，记作 `(:cell 名字)`。原始 binary64 位模式的变量描述为 `(:double-bits 名字)`，帧读取器先取齐高低位，再构造浮点对象。

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

前端用顶层 CST 的原始 cons 到源码位置的映射，保留宏展开中传下来的用户子形式
的位置；宏新建的形式继承外层调用位置。追踪事件可在 `process-toplevel` 和
`ir-convert` 的宏展开处记录宏名、展开前后的形式及位置。

宏展开查看器可以基于事件流逐步展示变换，并按包或宏名隐藏库内部展开，
参考 Racket 的 macro stepper。

## 已有函数的断点与单步（计划）

- 不在机器码上打断点。Cranelift 不做去优化，机器码层面的断点很难做对。
- 按 Clordane 的方式在源码形式前后插入检查，但不默认插入：用户对某个函数要求单步时，用 JIT 重新编译一份带检查的版本，替换函数格里的入口，借助重定义屏障（C4）。检查先看 `ctx` 上的标志（和 poll 点共用），再看按 PC 取模的摘要位表，最后才查断点表；不在调试时开销只是一次标志检查。
- 需要源码位置、变量位置和交互式 debugger，这些都已经有了。
