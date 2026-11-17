# 编译器架构

原生编译使用 **HIR → MIR → LIR**。文件模块、运行期编译、缓存和 FASL 使用独立 LIR。Lisp 生成布局无关的语义操作和控制流，规范化器建立类型化的 LIR 程序；kiln-cg 验证程序后展开布局、调用约定、动态区域、精确根和 poll，构造内部 KIR 并交给 Cranelift。结构化协议提供文件与内存入口，兼容 KIR 仍可作为诊断输入。

前端准备绑定、捕获、声明和退出等语义信息；MIR 在 CFG 和 SSA 上完成类型及区间传播、局部调用及多值摘要、函数目标传播、lambda lifting、内联、逃逸与存储选择和数值表示选择，再输出独立 LIR。HIR 求值器继续直接执行 HIR。具体证明边界和未覆盖的优化见 [mir.md](mir.md)，性能优化和后续分析扩展见 [roadmap.md](../roadmap.md)。

## 分层

```text
              Lisp（SBCL 上或 kiln 上）                       Rust（kiln-cg）
源码 → CST → HIR ──→ MIR ──→ 表示选择 ──→ LIR  ══结构化请求══▶  LIR → KIR → Cranelift → JIT / .o
        宏、环境、    CFG+SSA   装箱、存储、        布局无关         布局、ABI、    机器优化、
        绑定、声明    语义分析   闭包、多值                          GC 元数据      寄存器分配
             │
             └→ HIR 求值器（编译期执行、解释执行）
```

| 层 | 语言 | 负责 | 不负责 |
|---|---|---|---|
| HIR | Lisp | 宏和编译器宏、编译期环境、绑定身份、声明、编译期求值 | 控制流分析 |
| MIR | Lisp | CFG 和 SSA、类型与区间、调用摘要、内联、身份与逃逸、类型驱动的改写、表示选择 | tag、偏移、context 字段、调用序列 |
| LIR | 后端输入协议的程序载荷 | 表示已选定、布局无关的低层操作 | 独立的优化管线 |
| LIR → KIR | Rust | tag、对象布局、分配快路径、动态环境条目、调用约定、多值传递、poll、栈图和调试记录 | 类型推导、任何需要 Lisp 环境的决定 |
| KIR → 机器码 | Rust | Cranelift 构造、`try_call` 和异常表、寄存器分配 | |

**划分原则**：需要 Lisp 语义、类型知识或编译期环境的决定在 Lisp；需要对象布局、ABI 或 GC 元数据的决定在 Rust。LIR 是后端输入语言，也是编译协议的程序载荷，不再承担一套中端优化。它是这两类决定的分界线：它说“分配一个栈上的 cons”“读这个 simple-vector 的第 i 个元素”“这个变量是未装箱的 double”，不说 tag 是几、偏移多少、context 里哪个字。

## 为什么这样分

**MIR 留在 Lisp。** 类型传播、区间 widening、cons 和闭包的逃逸证明、局部函数身份都依赖求值顺序及路径合流。树形 HIR 需要每个分析分别解释 `tagbody`、`block`、`catch`、`unwind-protect` 的退出与合流；MIR 将它们统一为 CFG 的边，供分析共同使用。MIR 留在 Lisp 的理由：

- 类型展开与类型工具留在 Lisp：前端解析声明和类型别名，MIR 使用共享类型域及标准函数规则，不在 Rust 再实现一套 CL 类型知识库。
- 类型驱动的改写可以用 Lisp 写：类型推导之后生成 Lisp 形式，经 HIR 转换拼回 MIR（SBCL 的 deftransform 就是这种做法），并记录依赖。
- 编译器是 kiln 上最大的 Lisp 程序。它的数据结构和分析速度直接推动 kiln 本身的优化（[compiler-performance.md](compiler-performance.md)）。
- 活 image 里可以重定义、调试编译器（kiln-server、`*trace-toplevel*`），库可以扩展优化。
- Rust 边界只传表示已确定的程序和常量描述，不传类型环境或宏；宿主和 image 共享编码器，literal 的生命周期由 image 适配器管理。

**布局和 ABI 下沉到 Rust。** 如果 Lisp 发射器复制 kiln-rt 的对象和 context 布局，每次布局变化都需要同步两份定义，否则生成的代码会读写错误位置。布局定义因此集中在 kiln-rt（`object.rs`、`context.rs`），Lisp 只读取生成的语义目标描述。表示选择之后不再进行语言语义推导，但仍需完成控制流验证、safepoint 安排和低层展开：按布局展开操作，按调用约定排参数，按 GC 规则登记根。kiln-cg 承担这部分工作：

- 布局常量只有一份，ABI 指纹由同一来源计算。
- Lisp 编译器（包括 SBCL 上的交叉编译）不再知道 tag 和偏移，常量用可移植的描述输出。
- 改 ABI 只改 Rust 和 [abi.md](abi.md)，不用同时改 Lisp 发射代码。

**被否决的方案。**

