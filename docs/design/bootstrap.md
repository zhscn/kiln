# 自举和构建

## 决定

- SBCL 只做宿主：在 SBCL 里运行 kiln 编译器，交叉编译出第一个 kiln（kiln0），之后 kiln 编译自己。
- 用 Clostrum 建一个独立的编译期环境隔离宿主和目标（SBCL 自己靠 `sb-xc` 包重命名，SICL 靠一等环境；kiln 选后者）。目标里重定义 `car`、`defclass` 都不会碰到宿主。宏在编译期执行，所以宏展开函数及其依赖的代码必须是可移植 CL。
- **始终保留从 SBCL 构建的路径**：和 SBCL 自己一样，日常构建可以用 kiln 自己，但从 SBCL 从头构建的路径要一直能用，保证可复现。
- **初始堆由启动时的 init 函数构建**：符号、包、初始 metaobject 都按顶层形式的顺序，在启动时创建，类似按顺序执行 fasl。这和 MMTk 配合最简单。想跳过初始化时用堆快照（[heap-image.md](heap-image.md)）。
- **CLOS 在目标端 bootstrap**，不在宿主里做（[clos.md](clos.md)）。

## 路线

```
SBCL 宿主
 ├─ 载入 kiln 系统（kiln.asd）：Eclector、CST、Trucler、Common-boot、Iconoclast、
 │   Clostrum、Common-macros、Khazern、Anatomicl，加上 lisp/*.lisp
 ├─ cross-client：Clostrum 编译期环境，编译期求值用 Common-boot 的 HIR 求值器
 └─ stage0：五个模块和构建程序的 KIR，加上清单 modules.lisp-expr
        ↓ kiln-cg obj，和 launcher 链接
kiln0 ──运行构建程序──▶ stage1 ──kiln-cg──▶ kiln1 ──▶ stage2
```

`tools/bootstrap.sh`（`--from-stage1` 从 stage1 开始）做完整的自举，结果在 `build/boot/`：

| 阶段 | 做什么 | 要求 |
|---|---|---|
| stage0 | SBCL 在一个会话里编五个模块和构建程序（`kiln:bootstrap-stage0`），写出 `NAME.kir` 和清单 | |
| kiln0 | stage0 的 KIR 用 `kiln-cg obj` 编成一个目标文件，和 launcher 链接成 AOT 可执行文件 | |
| stage1 | 在一个目录里运行 kiln0：读清单，依次编五个模块和构建程序自己 | 每个 KIR 和 stage0 逐字节相同 |
| kiln1 | stage1 的 KIR 链接成可执行文件 | 和 kiln0 逐字节相同 |
| stage2 | 运行 kiln1 | 和 stage1 逐字节相同 |

`tools/stage0-kiln.sh [DIR]` 只做 stage0 和 kiln0，用来试编译器或 CLOS 的改动；配合只含部分模块的清单单独计时。

## 构建程序和清单

构建程序 `lisp/target/build.lisp` 是一个普通的程序模块（名字是 `build`），在 compiler 模块之后，由 SBCL 在 stage0 里用同一个会话编译，所以 kiln1 完全由 kiln 编出。它在 kiln 上做的事和 SBCL 一样：一个 `cross-client` 会话，kernel 带上 CL 的全部外部符号，编 compiler 模块之前调用 `prepare-compiler-session`（宿主宏、`defrule` 和 `define-syntax` 只在加载时定义、`host-inline-functions`，`lisp/cross.lisp`），按 `muffle-warning` 处理警告。它不依赖 SBCL 才有的东西：

- **文件列表**放在清单 `modules.lisp-expr` 里，由 stage0 写出：每个模块的名字和源文件，格式就是 `front-end` 接受的格式（路径是 namestring，`:renames`、`:compile-time-too` 原样保留），作用类似 SBCL 的 `build-order.lisp-expr`。SBCL 会话里的 `kiln.compiler::module-files` 是展开时用 ASDF 的宿主宏；构建程序在编 compiler 模块之前也注册同名的宿主宏，展开成清单里的文件列表。
- **输出**写到当前目录的 `NAME.kir`。
- 设了 `KILN_SERVE` 时，构建程序不做构建，改为在标准输入输出上运行后端协议（[backend-protocol.md](backend-protocol.md)）。
- 设了 `KILN_SAVE_IMAGE` 时，编完五个模块就保存堆快照，然后照常编后面的程序。快照的 toplevel 重新读入清单，只编五个模块之后的条目。

## 确定性

两代产物逐字节相同的前提是 KIR 输出**确定**：不依赖哈希表的遍历顺序、gensym 计数器在编译之外的状态、宿主里碰巧共享的结构、宿主的包名。前端和降级为此做的事见 [front-end.md](front-end.md) 的“确定性”，kiln-cg 的见 [codegen.md](codegen.md)。逐字节比较也作为编译器的回归检查保留。

## 测试

`tools/test.sh [FILE.lisp...]`：

- SBCL 在一个会话里编五个模块和 `tests/*/*.lisp`，每个测试按文件名前缀和需要的模块一起运行（[modules.md](modules.md)），走 JIT、GC 压力、AOT 三遍，和 `.expected` 比较。
- `NAME.slow`（内容是堆大小）：慢测试，只在命令行点名时跑，只跑 JIT 一遍。`tests/m5/co-clos`、`co-frontend`、`co-eval`、`co-compiler` 是 kiln 交叉编译 kiln 的各个模块。
- `NAME.same-kir`（内容是另一个测试名）：期望输出是同一个 SBCL 会话里编出的那个测试的 KIR，不必提交 KIR 文件。`co-kernel` 等用它验证 kiln 编出的 KIR 和 SBCL 的相同。
- `NAME.image`、`NAME.image2`：堆快照测试（[heap-image.md](heap-image.md)）。
- 测试源文件以绝对路径交给 SBCL，因为文件名写进了 KIR 的调试信息；比较 KIR 的测试在 kiln 上也用同样的名字。

**由 kiln 编译测试**：`KILN_COMPILER=build/boot/kiln1 tools/test.sh` 让 SBCL 只写清单（`kiln:write-manifest`：五个模块，测试文件作为程序模块排在后面），kiln 运行构建程序，在一个会话里编完五个模块再编各个测试，之后照常走三遍。第一次先编五个模块并存快照 `build/test/kiln-compiler.img`，旁边的 `.key` 是 kiln 可执行文件和五个模块全部源文件的哈希；键相同时直接从快照启动。

## 仓库结构

```
kiln/
├── docs/              设计文档、调研、路线图
├── lisp/              编译器（宿主和 kiln 共用，可移植 CL）：front、cross、lower、kir、abi、
│   │                  primitives、values、structures、macro-client、driver
│   └── target/        目标端的 Lisp 源码：kernel、clos/、eval/、compiler/、build.lisp
├── rust/
│   ├── kiln-cg/       KIR → Cranelift（JIT、目标文件、运行期 JIT 库）
│   ├── kiln-rt/       runtime：context、GC、unwinder、栈、数、系统调用、调试信息、快照
│   └── kiln-launcher/ AOT 可执行文件的 C main
├── vendor/            打了补丁的 SICL 生态模块（vendor/README.md）
├── tests/             端到端测试
├── bench/             基准
├── tools/             test.sh、bootstrap.sh、repl.sh、kiln-server.sh 等
├── deps.lock          依赖的固定版本
└── kiln.asd           SBCL 端的 ASDF 系统
```
