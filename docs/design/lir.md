# LIR：Lisp 编译器与 Rust 后端的输入契约

状态：**独立核心已接入，生产发射正在迁移**。独立的 `lir-module` 载荷经类型化解析、CFG 验证后由 Rust 构造 KIR，支持范围见下文“已实现的独立核心”。[结构化封套](compiler-protocol.md)支持文件与运行期交接。Lisp 生产发射目前使用兼容 KIR 载荷；兼容载荷已支持 fixnum、cons、character 和 single-float 的表示类测试、`field-load`/`field-store`、闭包环境读写、传递区读写和根计数设置，以及普通函数对象 `invoke` 及展开列表实参的 `invoke-list`，fixnum、字符和 single-float 常量以数值、码点和 IEEE 位模式传入，Rust 在构造 KIR 时展开立即数表示、布局和调用约定。动态传递区下标和根计数的范围由生成方保证。其余操作尚未迁移，不能视作完成 LIR。现在 Lisp 主要生成 KIR（[codegen.md](codegen.md)）。分层和迁移见 [compiler.md](compiler.md)。

兼容载荷的 `guarded-class-test` 由后端生成一般对象检查和 header 类测试，对任意 Lisp 值安全。兼容输入仍接受单独的 header 类测试，生成方必须确保只有一般对象到达该操作。完整 LIR 的类型测试将把安全检查与表示类测试作为同一操作处理。

兼容载荷的 `alloc-fixed` 接收对象种类和已求值的字段，Rust 据此分配和初始化堆 cons、double-float、complex 和 CLOS 实例；对象字段变量跨分配慢路径保持 GC root。兼容输入中的 `alloc-raw` 由生成方提供大小和 header；Rust 展开定长小对象的 bump 分配、清零与慢路径，其他大小调用 runtime 分配器。`alloc-raw` 的结果是未加 tag 的地址，生成方须在下一个 safepoint 前完成初始化并转换为对象引用。完整 LIR 的分配操作将改用对象种类、存储方式和字段。

`alloc-closure` 按入口和捕获项数量分配堆函数对象，初始化入口并把捕获项清零；生成方随后以 `closure-set` 填充捕获项。这允许递归组先建立所有函数对象，再互相引用，即使填充之前发生 GC 也可安全扫描。

栈上的 cons 和闭包以对象种类及引用项数量声明栈槽，由 Rust 决定大小、header、清零、引用字段起点和对象初始化。生成方标注栈根区域的进入与退出，Rust 初始化并链接动态根条目；rest 列表按生成方选择的栈槽地址初始化 cons。

catch、unwind-protect、跨函数退出点、special 绑定和 progv 的动态条目也由 Rust 按语义种类建立和撤销。special 绑定与 progv 的保存、设置和恢复，以及退出点重新链接使用对应的后端操作；Lisp 仍编排控制流及绑定、cleanup 的求值，退出目标及多值打包标志由后端从展开 payload 中解码。

`special-ref` 和 `special-set` 由 Rust 安排动态值与全局值的选择，调用方负责检查未绑定值。special 绑定使用后端操作取得或分配 TLS 下标，由后端保存旧值并设置新值，多个绑定的求值顺序仍由调用方编排。progv 提交已求值的符号列表与值列表；Lisp 检查 proper list 和元素类型，Rust 保存全部旧值后建立条目并写入新值，退出时恢复。下标分配的 runtime 调用不是 safepoint，调用名及签名由 Rust 决定，输入不携带 runtime 入口。

兼容载荷的 `receive-prefix` 保存所需的位置参数前缀并返回实参数量，缺失位置为 NIL；与独立 LIR 的 `receive` 共用后端实现。rest 操作只提交后缀起点及存储候选，由 Rust 读取入口参数并构造列表。生成方按源码顺序处理默认式、supplied-p 和关键字，不选择参数寄存器或传递区位置。

兼容载荷以 `poll` 提交入口或循环检查，Rust 生成栈限额或 poll 标志读取、慢路径及栈耗尽分派。尚未保存寄存器参数的入口使用 retry 模式：Rust 的共享 helper 保存有效实参并清零多余寄存器，poll 后尾调用原入口。文件模块提供可合并的 helper，image 编译引用 image 中已有的 helper。完整 LIR 的 poll 安排由后端完成。

`alloc-vector` 接收 simple-vector 或字符串的种类、未装箱长度和初值，Rust 负责尺寸、header、对齐及填充。字符串初值为字符码点，simple-vector 初值为对象；动态长度须由生成方检查范围。`alloc-vector-elements` 接收已求值的多个对象，按顺序初始化 simple-vector。填充过程没有 safepoint。

`vector-ref` 和 `vector-set` 访问 simple-vector 的对象元素，`string-ref` 和 `string-set` 访问字符串的字符；这些操作接收未装箱下标，对象类型与下标范围由生成方检查。`vector-length` 读取未装箱长度，并屏蔽 header 中的身份哈希。fixnum 和字符的装箱、拆箱操作负责立即数与机器字之间的转换。fixnum 的算术、位运算和移位由后端选择带 tag 的计算方式；加、减、乘可以返回溢出标志，除法与移位的输入范围由生成方检查。

`heap-number-p` 接受任意 Lisp 值，由后端检查表示后判断它是否为堆数值；`identity-hash` 由后端判断对象表示、读取已有哈希并按需调用 runtime。

double-float 的未装箱位模式和 complex 的实部、虚部通过字段操作读取。double 位模式是机器值，函数入口与 double 位模式均不能作为对象引用字段写入。

实例的 rack、class 和按位置访问的槽，funcallable instance 的函数，以及原生结构的 layout 和槽由后端按对象种类展开。槽位置传入机器字；生成方负责类型和位置的有效性。

`alloc-structure` 接收已求值的 layout 和未装箱槽数，由 Rust 计算结构对象大小和 header、清零槽并写入 layout；动态槽数由生成方保证在可表示范围内。

`alloc-rack` 接收 class 和槽数，后端分配并初始化 rack；普通实例和 funcallable instance 使用 `alloc-fixed`。分配 rack 后再次分配实例时，rack 保持为精确 GC 根。rack 的长度检查预留 class 字段所需的空间。

