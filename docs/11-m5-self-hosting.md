# 11 M5：编译器在 kiln 上运行，自举

**状态**：
- M5.1 完成（2026-11，§5）：目标端有了运行期的标准宏、`eval`、`compile`、`load` 和 REPL。
- M5.2 完成（2026-11，§7）：Common-boot 和它的依赖编成 compiler 模块，kiln 上 `cst-to-ast` 的结果和 SBCL 逐字相同。
- M5.3 完成（2026-11，§8）：kiln 自己的前端和 `lower.lisp` 也编进 compiler 模块，kiln 上编出的 KIR 和 SBCL 的逐字相同。
- M5.4 完成（2026-11，§9、§10）：kiln 交叉编译自己的五个模块（kernel、CLOS、frontend、eval、compiler），KIR 和 SBCL 的逐字相同（`tests/m5/co-kernel`，17 秒；`co-clos`、`co-frontend`、`co-eval`、`co-compiler`，各约 7–15 分钟，慢测试）。
  自举闭合（§10）：kiln0（SBCL 编出的 KIR 链接成的 AOT 可执行文件）编出的 stage1 和 SBCL 的 stage0 逐字节相同，kiln1 编出的 stage2 和 stage1 相同，kiln0 和 kiln1 两个可执行文件也逐字节相同（`tools/bootstrap.sh`，约 30 分钟）；测试程序改由 kiln1 编译，`tools/test.sh` 全部通过（§10.1）。
- M5.5 完成（2026-11，§11）：`compile` 把 lambda 表达式编成原生代码，装进运行中的 image（`tests/m5/co-native`）。

## 1. 目标和验证

- kiln0 是 SBCL 交叉编译出的 kiln。M5 要让同一个编译器（Common-boot 前端加 `lisp/*.lisp` 的中后端）在 kiln0 上运行，编译 kiln 自己的源码，产出 KIR。
- 验证分两步：
  1. kiln0 上编译出的 KIR 和 SBCL 上编译出的 KIR 逐字一致（kiln0 → kiln1）；
  2. kiln1 编出的 kiln2，其 KIR 和 kiln1 的一致。
- 两步都要求 KIR 输出是**确定的**：不依赖哈希表的遍历顺序，也不依赖 gensym 计数器在编译之外的状态。现在 SBCL 上是否已经确定，要在 M5.3 之前检查一遍：同一份源码编两遍，比较输出。
- KIR 到机器码这一步仍由 Rust 的 kiln-cg 完成（AOT 或 JIT）。M5 不要求 kiln-cg 进 image，那是 M5.5（§11）。

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
| M5.4 ✅ | kiln0 编译全部 kiln 源码（kernel、CLOS、前端、编译器各模块），kiln-cg AOT 链接成 kiln1；kiln1 再编出 kiln2 | kiln0 和 kiln1 产出的 KIR 一致；kiln1 和 kiln2 的一致；`tools/test.sh` 在 kiln1 上通过 |
| M5.5 ✅ | 原生 `compile`（§11）：kiln-cg 作为库链进 kiln-rt，`compile` → KIR → 进程内 JIT，代码登记进运行中的 image；s-expression-syntax 等的 `compile` 改走这条路径 | `compile` 出的函数和 AOT 的结果一致；编译时间 |

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
- 全局符号宏（`define-symbol-macro`）：运行期环境的描述（eval 模块的 Maclina client）只有常量和特殊变量，没有全局符号宏，所以目标端的编译器看不到它们。
- inline 表是宿主编完 compiler 模块那一刻的快照。宿主在同一会话里后来编译的文件（比如别的测试）再定义 inline 函数，目标端不知道。`co-compile-input` 用自己的包，不受影响。
- Common-boot 里 `cmd:` 前缀的符号仍按宿主的 COMMON-MACRO-DEFINITIONS 读入：`:renames` 只作用于 `in-package` 和 `defpackage`。所以运行期 `common-macro-definitions:macroexpand-1` 等没有定义。目标端的 client 不走这条路径（`convert-with-ordinary-macro-p` 为假），现在没有影响。

### 8.4 M5.4 要做的

- 在 kiln 上编译 kiln 全部源码（kernel、CLOS、frontend、eval、compiler），和 SBCL 的 KIR 比对。kernel 和 CLOS 要求宿主宏、`:compile-time-too` 文件项、包改名在目标端也有对应的做法。
- 前端在 kiln 上的速度决定 M5.4 是否可行（§3）。

