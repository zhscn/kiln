# 11 M5：编译器在 kiln 上运行，自举

**状态**：
- M5.1 完成（2026-11，§5）：目标端有了运行期的标准宏、`eval`、`compile`、`load` 和 REPL。
- M5.2 完成（2026-11，§7）：Common-boot 和它的依赖编成 compiler 模块，kiln 上 `cst-to-ast` 的结果和 SBCL 逐字相同。
- M5.3 完成（2026-11，§8）：kiln 自己的前端和 `lower.lisp` 也编进 compiler 模块，kiln 上编出的 KIR 和 SBCL 的逐字相同。

## 1. 目标和验证

- kiln0 是 SBCL 交叉编译出的 kiln。M5 要让同一个编译器（Common-boot 前端加 `lisp/*.lisp` 的中后端）在 kiln0 上运行，编译 kiln 自己的源码，产出 KIR。
- 验证分两步：
  1. kiln0 上编译出的 KIR 和 SBCL 上编译出的 KIR 逐字一致（kiln0 → kiln1）；
  2. kiln1 编出的 kiln2，其 KIR 和 kiln1 的一致。
- 两步都要求 KIR 输出是**确定的**：不依赖哈希表的遍历顺序，也不依赖 gensym 计数器在编译之外的状态。现在 SBCL 上是否已经确定，要在 M5.3 之前检查一遍：同一份源码编两遍，比较输出。
- KIR 到机器码这一步仍由 Rust 的 kiln-cg 完成（AOT 或 JIT）。M5 不要求 kiln-cg 进 image，那是 M5.5。

## 2. 要编进目标端的代码

宿主编译器 `kiln` 系统的依赖闭包约 6.5 万行（2026-11 统计，用 ASDF 数源文件行数）：

| 已在目标端 | 还没有 |
|---|---|
| Eclector、Concrete-Syntax-Tree（`frontend` 模块，10 §24），Khazern、Acclimation、Trinsic（CLOS 模块） | alexandria、closer-mop、let-plus、anaphora、more-conditions、utilities.print-items、architecture.builder-protocol、parser.packrat、s-expression-syntax、Iconoclast（AST、builder、walker、transformations）、Trucler（base、reference）、Clostrum（含 basic、trucler）、Ecclesia、Common-macros、Common-boot（含 HIR、AST-to-HIR、HIR-evaluator）、kiln 自己的 `lisp/*.lisp` |

`trucler-native` 是 SBCL 专用的，目标端不需要。Anatomicl 在宿主里展开 `defstruct`，目标端的编译器同样需要它。

### 2.1 运行期 `compile`：最先要解决的问题

- **s-expression-syntax 载入时就调用 `compile nil`**：它为每个特殊形式的语法定义编译一个解析器（`code/database.lisp` 的 `compile-parser`）。
- parser.packrat 在运行期为 inline cache 调用 `compile`（`src/interface/inline-cache.lisp`）。编译语法规则时，它用 `sb-cltl2:macroexpand-all` 检查一个表达式用了哪些宏（`src/grammar/base/compiler.lisp`）。
- Common-boot 用 s-expression-syntax 解析特殊形式。所以目标端在载入前端之前就要有 `compile`，不能等前端自己编译自己。

**决定：目标端的 `eval` 和 `compile` 先用 Maclina。**
- Maclina 是用可移植 CL 写的字节码编译器、VM 和 FASL 加载器。字节码函数是真正的函数（funcallable instance），能和原生函数互相调用。
- 依赖少：closer-mop、alexandria、Trucler、Ecclesia，`compile-file` 部分还要 Eclector。全部约 4500 行，不依赖 s-expression-syntax，所以没有循环依赖。
- 它同时解决几件事：
  - 目标端编译期求值宏和 `eval-when`；
  - 一个能用的 REPL（`read` + Maclina `eval` + `print`）；
  - s-expression-syntax 和 parser.packrat 的运行期 `compile`。
- 字节码很慢。M5.5 有了原生 `compile`（KIR → 进程内 Cranelift）之后，`compile` 改走原生路径，Maclina 保留作 `eval` 和交付期的轻量求值器（04 关键选择 1 的备选方案）。
- 宿主侧编译期求值暂时仍用 Common-boot 的 HIR 求值器。KIR 只依赖宏展开的结果，不依赖由哪个求值器执行宏。两边换成同一个求值器能少一套代码，但不是 M5 的前提。