`alloc-symbol` 只接收名称，由 Rust 选择空包、空 plist、空函数格及未绑定值，再由生成方建立未定义函数对象并写入函数格；这些分配期间 symbol 保持为精确根。动态分配路径不再由 Lisp 发射原始大小和 header，兼容载荷仍保留 `alloc-raw` 供旧输入使用。

静态函数、字符串、cons、simple-vector、bignum、ratio、complex、double-float 和 symbol 使用对象种类及内容描述，由 Rust 构造 header 与对象字。大整数常量提交十进制整数文本，Rust 选择补码 limbs、符号扩展及长度。引用和重定位保留原有的数据标签，字符串传递字符码点，Rust 负责 UTF-32 打包。静态 symbol 的可变字段以字段 ID 声明为根，包括需要随 image 保存的 TLS 下标。

静态对象引用声明数据标签及 cons 或 general 表示类，Rust 负责重定位加数；静态 cons 的可变引用字段以字段 ID 声明为根。函数格访问使用 symbol 字段操作，适用于静态 symbol 和 image literal。

image literal 表通过 `literal-table` 声明数量，读引用和间接调试引用只提交索引。可变静态对象 cell 通过 `object-cell` 声明初值，使用 `cell-ref` 和 `cell-set` 访问。Rust 构造表、计算偏移并登记 roots；独立 LIR 的 literals 与 cells 使用同一实现。

未绑定的 symbol 值和未绑定的标准对象槽使用不同的常量操作，由 Rust 提供其立即数表示。

`invalid-vector-length` 检查带 tag 的候选长度是否为非负 fixnum 且不超过运行时 header 可表示的最大长度；生成方负责错误路径。常量长度在后端展开时也检查同一上限。

LIR（low-level IR）是表示选择后的后端输入语言，也是编译协议的程序载荷。它不设独立的优化管线。初期由 HIR 降级产生，后续由 MIR 产生；两者使用同一 schema。它已经确定了“做什么”：每个值的表示、每个对象的存储、闭包的内容、控制流和动态范围；还没有确定“怎么做”：tag、对象和 context 的偏移、调用序列、展开 payload 的编码、栈图。后者由 kiln-cg 降级成 KIR 时按 kiln-rt 的布局决定。

固定角色入口通过 `(builtin ROLE file|image)` 声明。ROLE 是 `undefined-function`、`undefined-setf-function`、`funcallable-trampoline` 或 `funcallable-unset`；file 模式由 Rust 建立可合并的共享入口，image 模式导入已有入口。函数体、错误分派、捕获布局、初始函数对象和转发调用序列都由后端生成。`undefined-function-p` 检查函数对象是否为任一种未定义占位函数，返回机器布尔值；生成方保证操作数是函数对象。

生产静态占位函数使用 `static-builtin`，动态占位函数和 funcallable instance 使用 `alloc-undefined-function` 与 `alloc-funcallable`。这些操作不携带代码地址或捕获数量。独立 LIR 的 symbol 常量和实例分配使用相同的入口契约。

Lisp 的模块数据转换器在 `lisp/lir.lisp` 中建立独立的常量图和 cell 表。它先为声明分配索引，再翻译字段引用，因此前向引用与环不依赖遍历顺序。symbol 的名称和包转为语义描述，由 Rust 构造占位函数和字段；转换器检查初始值符合 symbol 契约。它拒绝显式 runtime imports、未知外部对象和原始数据内容。

`mutable-cons` 描述必须保留身份的可变静态 cons，字段与 `cons` 相同。Rust 为其引用字段登记 roots，并使其独立于常量合并；两个内容相同的可变节点仍是不同对象。生产路径的内联缓存使用 `static-mutable-cons` 声明同一性质。

旧构建器允许把字段读取、比较和条件选择嵌套在表达式中，而独立 LIR 的操作数必须是带表示声明的变量。`lisp/lir-function.lisp` 逐层规范化表达式，先发射输入的计算，再建立类型明确的临时变量；纯运算的输入和结果表示、容器写入的输入表示来自 Rust 导出的目标描述，避免 Lisp 再维护一套签名。浮点位模式跨表示时生成显式的 `f64-bits` 或 `f64-from-bits`，对象值与机器字保持分离。

函数转换器把入口前缀保存改写为 `receive` 声明和 `arg-ref`，由 Rust 在首次 poll 前接收参数；源码中的普通分支、switch 和循环保留控制流，错误使用独立终结操作。静态调试向量转为名称、文件、范围及变量描述。已知零值和单值返回使用固定结果列表。当前转换器还支持调用、多值视图和定长堆对象分配；动态区域、栈存储和其余分配形式仍需接入，因此默认输出器继续使用兼容载荷。显式调用转换器遇到未支持形式会报编译错误。

主值与计数若独立复制，合流点就无法判断它们对应哪次调用，也无法检查其余值是否已被覆盖。构建器用 `move-values` 记录成对赋值；Lisp 规范化器将每个结果对映射到一个 `mv`，在分支合流处发射显式的 `mv-move`，并把其余值读取转为 `mv-ref`。主值和计数仍可取成普通变量用于绑定和分支，借用的有效性则由 Rust 按 CFG 检查。跨调用保存统一使用 `mv-save` 的私有载体，恢复不依赖 Lisp 解码载体布局。

容器构造保留逻辑长度和初值：动态向量与字符串转为 `alloc-sequence`，元素列表转为 `vector`，结构对象转为带 layout、槽数与初值的 `alloc-structure`。构建器中的字符串初值是字符码，规范化时转回字符对象，让独立 LIR 统一检查对象表示。零填充的向量初值和下标检查中的零也显式声明为 fixnum，避免把机器字零当成对象常量。分配大小、header、引用槽清零和填充循环由 Rust 构造。

仅从环境读取推算捕获数量会漏掉未使用的位置，使同一入口的分配与读取采用不同形状。规范化器先扫描模块内的闭包分配声明，为每个入口登记完整的捕获项数，再检查捕获读取的下标；保存 self 的唯一赋值别名也可用于读取。堆闭包先分配并清零，再逐项填充，保留递归组的构造顺序。捕获写入携带已知入口名，让 Rust 验证环境形状；未知入口或冲突的捕获数量会在规范化时被拒绝。

