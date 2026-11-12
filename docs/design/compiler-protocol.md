# LIR 编译协议

状态：结构化传输已实现，布局无关的 LIR 操作仍在迁移。当前 payload 1 保存兼容操作树（KIR 与迁移中的字段、调用操作），payload 2 为 LIR 保留，后端暂时拒绝；二进制 KIR 不等同于完成 LIR 降级。LIR 是后端输入语言，本文定义其编码、调用和资源生命周期；操作含义见 [lir.md](lir.md)。它是编译器专用单向协议，不依赖通用 Rust 宿主模块、对象借用或 Lisp 回调网关。

## 已实现的封套

`protocol/lir-schema.def` 定义记录种类和版本，`tools/gen-lir-schema.py` 生成 Lisp 与 Rust 常量，`--check` 检查副本。`kiln-cg target-description` 生成 `lisp/backend-target.lisp`；目标描述提供参数寄存器数与多值传递区容量。目标指纹涵盖 runtime 对象与 context 定义、参数寄存器数、共享 schema 以及目标架构、系统，采用严格的构建匹配，不承诺布局相同时跨构建兼容。修改这些定义后重新生成目标描述。

头部为 64 字节，整数按小端编码：

| 偏移 | 宽度 | 内容 |
|---|---|---|
| 0 | 8 | magic：`KILNLIR` 和零字节 |
| 8、12 | 各 4 | major、minor，当前为 1、1 |
| 16、20 | 各 4 | payload 种类、标志（当前为零） |
| 24、32 | 各 8 | 目标指纹、总字节数 |
| 40、44、48、52 | 各 4 | 记录数、子记录引用数、UTF-8 字节数、根记录 ID |
| 56 | 8 | 保留，必须为零 |

随后依次为 16 字节记录、4 字节子记录 ID、UTF-8 池。记录为 `(tag:u32, offset:u32, payload:u64)`：整数保存有符号 64 位位模式；symbol/string 引用字节池；list 引用子 ID 区间。后序编号只能引用更早记录。整数、标识符、字符串和空列表按内容去重，非空列表只能有一个 owner，防止集合 DAG 的递归展开。解码前校验原子重复引用造成的展开量，不能因一个长字符串被大量引用而绕过资源限制。块、变量和操作由记录组成，程序标识符和字符串不经打印或 reader 解析。当前限制为 256 层、256 MiB 编码，并按 32 字节记录单位和字符串复制量估算展开成本，上限 1 GiB；这是逻辑展开预算，不是进程 RSS 上限。元数据原子共享不合并 Lisp literal 或其对象图。

宿主使用可移植 Lisp 编码器，image 使用批量 native 编码器，两者输出同一 schema。native 编码在无 safepoint 的窗口直接构造 Rust 自有记录，对原子使用临时对象身份缓存；记录和字节完成、缓存释放后才分配结果向量；分配通过带帧指针的 safepoint trampoline，调用者的其他对象保持为精确 roots。ASCII 标识符统一转小写，UTF-8 字符串保留原内容；非 ASCII 标识符不做大小写转换。需要保留字节时使用 simple-vector octets，编译入口批量复制为 native bytes 后解码。当前入口以 NIL 和 stderr 报告编译失败，结构化诊断与独立产物 handle 尚未接入；Rust panic 仍遵守工作区的 abort 配置。此载体每个 octet 占一个 Lisp 槽，不能把它称为紧凑的原生字节数组；后续可优化载体而保持 wire schema。纯编译入口没有 Lisp 分配或 safepoint，单 mutator 下由调用帧保持 literal 向量存活，安装后转为静态 roots；尚不支持并发 mutator 的 native 状态切换。

生产构建、自举、REPL 和基准的 `.lir` 输出使用二进制封套，旧 `.kir` 文件及 `kiln_rt_jit` 文本入口保留用于迁移对照。原生 `compile` 使用 `:compile-program`，一次性程序不物化字节向量；`eval` 的缓存载荷和 FASL 加载使用 `:compile-packet`。缓存和定义指纹采用规范化记录字节。FASL 格式版本为 2，记录标签 6 保存 packet octets；旧版本会拒绝加载。

## 已接入的字段操作

`field-load(field-id, object)` 和 `field-store(field-id, object, value)` 使用共享 schema 的字段编号。Rust 负责 cons、symbol、函数入口、double-float 位模式和 complex 分量的偏移；函数入口和 double 位模式只允许通过字段操作读取，其余已接入字段保存对象引用。类型检查和错误路径仍由 Lisp 生成。迁移期 KIR 文本读取器也接受这些操作，构造的内部 KIR 只含普通 load/store，便于保持旧后端和差分验证。

## 已接入的动态调用

`invoke(v0, count, callee, arguments, handler, location)` 接收已经求值到变量或立即数的参数，Rust 根据 runtime 的寄存器数量和 context 布局安排传递区，再构造低级 `call-lisp`。参数操作数不得包含需要重新读取内存的表达式，避免参数传递覆盖尚未求值的输入。Lisp 仍负责函数 designator 检查、参数表达式求值及 lambda-list 语义；已知局部调用、apply、尾调用和多值 ABI 尚未全部迁移。

## LIR 载荷的目标契约

程序记录使用统一 schema，需要持久化或传送字节时使用同一规范化二进制编码；进程内可以直接交接拥有所有权的记录。封套提供 schema、长度和 ABI 指纹；后端配置和 LIR 的语义表由载荷记录表达。整数按固定宽度小端编码，引用使用定宽局部 ID 或缓冲区偏移；地址和 Rust/Lisp 对象内存布局不进入编码。偏移对齐和保留位由 schema 固定，保留位写零。

