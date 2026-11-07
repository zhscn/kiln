# SICL 现状调研

**调研日期**：2026-11-03
**依据**：SICL 主仓库 <https://github.com/robert-strandh/SICL>（HEAD fce5770d4，2026-08-30），以及 s-expressionists、robert-strandh 等组织下的各模块仓库（各模块的提交日期见 6.2）。
**用途**：记录 SICL 的最新设计和实际代码进度，供后续会话直接引用，不必重新调研。本文不随 kiln 的代码更新；若 SICL 有大的更新，按文末“如何更新本文”重新核对。

文中的路径：`S/` 指 SICL 仓库根目录，`D/<模块>/` 指该模块仓库的根目录（例如 `D/Common-boot/` 是 Common-boot 仓库）。**规范**指 `S/Specification/` 里的文字，**代码**指实际存在并在用的代码。两者经常不一致：规范里有大段过时内容，以代码和 git log 为准。

---

## 1. 总体结论

1. **SICL 至今没有原生后端，也不产出 image。** 当前的全部成果是：在 SBCL 宿主里构建出一个自洽的 Clostrum 环境 E4，所有目标代码由 Common-boot 的 HIR 求值器以宿主闭包的形式执行。原生后端（`S/Code/Compiler/HIR-to-MIR`、`MIR-to-LIR`、`Code-generation`）自 2022 年起没有改动，依赖的系统已被删除，已经无法加载。
2. **前端和中端已经拆到 SICL 之外。** 现在的流水线是 Eclector → CST → Common-boot `cst-to-ast` → Iconoclast AST → Common-boot `ast-to-hir`。Cleavir 的 cst-to-ast、AST、HIR 都已删除。`S/Code/Cleavir/` 里还剩数据流分析、SSA、寄存器分配等 186 个文件，没有任何在用的代码路径引用它们。
3. **对 kiln 的意义**：SICL 生态里真正可用的是前端（读入到简化后的 AST）、标准库模块和 CLOS。从 HIR 往下的部分没有可以复用的实现，只有设计文字可以参考。kiln 的“前端复用、后端自研”定位没有变化，而且 SICL 的进度说明不能指望它在后端方向提供帮助。

---

## 2. 自举（New-boot）

### 2.1 现状

- **在用的是 `S/Code/New-boot`。** 它从 2023-09 开始写，2026 年仍在活跃开发。入口：`(asdf:load-system :sicl-new-boot)`，然后 `(boot)` 和 `(repl4)`（`S/README.md:79-103`）。
- **旧的 `S/Code/Boot` 已经废弃**，2026-08 正在逐个文件删除。
- **规范里的自举章节大部分已过时。** `chap-bootstrapping.tex` 从第 718 行起描述的是旧流程（E0、E5、E6、phase 5–10），138–172 行仍然提到 `cleavir-cst-to-ast`。最新的规范文字是 `app-roadmap.tex`（2025-11）。

### 2.2 目标代码在宿主里怎么执行

所有环境统一使用 **Common-boot 的 HIR 求值器**：Eclector 读出 CST → `cst-to-ast` → `ast-to-hir` → 每条 HIR 指令对应一个宿主闭包（thunk），然后执行（`D/Common-boot/HIR-evaluator/eval.lisp:5-11`、`evaluator.lisp:37-54`）。

- 宿主编译器只用来生成 lambda list 的参数解析器（`D/Common-boot/HIR-evaluator/parse-arguments-instruction.lisp:99`）。
- 目标闭包是 `cbe:closure`，一个宿主的 funcallable-standard-object，所以宿主代码可以直接调用目标函数。

求值器的演变（来自 git log）：

| 时间 | 变化 |
|---|---|
| 2023-09 | 使用 Common-boot 的 AST 求值器 |
| 2024-07-04 | 改用 Maclina 作为求值器（a81391a20） |
| 2024-09-21 | 移除 Maclina（ccfe18197），提交信息里没写原因 |
| 2024-09 | 改用 AST 解释器 |
| 2025-03 | 加入 HIR 解释器（7d415bb2a），删除 AST 解释器（3bb835e5b） |

推测选择 HIR 求值器的原因是：自举期的求值和以后的原生编译器共用同一个前端。`S/Code/New-boot/Maclina-backtrace-inspector/` 已经是死代码。

### 2.3 多层环境：E1 到 E4

SICL 坚持让**同一份未修改的 MOP 代码**（Clostrophilia）在宿主里构建出目标自己的 metaobject，因此需要多层环境。每一层的对象都是由上一层的类实例化出来的。

