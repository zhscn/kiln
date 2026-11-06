# kiln 设计文档

kiln 是一个现代 Common Lisp 实现：开发时是完整的活 image，交付时是经过整体优化和裁剪的静态原生二进制。

| 文档 | 内容 |
|---|---|
| [01-positioning.md](01-positioning.md) | 定位、目标与非目标、开发期和交付期的边界 |
| [02-runtime-constraints.md](02-runtime-constraints.md) | 底层约束：从第一天起必须遵守，为 GC、异步、重定义留出空间 |
| [03-async.md](03-async.md) | 异步模型：一次性定界续延和 condition 系统的统一，以及被否决的方案 |
| [04-bootstrap.md](04-bootstrap.md) | 复用与自研的划分、借助 SBCL 的自举路线、里程碑 |
| [05-sicl-survey.md](05-sicl-survey.md) | SICL 现状调研（2026-11）：自举、编译器、对象表示、模块生态、ANSI 覆盖情况、对 kiln 的影响 |
| [06-m0-abi.md](06-m0-abi.md) | M0 定下的 ABI：值表示、调用约定、context 布局、非局部退出（try_call + unwinder）、poll 点、KIR 语法 |
| [07-m1-gc.md](07-m1-gc.md) | M1：对象表示、MMTk binding、精确栈图、root 集合、编译器必须遵守的 GC 规则 |
| [08-m2-front-end.md](08-m2-front-end.md) | M2：Common-boot 前端、顶层形式处理和编译期环境、AST 降级、闭包和非局部退出 |
| [09-m3-kernel.md](09-m3-kernel.md) | M3：分步计划、立即数和堆对象的 kind 表、`%primop`、kernel |
| [10-m4-clos.md](10-m4-clos.md) | M4：CLOS 引导，复用 Clostrophilia 的方式、分派的解释执行、实例表示、分步计划 |
| [11-m5-self-hosting.md](11-m5-self-hosting.md) | M5：编译器在 kiln 上运行和自举的分步计划，目标端 `eval`/`compile`（Maclina），调试基础设施的数据格式（定义记录、调用点源码位置、宏展开追踪） |
| [12-abi-policy.md](12-abi-policy.md) | ABI 的稳定性方针：同一构建内部的契约、不承诺跨版本兼容、ABI 指纹、内联依赖，和 Swift ABI 稳定化的对照 |
| [13-modern-practices.md](13-modern-practices.md) | 可借鉴的现代编译器实践：构建期初始化和堆快照、依赖追踪和增量重编译、PGO 和内联缓存、逃逸分析和拆箱、并行编译和缓存、诊断和工具协议、测试方法；暂不采用的做法；内存模型；优先级 |
| [14-performance.md](14-performance.md) | 和 SBCL 的性能差距：对比基准（`bench/compare.lisp`）、差距集中在库和 CLOS 运行时而不是代码生成、需要的 Lisp 语义层优化 |

## 状态

M0、M1 已完成：SBCL → KIR → Cranelift（JIT 和 AOT），MMTk 移动式 GC 和精确栈图，多栈段和跨栈展开。M2 基本完成（[08](08-m2-front-end.md)）。M3 完成（[09](09-m3-kernel.md)）：用 Lisp 写的 kernel 单独作为一个模块，数值塔（bignum、ratio、单双精度浮点）、Unicode 字符和字符串、`typep` 和序列函数都已可用；包、数组、哈希表、condition 移到 M4。M4（CLOS 引导）完成（[10](10-m4-clos.md)）。M5 完成（[11](11-m5-self-hosting.md)）：运行期的标准宏、`eval`、`compile`、`load` 和 REPL（`tools/repl.sh`）；编译器在 kiln 上运行，交叉编译 kiln 自己的五个模块，KIR 和 SBCL 编出的逐字节相同；自举闭合：kiln0 → kiln1 → kiln2 的 KIR 逐字节相同，kiln0 和 kiln1 的可执行文件也相同（`tools/bootstrap.sh`），测试程序由 kiln1 编译时 `tools/test.sh` 全部通过；M5.5 起 `compile` 产出原生代码，装进运行中的 image。和 SBCL 的性能对比见 [14](14-performance.md)。各文档的“待定问题”一节列出尚未决定的事项。

## 约定

- **决定**：已经确定，修改前需要先更新文档。
- **约束**：实现必须遵守的规则，违反会导致后续设计无法实现。
- **待定**：尚未决定，附带倾向和需要验证的内容。