**`macroexpand-all`**：parser.packrat 只用它判断一个名字是否被用到（`%uses?`）。在 `#+kiln` 下改成保守的树遍历：名字出现过就当作用到了，结果只会让生成的解析器多做一点事，不会出错。按 vendor 规则先原样 vendor，再打补丁。

**closer-mop**：不用 vendor。M4 已经把 closer-mop 的符号别名到 Clostrophilia 的函数和类上（10 §20），Maclina 直接用。

## 3. 分步计划

| 步骤 | 内容 | 验证 |
|---|---|---|
| M5.1 ✅ | 目标端 Maclina：Ecclesia、Common-macros、Trucler 和 Maclina 编成 `eval` 模块（§5）；`eval`、`compile`（字节码）、`load` 源文件；最简 REPL | 测试里对字节码函数 `funcall`、和原生函数互相调用、`load` 一个源文件；不读文件时 REPL 能读入并求值 |
| M5.2 ✅ | 前端的其余依赖编成目标端的 compiler 模块（§7）：let-plus、anaphora、more-conditions、print-items、builder-protocol、parser.packrat、s-expression-syntax、Iconoclast、Trucler reference、Clostrum、Common-macros（AST 展开器）、Common-boot | 在 kiln 上 `cst-to-ast` 一组形式，打印 AST 的类和结构，和 SBCL 比对（`tests/m5/co-ast`） |
| M5.3 ✅ | kiln 的 `lisp/*.lisp` 编进目标端（§8）；在 kiln 上把一个测试文件编成 KIR | 和 SBCL 产出的 KIR 逐字一致（`tests/m5/co-compile`）；KIR 不依赖 gensym 计数器（§8.2） |
| M5.4 | kiln0 编译全部 kiln 源码（kernel、CLOS、前端、编译器各模块），kiln-cg AOT 链接成 kiln1；kiln1 再编出 kiln2 | kiln0 和 kiln1 产出的 KIR 一致；kiln1 和 kiln2 的一致；`tools/test.sh` 在 kiln1 上通过 |
| M5.5 | 原生 `compile`：kiln-cg 作为库链进 kiln-rt，`compile` → KIR → 进程内 JIT，代码登记进运行中的 image；s-expression-syntax 等的 `compile` 改走这条路径 | `compile` 出的函数和 AOT 的结果一致；编译时间 |

M5.4 每次编译都要跑完整的前端，速度取决于 CLOS 分派和 GC（10 §24、§26）。要是太慢，把 M5.5 提前：宏展开函数和 packrat 的解析器在字节码里执行，可能是主要开销。

和 M5 并行做的是 §4 的调试基础设施：它不改变编译器的行为，但需要的数据要在 M5 定下 KIR 格式时留出位置。

## 4. 调试基础设施：M5 定格式，M6 起做界面

最终要提供：
- 跳转到定义（Emacs 的 M-.）、who-calls、按文件列出定义；
- 重定义警告（「这个函数原来在另一个文件里定义」）；
- 宏展开查看器、单步执行。

界面在 M6 和 SLYNK 一起做，但下面这些数据由编译器产出，格式要在 M5 定下来。以后再改 KIR 和 ABI，代价很大。

### 4.1 定义记录（dspec）

**参考**

- **LispWorks 的 dspec**（*LispWorks User Guide* 第 7 章）：
  - **名字**：dspec 是定义的名字，不要求定义存在。规范形式是 `(类 主名字 . 限定)`，用 `equal` 比较。例：`car`、`(setf car)`、`(defclass standard-object)`、`(defmethod foo :around (integer t))`。
  - **类即名字空间**：顶层类对应不同的全局名字空间，例如 `variable` 下分出 `defvar` 和 `defconstant`。每个类提供 `definedp`（是否已定义）和 `undefiner`（怎样撤销定义）。
  - **别名**：`defparameter` 是 `defvar` 的别名，因为二者的效果无法区分。用户的定义宏展开成系统定义时，也要声明别名。
  - **定义之间的关系**：
    - 子定义：`defstruct` 展开出的访问函数用 `def` 记为外层定义的子形式。查 `foo-bar` 时返回 `((defstruct foo) 文件)`。
    - 分布式定义：方法是泛函的「部分」，主名字是泛函的名字，限定部分用来区分不同的方法。
  - **局部函数**：`(subfunction 子名字 父dspec)`，`flet`/`labels` 有简写。trace 和 advice 用它找局部函数。
  - **位置**：文件路径、`:listener`、`:unknown`，以及子定义的 `:inside`。
  - **记录时检查**：`record-definition` 在定义执行时记录位置，同时检查同名定义是否来自另一个位置，按 `*redefinition-action*` 警告或报错；还能保护包，例如禁止给 CL 包的外部符号下定义。
  - **form parser**：编辑器只看源码不执行，靠 form parser 从顶层形式算出 dspec。默认规则是：car 以 `DEF` 开头的形式，取第二个元素作名字。