| 环境 | 内容 | 位置 |
|---|---|---|
| E1 | MOP 类直接用宿主类，通过 closer-mop 创建；访问器是宿主泛函。载入 Clostrophilia、Predicament、ctype、Acclimation、Ecclesia | `Phase-1/boot.lisp:68-106`、`:195-342` |
| E2 | 再载入同一批代码，但 `make-instance` 被截获，改用 E1 的 cell。结果是 bridge class（E1 宿主类的实例） | `Phase-2/boot.lisp:135-138` |
| E3 | 同上，截获 E2 的 `make-instance`。结果是“不纯的 ersatz”对象：header 加 rack，类是 bridge class | `Phase-3/boot.lisp:156-162` |
| E4 | 最终系统主环境的模型，不再允许共享 cell，改用重命名函数（`make-instance-1` 绑定到 E3 的 `make-instance`） | `Phase-4/boot.lisp:3-8`、`:38-39` |
| Phase 5 | “tie the knot”：把 E4 里所有对象的类槽改指向 E4 自己的类，让 E4 自描述；之后做 satiation | `Phase-5/tie-the-knot.lisp:91-204` |
| Phase 6 | 往 E4 里载入普通库：Regalia、Alexandria、Cyclosis、用 Buoy 模拟的浮点、`sicl-cons`、`fast-generic-functions` 等（2026 年主要在做这个） | `Phase-6/boot.lisp:18-98` |

纯度模型在 `app-bootstrapping.tex:8-27`：纯度 0 是宿主对象，1 是 bridge，2 是不纯的 ersatz，3 及以上是纯 ersatz。

**进度**：Phase 1–5 可用，Phase 6 进行中。规范里的 phase 7–10（用 ersatz 替换宿主的符号、cons、整数，生成内存镜像，写出二进制文件）**完全没有实现**。唯一写过 image 的代码是 2022 年的 `S/Code/Boot/pointer.lisp`。`S/Code/ELF` 只是 2021 年的一个演示。

### 2.4 client 协议：SICL 怎么接入这些库

每个库的入口都多一个 `client` 参数，实现方通过特化自己的 client 类来定制行为。SICL 的 client 定义在 `S/Code/New-boot/Shared/client.lisp:3-7`：

```lisp
(defclass client (cb:macro-transforming-client
                  eclector.concrete-syntax-tree:cst-client
                  parcl-low-class:client
                  cbe:client) ...)
```

- **跨环境截获调用**：在 `clostrum:ensure-operator-cell` 上加一个 `:around` 方法，返回另一个环境的 cell（`Shared/function-cell-interception.lisp:12-32`）。HIR 求值器在构建 thunk 时会解析 cell，所以不改库的源码就能把调用重定向到别的环境。
- **符号**：`eclector.reader:interpret-symbol` 把非 CL 符号变成**未 intern 的宿主符号**，登记在属于目标的 Parcl 包里（`Shared/package-programming.lisp:19-118`）。这样目标包和宿主包是分开的，同时仍然用宿主符号作为表示。
- **Trucler**：`describe-variable :around` 把关键字、`T`、`NIL` 处理成常量（`Shared/environment.lisp:11-16`）。
- **Common-macros**：通过 `cmd:defun-compile-time-action`、`cmd:ensure-class-name` 等钩子决定标准宏的编译期副作用（`Phase-1/macro-programming.lisp:5-60`）。
- **primop**：目标原语一律写成 `(sicl-primop:primop :fixnum-multiply a b)`，在代码里一共用到大约 73 个操作码。自举时它绑定到一个宿主泛函，在宿主里模拟目标语义，例如 fixnum 在 2^62 处回绕（`Shared/primop.lisp:3-147`）。原生后端需要在 HIR → MIR 时识别这种调用并展开成内联代码。

### 2.5 规范和代码里能看到的经验

- 选择一等环境而不是重命名包（`chap-bootstrapping.tex:95-104`）。
- CLOS 必须早载入，因为很多库需要完整的 CLOS，包括 `define-method-combination`（`:5-14`）。
- 库之间的依赖顺序很难排：Predicament 的 `restart-case` 需要 `typep` 支持 `null` 和 `string`；ctype 需要所有系统类，而且在载入时就创建实例，所以必须最后载入（`:316-501`）。
- 宿主 reader 的坑：反引号的展开因实现而异；浮点字面量；potential number（`chap-cross-compilation.tex:20-54`）。SICL 后来用 Buoy 模拟浮点，不再用宿主浮点。
- 共享 cell 会让人看不清调用到底进了哪个环境，所以改成重命名（`app-roadmap.tex:259-268`）。
- 为了跨环境调用，Clostrophilia 的源码里出现了 `slot-value-using-location+1`、`class-of+1` 这类名字，路线图承认这很丑（`app-roadmap.tex:68-73`）。
- 大约 1200 行 phase 脚本基本都是特例补丁（`Phase-*/boot.lisp`），比如 `validate-superclass` 设成 `(constantly t)`，`subtypep-1` 设成 `(constantly t)`。

---

## 3. 编译器

### 3.1 流水线

