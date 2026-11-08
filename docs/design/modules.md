# 复用的模块和 kiln 的模块划分

## 决定

- **复用 SICL 生态里的独立模块，不复用 SICL 本体。** SICL 本体的 bootstrap 和它自己的对象表示、GC 设计、代码生成绑得很紧，至今没有原生后端，也不产出 image（[sicl-survey.md](../research/sicl-survey.md)）。kiln 的底层约束（context 指针、Cranelift、MMTk、精确栈图、帧可搬动）和它不同。真正有价值的是 s-expressionists 那批为“装进新实现”而写的模块。先例是 Clasp：复用 Eclector 和 Cleavir，后端自己接 LLVM。
- **AST 以下的编译器、对象表示、runtime 全部自己写。** 非局部退出、`unwind-protect`、context、poll 点、栈图都在这一层定义，SICL 在这一层只有设计文字。
- **vendor 规则**：要改的模块先原样 vendor 进 `vendor/` 一个提交，再打补丁；补丁记在 `vendor/README.md`，不往上游提。不改的模块按 `deps.lock` 固定 commit。

## 复用和自研的划分

| 部分 | 来源 | 用法 |
|---|---|---|
| Reader | Eclector（vendor） | 宿主前端的 reader；目标端编进 CLOS 模块（[io.md](io.md)） |
| 语法树 | Concrete-Syntax-Tree | 带源码位置，debugger 和报错都需要 |
| 全局环境 | Clostrum | 交叉编译的编译期环境，隔离宿主和目标 |
| 词法环境查询 | Trucler | |
| 前端（CST 到 IR）、编译期求值 | 自研（`lisp/ir/`，[ir.md](ir.md)） | 原来用 Common-boot 的 cst-to-ast、Iconoclast 的 AST 和 HIR 求值器，已换掉 |
| 标准宏 | Common-macros（vendor） | 编译期展开；运行期由 eval 模块提供 |
| 代码解析工具 | Ecclesia | lambda list 解析等 |
| 类型 | ctype（vendor） | kiln 自己的 client，否则会默认使用 SBCL 的 fixnum 范围和 UAET |
| 数组 | Regalia（vendor） | 只用于非 simple、多维、特化的数组；simple-vector 和 simple-string 是原生对象 |
| 结构 | Anatomicl | 宿主库，宏展开时运行 |
| 哈希表 | Salmagundi（vendor） | 补了基于 header 的身份哈希，表改成开放寻址 |
| 流 | Cyclosis（vendor） | 补了 fd 系统调用和缓冲 |
| 包 | Parcl（vendor） | intrinsic 方式加载 |
| LOOP | Khazern（vendor） | 宿主展开交叉编译的 LOOP；目标端编进 CLOS 模块 |
| FORMAT | Invistra（vendor） | |
| 打印器、pretty printer | Incless、Inravina（vendor） | |
| 浮点打印 | Quaviver | 现在用 kiln 自己的替身（[io.md](io.md)） |
| Condition 系统 | Predicament（vendor） | kiln 自己写 `condition` 类和 `define-condition` |
| CLOS / MOP | Clostrophilia（vendor） | 在目标端用 early 函数 bootstrap（[clos.md](clos.md)） |
| 字节码求值器 | Maclina（vendor） | eval 模块：运行期的编译期求值、交付期可选的轻量 `eval` |
| 序列、cons 字典 | Consecution、Constrictor | 还没有接入，现在是 kernel 的简单实现 |
| 数值塔 | 自研 | Rust runtime 原语，Lisp 包一层（SICL 也没有 bignum） |
| 符号、字符、字符串、pathname、文件、时间 | 自研 | 没有现成的模块 |
| 降级、代码生成、runtime | 自研 | |

**许可证**：部分 SICL 模块的仓库里没有许可证文件（[sicl-survey.md](../research/sicl-survey.md)）；kiln 用到的模块都要确认。

## kiln 的五个模块

kiln 的 Lisp 代码编成五个模块，按顺序载入，每个模块只编译一次；用户程序是排在后面的模块。文件列表在 `lisp/driver.lisp`。

| 模块 | 内容 | 测试前缀 |
|---|---|---|
| kernel | `lisp/target/*.lisp`（[kernel.md](kernel.md)） | 所有测试 |
| clos | Clostrophilia 和 CLOS 引导，Predicament、Salmagundi、Parcl、ctype、Regalia、Anatomicl 的目标端部分、Trinsic、Cyclosis、文件和 pathname、Acclimation、Incless、Inravina、Invistra、Khazern、alexandria、Eclector 的 reader，以及调试接口 | `clos-` |
| frontend | Concrete-Syntax-Tree、Eclector 的 parse-result 和 CST 读取器 | `fe-` |
| eval | Ecclesia、Common-macros（运行期标准宏）、Trucler、Maclina、`lisp/target/eval/`（evaluator、REPL、后端协议） | `ev-` |
| compiler | Trucler reference、Clostrum、Anatomicl，以及 kiln 自己的 `lisp/*.lisp`、`lisp/ir/` 和 `lisp/target/compiler/` | `co-` |

