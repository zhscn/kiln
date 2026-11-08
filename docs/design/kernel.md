# kernel

kernel 是第一个模块，源码在 `lisp/target/`（`kernel.lisp`、`types.lisp`、`sequences.lisp`、`early.lisp`），用 kiln 编译器交叉编译。它是 CLOS 之前能有的全部东西：几乎所有 SICL 模块都依赖 CLOS（[modules.md](modules.md) 的加载顺序），所以 kernel 只能是原语和手写的引导代码。

## 写法限制

- 只能用 `%primop`、已经定义的 kernel 函数和 Common-macros 的宏（[lowering.md](lowering.md)）。
- 宏展开函数在编译期由交叉编译的求值器运行，必须是可移植 CL。
- `defmacro` 在加载期也要调用 `(setf macro-function)`，所以 `(setf macro-function)` 是 kernel 的第一个定义，只用原语。

## 钩子

kernel 先给出简单的版本，后面的模块替换或扩充。钩子是 `kiln.kernel` 里的特殊变量或可重定义的函数：

| 钩子 | kernel 的默认 | 谁替换 |
|---|---|---|
| `%runtime-error` | 打印并结束程序（错误码 20） | CLOS 模块：按错误码 signal condition |
| `*class-typep*` | 无 | CLOS：类名作为类型 |
| `*ctype-typep*` | 无 | ctype：复合类型 |
| `%typep-cached` | 就是 `typep` | CLOS：带调用点缓存的版本（[clos.md](clos.md)） |
| `%cached-typep` | 不缓存的 `typep` | CLOS：按 stamp 缓存只取决于类的结果（[clos.md](clos.md)） |
| `*complex-array-kind*`、`*complex-array-op*` | 无 | Regalia 数组层（[stdlib.md](stdlib.md)） |
| `*instance-type-of*`、`*instance-equal*` | 无 | CLOS：实例的 `type-of`，pathname 的 `equal` |
| `*environment-macro-function*` | 无 | eval 模块：Maclina 词法环境里的局部宏 |
| `*compile-function*`、`*eval-function*` | 无 | eval 模块和 compiler 模块（[eval-compile.md](eval-compile.md)） |
| `*proclaim-hook*` | 无 | image-client：inline 声明 |
| `*redefinition-hook*` | 无 | compiler 模块：依赖追踪（[dependencies.md](dependencies.md)） |
| `*module-symbol-tables*`、`%register-module-symbols` | 只记录 | CLOS 模块的包系统（[modules.md](modules.md)） |

**early 桩**（`lisp/target/early.lisp`）：`error` 和 `cerror` 打印参数后终止程序（错误码 20），`warn` 只打印，`format` 的目标是 NIL 时直接返回控制串，`assert`，`define-condition` 把定义记在 `*early-condition-types*` 里（CLOS 模块在 Predicament 之后建成真正的 condition 类），`documentation` 和它的 `setf` 把文档存在 symbol 的 plist 上。流变量（`*error-output*` 等）先定义为 NIL。

## 数

- **运算在 Rust 里**：`kiln_rt_integer_op(ctx, op, a, b)`（`rust/kiln-rt/src/bignum.rs`，num-bigint）实现整数的加减乘、四种除法（商作为返回值，余数在 `ctx.values[0]`）、比较、位运算、`ash`、`gcd`、`expt`、`integer-length`。`kiln_rt_number_op`（`number.rs`，num-bigint 和 num-rational）处理全部实数的四则、四种除法（商是整数，余数和参数同类型）、比较、`eql`、转成浮点、`rational`、`sqrt`、`exp`、`log`、三角函数、`atan` 的两参数形式、`expt`。
- runtime 先把参数读成 BigInt 再分配结果，所以分配时的 GC 不影响参数；结果有多个堆对象时（ratio 的分子分母、除法的余数）先分配的用 `values_live` 登记为 root。
- **快路径和慢路径**：编译器对 `+ - *`、比较、除法、`ash`、`logand` 等内联 fixnum 运算。参数不是 fixnum 或者溢出时，调用 kernel 的 `two-arg-+`、`two-arg-<` 等函数，由它们按类型分派。`eql` 对不是同一对象的数调用 `eql-slow`。
- **数值错误是 condition**：runtime 的数值运算（Rust）发现的错误没法变成 condition，所以 kernel 在调用 runtime 之前先在 Lisp 里检查：`two-arg-*` 系列检查参数是不是实数，除法检查除数是不是零。
- **类型传染**按 CLHS 12.1.4：double > single > 有理数；有理数的初等函数结果是 single-float。比较是精确的：浮点数按它表示的有理数和有理数比较。
- **浮点的分解**（CLHS 12.2）：`integer-decode-float`、`decode-float`、`scale-float`、`float-sign`、`float-digits`、`float-precision`、`float-radix` 按位实现在 kernel 里。
- **complex**：运算在 kernel 里按两部分做（`two-arg-+` 等先判断有没有 complex 参数），部分之间的类型传染由实数的传染得到。`eql` 的慢路径、`=`、`zerop`、`abs`（浮点按比例缩放）、`phase`、`signum`、`conjugate`、`cis`，以及 `sqrt`/`exp`/`log`/`expt` 和三角、双曲函数及其反函数的 complex 版本；负数的 `sqrt`/`log` 和负底数的非整数次幂得到 complex。分支切割按 CLHS 12.1.5.3，在实轴上的取值和 SBCL 一致。双曲函数和反函数对实数也有。
- `float` 带 single-float 原型时把 double 转成 single；`ffloor`、`fceiling`、`ftruncate`、`fround`。
- 位运算：`logeqv`、`lognand`、`lognor`、`logandc1/2`、`logorc1/2`、`logcount`、`boole`。
- `random`、`*random-state*`、`make-random-state`：随机状态是一个结构，存一个 32 位的 xorshift128 生成器（`lisp/target/clos/random.lisp`）。
- 常量：超出 fixnum 范围的字面量编译成静态 bignum，double-float、ratio 和 complex 编译成静态对象，single-float 是立即数。
- 还没有：浮点的 trap、NaN 和无穷的读写。