- **Emacs Lisp**：
  - `load-history` 按文件记录这个文件定义了什么，元素形如 `(defun . f)`、`(cl-defmethod 名字 限定 . 特化)`、`(provide . 特性)`。
  - 不记录在文件中的位置。`find-function` 打开文件后，按定义种类用正则表达式重新搜索（`find-function-regexp-alist`）。宏展开出的定义还可以按展开结果去匹配。
  - 在另一个定义里面定义的东西，用符号的 `definition-name` 属性指向外层定义的名字，这和 LispWorks 的子定义是一个意思。
  - `unload-feature` 按 `load-history` 撤销定义，对应 LispWorks 的 `undefiner`。
  - 教训：不记位置、靠搜索找回来，宏生成的定义就很难找。kiln 有 CST，可以直接记位置。

**kiln 的格式（决定）**
- 名字采用 LispWorks 的规范形式 `(类 主名字 . 限定)`。符号单独出现时表示函数。
- 第一批类：`defun`、`defmacro`、`defgeneric`、`defmethod`（限定为方法限定符加特化列表）、`defclass`、`defstruct`、`define-condition`、`defvar`（`defparameter` 是别名）、`defconstant`、`deftype`、`defsetf`、`define-setf-expander`、`define-compiler-macro`、`define-method-combination`、`defpackage`。
- 位置：`(文件 起始偏移 结束偏移)`，取自顶层形式的 CST。子定义多一项父 dspec。文件用编译时的名字，交付期可以去掉。
- 记录点在 `process-toplevel`：
  - 宏展开之前，按顶层形式的 car 查一张表，由表中对应的条目算出 dspec。这张表的作用相当于 LispWorks 的 form parser，名字待定，比如 `kiln:define-dspec-parser`，用户可以扩展；表里没有的定义宏，按 `DEF` 前缀的默认规则处理。
  - 展开之后，结果里的 `defun` 等记为子定义，例如 `defstruct` 展开出的访问函数。
- KIR 模块加一个顶层条目 `(defs (dspec 位置) ...)`，dspec 是普通数据。模块初始化时，把这些记录装进 image 里的定义表。
- 同一个 dspec 被另一个文件重新定义时，载入时发出警告。这是重定义屏障（C4）的一部分；对哪些包报错、对哪些包只警告，可以配置。
- 局部函数复用现在的函数标签名字提示（`*name-hint*`）：`(flet g (defun f))` 写进函数的调试信息。
- seal 时（docs/01），tree shaking 用定义表知道每个函数来自哪个定义。

### 4.2 源码位置和调用点描述符

- 07 §4 计划把栈图和 06 §6 的调用点表合并成统一的**调用点描述符**，按返回地址索引：GC 槽位、handler、帧大小，再加 debugger 需要的信息。
- 信息加两项：
  - 调用点所在的函数（指向函数的调试信息：名字、dspec、lambda list）；
  - 调用点对应的源码形式（文件内偏移，引用的是哪个顶层形式由函数的调试信息给出）。
- KIR 的写法：`call-lisp`、`call-rt` 和 poll 点带可选的 `(loc 起始 结束)`，函数带 `(debug-info 名字 dspec lambda-list)`。kiln-cg 把它们写进调用点表。这样 backtrace 能显示每一帧的源码形式，错误信息也能定位。
- 变量在栈帧里的位置（Cranelift 的 value label）留到 M6 做单步和栈帧检查时再加，KIR 先给 `vars` 留可选的源码名字。

### 4.3 宏展开的追踪和来源

- **参考**：
  - Racket 的展开器在展开过程中发出事件流，macro stepper（Culpepper）和 DrRacket 用它显示展开过程，并支持隐藏策略：只看用户自己的宏，不看库里的宏。syntax 对象带 `origin` 属性，记录它由哪些宏生成。
  - Emacs 29 起，字节编译器读入的符号带位置（symbols with position），所以展开后的警告也能定位到源码。
  - LispWorks 的源码级调试要求宏展开结果里的子形式和原来的参数 `eq`；宏复制了子形式时，用 `replacement-source-form` 补救。
