# ABI：调用约定、context 和非局部退出

本文是编译出的 Lisp 代码、kiln-cg 和 kiln-rt 之间的约定。值和对象的表示见 [objects.md](objects.md)，KIR 和模块信息见 [codegen.md](codegen.md)，GC 的规则见 [gc.md](gc.md)。修改 ABI 前先改这里，并同步 `rust/kiln-rt/src/{object,context}.rs` 和 `lisp/abi.lisp`；kiln 对 ABI 的承诺见 [abi-policy.md](abi-policy.md)。

## 调用约定

- **所有 Lisp 函数使用 Cranelift 的 `tail` 调用约定。** 它支持尾调用。更关键的是，`try_call` 调用 `tail` 函数时，异常边上所有寄存器都视为被破坏，所以 unwinder 恢复时不需要还原 callee-saved 寄存器。
- **统一签名**：`(ctx, self, nargs, a0, a1, a2) -> (v0, nvals)`，全部是 i64。
  - `ctx`：context 指针（C1），作为显式的第一个参数。没有用 Cranelift 的 pinned register，这样更可移植，调用 Rust 时也不用特殊处理。
  - `self`：被调用的函数对象，闭包从这里取环境。
  - `nargs`：实际参数个数（裸整数）。被调方在入口检查。
  - `a0`–`a2`：前 3 个参数，多余的寄存器传 0。第 4 个及之后的参数放在 context 的传递区。
  - 返回 `v0` 和 `nvals`：主值和值的个数。第二个及之后的值放在传递区。`(values)` 的主值是 NIL。
- **为什么是 3 个寄存器参数**：6 个参数在 x86-64 上正好都放进参数寄存器，任何调用点都没有栈参数，被调方帧指针加 16 就一定等于调用方在调用点的 SP。GC 遍历栈时因此不需要每个调用点各自的 frame_offset（Cranelift 只为 `try_call` 记录 frame_offset，普通调用没有）。SBCL 在 x86-64 上同样用 3 个寄存器传参。
- **调用全局函数**：从 symbol 的函数 cell 读出函数对象，从函数对象读出入口地址，再 `call_indirect`。重定义时只改 cell。call-site manager 留到以后（[sicl-survey.md](../research/sicl-survey.md) 的 call-site manager 一节）。
- **帧指针**：`preserve_frame_pointers = true`。unwinder、GC 的栈遍历和调试信息的走栈都靠 FP 链。
- **从 runtime 进入 Lisp**：kiln-cg 生成 System V 调用约定的 `kiln_enter(ctx, fobj, entry, nargs, a0)`，在里面转成 `tail` 约定调用，并把自己的帧记为当前栈段的段底。

### 非逃逸局部函数的内部入口

只被已知调用点直接调用的局部函数，可以把捕获项作为额外参数传递。
内部入口仍使用统一签名：捕获项在前，源码参数在后，`nargs` 包含两者，
`self` 传零环境的静态入口对象，供入口 poll 的共享慢路径读取代码地址并重试。
捕获项作为必需参数的前缀，使可选参数的位置与 supplied-p 检查
整体后移；`&rest` 和关键字解析仍只处理源码实参。默认值及特殊参数的动态
绑定维持源码顺序。捕获项使用普通带 tag 的值；可变绑定传共享 cell 对象，退出点传
原有的堆令牌。所有参数沿用寄存器与 context 传递区的根保护规则。

这种内部入口不作为可逃逸或可观察身份的源码函数值暴露。存在这类使用、参数数量
错误的已知调用，或加上捕获项后超出传递区容量时，保留普通闭包入口。源码的
逻辑 lambda list 不变；MIR 在私有入口上显式记录捕获前缀，HIR 原生降级则使用
独立的内部环境布局。MIR 多值调用的捕获项走列表调用的固定前缀，不进入堆上的参数
收集列表；共享 cell 仍可由创建帧的栈槽承载。

### 超过 3 个参数

