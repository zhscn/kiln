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

## 状态

M0、M1 已完成：SBCL → KIR → Cranelift（JIT 和 AOT），MMTk 移动式 GC 和精确栈图，多栈段和跨栈展开。M2 基本完成（[08](08-m2-front-end.md)）。M3 进行中：字符、字符串、向量、用 Lisp 写的 kernel 和多模块链接已经可用，下一步是包（[09 §1](09-m3-kernel.md#1-分步)）。各文档的“待定问题”一节列出尚未决定的事项。

## 约定

- **决定**：已经确定，修改前需要先更新文档。
- **约束**：实现必须遵守的规则，违反会导致后续设计无法实现。
- **待定**：尚未决定，附带倾向和需要验证的内容。