- **MIR 和优化放在 Rust，Lisp 只交出 HIR**：封闭请求要求另建类型与函数摘要的同步机制；保留 Lisp 类型驱动扩展还需要额外的分阶段交互。相比之下，Lisp MIR 能直接复用语言服务，边界也能缩小到表示已确定的操作。当前没有测量证明语言迁移的性能收益足以抵消这些成本。
- **继续在 HIR 树上做分析**：见上文，每个流分析重复处理各种控制结构，分析和降级的边界也越来越难维护。
- **保持 Lisp 生成 KIR**：MIR 降级仍要经过 `lisp/primitives.lisp`、`lisp/lower.lisp` 那样的布局发射代码，ABI 常量继续维护两份。

## 运行环境

Lisp 部分照旧在两处运行：SBCL 上交叉编译（写 stage0），kiln 上编译（自举的后续阶段、运行期 `compile`/`eval`/`load`）。LIR 从第一版起采用结构化批量协议，不经过打印与文本解析：

- 文件：SBCL 写规范化的 `.lir` 二进制请求，由构建程序调用 kiln-cg 子进程生成目标文件；SBCL 不需要载入 Rust 动态库。自举默认写二进制并逐个比较确定性编码的 LIR 文件；文本仅用于显式诊断与迁移测试。
- 运行期：一次性编译批量快照结构化程序为 Rust 自有记录；FASL 和缓存载荷走字节入口。两种适配器共享程序 schema、操作校验和降级，不要求进程内请求先编码再解码。literal 向量受调用者 roots 保护，Rust 直接构造内部 KIR。现有 `kiln_rt_jit` 文本入口只是迁移期旧路径。

KIR 变成 kiln-cg 内部的数据结构；`kiln-cg dump FILE.lir` 将输入记录打印为可读形式；旧文本入口用于诊断和迁移对照。

## 实现入口与扩展规则

`compile-module` 构造带词法准备结果的 HIR，再经 `hir-to-mir`、MIR pass 和发射器
产生语义操作。现有私有构建器沿用 `kiln.kir` 的 `kmodule` 和块操作；
`normalize-lir-module` 将其转成独立 LIR。构建器和诊断 KIR 都不是新的跨语言契约。
生产调用方通过 `kiln.lir` API 输出 LIR，运行期提交结构化程序或 packet。

修改按职责落在相应层：

- 语法、环境查询、声明展开及词法绑定在 HIR 前端处理，保留编译期效果及定义依赖。
- 类型、调用、逃逸和表示证明在 MIR 计算；变换经 pass 接口修改图并失效受影响分析。
- 新增跨语言操作先定义 LIR 的参数、结果、效果与非法输入行为，再实现两端适配和契约测试。
- 布局、ABI、roots、调用及异常展开由 Rust 实现；Rust 不根据 Lisp 环境重新选择语义优化。

HIR 求值器和公共发射工具继续复用。原生编译只接受 MIR，不恢复另一条生产分析路径。
保守重算可以作为可靠的分析失效策略；细化缓存不得绕过语义证明、结构验证或 roots 检查。
性能预算用于发现回退，API 的职责和所有权由契约及测试保持。

## 待定

- 跨模块 inline 的表示：继续记源码形式，还是记 HIR 或 MIR（需要进 FASL 和堆快照）。
- 是否提供可选的表示断言模式，检查 fixnum 范围等可局部验证的性质；它不能证明完整逃逸安全，也不能代替后端自身的 roots 和布局验证。

## 验证范围

原生编译通过 HIR → MIR → LIR 执行。语义测试使用相同输入和策略，将生成程序的行为与宿主比较；有副作用的编译期形式在独立会话中执行。宿主和 kiln 编译分别覆盖 JIT、GC 压力、AOT、FASL 与快照；另外验证 cleanup、跨函数退出、多值、参数初始化、调试位置和定义失效。

语义差分必须不扩大 SBCL 已知基线，项目回归与自举确定性必须成立。编译延迟及运行期基准继续按 [性能预算](compiler-performance.md#小函数与切换预算) 优化；性能工作与旧路径清理分别推进。MIR 必须提供自己的类型、存储和调用证明，保守回退不能替代这些分析。HIR 求值器共用的词法准备和 LIR 公共发射工具各自保留，语义分析不再依赖 HIR 原生消费者。

ANSI 使用 `KILN_COMPILER` 指定被测可执行文件，`ANSI_EVAL=native|hir` 选择
原生编译或 HIR 求值路径，`ANSI_OUTPUT_DIR` 隔离日志和 prelude image。
`ANSI_REPORT_NAMES=1` 输出逐项结果，由 `tools/check-ansi-baseline.py` 对照指定分组
的失败名称、跳过项及原因。模块的构建路径不能代替运行期求值模式的选择。

Rust 后端仍由 Cargo 构建，各自举阶段共用：LIR 和二进制闭合验证 Lisp 编译器及其导出稳定性，不证明 Rust 后端能自举。Rust 降级另以旧 KIR 对照、独立协议样本和端到端执行验证。