词法栈对象在源函数入口声明存储并建立根区域，正文只重用这些存储。规范化器将入口的对象种类、捕获入口和根登记顺序转换为 `stack-object` 与 `stack-roots` 区域声明，将分配转换为带命名栈存储的 `alloc` 或 `alloc-closure`。初始化必须与槽声明匹配，根区域依次嵌套；Rust 在进入区域时统一初始化对象并链接引用区，在 CFG 上验证分配时根是否活动、退出是否按嵌套顺序执行。这样源构建器无需给出对象大小、字段地址或根条目的布局。

入口的 rest 列表需要在任何调用覆盖传递区之前构造。规范化器将源 `rest-list` 转为函数的 `rest` 声明，保留后缀起点和栈候选容量；位置参数、默认式和关键字仍按原控制流绑定。源构建器为 rest 预留的 cons 槽及根登记一并交由 Rust 管理，普通词法栈对象仍保留各自的区域声明。Rust 在入口保存所需参数并构造列表，容量不足时使用堆存储，并负责返回、尾调用和异常展开时的根清理。

special 绑定可在不同分支中建立，不能按块的排列顺序推断外层区域。规范化器沿源 CFG 传播活动区域栈，在每个合流点检查一致性，据此声明 `bind` 区域及其外层区域。源端的 TLS 下标准备、绑定和恢复序列合并为接收 symbol 与初值的 `enter` 及对应的 `leave`；Rust 统一选择 TLS 槽并保存、恢复动态值。词法栈根区域参与同一嵌套检查，rest 的私有候选根则由后端自行管理。

源 handler 用独立分派块检查展开目标，再将不匹配的目标转交外层。规范化器将这些分派块转换为区域的 landing 声明，并将调用上的 handler 标签映射到区域名。catch 和 exit-point 落地时的活动栈不包含本区域，unwind-protect 清理期间则保留本区域；清理体、落地多值及继续展开分别转为 `landing`、`mv` 和 `continue-unwind`。跨帧 `go` 在读取目标下标前重新进入退出点，允许同一 tagbody 多次接收跳转。Rust 负责目标分派、payload 和实际异常边上的初始化验证。

PROGV 保存旧值时需要分配 cons，若在保存完成前修改动态值，分配中的退出就无法完整恢复。兼容载荷的 PROGV 入口与独立 LIR 的 `enter` 共用 Rust 展开器：先保存输入及全部旧 TLS 值，再链接区域并设置新值；缺少初值的符号设为未绑定。恢复循环没有调用或分配。规范化器将符号列表、值列表和区域直接交接给这一实现，避免 Lisp 解码恢复链或读写 TLS 槽。

数值原语和已知 fixnum 的谓词均以 fixnum 描述声明对象零，机器字零只用于未装箱的计数、位模式和布尔结果。`heap-number-p` 接受任意对象并返回机器字布尔值，先检查 general 表示再读取 header，避免对立即数或 cons 解引用。兼容载荷和独立 LIR 共用这一展开。`hash-mix` 接收两个 fixnum 对象，按目标 fixnum 位宽执行回绕的 FNV-1a 步骤；素数和带 tag 的计算方式由 Rust 决定，Lisp 不组合表示位。这两种操作均不分配、不覆盖多值传递区。

动态 symbol 的空字段和未定义函数的捕获布局属于后端对象表示。`alloc-symbol` 接收已求值的名称对象，Rust 初始化未驻留的 symbol，并将值格设为未绑定；`alloc-undefined-function` 接收所属 symbol 及 ordinary/setf 角色，由 Rust 安装相应入口并保存 symbol，供报错时恢复函数名。生成方随后将占位对象写入所需函数格。这些构造器先保存输入，允许结果覆盖输入变量，并在分配后使旧多值视图失效；分配前的异常边不包含结果的初始化。

image 编译中的调试记录原本作为一个整体放在 literal 向量中，而独立 LIR 需要分别描述名称、文件、范围和变量。规范化器接收原 literal 绑定，检查记录与变量下标后将字段转换为语义描述；名称等对象追加到绑定向量末尾，复用已有对象的索引，原有索引保持稳定。`normalize-lir-module` 返回程序和更新后的绑定向量，调用方须将两者一起交给后端。cell 与未装箱浮点变量保留各自的调试标记，Rust 负责生成最终调试向量及 roots。

## 已实现的独立核心

`rust/kiln-cg/src/lir/program.rs` 定义独立数据结构，子模块分别负责解码、验证和降级。`LIR_PAYLOAD` 只接受 `lir-module`，不能把兼容 KIR 改一个封套标签后提交。二进制请求和运行期自有快照使用同一解析、验证和降级实现；诊断文本也可直接编译。

当前的可读记法如下。变量引用必须是名字，操作的输入先在前面的指令中求值；每个块以一个终结操作结束。

```lisp
(lir-module "example"
  (init "main")
  (function "main"
    (vars (answer obj) (returned mv))
    (block entry
      (set answer (fixnum 42))
      (values returned (answer))
      (return-mv returned))))
```

函数的 `receive` 声明所需的入口参数前缀长度，`arg-count` 返回实际参数数目，`arg-ref` 按从零开始的固定序号取值。Rust 在任何 poll 或调用之前保存该前缀，缺失位置保存 NIL，之后的调用和分配不能破坏原实参。参数数量检查及默认式的求值仍是生成方的控制流。`self` 取得当前函数对象。`function` 按入口名字取得模块中零捕获的静态函数对象。模块的 `init` 指定入口函数；Rust 为它建立函数对象。

函数可用 `(rest VAR FIRST)` 将从 FIRST 开始的实参绑定成堆列表，VAR 须声明为对象变量。Rust 在首次 poll 前保存寄存器实参、保护尚未读取的传递区并从尾到头构造列表，随后撤销传递区 roots。该列表在源码入口块已初始化，之后的调用不影响它。`receive` 保存的位置参数仍独立可用，默认式与关键字解析由生成方按求值顺序执行。

`(rest VAR FIRST (stack CAPACITY))` 为整个后缀能放入的调用选择固定栈 cons；超出容量时整条列表使用堆存储。Rust 建立栈槽、初始化对象并登记精确 roots，在普通返回和尾调用前逆序撤销，非局部展开由 runtime 摘除。生成方保证栈列表及尾部不逃逸，也不通过返回、多值或写入堆对象泄漏；允许返回从列表取出的独立堆对象。验证器检查变量表示、起始序号、容量和帧范围。生产路径的 `rest-list` 共用列表构造，Lisp 只提交起始位置与已登记的候选 cons 槽，不选择地址或安排 roots 切换。