- 调用方先求出所有参数，然后把第 4 个及之后的参数写进 `ctx.values[0..]`，紧接着调用。
- 被调方在入口处、第一个 safepoint 之前（poll 和参数个数检查的出错路径之前）把它们读进自己的变量。这段时间里没有 safepoint，所以这些字不需要作为 GC root。多值返回也用这块区域，两者的使用时段不重叠。
- `call-arguments-limit` 是 3 + 1021 = 1024，`multiple-values-limit` 是 1022。原来传递区只有 64 个字，Trinsic 的宏在编译期 `apply` 了更多参数，所以加大了。`apply` 和 `multiple-value-call` 在运行期按列表长度分配寄存器和传递区，超过上限时报错。
- `&rest` 的列表在入口处构造，这会分配内存，而传递区里还有没读出的参数。所以构造期间把 `ctx.values_live` 设为传递区里的参数个数，GC 把这些字当作 root，构造完再清零。
  已证明列表及所有尾部不逃逸的入口可为至多八个 cons 使用固定栈槽；引用字段在
  构造前登记为动态环境精确根，超过容量时整条列表采用堆存储。存储选择不改变调用签名。

### lambda list

HIR 前端转换 lambda list 之后（`lisp/hir/convert.lisp`），每个 `&optional` 和 `&key` 参数都有 supplied-p 变量，默认值在函数体里根据 supplied-p 计算，所以函数入口只需要：

1. 读出位置参数：必需参数和 `&optional` 参数，按 `nargs` 选择实参或 NIL，同时设置 supplied-p。这一步在第一个 safepoint 之前。
2. 检查参数个数。
3. 有 `&rest` 或 `&key` 时构造剩余参数的列表。
4. `&key`：检查列表长度是偶数；没有 `&allow-other-keys` 时，除非参数里有 `:allow-other-keys` 且值为真，否则遇到未知关键字报错；每个关键字参数取第一次出现的值。

## Context 布局（C1）

| 偏移 | 字段 | 说明 |
|---|---|---|
| 0 | `poll_flag` | 非零时循环头的 poll 点进入慢路径（C4）；由 `request_poll` 设置，它同时抬高 `stack_limit` |
| 8 | `dynenv` | 最内层的动态环境条目 |
| 16 | `stack_base_fp` | `kiln_enter` 帧的帧指针，GC 栈遍历的终点 |
| 24 | `safepoint_fp` | 最近一次 safepoint 的 trampoline 帧指针，GC 栈遍历的起点 |
| 32 | `mutator` | MMTk mutator |
| 40 | `segments` | 挂起的栈段链（[gc.md](gc.md) 的“栈和栈段”） |
| 48 | `tls` | 特殊变量的 TLS 表 |
| 56 | `values_live` | `values` 里有多少个字当前是 GC root，平时为 0 |
| 64 | `alloc_cursor` | bump 分配器 cursor 字段的地址：编译出的代码就地分配小对象（[gc.md](gc.md) 的“内联分配”） |
| 72 | `alloc_limit` | bump 分配器 limit 字段的地址 |
| 80 | `stack_limit` | 函数入口的帧指针低于它时进入 poll 慢路径：栈快用完了，或者有 poll 请求（这时是 `isize::MAX`，见“Poll 点”）。平时等于只给 Rust 用的 `stack_real_limit`，0 表示不知道栈的范围 |
| 88 | `values[1021]` | 传递区：第 4 个及之后的参数，第二个及之后的返回值。放在最后，改大小不移动别的字段 |

## 动态环境条目

`catch`、`unwind-protect`、特殊变量绑定等在建立它们的帧里用栈槽分配一个 48 字节的条目，链接到 `ctx.dynenv` 上：

| 偏移 | 字段 |
|---|---|
| 0 | kind |
| 8 | prev |
| 16 | fp：建立条目那一帧的帧指针（`get_frame_pointer`） |
| 24 | tag（GC root，不用时写 0） |
| 32 | `pend_target`：待继续的展开目标（cleanup 运行期间），或其他 kind 的附加字 |
| 40 | `pend_value`：待继续的展开值（GC root，不用时写 0） |

