# 前端：读入、顶层形式和编译期环境

前端把源码变成简化后的 AST，降级见 [lowering.md](lowering.md)。同一份前端既在 SBCL 上运行（交叉编译出 stage0），也在 kiln 上运行（自举、运行期 `compile`/`eval`）。

## 选择前端

编译会话可以使用两条输入路径：默认的 Iconoclast 路径，以及 `lisp/ir/` 中的直接 CST → IR → KIR 路径。`KILN_FRONTEND=ir` 在加载编译器时选择新路径；`KILN_FRONTEND=iconoclast` 选择旧路径。Lisp 调用者也可以动态绑定 `kiln.compiler:*front-end*` 为 `:ir` 或 `:iconoclast`。快照保存加载时的选择。

两条路径共享读入、顶层处理、编译期环境、内联源码表和 KIR 发射工具。新 IR 的词法绑定、自由变量、赋值、退出点和闭包布局直接记录在结构中，不调用 Iconoclast 的简化和 AST 分析。宏展开结果直接转换，不重建 CST；编译期求值仍由 client 的 HIR 或 Maclina 求值器处理。数据结构、源码位置和分析规则见 [ir.md](ir.md)。

下面描述默认的 Iconoclast 路径。

## 流水线

```
源文件
  │ Eclector（eclector.concrete-syntax-tree:read），一次读一个形式
  ▼
CST ── 顶层形式处理（lisp/front.lisp，CLHS 3.2.3.1）
  │      progn / eval-when / 宏展开在这里做，编译期求值交给 client 的求值器
  ▼
Common-boot cst-to-ast ──► Iconoclast AST
  │ simplify-ast（Common-boot AST-to-HIR 里的一串 Iconoclast 变换）
  ▼
简化后的 AST ── 降级（lisp/lower.lisp、lisp/primitives.lisp）
  ▼
KIR
```

**交接点是 `simplify-ast` 的输出**（理由见 [sicl-survey.md](../research/sicl-survey.md) 的“对 kiln 的影响”）。这时：

- 闭包已经转换：自由变量的值通过 `set-static-environment` 存进函数对象，函数体里用 `(static-environment)` 和 `read-static-environment` 读出；
- 被闭包捕获又被赋值的变量已经放进 cell（`make-cell`、`read-cell`、`write-cell`）；
- `let`/`let*` 变成一串 `let-temporary`，`flet` 和 lambda 都变成 `labels`，函数名字空间被消除（局部函数就是持有函数对象的变量）；
- 每个 `block`、`tagbody` 都带一个变量，表示它的退出点；`return-from`、`go` 引用这个变量；
- `symbol-macrolet` 已经代入，`macrolet` 变成 `locally`；
- 只调用一次的局部函数已经内联，没有用到的 block 已经删除。

目标端没有 Common-boot 的 AST-to-HIR 系统，`simplify` 抄了它的 `simplify-ast`。

## 文件划分和三种 client

| 文件 | 在哪里 | 内容 |
|---|---|---|
| `lisp/front.lisp` | 两边共用 | 顶层形式处理、inline 展开、声明简化、读入、session |
| `lisp/cross.lisp` | 两边共用 | `cross-client`：交叉编译用的编译期环境 |
| `lisp/target/compiler/client.lisp` | 只在 kiln 上 | `image-client`：在运行中的 image 里编译 |

`make-session` 的 `:client-class` 选择 client。宿主默认 `cross-client`，kiln 上默认 `image-client`。少量差异在 `front.lisp` 里用 `#+kiln` 区分（宿主为目标端编译时读入用的是目标的 features）：client 的超类、目标端读入的包是 CL-USER 而宿主是 KILN-USER、Common-macros 的包名等。

### cross-client：交叉编译

编译 kiln 自己的模块用它，在 SBCL 上和在 kiln 上都一样（kiln 编译自己时不能改掉正在运行编译器的 image，而且两边必须从同一个空的编译期环境开始）。

