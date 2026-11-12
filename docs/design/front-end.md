# 前端：读入、顶层形式和编译期环境

前端把源码变成 HIR（[hir.md](hir.md)），降级见 [lowering.md](lowering.md)。同一份前端既在 SBCL 上运行（交叉编译出 stage0），也在 kiln 上运行（自举、运行期 `compile`/`eval`）。

## 流水线

```
源文件
  │ Eclector（eclector.concrete-syntax-tree:read），一次读一个形式
  ▼
CST ── 顶层形式处理（lisp/front.lisp，CLHS 3.2.3.1）
  │      progn / eval-when / 宏展开在这里做，编译期求值交给 client 的求值器
  ▼
HIR 转换（lisp/hir/convert.lisp）── 构造后的分析（lisp/hir/analyze.lisp）
  ▼
HIR ── 降级（lisp/hir/lower.lisp，用 lisp/lower.lisp、lisp/values.lisp、lisp/primitives.lisp 的发射工具）
  ▼
KIR
```

HIR 的词法绑定、自由变量、赋值、退出点和闭包布局直接记录在结构中；宏展开结果直接转换，不重建 CST，源码位置按顶层形式 CST 里记下的位置取。编译期求值按 client 分派（`evaluate-at-compile-time`）：cross-client 和 image-client 共用 HIR 求值器（`lisp/hir/eval.lisp`）。数据结构、源码位置和分析规则见 [hir.md](hir.md)。

## 编译 client 与会话

| 文件 | 在哪里 | 内容 |
|---|---|---|
| `lisp/front.lisp` | 两边共用 | 顶层形式处理、inline 展开、读入、session |
| `lisp/cross.lisp` | 两边共用 | `cross-client`：交叉编译用的编译期环境 |
| `lisp/target/compiler/client.lisp` | 只在 kiln 上 | `image-client`：在运行中的 image 里编译 |

`make-session` 的 `:client-class` 选择 client。宿主默认 `cross-client`，kiln 上默认 `image-client`。少量差异在 `front.lisp` 里用 `#+kiln` 区分（宿主为目标端编译时读入用的是目标的 features）：client 的超类、目标端读入的包是 CL-USER 而宿主是 KILN-USER、Common-macros 的包名等。

### cross-client：交叉编译

编译 kiln 自己的模块用它，在 SBCL 上和在 kiln 上都一样（kiln 编译自己时不能改掉正在运行编译器的 image，而且两边必须从同一个空的编译期环境开始）。

- **编译期环境是一个 Clostrum 环境**，和运行编译器的 image 隔离。目标里重定义 `car`、`defclass` 都不会碰到宿主。
- **编译期求值用 HIR 求值器**（`lisp/hir/eval.lisp`，[hir.md](hir.md) 的“编译期求值”）：形式用 HIR 前端的转换器转成 HIR，再编成宿主闭包执行，全局函数和特殊变量都经过 Clostrum 环境的 cell，动态绑定是浅绑定。宏函数会调用目标环境里定义的辅助函数，所以不能直接交给宿主的 `compile`。
- 宿主 CL 包里所有的函数导入编译期环境，宏展开函数可以直接调用它们。和全局环境打交道的函数换成访问 Clostrum 环境的版本：`macro-function`、`(setf macro-function)`、`fdefinition`、`(setf fdefinition)`、`fboundp`、`symbol-value`、`(setf symbol-value)`、`boundp`、`proclaim`、`macroexpand`、`macroexpand-1`，以及接受符号作为函数标识的 `funcall`、`apply`。
- **编译期的 CLOS**：被交叉编译的库在编译期需要 `defclass`、`defgeneric`、`define-condition` 的副作用，这部分用宿主 CLOS（通过 closer-mop），并且和目标 image 里的 metaobject 严格分开（SICL 的 E1 也是这样）。
- 在 kiln 上，“宿主”就是 kiln 自己：编译期环境同样是 Clostrum 环境，HIR 求值器构造的闭包是 kiln 的闭包，导入的函数和宿主宏是 image 里的。

**宿主宏**：有些宏在编译期用宿主自己的展开函数，编译期的 `(setf macro-function)` 不覆盖它们：