函数以 `(captures N)` 声明环境中的对象捕获项数，`(capture-ref I)` 从本函数的 self 读取第 I 项。带捕获的入口由 `(make-closure RESULT "ENTRY" heap (捕获值...))` 建立，捕获值须先求值为普通对象变量；Rust 在分配前保存它们，允许 RESULT 与输入变量相同。递归组用 `(alloc-closure RESULT "ENTRY" heap)` 先分配并清零环境，再以 `(capture-set CLOSURE "ENTRY" I VALUE)` 填充引用；填充期间发生 GC 也能扫描所有成员。`capture-set` 的入口名用于校验环境长度，生成方保证对象具有该入口的环境形状。表示、header、环境起点与入口指针均由 Rust 决定。

验证器检查捕获项数量、类型、初始化及下标，堆闭包分配使旧多值视图失效，并使用所在动态区域的 handler。要求捕获的入口不能作为零环境的静态函数对象取得，也不能成为模块 init。Rust 只为零捕获入口建立静态函数对象。

函数用 `(stack-object NAME cons)` 或 `(stack-object NAME (closure "ENTRY"))` 声明命名的栈对象。cons 的分配写为 `(alloc RESULT cons (stack NAME) (CAR CDR))`；make-closure 与 alloc-closure 也接受 `(stack NAME)`。Rust 根据对象种类和入口的捕获项数安排固定栈槽，输入记录不包含字节大小、地址、tag 或引用字段起点。

栈对象由 `(region R stack-roots OUTER NAME)` 管理；enter 不接收参数，先初始化 header 并清零全部字段，再登记引用区。分配该对象时，匹配的根区域必须活动，且同一对象只能被一个活动区域登记。每次区域进入与对象重新初始化都清零引用字段，闭包入口在建立闭包时写入。leave 摘除引用区；非局部展开由 runtime 摘除。stack-roots 没有 handler，区域内调用使用外层的 handler。栈分配和根登记不分配堆内存、不覆盖传递区，因此保留当前多值视图。

存储选择仍是生成方的证明：同一栈槽中不能同时存在两个仍可观察的身份，引用不能越过根区域的生命周期，也不能写入堆对象或通过返回与尾调用离开本帧。Rust 检查声明、布局匹配、活动区域、帧地址范围和初始化展开预算，继承生成方的逃逸与生命周期证明。栈对象可以引用其他生命周期相容的栈对象；各对象的堆引用字段分别登记为精确 roots。

局部变量使用 `obj`、`word`、`f64`、`mv` 四种表示。常量提供 `word`、`fixnum`、`character`、`single-float`、`f64` 位模式、`nil`、`t` 和两种未绑定标记。`literals` 声明 image literal 表大小，`literal` 只按合法下标引用；Rust 建立表和静态 roots，安装器检查实际向量与声明一致。

函数可声明 `(debug NAME FILE START END ((VAR NAME [cell])...))`，名称与文件使用常量字段语法，范围使用非负 32 位偏移。变量须已声明且表示为 `obj` 或 `f64`；cell 只用于对象变量。Rust 构造函数描述和变量名向量，按变量表示生成 cell 或 binary64 描述并标记 KIR 变量位置。描述中的 image literal 与普通常量字段共用安装期绑定。cell 与 binary64 描述引用运行环境的标准关键字符号，以保持 debugger 的标签身份。`call` 的 `loc` 优先于函数范围；变量值只在调用点存活时可见。

核心操作包括机器字计算与比较、对象同一性、fixnum 计算和装拆箱、字符装拆箱、binary64 计算及 double 拆箱、simple-vector 和字符串读取。操作表同时定义纯操作的名称、参数表示和结果表示。`test` 接收表示类名，对任意 Lisp 值安全；`field-ref` 和 `field-set` 使用 `cons.car`、`symbol.function` 等字段名。`alloc` 接收结果、对象种类、存储方式和字段列表，例如 `(alloc pair cons heap (head tail))`。目前支持 cons、double-float、complex 和普通实例的堆分配。Rust 保存所有字段后分配、初始化；对象字段跨慢路径保持精确 roots，允许结果变量同时作为旧字段输入。

`(error CODE VALUE [(loc START END)])` 是可展开的终结操作。CODE 使用目标描述的语义错误码，VALUE 是对象变量。Rust 调用当前 `%runtime-error` 定义；定义尚不可用或意外返回时调用 fatal runtime 入口。验证器检查错误码、位置、对象表示与初始化，并将所有活动 handler 的异常边纳入 CFG。生产路径的 `signal-error` 与独立 LIR 共用此展开，Lisp 不再读取错误函数的代码入口或安排分派调用。

`(fatal-error CODE VALUE [(loc START END)])` 直接终结进程，CODE 为机器字变量，VALUE 为对象变量。它不调用 Lisp 条件处理函数，不恢复当前动态区域；Rust 提供终止 runtime 调用及其帧参数。验证器检查表示、初始化和源码范围，控制流没有后继。生产路径也使用此终结操作，不声明 fatal runtime 的 C 签名。

`(numeric RESULT OP (ARG...) 选项...)` 执行具名的整数或实数操作，产生 `mv` 视图。操作表在 Rust 中绑定到 runtime 操作码、参数数量和返回值数量；整数与一般实数的 truncate、floor、ceiling、round 返回商与余数，其余操作返回一个值。Rust 安排 context、运行时调用及次值传递。所有参数为对象变量，验证器检查数量、表示和初始化，数值操作覆盖旧多值视图，并与 call 使用相同的区域、位置和异常边规则。除 `number-eql` 接受任意对象外，生成方应在语言语义要求的位置完成数字类型与除零检查；原语本身复用 runtime 数值入口的错误行为。

生产原语也使用具名操作，兼容载荷的 `numeric-op` 与独立 LIR 共用 Rust 展开。Lisp 不声明数值 runtime 调用签名，不携带数值操作码，也不读取余数槽或指定数值操作的返回个数。

动态容器使用 `(alloc-sequence RESULT simple-vector|string LENGTH INITIAL)`，LENGTH 为未装箱机器字，INITIAL 为对象；字符串初值为字符。Rust 检查长度在目标 header 的范围内，并检查字符串初值的表示，随后保存输入、分配和填充。`(vector RESULT (ELEMENT...))` 从已求值的对象建立 simple-vector，允许 RESULT 与输入相同。输入对象跨慢路径保持 roots。分配使旧多值视图失效，异常边来自操作之前。