- **编译期环境是一个 Clostrum 环境**，和运行编译器的 image 隔离。目标里重定义 `car`、`defclass` 都不会碰到宿主。
- **编译期求值用 Common-boot 的 HIR 求值器**（`cb:eval-cst`）。它和 kiln 的前端一致，SICL 也这样做。宏函数会调用目标环境里定义的辅助函数，所以不能直接交给宿主的 `compile`。
- 宿主 CL 包里所有的函数导入编译期环境，宏展开函数可以直接调用它们。和全局环境打交道的函数换成访问 Clostrum 环境的版本：`macro-function`、`(setf macro-function)`、`fdefinition`、`(setf fdefinition)`、`fboundp`、`symbol-value`、`(setf symbol-value)`、`boundp`、`proclaim`、`macroexpand`、`macroexpand-1`，以及接受符号作为函数标识的 `funcall`、`apply`。
- **编译期的 CLOS**：被交叉编译的库在编译期需要 `defclass`、`defgeneric`、`define-condition` 的副作用，这部分用宿主 CLOS（通过 closer-mop），并且和目标 image 里的 metaobject 严格分开（SICL 的 E1 也是这样）。
- 在 kiln 上，“宿主”就是 kiln 自己：编译期环境同样是 Clostrum 环境，HIR 求值器的三个系统编进了 compiler 模块，导入的函数和宿主宏是 image 里的。

**宿主宏**：有些宏在编译期用宿主自己的展开函数，编译期的 `(setf macro-function)` 不覆盖它们：

- `quasiquote`/`unquote`/`unquote-splicing`（Eclector 的反引号）、`loop`/`loop-finish`（Khazern）、`defstruct`（Anatomicl，在宿主里运行，生成的代码不引用它自己）、不在顶层的 `defpackage`。否则目标源码里的 `defmacro quasiquote` 等会把编译期的反引号换成调用目标端函数的展开函数。
- **宿主库**：compiler 模块里的那些库（parser.packrat、s-expression-syntax、let-plus 等，包列表在 `*compiler-host-macro-packages*`）宿主也载入了，编译期直接用宿主的宏、函数和常量（`use-host-macros`）。宏照常编进模块，供运行期使用。不在编译期求值这些库本身，因为它们的宏在展开时要用编译期没有的东西（parser.packrat 的 `defrule` 要用 grammar 对象，let-plus 用泛函展开），有些宏也不在顶层定义。
- 宿主宏的展开里有宿主的反引号对象（SBCL 的 `sb-int:quasiquote` 和 `sb-impl::comma`），改写成 Eclector 的形式（`translate-host-backquote`），并且总是复制，不共享展开函数里的字面量。改写之后如果还有宿主对象或 `SB-` 包的符号就报错（`check-host-expansion`）。
- 这些宿主库的 compiler macro 也用于为目标编译的代码（`client-compiler-macro`），展开结果同样要通过检查，不合格的放弃展开。parser.packrat 的 `parse` 靠它在编译期编译常量表达式。
- **不能在编译期改宿主的状态**：`defgrammar`、`defrule`、`define-syntax` 的展开去掉 `(eval-when (:compile-toplevel) ...)` 部分，`ensure-grammar` 等包进 `kiln.compiler::load-time-only`（顶层只编译、不求值），否则会把宿主语法里正在使用的规则换掉。

**Common-macros 的宏**：标准宏在编译期用 Common-macros 的定义。宿主取 `cmd:macro-function`；kiln 上取 eval 模块载入 Common-macros 时存下的 `kiln.kernel::*common-macros*`。kiln 上 Common-macros 的包是 `KILN.CMD`，宿主上是 `COMMON-MACRO-DEFINITIONS`，所以 kiln 上展开结果里新出现的 `KILN.CMD` 符号换成宿主包的同名符号，它们的内部宏也以宿主的名字放进编译期环境。kiln 对 Common-macros 的定制在 `lisp/macro-client.lisp`，宿主载入包 `kiln.macros`，目标端读进 `kiln.macros-target`，同一个宏在编译期和运行期展开的结果相同。

### image-client：在 image 里编译

运行期 `compile`、`eval`、`load` 用它（[eval-compile.md](eval-compile.md)）。编译期环境就是运行期的环境，和一般的实现一样：

- Trucler 的全局环境是一个 `run-time-environment` 对象，对它的查询转给 eval 模块的 Maclina client：宏、特殊变量、常量、已定义的函数都来自运行中的 image。依赖追踪在这里记录查询（[dependencies.md](dependencies.md)）。
- 编译期求值用 Maclina。顶层 `macrolet`、`symbol-macrolet` 的局部宏换成 Maclina 词法环境里的局部宏。不在顶层的 `macrolet`：Common-boot 把局部宏的展开函数交成 AST，而 Maclina 要的是形式，所以 image-client 在 `finalize-local-macro-ast` 外面包一层，取局部函数 AST 的 origin（定义的 CST），由 Maclina 从这个形式编译，所在环境含外层的局部宏。
- 编译期的效果直接落在 image 里：`defmacro` 定义宏，`defvar` 宣告特殊变量，`deftype` 和 `define-setf-expander` 记在 plist 上。`declaim inline` 经 kernel `proclaim` 的 `*proclaim-hook*` 通知前端。
- image 里所有的编译会话共用一张内联函数表（`*image-inline-functions*`），初始内容是宿主编完 compiler 模块那一刻的 inline 表（`host-inline-functions`）。