- `quasiquote`/`unquote`/`unquote-splicing`（Eclector 的反引号）、`loop`/`loop-finish`（Khazern）、`defstruct`（Anatomicl，在宿主里运行，生成的代码不引用它自己）、不在顶层的 `defpackage`。否则目标源码里的 `defmacro quasiquote` 等会把编译期的反引号换成调用目标端函数的展开函数。
- **宿主库**：compiler 模块里的那些库（Trucler reference、Clostrum，包列表在 `*compiler-host-macro-packages*`）宿主也载入了，编译期直接用宿主的宏、函数和常量（`use-host-macros`）。宏照常编进模块，供运行期使用。不在编译期求值这些库本身，因为它们的宏在展开时可能要用编译期没有的东西。
- 宿主宏的展开里有宿主的反引号对象（SBCL 的 `sb-int:quasiquote` 和 `sb-impl::comma`），改写成 Eclector 的形式（`translate-host-backquote`），并且总是复制，不共享展开函数里的字面量。改写之后如果还有宿主对象或 `SB-` 包的符号就报错（`check-host-expansion`）。
- 这些宿主库的 compiler macro 也用于为目标编译的代码（`client-compiler-macro`），展开结果同样要通过检查，不合格的放弃展开。

**Common-macros 的宏**：标准宏在编译期用 Common-macros 的定义。宿主取 `cmd:macro-function`；kiln 上取 eval 模块载入 Common-macros 时存下的 `kiln.kernel::*common-macros*`。kiln 上 Common-macros 的包是 `KILN.CMD`，宿主上是 `COMMON-MACRO-DEFINITIONS`，所以 kiln 上展开结果里新出现的 `KILN.CMD` 符号换成宿主包的同名符号，它们的内部宏也以宿主的名字放进编译期环境。kiln 对 Common-macros 的定制在 `lisp/macro-client.lisp`，宿主载入包 `kiln.macros`，目标端读进 `kiln.macros-target`，同一个宏在编译期和运行期展开的结果相同。

### image-client：在 image 里编译

运行期 `compile`、`eval`、`load` 用它（[eval-compile.md](eval-compile.md)）。编译期环境就是运行期的环境，和一般的实现一样：

- Trucler 的全局环境是一个 `run-time-environment` 对象，对它的查询转给 eval 模块的 image 全局环境 client：宏、特殊变量、常量、已定义的函数都来自运行中的 image。依赖追踪在这里记录查询（[dependencies.md](dependencies.md)）。
- 编译期求值使用 HIR 求值器，直接保留前端的局部宏和 symbol macro 环境。`macrolet` 的展开函数由同一转换器和求值器构造；其环境保留外层的局部宏、symbol macro 和 special 声明，屏蔽词法值及局部函数。
- 编译期的效果直接落在 image 里：`defmacro` 定义宏，`defvar` 宣告特殊变量，`deftype` 和 `define-setf-expander` 记在 plist 上。`declaim inline` 经 kernel `proclaim` 的 `*proclaim-hook*` 通知前端。
- image 里所有的编译会话共用一张内联函数表（`*image-inline-functions*`），初始内容是宿主编完 compiler 模块那一刻的 inline 表（`host-inline-functions`）。

## 顶层形式处理

顶层处理直接作用于 CST 或顶层宏展开出的普通形式：

- `progn`：逐个子形式递归处理。
- `eval-when`：按 CLHS 3.2.3.1 的表格决定是编译、编译期求值，还是两者都做。
- 宏形式：先查环境里的宏（`trucler:describe-function`），再查 Common-macros 的宏，展开结果直接递归处理，不调用 `cst:reconstruct` 重建 CST；转换中遇到宏展开传下来的普通子形式时，按需从顶层 CST 惰性建一次 `eq` 位置表（`*hir-form-sources*`）保留源码位置，宏新生成的子形式继承外层宏调用的源码位置（`*macro-source*`）。
- `locally`、`macrolet`、`symbol-macrolet`：主体按顶层形式处理，局部宏的展开函数求值后加进 Trucler 环境（`process-toplevel-body`）；主体以声明开头时整体编译。
- 其他形式：在 compile-time-too 模式下先求值，然后转换成 HIR（`cst-to-hir`），加入顶层形式列表。
- 处理每个顶层形式时 `*gensym-counter*` 绑定为 0，和 SBCL 的 `compile-file` 一样。
- `kiln.compiler::*trace-toplevel*` 为真时，把每个文件和每个顶层形式的开头打印到 `*error-output*`。

**文件项**：模块的文件列表里除了路径，还有 `(:compile-time-too 路径)`（文件里的形式都当作在 `(eval-when (:compile-toplevel :load-toplevel :execute))` 里处理，用于定义宏的展开函数要调用同文件里的函数的库）和 `(:renames 别名表 路径)`（读入时按别名换包名，作用于 `in-package` 和 `defpackage`；这样的文件里对编译期已有宏的重新定义只在载入时生效）。