| kind | 名字 | 用法 |
|---|---|---|
| 1 | catch | tag 是 catch tag |
| 2 | unwind-protect | |
| 3 | cleanup 运行中 | 正在执行 cleanup 的 unwind-protect 条目（见下文） |
| 4 | 栈边界 | `fp` 是旧栈上 trampoline 的帧指针，`pend_target` 持有新栈（[gc.md](gc.md) 的“栈和栈段”） |
| 5 | 退出点 | 闭包非局部退出的目标 `block`/`tagbody`；tag 是令牌（[lowering.md](lowering.md)） |
| 6 | 特殊变量绑定 | tag 是 symbol，`pend_target` 是 TLS 下标，`pend_value` 是旧的表项 |
| 7 | progv | tag 是 `(symbol . 旧 TLS 值)` 的列表 |
| 8 | 栈引用区 | `pend_target` 是连续 Lisp 引用字段的地址，`pend_value` 是字段个数（原始整数），tag 为 0 |

动态环境条目的所有 Lisp 对象字段都要初始化。通常 GC 扫描 `tag` 和
`pend_value`；kind 8 则仅扫描登记区间的引用字段，不把原始地址和计数当作 Lisp 值。
栈引用区在函数建立后保持链接，正常返回前摘除；非局部展开直接跳过并摘除。
登记字段在链接前清零，栈对象指针本身不交给 MMTk，字段中的堆引用仍会被移动和修正。

## 非局部退出（C3）

**决定：Cranelift 的 `try_call` 加上 kiln 自己的 unwinder。** 正常路径零开销。异常表和 GC 栈图都按“调用点返回地址”组织，属于同一类元数据，相当于 SICL 的调用点描述符。

### 调用点

- 在有活跃条目的区域里，所有可能展开的调用都编译成 `try_call`，带一个 default handler。可能展开的调用包括：Lisp 函数调用，以及声明为 `unwinds` 的 runtime 函数。
- 每个调用点只有一个 handler。handler 收到两个 payload：`exn0` 是目标条目的地址，`exn1` 是传递的值。`exn0` 的第 0 位表示 `exn1` 是打包成列表的多值（条目 8 字节对齐，这一位本来是 0），比较前要屏蔽。handler 先把 `exn0` 和本区域的条目比较：相同就进入本区域的落地代码，否则跳到同一帧里外层区域的 handler。所以同一帧里嵌套多个区域也能正确分派。
- 没有 handler 的条目（特殊变量绑定），它所在区域里的调用使用外层区域的 handler。
- kiln-cg 编译完每个函数后，从 Cranelift 读出带 handler 的调用点，记录（返回地址偏移、handler 偏移、frame_offset），登记给 runtime（[codegen.md](codegen.md) 的“模块信息”）。

### 展开算法（`rust/kiln-rt/src/unwind.rs`）

1. 从 `ctx.dynenv` 栈顶开始逐个弹出条目，直到目标：
   - 中间的 catch、退出点、栈引用区：跳过；
   - 中间的 unwind-protect：把展开目标和值保存在这个条目里，把它标记为 cleanup 运行中（条目留在链上），然后恢复进它所在的帧，执行 cleanup。cleanup 结束时调用 `kiln_rt_continue_unwind`，摘掉条目，继续展开；
   - 已标记为 cleanup 运行中的条目：直接摘掉（原来那次展开被放弃）；
   - 特殊变量绑定和 progv：恢复旧值；
   - 栈边界：恢复旧栈的段信息，把新栈放进待释放列表（unwinder 这时还运行在新栈上，不能立即释放），然后从边界条目记录的旧栈 trampoline 帧继续展开；
   - 到达目标：恢复进它所在的帧，`exn1` 就是传递的值。
2. **恢复进一个帧**：从 trampoline 的帧指针出发沿 FP 链往上走，找到“调用者 FP 等于目标帧 FP”的那一帧，取它的返回地址，也就是目标帧当前活跃的调用点。查表得到 handler 和 frame_offset，然后设置 SP = FP − frame_offset、FP、两个 payload 寄存器（x86-64 上是 rax、rdx），跳转到 handler。做法和 wasmtime 的 unwinder 一致。

只会恢复进 dynenv 里记录的帧，中间没有条目的帧直接越过，不需要扫描它们的表。每个栈各自用自己的 FP 链寻找目标帧，所以展开能跨栈并停在帧标记上。

### cleanup 运行期间条目留在链上

如果 runtime 先把条目从 `ctx.dynenv` 摘下来再跳进 cleanup，暂存在条目里的待传值就不再被扫描，cleanup 一旦分配，这个值就成了悬空指针（GC 压力测试发现的）。所以：