节包括模块和入口、函数、变量及表示、基本块、操作及操作数、动态区域、常量对象图、初始化顺序、源码与调试描述、依赖引用。字符串采用带长度 UTF-8，浮点常量保存位模式。带环常量图按创建与填充记录编码。image literal 以整数 ID 引用请求外的受保护向量。

操作表规定数值 opcode、操作数和结果类别、变长参数规则，以及调用、分配、GC、多值区破坏和退出效果。表是接口定义的唯一来源，生成 Lisp 编码常量与 Rust 解码声明；CL 函数的类型摘要和语义改写仍由 Lisp 维护。未知必需操作、长度溢出、无效 ID、非法布局或目标不匹配返回诊断。

编码器按稳定遍历顺序分配编号，规范化各区段顺序和填充字节，不依赖地址或哈希表迭代。当前 major/minor 均精确匹配；将来只有显式实现了可选节协商后才允许 minor 扩展。schema、runtime ABI 和后端管线版本分别校验。

以下是解码后的示意记录，不是可直接提交的文本格式或已实现的 opcode 编号：

```text
header { schema: 1.1, target: ABI, module: "example" }
variables [ {id: 0, repr: obj}, {id: 1, repr: word} ]
operations [
  { op: arg-count, dst: 1 },
  { op: check-arity, count: 1, min: 1, max: 1 },
  { op: arg-ref, dst: 0, index: 0 },
  { op: return, values: [0] }
]
```

`check-arity` 是 Lisp 选定的检查操作；后端实现错误路径与参数读取，不处理默认初始化式。类型测试例如 `test(repr-class=fixnum, value=v0)`，字段访问例如 `field-load(kind=cons, field=car, object=v0)`；范围证明不序列化为需要 Rust 再推导的类型格。

## 内存入口与所有权

逻辑程序 schema 与 wire 编码分开：文件需要长度、索引和版本封套，进程内一次性请求可以直接构造 Rust 拥有的记录，避免编码后立即解码。两者最终进入同一操作解析、验证和降级代码。schema 的变化仍受版本与目标指纹约束，不能形成两套操作含义。

当前 `kiln_rt_compile_program` 接收结构化 Lisp 程序、literal 向量和期望目标指纹。在无 safepoint 的窗口复制为 Rust 自有记录，核验目标后直接构造 KIR；之后不访问程序的原始对象地址。`kiln_rt_compile_packet` 将 octet 向量复制成 native bytes，经过封套校验和解码进入同一程序路径。两者都是单次批量调用，不逐节点 FFI，也不在降级期间回调 Lisp。

后续的 native span 或 record-builder API 沿用此 schema 和所有权规则；移动堆内部地址不能作为长时间 Rust 借用。序列化不是一次性编译的必经阶段。

Rust 同步消费请求，返回结构化状态、诊断缓冲区或未发布的代码产物 handle。Rust 分配的缓冲区和产物只由配套释放入口销毁；不跨 ABI 传 `Vec`、`String`、`Result` 或 Rust 引用。所有 Rust 入口捕获可展开的 panic 并转换为内部编译故障；不允许 Rust unwind 穿过 C/Lisp 边界。输入错误不会留下已发布定义。

输入校验包括边界、签名、初始化、动态区域和短期多值使用；它不重复 Lisp 的类型或逃逸证明。Rust 低层展开仍对自身生成的 roots、栈槽和异常路径负责。解码器对深度、数量和分配设置上限，避免畸形输入导致溢出或无界递归。

## literal 与代码安装

请求建立时，Lisp 将现存对象放入受 GC 扫描和更新的 literal 向量。runtime 保持该向量的作用域 root，Rust 仅操作 literal ID，不读取 tagged word 或查询 Lisp。纯降级阶段不保留对象地址；物化和安装阶段通过 runtime 解析 ID 并建立最终 roots，发布前保持可更新状态。

安装流程为：校验依赖版本与 ABI，解析 literals 和重定位，登记代码、异常表、栈图及持久 roots，再发布定义。请求 root 只能在成功转交所有权或彻底释放暂存产物后撤销。失败、取消和旧依赖失效都销毁未发布产物。初期同步安装，不承诺任意线程编译或并发定义发布。

SBCL 只提交可移植常量图，不传递宿主 tagged word。stage0 写二进制请求并调用 kiln-cg 子进程；kiln image 使用进程内入口，literal ID 保持 `eq` 身份。两条路径共享编码器和后端解码器。

## 文件、FASL、快照与缓存

`.lir` 文件保存规范化请求；诊断 dump 不参与往返解析。目标 FASL 编译载荷采用 LIR 字节和常量图，其格式版本记录 LIR schema、目标 ABI 和后端兼容键。当前版本 2 已保存 packet 载荷；LIR 操作或 schema 变化时仍需显式更新兼容键，不以旧版本头装入不兼容载荷。

快照若含缓存的 LIR 或内联编译数据，也记录对应 schema 和编译器版本。不兼容的可重建缓存丢弃；无法恢复的必要数据明确拒绝加载。内联源码或绑定后 IR 的持久表示另行决定，不能默认为跨版本兼容。

缓存键包含目标、配置、schema、后端版本、依赖及常量身份。`load-time-value` 单元和可变静态 cell 不因缓存而共享，缓存不能跳过编译期效果。前端实际执行的展开依赖必须保留；内联候选和变换的条件依赖只有被选中才并入产物，见 [dependencies.md](dependencies.md)。

## 实施边界

首期同时提供 schema、共享编码器、内存调用、文件驱动、解码验证、literal roots 和失败清理。结构化交接不是文本方案之后的可选优化。当前封套位宽与记录标签已经固定并有跨语言样本；LIR 操作编号、结构化诊断和独立产物接口随相应实现接入。