| 阶段 | 规范 | 代码现状 |
|---|---|---|
| 读入 | Eclector 读成 CST，`sicl-source-tracking` 把文件保存为行向量（`chap-compiler.tex:248-309`） | 可用 |
| CST → AST | Common-boot，AST 类来自 Iconoclast。AST 与环境无关，它的文本形式就是 FASL 格式（`:313-336`、`chap-fasl.tex:44-64`） | 可用：`D/Common-boot/Code/cst-to-ast.lisp` |
| AST 简化 | — | 可用：`D/Common-boot/AST-to-HIR/ast-to-hir.lisp:3-22` 里一串固定的 Iconoclast 变换（见 3.2） |
| AST → HIR | 规范说 HIR 由 Hirundine 定义（`chap-compiler.tex:341-347`） | 实际产出的是 **Common-boot 自己的 HIR**，不是 Hirundine。Hirundine 至今没有生产者 |
| HIR 变换 | 全局函数引用、catch、bind、unwind、symbol-value 都变成调用点，交给 call-site manager（`:351-385`） | 未实现 |
| HIR → MIR → 机器码 | 规范说 MIR 和代码生成来自 Posterior 库，“仍在进行中” | 本地没有 Posterior 的源码；路线图称它“still embryonic”（`app-roadmap.tex:210-227`） |

### 3.2 AST 简化链

`simplify-ast` 依次执行这些变换（`D/Common-boot/AST-to-HIR/ast-to-hir.lisp:3-22`）：

```
macrolet-to-locally → lexify-lambda-list → split-let-or-let*
→ replace-special-let-with-bind → let-to-labels → flet-to-labels → split-setq
→ inline-inlinable-functions → remove-degenerate-labels
→ assignment-conversion → convert-block → remove-unused-blocks → convert-tagbody
→ transform-function-definition-and-reference → eliminate-function
→ closure-conversion → replace-trivial-locally-by-progn → eliminate-trivial-progn
```

输出是一个已经做过赋值转换和闭包转换的 AST，用 `static-environment-ast`、`make-cell-ast`、`read-cell-ast`、`write-cell-ast` 等节点表示闭包环境。lambda list 已经词法化（不含初始化表达式和 `&aux`）。Iconoclast 大约有 150 个 AST 类，包括 `handler-bind-ast`、`with-slots-ast` 这样的宏级节点。

### 3.3 动态环境和非局部退出

- **动态环境是 HIR 里显式传递的一等值。** 每条 `funcall-instruction` 都有一个动态环境输入；`block`、`tagbody`、`catch`、`special-variable-bind` 各产出一个扩展后的新动态环境（`D/Hirundine/Code/Graph/funcall-instruction.lisp:11-26` 及同目录各指令）。
- **在机器层面是一个隐式参数寄存器**：x86-64 上是 RBX，RISC-V 上是 x6。线程对象单独放在 FS（`chap-backend-x86-64-new.tex:20-55`）。
- **special 变量用深绑定。** 访问时在动态环境里线性查找当前线程的绑定，找到就返回栈上的动态值 cell，否则返回全局值 cell（`chap-compiler.tex:406-446`）。
- **退出**：`block` 创建一个退出点条目和一个唯一标识；`return-from` 和 `go` 接收动态环境和这个标识，后继是负责接收值的 `receive-instruction`。
- **展开算法**（只存在于 2021 年的旧 runtime 代码里，`S/Code/Compiler/Run-time/unwind.lisp:3-33`）：
  1. 找到目标条目，失效就报错；
  2. 让中间的退出点全部失效；
  3. 依次执行 `unwind-protect` 的 cleanup，执行每个 cleanup 时动态环境截断到它自己的条目之后；
  4. 从条目恢复 SP 和 FP。
- **handler 和 restart 就是普通的 special 变量。** Predicament 里 `handler-bind` 展开成对 `*handler-clusters*` 的 `let`（`D/Predicament/Code/handler-bind-defmacro.lisp:3-8`），restart 用 `*restart-clusters*`。不需要编译器的特殊支持。
- **还没解决的地方**：
  - Hirundine 没有 `unwind-protect` 指令；
  - Common-boot 对 `unwind-protect` 的翻译标着 “FIXME: this is not doing the right thing”，只是把各个形式顺序执行（`D/Common-boot/AST-to-HIR/unwind-protect-ast.lisp:3-8`）；
  - catch 指令缺少值输出（`D/Common-boot/HIR/catch-instruction.lisp:36`）；
  - 规范里“向退出点传递多值”一节写着 “To be filled in”（`chap-processing-values.tex:253-255`）。

### 3.4 调用约定（只有规范，没有在用的实现）

`chap-processing-values.tex`：

- 没有 callee-saved 寄存器，默认所有参数都放在栈上；
- 由调用方按被调函数的 frame size 构建被调方的栈帧；
- 被调方根据 FP、SP 和自身的静态帧大小算出参数个数；
- 第一个返回值放在寄存器里，其余值放在栈上，个数由 FP − SP 得出；
- 所有多值消费者都归约为 `multiple-value-call`；
- 尾调用直接替换调用方的栈帧。

x86-64 的寄存器分配：RAX 放第一个返回值，RBX 放动态环境，RCX 放返回时调用方的 FP，R10 放静态环境，RBP 是帧指针，FS 指向线程对象。

### 3.5 Call-site manager（只有设计，代码是空壳）

`chap-call-site-manager.tex`（总结自 Strandh 在 ELS 2021 的论文）：