## 顶层形式处理

Common-boot 本身的顶层处理不完整（`*compile-time-too*` 从来不会被设为真；SICL 加载文件时逐个形式 `eval-cst`，是 `load` 语义），所以 kiln 在 CST 层自己做：

- `progn`：逐个子形式递归处理。
- `eval-when`：按 CLHS 3.2.3.1 的表格决定是编译、编译期求值，还是两者都做。
- 宏形式：先查环境里的宏（`trucler:describe-function`），再查 Common-macros 的宏，展开后用 `cst:reconstruct` 保留源码位置，再递归处理。
- `locally`、`macrolet`、`symbol-macrolet`：主体按顶层形式处理，局部宏的展开函数求值后加进 Trucler 环境（`process-toplevel-body`）；主体以声明开头时整体编译。
- 其他形式：在 compile-time-too 模式下先求值，然后 `cst-to-ast`、`simplify-ast`，加入顶层 AST 列表。
- 处理每个顶层形式时 `*gensym-counter*` 绑定为 0，和 SBCL 的 `compile-file` 一样。
- `kiln.compiler::*trace-toplevel*` 为真时，把每个文件和每个顶层形式的开头打印到 `*error-output*`。

**文件项**：模块的文件列表里除了路径，还有 `(:compile-time-too 路径)`（文件里的形式都当作在 `(eval-when (:compile-toplevel :load-toplevel :execute))` 里处理，用于定义宏的展开函数要调用同文件里的函数的库）和 `(:renames 别名表 路径)`（读入时按别名换包名，作用于 `in-package` 和 `defpackage`；这样的文件里对编译期已有宏的重新定义只在载入时生效）。

**包和读入**：

- 顶层的 `defpackage` 和 `in-package` 在编译期执行（宿主上在宿主里），影响后面的读入；运行期的包从模块的符号表得到（[modules.md](modules.md)）。包系统存在之后编译的文件里，顶层 `in-package` 在载入时也设置 `*package*`，文件末尾恢复成 CL-USER，和 `load` 一样。
- 读目标源码时 `*features*` 绑定为 kiln 的列表（`:kiln :common-lisp :64-bit :x86-64 ...`），编译期环境里的 `*features*` 也是它，所以 `#+sbcl` 的分支不会读进 kiln 的代码。
- `#.` 在编译期环境里求值。

**未定义函数的警告**推迟到文件末尾（CLHS 3.2.2.3）：Common-boot 遇到未知函数时发出的 `no-function-description` 先被屏蔽、记录下来；文件处理完后，去掉本文件定义过的函数和原语，剩下的作为一个 style-warning 报告。

## 对 Common-boot 的调整

不改 Common-boot 的部分在 kiln 的 client 上用 `cb::convert` 的 `:around` 方法等完成；必须改源码的打成 vendor 补丁（`vendor/Common-boot`，见 `vendor/README.md`）。

- **对 symbol macro 做 `setq`**：Common-boot 不接受，CLHS 3.1.2.1.1 要求按对展开式的 `setf` 处理。转换之前把这样的 `setq` 改写成 `(setf 展开式 值)`。`with-slots`、`with-accessors` 依赖这一点。
- **声明和 `the` 里的复合类型**：Iconoclast 没有 `(function ...)`、`(values ...)` 这类类型的 AST，转换之前降级为 `function` 或 `t`，并去掉 `ftype` 声明。它们目前只是提示。
- **`(load-time-value form read-only-p)`**：转换前去掉 read-only-p。
- **`let` 绑定特殊变量要并行**：Iconoclast 的 `split-let-or-let*` 把绑定嵌套起来，排在一个特殊变量后面的初始化形式会看到它已经被绑定。所以几个变量的 `let` 里有特殊变量时，前端先把所有初始化形式求值到临时变量里，再绑定。
- **`(setf (the 类型 place) 值)`**（CLHS 5.1.2.6）：交叉编译和运行期都按 `(setf place (the 类型 值))` 处理。
- **Trucler 的缓存**：reference 环境会把查到的全局描述缓存在环境对象里，而会话的环境在多个文件之间是同一个，后来重新定义的宏会被缓存挡住，所以每个顶层形式之前都清空缓存。
- vendor 补丁修的上游问题：全局 special 变量的绑定之后环境变成 NIL；`load-time-value` 的子形式没有词法环境；lambda list 所在函数体里声明中的名字没有解析。

