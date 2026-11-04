# 11 M5：编译器在 kiln 上运行，自举

**状态**：计划（2026-11）。

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

**closer-mop**：它对每种实现有条件读入的分支，已有 `sicl` 和 `mezzano` 的分支。kiln 的 MOP 来自 Clostrophilia，大概能走 `sicl` 分支，或者加一个 `kiln` 分支：closer-mop 的包直接重新导出 Clostrophilia 的符号。需要 vendor。

## 3. 分步计划

| 步骤 | 内容 | 验证 |
|---|---|---|
| M5.1 | 目标端 Maclina：closer-mop（kiln 分支）、Ecclesia、Trucler、Clostrum 和 Maclina 编成 `eval` 模块；`eval`、`compile`（字节码）、`load` 源文件；最简 REPL | 测试里对字节码函数 `funcall`、和原生函数互相调用、`load` 一个源文件；不读文件时 REPL 能读入并求值 |
| M5.2 | 前端的其余依赖编成目标端模块：alexandria、let-plus、anaphora、more-conditions、print-items、builder-protocol、parser.packrat、s-expression-syntax、Iconoclast、Common-macros、Common-boot | 在 kiln 上 `cst-to-ast` 一个形式，打印 AST 的类和结构，和 SBCL 比对 |
| M5.3 | kiln 的 `lisp/*.lisp` 编进目标端；在 kiln 上把一个测试文件编成 KIR | 和 SBCL 产出的 KIR 逐字一致；先查 KIR 输出是否确定（§1） |
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
