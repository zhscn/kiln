# 09 M3：kernel 和 ANSI 核心库

**状态**：进行中（2026-11）。本文记录 M3 的分步计划和已经定下的对象表示。

M3 的目标见 [04 的里程碑](04-bootstrap.md#里程碑)：把 ANSI 核心库交叉编译进 kiln。按 [04 的加载顺序](04-bootstrap.md#目标端的加载顺序)，CLOS 之前只能有 kernel 原语和手写的引导代码，而大多数 SICL 模块依赖 CLOS（M4）。所以 M3 先做不依赖 CLOS 的部分：对象表示、kernel、多模块链接、符号和包、字符和字符串、数值塔。

## 1. 分步

| 步骤 | 内容 | 状态 |
|---|---|---|
| M3.1 | 立即数和堆对象的完整 kind 表；字符、字符串、simple-vector；symbol 的名字改为字符串对象；`%primop`；用 Lisp 写的 kernel（`lisp/target/`） | ✅ |
| M3.2 | 多模块：kernel 只编译一次，用户程序作为另一个模块和它链接；symbol 在模块之间保持同一身份 | ✅ |
| M3.3 | 整数：bignum、溢出时转 bignum、整数除法和位运算 | ✅ |
| M3.4 | ratio、浮点（Quaviver 负责 I/O）、complex | ✅（complex 和 Quaviver 未做，见 §9） |
| M3.5 | 剩下的不依赖 CLOS 的部分：数组（Regalia 的原语部分）、`equal`/`equalp`、序列的基本函数 | |

依赖 CLOS 的模块（Predicament、ctype、Consecution、Salmagundi、Cyclosis、打印器等）放到 M4 之后。

**包移到 M4**：Parcl 的底层协议（`parcl-low`）全是泛函，包本身是 CLOS 类（`Low/package-class.lisp`），符号表用哈希表。它要在 CLOS 和 Salmagundi 之后才能运行。在那之前自己写一套简单的包实现，Parcl 一到就要扔掉，所以不做。在那之前，symbol 的 `package` 槽存包名字符串，`keywordp` 和打印器靠它判断。交叉编译时目标包和宿主包怎么分开（例如目标的 Eclector 和宿主编译器用的 Eclector 同名），也等到真正交叉编译这些模块时再定。

## 2. 值的表示

低 3 位是 tag（[07 §1](07-m1-gc.md#1-值和对象的表示)）：

| 低位 | 含义 |
|---|---|
| `...0` | fixnum，63 位 |
| `001` | cons |
| `101` | 其他堆对象（带 header） |
| `011` | 立即数，第 3–7 位是立即数的种类，第 8 位起是载荷 |
| `111` | 保留 |

立即数：

| 低 8 位 | 种类 | 载荷 |
|---|---|---|
| `0x0B` | character | Unicode 码点（第 8 位起） |
| `0x13` | UNBOUND（未绑定标记，不是一等值） | — |
| `0x1B` | single-float | 第 32–63 位是 IEEE 754 单精度 |
| `0x23` | NO_TLS（TLS 表的空项，不是一等值） | — |

## 3. 堆对象的 kind

header 的低 8 位是 kind，第 8 位起是长度（含义随 kind 而定）。GC 只扫描标为“扫描”的部分。

| kind | 类型 | 布局 | 长度 | GC 扫描 |
|---|---|---|---|---|
| 1 | symbol | `[header, name, package, function, value, TLS 下标, plist]` | — | name 到 plist（TLS 下标是 fixnum 形式的整数，不影响） |
| 2 | function | `[header, 入口, env...]` | env 字数 | env |
| 3 | cons | `[header, car, cdr]` | — | car、cdr |
| 4 | simple-vector | `[header, 元素...]` | 元素个数 | 全部元素 |
| 5 | simple-character-string | `[header, UTF-32 码点...]`，按 8 字节补齐 | 字符个数 | 否 |
| 6 | bignum | `[header, 64 位数字...]`，二进制补码，小端，最短 | 数字个数 | 否 |
| 7 | ratio | `[header, 分子, 分母]`，约分过，分母 > 1 | — | 分子、分母 |
| 8 | double-float | `[header, IEEE 754 位模式]` | — | 否 |

以后的 kind（M3.4、M3.5）：simple-base-string、specialized vector（`(unsigned-byte 8)` 等）、bit-vector、bignum、ratio、double-float、complex、array header、标准对象和 rack（M4）。

**字符串**：只有一种 UTF-32 的 `simple-character-string`，每个字符 4 字节。`base-string` 以后再加，到时作为 `simple-character-string` 的子类型单独一个 kind。

**symbol**：

- `name` 是字符串对象，`package` 是包对象，未 intern 的 symbol 是 NIL。M3.3 之前还没有包对象，`package` 暂时存包名字符串。
- keyword 的值是它自己，`function` 槽初始指向“未定义函数”对象（[08 §3](08-m2-front-end.md#3-对象布局的扩展)）。
- NIL 和 T 仍然是 runtime 里的静态对象，名字字符串在 runtime 启动时填写（Rust 的常量求值不能做指针加 tag）。

## 4. `%primop`

`(kiln.sys:%primop :名字 参数...)` 是 kernel 代码访问底层操作的唯一入口（[05 §7.1](05-sicl-survey.md#71-采纳)）。

- 它对前端来说是普通的函数调用，降级时按第一个参数（必须是 keyword 字面量）查 primop 表，展开成内联代码，所以前端不需要改。
- [08 §5.1](08-m2-front-end.md#51-原语) 的原语仍然保留：对 CL 函数的调用照样内联。kernel 用 `(defun car (x) (car x))` 这种写法给每个原语一个真正的全局函数，这样 `#'car`、`(apply 'car ...)` 都能工作，不再需要编译器生成的包装函数。

## 5. kernel

`lisp/target/` 是目标端的 Lisp 源码，用 kiln 编译器交叉编译。M3.2 之前它作为前缀和每个程序编译进同一个模块。

kernel 的写法限制：

- 只能用 `%primop`、已经定义的 kernel 函数和 Common-macros 的宏。
- 宏展开函数在宿主里运行，必须是可移植 CL（[04 关键选择 1](04-bootstrap.md#关键选择)）。

## 6. M3.1 的实现记录

- **KIR** 增加了 `(load32 A 偏移)`（零扩展）和 `(store32 A 偏移 V)`，用于 UTF-32 字符串。
- **TLS 下标**改为按 fixnum 存放（下标 << 1），symbol 的所有字段都是合法的 Lisp 值，GC 可以统一扫描堆上的 symbol。TLS 表项地址 = 表基址 + 存放的值 << 2。
- **大对象**：超过当前 plan 的普通分配上限时，`kiln_rt_alloc` 改用 MMTk 的 large object space。
- **函数标识**：`funcall`、`apply`、`multiple-value-call` 接受 symbol，取它的全局函数。
- **`(setf f)` 函数**：`defun` 展开成 `(funcall #'(setf fdefinition) f name)`，而 `name` 经过简化后是一个绑定到常量的临时变量。降级时记录“绑定到常量且从不赋值”的临时变量，函数名是编译期常量时直接写进对应的 cell。运行期才知道的 `(setf f)` 函数名要等 M3.3。
- **比较原语**接受任意个参数，按相邻两两比较。
- **前端**：
  - 文件改为读一个形式处理一个，顶层的 `in-package` 在宿主里设置 `*package*`，影响后面的读入（目标端还没有包，不编译它）。
  - Eclector 把反引号读成 `eclector.reader:quasiquote`，这个宏和 `eclector.reader::expand` 要装进编译期环境（SICL 也这样做）。
  - 宏展开函数在编译期环境里由 HIR 求值器执行，那里还没有 `loop`（Khazern 要等 M4 之后）。
- **原语的包装函数已删除**：kernel 为每个原语定义了真正的函数，`#'car` 直接读 symbol 的函数 cell（[08 §5.1](08-m2-front-end.md#51-原语) 里的包装函数不再需要）。
- **测试**：所有测试都以 kernel 为前缀编译。`tests/m3/chars-strings.lisp`（Unicode 字符和字符串、Latin-1 的大小写、跨 GC 的字符串、large object space 里的大字符串）、`tests/m3/sequences.lisp`（向量、列表函数、原语作为函数对象、symbol 的 plist）。
- **限制**：字符的大小写和分类只覆盖 Latin-1；`string=` 等还不支持 `:start`/`:end`；`make-array` 只能建一维 simple-vector；数只有 fixnum。

## 7. M3.2：多模块

- **KIR**：`(shared "名字"...)` 声明本模块里哪些数据和函数可能被别的模块以相同内容定义：symbol 对象、它的名字字符串和未定义函数对象、`(setf f)` 的 cell、包名字符串、`kiln_undefined_function`。其他名字（函数、常量、`load-time-value` 的 cell、init 函数）都带模块名前缀，不会冲突。
- **kiln-cg** 一次接受多个 KIR 文件（`kiln-cg jit kernel.kir prog.kir`、`kiln-cg obj kernel.kir prog.kir -o prog.o`），先合并成一个模块：导入去重，共享定义只保留第一份，其他名字重复就报错，root 去重，各模块的 init 函数按给出的顺序执行。runtime 登记静态 root 时也会去重。
- **`kiln_module_info`** 改为 72 字节：`enter`、`inits`（init 函数对象数组）、`ninits`、调用点表、栈图、root 表。
- **编译会话**（`kiln.compiler:make-session`）：Clostrum 编译期环境和已定义函数的记录在多个文件之间保留。`kiln:compile-kernel` 先把 kernel 编译成 `kernel.kir`，之后同一个会话里用 `kiln:compile-file-to-kir` 编译的程序能看到 kernel 的宏和函数。`tools/test.sh` 这样只编译一次 kernel。
- **以后**：分别生成的目标文件之间链接（共享定义用 weak 链接，launcher 汇总多个 module info），以及 image 里增量加载模块。

## 8. M3.3：整数

- **表示**：fixnum 范围（63 位）之外的整数是 bignum（kind 6）：二进制补码、小端的 64 位数字，长度最短。fixnum 范围内的整数永远是 fixnum，所以整数的 `eql` 就是 fixnum 的 `eq` 或 bignum 的值相等。
- **运算在 Rust 里**（`rust/kiln-rt/src/bignum.rs`，用 num-bigint）：`kiln_rt_integer_op(ctx, op, a, b)` 实现加减乘、四种除法（商作为返回值，余数在 `ctx.values[0]`，即两个值）、比较、位运算、`ash`、`gcd`、`expt`、`integer-length`。它先把参数读成 BigInt 再分配结果，所以分配时的 GC 不影响参数；除法先分配余数并通过 `values_live` 把它登记为 root，再分配商。
- **快路径和慢路径**：编译器对 `+ - *` 和比较照样内联 fixnum 运算。参数不是 fixnum 或者溢出时，调用 kernel 里的 `two-arg-+`、`two-arg-<` 等函数，由它们按类型分派（现在只有整数，M3.4 加 ratio 和浮点）。`eql` 对不是同一对象的堆对象调用 kernel 的 `eql-slow`。
- **kernel**：`truncate`/`floor`/`ceiling`/`round`（两个值）、`mod`、`rem`、`logand`/`logior`/`logxor`（fixnum 有快路径：带 tag 的 fixnum 直接按位运算）、`lognot`、`logtest`、`logbitp`、`ash`、`integer-length`、`evenp`/`oddp`、`gcd`、`lcm`、`expt`、`isqrt`、`abs`、`signum`。
- **常量**：超出 fixnum 范围的字面量编译成静态 bignum。
- **打印**：runtime 的打印器用 num-bigint 输出十进制，以后换成 Lisp 写的打印器。
- `tests/m3/integers.lisp`：溢出成 bignum 再回到 fixnum、fixnum 边界、大数乘法、比较、除法的四种取整、位运算、`ash`、`gcd`、`expt`、`isqrt`、跨 GC 的 bignum。

## 9. M3.4：ratio 和浮点

- **表示**：ratio 是 kind 7，总是约分过、分母大于 1，分母为 1 时就是整数。single-float 是立即数，所以 `eql` 对它就是 `eq`（`0.0` 和 `-0.0` 位模式不同，因此不 `eql`，符合 CLHS）。double-float 是 kind 8，装箱存放。默认浮点格式是 single-float，和宿主读入 `1.5` 的结果一致。
- **运算在 Rust 里**（`rust/kiln-rt/src/number.rs`，用 num-bigint 和 num-rational）：`kiln_rt_number_op` 处理全部实数的加减乘除、四种除法（商是整数，余数和参数同类型）、比较、`eql`、转成浮点、`numerator`/`denominator`、`rational`、`sqrt`、`exp`、`log`、三角函数、`atan` 的两参数形式、`expt`。类型传染按 CLHS 12.1.4：double > single > 有理数；有理数的初等函数结果是 single-float。比较是精确的：浮点数按它表示的有理数和有理数比较。
- **分配和 GC**：结果为 ratio 时，分子和分母可能是 bignum，先分配它们，并通过 `values_live` 把它们登记为 root，再分配 ratio。除法的余数同理。
- **kernel**：`two-arg-*` 一律交给 `kiln_rt_number_op`；`/`、`float`、`numerator`、`denominator`、`rational`、`rationalp`、`floatp`、`realp`、`sqrt`、`exp`、`log`、`sin`、`cos`、`tan`、`atan`、`ffloor`；`truncate` 等四种除法支持所有实数。位运算仍然只接受整数。
- **常量**：single-float 编译成立即数，double-float 和 ratio 编译成静态对象。
- **打印**：runtime 的打印器按 `*read-default-float-format*` = single-float 的规则输出：最短的、能读回原值的数字；`1e-3 <= |x| < 1e7` 用定点表示，否则用指数表示；double 用 `d`（`1.0d0`、`1.5d-5`）。以后由 Lisp 写的打印器和 Quaviver 取代。
- **没做**：complex；浮点的 trap 和 `float-digits`、`integer-decode-float`、`scale-float` 等；NaN 和无穷的读写。
- `tests/m3/reals.lisp`：ratio 的约分和运算、类型传染、浮点打印、`=` 和 `eql` 对 `0.0`/`-0.0` 和不同格式的区别、有理数和浮点的精确比较、四种除法、初等函数、跨 GC 的 ratio 和 double。