- 每个具名调用点是一条 `jmp`，跳到为这个调用点单独生成的 trampoline 片段；
- 每次 `(setf fdefinition)` 都重新生成片段，把被调函数的静态环境、帧大小和入口地址作为常量固化进去；
- 每个函数有两个函数体：带参数解析序言的通用版本，和没有序言的优化版本。片段直接把参数从调用方的位置搬到被调方期望的位置，keyword 参数解析因此消失；
- **重定义协议**：先把所有片段都指回始终有效的默认解析入口，再按新函数重新特化（`:75-80`）；
- SICL 刻意不利用 CLHS 3.2.2.3 允许的“假定被调函数固定不变”（`:82-93`）。

规范写明“初始版本的 SICL 不包含 call-site manager”。代码是一个什么都不做的桩（`S/Code/Call-site-manager/add-call-site.lisp`，2022）。

每个调用点的描述符（call-site descriptor）包含：被调函数名、跳转索引、源码位置、**GC trace map**、参数位置、活跃变量的位置和类型（`chap-data-representation.tex:227-319`）。它同时服务于 GC、debugger 和 backtrace。

---

## 4. 对象表示和 CLOS

### 4.1 数据表示（只有规范，`S/Code/Memory/pointer.lisp` 是个空壳）

`chap-data-representation.tex`：

| 低 3 位 | 含义 |
|---|---|
| `xx0` | fixnum，62 位 |
| `001` | cons |
| `011` | 立即数：5 位次级标签，`00011` 是字符，`10011` 是放在高 32 位的 single-float |
| `101` | 标准对象的 header |
| `111` | rack 指针（不是一等值） |

- **标准对象 = 两个字的 header：[class, rack]。** rack 的第 0 个字是 **stamp**（类的唯一编号），第 1 个字是创建时的有效槽列表，之后才是槽（`:94-190`）。所以过时的实例是自描述的，GC 和实例更新都能直接用。
- **为什么要 rack 这一层间接**：`adjust-array`、泛函更新都是构建一个新 rack，然后一次写入替换掉旧的，这样不用加锁也能保持一致。`change-class` 只换 rack，header 不变，对象身份保持不变（`:109-134`、`chap-object-system.tex:117-126`）。
- **在考虑的替代设计**：把类指针移进 rack，`change-class` 只需要单字 CAS，不用双字 CAS。header 空出来的那个字用来存身份哈希（`app-possible-alternative-designs.tex:3-21`）。
- **函数都是 funcallable standard object。** rack 里存 stamp、槽、静态环境、入口地址和帧大小。函数描述符放在参数解析入口之前的那个字里（`:321-473`）。
- **符号本身不存值、函数和 plist**，这些都放在一等全局环境里（`:400-419`）。
- 规范假设堆不移动：字面量直接嵌在代码里，rack 里存裸入口地址，rack 指针可以跨 GC 缓存（`:371-377`、`:457-466`）。

### 4.2 泛函分派（Clostrophilia）

采用 Strandh 在 ILC 2014 提出的快速泛函分派（`D/Clostrophilia/Documentation/Texinfo/chap-generic-dispatch.texi:60-165`）：

- 每个泛函保存一份**调用历史**，据此编译出一个判别函数。判别函数是一个对**小整数做区间比较**的自动机；
- 标准对象用 rack 的第 0 个字（stamp）作为这个整数，fixnum、cons、字符等特殊实例用它们的类的编号；
- 未命中时，先比较实例的 stamp 和它的类当前的编号：不同说明实例已经过时，先更新实例再重试；相同就调用 `compute-applicable-methods-using-classes`，把结果加入调用历史，然后重新计算自动机；
- 只有一个条目的访问器退化成一次比较加内联的槽访问。

实现在 `D/Clostrophilia/Code/Generic-function-invocation/`。

**重要**：判别函数和有效方法都是**运行期调用 `compile nil` 编译出来的**（`compute-discriminating-function.lisp:245,254,319,392`）。SICL 在自举时靠 satiation（预先填好分派缓存）避开这个问题。

### 4.3 Clostrophilia 需要实现方提供的原语

- `allocate-general-instance`（参数为类和大小）
- `standard-instance-access`（读写 rack 的 cell）
- `+unbound-slot-value+`
- `set-funcallable-instance-function`
- `class-of`、`small-integer=`、`small-integer<`
- `find-method-combination-template`
- 自举用的 `+1` 重命名函数：`ensure-generic-function+1`、`slot-value-using-location+1` 等
- 运行期的 `compile`

rack 的布局：cell −2 是 stamp，cell −1 是有效槽列表（`Class-initialization/allocate-instance.lisp:25-43`）。

---

## 5. GC 和 debugger（只有规范，代码要么过时要么只是演示）

- **GC 规范**（`chap-garbage-collector.tex`）：
  - 一个全局的、**不移动的**、并发并行的 mark-sweep 收集器；
  - 2025-01 删除了按线程分配的 nursery 设计；
  - 堆分为放 cons 和 header 的 dyad 空间（每格 2 个字，没有碎片），以及用改造过的 dlmalloc 管理的 rack 空间；
  - Dijkstra 式写屏障；
  - 精确扫描 root：每一帧的 trace map 来自上一帧的调用点描述符。