## 9. M5.4：kiln 编译 kiln

### 9.1 交叉编译模式

M5.3 的 client 在运行中的 image 里编译。这对用户程序是对的，但编译 kiln 自己不行：
- kernel 定义了早期的 `assert`、`define-condition`，CLOS 模块在编译期求值 Clostrophilia 的函数，这些都会改掉正在运行编译器的 image；
- SBCL 的会话从一个空的编译期环境开始，依次编译各模块，两边的起点必须一样。

所以 kiln 也用宿主那套交叉编译：`lisp/host.lisp` 改成两边共用的 `lisp/cross.lisp`（`cross-client`），M5.3 的 client 改名 `image-client`。`make-session` 的 `:client-class` 选择用哪个；宿主默认 `cross-client`，kiln 上默认 `image-client`。

在 kiln 上，`cross-client` 的「宿主」就是 kiln 自己：
- 编译期环境是 Clostrum 环境，编译期求值用 Common-boot 的 HIR 求值器。它的三个系统（HIR、AST-to-HIR、HIR-evaluator）也编进了 compiler 模块。
- 导入的函数和宿主宏是 image 里的：LOOP 是 image 的 Khazern，反引号是 Eclector 的。
- 标准宏用 Common-macros 的定义。eval 模块载入 Common-macros 之后、换回 kiln 自己的宏之前，把它们存在 `kiln.kernel::*common-macros*`；宿主则取 `cmd:macro-function`。

### 9.2 修正

- **Common-macros 的 `macroexpand-1` 丢掉了环境**（上游 bug）。宿主的编译期环境里本来没有 Common-macros 的宏：`cb:create-environment` 用错了名字去找，所以标准宏都经 `cmd:macroexpand-1` 展开，局部宏和符号宏对它们不可见。例如 `(setf (m) x)`，`m` 是 `macrolet` 定义的局部宏，结果被编成对 `(setf m)` 的调用。
  - 现在 vendor 补丁把环境传给展开函数（vendor/README.md），宿主的编译期环境也直接放进这些宏。
  - HIR 求值器的 `make-thunk` 就有这样的 `setf`。
  - 回归测试 `tests/m5/local-macro-places`。
- `fboundp` 对 `(setf t)`、`(setf nil)` 报类型错误，现在返回假。
- 模块的额外符号和新定义包的外部符号按名字排序后输出，因为包里符号的遍历顺序因 image 而异。

### 9.3 kiln 上编译器的速度

kernel 的交叉编译一开始跑了一个多小时也没结束。测量工具：
- perf：`kernel.perf_event_paranoid` 为 2 时，只有软件事件（`-e cpu-clock`）能用。默认的 `cycles` 事件也计内核态，`-g` 要内核调用链，所以都被拒绝。设为 1 后，硬件事件和 `-g` 都能用；kiln 的 AOT 代码有帧指针，`perf report --children` 能给出包含时间。
- kiln-cg 的 JIT 设了 `KILN_PERF_MAP=1` 时，写出 `/tmp/perf-PID.map`，perf 能显示 JIT 函数的名字。
- AOT 程序有帧指针，gdb 能回溯。每次 attach 一次 gdb 抽一个调用栈；在同一次 gdb 会话里连续抽样时，进程一直停着，得到的其实是同一个瞬间。
- 很多函数的标签里没有名字：`block` 没有 `return-from` 时在简化阶段被删掉了。从 KIR 里「把哪个函数对象存进哪个符号」可以得到对应关系。

改动和效果（`co-compile` 的 AOT 程序从 12 秒到 2.3 秒；kernel 从超过一小时到 38 秒）：

1. **CLOS 分派没命中时重建判别函数**：Clostrophilia 每次没命中，都把整个调用历史重新加进一个新的自动机，而 `add-path` 每加一条路径还要线性查找转移。`walk-ast-node` 的调用历史有 1500 项，一次编译要加 170 万条路径，总代价是 N³。
   - 现在没命中时，如果调用历史里已有这组类，就直接调用它的有效方法；没命中的次数达到上次构建时历史长度的四分之一才重建（vendor/README.md）。
   - 这一组类在调用历史里的查找按 `eq` 比较。原来用的 `equal`，比较 instance 时要走 `typep`。
