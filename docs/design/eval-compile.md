# 运行期求值、编译和文件加载

运行期与编译期共用 HIR 前端。eval 模块提供词法环境、宏展开、HIR 分析与求值，
compiler 模块安装 HIR → KIR → Cranelift 的原生入口。两种执行方式构造的函数
都可与 AOT 函数互相调用；全局函数、特殊变量及宏定义属于同一个运行中 image。

## 目标后端交接

目标原生路径为 Lisp 的 HIR/MIR → 表示选择 → LIR 请求 → Rust 布局与 ABI 降级 → 内存 KIR → Cranelift。HIR 求值器继续留在 Lisp。运行期直接提交连续二进制缓冲区和受保护的 literal 向量，不生成 LIR 或 KIR 文本；请求失败与产物发布采用 [compiler-protocol.md](compiler-protocol.md) 的所有权规则。当前原生入口已切换结构化 packet，载荷仍是 KIR；布局和 ABI 降级尚未移交 Rust。FASL 版本 2 保存 packet，加载不解析 KIR 文本。

## 模块与自举边界

编译器的前端与 HIR 求值器随 eval 模块载入，因此原生编译入口安装前已经能够
运行宏、`eval` 和 `compile`。求值器把分析后的 HIR 节点构造成原生闭包，不需要
调用正在初始化的原生编译器。编译期和解释执行共用相同的词法绑定、声明、捕获、
多值与退出分析。cross-client 的全局定义保存在 Clostrum 环境中，image-client
直接访问运行中 image；后者的动态绑定使用运行时 `progv`。

模块按依赖顺序加载：

1. frontend 提供 Eclector CST reader。
2. eval 提供 Ecclesia、运行期 Common-macros、Trucler 查询协议和 image 全局环境。
3. eval 中的共享前端包含 Trucler reference 环境、Clostrum、Anatomicl、HIR、
   KIR 降级及 image-client。求值路径不调用降级和机器码生成。
4. eval 提供 HIR 执行入口、编译单元、FASL 对象图、文件和模块加载、REPL 及后端协议。
5. compiler 提供内联元数据、依赖追踪、顶层原生缓存、原生 `compile` / `eval` 和
   `compile-file`。安装入口后，完整开发 image 默认生成原生代码。

运行期 Common-macros 使用 `kiln.cmd` 包；kernel 和 CLOS 自带宏保持优先。
标准宏、setf 展开器、类型展开器和自定义声明使用同一套 image 元数据。环境查询
通过产生环境的 client 处理，局部宏和 symbol macro 直接保留 HIR/Trucler 环境，
不转换为另一种求值器环境。

`tools/repl.sh` 构建 kernel、CLOS、frontend 和 eval，使用 HIR 求值。
只需要解释执行的发行版可裁剪未调用的降级与原生编译入口；具体体积取决于裁剪结果。
完整开发 image 载入 compiler 后使用原生入口。

## `provide` 和 `require`

`provide` 把字符串设计符转换为名字，按 `string=` 去重后加入 `*modules*`，返回 T。`require` 已登记的模块时不加载文件；否则按顺序加载指定的单个 pathname 或 pathname 列表，即使第一个文件已调用 `provide`，也继续加载其余文件。模块代码负责调用 `provide`，`require` 不自动登记名字。返回值是本次新增登记的模块名字列表。

未指定文件时，`require` 按顺序调用 `kiln.kernel::*module-provider-functions*`，直到某个函数返回真，传入原始名字设计符。该列表初始为空，找不到 provider 时报告错误。嵌套加载会检查循环依赖；错误或非局部退出会恢复当前加载栈。

## 编译单元

`with-compilation-unit` 将原生编译和 HIR 求值中的未知函数引用延迟到单元结束，再根据最终函数定义决定是否报告。未知变量警告同样延迟；后来初始化变量不撤销先前缺失声明的警告。其他警告即时报告。普通嵌套单元共用外层队列，`:override` 为真时建立独立队列；重复函数引用合并，已经补齐的定义不再警告。

单元返回主体的全部值。正常返回、错误或非局部退出都会结束当前单元并恢复外层状态；独立内层单元的结束警告直接报告，不重新加入外层队列。

## 编译文件的路径和动态状态

