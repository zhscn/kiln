# 降级：MIR 到 LIR

原生编译在 MIR 上完成语义分析与表示选择，随后由 `lisp/mir/lower.lisp` 退出 SSA，使用 `lisp/lower.lisp`、`lisp/values.lisp` 和 `lisp/primitives.lisp` 的发射工具构造 LIR。Rust 验证 LIR 并落实对象布局、机器调用约定、精确 roots 与动态环境条目，见 [lir.md](lir.md) 和 [compiler-protocol.md](compiler-protocol.md)。

## 证明与操作

发射器接收 MIR 的类型、多值、存储和机器表示事实，不再遍历 HIR 树推导这些性质。声明检查已经进入 MIR 的 CFG；证明不足时保留检查或调用通用入口。全局内建原语、类型测试、数组访问、序列搜索、槽缓存和构造器特化遵守调用点的策略及 `notinline`，具体证明边界见 [mir.md](mir.md)。

MIR 中的函数与区域各有独立编号。退出 SSA 时，块参数变为局部操作数，边实参通过复制传入后继；机器 double 值和装箱对象副本按实际用途保存。源码变量的位置来自 MIR 调试绑定，源码位置和宏展开来源沿用 HIR 的语义来源。函数、闭包捕获、共享 cell 及私有入口的布局由已验证的 MIR 单元决定。

## 参数与多值

参数协议先在 MIR 中展开为普通 CFG：保存入口实参、检查数量、求出缺失默认值、绑定 supplied-p 与关键字快照，并按顺序建立 special 绑定。发射器以 `receive-prefix` 提交位置实参目标和计数；Rust 在可能覆盖传递区的操作前保存它们。`rest-list` 提交后缀起点及已证明安全的候选栈 cons，Rust 选择整条列表的栈或堆构造并保护未读取的实参。

主值和计数作为一组传递。跨调用需要保留的多值通过 `save-values`、`restore-values`、`push-values` 和 `values-list` 表达，由 Rust 维护载体、传递区和分配 roots。调用结果的未知计数和非局部退出的多值载荷保持运行期计数；`move-values` 将主值与计数一起复制到合流目标。接口和限制见 [abi.md](abi.md)。

## 动态区域与存储

MIR 的区域关系决定正常退出、本地退出和异常落地需要恢复哪些绑定与清理。发射器提交动态环境操作和 handler 后继，Rust 分配条目并实现展开。跨函数 block／tagbody 的闭包捕获堆令牌，堆对象不持有帧内部地址；`unwind-protect` 的 cleanup CFG 和继续展开规则见 [mir.md](mir.md)。

词法 cons、闭包和入口 rest 只有在 MIR 逃逸证明及调试可见性检查通过后才使用栈存储。`establish-stack-object` 初始化固定槽并登记连续引用字段，Rust 按 LIR 的存储形状建立精确 roots。证明不足时保留堆分配；对象布局和小对象分配快路径见 [gc.md](gc.md)。

独立 LIR 由 Rust 在入口保存参数、构造 rest 后安排 poll，并按 CFG 选择循环 poll；栈耗尽时调用当前 `%stack-exhausted`。MIR 的循环及动态区域验证保证源语义需要的 safepoint 和异常后继不会在发射时丢失。

## 固定角色入口

普通和 SETF 函数格的未定义占位对象、funcallable 转发及未设置目标时的错误入口由 Rust 生成。Lisp 按角色和 file/image 作用域声明所需入口；静态或动态占位对象提交其所属 symbol，funcallable 分配提交 rack。后端决定捕获字段、入口引用和初始调用目标。函数格的未定义检测使用 `undefined-function-p`，不比较代码地址。

## Runtime 服务

普通 runtime 服务提交 `runtime-op`，包含操作名、已求值对象、动态 handler 和源码位置。Rust 的闭合表定义调用名称、参数数量、签名和 safepoint 效果，补齐 imports，并为身份哈希保留缓存快路径。Lisp 发射与规范化使用生成的服务描述检查名称和参数数量，不声明这些函数的 ABI，也不选择哪些服务需要 safepoint trampoline。生产路径的帧指针操作表达为后端 token，不在 Lisp 中构造地址。

GC、packet 编码、编译失败诊断和跨栈 Lisp 调用可能 safepoint 或覆盖传递区；独立 LIR 验证器使旧多值视图失效并传播异常边。其余服务遵守当前 runtime 的 NoSafepoint 合同，保留传递区内容。运行期编译的批量快照、代码安装和 literal 绑定期间不调用 Lisp。

