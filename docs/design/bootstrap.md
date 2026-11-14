# 自举和构建

## 决定

- SBCL 只做宿主：在 SBCL 里运行 kiln 编译器，交叉编译出第一个 kiln（kiln0），之后 kiln 编译自己。
- 用 Clostrum 建一个独立的编译期环境隔离宿主和目标（SBCL 自己靠 `sb-xc` 包重命名，SICL 靠一等环境；kiln 选后者）。目标里重定义 `car`、`defclass` 都不会碰到宿主。宏在编译期执行，所以宏展开函数及其依赖的代码必须是可移植 CL。
- **始终保留从 SBCL 构建的路径**：和 SBCL 自己一样，日常构建可以用 kiln 自己，但从 SBCL 从头构建的路径要一直能用，保证可复现。
- **初始堆由启动时的 init 函数构建**：符号、包、初始 metaobject 都按顶层形式的顺序，在启动时创建，类似按顺序执行 fasl。这和 MMTk 配合最简单。想跳过初始化时用堆快照（[heap-image.md](heap-image.md)）。
- **CLOS 在目标端 bootstrap**，不在宿主里做（[clos.md](clos.md)）。

## 目标协议与自举范围

自举默认写出 `.lir` 二进制封套，当前载荷是迁移中的兼容程序。SBCL 使用可移植编码器，kiln 使用 native 记录构造器，两者按同一规则分配编号并去重原子。布局无关的 LIR 操作继续在此协议上迁移。SBCL 写 stage0 文件后调用 kiln-cg 子进程，不通过 FFI 载入 Rust 库；kiln 的后续阶段也写相同格式。运行期原生编译使用同一 schema 的内存入口，见 [compiler-protocol.md](compiler-protocol.md)。

Rust 后端由 Cargo 构建并在各阶段共用。LIR 逐字节闭合验证 Lisp 编译器、表示选择与导出的确定性，最终二进制闭合同时检查固定后端处理相同输入的确定性；这不证明 Rust 后端自身经过 Lisp 自举。后端另以独立样本、旧 KIR 对照和执行验证覆盖。

## 当前路线

```
SBCL 宿主
 ├─ 载入 kiln 系统（kiln.asd）：Eclector、CST、Trucler、Clostrum、Common-macros、
 │   Khazern、Anatomicl，加上 lisp/*.lisp
 ├─ cross-client：Clostrum 编译期环境，编译期求值用 HIR 求值器
 └─ stage0：五个模块和构建程序的二进制 LIR 封套，加上清单 modules.lisp-expr
        ↓ kiln-cg obj，和 launcher 链接
kiln0 ──运行构建程序──▶ stage1 ──kiln-cg──▶ kiln1 ──▶ stage2
```

`tools/bootstrap.sh`（`--from-stage1` 从 stage1 开始）做完整的自举，结果在 `build/boot/`：

| 阶段 | 做什么 | 要求 |
|---|---|---|
| stage0 | SBCL 在一个会话里编五个模块和构建程序（`kiln:bootstrap-stage0`），写出 `NAME.lir` 和清单 | |
| kiln0 | stage0 的 LIR 用 `kiln-cg obj` 编成一个目标文件，和 launcher 链接成 AOT 可执行文件 | |
| stage1 | 在一个目录里运行 kiln0：读清单，依次编五个模块和构建程序自己 | 每个 LIR 文件和 stage0 逐字节相同 |
| kiln1 | stage1 的 LIR 链接成可执行文件 | 和 kiln0 逐字节相同 |
| stage2 | 运行 kiln1 | 和 stage1 逐字节相同 |

`tools/stage0-kiln.sh [DIR]` 只做 stage0 和 kiln0，用来试编译器或 CLOS 的改动；配合只含部分模块的清单单独计时。

## 构建程序和清单

构建程序 `lisp/target/build.lisp` 是一个普通的程序模块（名字是 `build`），在 compiler 模块之后，由 SBCL 在 stage0 里用同一个会话编译，所以 kiln1 完全由 kiln 编出。它在 kiln 上做的事和 SBCL 一样：一个 `cross-client` 会话，kernel 带上 CL 的全部外部符号，编 eval 和 compiler 模块之前调用 `prepare-compiler-session`（宿主宏、`defrule` 和 `define-syntax` 只在加载时定义、`host-inline-functions`，`lisp/cross.lisp`），按 `muffle-warning` 处理警告。它不依赖 SBCL 才有的东西：

