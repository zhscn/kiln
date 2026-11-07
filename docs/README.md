# kiln 文档

kiln 是一个现代 Common Lisp 实现：开发时是完整的活 image，交付时是经过整体优化和裁剪的静态原生二进制。

- `design/`：系统现在的样子和理由。改代码时同步更新。
- `research/`：调研和测量，每篇注明日期，不随代码更新。
- [roadmap.md](roadmap.md)：里程碑、优先级、性能计划、项目工具和包管理的计划、还没做的事。

## design/

| 文档 | 内容 |
|---|---|
| [positioning.md](design/positioning.md) | 定位、目标与非目标、开发期和交付期、seal 的语义 |
| [runtime-constraints.md](design/runtime-constraints.md) | 底层约束 C1–C8 和检查清单，内存模型 |
| [modules.md](design/modules.md) | 复用哪些 SICL 模块、kiln 的五个模块和加载顺序、运行期的包、Lisp 依赖 |
| [objects.md](design/objects.md) | 值的 tag、立即数、堆对象的 kind 和布局、静态对象、身份哈希 |
| [abi.md](design/abi.md) | 调用约定、context 布局、动态环境条目、非局部退出和 unwinder、特殊变量、多值、poll 点 |
| [abi-policy.md](design/abi-policy.md) | ABI 不承诺跨版本兼容、ABI 指纹、编译期依赖 |
| [codegen.md](design/codegen.md) | KIR 语法、kiln-cg（JIT、目标文件、多模块、模块信息、运行期编译） |
| [gc.md](design/gc.md) | MMTk binding、root、栈图、编译器的 GC 规则、内联分配、栈和栈段 |
| [front-end.md](design/front-end.md) | Eclector 到简化后的 AST、顶层形式处理、编译期环境（cross-client、image-client）、inline、确定性 |
| [lowering.md](design/lowering.md) | AST 到 KIR：闭包、退出点、多值、原语和 `%primop`、降级时的改写 |
| [kernel.md](design/kernel.md) | kernel 模块：钩子、数、字符串、类型、序列、运行期的宏环境和错误 |
| [clos.md](design/clos.md) | CLOS：vendor Clostrophilia、目标端引导、分派和缓存、类的重定义、实例初始化和 `make-instance` 的快路径、类名 `typep` |
| [stdlib.md](design/stdlib.md) | condition、哈希表、包、ctype、数组、结构、LOOP |
| [io.md](design/io.md) | 系统接口、流、pathname 和文件、reader、打印器、FORMAT、美化打印 |
| [eval-compile.md](design/eval-compile.md) | eval 模块（Maclina）、原生 `compile`/`eval`/`load`、image 模式的 KIR |
| [bootstrap.md](design/bootstrap.md) | 自举（stage0 → kiln0 → kiln1）、构建程序和清单、测试方式、仓库结构 |
| [heap-image.md](design/heap-image.md) | 堆快照：固定地址、静态根、运行期代码区、GC 扫描快照区 |
| [debugging.md](design/debugging.md) | 函数和调用点的调试信息、变量的栈槽、走栈接口、采样和分配分析器、定义记录和单步的方案 |
| [backend-protocol.md](design/backend-protocol.md) | `kiln.sys:serve`：任务、嵌套的 debug 层、消息格式、`tools/kiln-server.sh` |
| [dependencies.md](design/dependencies.md) | image 里定义的依赖追踪：依赖的种类、失效、提前截断 |
| [specialization.md](design/specialization.md) | 推测、守卫和失效（草案）：统一现有的各种缓存、生成代码代替手写闭包、编译结果的缓存、seal 时折叠 |
| [async.md](design/async.md) | 异步模型（未实现）：一次性续延和 condition 系统的统一、被否决的方案 |
| [rust-interop.md](design/rust-interop.md) | Rust 宿主模块和双向互操作（草案）；交付时生成唯一的 staticlib 静态链接 |
| [editor.md](design/editor.md) | 编辑器和 IDE KilnWorks（草案）：架构、显示管线、对运行时的需求、扩展模型 |

## research/

| 文档 | 日期 | 内容 |
|---|---|---|
| [sicl-survey.md](research/sicl-survey.md) | 2026-11-03 | SICL 现状：自举、编译器、对象表示、模块生态、ANSI 覆盖、对 kiln 的影响；文末有更新步骤。涉及 SICL 的问题先查这里 |
| [clostrophilia.md](research/clostrophilia.md) | 2026-11 | Clostrophilia 的规模、要实现方提供的东西、缺陷 |
| [modern-practices.md](research/modern-practices.md) | 2026-11 | 可借鉴的现代编译器实践（含项目工具和包管理的问题分析）和暂不采用的做法 |
| [performance.md](research/performance.md) | 2026-11 | 和 SBCL 的对比、cl-bench、自举速度的变化、各基准的测量 |
| [dotnet-runtime-async.md](research/dotnet-runtime-async.md) | 2026-11 | .NET 的 runtime async 和对 kiln 拷栈方案的启发 |
| [swift-abi.md](research/swift-abi.md) | 2026-11 | Swift 的 ABI 稳定化和 kiln 的对照 |
| [zig-incremental.md](research/zig-incremental.md) | 2026-11 | Zig 的增量编译和 kiln 的依赖追踪的对照 |
| [debugging-references.md](research/debugging-references.md) | 2026-11 | LispWorks dspec、Emacs、Racket、Clordane 的调试设施 |

## 约定

- **决定**：已经确定，修改前先更新文档。
- **约束**：实现必须遵守的规则，违反会导致后续设计无法实现。
- **待定**：尚未决定，附带倾向和需要验证的内容。
- 文档之间用文件名和标题互相引用，不用节号。
- 不写本机路径；仓库内的路径（`lisp/...`、`rust/kiln-rt/src/...`）可以写。