## 数值与错误分派

整数和实数 runtime 原语提交具名 `numeric-op`。操作码、调用签名、context 参数和返回个数在 Rust 中选择，除法余数按 runtime 约定转换成多值结果；Lisp 不读取余数所在的传递区槽。普通数值快路径由 MIR 类型和区间事实选择，后端接口不重新进行语言类型推导。

可恢复错误提交 `signal-error`，包含语义错误码、已求值对象、动态 handler 和源码位置。Rust 查找当前 `%runtime-error` 定义，安排 Lisp 调用，并在定义不可用或返回时调用 fatal runtime 入口。该操作终结当前块；条件系统引发的非局部退出沿原有 handler 展开。

## 加载期初始化

HIR 词法准备收集 `load-time-value`，MIR 为其建立独立初始化函数和 root cell。模块 init 在包含它的顶层形式之前按顺序执行初始化一次；引用处只读取该 cell。运行期 image 的 literal 表保留原对象身份，原生编译请求和安装过程保护所有 literal roots。

## 常量

- fixnum、字符、single-float、NIL、T 是立即数或静态对象。
- symbol 是静态 symbol（或运行期 image 里的符号，见 [eval-compile.md](eval-compile.md)）。
- cons 树、字符串、向量、bignum、ratio、double-float 作为静态数据输出，GC 不移动也不扫描。静态字符串常量按内容合并，cons 常量按 car 和 cdr 合并。编译进活 image 时，literal 表保留原对象身份。
- MIR 从 SSA 定义证明函数名为常量后，可将 `(setf fdefinition)` 调用降级为函数对象检查、函数 cell 写入和定义变更通知。
- `defconstant` 的常量在编译期登记进编译期环境，引用处直接编译成值。

## 原语和 `%primop`

**原语**（`lisp/primitives.lisp`）是编译器直接展开的 CL 函数：fixnum 的 `+ - * 1+ 1- < > <= >= = /= zerop plusp minusp`、`logand`、`logior`、`logxor`，字符比较（`char= char/= char< char> char<= char>=`），`eq eql null not`，类型谓词，cons 操作（`cons car cdr first rest second third cadr cddr endp rplaca rplacd list list*`），`svref`、`(setf svref)`、`length`，`values`、`values-list`、`apply`、`funcall`、`nth`、`nthcdr`、`fdefinition`、`symbol-value`、`boundp` 及其 setf，以及 `kiln.sys` 里的测试用原语。

- CL 的函数不能被重定义（CLHS 11.1.2.1.2），所以内联是合法的。
- 数值原语内联 fixnum 的快路径；参数不是 fixnum 或者溢出时调用 kernel 的 `two-arg-+` 等函数。`floor`、`truncate`、`ceiling`、`round`、`mod`、`rem` 对两个 fixnum、`ash` 对 fixnum 也有内联的快路径（KIR 的 `sdiv`、`srem`、`shlv`、`sarv`），不调用 runtime。比较原语接受任意个参数，按相邻两两比较。
- `svref`、`length` 对 simple vector（`length` 也对字符串）内联，其他情况调用 kernel 的函数。
- `eql`：两个不同的一般对象，只在第一个是 bignum、ratio、double-float 时才调用 kernel 的 `eql-slow`，其他直接返回 NIL。
- 原语被当作函数对象使用时（`#'car`），读 symbol 的函数 cell：kernel 用 `(defun car (x) (car x))` 这种写法给每个原语一个真正的全局函数。
- 单参数的 `print` 是给没有流的早期测试用的原语（带流参数的 `print` 调用打印器的 `print`），直接调用 runtime 的打印函数（先打印对象再换行，不经过 `*standard-output*` 和 `print-object`）。编进运行中 image 的代码不用它。

**`%primop`**：`(kiln.sys:%primop :名字 参数...)` 是 kernel 代码访问底层操作的唯一入口（单一入口加关键字操作码，和 SICL 的做法一样）。它对前端来说是普通的函数调用，HIR 转换验证第一个参数是 keyword 字面量，MIR 发射时查 primop 表（`*primops*`），展开成内联代码，所以前端不需要改。例如分配和读写实例、`:identity-hash`、`:hash-mix`、`:fd-read`、`:sys`、`:jit`、浮点的位模式。