frontend 不进 CLOS 模块，以免拖慢所有 CLOS 测试的启动。

### 加载顺序

先有 CLOS，再装依赖泛函的库。交叉编译阶段 reader 在宿主里运行，没有这个问题，只有在目标端加载时才需要排好顺序。

```
kernel 原语和 primop（cons/symbol/vector/funcall/闭包/数/字符串/typep/序列）
 → CLOS 早期引导（braid、early 泛函）→ Clostrophilia 的其余部分 → 切换到完整 MOP
 → Predicament + kiln 的 condition 类、运行期错误
 → Salmagundi → Parcl（包）→ ctype → Regalia → 结构、change-class
 → Trinsic + Cyclosis → Incless、Inravina → Acclimation、Invistra
 → pathname、文件、时间、快照、调试接口 → Khazern → alexandria、Eclector
 → frontend → eval（Ecclesia、Common-macros、Trucler、Maclina）→ compiler
```

精确的顺序以 `lisp/driver.lisp` 为准。几乎所有模块都依赖 CLOS，所以 CLOS 之前只能放 kernel 原语和手写的引导代码。ctype 在载入时就创建实例，要放在 CLOS 之后；Regalia 选数组类要用 `subtypep`，所以在 ctype 之后。

## intrinsic 加载和包

SICL 的库有 intrinsic（库就是实现自己的版本，直接定义 `CL` 包里的符号）和 extrinsic（库定义在自己的包里，和宿主并存）两种用法。kiln 的目标端一律用 intrinsic 方式，CL 的函数就是这些库的函数；接口层由 kiln 写在 `lisp/target/clos/` 下的 client 文件里。

**运行期的包镜像宿主的包**：目标源码由宿主的 Eclector 读进宿主的包（`defpackage` 在宿主执行），所以宿主的包结构就是目标程序的包结构。上游 intrinsic 接口里依赖加载时包操作的部分（`shadowing-import` 进 CL 等）做不了，补丁让这些库直接使用 CL 的 symbol。

**模块的符号表**：每个模块编译完后，编译器生成一张 symbol 表，记下两类包：模块里 symbol 的 home 包，和模块的 `defpackage` 处理过的包。每个包记录：

- 名字、昵称、use 列表（只保留运行期存在的包）；
- 模块里每个在该包中 present 的 symbol 及其状态（internal/external、是否 shadowing、该包是否是它的 home 包）；
- 包局部昵称（只保留指向运行期存在的包的，按昵称排序）。

`defpackage` 处理过的包，它的外部 symbol，以及它从运行期存在的包 import 的 symbol，都放进表里，哪怕模块没有引用：import 的宏在编译时已经展开，代码里不再出现，但运行期在这个包里读源码时要用到。kernel 额外带上 CL 的全部 978 个外部 symbol，运行期每个标准 symbol 都存在。宿主的 `KILN-USER`（测试程序读入的包）在运行期叫 `COMMON-LISP-USER`，昵称 `CL-USER`，use KILN.SYS；CLOS 模块一开始就按这个描述建它。

**加载时**：模块的 init 函数第一件事是把这张表推到 `kiln.kernel::*module-symbol-tables*`，`%register-module-symbols` 已经定义时就调用它。CLOS 模块加载完 Parcl 和 client 后自己调用一次，把 kernel 和 CLOS 模块的表登记成包对象：新建 Parcl 的包对象，填好符号表、use 列表和包局部昵称（宿主已经检查过冲突，直接写入），把每个 symbol 的 `package` 槽从包名字符串换成 home 包对象。之后加载的模块在 init 开头就完成登记。运行期编进 image 的代码没有符号表，符号都已经在 image 里（[eval-compile.md](eval-compile.md)）。

**closer-mop**：用 closer-mop 的库在宿主里读入，读到的是宿主 CLOSER-MOP 包的符号。宏 `kiln.sys::closer-mop-aliases` 展开成一次 `kiln.sys::%alias-names` 调用：对 CLOSER-MOP 的每个外部符号，取 Clostrophilia 里可访问的同名符号，运行期在后者有定义时，把函数、setf 函数和类给前者（`closer-mop.lisp`）。kiln 的 image 里因此也有 CLOSER-MOP 包，Maclina 等直接使用。

## Lisp 依赖

- SICL 生态的模块和 Quicklisp 里没有的传递依赖，按 URL、分支、commit 固定在仓库根目录的 `deps.lock` 里。`tools/fetch-deps.sh` 把它们 clone 到 `deps/`（不提交；`KILN_DEPS_DIR` 可以指向别处），`--check` 只检查 commit 是否一致。
- 其余依赖（closer-mop 等）从 Quicklisp 获取。`tools/env.lisp` 设置 ASDF 的 source registry，`vendor/` 先于 `deps/` 被找到。
- 不用 submodule。没改的模块也不 vendor：部分模块没有许可证文件。