## 源码读入

`source-reader-client` 对结构不匹配的 CST 重建复用子树索引：先按原有顺序建立
raw cons 到 CST 的只读映射，再分别为 car、cdr 筛选引用、登记原子和构造结果。
两个分支不共享可变结果表，保留歧义原子的位置选择和循环结构的处理。

读入使用编译会话的包与 feature 环境：

- 顶层的 `defpackage` 和 `in-package` 在编译期执行（宿主上在宿主里），影响后面的读入；运行期的包从模块的符号表得到（[modules.md](modules.md)）。包系统存在之后编译的文件里，顶层 `in-package` 在载入时也设置 `*package*`，文件末尾恢复成 CL-USER，和 `load` 一样。
- 读目标源码时 `*features*` 绑定为 kiln 的列表（`:kiln :common-lisp :64-bit :x86-64 ...`），编译期环境里的 `*features*` 也是它，所以 `#+sbcl` 的分支不会读进 kiln 的代码。
- `#.` 在编译期环境里求值。

**未定义函数的警告**推迟到文件末尾（CLHS 3.2.2.3）：转换遇到环境里没有的函数时记下名字（`*referenced-functions*`）；文件处理完后，去掉本文件定义过的函数和原语，剩下的作为一个 style-warning 报告。

## 转换时的处理