2. **parser.packrat 的 `parse` 靠 compiler macro 在编译期编译常量表达式**。kiln 不用 compiler macro，于是 s-expression-syntax 的 `classify` 每转换一个形式，都要在运行期重新解析一遍表达式，再用 Maclina 编译。
   - 现在宿主库（`use-host-macros` 的那些包）的宿主 compiler macro 也用于为目标编译的代码（`client-compiler-macro`）。展开结果照样经过反引号改写和 `check-host-expansion`；不合格的，当作 compiler macro 放弃展开。
3. **输出**：kiln 的文件流没有缓冲，每个字节都要分配一个向量、做一次 `write` 系统调用。
   - 没有加缓冲：runtime 的 `print` 直接写 fd 1，Lisp 这边一缓冲，两边的输出顺序就会乱。
   - 改为 POSIX 文件流的 `stream-write-string` 一次编码整个字符串，只写一次。
   - KIR 打印器先在字符串里拼好每个顶层形式，再一次写出。
4. **kernel 的序列函数**：
   - `member`、`assoc`、`find`、`position` 在 test 是 `eq`/`eql`、又没有 key 时，直接循环比较；
   - 列表上的 `find`/`position` 不再先复制一份列表；
   - Regalia 判断数组种类（`stringp`、`length` 对每个 instance 都要问）改用 stamp 查向量，原来是扫一张 30 项的 alist。

还没处理的开销：parser.packrat 的 inline cache 和 s-expression-syntax 的解析器，仍然是载入时或首次使用时用 Maclina 编成字节码（`compile-parser`）。在整个编译里，它们的执行占了相当一部分时间。

### 9.4 kiln 编 CLOS 模块

`tests/m5/co-clos`：同一个交叉编译会话里先编 kernel，再编 CLOS（约 150 个文件），输出的 CLOS 模块和 SBCL 编出的逐字节相同。
- 文件列表由宿主宏 `kiln.compiler::module-files` 在编译测试时给出。
- 这个测试很慢（约 8 分钟，要 2 GiB 堆），有 `co-clos.slow`，只在命令行点名时才跑，只跑 JIT 一遍（`tools/test.sh tests/m5/co-clos.lisp`）。

宿主特有的部分在 kiln 上的对应：
- **`defstruct`**：Anatomicl 和 `lisp/structures.lisp` 编进 compiler 模块，kiln 上的交叉编译同样用它展开。
- **Common-macros 的包**：kiln 上 Common-macros 是 eval 模块的 `KILN.CMD`，宿主上是 `COMMON-MACRO-DEFINITIONS`。
  - kiln 上交叉编译时，这些宏展开结果里新出现的 `KILN.CMD` 符号换成 `COMMON-MACRO-DEFINITIONS` 的同名符号（如 `check-type` 展开出的 `check-type-error`），被展开的形式里原有的保留。
  - 它们的内部宏（`with-store-value-restart`）也以宿主的名字放进编译期环境。宿主上这些宏是退回到宿主定义上展开的，kiln 上没有这条退路，所以要显式放进去。
- **`closer-mop-aliases`**：kiln image 里也有 CLOSER-MOP 包（CLOS 模块建的），原样可用。
- **宿主库的 compiler macro**：CLOS 模块用不到。

