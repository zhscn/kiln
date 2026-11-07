# 17 调试信息和后端协议（M6.2、M6.3）

**状态**：M6.2 帧的调试信息已完成（2026-11）。M6.3 后端协议（批处理 REPL 和嵌套式 debugger）还没做。

这是 [11](11-m5-self-hosting.md) §4.2 计划的实现：§4.2 定的是调用点描述符加源码位置，变量位置留到 M6。两者在这里一起做了。

## 1. 目标

- backtrace：每一帧显示函数名、源文件、当前调用在源码中的位置。
- 帧检查：每一帧显示变量的值。
- 不影响生成的代码：调试信息只是附加的表。代码和没有调试信息时完全相同，所以自举和性能都不受影响。
- 后端协议（§4）建立在这些接口上，编辑器（[16](16-editor.md)）、外部工具和 agent 共用。

## 2. 数据

### 2.1 函数的调试信息对象

每个编译出的函数带一个 Lisp 对象（lower.lisp 构造，作为常量放进模块）：

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
- 定义的名字由 front.lisp 的 `definition-name` 在宏展开之前从形式算出：
  - 上表中的定义宏有专门的规则；
  - 其他 CL 包里以 `DEF` 开头的宏，取 `(宏名 名字)`。
- 展开结果里的定义优先于外层的定义。例如 `defstruct` 展开出的访问函数用自己的名字。
- 这是 [11](11-m5-self-hosting.md) §4.1 dspec 的一个子集，只用于命名。定义表和重定义警告还没做。

### 2.2 KIR

[06](06-m0-abi.md) §8 的语法增加了三处：

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
- 只有绑定源码变量的 KIR 变量才带下标。源码变量指变量定义的源码范围恰好是名字本身，即范围的长度等于符号名的长度。不带下标的有：
  - 编译器的临时变量；
  - 宏引入的变量：`cst:reconstruct` 新造的 CST 用宏调用形式的范围。这些变量对调试没有用；而且 Common-macros 这类宏库的包在宿主和 kiln 上名字不同（[11](11-m5-self-hosting.md) §3），把它们写进 KIR，两边就不一致了；
  - 局部函数对象；
  - 退出用的 token。
- 文件名和位置都写进了 KIR，所以 SBCL 和 kiln 读同一个文件时，必须得到相同的名字和偏移：
  - 偏移是 `file-position` 的值，即八位组偏移。kiln 的文件流以前没有扣除 `unread-char` 退回的字符，所以 Eclector 读到的形式起点在 kiln 上晚一个字符；现在扣除了（`files.lisp`）；
  - 编译一个模块时，文件名必须和 SBCL 用的相同（测试 `co-kernel` 改为用 `module-files`）。

### 2.3 kiln-cg：变量在哪里

调试信息只在调用点上有意义：除了正在执行的那一帧，每一帧都停在一次调用上。正在执行的帧是 runtime 或 debugger 自己。

- 在调用期间仍然活着、需要栈图的值，cranelift-frontend 都放在栈槽里：
  - 每个这样的值在整个生命期内占一个槽；
  - 值定义之后立即存入；
  - 槽列在调用的栈图里，GC 也会更新它（[07](07-m1-gc.md) §4）。
  
  所以每个调用点上，活着的 Lisp 变量都可以在一个已知的栈槽里找到，不需要处理寄存器。
- kiln-cg 在 `FunctionBuilder::finalize` 之后（这时已经插入了存槽指令）分析 IR：
  1. 值的标签：KIR 变量带下标时，每次赋给它的 SSA 值都记上这个下标。SSA 构造产生的块参数，如果所有传入值的标签都相同，就继承这些标签。取最小不动点，结果与遍历顺序无关。
  2. 槽中的值：沿支配树深度优先遍历，维护「槽 → 最近一次存入的值」，带撤销日志。
     - 一个槽只有在其中的值死亡之后才会被复用；
     - 在调用点活着的值，一定定义在调用点的支配者中；
     
     所以在支配序上离调用点最近的那次存入，就是调用期间槽里的值。
  3. 每个调用指令用 srcloc 标上调用序号（第几个 `call-lisp`/`call-rt`）。编译完成后，按返回地址找到序号，再取帧布局中各槽相对 SP 的偏移。
  4. 只保留出现在该调用点栈图里的偏移，和 GC 看到的一致。
- 变量的值是调用时的值。调用之后不再用到的变量已经死亡，不显示，和优化编译的调试器一样。

### 2.4 运行期的表

每个函数一条记录（`kiln_rt::debug::FuncDebugRecord`，48 字节）：

| 字段 | 内容 |
|---|---|
| 代码起始地址 | |
| 代码长度 | |
| 调试信息对象 | 对象本身，或存放它的字的地址（标志位 0）；0 表示没有 |
| 标志 | |
| 调用点数据 | 地址和长度 |

