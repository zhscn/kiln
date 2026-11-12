# LIR：Lisp 编译器与 Rust 后端的输入契约

状态：**操作层正在接入**。[结构化封套](compiler-protocol.md)已支持文件与运行期交接，当前承载 KIR，兼容载荷已支持 fixnum、cons、character 和 single-float 的表示类测试、`field-load`/`field-store`、闭包环境读写、传递区读写和根计数设置，以及普通函数对象 `invoke`，字符和 single-float 常量以码点和 IEEE 位模式传入，Rust 在构造 KIR 时展开立即数表示、布局和调用约定。动态传递区下标和根计数的范围由生成方保证。其余操作尚未迁移，不能视作完成 LIR。现在 Lisp 主要生成 KIR（[codegen.md](codegen.md)）。分层和迁移见 [compiler.md](compiler.md)。

兼容载荷中的堆对象测试分为一般对象 tag 测试和受该测试保护的 header 类测试；生成方必须确保只有一般对象到达后者。完整 LIR 的类型测试将把安全检查与表示类测试作为同一操作处理。

兼容载荷的 `alloc-fixed` 接收对象种类和已求值的字段，Rust 据此分配和初始化堆 cons、double-float、complex 和 CLOS 实例；对象字段变量跨分配慢路径保持 GC root。兼容输入中的 `alloc-raw` 由生成方提供大小和 header；Rust 展开定长小对象的 bump 分配、清零与慢路径，其他大小调用 runtime 分配器。`alloc-raw` 的结果是未加 tag 的地址，生成方须在下一个 safepoint 前完成初始化并转换为对象引用。完整 LIR 的分配操作将改用对象种类、存储方式和字段。

`alloc-closure` 按入口和捕获项数量分配堆函数对象，初始化入口并把捕获项清零；生成方随后以 `closure-set` 填充捕获项。这允许递归组先建立所有函数对象，再互相引用，即使填充之前发生 GC 也可安全扫描。

栈上的 cons 和闭包以对象种类及引用项数量声明栈槽，由 Rust 决定大小、header、清零、引用字段起点和对象初始化。生成方标注栈根区域的进入与退出，Rust 初始化并链接动态根条目；rest 列表按生成方选择的栈槽地址初始化 cons。

catch、unwind-protect、跨函数退出点、special 绑定和 progv 的动态条目也由 Rust 按语义种类建立和撤销。special 绑定的保存与恢复、progv 已保存绑定的读取和退出点重新链接使用对应的后端操作；Lisp 仍编排控制流及绑定、cleanup 的求值，展开 payload 仍使用兼容载荷。

`special-ref` 和 `special-set` 由 Rust 安排动态值与全局值的选择，调用方负责检查未绑定值。绑定和 progv 使用后端操作取得或分配 TLS 下标及读写动态槽；special 绑定按已分配的下标由后端保存旧值并设置新值，绑定顺序仍由调用方编排。下标分配的 runtime 调用不是 safepoint。

兼容载荷以 `poll-test` 区分入口和循环检查，Rust 生成对应的栈限额或 poll 标志读取；调用方仍生成慢路径和入口重试。完整 LIR 的 poll 安排由后端完成。

`alloc-vector` 接收 simple-vector 或字符串的种类、未装箱长度和初值，Rust 负责尺寸、header、对齐及填充。字符串初值为字符码点，simple-vector 初值为对象；动态长度须由生成方检查范围。`alloc-vector-elements` 接收已求值的多个对象，按顺序初始化 simple-vector。填充过程没有 safepoint。

`vector-ref` 和 `vector-set` 访问 simple-vector 的对象元素，`string-ref` 和 `string-set` 访问字符串的字符；这些操作接收未装箱下标，对象类型与下标范围由生成方检查。`vector-length` 读取未装箱长度，并屏蔽 header 中的身份哈希。fixnum 和字符的装箱、拆箱操作负责立即数与机器字之间的转换。fixnum 的加、减、乘操作由后端选择带 tag 的计算方式，并可返回溢出标志。

`heap-number-p` 在已验证一般对象的路径上判断它是否为堆数值；`identity-hash` 由后端判断对象表示、读取已有哈希并按需调用 runtime。

double-float 的未装箱位模式和 complex 的实部、虚部通过字段操作读取。double 位模式是机器值，函数入口与 double 位模式均不能作为对象引用字段写入。

实例的 rack、class 和按位置访问的槽，funcallable instance 的函数，以及原生结构的 layout 和槽由后端按对象种类展开。槽位置传入机器字；生成方负责类型和位置的有效性。