修正：
- **`defpackage` 处理过的包都算本模块的包**：原来只有宿主里原本没有的包才算（才输出全部外部符号）。SBCL 上 Eclector、Khazern、Alexandria 已经存在，kiln 上所有包都已存在，两边结果就不一样了。
- **反引号的共享结构**：Eclector 把 `` `(a ,@x) `` 展开成 `(append (list 'a) x 'nil)`，会复制 `x`；SBCL 的反引号则共用 `x`。
  - 宿主上的宏展开函数（如 Ecclesia 的）是 SBCL 编的，kiln 上的是 kiln 从 Eclector 的展开编的。于是 `` `(:allow-other-keys ,@keywords) `` 和 `keywords` 在 SBCL 上共用尾部，合成一个常量，在 kiln 上是两个。
  - 现在 Eclector 也把最后的 `,@x` 直接当作尾部（vendor/README.md），CLHS 2.4.6 允许这样做。
- **无名符号**：模块常量里的无名符号（如宏展开留下的 `#:G123`）以前按名字取标签，名字里沿用宿主当时的计数器。现在照 SBCL 的做法：
  - 前端处理每个顶层形式时，把 `*gensym-counter*` 绑定为 0，和 SBCL 的 `compile-file` 一样。
  - `compile-module` 按无名符号在模块里第一次出现的顺序给它们编号，标签用这个序号和模块名，不用名字。这相当于 SBCL fasl 按对象本身保存无名符号：同名的两个仍是两个符号，不同模块的也不会合并。
  - 名字以数字结尾的（gensym）改用这个序号作结尾。宿主自己也会调用 `gensym`（SBCL 的 PCL 在运行期为分派生成代码时就会），同一个形式里的编号两边可能错开。代价是源码里写的 `#:x1` 这类名字也会被改掉，只影响打印。
- `butlast` 对点结尾列表（Ecclesia 解析 `(a b . body)`）报错。
- `call-arguments-limit` 原来是 67（3 个寄存器参数加 64 字的传递区）。Trinsic 的宏在编译期 `apply` 了更多参数，现在是 1024（docs/06 §5）。
- Lisp 程序在一个栈为 64 MiB 的线程上运行（docs/07 §10）：HIR 求值器给长指令链建 thunk 时递归约 3500 层，超出了主线程的 8 MiB。
- kiln-cg 的 JIT 把代码和数据放进同一块 2 GiB 的预留区：模块变大后，malloc 来的几块内存可能相距超过 2 GB，32 位 PC 相对重定位溢出。
- 调试：`kiln.compiler::*trace-toplevel*` 为真时，前端把每个文件和每个顶层形式的开头打印到 `*error-output*`。

速度（perf 采样，`perf report --children`）：
- Iconoclast 的 AST 遍历器用 `reinitialize-instance` 设置一个槽，约占 40% 的时间。
  - Clostrophilia 的 `shared-initialize-aux` 对每个槽都先调 `slot-boundp-using-class` 和 `slot-definition-initfunction`，然后才看 `slot-names`。现在先看 `slot-names`，它在这里是 NIL，这两次泛函调用就省掉了（vendor/README.md）。
  - 它每次还要 `(intern name (find-package "KEYWORD"))`：按名字查包时 `equal` 哈希表里的 `string=` 逐个字符调用 `char=` 和 `schar`。现在 `string=` 用 primop 比较字符。
- 剩下的大头是泛函分派本身：判别函数解释自动机，每层二分查找；Iconoclast 和 builder 协议的泛函调用非常密集。
- kernel 交叉编译从 38 秒降到 35 秒（AOT），CLOS 约 16 分钟（JIT）。

之后又做了一轮（和 SBCL 的对比：SBCL 编 kernel 1.8 秒、编 CLOS 25.6 秒；微基准里 `fib` 和分配持平，泛函调用约慢 4 倍，`equal` 哈希表约慢 28 倍）：
- **哈希表**：分桶表把查找要用的数据放在一个简单向量里，按固定位置从实例读出，eq、eql、equal 内联比较；`cl:gethash`、`(setf gethash)`、`remhash` 遇到分桶表时直接调用它的函数，不经过泛函。微基准 642 → 190 ms（SBCL 23 ms）。
- **分派**：只按一个或两个展开参数分派、没有 EQL 特化的泛函，判别闭包记住上一次调用的 stamp 和有效方法，命中时不走自动机。泛函调用微基准 211 → 95 ms（SBCL 50 ms）。
- **按名字读槽**（`%slot`，`class-typep` 和 `call-next-method` 每次都用）：按槽列表和名字缓存位置；`:identity-hash` 在对象头里已有哈希时内联读出，不调用运行时。
- **GC**：MMTk 的 debug assertions 检查每次 side metadata 访问，GC 占了约三分之一的时间，dev 构建里对 mmtk 关掉；默认堆从 256 MiB 改为 1 GiB。
- 结果：kernel 交叉编译 35 → 17 秒（AOT，SBCL 1.8 秒）；kernel 加 CLOS 约 16 → 7.7 分钟（JIT，SBCL 约 27 秒）。

### 9.5 kiln 编 frontend、eval、compiler 模块

测试：`tests/m5/co-frontend`、`co-eval`、`co-compiler`（都是慢测试，按 SBCL 的顺序在同一个会话里先编前面的模块，只打印最后一个）。compiler 模块编译前的准备（宿主宏、`defrule` 和 `define-syntax` 只在加载时定义、`host-inline-functions`）是 `cross.lisp` 的 `prepare-compiler-session`，SBCL 和 kiln 共用。

frontend 模块不需要改动。其余的不一致和错误，大多是“在 SBCL 上碰巧没事”：

- **包局部昵称**：模块的 symbol 表原来不记局部昵称，kiln 上 `KILN.CMD` 没有 `ECC`，读不了 Common-macros 的源码。现在表里记下指向运行期存在的包的局部昵称，加载时登记（docs/10 §12）。
- **import 的 symbol**：parser.packrat 从 trivial-with-current-source-form import 的宏，SBCL 编译时已经展开掉，模块里不再引用，于是 kiln 上的包没有这个 import，读源码时另建了一个同名 symbol。现在模块的包从运行期存在的包 import 的 symbol 也记在表里。
- **`string=` 等**：kernel 的字符串比较不接受 `:start1` 等关键字（`check-host-expansion` 用了 `:end2`），`string>`、`string<=` 返回的下标也不对。补全了整组，包括不区分大小写的函数和 `char-lessp` 等。
- **parser.packrat 的自举解析器**：它的 ASDF 定义在加载完之后把 `*bootstrapping*` 设为 NIL，之后表达式由元语法解析；compiler 模块只编了源文件，kiln 上一直用自举解析器（`(? x)` 成了 `(* x nil 1)`，`(<- (a b) ...)` 不解构）。现在 compiler 模块在 parser.packrat 之后做同样的设置（`lisp/target/compiler/parser-packrat.lisp`）。
- **共享结构**：KIR 的常量反映宿主里哪些 cons 是同一个，而这在两边不同：
  - 宿主宏的展开在 SBCL 上经 `translate-host-backquote` 复制，在 kiln 上原来不复制，展开函数的字面量在不同展开之间共享。现在两边都复制。
  - SBCL 的反引号把模板里没有 unquote 的子表和尾部当作字面量，Eclector 的逐个重建。现在 Eclector 也这样做（vendor/README.md）。
  - SBCL 的 `compile-file` 合并相似的常量（`(value object)` 的尾部和 `(object)` 是同一个 cons）。现在 KIR 的 cons 常量按 car 和 cdr 合并（`constant-word`），宿主碰巧共享了哪些 cons 不再影响 KIR。
- **`%uses?`**：parser.packrat 生成规则时用 `macroexpand-all` 判断代码是否用到 `:fail`、`:fatal`、`position`；kiln 上原来的近似（名字出现就算）多生成了函数。现在 kiln 上用 `compile`（Maclina）展开，结果和 SBCL 相同。
- **Maclina**：vendor 进来并修了两处（vendor/README.md）：VM 的 `throw` 不带值，被原生代码的 `catch` 接住时得到 NIL；字节码函数被非局部退出跳出时不拆帧，VM 的寄存器停在被调函数的帧里。

速度和内存：
- compiler 模块在 2 GiB 堆（SemiSpace，可用一半）下跑了 51 分钟后内存不足：存活数据接近半堆时几乎一直在 GC。`co-compiler` 用 8 GiB 堆。GC 线程从 2 个改为 CPU 核数（最多 8 个）后，五个模块在 kiln 上一共约 40 分钟（co-clos 约 7 分钟、co-compiler 约 15 分钟）。
- 分配快路径原来假定 bump 分配器（SemiSpace），换成 Immix 会崩溃；现在按 plan 取默认分配器的 bump pointer（docs/07 §2）。

### 9.6 接下来

见 §10。

## 10. 自举：kiln0 → kiln1 → kiln2

`tools/bootstrap.sh` 做完整的自举，结果在 `build/boot/`：

| 阶段 | 做什么 | 结果 |
|---|---|---|
| stage0 | SBCL 在一个会话里编五个模块和构建程序（`kiln:bootstrap-stage0`），写出 `NAME.kir` 和清单 `modules.lisp-expr` | 约 70 秒 |
| kiln0 | stage0 的六个 KIR 用 `kiln-cg obj` 编成一个目标文件，和 launcher 链接成 AOT 可执行文件 | `kiln-cg` 约 15 秒，峰值内存约 9.5 GB；可执行文件约 120 MB；启动（各模块的顶层初始化）约 0.65 秒 |
| stage1 | 在一个目录里运行 kiln0：读清单，依次编五个模块和构建程序自己 | 约 14.5 分钟，峰值 RSS 约 9 GB（8 GiB 堆）；六个 KIR 和 stage0 逐字节相同 |
| kiln1 | stage1 的 KIR 链接成可执行文件 | 和 kiln0 逐字节相同 |
| stage2 | 运行 kiln1 | 和 stage1 逐字节相同 |

构建程序 `lisp/target/build.lisp` 是一个普通的程序模块（名字是 `build`），在 kiln 上的做法和 `tests/m5/co-compiler` 一样：一个交叉编译会话，kernel 带上 CL 的全部外部符号，编 compiler 模块之前调用 `prepare-compiler-session`，按 `muffle-warning` 处理警告。它不依赖 SBCL 才有的东西：
- **文件列表**：放在清单里，而不是 `module-files` 宏（那是 SBCL 会话里的宿主宏，展开时要用 ASDF）。清单由 stage0 写出：每个模块的名字和源文件，格式就是 `front-end` 接受的格式（路径是 namestring，`:renames`、`:compile-time-too` 原样保留）。作用类似 SBCL 的 `build-order.lisp-expr`。
- **输出**：写到当前目录的 `NAME.kir`。
- 构建程序自己也在 stage0 里由 SBCL 编译（模块名 `build`，在 compiler 模块之后，用同一个会话），所以 stage1 也包含它；kiln1 完全由 kiln 编出。

修正：kiln-cg 原来对同样的 KIR 生成的机器码不完全相同。函数里 landing block（`try_call` 的异常入口）按哈希表的遍历顺序填充，SSA 值的编号和寄存器分配因此每次不同。现在按创建顺序填充，kiln-cg 的输出只取决于 KIR。

### 10.1 测试程序由 kiln 编译

`KILN_COMPILER=build/boot/kiln1 tools/test.sh` 让 kiln 编译测试：SBCL 只写清单（`kiln:write-manifest`：五个模块，测试文件作为程序模块排在后面），kiln 运行构建程序，在一个会话里编完五个模块再编各个测试。会话的顺序和 SBCL 模式一样。之后照常走 JIT、GC 压力、AOT 三遍。快速测试全部通过（约 25 分钟，其中约 15 分钟是编五个模块）。这样 M5.4 计划表里的验证就都完成了。

`tests/m5/co-*` 用到的 `kiln.compiler::module-files` 在 SBCL 里是 `compile-compiler` 注册的宿主宏。构建程序在编 compiler 模块之前也注册同名的宿主宏，展开成清单里的文件列表。

### 10.2 自举的速度

用 `perf` 剖析了一次完整的阶段（kiln1 编五个模块，845 秒）。按模块统计自身时间：

| 部分 | 占比 |
|---|---|
| clos 模块（分派、slot 访问、实例初始化、哈希表） | 约 45% |
| kernel 模块（`member`、`typep`、`logand` 等） | 约 27% |
| GC（MMTk 工作线程） | 约 17% |
| compiler 模块自己的代码 | 约 3% |
| Maclina 的字节码 VM | 约 1%（包含时间 14%，几乎都是它调用的原生函数：parser.packrat 的规则） |

所以换成原生 `compile`（M5.5）几乎不会让自举变快：字节码只是一层很薄的胶水。

改动（`tools/stage0-kiln.sh` 只做 stage0 和 kiln0，用来试改动）：

| 改动 | 说明 |
|---|---|
| `if` 的测试直接分支 | 谓词原语的 `(:select c T NIL)` 不再先物化、再和 NIL 比较，而是直接按 `c` 分支；`and`、`or`（`(let ((g x)) (if g g y))`）、`not`、嵌套的 `if`、常量在测试位置也都展开成分支（`lower-branch`） |
| 闭包变量用到时再读 | Common-boot 的闭包转换在函数入口读出全部捕获变量，它们跨调用存活，都被溢出到栈上。闭包环境不可变（被赋值的变量在 cell 里），现在每次引用时从函数对象读 |
| Iconoclast 的 `set-slot` | AST walker 对每个节点的每个槽，都 `intern` 一次关键字，再调用 `reinitialize-instance`（两个 `&rest` 泛函，加上 `shared-initialize`）。这占了全部时间的三分之一。现在按（类，reader）缓存槽名，直接 `(setf slot-value)`（vendor/README.md） |
| `shared-initialize` 的计划、类名 `typep` 的调用点缓存 | docs/10 §27 |
| `member`、`assoc` | 不带关键字，或 `:test` 是 `#'eq`、`#'eql` 时，调用两个参数的 `%member-eql` 等，不再解析关键字参数 |
| `logand`、`logior`、`logxor` | 原来不是原语，每次调用都是 `&rest` 函数；现在 fixnum 内联，其他走 `two-arg-*` |

结果：一个阶段从 845 秒降到 525 秒（−38%），其中 CLOS 模块从约 268 秒降到约 148 秒。完整自举从约 30 分钟降到约 19 分钟。

第二轮（重新 profile 后）：

| 改动 | 说明 |
|---|---|
| 判别闭包的缓存表 | 按一个、两个参数分派的泛函，以及只按一个参数分派的 `&optional`/`&rest`/`&key` 泛函，用直接映射的缓存表，未命中的路径放在单独的函数里（docs/10 §27） |
| `slot-value`、类名 `typep` 的全局缓存 | docs/10 §27 |
| 名字不用 `format` 生成 | 每个 KIR 变量、块和标签的名字都调用一次 `(format nil "~A~D" ...)`。kiln 上 `format` 每次都要解释控制字符串，再逐字符写进字符串流，占了约 18%。现在用 `kir-name` 直接拼接 |
| 文件流批量写入 | `stream-write-octets` 原来对每个八位组调用一次泛函 `stream-write-octet`（每次又要调用几个槽访问器泛函），现在按块拷进缓冲区 |

结果：一个阶段 321 秒（最初 845 秒，−62%）。各模块依次是 kernel 7 秒、CLOS 88 秒、frontend 3 秒、eval 28 秒、compiler 193 秒。完整自举约 12 分钟。SBCL 编同样的五个模块约 50 秒，现在 kiln 慢 6 倍左右（最初是 11 倍）。

试过 Immix（`MMTK_PLAN=Immix`）：比 SemiSpace 慢约 5%。

### 10.3 接下来

和 SBCL 的逐项对比，以及差距的原因，见 [14](14-performance.md)。

- 剩下的热点（CLOS 阶段）：GC 约 13%；kernel 的函数约 21%，比较分散；Salmagundi 哈希表约 5%；`append` 方法组合（Iconoclast 的 `slot-designators`，walker 每访问一个节点调用一次）约 5%；`&rest` 泛函每次调用分配参数列表。
- 分代 GC 或 Immix 的大堆配置。
- 模块之间可以先存快照（docs/13 §1），后面的阶段从快照开始。kiln 模式的测试也能从“五个模块编完”的快照开始，不必每次重编模块。

## 11. M5.5：原生 `compile`

`compile` 给 lambda 表达式生成机器码，直接装进正在运行的 image。kiln-cg 作为库进入 `libkiln_launcher.a`，运行期的入口是 `kiln_rt_jit`。只有引用了它的程序，也就是含 compiler 模块的程序，链接时才带进 Cranelift，其他程序的大小不变。

### 11.1 路径

1. kernel 的 `compile`（eval 模块，`lisp/target/eval/evaluator.lisp`）通过 `kiln.kernel::*compile-function*` 编译 lambda 表达式。这个变量为 NIL 时用 Maclina 的字节码。compiler 模块的最后一个文件 `lisp/target/compiler/native.lisp` 把它设成 `native-compile`，所以从那以后的 `compile` 都编成原生代码。compiler 模块自己载入时（s-expression-syntax 的解析器）仍是字节码。
2. `native-compile` 新建一个 session（`image-client`），然后：
   - 用 `front-end-forms` 处理 `(setq *compiled-function* (function LAMBDA))`。`front-end-forms` 和 `front-end` 一样，只是直接处理形式，不读文件。
   - 用 `compile-module :image t` 降级。
   - 用 `module-string` 把 KIR 写成一个字符串。
   - 把字符串和字面量向量交给 `(%primop :jit text literals)`。
3. `kiln_rt_jit`（`rust/kiln-cg/src/jit.rs`）依次：
   - 解析 KIR，用 Cranelift 编进内存；
   - 登记调用点、栈图、static root；
   - 把字面量向量的元素写进模块的字面量字；
   - 返回 init 函数对象，此时还没调用。

   KIR 编不过时，它打印原因并返回 NIL，`native-compile` 据此报错。
4. `native-compile` 先动态绑定 `*compiled-function*`，再调用 init 函数，取出编好的函数。

### 11.2 image 模式的 KIR

编进运行中 image 的代码，引用的是 image 里已有的对象。和编译文件（`compile-file`，以及交叉编译的模块）相比，有三点不同：

- **字面量**：
  - 除立即数（fixnum、字符、单精度浮点、NIL、T）以外，字面量一律占用模块数据 `kiln_literals` 的一个字。每个字都是 static root，数据字写成 `(:literal i)`，操作数是 `(load (addr "kiln_literals") 8i)`。
  - 字面量保持同一性：`compile` 不复制字面量（CLHS 3.2.4），未 intern 的符号、列表都还是原来那个对象。
  - 符号也走这条路：运行期 intern 的符号在堆里，GC 会移动它们，不能把地址编进代码。代价是全局函数调用和特殊变量的访问各多一次 load。
- **没有符号表**：符号都已经在 image 里，init 函数不调用 `%register-module-symbols`。
- **共享的定义用 image 的**：
  - 未定义函数的入口（`kiln_undefined_function` 等）和 funcallable instance 的 trampoline 要和函数槽里的值比较（`fboundp`、`emit-error`），所以必须是 image 里的那一份。
  - image 模式把它们写成 `import-data`。kiln-cg 链接时按名字解析：每个模块导出 `kiln_rt::EXPORTED_NAMES` 中它定义的那些名字，kiln-rt 记下地址。
  - `kiln_module_info` 因此改为 88 字节，最后两个字段是 `exports`（`[C 字符串名字, 地址]` 对的数组）和 `nexports`。

### 11.3 内存和登记

- 运行期编出的模块共用一块预留的 16 GiB 地址空间：只预留，用到时才提交，从低往高分配，从不释放。代码目前不回收。
- 调用点表、栈图表、static root 表都按地址排序。新模块的地址在已有模块之上时，登记只需追加。原来每次都把整张表（image 的几十万项）重排一遍，一次登记要 1.2 ms。
- kiln-cg 处理小模块时不再开线程，ISA 也只建一次。

### 11.4 速度

在 AOT 可执行文件里测量，单位是每次的毫秒数：

| | 原生 | Maclina |
|---|---|---|
| 编译 `(lambda (x) (* x x))` | 3.4 | 0.12 |
| 编译一个带 `loop` 的 lambda | 约 20 | 1.2 |
| 运行一百万次迭代的 `dotimes` | 2.2 | 1250 |

编译 `(lambda (x) (* x x))` 的 3.4 ms 中，前端 1.9 ms，降级 0.4 ms，打印 KIR 0.2 ms，kiln-cg 0.7 ms，新建 session 0.2 ms。原来 KIR 用字符串输出流逐字符写，光打印就要 15 ms；现在整个模块写进一个缓冲区（`module-string`）。

所以 `eval` 仍用 Maclina：对只运行一次的代码，编译时间占主导。由于同样的原因，有两处只为展开宏或只运行几次而调用 `compile` 的地方，固定用 Maclina（把 `*compile-function*` 绑成 NIL，vendor/README.md）：
- Common-boot 的 HIR 求值器：交叉编译时，每个宏的展开函数都要求值，求值器为每个函数编一个参数解析器。编 kernel 和 CLOS 时要编约 800 个，改成原生编译后，一个自举阶段从 321 秒变成 357 秒。
- parser.packrat 的 `%uses?`：借编译来展开宏。原生编译器还不支持不在顶层的 `macrolet`，编译出错后退回保守的判断，结果和 SBCL 不同，自举因此不闭合。

改了这两处后，自举的速度和以前相同，仍然闭合。

### 11.5 还没做

- 代码回收：函数对象不再被引用后，代码和它的表也不会释放。
- `compile` 的前端开销：每次都新建 session，复制宿主 inline 表。
- 不在顶层的 `macrolet`（§8.3）：image-client 还不能编译局部宏的展开函数，含有它的 lambda 表达式 `compile` 时会报错。Maclina 能编译，所以 parser.packrat 的 `%uses?` 仍用 Maclina（§11.4）。
- `compile-file` 和 FASL：现在只有 `compile`。
