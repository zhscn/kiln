# LIR 编译协议

生产编译使用 payload 2，保存独立的类型化 LIR；后端使用独立解析器、CFG 验证器和 Rust 降级器，操作契约见 [lir.md](lir.md)。payload 1 保留兼容 KIR 输入。本文描述现有 LIR 的编码、调用和资源生命周期；它是编译器专用单向协议，不依赖通用 Rust 宿主模块、对象借用或 Lisp 回调网关。

## 生产入口

Lisp 调用方使用 `kiln.lir:module-program`、`module-packet`、`encode-program`、
`write-module` 和 `target-fingerprint`。`require-init` 解码运行期结果，
`backend-error` 的 operation、stage、message 和 truncated-p 读者提供结构化诊断。这些入口固定生成独立 LIR，不暴露语言标签
选择。`kiln.kir` 的构建器、通用编码器及诊断打印属于内部实现。

Rust 的运行期入口使用 `packet::load_lir` 或 `compile_lir_program`，拒绝兼容 KIR。
命令行的通用文件与文本分派仍支持显式的兼容输入；它们不供 image 的生产编译使用。

## 已实现的封套

`protocol/lir-schema.def` 定义记录种类和版本，`tools/gen-lir-schema.py` 生成 Lisp 与 Rust 常量，`--check` 检查副本。`kiln-cg abi-description` 从运行时错误码生成 `lisp/abi.lisp`；`kiln-cg target-description` 生成 `lisp/backend-target.lisp`；目标描述提供参数和返回值的数量上限，以及独立 LIR 纯运算、写入操作的类型签名和 runtime 服务的参数数量、safepoint 属性，供 Lisp 编译器使用。数量检查直接采用语义上限，不由 Lisp 组合寄存器数与传递区容量。目标指纹涵盖共享布局与语义展开器、runtime 对象、数值、动态退出、错误接口、context 定义及 runtime 导出接口、参数寄存器数、共享 schema、LIR 类型和操作定义及其解码规则，以及目标架构、系统，采用严格的构建匹配，不承诺布局相同时跨构建兼容。修改这些定义后重新生成目标描述。

头部为 64 字节，整数按小端编码：

| 偏移 | 宽度 | 内容 |
|---|---|---|
| 0 | 8 | magic：`KILNLIR` 和零字节 |
| 8、12 | 各 4 | major、minor，取值由 schema 定义 |
| 16、20 | 各 4 | payload 种类、标志（当前为零） |
| 24、32 | 各 8 | 目标指纹、总字节数 |
| 40、44、48、52 | 各 4 | 记录数、子记录引用数、UTF-8 字节数、根记录 ID |
| 56 | 8 | 保留，必须为零 |

随后依次为 16 字节记录、4 字节子记录 ID、UTF-8 池。记录为 `(tag:u32, offset:u32, payload:u64)`：整数保存有符号 64 位位模式；symbol/string 引用字节池；list 引用子 ID 区间。后序编号只能引用更早记录。整数、标识符、字符串和空列表按内容去重，非空列表只能有一个 owner，防止集合 DAG 的递归展开。解码前校验原子重复引用造成的展开量，不能因一个长字符串被大量引用而绕过资源限制。块、变量和操作由记录组成，程序标识符和字符串不经打印或 reader 解析。当前限制为 256 层、256 MiB 编码，并按 32 字节记录单位和字符串复制量估算展开成本，上限 1 GiB；这是逻辑展开预算，不是进程 RSS 上限。元数据原子共享不合并 Lisp literal 或其对象图。

大模块的编码暂存区也必须有界。把记录、引用及每个 UTF-8 字节都保存在 cons
列表中，会让暂存区远大于最终请求，并与待写程序同时占用宿主堆。便携编码器
因此用可增长向量保存这些区段：记录的三个字段平铺在普通向量中，子引用使用
32 位无符号元素，UTF-8 池使用 8 位无符号元素。遍历完成后按编号顺序写出，
流式文件输出不再额外物化整份请求的 octet 向量。

宿主使用可移植 Lisp 编码器，image 使用批量 native 编码器，两者输出同一 schema。native 编码在无 safepoint 的窗口直接构造 Rust 自有记录，对原子使用临时对象身份缓存；记录和字节完成、缓存释放后才分配结果向量；分配通过带帧指针的 safepoint trampoline，调用者的其他对象保持为精确 roots。ASCII 标识符统一转小写，UTF-8 字符串保留原内容；非 ASCII 标识符不做大小写转换。需要保留字节时使用 simple-vector octets，编译入口批量复制为 native bytes 后解码。编译失败返回有界诊断向量，由 Lisp 解码为结构化 condition；独立产物 handle 未公开，Rust panic 遵守工作区的 abort 配置。此载体每个 octet 占一个 Lisp 槽，不能把它称为紧凑的原生字节数组；后续可优化载体而保持 wire schema。请求快照、降级和成功安装期间没有 Lisp 分配；失败诊断可以分配，因此两个编译服务声明为 safepoint，单 mutator 下由调用帧保护后续仍需使用的对象；尚不支持并发 mutator 的 native 状态切换。