`alloc-structure` 接收已求值的 layout 和未装箱槽数，由 Rust 计算结构对象大小和 header、清零槽并写入 layout；动态槽数由生成方保证在可表示范围内。

`alloc-rack` 接收 class 和槽数，后端分配并初始化 rack；普通实例和 funcallable instance 使用 `alloc-fixed`。分配 rack 后再次分配实例时，rack 保持为精确 GC 根。rack 的长度检查预留 class 字段所需的空间。

`alloc-symbol` 初始化 symbol 的名称、包、值和函数格，再由生成方建立未定义函数对象并写入函数格；这些分配期间 symbol 保持为精确根。动态分配路径不再由 Lisp 发射原始大小和 header，兼容载荷仍保留 `alloc-raw` 供旧输入使用。

静态函数、字符串、cons、simple-vector、bignum、ratio、complex、double-float 和 symbol 使用对象种类及内容描述，由 Rust 构造 header 与对象字。引用和重定位保留原有的数据标签，字符串传递字符码点，Rust 负责 UTF-32 打包。静态 symbol 的可变字段以字段 ID 声明为根，包括需要随 image 保存的 TLS 下标。

静态对象引用声明数据标签及 cons 或 general 表示类，Rust 负责重定位加数；静态 cons 的可变引用字段以字段 ID 声明为根。函数格访问使用 symbol 字段操作，适用于静态 symbol 和 image literal。

未绑定的 symbol 值和未绑定的标准对象槽使用不同的常量操作，由 Rust 提供其立即数表示。

`invalid-vector-length` 检查带 tag 的候选长度是否为非负 fixnum 且不超过运行时 header 可表示的最大长度；生成方负责错误路径。常量长度在后端展开时也检查同一上限。

LIR（low-level IR）是表示选择后的后端输入语言，也是编译协议的程序载荷。它不设独立的优化管线。初期由 HIR 降级产生，后续由 MIR 产生；两者使用同一 schema。它已经确定了“做什么”：每个值的表示、每个对象的存储、闭包的内容、控制流和动态范围；还没有确定“怎么做”：tag、对象和 context 的偏移、调用序列、展开 payload 的编码、栈图。后者由 kiln-cg 降级成 KIR 时按 kiln-rt 的布局决定。

## 原则

- **布局无关**：LIR 里不出现 tag、偏移、kind 编号、context 字段和 `ctx.values` 下标。对象种类和字段用名字，名字集合来自目标描述。
- **决定已经做完**：LIR 不留需要类型推导或 Lisp 环境才能做的决定。Rust 不进行类型、别名、逃逸等语言语义推导，不重新选择表示；它可以进行验证和低层展开所需的控制流分析，生成快慢路径、handler 分派和 ABI 适配块。机器层的优化由 Cranelift 做。
- **Lisp 证明，Rust 信任**：栈存储的安全、`fixnum-tag` 的范围、已知函数的参数个数等性质由 MIR 证明。Rust 不重复证明语言性质，但必须验证结构、变量初始化、区域和临时多值的合法使用，并保证自身生成的栈槽、roots、清理和布局正确。
- **确定**：同一输入产生规范化的 LIR 二进制记录；kiln-cg 的输出由 LIR、目标描述和后端配置共同决定。自举逐个比较 LIR 文件，kiln0 和 kiln1 逐字节相同的要求不变。

## 变量和表示

LIR 和 KIR 一样使用可赋值的变量，不是 SSA：MIR 退出 SSA 时将块参数转换为边上的并行复制，必要时拆分临界边，并用临时变量消除复制环，kiln-cg 再用 cranelift-frontend 构造 SSA，并由它在 safepoint 处为对象引用插入溢出和重载（C5）。Rust 无须构造另一套用于语义优化的 SSA；允许使用 CFG 状态传播验证变量、动态区域和多值的使用。

| 类别 | 含义 | GC |
|---|---|---|
| `obj` | Lisp 值（立即数或对象引用） | 跨 safepoint 存活时登记为根 |
| `word` | 64 位整数：未加 tag 的整数、条件的 0/1、计数 | 不登记 |
| `f64` | binary64 | 不登记，用浮点寄存器 |
| `mv` | 一组多值（见下文“多值”） | 由 Rust 安排 |

变量可以带源码变量的调试描述（名字、cell 或机器值表示），Rust 据此写帧的调试记录（[debugging.md](debugging.md)）。

## 操作

下面按类列出操作的种类，具体的名字和签名在实现时写进操作表，编号、参数类别、结果和效果纳入同一 schema。下列 s-expression 只是可读记法，不是传输编码。