- **GC 代码**：`S/Code/Garbage-collector/gc.lisp` 是 2021 年的滑动式 nursery 收集器，和现行规范矛盾。
- **safepoint**：规范只把调用点当作 safepoint（`chap-data-representation.tex:306-312`）。
- **Debugger**（`chap-debugger.tex`，`D/Clordane`）：
  - 打了断点的函数强制使用通用版本；
  - 函数入口查一张按 PC 取模的位图，命中后再查以 PC 为键的哈希表；
  - 通用版本里所有词法变量都放在固定的栈槽里，并且不做类型传播，这样 debugger 可以给任意变量赋任意值（`chap-data-representation.tex:501-525`）；
  - Clordane 的文档设计了 **poll 点**：在 `debug` 级别高时，每个源码形式前后各插一个，依次检查线程的 debug 标志、位图、断点表（`D/Clordane/Documentation/app-implementing-poll-points.tex:15-75`）；
  - 文档里定义了按源码形式的 step over、step in、step out；
  - 代码只是一个 168 行的 McCLIM 原型。

---

## 6. 模块生态

### 6.1 intrinsic 和 extrinsic

- **extrinsic**：库载入到已有的 CL 实现里，不覆盖实现自带的函数。库的操作符放在一个 shadow 了 CL 同名符号的包里，比如 `khazern-extrinsic:loop`。
- **intrinsic**：库就是实现自己的原生版本，直接定义 `CL` 包里的符号（`chap-standardized-modules.tex:236-239`、`D/Khazern/README.md`）。
- Tarn Burton 的库（Cyclosis、Salmagundi、Incless、Inravina、Invistra、Khazern、Anatomicl）都用 **Trinsic** 的 `make-define-interface` 生成 CL 层接口，参数是 `:client-form` 和 `:intrinsic t/nil`（例如 `D/Khazern/code/interface.lisp:259`）。
- 共同的协议模式：每个入口都转发到一个多带 `client` 参数的泛函，`client` 取自 `*client*`。实现方特化自己的 client 类来定制行为。

### 6.2 模块表

日期是最后一次提交的日期。代码行数统计所有 `.lisp` 文件，包括测试。