`(alloc-structure RESULT LAYOUT COUNT INITIAL)` 建立带布局描述及 COUNT 个引用槽的结构对象。`(alloc-instance RESULT standard-instance|funcallable-instance CLASS COUNT STAMP SLOT-DEFINITIONS INITIAL)` 建立实例；COUNT 只计算用户槽，INITIAL 为用户槽初值。Rust 保存全部对象输入、检查 COUNT 范围、构造 rack 及其元数据，并为 funcallable 实例安装标准入口和未设置的函数对象。描述不包含 header、rack 大小或代码地址。

结构和实例的读取包括 `structure-layout`、`structure-slot`、`instance-rack`、`instance-class`、`instance-stamp`、`instance-slot-definitions`、`instance-slot` 和 `funcallable-function`。写入使用对应的 `*-set` 操作；vector 和 string 的元素写入为 `vector-set`、`string-set`。索引为机器字，值为对象。生成方保证对象类别和索引范围符合操作含义；元数据使用具名操作。Rust 决定标准与 funcallable 实例的不同字段位置。读取和写入不分配、不覆盖多值区。

`(runtime RESULT OP (ARG...) 选项...)` 调用闭合的 runtime 服务集合，包括 GC、跨栈调用、身份哈希、I/O、编译与 packet 适配器、堆快照、帧检查和浮点十进制拆分。参数和结果均为对象。Rust 表定义参数数量、runtime 名称、调用签名及 safepoint 效果；源请求不声明这些 ABI 属性。调用位置使用 `loc`，可能展开的服务须标注当前 handler。叶服务可省略区域标注；提供时仍须与当前 handler 一致，后端不会为叶服务生成展开分支。

GC、跨栈 Lisp 调用和 packet 编码可能 safepoint，因此使旧多值视图失效，并产生操作前的异常边。其余服务按当前单 mutator runtime 的 NoSafepoint 合同执行，不覆盖传递区，保留借用视图；运行期编译先取得 Rust 自有记录，再注册代码与 roots，期间不调用 Lisp。身份哈希继续使用后端的缓存快路径。`frame-pointer` 返回供帧服务使用的不透明对象 token，生成方不构造地址或进行布局换算。

生产发射以 `runtime-op` 提交相同的具名服务和已求值对象，由同一张 Rust 表补齐 imports 与调用序列。当前动态 handler 由生成方统一标注，是否需要展开分支由后端决定。

`call` 接收一个 `mv` 结果、函数对象变量、实参变量列表、可选的 `loc`，以及有 handler 时必需的 `(region R)` 标注。`values` 建立临时多值视图，`mv-count` 读个数，`mv-ref` 按固定序号取值、不足补 NIL，`return-mv` 返回该视图。`return` 直接接收对象变量列表，`tail-call` 接收函数对象和实参列表。寄存器、传递区、主值与计数的配对都由 Rust 选择。

`(call-known view "ENTRY" callee (arguments...) ...)` 保留已知局部入口的直接调用。验证器检查入口存在及操作数表示；生成方保证 callee 的环境适用于该入口。Rust 仍安排参数、self、handler 和返回值，输入没有代码地址。

`(call-spread RESULT CALLEE (固定实参...) LIST 选项...)` 将已求值的固定实参与 LIST 的元素一起交给函数对象，返回 `mv`。它与 call 使用同样的源码位置和区域标注，覆盖旧多值视图，异常边也从调用前的状态出发。Rust 检查动态列表的 cons/NIL 结构和总参数容量，安排寄存器与传递区，并在填充和实际调用之间保持无 safepoint。展开最多读取目标允许的参数数目；非 proper 的尾部和容量溢出分别走类型错误与参数数量错误路径。

生产 Lisp 的 `emit-apply` 提交兼容操作 `invoke-list`，包含已求值的固定参数向量、列表及 handler/位置；它与独立 LIR 共用上述 Rust 降级。固定参数直接传入后端，保留求值顺序。兼容解析器按需补齐 NIL、当前 `%runtime-error`、未定义函数入口及 fatal error 的后端依赖。

`(mv-move destination source)` 将当前视图改用 destination 这个名字；目标不同于 source 时，旧名字失效，原地移动保持有效。它不修改传递区、不分配，两个分支可移动到同一个目标视图后合流。验证器在移动前检查 source，在合流后要求目标视图在每条路径上有效。

`(mv-save saved view)` 将当前视图保存为普通 `obj`，并使旧视图失效；`(mv-restore view saved)` 恢复它，建立新的视图。保存载体是后端私有的不可变对象，生成方只能把遵守同一保存契约的对象交给 restore。Rust 在保存前保护主值和传递区，逐项分配时维持精确 roots。当前使用包含全部值的 proper list，包括零值的空表和单值的一元素表；恢复不分配。保存后的对象可以跨调用、GC 和 cleanup 存活。

`(values-from-list view list)` 检查 proper list 和多值上限后建立多值视图；循环表也会在上限检查处报错。`(mv-push result view accumulator)` 将视图中的值按逆序压入 accumulator，得到普通对象并使旧视图失效。两种操作的检查、遍历和分配保活由 Rust 生成。

函数声明 `(region R KIND OUTER LANDING)`，根区域的 OUTER 为 `nil`。`catch`、`unwind-protect` 和 `exit-point` 声明 landing；`bind` 和 `progv` 省略它；stack-roots 在相同位置指定栈对象名。`(enter R (参数...))` 和 `(leave R)` 保留求值与动态作用域的顺序。catch 接收 tag，exit-point 接收堆令牌，bind 接收 symbol 与新值，progv 接收符号列表与值列表；unwind-protect 没有参数。生成方负责符号及 proper list 的语言检查。Rust 分配动态条目栈槽、初始化和链接，离开时恢复绑定并摘除条目；progv 先保存完整的旧绑定列表，再链接条目并写入新值。值列表不足的位置写入未绑定标记。`special-ref` 和 `special-set` 按动态绑定或全局格读写，未绑定检查仍由生成方编排。