## inline 声明

实现在 `lisp/front.lisp`。

- 编译期的 `proclaim` 记录 `inline` 和 `notinline`，存在 session 的 inline 表里，所以跨模块有效：kernel 里声明的函数，在 CLOS 模块和程序里调用时也会展开。
- 顶层的 `(defun f ...)` 若在 `(declaim (inline f))` 之后，就记下它的 lambda list、声明和 `(block f ...)` 形式的函数体。只记录 lambda list 只有必需参数、且定义在空词法环境里的函数。之后的同名定义替换记下的展开。`(setf f)` 函数同样可以 inline；Common-macros 把 setf 一个 place 默认展开成 `(funcall #'(setf f) 新值 参数...)`，这种调用按 `(setf f)` 的调用展开。
- Common-boot 转换形式之前（`cb::convert :around`），`(f a b)` 改写成 `(let ((x a) (y b)) 声明 (block f ...))` 再转换，所以实参按顺序、在外层环境里求值。以下情况不展开：
  - f 在调用处是局部函数；
  - 正在展开 f 自身（递归调用只展开一层），或者展开嵌套深度超过 8；
  - 有覆盖这个调用的 `notinline` 声明；
  - 调用处的局部函数、局部宏或局部 symbol macro 遮蔽了函数体里出现的某个名字；
  - 实参个数不对，这时照常调用，由运行期报错。
- **局部 `notinline`**：Common-boot 的环境不记录 inline 声明，所以前端自己处理。转换 `lambda`、`let`、`locally` 等形式时，收集其主体开头的 `notinline` 声明，在转换整个形式期间生效。范围比 CL 规定的宽（绑定的初始化形式也包括在内），不展开总是正确的。
- **编译期的代码不展开**：展开式里可能用到 kernel 的内部函数和 `%primop`，它们在编译期并不存在。只有把形式转成目标端 AST 时才打开展开（`*inline-enabled*`）。
- kernel 和 CLOS 里声明为 inline 的：一行的类型谓词、`char-code`、`acons`、`identity`、cXXr，`standard-instance-access`、`instancep`、`class-of+1`、`stamp+1`，结构的访问器等。

## 编译器宏

用户和库的 `define-compiler-macro` 在编译期被忽略（编译期环境里的 `(setf compiler-macro-function)` 什么也不做：登记进 Clostrum 的话，Common-boot 会调用它尚未实现的 `expand-compiler-macro`），运行期只记在 plist 上。唯一的例外是上文的宿主库 compiler macro。

## 确定性

自举要求同一份源码在 SBCL 和 kiln 上编出逐字节相同的 KIR（[bootstrap.md](bootstrap.md)），所以前端和降级不能依赖：

- **哈希表的遍历顺序**：模块的额外符号和新定义包的外部符号按名字排序后输出。
- **gensym 计数器**：名字是 gensym 的局部函数，标签里去掉数字，由 `fresh-label` 的计数保证唯一。模块常量里的无名符号按第一次出现的顺序编号，标签用这个序号和模块名，名字以数字结尾的也改用这个序号（相当于 SBCL fasl 按对象本身保存无名符号）。代价是源码里写的 `#:x1` 这类名字也会被改掉，只影响打印。
- **宿主里碰巧共享的结构**：KIR 的 cons 常量按 car 和 cdr 合并（`constant-word`）；Eclector 的反引号对模板里没有 unquote 的子表和尾部、以及最后的 `,@x`，都像 SBCL 一样当作字面量或尾部共享（vendor 补丁，CLHS 2.4.6 允许）。
- **宿主包名**：符号的标签和包名字符串统一用 `target-package-name`（测试程序的包在运行期叫 COMMON-LISP-USER）。
- **源码位置**：位置是 `file-position` 的八位组偏移，kiln 的文件流要扣除 `unread-char` 退回的字符；编译时的文件名两边要相同。

还不确定的：字面数据里未 intern 的符号，名字里带宿主当时的 gensym 计数（宿主自己也会调用 `gensym`，例如 SBCL 的 PCL）。

## 已知限制

- `defclass` 定义的访问函数，在文件末尾被报成未定义函数（`cmd:defclass-compile-time-action` 拿不到槽）。
- 全局符号宏（`define-symbol-macro`）：image-client 的运行期环境描述没有它，目标端编译器看不到。
- 运行期的 `proclaim` 只记录 `special` 和 inline 相关的声明。