- 调用点数据是变长整数序列，按返回地址递增排列。每个调用点依次是：
  - 返回偏移；
  - 起始 + 1（0 表示没有源码范围）；
  - 结束（有起始时才有）；
  - 变量个数；
  - 每个变量的名字下标和槽偏移（字）。
  
  只记有源码范围或有变量的调用点。
- 记录的来源：
  - AOT：`kiln_module_info` 新增两项（记录数组和个数）；
  - JIT 运行的程序：`register_code`；
  - 装进运行中 image 的代码：`code::register`，它保留一份副本，堆快照保存它（[15](15-heap-image.md) §3）。
- 记录在启动时只是追加进表，第一次查找时才排序，所以不增加启动时间。
- 查找：按返回地址二分查找函数，再顺序解码它的调用点。

### 2.5 走栈

`kiln_rt_frame(ctx, op, a, b)`：

- 帧用句柄表示：它所调用的那一帧的帧指针。句柄 + 8 处是返回地址，在本帧的函数里；句柄 + 16 是调用时的 SP。句柄是对齐的地址，在 Lisp 里就是 fixnum。
- 走栈的方式和 GC 相同：沿帧指针链，先走当前栈段，再走挂起的栈段（[07](07-m1-gc.md) §7）。只返回返回地址落在有记录的函数里的帧。
- 不分配内存。帧列表填进 Lisp 传入的 simple-vector，放不下时 Lisp 换一个更大的向量重试。

### 2.6 Lisp 接口（`kiln.sys`，`lisp/target/clos/debug.lisp`）

| 函数 | |
|---|---|
| `(frame-list)` | 栈上 Lisp 帧的句柄，由内向外，第一个是调用者的帧 |
| `(frame-name f)` | §2.1 的名字 |
| `(frame-source f)` | 文件名，当前调用的起止位置（没有时取函数的范围） |
| `(frame-variables f)` | `((名字 . 值) ...)`，cell 中的变量取 cell 的内容 |
| `(frame-pc f)` | 返回地址和在函数中的偏移 |
| `(source-line file pos)` | 行（从 1 起）和列（从 0 起） |
| `(print-frame f stream &key variables)`、`(print-backtrace &key stream frames count variables)` | |
| `(exit &optional code)` | 结束进程（kiln_rt_sys 的新操作 18） |

默认的 debugger 改为：打印 condition 的报告，以及 `invoke-debugger` 之外的帧（最多 30 帧，带变量），然后以状态 1 退出。环境变量 `KILN_BACKTRACE=0` 时不打印 backtrace。以前的默认 debugger 只打印 condition 的类和槽，现在只在打印本身出错时使用。

### 2.7 测试

`tests/m6/clos-frames.lisp` 覆盖以下内容：

- `defun`、`flet`（被内联后的样子）、`defmethod`、`lambda` 帧的名字；
- 文件、行和列；
- 活着的变量和 cell 中的变量；
- 从 handler 里看出错的帧。

JIT、GC 压力和 AOT 三遍输出相同。

文件名写进了 KIR，所以 `tools/test.sh` 把测试源文件都换成绝对路径交给 SBCL。比较 KIR 的测试（`co-compile`、`co-kernel`）在 kiln 上也用同样的名字。修正 `file-position` 之后，`fe-read` 的期望输出改成了正确的位置。

### 2.8 代价

| | 之前 | 之后 |
|---|---|---|
| kiln1（strip 后） | 69 MB | 77 MB |
| 自举每个阶段 | 约 5.5–6 分钟 | 339 s，没有变慢 |

- 增加的 8 MB 中：
  - 函数记录（约 3.1 万个函数，每个 48 字节）1.5 MB；
  - 调用点数据 1.8 MB；
  - 其余是调试信息对象（向量、名字表、名字里的列表）。
- 生成的代码不变。
- seal 时可以整个去掉，或者只留函数名。

## 3. 还没做

- 闭包从静态环境读取的变量不显示：每次使用时才从函数对象里读，不在帧里。可以在调试信息中记下环境下标和变量名，再从帧的 `self` 读出来，但 `self` 也不一定活着。
- 源码位置是八位组偏移，行号要打开文件重新数（`source-line`）。
- `compile` 编出的函数名是 `(lambda)`；`load` 逐个读取形式再求值，没有文件和位置。
- 单步、断点、在帧中求值、从帧返回、重新执行帧：在 [11](11-m5-self-hosting.md) §4.4 的方案上做，需要后端协议。
- 定义表（dspec 和位置）、who-calls：[11](11-m5-self-hosting.md) §4.1。

## 4. 后端协议（M6.3，待定）

见下一步。
