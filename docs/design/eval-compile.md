# 运行期求值、编译和文件加载

运行期求值有两层：eval 模块的 Maclina 字节码，和 compiler 模块载入后的原生编译。两者产出的函数都是真正的函数，可以和 AOT 代码互相调用。

## 为什么先有 Maclina

原生编译器是最后载入的模块，而在它之前，REPL、`load` 和载入期间的 `eval`、`compile` 就要能用；编译期形式使用 HIR 求值器，共用原生前端并直接构造可执行闭包。所以 `eval` 和 `compile` 不能等编译器。

**决定：eval 模块用 Maclina。** Maclina 是用可移植 CL 写的字节码编译器、VM 和 FASL 加载器。字节码函数是 funcallable instance，能和原生函数互相调用。它依赖少（closer-mop、alexandria、Trucler、Ecclesia），不依赖编译器，所以没有循环依赖。它同时提供：

- 一个能用的 REPL 和 `eval`；
- compiler 模块载入之前的 `compile`；
- 原生编译器就绪前的运行期求值；
- 交付期可选的轻量求值器（不带 Cranelift 的发行版里执行扩展，[editor.md](editor.md)）。

## eval 模块

`kiln:compile-eval`，在 CLOS 和 frontend 之后载入。内容按顺序：

1. Ecclesia。
2. **运行期的标准宏：Common-macros。**
   - 宿主编译器用的是它的 extrinsic 版本（包 `COMMON-MACRO-DEFINITIONS` 遮蔽宏的名字），这些源码不能原样编进目标端，上游的 intrinsic 包也不能用（遮蔽得太少）。kiln 自己定义包 `kiln.cmd`：使用 CL，只遮蔽 `get-setf-expansion`、`ensure-generic-function`、`proclaim` 这三个带 client 参数的函数；读 Common-macros 的源码时用 `:renames` 把包名换成 `KILN.CMD`。
   - kernel 和 CLOS 自己定义的宏（`loop`、`define-condition`、`do-symbols` 等）在载入 Common-macros 之前保存起来，之后恢复，所以仍然优先。Common-macros 的定义另存在 `kiln.kernel::*common-macros*`，kiln 上的交叉编译要用（[front-end.md](front-end.md)）。
   - 嵌套 `values` 位置为每个子位置的次要存储变量预先绑定 NIL；只向子位置的主存储变量分配输入值，零存储变量的子位置不消耗输入值。
   - 广义位置支持 `(apply #'symbol ...)`，读取和写入共用已求值的参数。长格式 `defsetf` 为参数和存储变量生成独立临时变量，展开函数保留定义时的词法环境及具名 block。`define-modify-macro` 传递调用点的词法环境，先求值附加参数，再读取位置。
   - `define-compiler-macro` 登记展开函数后，返回定义的函数名作为唯一值，包括 `(setf name)`；编译器是否使用展开函数遵循其编译策略。
   - `define-setf-expander` 和 `defsetf` 在载入时生效，展开函数记在符号的 plist 上。运行期的 `get-setf-expansion` 依次查展开函数、宏，最后用 setf 函数。
3. Trucler（base，以及 trucler-native 的 client 类）。
4. Maclina：base、compile、vm-shared、vm-native，以及对象图的 FASL 编码器和加载器。文件读取沿用 kiln 的 CST reader，序列化器通过 `fasl-protocol.lisp` 获取包名和可选的源码信息。
5. `lisp/target/eval/evaluator.lisp`：
   - kiln 的 Trucler client 继承 `trucler-native:client`（Maclina 的 native VM 就是为这类 client 写的）。它描述的全局环境是运行中的 image：special 变量来自运行期的 `proclaim`（`defvar` 的展开在载入时调用它，把变量记在 plist 上），常量来自 `defconstant`，函数和宏查符号本身。
   - `macro-function` 和 `macroexpand` 收到 Maclina 的词法环境时，经 Trucler 查局部宏。
   - 字节码存成 simple vector（kiln 的 Maclina client 定义 `m:make-module`）：`(unsigned-byte 8)` 数组是 Regalia 的实例，`aref` 要经过几层泛函。
   - 对未知函数的调用只在形式执行完后仍未定义时才警告，所以递归的 `defun` 不会报警告。