- **对 symbol macro 做 `setq`**：CLHS 3.1.2.1.1 要求按对展开式的 `setf` 处理，转换时改写成 `(setf 展开式 值)`。`with-slots`、`with-accessors` 依赖这一点。
- **词法类型声明**按绑定身份和作用域保留，供 Trucler 查询。可投影到证明域的声明在绑定、赋值或局部读取处检查后用于特化；用户类型别名在当前编译期环境中展开，保留原始声明供环境查询与诊断；尚未支持的复合类型不建立证明事实，见 [HIR 类型传播](hir.md#类型传播与降级特化)。
- **`(setf (the 类型 place) 值)`**（CLHS 5.1.2.6）：交叉编译和运行期都按 `(setf place (the 类型 值))` 处理。
- **Trucler 的缓存**：reference 环境会把查到的全局描述缓存在环境对象里，而会话的环境在多个文件之间是同一个，后来重新定义的宏会被缓存挡住，所以每个顶层形式之前都清空缓存。

## inline 声明

实现在 `lisp/front.lisp`。

- 编译期的 `proclaim` 记录 `inline` 和 `notinline`，存在 session 的 inline 表里，所以跨模块有效：kernel 里声明的函数，在 CLOS 模块和程序里调用时也会展开。
- 顶层的 `(defun f ...)` 若在 `(declaim (inline f))` 之后，就记下它的 lambda list、声明和 `(block f ...)` 形式的函数体。只记录 lambda list 只有必需参数、且定义在空词法环境里的函数。之后的同名定义替换记下的展开。`(setf f)` 函数同样可以 inline；Common-macros 把 setf 一个 place 默认展开成 `(funcall #'(setf f) 新值 参数...)`，这种调用按 `(setf f)` 的调用展开。
- 转换调用形式时（`hir-convert`），`(f a b)` 改写成 `(let ((x a) (y b)) 声明 (block f ...))` 再转换，所以实参按顺序、在外层环境里求值。以下情况不展开：
  - f 在调用处是局部函数；
  - 正在展开 f 自身（递归调用只展开一层），或者展开嵌套深度超过 8；
  - 有覆盖这个调用的 `notinline` 声明；
  - 调用处的局部函数、局部宏或局部 symbol macro 遮蔽了函数体里出现的某个名字；
  - 实参个数不对，这时照常调用，由运行期报错。
- **局部 `notinline`**：转换主体（`lambda`、`let`、`locally` 等）时，收集其开头的 `notinline` 声明，在转换主体期间生效（`*local-notinline*`）。局部函数调用也记录该限制，供后续 HIR 内联和调用点特化使用。
- **编译期求值不做全局 CST 展开**：展开式里可能用到 kernel 的内部函数和 `%primop`，它们在编译期并不存在。只有把形式转成目标端 HIR 时才打开展开（`*inline-enabled*`）。
- kernel 和 CLOS 里声明为 inline 的：一行的类型谓词、`char-code`、`acons`、`identity`、cXXr，`standard-instance-access`、`instancep`、`class-of+1`、`stamp+1`，结构的访问器等。

## 编译器宏

用户和库的 `define-compiler-macro` 参与目标代码转换。cross-client 将定义保存在会话环境中，
不会修改宿主的函数；image-client 查询运行期的编译器宏。宿主库的包装展开器继续作为
交叉编译的后备来源，显式删除会话内的定义也会遮蔽这个来源。
FORMAT 的交叉展开使用宿主上的 Invistra 指令编译器，client 只提供目标端的 client
表达式；生成形式不包含宿主对象。宿主的 Gray 包保留在独立名字下，目标源码的
NGRAY 包仍导入 Cyclosis 的符号。kiln 自身交叉编译时使用 image 中同一套服务。

普通调用和 `funcall` 的字面 `function` 名字都可展开，包括 `(setf name)`。局部函数或
局部宏会遮蔽同名编译器宏，全局及局部 `notinline` 阻止调用点展开；
`compiler-macro-function` 的环境查询只处理遮蔽，仍可查询被声明为 `notinline` 的全局定义。
展开器收到原始调用形式和词法环境；返回同一个形式表示拒绝展开，返回 NIL 则编译为 NIL。
展开结果重新进入转换，嵌套展开受预算约束。展开器出错时报告 style-warning，并保留原调用。
编译期求值本身不使用这项优化。

image 中的定义记录编译器宏依赖，包括当前不存在或拒绝展开的定义；设置、替换和删除
编译器宏均通知依赖者重新求值。独立 `compile` 返回的旧函数对象保留原来的代码。

## 优化策略

前端将 `speed`、`safety`、`debug`、`space` 和 `compilation-speed` 各以两位打包，
保存在函数、节点及变量的绑定信息上。全局 `proclaim` 影响后续编译，局部声明覆盖其
词法作用域；`let` 的初始化式继续使用外层策略，绑定检查及主体使用声明后的策略。
默认各质量均为 3。

- `speed` 为零或低于 `compilation-speed` 时，抑制内联、编译器宏、调用点克隆、cons
  标量替换及固定栈存储等可选变换。类型传播和捕获、cell、退出点分析仍然执行。
- `space` 高于 `speed` 时，多调用点小函数克隆采用更小的代码增长预算。
- `safety` 为零时省略声明的值检查，以声明作为调用者须遵守的契约；其他级别保留检查。
  常规算术仍保留任意精度结果的语义。
- `debug` 小于 2 时，不登记词法变量的源码名字；函数及位置仍保留。其他级别继续将
  变量视作调试器可观察的身份。逃逸证明使用绑定的策略，因此局部降低 debug 不会使
  外层已经可观察的绑定失去保护。

## 确定性

自举要求同一份源码在 SBCL 和 kiln 上编出逐字节相同的 KIR（[bootstrap.md](bootstrap.md)），所以前端和降级不能依赖：

- **哈希表的遍历顺序**：模块的额外符号和新定义包的外部符号按名字排序后输出。
- **gensym 计数器**：名字是 gensym 的局部函数，标签里去掉数字，由 `fresh-label` 的计数保证唯一。模块常量里的无名符号按第一次出现的顺序编号，标签用这个序号和模块名，名字以数字结尾的也改用这个序号（相当于 SBCL fasl 按对象本身保存无名符号）。代价是源码里写的 `#:x1` 这类名字也会被改掉，只影响打印。
- **宿主里碰巧共享的结构**：静态字符串常量按内容合并，KIR 的 cons 常量按 car 和 cdr 合并（`constant-word`）；Eclector 的反引号对模板里没有 unquote 的子表和尾部、以及最后的 `,@x`，都像 SBCL 一样当作字面量或尾部共享（vendor 补丁，CLHS 2.4.6 允许）。
- **宿主包名**：符号的标签和包名字符串统一用 `target-package-name`（测试程序的包在运行期叫 COMMON-LISP-USER）。
- **源码位置**：位置是 `file-position` 的八位组偏移，kiln 的文件流要扣除 `unread-char` 退回的字符；编译时的文件名两边要相同。

还不确定的：字面数据里未 intern 的符号，名字里带宿主当时的 gensym 计数（宿主自己也会调用 `gensym`，例如 SBCL 的 PCL）。

## 已知限制

- `defclass` 定义的访问函数，在文件末尾被报成未定义函数（`cmd:defclass-compile-time-action` 拿不到槽）。
- 全局符号宏（`define-symbol-macro`）：image-client 的运行期环境描述没有它，目标端编译器看不到。
- 运行期的 `proclaim` 支持 `special`、声明名字、`optimize` 和 inline 相关的声明，其他全局声明仍需扩展。