- **kiln**：
  - Eclector 的 CST 加上 `cst:reconstruct`，已经能让展开结果里和原参数 `eq` 的部分回到源码位置。这和 LispWorks 的规则是一样的。
  - 在两个地方发出「宏名、展开前的 CST、展开后的 CST」事件：`process-toplevel` 的宏展开，以及 `cb::convert` 的 `:around`（inline 展开已经挂在这里）。M5 期间先在宿主上用，做一个 `kiln:trace-expansions` 调试 kiln 自己。
  - 展开结果里不来自原始源码的部分，标上生成它的宏的调用位置。这样 §4.2 的源码位置至少能指到那个宏调用。
- M6 的宏展开查看器（隐藏策略、逐步展开）建立在这个事件流上。

### 4.4 单步和断点（M6 之后）

- **Clordane 的设计**（文档附录「Implementing poll points」）：
  - 每个线程有一个调试标志、一张按 PC 索引的断点表，以及一张约 1024 位的摘要位表（PC 取模）。
  - 用高 debug 级别编译时，在每个源码形式的前后插入对一个局部小例程的廉价调用。例程先看调试标志，再看位表，最后才查断点表。
  - 线程不在调试时，开销只是一次标志检查。
- **kiln**：
  - 不在机器码上打断点。Cranelift 不做去优化，机器码层面的断点很难做对。
  - 按 Clordane 的方式在源码形式前后插入检查，但不默认插入：用户对某个函数要求单步时，用 JIT 重新编译一份带检查的版本，替换函数格里的入口，借助重定义屏障（C4）。
  - 检查和现有的 poll 点（06 §7）共用 `ctx` 上的标志位。
  - 需要 §4.2 的源码位置和 M6 的变量位置，以及交互式 debugger。

## 5. M5.1：`eval` 模块

**模块**：`kiln:compile-eval`，在 CLOS 模块之后载入；名字以 `ev-` 开头的测试（`tests/m5/`）带上它运行。`tools/repl.sh` 构建 kernel、CLOS、eval 三个模块，链接成可执行文件后启动 REPL；`--jit` 改用 JIT 运行。内容按顺序：

1. Ecclesia。
2. **运行期的标准宏**：Common-macros。
   - 宿主编译器用的是它的 extrinsic 版本：包 `COMMON-MACRO-DEFINITIONS` 遮蔽了宏的名字，宏定义在小写名字的符号上。这些源码不能原样编进目标端，upstream 的 intrinsic 包也不能用（遮蔽得太少，见 `vendor/README.md`）。
   - kiln 自己定义一个包 `kiln.cmd`：使用 CL，只遮蔽 `get-setf-expansion`、`ensure-generic-function`、`proclaim` 这三个带 client 参数的函数。读 Common-macros 的源码时把包名 `COMMON-MACRO-DEFINITIONS` 换成 `KILN.CMD`。
   - 换包名靠文件项 `(:renames 别名表 路径)`（`front.lisp` 的 `*package-renames*`），它作用于 `in-package` 和 `defpackage`。这样的文件里，对编译期已有宏的重新定义只在载入时生效，宿主编译器的宏不会被换掉。
   - kiln 对 Common-macros 的定制（`defclass`、`defgeneric`、`defmethod` 的展开等）从 `front.lisp` 移到 `lisp/macro-client.lisp`。宿主把它载入包 `kiln.macros`；目标端把它读进 `kiln.macros-target`，在那里 `cmd` 指向 `kiln.cmd`。所以同一个宏在编译期和运行期展开的结果相同。
   - kernel 和 CLOS 自己定义的宏（`loop`、`define-condition`、`do-symbols` 等）在载入 Common-macros 之前保存起来，之后恢复，所以仍然优先。
   - `define-setf-expander` 和 `defsetf` 现在在载入时也生效：展开函数记在符号的 plist 上。运行期的 `get-setf-expansion` 依次查展开函数、宏，最后用 setf 函数。