catch 和 exit-point 的 landing 块以 `(landing R view)` 开始；异常到达时 runtime 已摘除该区域。unwind-protect 的 landing 以 `(landing R)` 开始，此时条目仍以 cleanup 运行状态链接。cleanup 正常完成用 `(continue-unwind R)` 继续，另一条本地退出路径可以先 leave 放弃待继续的展开。cleanup 中的调用使用外层 handler；Rust 生成的分派链按当时的活动区域确定，允许 cleanup 内建立新的 catch。`(throw tag view)` 和 `(exit-to token view)` 是终结操作，Rust 负责单值与打包多值的 payload，目标不存在时调用当前 `%runtime-error` 定义。

验证器把正常边和各可能展开操作的异常边都纳入 CFG。异常边上的初始化集合来自操作执行之前，不能把调用结果当成已经赋值；落地状态反映已弹出的条目或仍链接的 cleanup。progv 在条目建立前的分配使用外层状态。

模块的 `(cells VALUE...)` 声明可变静态对象槽，初始值使用常量字段语法。`(cell-ref I)` 和 `(cell-set I VALUE)` 按下标读写，验证器检查下标、对象表示和输入初始化。Rust 建立私有数据表并登记每个槽为 root，image literal 初值由安装器绑定；cell 不参与常量内容合并。

模块的 `(constants NODE...)` 声明按下标确定对象身份，表达式 `(constant I)` 引用节点。节点使用 `(string "...")`、`(cons A B)`、`(vector A...)`、`(ratio A B)`、`(complex A B)` 、`(bignum "十进制整数")` 或 `(double-bits BITS)`；字符串也可逐项给出字符码。对象字段接受立即数、`(constant I)` 和 `(literal I)`，支持前向引用和循环。验证器检查引用范围、字符范围、数值规范化条件与总展开大小，Rust 构造 header、标签和重定位，并登记所有对象字段为静态 roots。image literal 字段先生成占位 word，安装器在登记数据后从 literal 向量绑定；整个安装过程没有 Lisp safepoint。文件驱动拒绝需要 image literal 绑定的模块。节点使用模块名和下标生成私有链接名。相同内容的字符串合并，非循环 cons 按字段引用身份与立即数递归合并；循环 cons、依赖循环的 cons 和 vector 保留声明身份。数值节点保留声明身份。`(symbol "包名" "符号名")` 生成与其他文件模块相同的共享链接名；`(uninterned "名字" 编号)` 按模块名和编号区分身份，重复编号要求名字一致。`(function "入口")` 引用零捕获函数。symbol 的名称、包名、未定义函数对象和可变字段 roots 都由 Rust 生成。静态 symbol 描述用于文件模块的链接共享；引用已有 image 内的 symbol 时使用 literal，保留包系统的对象身份。ratio 的两个字段须为整数，分母大于一且分子分母互质；complex 的两部分须同为有理数或同一浮点格式，有理数虚部非零。这些数值字段不能使用类型未知的 image literal。

验证器在产生 KIR 之前检查以下性质：

- 函数、变量、区域和块名唯一，入口与所有跳转目标存在，每个块有唯一终结操作，switch 键不重复。所有块都验证结构和表示；可达部分验证数据流，降级时略去不可达块。
- 所有操作的参数和结果表示匹配；常量、入口参数、literal 和多值下标符合目标限制；原始地址、偏移、context 和代码入口不属于该语言。
- 按 CFG 传播确定初始化集合，在合流点取交集，并求固定点，覆盖循环首次进入、回边和异常落地。
- 区域声明的外层关系无环，每条路径上的 enter/leave 配对，合流点的活动区域栈一致。普通跳转不能进入 landing；返回和尾调用要求本帧没有活动条目。调用标注必须是当前最内层的 handler，跳过 bind、progv、stack-roots 和运行中的 cleanup；continue-unwind 要求匹配的 cleanup 位于最内层。
- 临时多值只能在当前有效视图上读取或返回。调用、重新发布多值、保存视图、progv 进入时的分配、显式分配、显式 poll 和后端插入的循环 poll 都使旧视图失效；合流点要求每条路径保留同一视图。多值视图不能普通复制或 select；显式 `mv-move` 将当前借用改用新名字，旧名字随即失效。

验证成功产生供降级器使用的受检引用；不能绕过验证直接调用降级。Rust 在入口安排栈检查，并通过包含异常边的 CFG 的 DFS 回边目标块选择循环 poll。删除全部 DFS 回边后图无环，因此该集合覆盖不可约循环和多个入口的强连通分量；不依赖块编号。循环 poll 对多值借用的影响也计入验证。插入 poll 后重新传播其异常边并更新 poll 集合，直到覆盖最终图。

独立核心的静态常量图支持 symbol、uninterned、function、string、cons、vector、bignum、ratio、complex 和 double 位模式；调试变量支持对象、cell 和未装箱 binary64；入口 rest 支持堆分配、栈存储与容量回退；剩余运行时操作及生产参数绑定发射仍在接入。Lisp 生产编译器仍输出兼容载荷。后续扩展继续使用上述独立数据结构和验证入口；下文描述完整的目标契约。

## 原则

- **布局无关**：LIR 里不出现 tag、偏移、kind 编号、context 字段和 `ctx.values` 下标。对象种类和字段用名字，名字集合来自目标描述。
- **决定已经做完**：LIR 不留需要类型推导或 Lisp 环境才能做的决定。Rust 不进行类型、别名、逃逸等语言语义推导，不重新选择表示；它可以进行验证和低层展开所需的控制流分析，生成快慢路径、handler 分派和 ABI 适配块。机器层的优化由 Cranelift 做。
- **Lisp 证明，Rust 信任**：栈存储的安全、`fixnum-tag` 的范围、已知函数的参数个数等性质由 MIR 证明。Rust 不重复证明语言性质，但必须验证结构、变量初始化、区域和临时多值的合法使用，并保证自身生成的栈槽、roots、清理和布局正确。
- **确定**：同一输入产生规范化的 LIR 二进制记录；kiln-cg 的输出由 LIR、目标描述和后端配置共同决定。自举逐个比较 LIR 文件，kiln0 和 kiln1 逐字节相同的要求不变。

兼容载荷中的 `arg-ref`、`arg-read` 和 `arg-write` 使用保存的寄存器参数，由后端选择寄存器或传递区；动态下标范围由生成方检查。`invoke-prepared` 在参数已填充后调用函数对象，接收参数计数和保存的寄存器参数，保留 handler 与源码位置；后端验证常量计数的容量，动态计数由生成方保证。