- 条目在 cleanup 运行期间**留在链上**，kind 改为 3。GC 照常扫描它的 `pend_value`。
- 后续的展开再次经过它时，直接摘掉，不会第二次执行 cleanup。cleanup 里再 throw 就是这种情况，原来那次展开随之放弃。
- cleanup 正常结束时调用 `kiln_rt_continue_unwind`。这时它必须是链上最内层的条目，摘掉之后继续原来的展开。
- 编译器在 cleanup 的落地代码外面加一个 `:cleanup-running` 区域。从 cleanup 里做本地退出（`return-from`、`go`）时会先摘掉它；cleanup 里的调用使用外层的 handler。

### 会展开的 runtime 函数经过 trampoline

用 `try_call` 调用 System V 函数时，Cranelift 假设 callee-saved 寄存器在异常边上依然有效，但 Rust 函数被跳出时不会恢复它们。所以 KIR 里标记为 `unwinds` 的 runtime 函数，kiln-cg 会为它生成一个 `tail` 约定的 trampoline（`__kiln_t_<名字>`）。Lisp 代码 `try_call` 这个 trampoline，trampoline 再调用 Rust 函数，并把自己的帧指针作为最后一个参数传过去，作为 unwinder 和 GC 遍历 FP 链的起点。

分配、`kiln_rt_poll` 和所有可能 signal 的 runtime 函数都是 `unwinds`。**凡是可能展开的 native 调用，都经过 `tail` trampoline**，这和 C6 的 FFI trampoline 是同一套机制。

### 本地退出

`return-from` 和 `go` 在同一个函数里时直接跳转。跳转前按从内到外的顺序弹出经过的条目，遇到 unwind-protect 就把 cleanup 内联执行，遇到绑定就恢复旧值。来自闭包的退出见 [lowering.md](lowering.md)。

## 特殊变量（C1 的 TLS 下标方案）

`rust/kiln-rt/src/special.rs`。

- symbol 第一次被动态绑定时，runtime（`kiln_rt_tls_index`）给它分配一个 TLS 下标，写进 symbol 的 TLS 下标槽。下标从 1 开始。
- 每个 context 有一张 TLS 表（`ctx.tls`，目前固定 4096 项）。表项是 NO_TLS 表示这个 context 里没有绑定，回退到 symbol 的全局值。第 0 项永远是 NO_TLS，所以读一个从没被绑定过的 symbol 时不需要先判断下标是否为 0。
- **读**：`v = tls[sym.index]`，是 NO_TLS 就读 `sym.value`，最后检查 UNBOUND。**写**（`setq`、`(setf symbol-value)`）：TLS 表项有值就写表项，否则写全局值。
- **绑定**：在栈上建立一个绑定条目（kind 6），然后写入新值。正常离开和本地退出时从条目恢复旧值；展开经过绑定条目时，unwinder 恢复旧值。
- **`progv`**：绑定的个数运行期才知道，所以只建立一个 progv 条目（kind 7）。先把所有旧值存进列表，再链接条目，最后写入新值，所以展开时看到的列表总是完整的。值不够时，多出来的 symbol 变为未绑定。
- GC 扫描每个 context 的 TLS 表里已分配的项。
- 切换 context（以后的线程、fiber）只需换一张表，O(1)。

## 多值

- 返回约定见上文：主值加值的个数，第二个及之后的值在 `ctx.values` 里。
- `ctx.values` 会被下一次调用覆盖。需要跨过可能调用函数的代码保留多值时（cleanup、`multiple-value-prog1` 的其余形式、`return-from` 途经的 cleanup、为 `multiple-value-call` 收集参数），只有一个值就直接保存它，否则先把值转成列表，事后再展开回 `ctx.values`。
- 转成列表要分配，而值还在 `ctx.values` 里：转换期间 `ctx.values_live` 是值的个数减一，GC 把这些字当作 root。平时它是 0，GC 不扫描 `ctx.values`（那里多半是失效的旧值）。
- **经过展开传递多值**（`throw`、闭包里的 `return-from`）：runtime 的待传值只有一个字。值的个数不是 1 时，先把值转成列表，再传这个列表，并在目标条目地址的第 0 位带上“已打包”标志：到达时在 `exn0` 里，cleanup 拦截期间在 `pend_target` 里。落地代码看到标志就把列表展开回多值。`go` 传递的段下标不打包。