3. Trucler（base，以及 trucler-native 的 client 类）。
4. Maclina：base、compile、vm-shared、vm-native。`compile/parse-macro.lisp` 带 `:compile-time-too`，因为 `destructure-syntax` 的展开函数要调用它。
5. `lisp/target/eval/evaluator.lisp`：
   - kiln 的 Trucler client 继承 `trucler-native:client`，Maclina 的 native VM 就是为这类 client 写的。它描述的全局环境是 NIL：
     - special 变量来自运行期的 `proclaim`，`defvar` 的展开在载入时就会调用它，把变量记在 plist 上；
     - 常量来自 `defconstant`；
     - 函数和宏查符号本身。
   - `macro-function` 和 `macroexpand` 收到 Maclina 的词法环境时，经 Trucler 查局部宏（kernel 的 `*environment-macro-function*`）。
   - `eval` 编译成字节码后执行。对未知函数的调用只在形式执行完后仍未定义时才警告，所以递归的 `defun` 不会报警告。
   - `compile` 产出字节码函数。
   - `load` 逐个读入形式并 `eval`。
6. `lisp/target/eval/repl.lisp`：`kiln.sys:repl`。
   - 维护 `*`、`+`、`/` 等变量。
   - 形式没有处理的错误会被打印出来，然后经 `abort` 回到提示符。

**验证**（`tests/m5/ev-macros.lisp`、`ev-eval.lisp`）：
- 运行期宏展开；
- `eval` 覆盖：
  - 特殊变量在原生代码和字节码之间的动态绑定；
  - 闭包、多值、`catch`/`unwind-protect`、`labels`、`&key`；
  - 原生代码里发出、在字节码里处理的 condition；
  - 经 `eval` 定义的类、泛函和方法；
  - 原生代码调用字节码函数；
- `compile`；
- `load` 一个文件，其中的宏供后面的形式使用，还有 `defpackage` 和 `in-package`；
- 在字符串上运行 REPL。

**性能**：
- 启动：AOT 可执行文件 0.3 秒；JIT 7.7 秒，用来编译所有模块。
- 字节码很慢：`(fib 25)` 要 5.7 秒，SBCL 的编译代码约 1 毫秒。`eval` 一个小形式约 0.3 毫秒。
- 前端要在 kiln 上运行，s-expression-syntax 的解析器也是 `compile` 出来的，所以 M5.5 的原生 `compile`，或者 VM 本身的性能（它的主循环是 kiln 编译的），可能要提前做。

**顺带修的问题**：
- NIL 和 T 的函数格是空的，`(fboundp nil)` 会崩溃。现在 kernel 启动时给它们放上未定义函数对象。
- 没有 slot 的结构体被 `:include` 时，报「没有这个结构体」。
- 宏展开函数调用的 `eval` 用的是宿主的环境。现在在编译期环境里求值（Maclina 的 `defops`）。
- Predicament 的若干 bug，见 `vendor/README.md`：`style-warning` 不是 `warning`；`reader-error` 的超类不对；`(abort)` 等不带参数调用时总是失败。
- 补了 `map-into`、`nintersection`、`nset-difference`、`nset-exclusive-or`，以及缺的 `-if-not` 函数。

## 6. 字节码 VM 的性能（M5.1 之后）

基准是 `(fib 25)` 在 REPL 里由字节码执行（AOT 可执行文件，`perf` 取样）。SBCL 的编译代码约 1 毫秒。

| 改动 | 秒 |
|---|---|
| M5.1 结束时 | 5.70 |
| 字节码存成 simple vector：kiln 的 Maclina client 定义 `m:make-module` 方法。`(unsigned-byte 8)` 数组是 Regalia 的实例，`aref` 要经过几层泛函和 `typep` | 1.90 |
| 结构的访问器不再是泛函（先是带缓存的闭包函数） | 1.27 |
| `ash` 的 fixnum 快速路径（KIR 加了按值移位 `shlv`、`sarv`）。原来每次都由 runtime 换成 BigInt 再算 | 1.18 |
| `ceiling`、`round` 的 fixnum 快速路径。Khazern 把 `(loop repeat n)` 展开时用到 `ceiling` | 0.81 |
| 访问器是 inline 的顶层函数，槽位置是常量；inline 也支持 setf 函数（10 §15、08 §8） | 0.70 |
| `(eql x 常量)` 按 `eq` 降级；只有一个下标的 `aref` 就地读写 simple vector | 0.55 |

`eval` 一个小形式约 0.22 毫秒，主要花在 Maclina 编译上。