## 变量和表示

LIR 和 KIR 一样使用可赋值的变量，不是 SSA：MIR 退出 SSA 时将块参数转换为边上的并行复制，必要时拆分临界边，并用临时变量消除复制环，kiln-cg 再用 cranelift-frontend 构造 SSA，并由它在 safepoint 处为对象引用插入溢出和重载（C5）。Rust 无须构造另一套用于语义优化的 SSA；允许使用 CFG 状态传播验证变量、动态区域和多值的使用。

| 类别 | 含义 | GC |
|---|---|---|
| `obj` | Lisp 值（立即数或对象引用） | 跨 safepoint 存活时登记为根 |
| `word` | 64 位整数：未加 tag 的整数、条件的 0/1、计数 | 不登记 |
| `f64` | binary64 | 不登记，用浮点寄存器 |
| `mv` | 一组多值（见下文“多值”） | 由 Rust 安排 |

变量可以带源码变量的调试描述（名字、cell 或机器值表示），Rust 据此写帧的调试记录（[debugging.md](debugging.md)）。

## 操作

下面按类列出操作的种类，具体的名字和签名在实现时写进操作表，编号、参数类别、结果和效果纳入同一 schema。下列 s-expression 只是可读记法，不是传输编码。

- **常量**：常量表里的项、fixnum、字符、`nil`、`t`、未绑定标记。
- **类型测试**：`(test x CLASS)` 得到 `word` 0/1。`CLASS` 是目标描述里列出的表示类：fixnum、cons、symbol、function、funcallable-instance、simple-vector、string、bignum、ratio、double-float、single-float、complex、character、standard-instance、structure-instance 等，以及若干组合类（如“堆上的数”）。`list`、整数区间、`member` 这类组合由 MIR 用分支表达。
- **fixnum**：带溢出标志的加、减、乘，比较，按位运算，移位，除法和余数；`fixnum-untag`（`obj` → `word`）和 `fixnum-tag`（`word` → `obj`，范围由 MIR 保证）。tag 的位置和“带 tag 直接相加”这类技巧只在 Rust 里。
- **浮点**：`f64` 的算术和比较；`box-double`、`unbox-double`；single-float 的位模式。
- **字段**：按对象种类和字段名读写，例如 cons 的 car/cdr、symbol 的各个 cell、函数对象的环境第 i 项、simple-vector 和字符串的第 i 个元素（下标是 `word`）、rack 的槽、结构对象的槽、对象的长度。写入对象引用时由 Rust 插入需要的写屏障。
- **分配**：`(alloc KIND STORAGE 字段...)` 和变长的 `(alloc-vector KIND 长度 初值 STORAGE)`。`STORAGE` 是 `heap` 或 `stack`。`stack` 表示 MIR 已经证明身份不越过本帧、同一分配点不会同时有两个活的对象；Rust 为每个分配点安排固定栈槽，把引用字段登记为精确根。堆分配由 Rust 生成 bump pointer 快路径和慢路径。
- **函数和闭包**：`(static-function F)` 是没有自由变量的函数对象；`(make-closure F STORAGE 捕获值...)`；`(closure-ref i)` 读本函数的第 i 个捕获值；`(make-cell v)`、`(cell-ref c)`、`(cell-set c v)`。函数对象和 cell 的布局由 Rust 决定。
- **全局**：special 变量的读、写、`boundp`（TLS 和全局值的查找在 Rust）；symbol 的函数 cell 和 `(setf f)` cell；`load-time-value` cell 和调用点缓存的读写。
- **错误**：`(error CODE v)` 是终结操作。错误码来自目标描述；Rust 展开成调用 `kiln.kernel::%runtime-error`、未定义时结束程序。

## 函数和调用

函数头声明外部或内部入口、参数接收上限与捕获项前缀。Lisp 生成完整的参数绑定程序，包括参数数量检查、`&optional`/`&key` 的默认式与 supplied-p、rest 身份、声明检查及初始化顺序；这些都是可优化的普通控制流。LIR 以 `receive` 和 `rest` 声明入口所需的位置参数与后缀列表，`arg-count` 与 `arg-ref` 供绑定程序使用。Rust 实现寄存器与传递区读取、列表分配和入口参数保护；缺失的位置参数槽保存 NIL，默认式仍由 Lisp 程序执行；Rust 不维护另一套 lambda-list 语义。

调用：`(call 结果 CALLEE (实参...) 选项)`。

- `CALLEE`：`(global sym)`、`(global-setf sym)` 读函数 cell；`(known F 捕获...)` 是已知的局部函数，直接调用入口；`(value f)` 调用一个函数对象；`(runtime 名字)` 调用 runtime 函数。
- 结果：`primary`（只要主值）、`(fixed n)`（前 n 个值，不足补 NIL）、`mv`（全部值）。
- `(spread list)`：最后一个实参是列表，按 `apply` 展开。
- `(region R)`：调用可能展开时所在的最内层带 handler 的区域；`(loc 起始 结束)` 是调用形式的源码范围。
- `tail-call` 是终结操作，只能在没有活动区域的地方使用。

寄存器参数、传递区、`nargs`、返回值的个数和 `ctx.values` 的使用都由 Rust 按 [abi.md](abi.md) 安排。

## 多值

兼容载荷的 `argument-roots` 和 `value-roots` 接收完整的实参或返回值计数，由后端扣除寄存器部分并设置传递区根范围。零计数不产生根；常量计数检查容量，动态计数范围由生成方保证。

兼容载荷的 `secondary-value-ref` 和 `secondary-value-set` 按返回值序号访问次值，序号从 1 开始；后端映射到传递区并检查常量序号的容量。动态序号范围由生成方保证。

`mv` 变量由调用、`(values ...)`、`(landing ...)` 或 `mv-restore` 产生。它是短期借用的返回值视图，在任何可能覆盖多值区的操作或 safepoint 之前必须被消费：取第 i 个值、取个数、作为返回值、作为 `mv` 结果的实参展开，或用 `(mv-save m)` 存成 `obj`（以后用 `(mv-restore o)` 取回）。`mv-save` 自身可能分配，Rust 必须先保护主值、计数和其余值，不能先触发 GC 再读取旧视图。验证器按 CFG 检查视图有效性；需要跨块或跨 cleanup 保存时优先显式保存。值的个数固定的地方，MIR 应当直接用 `(fixed n)` 拆成普通变量。Rust 负责把主值、个数和 `ctx.values` 映射到 `mv` 上。