6. `repl.lisp`：`kiln.sys:repl`，维护 `*`、`+`、`/` 等变量；形式没有处理的错误打印出来，经 `abort` 回到提示符。`tools/repl.sh` 构建 kernel、CLOS、eval 三个模块并启动它（`--jit` 改用 JIT）。
7. `server.lisp`：后端协议（[backend-protocol.md](backend-protocol.md)）。

## `provide` 和 `require`

`provide` 把字符串设计符转换为名字，按 `string=` 去重后加入 `*modules*`，返回 T。`require` 已登记的模块时不加载文件；否则按顺序加载指定的单个 pathname 或 pathname 列表，即使第一个文件已调用 `provide`，也继续加载其余文件。模块代码负责调用 `provide`，`require` 不自动登记名字。返回值是本次新增登记的模块名字列表。

未指定文件时，`require` 按顺序调用 `kiln.kernel::*module-provider-functions*`，直到某个函数返回真，传入原始名字设计符。该列表初始为空，找不到 provider 时报告错误。嵌套加载会检查循环依赖；错误或非局部退出会恢复当前加载栈。

## 编译单元

`with-compilation-unit` 将动态范围内原生编译器和 Maclina 的未知函数引用延迟到单元结束，再根据最终函数定义决定是否报告。Maclina 的未知变量警告延迟到结束；后来初始化变量不撤销先前缺失声明的警告。未知类型按最终类型定义复查。其他警告即时报告。普通嵌套单元共用外层队列，`:override` 为真时建立独立队列；重复函数引用合并，已经补齐的定义不再警告。

单元返回主体的全部值。正常返回、错误或非局部退出都会结束当前单元并恢复外层状态；独立内层单元的结束警告直接报告，不重新加入外层队列。

## 编译文件的路径和动态状态

`compile-file-pathname` 按输入路径、显式输出路径和 `*default-pathname-defaults*`
计算产物名，默认类型为 `fasl`（逻辑路径为 `FASL`）。输出路径未指定目录时沿用
输入目录；显式输出类型予以保留。函数接受编译器的其他关键字，不访问文件系统。

这些接口随 eval 模块提供。`*compile-file-pathname*`、`*compile-file-truename*`
初始为 NIL，`*compile-print*` 初始为 NIL，`*compile-verbose*` 初始为 T。

## 原生 `compile`

compiler 模块的最后一个文件 `lisp/target/compiler/native.lisp` 把 `kiln.kernel::*compile-function*` 设成 `native-compile`，此后的 `compile` 都编成机器码。这个变量为 NIL 时用 Maclina。compiler 模块自己载入时调用的 `compile` 仍是字节码。

1. `native-compile` 新建一个 session（`image-client`），然后：
   - 用 `front-end-forms` 处理 `(setq *compiled-function* (function LAMBDA))`（和 `front-end` 一样，只是直接处理形式，不读文件）；
   - 用 `compile-module :image t` 降级；
   - 用 `module-string` 把整个模块写进一个字符串；
   - 把字符串和字面量向量交给 `(%primop :jit text literals)`，即 kiln-cg 的 `kiln_rt_jit`（[codegen.md](codegen.md)）。它返回 init 函数对象，KIR 编不过时返回 NIL，`native-compile` 据此报错。
2. `native-compile` 动态绑定 `*compiled-function*`，调用 init 函数，取出编好的函数。

### image 模式的 KIR

编进运行中 image 的代码，引用的是 image 里已有的对象。和编译文件相比有三点不同：