**剩下的开销**：
- 主循环本身约占三分之一，热点是循环头的一长串栈槽到栈槽的搬移。有大约二十个值活过整个循环，主要是 VM 的局部函数（`spush`、`spop`、`code` 等）的闭包对象，它们都被 spill 了，每条指令都要搬一遍。
- 解决办法是在编译器里对不逃逸的局部函数做 lambda lifting，或者内联小的局部函数。这对所有代码都有用，不只是 VM。
- 其余开销：Maclina 自己的泛函（`m:entry-pc` 等，每次调用要访问五次）；`max`，以及 `logand`/`logior` 的全局调用。

原生 `compile` 不能提前：它要在 kiln 上产出 KIR，前提是前端和 `lower.lisp` 在 kiln 上运行（M5.2、M5.3），而运行期编译的代码怎样引用运行期才有的符号和字面量，也要和 M5.3 一起设计。所以仍按 M5.2 → M5.3 → M5.5 的顺序。

## 7. M5.2：compiler 模块

compiler 模块（`kiln:compile-compiler`，`lisp/driver.lisp` 的 `*compiler-files*`）在 frontend 和 eval 模块之后载入，现在有 511 个源文件。顺序是：
1. print-items、anaphora、let-plus、more-conditions、builder-protocol；
2. parser.packrat、s-expression-syntax（含 CST client）；
3. Iconoclast（AST、builder、walker、transformations）、Trucler reference、Clostrum（basic、trucler；不含文档字符串）；
4. Common-macros（宏到 AST 的展开器，不是 M5.1 的 Common-macro-definitions）、Common-boot。

大多数文件的列表从 ASDF 取（`system-files`）。测试 `co-*.lisp` 和 kernel、CLOS、frontend、eval、compiler 五个模块一起运行：
- `co-syntax`：s-expression-syntax 用 list builder 解析特殊形式；
- `co-ast`：Common-boot `cst-to-ast` 十个形式，输出和 SBCL 逐字相同。

规模：KIR 约 100 MB，链接后的可执行文件约 120 MB。`co-ast` 的 AOT 可执行文件连启动共 1.4 秒。

### 7.1 宿主的宏展开这些库

这些库宿主也载入了（它们是宿主前端的依赖），所以编译期直接用宿主的定义，像 LOOP 一样（`kiln.compiler:use-host-macros`，包列表在 `*compiler-host-macro-packages*`）：
- 这些包的宏在编译期由宿主的展开函数展开，宏还是照常编进模块，供运行期使用。宿主的 `defmacro` 不在编译期生效。
- 编译期求值调用的这些包的函数，也是宿主的函数。
- 这些包的常量用宿主的值。

**为什么不在编译期求值这些库本身**：
- 它们的宏在展开时要用编译期没有的东西：parser.packrat 的 `defrule` 在宏展开时编译规则，要用 grammar 对象（CLOS）；let-plus 用泛函做展开。宿主的编译期环境里没有 CLOS。
- 有些宏不是在顶层定义的（anaphora 的 `anaphoric` 在 `let` 里定义）。按 `compile-file` 的语义它在编译期不存在，但 ASDF 编完一个文件就载入，下一个文件就能用。

**宿主展开结果的处理**：
- 宏定义宏的展开里有 SBCL 的反引号（`sb-int:quasiquote` 和 `sb-impl::comma` 对象）。这些被改写成 Eclector 的 `quasiquote`/`unquote`/`unquote-splicing`（`translate-host-backquote`）。
- 改写之后如果还有宿主对象或 `SB-` 包的符号，就报错（`check-host-expansion`）。

**不能在编译期改宿主的状态**：
- s-expression-syntax 把一些 `defrule` 放在 `(eval-when (:compile-toplevel ...))` 里。如果在编译期求值，会把宿主语法里的规则换成编译期求值器执行的闭包，而宿主自己也在用这些规则解析。
- 所以 `defgrammar`、`defrule`、`define-syntax` 的展开去掉 `(eval-when (:compile-toplevel) ...)` 部分。`ensure-grammar`、`ensure-rule`、`ensure-syntax` 包进 `kiln.compiler::load-time-only`，它展开成 `(eval-when (:load-toplevel) ...)`，在顶层只编译、不求值。
- `in-grammar` 在宏展开时设置宿主的 `*grammar*`，宿主的 `defrule` 在当前 grammar 里编译规则。

**常量**：Clostrum-basic 的 `(defconstant +unbound+ 'unbound)`，其值正是宿主 Clostrum（编译期环境本身）表示未绑定格子的标记。存进编译期环境后，这个常量看起来就是未绑定的。