## 动态范围和退出

函数头声明这个函数里的区域：`(region R KIND 外层区域 [landing 块])`，`KIND` 是 `catch`、`unwind-protect`、`exit-point`、`bind`、`progv`。代码里用 `(enter R 参数...)` 和 `(leave R)` 建立和撤销；`enter` 的参数是 catch 的 tag、退出点的令牌、special 绑定的符号和值。条目的布局、链入 context、特殊变量的保存和恢复都在 Rust。

- **本地退出**：MIR 生成 `leave`、内联的 cleanup 代码和跳转，Rust 不重新安排。
- **非局部退出**：`(throw tag mv)`、`(exit-to token mv)` 是终结操作。退出令牌是堆对象（C5：堆对象不能指向栈帧），由 MIR 用普通分配生成。
- **落地**：带 handler 的区域有 landing 块，以 `(landing R)` 开始，得到传来的值（`mv`）；`exit-point` 的 landing 还得到 `go` 的目标下标。不是本区域的展开，由 Rust 生成的分派转给外层区域的 landing。`unwind-protect` 的 landing 执行 cleanup 后用 `(continue-unwind R)` 继续展开。payload 怎么编码多值由 Rust 决定。

区域嵌套和 `region` 选项由 Lisp 给出，Rust 的验证器检查每条路径上 `enter`/`leave` 成对、调用标注的区域是当时最内层的带 handler 区域。

## 纯标量操作

机器字操作覆盖加、减、乘、带符号商与余数、按位运算、有符号比较及三种移位。`word-shift-right` 做算术右移，`word-shift-right-logical` 补零；计数为机器字，生成方保证在 0–63 内。除法要求除数非零，并排除最小机器字除以 -1。fixnum 的比较、位运算、奇偶检查、折半、商与余数、移位使用对象输入；移位计数也是 fixnum，范围为 0–62。生成方负责 fixnum 类型及结果范围事实，Rust 选择带 tag 的计算方式。

`single-float-tag` 与 `single-float-bits` 在对象和 32 位 IEEE 模式之间转换。`f64-from-bits` 与 `f64-bits` 在机器字和未装箱 binary64 之间按位转换，保留负零和 NaN payload；它们不做数值转换。`f64-compare` 返回 -1、0 或 1，unordered 返回 0，延续 runtime 数值比较的三路约定。普通 `f64-add/sub/mul/div` 接收并返回 `f64`。不同表示不能隐式混用，操作表定义参数和结果类型，验证器在降级前检查。

这些操作不分配、不覆盖多值区，不引入 Lisp 异常边。无效的机器除法及移位输入不属于支持的操作域；语言错误须由生成方在进入纯操作前分派。

## 受检 fixnum 运算

`(fixnum-add-ovf result overflow left right)`、`fixnum-sub-ovf` 和 `fixnum-mul-ovf` 接收两个已证明是 fixnum 的对象，产生对象候选结果和机器布尔溢出标志。候选结果只在未溢出的路径上作为算术结果使用；生成方选择大整数慢路径。结果可以覆盖任一输入，后端在写结果前读取输入。两个输出同时初始化；操作不分配、不展开并保留当前多值视图。tag 计算与机器溢出序列在 Rust 中选择。

## poll 点

Rust 在函数入口生成栈检查（包括“参数全在寄存器里的函数经共享慢路径重试”的做法），并保证所有可能无限执行的循环路径经过 safepoint。根据 CFG 的循环结构安排 poll，覆盖不可约循环，不以块编号倒序代替循环分析；见 [abi.md](abi.md) 的“Poll 点”。LIR 也可以写显式的 `(poll)`。

## 常量和模块

模块头记录 schema 版本、目标指纹、后端配置和模块名，指纹不符时 kiln-cg 拒绝。模块包含 init 函数、函数、常量表、静态 cell 和 root。

常量表用可移植的描述，不含地址：

- `(symbol "包" "名字")`、`(uninterned "名字" 编号)`；
- `(string "...")`、`(cons C C)`、`(vector C...)`、`(bignum "十进制整数")`、`(ratio C C)`、`(double 位模式)`、`(complex C C)` 等，`C` 是常量表下标或立即数；
- `(literal i)`：运行中 image 的对象，取自和 LIR 一起交给 `kiln_rt_jit` 的 literal 向量，保持对象身份；
- 可变的静态数据单独列出：`load-time-value` cell、调用点缓存（[specialization.md](specialization.md)）。它们不参与合并。

静态数据的布局、symbol 的共享定义（[codegen.md](codegen.md) 的“多模块”）、静态字符串和 cons 按内容合并的规则在 Rust 里实现；SBCL 上的交叉编译因此不需要知道任何对象布局。

## 目标描述

布局和 context 常量只在 kiln-rt 里定义。kiln-cg 生成一份目标描述（s-expression），供 Lisp 编译器在编译期读入，内容只有语义上需要的部分：

- fixnum 的范围、`char-code-limit`、`call-arguments-limit`、`multiple-values-limit`、数组大小上限；
- 表示类、对象种类、字段名和错误码的列表（用于检查 `%primop` 和 MIR 的降级）；
- ABI 指纹和 LIR 版本。

`lisp/abi.lisp` 换成读入这份描述；测试检查仓库里的副本和 kiln-cg 生成的一致。

## 结构化交接

LIR 请求从第一版起采用下述[编译协议](compiler-protocol.md)。运行期批量提交结构化记录并由适配器转交 Rust 所有权，生产构建文件默认保存这些记录的规范化二进制编码。解码与快照适配器进入同一个操作验证和 KIR 构造路径，避免进程内的序列化往返。可读的 LIR/KIR dump 只供诊断，不是编译输入的中转步骤。

## 迁移期间

先由现有 HIR 降级产生 LIR。kiln-cg 暂时同时接受旧 KIR 和新 LIR 输入，以便对照输出；新生产入口不依赖旧文本入口。MIR 接入后直接以相同 LIR 契约为目标。切换和删除门槛见 [compiler.md](compiler.md#切换门槛和验证范围)。