生产构建、自举、REPL 和基准的 `.lir` 输出使用二进制封套，旧 `.kir` 文件及 `kiln_rt_jit` 文本入口保留用于迁移对照。原生 `compile` 使用 `:compile-program`，一次性程序不物化字节向量；`eval` 的缓存载荷和 FASL 加载使用 `:compile-packet`。缓存和定义指纹采用规范化记录字节。FASL 记录数据的标签 6 保存 packet octets。加载器支持封套版本 2、3 和 4。

## 语义构建器与兼容输入的字段操作

`field-load(field-id, object)` 和 `field-store(field-id, object, value)` 使用共享 schema 的字段编号。Rust 负责 cons、symbol、函数入口、double-float 位模式和 complex 分量的偏移；函数入口和 double 位模式只允许通过字段操作读取，其余已接入字段保存对象引用。类型检查和错误路径仍由 Lisp 生成。迁移期 KIR 文本读取器也接受这些操作，构造的内部 KIR 只含普通 load/store，便于保持旧后端和差分验证。

## 语义构建器与兼容输入的动态调用

`invoke(v0, count, callee, arguments, handler, location)` 接收已经求值到变量或立即数的参数，Rust 根据 runtime 的寄存器数量和 context 布局安排传递区，再构造低级 `call-lisp`。参数操作数不得包含需要重新读取内存的表达式，避免参数传递覆盖尚未求值的输入。Lisp 负责函数 designator 检查、参数表达式求值及 lambda-list 语义。规范化器将普通调用、已知入口调用、apply、尾调用和返回值对转换为独立 LIR 的调用及多值视图，Rust 统一安排参数和返回值传递。

## LIR 载荷的目标契约

程序记录使用统一 schema，需要持久化或传送字节时使用同一规范化二进制编码；进程内可以直接交接拥有所有权的记录。封套提供 schema、长度和 ABI 指纹；后端配置和 LIR 的语义表由载荷记录表达。整数按固定宽度小端编码，引用使用定宽局部 ID 或缓冲区偏移；地址和 Rust/Lisp 对象内存布局不进入编码。偏移对齐和保留位由 schema 固定，保留位写零。

节包括模块和入口、函数、变量及表示、基本块、操作及操作数、动态区域、常量对象图、初始化顺序、源码与调试描述、依赖引用。字符串采用带长度 UTF-8，浮点常量保存位模式。带环常量图按创建与填充记录编码。image literal 以整数 ID 引用请求外的受保护向量。

封套 schema 生成记录标签、字段和类别编号；独立操作由 Rust 的类型、解析器和验证器
定义。`target-description` 导出纯运算、写入操作签名及 runtime 服务的参数数量和 safepoint 属性，Lisp 发射器与规范化器消费生成的描述。
它尚未生成全部控制、分配和区域操作的两端实现。扩展操作时需要同步解析、验证、
降级及 Lisp 构造，并添加契约测试。CL 类型摘要和语义改写仍由 Lisp 维护。

编码器按稳定遍历顺序分配编号，规范化各区段顺序和填充字节，不依赖地址或哈希表迭代。当前 major/minor 均精确匹配；将来只有显式实现了可选节协商后才允许 minor 扩展。schema、runtime ABI 和后端管线版本分别校验。

独立 LIR 的实际语法与操作规则见 [lir.md](lir.md)。wire 层只编码这些结构，
不会把未实现的语义操作自动展开成后端指令。

## 内存入口与所有权

逻辑程序 schema 与 wire 编码分开：文件需要长度、索引和版本封套，进程内一次性请求可以直接构造 Rust 拥有的记录，避免编码后立即解码。两者最终进入同一操作解析、验证和降级代码。schema 的变化仍受版本与目标指纹约束，不能形成两套操作含义。

当前 `kiln_rt_compile_program` 接收结构化 Lisp 程序、literal 向量和期望目标指纹。在无 safepoint 的窗口复制为 Rust 自有记录，核验目标后进入独立 LIR 的解析、验证和降级；之后不访问程序的原始对象地址。`kiln_rt_compile_packet` 将 octet 向量复制成 native bytes，经过封套校验和解码进入同一程序路径。两者都是单次批量调用，不逐节点 FFI，也不在降级期间回调 Lisp。

字节包校验通过后，LIR 解析器按记录编号直接读取原子和列表边，构造拥有操作数和名称的类型化程序。运行期包入口随即释放字节缓冲。兼容 KIR 和诊断输出可按需构造 S 表达式。

验证时将分支目标和异常落点解析为函数内的块编号。布局降级复用这些编号，并为生成的 KIR 建立标签。这样每条边只解析一次名称。