### 7.2 补丁和修正

vendor 补丁（`vendor/README.md`）：
- parser.packrat 和 s-expression-syntax 原样 vendor，两者都是宿主库。
- parser.packrat 的 `%uses?` 用 `sb-cltl2:macroexpand-all`（§2.1），改成保守的树遍历。
- s-expression-syntax：
  - `constant?` 改用 `constantp`；
  - `pprint-logical-block` 的语法里，`suffix` 被写成了连字 ﬃ（U+FB03），SBCL 只警告了一下。
- Common-macros 的 `define-modify-macro` 用 `let` 绑定位置的临时变量，新值的形式引用不到它们，改成 `let*`。
- Clostrophilia：
  - 调用带 `&key` 的方法时，上游在参数后追加 `:allow-other-keys t`，方法的 `&rest` 参数也看得到它（builder-protocol 会把这样的列表存进节点）。kiln 改为在方法 lambda 的 lambda list 里加 `&allow-other-keys`（`lisp/macro-client.lisp`）。
  - `:allocation :class` 的槽一开始就绑定为 `nil`，所以 initform 永远不起作用。改成一开始未绑定。

kiln 自己的修正：
- **前端**：
  - `(the (values ...) x)` 和 `(the (function ...) x)`：Iconoclast 没有这些类型的 AST，降成 `t` 和 `function`，和 DECLARE 的处理一样（08）。
  - 在包系统存在之后编译的文件里，顶层 `in-package` 在载入时也设置 `*package*`，文件末尾恢复成 CL-USER。这和 `load` 一样；Iconoclast 在载入时用当前包 `export`。
- **CLOS**：
  - 前向引用的超类：先是 `forward-referenced-class`；定义时，这个对象本身经 `change-class` 和 `initialize-instance` 成为真正的类。这样子类的 CPL 和特化在它上面的方法看到的是同一个对象。
  - 新增 `cl:ensure-generic-function`、closer-mop 的 `ensure-finalized`。
  - funcallable 实例的 `change-class`。
  - `documentation` 和 `(setf documentation)` 改成泛函。Maclina 给它们加方法，原来会把 kernel 的函数整个换掉。
- **kernel**：
  - 新增 `fmakunbound`；
  - `map`、`map-into` 不再复制列表参数。builder-protocol 传进来的是循环列表，`map` 应当在最短的序列处停止。
- **运行期宏环境**：`macro-function` 和 `macroexpand` 带环境时，用造出这个环境的那个 client 去查询（`kiln.eval:environment-client`）。Common-boot 的 trucler-reference 环境用 reference client 查询（`lisp/target/compiler/environment.lisp`）。

**测试基础设施**：一个 SBCL 会话编完五个模块和所有测试，需要 `--dynamic-space-size 4GB`。

M5.3 的做法见 §8。

## 8. M5.3：编译器在 kiln 上编出 KIR

compiler 模块的末尾加上 kiln 自己的 `lisp/abi.lisp`、`kir.lisp`、`lower.lisp`、`values.lisp`、`primitives.lisp`、`front.lisp`，以及目标端的 `lisp/target/compiler/client.lisp` 和 `session.lisp`。这些文件读进宿主已有的包（`kiln.compiler` 等），运行期的包从符号表得到。

验证用 `tests/m5/co-compile`：在 kiln 上用 `front-end` 和 `compile-module` 编译 `co-compile-input.lisp`，打印 KIR。期望输出是同一个 SBCL 会话里宿主编出的那个模块。`co-compile.same-kir` 写着输入文件的测试名，`tools/test.sh` 据此拿 `build/test/` 下的 KIR 当期望输出，不必提交 KIR 文件。输入本身也是普通测试，检查编出的程序运行结果。输入用到了：
- 包、`defvar`、`defparameter`、`defconstant`、`eval-when` 和 `defmacro`；
- inline 函数、闭包、`flet`/`labels`、多值、`handler-case`、`catch`、`unwind-protect`；
- LOOP、`defclass`/`defgeneric`/`defmethod`、`setf` 和 `push`；
- 顶层的 `macrolet` 和 `symbol-macrolet`；
- 字符串、字符、单双精度浮点、分数、bignum。

两边的 KIR 逐字相同（1113 行）。kiln 上编这个约 100 行的文件，AOT 可执行文件连启动要 12 秒，SBCL 不到 1 秒。

### 8.1 前端拆成三个文件