`compile-file-pathname` 按输入路径、显式输出路径和 `*default-pathname-defaults*`
计算产物名，默认类型为 `fasl`（逻辑路径为 `FASL`）。输出路径未指定目录时沿用
输入目录；显式输出类型予以保留。函数接受编译器的其他关键字，不访问文件系统。

这些接口随 eval 模块提供。`*compile-file-pathname*`、`*compile-file-truename*`
初始为 NIL，`*compile-print*` 初始为 NIL，`*compile-verbose*` 初始为 T。

## 原生 `compile`

compiler 模块的 `lisp/target/compiler/native.lisp` 把 `kiln.kernel::*compile-function*` 设成 `native-compile`，此后的 `compile` 都编成机器码。这个变量为 NIL 时构造 HIR 求值闭包。compiler 模块初始化期间的 `compile` 使用已经就绪的 HIR 求值器。

1. `native-compile` 新建一个 session（`image-client`），然后：
   - 用 `front-end-forms` 处理 `(setq *compiled-function* (function LAMBDA))`（和 `front-end` 一样，只是直接处理形式，不读文件）；
   - 用 `compile-module :image t` 降级；
   - 用 `module-packet` 编码成带版本和目标指纹的记录字节；
   - 把 packet 和字面量向量交给 `(%primop :compile-packet packet literals)`，即 kiln-cg 的 `kiln_rt_compile_packet`（[codegen.md](codegen.md)）。它返回 init 函数对象，KIR 编不过时返回 NIL，`native-compile` 据此报错。
2. `native-compile` 动态绑定 `*compiled-function*`，调用 init 函数，取出编好的函数。

### image 模式的 KIR

编进运行中 image 的代码，引用的是 image 里已有的对象。和编译文件相比有三点不同：

- **字面量**：除立即数（fixnum、字符、单精度浮点、NIL、T）以外，字面量一律占用模块数据 `kiln_literals` 的一个字。每个字都是 static root，数据字写成 `(:literal i)`，操作数是 `(load (addr "kiln_literals") 8i)`。`compile` 不复制字面量（CLHS 3.2.4），未 intern 的符号、列表都还是原来那个对象。符号也走这条路：运行期 intern 的符号在堆里，GC 会移动它们，不能把地址编进代码。代价是全局函数调用和特殊变量的访问各多一次 load。
- **没有符号表**：符号都已经在 image 里，init 函数不调用 `%register-module-symbols`。
- **共享的定义用 image 的**：未定义函数的入口和 funcallable instance 的跳板要和函数槽里的值比较（`fboundp`、报错代码），所以必须是 image 里的那一份，写成 `import-data`，由 kiln-cg 按导出的名字解析。

### 内存

运行期编出的模块共用一块预留的 16 GiB 地址空间（固定地址 `0x3800_0000_0000`，`rust/kiln-rt/src/code.rs`）：只预留，用到时才提交，从低往高分配，从不释放。各模块的表在 kiln-rt 里留一份，堆快照可以连同这些代码一起保存（[heap-image.md](heap-image.md)）。代码目前不回收。

## 原生 `eval` 和 `load`

compiler 模块载入后，`eval` 也走原生编译（`native-eval`，挂在 `kiln.kernel::*eval-function*` 上；绑成 NIL 则用 HIR 求值）。`load` 和 REPL 都经过 `eval`，所以载入的源文件和 REPL 里定义的函数都是机器码。做法和 SBCL 的 `eval` 一样：

- 不需要代码的形式直接求值：符号（先处理 symbol macro）、自求值对象、`quote`、`(function 符号)`。
- `progn` 和 `eval-when`（含 `:execute` 时）逐个求值子形式，所以 `defmacro` 在下一个子形式编译之前就已生效。
- 宏形式先展开一层再判断。展开定义宏之前记下定义的名字（`definition-name`），交给前端（`*eval-definition*`），调试信息和依赖追踪按它命名（[debugging.md](debugging.md)、[dependencies.md](dependencies.md)）。
- 其他形式作为顶层形式编译，然后调用。

每个形式至少多花几毫秒的编译时间，交互时察觉不到。对只为展开宏或只运行几次的代码，编译时间占主导：这样的 `compile` 要把 `*compile-function*` 绑成 NIL，构造 HIR 求值闭包。交叉编译的编译期求值用 HIR 求值器（构造宿主闭包），不经过 `compile`。