后续的 native span 或 record-builder API 沿用此 schema 和所有权规则；移动堆内部地址不能作为长时间 Rust 借用。序列化不是一次性编译的必经阶段。

当前两个编译入口同步消费请求，成功返回已安装代码的 init 函数对象，调用方随后
执行 init。失败返回带版本、阶段、截断标志和 Unicode 字符的诊断向量，
`kiln.lir:require-init` 将其转成 `kiln.lir:backend-error`。诊断格式见 [abi.md](abi.md)，
没有公开的产物 handle 或需要另行释放的诊断缓冲区。
Rust 的 `Vec`、`String`、`Result` 和引用不进入 ABI。工作区使用 panic=abort，
内部 panic 终止进程，不提供可恢复的 panic 诊断；Rust unwind 不跨 C/Lisp 边界。
诊断一次分配完成且不包含堆引用。发生 GC 后，Rust 不再访问旧请求地址。

输入校验包括边界、签名、初始化、动态区域和短期多值使用；它不重复 Lisp 的类型或逃逸证明。Rust 低层展开仍对自身生成的 roots、栈槽和异常路径负责。解码器对深度、数量和分配设置上限，避免畸形输入导致溢出或无界递归。

## literal 与代码安装

请求建立时，Lisp 将现存对象放入受 GC 扫描的 literal 向量。image 适配器在
无 safepoint 窗口读取 Lisp 对象表示并建立 Rust 自有请求；解析、验证和降级只使用
记录及 literal ID，不查询 Lisp 环境。安装时先将 literal 写入尚未登记的数据槽，全部校验通过后再登记静态 roots。
调用帧保持 literal 向量存活。请求读取和安装期间不触发 Lisp GC 或回调；失败路径完成原始对象访问后，可以通过 safepoint 分配诊断向量。

Lisp 负责语义依赖及缓存版本，Rust 校验目标和载荷，准备尚未登记的代码与数据，
验证并绑定全部 literal，取得 init 后才统一登记代码、roots 和导出符号。代码安装不等于 Lisp 定义发布：定义初始化由调用方执行
init 完成。当前同步入口没有取消或显式释放已安装代码的协议；成功代码随 image
存活。编译期请求和未发布元数据由 Rust 所有，失败时释放；共享代码 arena 已保留的容量不保证回收。未登记产物不会留下 roots 或导出符号，不承诺并发 mutator 或并发发布。

SBCL 只提交可移植常量图，不传递宿主 tagged word。stage0 写二进制请求并调用 kiln-cg 子进程；kiln image 使用进程内入口，literal ID 保持 `eq` 身份。两条路径共享程序契约和后端验证、降级；宿主与 image 分别实现编码适配，直接程序入口不经过字节解码。

## 文件、FASL、快照与缓存

`.lir` 文件保存规范化请求；诊断 dump 不参与往返解析。目标 FASL 编译载荷采用 LIR 字节和常量图，其格式版本记录 LIR schema、目标 ABI 和后端兼容键。从封套版本 3 起，记录种类使用单字节操作码。版本 4 把 cons 创建和初始化的对象编号直接编为变长整数。各受支持的版本使用同一种 packet 载荷。LIR 操作或 schema 变化时仍需显式更新兼容键。

FASL 记录解码使用每次加载独有的工作向量。解码嵌套数据时，每个尚未组装的对象占用两个槽，
向量按嵌套深度扩容，并在记录之间复用。组成对象后立即清除对应的引用槽。

快照若含缓存的 LIR 或内联编译数据，也记录对应 schema 和编译器版本。不兼容的可重建缓存丢弃；无法恢复的必要数据明确拒绝加载。内联源码或绑定后 IR 的持久表示另行决定，不能默认为跨版本兼容。

缓存键包含目标、配置、schema、后端版本、依赖及常量身份。`load-time-value` 单元和可变静态 cell 不因缓存而共享，缓存不能跳过编译期效果。前端实际执行的展开依赖必须保留；内联候选和变换的条件依赖只有被选中才并入产物，见 [dependencies.md](dependencies.md)。

## 实施边界

现有生产入口包括结构化程序、二进制 packet、文件驱动和 literal 绑定。
协议版本、目标指纹及非法输入由契约测试检查。新增入口或载荷不得绕过同一份
LIR 验证与降级。未实现接口集中记录在路线图，不能作为当前调用方的前提。

端到端测试默认编译并执行独立 LIR packet，JIT、GC 压力和 AOT 使用相同载荷。`.same-kir` 比较仍采用同一编译结果的诊断文本；测试构建同时保留 `.kir` 文件，避免再次编译改变会话状态。宿主构建器的 `*write-diagnostic-kir*` 和目标构建程序的 `KILN_DIAGNOSTIC_KIR` 可在写出二进制时生成这份诊断副本。