- `lisp/front.lisp` 两边共用：顶层形式处理、inline 展开、声明简化、读入、session。少量差异用 `#+kiln` 区分，因为宿主为目标端编译时用的是目标的 features：
  - `client` 的超类：宿主是 `kiln.macros:macro-client` 加 HIR 求值器的 client，目标端是 `kiln.macros-target:macro-client`；
  - `macroexpand-toplevel` 在目标端不排除 `defmacro`，也没有 Common-macros 的后备展开；
  - 目标端读入的包是 CL-USER，宿主是 KILN-USER；
  - 绑定的是 `kiln.cmd:*client*`，宿主是 `cmd:*client*`。
  - `simplify` 抄了 Common-boot 的 `simplify-ast`：目标端没有它所在的 AST-to-HIR 系统。
- `lisp/host.lisp` 只在宿主：Clostrum 编译期环境、导入宿主函数、宿主宏（§7.1）、宿主常量。
- `lisp/target/compiler/client.lisp` 只在目标端。编译期环境就是运行期的环境，和一般的实现一样：
  - Trucler 的全局环境是一个 `run-time-environment` 对象。对它的查询转给 eval 模块的 Maclina client，它描述的就是运行中的 image：宏、特殊变量、常量、已定义的函数。
  - 编译期求值用 Maclina。顶层 `macrolet`、`symbol-macrolet` 引入的局部宏，换成 Maclina 词法环境里的局部宏。
  - 编译期的效果直接落在 image 里：`defmacro` 定义宏，`defvar` 宣告特殊变量，`deftype` 和 `define-setf-expander` 记在 plist 上。`defconstant` 的编译期部分 `kiln.sys::%define-constant`，在 kernel 里补了运行期的定义（宿主的编译期环境有自己的定义）。
  - `declaim inline` 经 kernel `proclaim` 的 `*proclaim-hook*` 通知前端。
- **session**：目标端的编译器不知道宿主编译前面几个模块时记下的 inline 函数。`session.lisp` 的 `(host-inline-functions)` 是宿主宏（`compile-compiler`），展开成宿主 session 的 inline 表。`make-session` 在目标端用它初始化，包列表用 `list-all-packages`。
- `lower.lisp` 取浮点数的位模式：宿主用 `sb-kernel`，目标端用新的 primop `:single-float-bits`、`:double-float-high-bits`、`:double-float-low-bits`。

### 8.2 两边一致需要的修正

- **标签不依赖 gensym 计数器**：名字是 gensym 的局部函数，标签里去掉数字（`local-function-label-name`），由 `fresh-label` 的计数保证唯一。
- **包名**：符号的标签和包名字符串原来用宿主包名，测试程序的符号因此带 KILN-USER。现在统一用 `target-package-name`，即 COMMON-LISP-USER。
- **运行期的 CL-USER**：原来没有 CL-USER 这个昵称，也不 use KILN.SYS。宿主为测试程序描述的包有这两样，载入第一个测试模块后运行期也就有了。现在 CLOS 模块一开始就按这个描述建 CL-USER。
- **`defvar` 的位置**：`lower.lisp` 在 `*regions*` 的 `defvar` 之前就绑定了它，SBCL 把那个 `let` 编成了词法绑定；`*primops*` 定义在后面的 `primitives.lisp`。Common-boot 遇到未宣告的自由变量会报错，两处都挪到了前面。

还不确定的地方：字面数据里的未 intern 符号，名字里带 gensym 的计数，标签和名字字符串都会不同。现在的输入没有这样的数据。

### 8.3 还没做

- 不在顶层的 `macrolet`：Common-boot 从 AST 编译局部宏的展开函数（`compile-local-macro-function-ast`），Maclina 要的是形式。目标端现在直接报错。
- `defstruct`：Anatomicl 不在目标端，运行期也没有 `defstruct` 宏。session 里的结构布局也没有传给目标端。
- `defclass` 的访问函数在两边都被报成未定义函数（`cmd:defclass-compile-time-action` 拿不到槽）。

### 8.4 M5.4 要做的

- 在 kiln 上编译 kiln 全部源码（kernel、CLOS、frontend、eval、compiler），和 SBCL 的 KIR 比对。kernel 和 CLOS 要求宿主宏、`:compile-time-too` 文件项、包改名在目标端也有对应的做法。
- 前端在 kiln 上的速度决定 M5.4 是否可行（§3）。