| 模块 | 用途 | 实现方需要提供的钩子 | 日期 / 行数 | 许可证 |
|---|---|---|---|---|
| Eclector | Reader、readtable、CST reader | 约 40 个 client 泛函：`interpret-symbol`、`interpret-token`、`find-character`、`make-structure-instance`、`evaluate-expression`、`source-position` 等 | 2026-08 / 12.2k | BSD |
| Concrete-Syntax-Tree | 带源码位置的语法树、lambda list 解析 | 无 | 2025-08 / 4.9k | BSD |
| Clostrum | 一等全局环境 | 底层的 `clostrum-sys` 泛函（`operator-cell`、`variable-cell` 等）；可以直接用现成的 `clostrum-basic` | 2026-04 / 2.1k | BSD-2 |
| Trucler | 词法环境查询协议 | 一个 client 类；用 `trucler-reference` 即可 | **2023-09** / 2.5k | BSD |
| s-expression-syntax | 所有特殊形式和标准宏的语法描述 | 一个 builder | 2024-11 / 9.4k | MIT |
| architecture.builder-protocol | builder 协议 | — | 2023-11 / 5.3k | **LGPLv3** |
| Iconoclast | AST 类、builder、遍历器、AST 变换 | — | 2025-07 / 10.6k | **没有许可证文件** |
| Common-boot | CST → AST、AST 简化、AST → HIR、闭包转换、HIR 求值器 | client 类 | 2025-10 / 8.9k | **没有许可证文件** |
| Common-macros | 用 `defmacro` 写的标准宏（`common-macro-definitions`） | `defun-compile-time-action`、`defclass-compile-time-action`、`ensure-class-name`、`get-setf-expansion`、`proclaim` 等 | 2026-02 / 5.7k | BSD |
| Ecclesia | lambda list 解析、解构、body 和声明解析 | — | 2026-07 / 4.5k | MIT |
| Acclimation | condition 报告的本地化 | — | 2024-05 / 1.1k | BSD-2 |
| Predicament | condition 系统：handler、restart、`signal`、`error`、`invoke-debugger`、标准 condition 类型 | `*condition-maker*`、`*default-debugger*`。**不提供 `condition` 类和 `define-condition`**，SICL 在 `S/Code/Conditions` 里自己实现 | 2025-06 / 1.9k | BSD |
| Clostrophilia | AMOP 级别的 CLOS | 见 4.3 | 2026-08 / 5.3k | BSD |
| ctype | `typep`、`subtypep` | `ctype/client.lisp` 里的一组泛函：fixnum 范围、浮点类型、UAET 等。**不特化就会默认使用宿主 SBCL 的值，对交叉编译是错的** | 2026-06 / 8.3k | BSD |
| Regalia | 数组类层次、`make-array`、`aref` | `make-array-instance` 和 15 个按类型区分的访问器（`t-aref`、`unsigned-8-bit-aref` 等） | 2026-06 / 1.1k | BSD |
| Anatomicl | `defstruct` | `structure-description`、`generate-allocation-form`、`compute-slot-layout` 等 | 2026-06 / 1.3k | BSD |
| Constrictor | cons 字典，除了 `cons`、`car`、`cdr`、`rplaca`、`rplacd` | 基本的 cons 原语；目前仍用到少量泛函，路线图计划去掉，使它不依赖 CLOS | 2026-07 / 6.6k | BSD |
| Consecution | 序列字典 | `replicate-for-each-vector-class` 宏；依赖 fast-generic-functions | 2026-07 / 28.4k | BSD |
| Khazern | `loop` 及其扩展子句 | `standard-client` 的子类 | 2026-09 / 6.1k | BSD/MIT |
| Salmagundi | 哈希表、`sxhash` | `make-hash`、`hash` 等。**EQ 哈希用 `#+impl` 取地址，未知实现时退化为常数 0**（`code/hash.lisp:195-205`）；不支持弱表 | 2025-09 / 2.5k | BSD |
| Cyclosis | 流字典和 Gray streams、外部格式（来自 Mezzano） | 文件 I/O 按 `#+sbcl`、`#+sicl` 写死了系统调用（`code/posix-file-stream.lisp:46-90`），kiln 需要补一个 `#+kiln` 分支 | 2026-06 / 6.6k | BSD |
| Incless | `write`、`print`、标准类的 `print-object` | `print-object`、`write-object`、`circle-check` 等 | 2026-07 / 1.3k | BSD |
| Inravina | pretty printer | — README 写明仍在开发中，尚不能替代现有的 pretty printer | 2026-07 / 4.0k | MIT |
| Invistra | `format`、`formatter` | — | 2026-06 / 6.9k | BSD |
| Quaviver | 浮点数和十进制的互相转换（Schubfach、Dragonbox 等） | `float-triple`、`triple-float` 等 | 2026-06 / 7.2k | MIT |
| Buoy | 浮点初等函数（移植自 core-math），以及自举时用的软件浮点 `buoy-simulate` | — README 写明目前只实现了 double-float 的 `sin` | 2026-08 / 5.5k | BSD |
| Maclina | 可移植的字节码编译器、`compile-file`、FASL、VM；`vm-cross` 可以在 Clostrum 环境里运行 | `*client*`、`link-function`、`link-variable` 等 | 2026-09 / 15.2k | BSD-2 |
| Hirundine | HIR 控制流图、基本块、支配关系 | — | 2025-11 / 1.3k | BSD-2 |
| Parcl | 包系统 | 正确的仓库是 `s-expressionists/Parcl`。SICL 的 `get-dependencies.sh` 里写的 `robert-strandh/Parcl` 只有一个 LICENSE 文件 | 2025-06 | BSD-2 |
| Trinsic | 生成 intrinsic/extrinsic 接口 | — | 2026-01 | — |
| Clordane | debugger 原型 | — | 2024-10 / 168 | 无 |

传递依赖里还有 fast-generic-functions、nontrivial-gray-streams、documentation-utils、trivial-with-current-source-form、trivial-features，使用这些模块时需要一并获取。closer-mop 可以从 Quicklisp 获取。

### 6.3 ANSI 各章的覆盖情况

| ANSI 章节 | 由哪个模块覆盖 | 实现方要自己写的部分 |
|---|---|---|
| 3 求值和编译 | Common-boot、Iconoclast、Common-macros、CST、Trucler、Clostrum、Maclina | 原生后端 |
| 4 类型和类 | ctype | `coerce`、`type-of` |
| 5 数据和控制流 | Common-macros（`setf` 系列等） | 特殊操作符、`funcall`/`apply`、`values`、`eq`/`eql`/`equal`/`equalp` |
| 6 迭代 | Khazern、Common-macros | — |
| 7 对象 | Clostrophilia | 原语和胶水代码 |
| 8 结构 | Anatomicl | — |
| 9 condition | Predicament | `condition` 类、`define-condition` |
| 10 **符号** | — | **全部** |
| 11 包 | Parcl | 需要确认 Parcl 的完成度 |
| 12 **数** | Quaviver（浮点 I/O）；SICL 的 `Code/Arithmetic` 可以参考，但**没有 bignum**（`binary-multiply-defmethods.lisp:8-9` 里是 `(error 'create-a-bignum)`） | **bignum、ratio、完整的数值塔、无理函数、`random`** |
| 13 **字符** | —（SICL 的 `Code/Character` 只支持 ASCII） | **全部，包括 Unicode 表** |
| 14 cons | Constrictor | 基本原语 |
| 15 数组 | Regalia | 访问器和分配原语 |
| 16 **字符串** | 序列操作部分由 Consecution 覆盖 | **`string=`、`string-upcase`、`string-trim` 等** |
| 17 序列 | Consecution | — |
| 18 哈希表 | Salmagundi | 身份哈希、弱表 |
| 19 **文件名** | — | **全部（pathname、逻辑 pathname）** |
| 20 **文件** | — | **全部** |
| 21 流 | Cyclosis | fd 系统调用 |
| 22 打印器 | Incless、Inravina、Invistra、Quaviver | — |
| 23 reader | Eclector | — |
| 24 系统构造 | Maclina 的 `compile-file` 和 FASL | `require`/`provide`、`*features*` |
| 25 **环境** | — | **`time`、`get-universal-time`、`describe`、`inspect`、`apropos`、`disassemble`、`trace` 等** |