- **常量**：常量表里的项、fixnum、字符、`nil`、`t`、未绑定标记。
- **类型测试**：`(test x CLASS)` 得到 `word` 0/1。`CLASS` 是目标描述里列出的表示类：fixnum、cons、symbol、function、funcallable-instance、simple-vector、string、bignum、ratio、double-float、single-float、complex、character、standard-instance、structure-instance 等，以及若干组合类（如“堆上的数”）。`list`、整数区间、`member` 这类组合由 MIR 用分支表达。
- **fixnum**：带溢出标志的加、减、乘，比较，按位运算，移位，除法和余数；`fixnum-untag`（`obj` → `word`）和 `fixnum-tag`（`word` → `obj`，范围由 MIR 保证）。tag 的位置和“带 tag 直接相加”这类技巧只在 Rust 里。
- **浮点**：`f64` 的算术和比较；`box-double`、`unbox-double`；single-float 的位模式。
- **字段**：按对象种类和字段名读写，例如 cons 的 car/cdr、symbol 的各个 cell、函数对象的环境第 i 项、simple-vector 和字符串的第 i 个元素（下标是 `word`）、rack 的槽、结构对象的槽、对象的长度。写入对象引用时由 Rust 插入需要的写屏障。
- **分配**：`(alloc KIND STORAGE 字段...)` 和变长的 `(alloc-vector KIND 长度 初值 STORAGE)`。`STORAGE` 是 `heap` 或 `stack`。`stack` 表示 MIR 已经证明身份不越过本帧、同一分配点不会同时有两个活的对象；Rust 为每个分配点安排固定栈槽，把引用字段登记为精确根。堆分配由 Rust 生成 bump pointer 快路径和慢路径。
- **函数和闭包**：`(static-function F)` 是没有自由变量的函数对象；`(make-closure F STORAGE 捕获值...)`；`(closure-ref i)` 读本函数的第 i 个捕获值；`(make-cell v)`、`(cell-ref c)`、`(cell-set c v)`。函数对象和 cell 的布局由 Rust 决定。
- **全局**：special 变量的读、写、`boundp`（TLS 和全局值的查找在 Rust）；symbol 的函数 cell 和 `(setf f)` cell；`load-time-value` cell 和调用点缓存的读写。
- **错误**：`(error CODE v)` 是终结操作。错误码来自目标描述；Rust 展开成调用 `kiln.kernel::%runtime-error`、未定义时结束程序。

## 函数和调用

函数头声明外部或内部入口、参数接收上限与捕获项前缀。Lisp 生成完整的参数绑定程序，包括参数数量检查、`&optional`/`&key` 的默认式与 supplied-p、rest 身份、声明检查及初始化顺序；这些都是可优化的普通控制流。LIR 提供 `arg-count`、`arg-ref`、`arg-rest` 等低层操作，Rust 实现寄存器与传递区读取、列表分配和入口参数保护。可选参数缺失时不执行 `arg-ref`，默认式仍由 Lisp 程序执行；Rust 不维护另一套 lambda-list 语义。

调用：`(call 结果 CALLEE (实参...) 选项)`。

- `CALLEE`：`(global sym)`、`(global-setf sym)` 读函数 cell；`(known F 捕获...)` 是已知的局部函数，直接调用入口；`(value f)` 调用一个函数对象；`(runtime 名字)` 调用 runtime 函数。
- 结果：`primary`（只要主值）、`(fixed n)`（前 n 个值，不足补 NIL）、`mv`（全部值）。
- `(spread list)`：最后一个实参是列表，按 `apply` 展开。
- `(region R)`：调用可能展开时所在的最内层带 handler 的区域；`(loc 起始 结束)` 是调用形式的源码范围。
- `tail-call` 是终结操作，只能在没有活动区域的地方使用。

寄存器参数、传递区、`nargs`、返回值的个数和 `ctx.values` 的使用都由 Rust 按 [abi.md](abi.md) 安排。

## 多值

`mv` 变量由调用、`(values ...)`、`(landing ...)` 或 `mv-restore` 产生。它是短期借用的返回值视图，在任何可能覆盖多值区的操作或 safepoint 之前必须被消费：取第 i 个值、取个数、作为返回值、作为 `mv` 结果的实参展开，或用 `(mv-save m)` 存成 `obj`（以后用 `(mv-restore o)` 取回）。`mv-save` 自身可能分配，Rust 必须先保护主值、计数和其余值，不能先触发 GC 再读取旧视图。验证器按 CFG 检查视图有效性；需要跨块或跨 cleanup 保存时优先显式保存。值的个数固定的地方，MIR 应当直接用 `(fixed n)` 拆成普通变量。Rust 负责把主值、个数和 `ctx.values` 映射到 `mv` 上。

