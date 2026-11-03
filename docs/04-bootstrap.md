# 04 复用与自举

## 决定

- **复用 SICL 生态里的独立模块，不复用 SICL 本体。**
- AST 以下的编译器、对象表示、runtime 全部自己写。
- SBCL 只做宿主，交叉编译出第一个 kiln，之后 kiln 编译自己。

## 为什么不用 SICL 本体

- SICL 本体不是一个能直接拿来用的成品实现。它的 bootstrap 流程和自己的对象表示、GC 设计、代码生成绑得很紧。
- kiln 的底层约束（[02-runtime-constraints.md](02-runtime-constraints.md)：context 指针、Cranelift、MMTk、精确栈图、帧可搬动）和 SICL 不同。照搬它的后端和 runtime，等于把这些约束全部重新塞进去。
- SICL 真正有价值的，是 s-expressionists 那批**为“装进新实现”而写的模块**。

先例：Clasp 复用了 Eclector 和 Cleavir，后端自己接 LLVM。

SICL 的现状调研见 [05-sicl-survey.md](05-sicl-survey.md)。SICL 至今没有原生后端，也不产出 image，从 HIR 往下没有可以复用的实现。

## 复用和自研的划分

| 部分 | 选择 | 说明 |
|---|---|---|
| Reader | 复用 **Eclector** | 带源码位置，配合 CST 使用 |
| 语法树 | 复用 **Concrete-Syntax-Tree** | 保留源码信息，debugger 和报错都需要 |
| 全局环境 | 复用 **Clostrum** | 一等全局环境，交叉编译时隔离宿主和目标的关键 |
| 词法环境查询 | 复用 **Trucler** | |
| 前端（CST 到 AST） | 复用 **Common-boot** 的 cst-to-ast，AST 用 **Iconoclast** | **交接点是 `simplify-ast` 的输出**：闭包转换、赋值转换已经完成，见 [05 §7.1](05-sicl-survey.md#71-采纳) |
| 标准宏 | 复用 **Common-macros**（`common-macro-definitions`） | 实现它的编译期副作用钩子 |
| 代码解析工具 | 复用 **Ecclesia** | lambda list 解析等，原 cleavir-code-utilities |
| 模式匹配 | 复用 **Trivia** | 编译器内部使用 |
| 类型系统 | 复用 **ctype** | 必须完整实现 kiln 的 client，否则会默认使用 SBCL 的 fixnum 范围和 UAET |
| 数组 | 复用 **Regalia** | 提供 `make-array-instance` 和按类型区分的访问器，降级为 Cranelift 内联指令 |
| cons 字典 | 复用 **Constrictor** | |
| 序列 | 复用 **Consecution** | 依赖 fast-generic-functions |
| 结构 | 复用 **Anatomicl** | |
| 哈希表 | 改造 **Salmagundi** | 补一个基于 header 哈希字的身份哈希（MMTk 会移动对象）；弱表要自己做 |
| 流 | 改造 **Cyclosis** | 补 `#+kiln` 的 fd 系统调用 |
| 包 | 候选 **Parcl**（`s-expressionists/Parcl`） | 需要确认完成度 |
| LOOP | 复用 **Khazern** | |
| FORMAT | 复用 **Invistra** | |
| 打印器、pretty printer | 复用 **Incless**；**Inravina** 仍在开发中 | |
| 浮点打印 | 复用 **Quaviver** | |
| AST 以下的 IR、优化、Cranelift 生成 | **自研** | 非局部退出、`unwind-protect`、context、poll 点、栈图都在这一层定义。SICL 在这一层只有设计文字 |
| Condition 系统 | 复用 **Predicament**，自己写 `condition` 类和 `define-condition` | handler 和 restart 是普通的 special 变量，按 C1 自然挂在 context 上。捕获续延的 handler 以后再加 |
| CLOS / MOP | 基于 **Clostrophilia**，在目标端用 early 函数 bootstrap | 采用 rack 间接和 stamp 分派。是直接用它的代码还是只参考，M4 再定，见下文 |
| 轻量 `eval` | 参考 **Maclina** | 可作为交付期可选的 `eval` 模块，或自举完成前的运行期 `compile` |
| 数值塔（bignum、ratio） | 自研：Rust runtime 原语，Lisp 包一层 | SICL 也没有 bignum。bignum 的 limb 由 MMTk 分配 |
| 符号、字符（Unicode）、字符串、pathname、文件、环境字典 | **自研** | 没有现成的模块，见 [05 §6.3](05-sicl-survey.md#63-ansi-各章的覆盖情况) |

**待办**：
- 确认 Iconoclast 和 Common-boot 的许可证（仓库里没有许可证文件），评估 builder-protocol 的 LGPLv3 对静态链接的影响；
- 读 Common-boot 的 cst-to-ast，确认它对 client 的要求（环境协议、宏展开钩子）能否套上 Clostrum 目标环境。

## 自举路线

核心思路：在 SBCL 里运行 kiln 编译器，**用 Clostrum 建一个独立的目标环境**，交叉编译出目标代码，链接成第一个 kiln 可执行文件，再让它编译自己。

```
SBCL 宿主
 ├─ 载入：Eclector + CST + Trucler + Common-boot/Iconoclast 前端 + kiln 中后端
 ├─ Clostrum 目标环境 E_target（和宿主的包、函数、宏完全隔离）
 │    目标源码中的 defmacro / eval-when → 由宿主侧求值器执行（倾向 Common-boot HIR 求值器）
 │    目标源码中的 defun   → 降级到 kiln IR → 输出 CLIF
 └─ 输出 CLIF / 目标 IR
        ↓
Rust 侧 kiln-cg（cranelift-reader + cranelift-object）
        ↓  .o 文件
与 Rust runtime（kiln-rt：MMTk、context、FFI trampoline）链接
        ↓
kiln0  ──编译自己──▶ kiln1 ──编译自己──▶ kiln2   （kiln1 和 kiln2 的产物应当一致）
```

### 关键选择

1. **用 Clostrum 隔离宿主和目标。**
   SBCL 自己的交叉编译靠 `sb-xc` 包重命名，SICL 靠一等环境。kiln 选后者：目标里重定义 `car`、`defclass` 都不会碰到宿主。

   **约束**：宏在编译期由宿主执行，所以宏展开函数及其依赖的代码必须是可移植 CL，不能用 kiln 特有的扩展。

   **宏和 `eval-when` 怎么执行**：宏函数会调用目标环境里定义的辅助函数，所以不能直接交给 SBCL 的 `compile`。倾向使用 Common-boot 的 HIR 求值器，因为它和 kiln 的前端一致，SICL 现在也这样做。Maclina `vm-cross` 作为备选。对比见 [05 §7.3](05-sicl-survey.md#73-需要修正-kiln-原计划的地方)。

   **编译期的 CLOS**：被交叉编译的库在编译期需要 `defclass`、`defgeneric`、`define-condition` 的副作用，这部分直接用宿主 CLOS（通过 closer-mop），并且和 image 里的目标 metaobject 严格分开。SICL 的 E1 就是这样做的。

2. **交换格式是 KIR（M0 修订）。**
   原计划用 CLIF 文本，M0 改成了 KIR：一种 s-expression 形式的低级 IR，由 kiln-cg 通过 cranelift-frontend 构建 Cranelift IR，这样能直接用上 SSA 构建和栈图溢出。原因和语法见 [06-m0-abi.md](06-m0-abi.md)。需要看 CLIF 时用 `--dump-clif`。

3. **初始堆由启动时的 init 函数构建，不做堆快照。**
   符号、包、初始 metaobject 都按顶层形式的顺序，在 kiln0 启动时创建，类似按顺序执行 fasl。这样和 MMTk 配合最简单。以后想加快启动，再把常量数据放进 `.rodata`。

4. **CLOS 在目标端 bootstrap，不在宿主端做。**
   SICL 在宿主里构造多层环境，让宿主运行目标的 CLOS 代码生成 metaobject，这套机制很复杂。kiln 从第一天起就有自己的 runtime，所以可以用 PCL 式的 early 函数：先用非泛函的引导函数建出核心类和泛函，再切换到完整的 MOP。

   调研确认这条路可行：SICL 拒绝它是出于追求优雅，不是因为不可行（[05 §7.3](05-sicl-survey.md#73-需要修正-kiln-原计划的地方)）。

   **新风险**：Clostrophilia 在运行期用 `compile nil` 生成判别函数和有效方法，而 kiln0 在 M5 之前不带编译器。要在 M4 之前选定方案：宿主侧 satiation、分派自动机解释器、内置字节码 VM，或者转发给远程 JIT。

5. **同时保留远程 JIT 模式。**
   SBCL 端编译，通过 socket 发给正在运行的 kiln runtime，由 cranelift-jit 执行。自举完成之前，靠它做交互式开发和调试 runtime。

6. **始终保留从 SBCL 构建的路径。**
   和 SBCL 自己一样：自举完成后，日常构建可以用 kiln 自己，但 CI 里保留一条从 SBCL 从头构建的路径，保证可复现。

## 目标端的加载顺序

先有 CLOS，再装依赖泛函的库。交叉编译阶段 reader 在宿主里运行，没有这个问题，只有在目标端加载时才需要排好顺序。

```
kernel 原语和 primop（cons/symbol/vector/funcall/闭包/GC）
 → 类层次骨架（Clostrophilia、Regalia、数值、cons）
 → Acclimation、Ecclesia
 → Predicament + kiln 的 condition 类和 define-condition
 → CLOS 早期引导 → 完整 MOP（Clostrophilia）
 → ctype（kiln client；它在载入时就创建实例，要放在 CLOS 之后）
 → Common-macros、Regalia、Constrictor、Khazern
 → 符号、包、数值塔、Quaviver、字符、字符串
 → Consecution、Salmagundi、Trinsic + Cyclosis、Anatomicl
 → Eclector、Incless、Inravina、Invistra
 → pathname、文件、编译器（前端 + 中后端）
 → 自举完成
```

几乎所有模块都依赖 CLOS，这一点 SICL 也承认（[05 §6.4](05-sicl-survey.md#64-sicl-实际的载入顺序)）。所以 CLOS 之前只能放 kernel 原语和手写的引导代码。

## 里程碑

| 阶段 | 内容 | 主要验证点 |
|---|---|---|
| M0 ✅ | SBCL 生成 KIR，Rust 编译，跑通几个函数 | 调用约定、context 寄存器、非局部退出方案。已完成，见 [06-m0-abi.md](06-m0-abi.md) |
| M1 ✅ | kernel 原语和 MMTk，加上 `%switch-stack` 测试 | 精确栈图、多栈扫描、展开到分界点（C2、C3、C5、C8）。已完成，见 [07-m1-gc.md](07-m1-gc.md) |
| M2 | 前端接入：Eclector、CST、Trucler、Common-boot/Iconoclast 和 Clostrum 目标环境（进行中，见 [08](08-m2-front-end.md)） | 所有特殊形式都能降级，宏在宿主中执行 |
| M3 | ANSI 核心库交叉编译 | 数值塔、符号、Unicode 字符、字符串、pathname 都要自己写，工作量比原先估计的大 |
| M4 | CLOS 引导，接入打印器、FORMAT、LOOP | 目标端 MOP 能自洽，重定义屏障（C4），自举完成前的运行期 `compile` 方案 |
| M5 | 编译器自身交叉编译，kiln0 → kiln1 → kiln2 | 两代产物一致 |
| M6 | SLYNK/Swank 接入 | 完整的 image 开发体验，REPL 中断 |

之后依次是：seal、WPO 和 AOT 交付；异步（[03-async.md](03-async.md)）。

**风险最大的是 M0 和 M1**：调用约定和栈图一旦定错，后面全部要返工，所以要最早验证。**工作量最大的是 M3 和 M4**，但基本是体力活。

## Lisp 依赖

- SICL 生态的模块和 Quicklisp 里没有的传递依赖，按 URL、分支、commit 固定在仓库根目录的 `deps.lock` 里。`tools/fetch-deps.sh` 把它们 clone 到 `deps/`（不提交；可以用 `KILN_DEPS_DIR` 指向别处），`--check` 只检查 commit 是否一致。
- 其余依赖（closer-mop、let-plus、more-conditions 等）从 Quicklisp 获取。
- `tools/env.lisp` 设置 ASDF 的 source registry，之后用 `ql:quickload` 加载。
- 不用 submodule，也不 vendor 进仓库：部分模块没有许可证文件（见 05 §7.3）。
- **s-expression-syntax 必须用 `beach` 分支**。Common-macros 和 Common-boot 用到的 `ses:unparse` 只在这个分支上，默认分支 `builder-protocol` 没有。SICL 的 `get-dependencies.sh` 没有写明这一点。
- parser.packrat 不在 Quicklisp 里，s-expression-syntax 依赖它（它自己的 CI 也是单独 clone 的）。

## 仓库结构（初步）

```
kiln/
├── docs/              设计文档
├── lisp/              Lisp 源码（M0 时还是平铺的，M2 起按下面的划分拆分）
│   ├── host/          只在 SBCL 宿主中运行的部分（交叉编译驱动、Clostrum 环境）
│   ├── compiler/      编译器（宿主和目标共用，必须是可移植 CL）
│   └── target/        目标端标准库（kernel、数值、condition、CLOS……）
├── rust/              Rust workspace（根目录的 Cargo.toml）
│   ├── kiln-cg/       代码生成：KIR → Cranelift（JIT / object）
│   ├── kiln-rt/       runtime：context、unwinder，以后加 MMTk、栈、FFI trampoline
│   └── kiln-launcher/ AOT 可执行文件的 C main
├── tests/m0/、m2/     端到端测试
├── tools/test.sh      测试脚本
└── kiln.asd           SBCL 端的 ASDF 系统
```

## 待定问题

- 编译器内部 IR 的形态：从 `simplify-ast` 的输出降到自研的 SSA IR。动态环境是否像 SICL 的 HIR 那样作为 SSA 值显式传递（对以后的续延有用）？Hirundine 的节点类是否作为命名参考？
- 自举完成前的运行期 `compile` 由谁提供（见上文“新风险”）。
- 对象表示：采用 rack 间接。类指针放在 header 还是 rack 里？倾向放进 rack，header 空出的字存身份哈希。
- 远程 JIT 模式的协议：自定义二进制协议，还是复用 SLYNK 通道？
- SBCL 和 Rust 之间：M0 用文件交换 KIR，之后是改成 socket，还是通过 FFI 把 kiln-cg 作为 cdylib 载入 SBCL？