### 6.4 SICL 实际的载入顺序

1. Phase 1–4（`Phase-1/boot.lisp:175-342`）：`sicl-primop` → Clostrum 环境的包 → Clostrophilia 的包和类层次 → 算术类层次 → 类型支持 → Predicament、ctype、Acclimation、Ecclesia → Clostrophilia 的其余部分（泛函调用、初始化、类终结、方法组合）→ `common-macro-definitions` → `make-instance`
2. Phase 5：satiation、tie the knot
3. Phase 6（`Phase-6/boot.lisp:19-98`）：数组和 Regalia → setf expander → Alexandria → POSIX → Trinsic → Cyclosis → 浮点算术 → `coerce` → 字符 → cons → 数据和控制流 → fast-generic-functions；Quaviver 单独载入

几乎所有模块都用 `defgeneric` 或 `defclass`。规范的引言承认，原本想排出一个不依赖 CLOS 的偏序，这个计划已经放弃（`chap-intro.tex:39-51`）。

---

## 7. 对 kiln 的影响

这一节写于 kiln 实现前端和 CLOS 之前，记录的是当时的判断。后来的决定：前端见 [front-end.md](../design/front-end.md)，复用的划分见 [modules.md](../design/modules.md)，CLOS 见 [clos.md](../design/clos.md)（单一环境的目标端引导、vendor Clostrophilia、分派解释执行），运行期 `compile` 见 [eval-compile.md](../design/eval-compile.md)。

### 7.1 采纳

| 项目 | 做法 |
|---|---|
| 前端 | Eclector + CST + Common-boot 的 `cst-to-ast` + Iconoclast。**交接点定在 `simplify-ast` 的输出**：这时闭包转换、赋值转换、block/tagbody 转换都已完成，lambda list 也已词法化。从这里往下降级到 kiln 自己的 IR，再到 CLIF。简化链可以按需裁剪或重排，比如 kiln 可能想自己做闭包转换 |
| 目标环境 | Clostrum（`clostrum-basic`、`clostrum-trucler`）加上 client 特化的写法 |
| 跨环境的 reader | 参考 SICL 用 Eclector 和 Parcl 的做法：目标符号用未 intern 的宿主符号表示，登记在目标自己的包里 |
| primop | 采用单一的 `primop` 入口加关键字操作码。kiln 在降级时把它识别成 Cranelift 内联指令。自举期间在宿主里模拟目标语义：fixnum 宽度、字符编码，**不使用宿主浮点** |
| rack 间接和 stamp 分派 | 采用。和移动式的 MMTk 兼容，前提是 rack 是普通的被追踪对象，不依赖固定地址。倾向采用替代设计：类指针放进 rack，header 空出的字存身份哈希（同时解决 Salmagundi 的 EQ 哈希问题） |
| Clostrophilia 的分派自动机 | 采用 |
| handler 和 restart 用 special 变量 | 采用 Predicament 的做法。kiln 的 special 变量按 TLS 索引存在 context 上（C1），所以 handler 链自然挂在 context 上，C7 也满足 |
| 调用点描述符 | 采用“每个 safepoint 一份元数据记录”：GC map、debugger 需要的活跃变量、backtrace 信息放在一起。kiln 的 poll 点（C4）也要有描述符，SICL 假设 safepoint 只在调用点 |
| call-site manager | 先只采用设计：每个调用点一个可修补的间接 cell 或 stub，通用入口和优化入口，“先指回默认入口，再重新特化”的重定义协议。在 Cranelift 上通过间接 cell 实现，不修补函数内部的代码。放到 WPO 之后再做 |
| Debugger | 参考 Clordane 的 poll 点设计，以及“通用版本保留所有变量的栈槽、不做类型传播”的做法。kiln 的 C4 poll 点可以兼作断点检查点 |
| 标准库模块 | Khazern、Constrictor、Consecution、Common-macros、Predicament、ctype（需要完整的 kiln client）、Anatomicl、Invistra、Incless、Quaviver 按 intrinsic 方式使用 |

### 7.2 不采纳