## 字符和字符串

- 字符是 Unicode 码点，字符串是 UTF-32（[objects.md](objects.md)）。
- 字符的大小写和分类只覆盖 Latin-1。
- 字符串比较（`string=` 到 `string-not-lessp`，以及不区分大小写的版本和 `char-lessp` 等）接受 `:start1` 等关键字；`string=` 用 primop 逐字比较。

## 类型

- **`typep`**（`types.lisp`）认识内建的原子类型和常用的复合类型（`or`、`and`、`not`、`member`、`eql`、`satisfies`、带范围的 `integer`/`rational`/`real`/`float`、`mod`、`unsigned-byte`、`signed-byte`、`cons`、带长度的字符串和向量、数组类型的维度）。其余的先用 `typexpand-1` 展开 `deftype` 定义的名字（展开函数在 plist 上）；展开不了的，symbol 交给 `*class-typep*`，复合类型交给 `*ctype-typep*`。`or`、`and`、`not` 和不是标准类型名的 symbol 先经过 `%cached-typep`：CLOS 载入后，只取决于对象的类的答案按 stamp 缓存（[clos.md](clos.md) 的“类名的 `typep`”）。缓存在 `*typep-cache*` 里；类型假设（`deftype`、`(setf find-class)`、类的重新 finalize）改变时，观察者调用 `invalidate-type-caches` 清空它（[specialization.md](specialization.md)）。
- 编译期把常量原子类型的 `typep` 换成谓词调用，把类名的 `typep` 换成 `%typep-cached`（[lowering.md](lowering.md)）。
- `type-of`、`coerce`、`equalp` 覆盖已有的类型。`typep` 也认识 `complex`、`(complex 类型)` 和 `simple-bit-vector`。`deftype` 和 `subtypep` 由 ctype 提供（[stdlib.md](stdlib.md)）。

## 序列和列表

- `sequences.lisp` 是 bootstrap 用的简单实现：`find`、`position`、`count`、`remove`、`remove-duplicates`、`substitute`、`some`/`every`、`map`、`map-into`、`reduce`、`sort`/`stable-sort`（稳定的归并排序）、`fill`、`replace`、`search`、`mismatch`，以及 `member`/`assoc`/`adjoin`/`union` 等带 `:test`/`:test-not`/`:key` 的列表函数。很多函数先把序列转成列表再处理；对非 simple 向量返回 simple 向量。Consecution 还没有接入。
- 快路径：`member`、`assoc`、`find`、`position` 在 test 是 `eq`/`eql`、又没有 key 时直接循环比较；不带关键字或 `:test` 是 `#'eq`、`#'eql` 时调用两个参数的 `%member-eql` 等，不解析关键字参数；列表上的 `find`/`position` 不复制列表。
- `map`、`map-into` 不复制列表参数，在最短的序列处停止（调用者可能传入循环列表）。
- `search`、`mismatch` 接受全部关键字（`:from-end`、`:start1`、`:end1`、`:end2`），但实现很朴素（`search` 逐个 `elt`）。
- `replace` 对两个向量直接逐个复制，不经过列表；对列表也不用 `(setf nth)`。
- 特化向量的复制（`subseq`、`copy-seq`、`reverse`、`remove`）保留元素类型。

## 运行期的宏环境

- `(setf macro-function)` 把展开函数记在符号 plist 的 `macro-function` 下；`macro-function`、`macroexpand-1`、`macroexpand`、`*macroexpand-hook*`、`constantp` 都在 kernel 里。带 Maclina 或编译器前端的 Trucler 环境时，由造出这个环境的 client 查询局部宏（`kiln.eval:environment-client`）。
- `defconstant` 在加载期给符号做常量标记；`define-setf-expander` 和 `defsetf` 的展开函数也记在 plist 上（eval 模块之后）。
- 编译期仍然用前端自己的环境（[front-end.md](front-end.md)），两者互不影响。

## 运行期错误

编译器生成的报错代码调用 `%runtime-error`（[abi.md](abi.md)）。kernel 的定义是结束程序；`%runtime-error` 还没定义的时候（kernel 加载完之前），报错代码先检查它的函数格，未定义就直接结束程序。CLOS 模块（`runtime-errors.lisp`）把它重定义为 signal `type-error`、`undefined-function`、`unbound-variable`、`division-by-zero`、`program-error` 等。`:lisp-error`（early `error` 和兜底的 debugger 用的）始终直接结束程序。

## 打印

runtime 有一个 Rust 写的打印器（`kiln_rt_print`），给编译器原语 `print` 和早期的错误信息用：整数（bignum 用 num-bigint 输出十进制）、浮点（最短的、能读回原值的数字；`1e-3 <= |x| < 1e7` 用定点表示，否则用指数表示；double 用 `d`）、symbol（包前缀、keyword 的判断见 [objects.md](objects.md)）、字符串、列表、向量。CL 的打印函数是 Incless（[io.md](io.md)）。