- **字面量**：除立即数（fixnum、字符、单精度浮点、NIL、T）以外，字面量一律占用模块数据 `kiln_literals` 的一个字。每个字都是 static root，数据字写成 `(:literal i)`，操作数是 `(load (addr "kiln_literals") 8i)`。`compile` 不复制字面量（CLHS 3.2.4），未 intern 的符号、列表都还是原来那个对象。符号也走这条路：运行期 intern 的符号在堆里，GC 会移动它们，不能把地址编进代码。代价是全局函数调用和特殊变量的访问各多一次 load。
- **没有符号表**：符号都已经在 image 里，init 函数不调用 `%register-module-symbols`。
- **共享的定义用 image 的**：未定义函数的入口和 funcallable instance 的跳板要和函数槽里的值比较（`fboundp`、报错代码），所以必须是 image 里的那一份，写成 `import-data`，由 kiln-cg 按导出的名字解析。

### 内存

运行期编出的模块共用一块预留的 16 GiB 地址空间（固定地址 `0x3800_0000_0000`，`rust/kiln-rt/src/code.rs`）：只预留，用到时才提交，从低往高分配，从不释放。各模块的表在 kiln-rt 里留一份，堆快照可以连同这些代码一起保存（[heap-image.md](heap-image.md)）。代码目前不回收。

## 原生 `eval` 和 `load`

compiler 模块载入后，`eval` 也走原生编译（`native-eval`，挂在 `kiln.kernel::*eval-function*` 上；绑成 NIL 则用 Maclina）。`load` 和 REPL 都经过 `eval`，所以载入的源文件和 REPL 里定义的函数都是机器码。做法和 SBCL 的 `eval` 一样：

- 不需要代码的形式直接求值：符号（经 Maclina，以便处理符号宏）、自求值对象、`quote`、`(function 符号)`。
- `progn` 和 `eval-when`（含 `:execute` 时）逐个求值子形式，所以 `defmacro` 在下一个子形式编译之前就已生效。
- 宏形式先展开一层再判断。展开定义宏之前记下定义的名字（`definition-name`），交给前端（`*eval-definition*`），调试信息和依赖追踪按它命名（[debugging.md](debugging.md)、[dependencies.md](dependencies.md)）。
- 其他形式作为顶层形式编译，然后调用。

每个形式至少多花几毫秒的编译时间，交互时察觉不到。对只为展开宏或只运行几次的代码，编译时间占主导：这样的 `compile` 要把 `*compile-function*` 绑成 NIL，改用 Maclina。交叉编译的编译期求值用 HIR 求值器（构造宿主闭包），不经过 `compile`。

`symbol-macrolet` 在字节码和原生前端都拒绝常量、全局特殊变量，以及对自身绑定的 `special` 声明；内层自由声明和新变量绑定仍可遮蔽外层 symbol macro。HIR 语法错误属于 `program-error`，同时保留编译器的错误信息和源码位置。

## 原生 `compile-file` 和 FASL

compiler 模块提供 `compile-file`。文件沿用原生前端处理顶层形式，读入从调用者的
`*package*` 开始，使用调用者的 features 和指定的 external format。
`eval-when`、宏定义和声明按文件编译规则生效，普通顶层代码留到加载时运行。
编译期间绑定 `*compile-file-pathname*` 和 `*compile-file-truename*`，并保存调用者的
package 和 readtable 绑定。编译期 HIR 求值使用运行期宏 client，词法环境与原生前端共用。

每个处理后的顶层形式生成一个 image 模式的 KIR 模块。FASL 使用 Maclina 的二进制
对象图容器保存 KIR 字符串、字面量和加载调用，加载时通过 Cranelift 生成机器码并
执行模块入口。后续形式的字面量在前一个模块入口执行后重建，因此文件里的
`defpackage` 可以先建立后续符号所需的 package。编译器的字面量保持对象共享关系，
cons 和数组可以自引用；用户对象经 `make-load-form` 重建。对象初始化形式先在
子记录中展开，共享已经登记的 creator，只记录新增的指令和常量。若初始化引用
外层尚未创建完成的对象，就丢弃这次子记录，并在该对象的 creator 登记后重试。
完整展开才合并记录，避免重试时复用未完成的 cons、数组或字面量表。
初始化形式尽早执行，真正的循环创建依赖报告 `program-error`。

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
- 运行期的 `defstruct`（[stdlib.md](stdlib.md)）。