| 项目 | 原因 |
|---|---|
| E1 到 E4 的多层环境、straddle 函数、`+1` 命名、tie the knot | 这套机制的存在，是因为 SICL 要求在宿主里用未修改的 MOP 代码构建目标 metaobject。代价很高，SICL 自己的路线图也承认（`app-roadmap.tex:68-73`、`:259-268`） |
| 用宿主求值器跑整个系统 | SICL 走这条路两年半，至今没有产出 image |
| SICL 的调用约定 | 参数全部放栈上、由调用方构建帧、值放栈上，这些都无法映射到 Cranelift。kiln 用 Cranelift 的调用约定，加上显式参数个数、context 参数（对应 SICL 的 RBX），多值放在 context 的值缓冲区里 |
| 深绑定 | 和 C1 的 TLS 索引方案冲突。但 HIR 里**把动态环境当作 SSA 值显式传递**的形式值得保留，对以后的一次性续延有用。降级时把 bind 变成“保存、设置、展开时恢复” |
| GC 设计 | 不移动的并发 mark-sweep 和 Dijkstra 写屏障不适用于 MMTk，用 MMTk 自己的屏障 |
| 假设堆不移动的设计 | 字面量嵌入代码、rack 里存裸入口地址。kiln 要么用可重定位的字面量表，要么把代码空间设为不移动，要么 pin 住相关对象 |
| Hirundine 和 Common-boot HIR | Hirundine 没有生产者；Common-boot HIR 面向求值器，`unwind-protect` 和 catch 的值都有 FIXME。kiln 自己设计 AST 以下的 IR，`unwind-protect` 也要自己设计。Hirundine 的节点类可以作为命名参考 |

### 7.3 需要修正 kiln 原计划的地方

1. **宏和 `eval-when` 在宿主里怎么执行。**
   原计划是“defmacro 由 SBCL 编译成宿主函数”。但宏函数会调用目标环境里定义的辅助函数，而那些函数存在于 Clostrum 环境中，不在宿主的全局环境里，所以直接用 SBCL 的 `compile` 不行。可选做法：

   | 做法 | 说明 |
   |---|---|
   | Common-boot 的 HIR 求值器 | 和 kiln 前端完全一致，SICL 目前用的就是它。**倾向这个** |
   | Maclina `vm-cross` | 完整，基于 Clostrum。缺点是前端和 kiln 不同，声明、`load-time-value`、源码跟踪等语义可能有细微差别；SICL 试用后又移除了 |
   | 把 kiln AST 翻译成宿主 Lisp 再交给 SBCL 编译 | 性能最好，但要自己写一个翻译器 |

2. **编译期的 CLOS。**
   被交叉编译的库在编译期会用到 CLOS：`defclass`、`defgeneric` 的编译期副作用，ctype 的方法组合，`define-condition`。SICL 的 E1 给出了便宜的答案：编译期的 CLOS 直接用宿主 CLOS（通过 closer-mop），并且和最终 image 里的目标 metaobject 严格分开。kiln 照此处理。

3. **CLOS 在目标端 bootstrap：计划成立。**
   SICL 拒绝 PCL 式 early 函数的理由是追求优雅，不是因为它不可行（`chap-bootstrapping.tex:16-36`）。kiln 用手写的核心 metaobject 骨架、early 函数桩和事后修补，换掉 SICL 的环境杂耍。是直接复用 Clostrophilia 的代码（需要把 `+1` 系列名字在单一环境下绑回自身），还是只参考它，留到 M4 再决定。

4. **新风险：自举完成前，运行期的 `compile` 由谁提供。**
   Clostrophilia 在运行期用 `compile nil` 生成判别函数和有效方法。kiln0 在 M5 之前不带编译器。可选做法：
   - 在宿主侧做 satiation，构建时就把分派缓存填满；
   - 给分派自动机写一个解释器作为兜底；
   - 内置一个字节码 VM（参考 Maclina）；
   - 开发期走远程 JIT，把编译请求转发给 SBCL 端。

   要在 M4 之前定下来。

5. **许可证。**
   Iconoclast 和 Common-boot 没有许可证文件，builder-protocol 是 LGPLv3。这些属于编译器，seal 之后不带编译器的交付物里不会有它们。但自举后的 kiln image 本身包含编译器。要向作者确认 Iconoclast 和 Common-boot 的许可证，并评估 LGPL 对静态链接的影响。

6. **要自己写的标准库部分比原先估计的多。**
   符号、数值塔（bignum 在 SICL 里也没有实现）、Unicode 字符、字符串函数、pathname 和文件、环境字典、`condition` 类和 `define-condition`、身份哈希、弱表，见 6.3。M3 的工作量要相应上调。

7. **ctype 的 client 必须完整实现。** 否则它会默认使用 SBCL 的 fixnum 范围和 UAET，交叉编译时是错的。

---

## 如何更新本文

SICL 更新后，按以下顺序核对，然后修改本文对应的小节：

1. 在 SICL 仓库里执行 `git log --since=<上次调研日期> --format='%cs %s'`，看活动集中在哪些目录；
2. `S/Code/New-boot/` 有没有出现 phase 7 及以后，或者写 image 的代码；
3. `S/Specification/app-roadmap.tex` 有什么变化；
4. Common-boot 的 `AST-to-HIR/unwind-protect-ast.lisp` 还有没有 FIXME，是否改为产出 Hirundine HIR；
5. 有没有出现 Posterior 仓库，原生后端是否重新开始开发；
6. 更新各模块仓库，然后用 `git log -1 --format=%cs` 更新 6.2 表里的日期。