- **文件列表**放在清单 `modules.lisp-expr` 里，由 stage0 写出：每个模块的名字和源文件，格式就是 `front-end` 接受的格式（路径是 namestring，`:renames`、`:compile-time-too` 原样保留），作用类似 SBCL 的 `build-order.lisp-expr`。SBCL 会话里的 `kiln.compiler::module-files` 是展开时用 ASDF 的宿主宏；构建程序在编 eval 和 compiler 模块之前也注册同名的宿主宏，展开成清单里的文件列表。
- **输出**默认写到当前目录的 `NAME.lir`。`KILN_OUTPUT_FORMAT=kir` 选择文本诊断格式；宿主 `bootstrap-stage0` 可用 `:output-format :kir` 选择相同的兼容路径。
- 设了 `KILN_SERVE` 时，构建程序不做构建，改为在标准输入输出上运行后端协议（[backend-protocol.md](backend-protocol.md)）。
- 设了 `KILN_SAVE_IMAGE` 时，编完五个模块就保存堆快照，然后照常编后面的程序。快照的 toplevel 重新读入清单，只编五个模块之后的条目。

## 确定性

两代产物逐字节相同的前提是程序记录及其编码**确定**：不依赖哈希表的遍历顺序、gensym 计数器在编译之外的状态、宿主里碰巧共享的结构、宿主的包名。前端和降级为此做的事见 [front-end.md](front-end.md) 的“确定性”，kiln-cg 的见 [codegen.md](codegen.md)。逐字节比较也作为编译器的回归检查保留。各阶段比较 LIR 文件；Rust 的布局和 ABI 降级在各阶段共用，kiln0 和 kiln1 也须逐字节相同。

## 测试

`tools/test.sh [FILE.lisp...]` 默认使用完整开发 image 测试文件编译和加载。
基础系统包含五个模块，先通过 SBCL 交叉编译并链接成一个 AOT 可执行文件，
完成初始化后保存 `build/test-fasl/base/base.img`。每个测试从同一份快照启动独立进程，
用 `compile-file` 写出 FASL，再分别从快照启动正常堆和 64 MiB 堆的进程加载该文件，
将输出与 `.expected` 逐字节比较。编译进程与加载进程相互隔离，测试之间也不共享定义。
`ev-` 用例加载期间动态关闭原生 `eval` 和 `compile` 钩子，保留 HIR 求值路径的覆盖。

交叉测试的单参数 `print` 使用 runtime 诊断打印操作，image 模式默认使用标准流打印器。
为保持同一份参考输出，测试驱动仅在文件编译进程安装 compiler macro，将单参数
`print` 映射到 base 中的诊断打印函数。加载进程没有这个 compiler macro，
运行期 `eval` 和显式指定流的 `print` 保持标准行为，输出比较不归一化空白。

FASL 保存 LIR 和字面量对象图，加载时仍由 Cranelift 生成测试自身的机器码。
共享基础系统避免每个用例重新生成并保留完整系统的目标文件和静态可执行文件。
完整环境会预先安装高层模块；需要验证最小模块环境的测试可用空的 `NAME.cross`
标记选择交叉路径。

base 可执行文件和快照必须配套使用。测试驱动按 Lisp、vendor、Rust、协议和构建工具
的内容计算缓存键，变化后重新构建二者；测试 FASL 每次重新生成。
首次构建和快照日志保存在 `build/test-fasl/base/`，各测试的编译及加载输出保存在
`build/test-fasl/`。基础模块的 LIR 在成功生成快照后删除，需要重新构建时再生成。

`tools/test.sh --cross [FILE.lisp...]` 选择独立 LIR 的完整交叉测试，
也可直接调用 `tools/test-cross.sh`。该路径在 SBCL 的同一会话里编基础模块和测试，
按文件名前缀选择依赖，分别验证 JIT、GC 压力和 AOT，并比较 `.expected`。
它覆盖静态字面量、跨模块共享对象、重定位和初始化，不能由 image 模式的 FASL 测试替代。
交叉驱动在链接完成后删除目标文件；用例的全部检查成功后删除可执行文件及测试快照，
失败时保留可执行文件和快照供排查。LIR、诊断 KIR 和执行输出继续保留。

没有 `clos-`、`fe-`、`ev-` 或 `co-` 前缀的早期测试依赖 kernel 最小环境，
也交给交叉驱动；其中的简化打印器与完整 image 的标准打印器具有不同的输出格式。
默认入口还将以下用例交给交叉驱动：

- `NAME.same-kir`：内容是同会话参考测试或模块名，比较诊断 KIR；参考测试自动加入编译会话。
- `NAME.image`、`NAME.image2`：验证保存和恢复快照及附带快照的可执行文件。
- `NAME.slow`：内容是堆大小，只在命令行点名时运行一次 JIT。
- `NAME.cross`：显式要求最小模块环境或交叉后端验证。

`KILN_COMPILER=build/boot/kiln1 tools/test.sh --cross` 用 kiln 编译交叉测试。
为保留已有命令的含义，设置 `KILN_COMPILER` 时省略 `--cross` 也选择完整交叉路径。
SBCL 只写清单，kiln 在一个交叉编译会话中生成独立 LIR 和诊断 KIR，
然后运行同样的 JIT、GC 压力和 AOT 检查。编完基础模块后的会话缓存于
`build/test/kiln-compiler.img`；缓存键涵盖编译器可执行文件和模块源码。
它用于恢复交叉编译工作，与供普通文件编译和加载使用的 base 快照分开。

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