`symbol-macrolet` 在字节码和原生前端都拒绝常量、全局特殊变量，以及对自身绑定的 `special` 声明；内层自由声明和新变量绑定仍可遮蔽外层 symbol macro。HIR 语法错误属于 `program-error`，同时保留编译器的错误信息和源码位置。

## 原生 `compile-file` 和 FASL

compiler 模块提供 `compile-file`。文件沿用原生前端处理顶层形式，读入从调用者的
`*package*` 开始，使用调用者的 features 和指定的 external format。
`eval-when`、宏定义和声明按文件编译规则生效，普通顶层代码留到加载时运行。
编译期间绑定 `*compile-file-pathname*` 和 `*compile-file-truename*`，并保存调用者的
package 和 readtable 绑定。编译期 HIR 求值使用运行期宏 client，词法环境与原生前端共用。

每个处理后的顶层形式生成一个 image 模式的 KIR 模块。FASL 保存 KIR 字符串、
字面量对象图和顺序执行记录，加载时通过 Cranelift 生成机器码并执行模块入口。
后续形式的符号和字面量在前一个模块入口执行后重建，因此文件里的 `defpackage`
可以先建立后续符号所需的 package。

对象图编码由 `lisp/target/eval/fasl.lisp` 提供。对象按身份编号，容器的分配与
内容初始化分开记录，保留共享、循环、特化数组、位移和 fill pointer。用户对象
通过 `make-load-form` 提供创建与初始化形式；创建形式依赖的对象必须先创建，
初始化形式可等待仍在创建的对象。就绪记录按依赖发射，初始化尽早执行；真正的
循环创建依赖报告 `program-error`。整个文件共用身份表，顶层入口之间保持对象
共享关系。

二进制头为 `89 4B 46 41 53`（带非文本前缀的 KFAS），后接格式版本 2；
非文本前缀使源文件以 `KFAS` 符号开头时仍按 Lisp 源码加载。整数使用七位分组的变长编码，字符使用
Unicode code point。记录数据包含整数、字符、字符串、符号、列表及 packet octets，任意字面量
通过有索引的对象记录表示。浮点保存有限值的整数尾数、指数、符号与精度，包含
负零。格式版本不匹配时加载器报错。文件格式是实现内部协议。

`compile-file` 返回产物的 truename、是否有告警、是否有非 style 告警。`:verbose`
和 `:print` 动态绑定对应变量，并控制标准输出上的编译信息。读取或编译失败时，
函数报告诊断并返回 NIL、T、T；文件访问错误和循环创建依赖仍正常报告。输出在成功生成完整
对象图后才打开写入。
`load` 检查文件头来区分 FASL 和源文件，也接受显式的二进制 FASL 输入流。
FASL 的 `:print` 信息报告已加载的原生顶层入口；源文件则打印求值结果。原生
FASL 加载需要 compiler 模块及 Cranelift；保存的是 KIR，机器码在加载时生成。
源文件加载仍按形式求值，按调用者指定的 external format 解码。

## 顶层编译缓存

原生 `eval` 和 `load` 保留最近使用的顶层原生产物。每次重放宏展开、前端和降级，只在 KIR、literal 身份及依赖版本相同时复用机器码；命中后仍执行该顶层形式。缓存默认至多 64 项，可通过 `kiln.sys:*compilation-cache-limit*`、`clear-compilation-cache` 和 `compilation-cache-statistics` 管理。调试元数据按结构比较，程序 literal 保持身份。详细协议见 [specialization.md](specialization.md)。

## 已知限制

- FASL 的通用浮点编码器只处理有限浮点数。
- 代码回收：函数对象不再被引用后，代码和它的表也不会释放。
- `compile` 的前端开销：每次都新建 session。
- `compile` 编出的函数名是 `(lambda)`；`load` 逐个读取形式再求值，没有文件和位置。
- typed-vector `defstruct` 的位置构造器布局展开（[stdlib.md](stdlib.md)）。

## 语义验证

`tools/ansi-test.sh` 默认使用完整 image 的原生 `eval` 和 `compile`。设置
`ANSI_EVAL=hir` 可独立验证 HIR 求值；两种模式都使用同一前端。原生文件编译
仍需结合 FASL 加载验证，交叉 AOT 需要端到端测试覆盖静态字面量和模块初始化。
解释执行、image 编译和交叉 AOT 的通过情况不能互相替代。任一测试组失败或
进程异常时，ANSI 驱动完成其他组后返回非零状态。
