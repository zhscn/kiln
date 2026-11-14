# 编译器架构

状态：**LIR 分层与 MIR 实验框架已接入**。文件模块、运行期编译、缓存和 FASL 使用独立 LIR。Lisp 从 HIR 生成布局无关的语义操作和控制流，规范化器建立类型化的 LIR 程序；kiln-cg 验证程序后展开布局、调用约定、动态区域、精确根和 poll，构造内部 KIR 并交给 Cranelift。结构化协议提供文件与内存入口，兼容 KIR 仍可作为诊断输入。HIR 分析及其存储、调用优化仍在 Lisp 中，MIR 的 CFG、SSA 验证、基础类型传播、声明检查证明及装箱值降级已有显式实验入口，后续扩展动态区域并迁移其余分析（见 [hir.md](hir.md)、[lowering.md](lowering.md)）。

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

**MIR 留在 Lisp。** 最近的分析能力（按求值顺序的类型传播、区间 widening、cons 和闭包的逃逸证明、局部函数身份）都做在 HIR 树上，每个分析都要自己处理 `tagbody`、`block`、`catch`、`unwind-protect` 的合流和退出，按树的形状写一遍求值顺序。MIR 把这些统一成 CFG 的边，分析只面对块和边。MIR 留在 Lisp 的理由：

- 类型系统只有一份：MIR 直接调用 ctype 的 `typep`/`subtypep`，不在别处再实现一套 CL 类型格和标准函数知识库。
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

## 迁移

1. **LIR 和 Rust 降级**：定义 LIR（[lir.md](lir.md)），kiln-cg 实现二进制文件和内存入口、LIR 验证及 LIR → KIR。先完成编译器专用的缓冲区所有权和 literal roots，通用双向 interop 不在前置范围。现有 Lisp 降级改为输出 LIR：`primitives.lisp`、`lower.lisp`、`values.lisp` 里展开 tag、偏移、动态环境条目和多值的代码移到 Rust，`abi.lisp` 换成 Rust 生成的目标描述。验证：保持发射顺序的部分逐字节比较新旧 KIR；合法的布局与控制流展开差异通过执行与元数据验证，`tools/test.sh` 三遍、ANSI 测试和自举照常。
2. **MIR 骨架**：已有标量绑定、普通控制流和多值 bundle 的实验入口；继续扩展 HIR → MIR 构造、MIR 验证器、MIR → LIR 的降级（[mir.md](mir.md)）。仅导入能够映射到具体绑定、操作和作用域的有效事实；结构改变后失效的证明重新分析或保守回退，不能直接照搬 HIR 标记。保守路径只用于开发验证。两条路径并存，满足下述切换门槛后，MIR 成为默认路径，删除 `lisp/hir/lower.lisp`。
3. **分析迁到 MIR**：类型和区间传播、逃逸和存储选择、局部函数的调用摘要和 lambda lifting、double 拆箱，逐项在 MIR 上重写；仅在旧生产路径和求值器不再依赖相应代码后删除 HIR 上的对应实现（`lisp/hir/types.lisp`、`escape.lisp`、`analyze.lisp` 的相应部分）。
4. **新的优化**：类型驱动的改写、高阶序列函数的展开、跨迭代的对象图、更多机器值表示；seal 后的 WPO。

第 1 步先做，因为它有可以逐字节对照的验证手段，而且 MIR 的降级目标从一开始就是 LIR，MIR → 布局代码只写一次。代价是 `hir/lower.lisp` 要先改输出 LIR，到第 2 步再删除。

## 待定

- 跨模块 inline 的表示：继续记源码形式，还是记 HIR 或 MIR（需要进 FASL 和堆快照）。
- 是否提供可选的表示断言模式，检查 fixnum 范围等可局部验证的性质；它不能证明完整逃逸安全，也不能代替后端自身的 roots 和布局验证。

## 切换门槛和验证范围

LIR 阶段保留 HIR → KIR 与 HIR → LIR → KIR 两条路径；MIR 阶段保留 HIR → LIR 与 HIR → MIR → LIR。使用同一输入和策略比较结果，不在同一 image 中重复执行有副作用的编译期形式。宿主和 kiln 编译分别覆盖 JIT、GC 压力、AOT、FASL 与快照；另外验证 cleanup、跨函数退出、多值、参数初始化、调试位置和定义失效。

默认路径切换要求语义差分不扩大 SBCL 已知基线，项目回归与自举确定性成立，编译延迟及运行期基准满足 [性能预算](compiler-performance.md#小函数与切换预算)。实验路径允许性能回退，但不能凭保守 MIR 已能运行就替换生产路径；缺少的类型、存储和调用优化必须先补齐。旧分析与降级相互耦合，删除按依赖消除进行，不按 pass 写完的顺序进行。

迁移涉及 HIR 分析、原语和降级代码的数千行重构，需要分阶段实施；精确范围以调用关系为准。Rust 后端仍由 Cargo 构建，各自举阶段共用：LIR 和二进制闭合验证 Lisp 编译器及其导出稳定性，不证明 Rust 后端能自举。Rust 降级另以旧 KIR 对照、独立协议样本和端到端执行验证。