## 动态范围和退出

函数头声明这个函数里的区域：`(region R KIND 外层区域 [landing 块])`，`KIND` 是 `catch`、`unwind-protect`、`exit-point`、`bind`、`progv`。代码里用 `(enter R 参数...)` 和 `(leave R)` 建立和撤销；`enter` 的参数是 catch 的 tag、退出点的令牌、special 绑定的符号和值。条目的布局、链入 context、特殊变量的保存和恢复都在 Rust。

- **本地退出**：MIR 生成 `leave`、内联的 cleanup 代码和跳转，Rust 不重新安排。
- **非局部退出**：`(throw tag mv)`、`(exit-to token mv)` 是终结操作。退出令牌是堆对象（C5：堆对象不能指向栈帧），由 MIR 用普通分配生成。
- **落地**：带 handler 的区域有 landing 块，以 `(landing R)` 开始，得到传来的值（`mv`）；`exit-point` 的 landing 还得到 `go` 的目标下标。不是本区域的展开，由 Rust 生成的分派转给外层区域的 landing。`unwind-protect` 的 landing 执行 cleanup 后用 `(continue-unwind R)` 继续展开。payload 怎么编码多值由 Rust 决定。

区域嵌套和 `region` 选项由 Lisp 给出，Rust 的验证器检查每条路径上 `enter`/`leave` 成对、调用标注的区域是当时最内层的带 handler 区域。

## poll 点

Rust 在函数入口生成栈检查（包括“参数全在寄存器里的函数经共享慢路径重试”的做法），并保证所有可能无限执行的循环路径经过 safepoint。根据 CFG 的循环结构安排 poll，覆盖不可约循环，不以块编号倒序代替循环分析；见 [abi.md](abi.md) 的“Poll 点”。LIR 也可以写显式的 `(poll)`。

## 常量和模块

模块头记录 schema 版本、目标指纹、后端配置和模块名，指纹不符时 kiln-cg 拒绝。模块包含 init 函数、函数、常量表、静态 cell 和 root。

常量表用可移植的描述，不含地址：

- `(symbol "包" "名字")`、`(uninterned "名字" 编号)`；
- `(string "...")`、`(cons C C)`、`(vector C...)`、`(bignum 位...)`、`(ratio C C)`、`(double 位模式)`、`(complex C C)` 等，`C` 是常量表下标或立即数；
- `(literal i)`：运行中 image 的对象，取自和 LIR 一起交给 `kiln_rt_jit` 的 literal 向量，保持对象身份；
- 可变的静态数据单独列出：`load-time-value` cell、调用点缓存（[specialization.md](specialization.md)）。它们不参与合并。

静态数据的布局、symbol 的共享定义（[codegen.md](codegen.md) 的“多模块”）、静态字符串和 cons 按内容合并的规则在 Rust 里实现；SBCL 上的交叉编译因此不需要知道任何对象布局。

## 目标描述

布局和 context 常量只在 kiln-rt 里定义。kiln-cg 生成一份目标描述（s-expression），供 Lisp 编译器在编译期读入，内容只有语义上需要的部分：

- fixnum 的范围、`char-code-limit`、`call-arguments-limit`、`multiple-values-limit`、数组大小上限；
- 表示类、对象种类、字段名和错误码的列表（用于检查 `%primop` 和 MIR 的降级）；
- ABI 指纹和 LIR 版本。

`lisp/abi.lisp` 换成读入这份描述；测试检查仓库里的副本和 kiln-cg 生成的一致。

## 结构化交接

LIR 请求从第一版起采用下述[编译协议](compiler-protocol.md)。运行期批量提交结构化记录并由适配器转交 Rust 所有权，生产构建文件默认保存这些记录的规范化二进制编码。解码与快照适配器进入同一个操作验证和 KIR 构造路径，避免进程内的序列化往返。可读的 LIR/KIR dump 只供诊断，不是编译输入的中转步骤。

## 迁移期间

先由现有 HIR 降级产生 LIR。kiln-cg 暂时同时接受旧 KIR 和新 LIR 输入，以便对照输出；新生产入口不依赖旧文本入口。MIR 接入后直接以相同 LIR 契约为目标。切换和删除门槛见 [compiler.md](compiler.md#切换门槛和验证范围)。