## Poll 点（C4）

函数入口和每个 tagbody 标签（也就是循环头）都插入 poll。循环头读取 `ctx.poll_flag`，非零就调用 `kiln_rt_poll`；函数入口只比较帧指针和 `ctx.stack_limit`（一次比较一次分支，和 V8 用栈界限传中断一样）。请求 poll 的一方（`request_poll`）先设 `poll_flag`，再把 `stack_limit` 设成 `isize::MAX`（编译出的代码按有符号数比较），所以下一个函数入口也进入慢路径；`kiln_rt_poll` 清掉标志，把 `stack_limit` 恢复成真正的界限。`kiln_rt_poll` 声明为 `unwinds`，经过 trampoline、按 `try_call` 编译，因为慢路径可能 signal 并展开。慢路径现在处理栈耗尽和采样分析器的采样（[debugging.md](debugging.md) 的“性能分析器”）。

参数全在寄存器里的函数（位置参数不超过 3 个，没有 `&rest`、`&key`）在读参数之前就做入口检查，慢路径不是调用，而是带着同样的 self 和参数尾调用共享函数 `kiln_poll_retry`：它把 `nargs` 之外的参数寄存器清零（GC 不会看到垃圾），调用 `kiln_rt_poll`，需要时发出栈耗尽，然后再尾调用回这个函数。这样函数自己的命中路径上没有调用，参数不必为 safepoint 存到栈上（Cranelift 把跨 safepoint 存活的引用在定义处存进栈槽）。

**栈耗尽**：函数入口的帧指针低于真正的界限（`stack_real_limit`）时，慢路径报告栈耗尽。`kiln_rt_poll` 返回 1 表示栈耗尽，入口随后调用 `kiln.kernel::%stack-exhausted`，它发出 `kiln.sys:stack-exhausted`（`storage-condition` 的子类，不是 `error`，和 SBCL 一样）。

内核导出 `%stack-exhausted` 的静态 symbol 对象，Rust 后端生成的 LIR poll 慢路径通过该对象的函数格调用当前定义。运行期编译和文件编译使用同一符号链接约定；导出名由 runtime 的 `STACK_EXHAUSTED_SYMBOL` 定义。

`%runtime-error` 的静态 symbol 也属于内核导出接口，导出名为 runtime 的 `RUNTIME_ERROR_SYMBOL`。后端生成的错误路径先调用它的当前函数定义；函数尚未定义或意外返回时，调用 `kiln_rt_error` 结束程序。

- runtime 为每个栈设两个界限（`rust/kiln-rt/src/stack.rs`）：软界限在栈底之上栈大小的 1/8（256 KiB 到 4 MiB 之间），硬界限在栈底之上 64 KiB。
- 越过软界限时界限降到硬界限，handler 有空间运行；再越过硬界限就结束程序。
- 展开落到比软界限高出一段距离的帧时，界限恢复为软界限，所以同一个栈可以反复耗尽、反复处理。
- `%call-on-new-stack` 的新栈有自己的界限，离开时（正常返回或展开经过边界）恢复原来的。
- 检查只在函数入口做，代价是一次比较；Rust 代码自身的递归不在检查范围内。

## 运行期错误

编译器生成的报错代码（类型检查、参数个数、未定义函数、未绑定变量、下标越界等）调用 kernel 的 `%runtime-error`，传入错误码（fixnum，定义在 `lisp/abi.lisp`）和出错的对象。CLOS 模块把它定义为按错误码 `error` 出对应的 condition（[kernel.md](kernel.md) 的“运行期错误”）。这是普通的 Lisp 调用，调用链上没有 Rust 帧，handler 的非局部退出照常工作。


## 未装箱变量的帧取值

`kiln_rt_frame` 操作 9、10 分别返回变量栈槽原始字的高、低 32 位，以非负 fixnum
表示。两次读取均不分配，调用者在分配恢复对象之前先取齐两部分。操作 6 用于
槽内已有 Lisp 对象的变量，不能用它把任意浮点位模式作为对象传回 Lisp。
调试变量描述 `(:double-bits 名字)` 表示 binary64 位模式；调试器从两部分重建
浮点对象，原始槽不作为 GC 引用扫描。
