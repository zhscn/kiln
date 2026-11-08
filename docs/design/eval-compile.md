# 运行期的 `eval`、`compile` 和 `load`

运行期求值有两层：eval 模块的 Maclina 字节码，和 compiler 模块载入后的原生编译。两者产出的函数都是真正的函数，可以和 AOT 代码互相调用。

## 为什么先有 Maclina

原生编译器是最后载入的模块，而在它之前，REPL、`load` 和载入期间的 `eval`、`compile` 就要能用；编译器在 image 里编译时，编译期求值也需要一个不依赖它自己的求值器。所以 `eval` 和 `compile` 不能等编译器。

**决定：eval 模块用 Maclina。** Maclina 是用可移植 CL 写的字节码编译器、VM 和 FASL 加载器。字节码函数是 funcallable instance，能和原生函数互相调用。它依赖少（closer-mop、alexandria、Trucler、Ecclesia），不依赖编译器，所以没有循环依赖。它同时提供：

- 一个能用的 REPL 和 `eval`；
- compiler 模块载入之前的 `compile`；
- image-client 的编译期求值（[front-end.md](front-end.md)）；
- 交付期可选的轻量求值器（不带 Cranelift 的发行版里执行扩展，[editor.md](editor.md)）。

## eval 模块

`kiln:compile-eval`，在 CLOS 和 frontend 之后载入。内容按顺序：

1. Ecclesia。
2. **运行期的标准宏：Common-macros。**
   - 宿主编译器用的是它的 extrinsic 版本（包 `COMMON-MACRO-DEFINITIONS` 遮蔽宏的名字），这些源码不能原样编进目标端，上游的 intrinsic 包也不能用（遮蔽得太少）。kiln 自己定义包 `kiln.cmd`：使用 CL，只遮蔽 `get-setf-expansion`、`ensure-generic-function`、`proclaim` 这三个带 client 参数的函数；读 Common-macros 的源码时用 `:renames` 把包名换成 `KILN.CMD`。
   - kernel 和 CLOS 自己定义的宏（`loop`、`define-condition`、`do-symbols` 等）在载入 Common-macros 之前保存起来，之后恢复，所以仍然优先。Common-macros 的定义另存在 `kiln.kernel::*common-macros*`，kiln 上的交叉编译要用（[front-end.md](front-end.md)）。
   - `define-setf-expander` 和 `defsetf` 在载入时生效，展开函数记在符号的 plist 上。运行期的 `get-setf-expansion` 依次查展开函数、宏，最后用 setf 函数。
3. Trucler（base，以及 trucler-native 的 client 类）。
4. Maclina：base、compile、vm-shared、vm-native。
5. `lisp/target/eval/evaluator.lisp`：
   - kiln 的 Trucler client 继承 `trucler-native:client`（Maclina 的 native VM 就是为这类 client 写的）。它描述的全局环境是运行中的 image：special 变量来自运行期的 `proclaim`（`defvar` 的展开在载入时调用它，把变量记在 plist 上），常量来自 `defconstant`，函数和宏查符号本身。
   - `macro-function` 和 `macroexpand` 收到 Maclina 的词法环境时，经 Trucler 查局部宏。
   - 字节码存成 simple vector（kiln 的 Maclina client 定义 `m:make-module`）：`(unsigned-byte 8)` 数组是 Regalia 的实例，`aref` 要经过几层泛函。
   - 对未知函数的调用只在形式执行完后仍未定义时才警告，所以递归的 `defun` 不会报警告。
6. `repl.lisp`：`kiln.sys:repl`，维护 `*`、`+`、`/` 等变量；形式没有处理的错误打印出来，经 `abort` 回到提示符。`tools/repl.sh` 构建 kernel、CLOS、eval 三个模块并启动它（`--jit` 改用 JIT）。
7. `server.lisp`：后端协议（[backend-protocol.md](backend-protocol.md)）。

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

每个形式至少多花几毫秒的编译时间，交互时察觉不到。对只为展开宏或只运行几次的代码，编译时间占主导：这样的 `compile` 要把 `*compile-function*` 绑成 NIL，改用 Maclina。交叉编译的编译期求值用 IR 求值器（构造宿主闭包），不经过 `compile`。

## 顶层编译缓存

原生 `eval` 和 `load` 保留最近使用的顶层原生产物。每次重放宏展开、前端和降级，只在 KIR、literal 身份及依赖版本相同时复用机器码；命中后仍执行该顶层形式。缓存默认至多 64 项，可通过 `kiln.sys:*compilation-cache-limit*`、`clear-compilation-cache` 和 `compilation-cache-statistics` 管理。调试元数据按结构比较，程序 literal 保持身份。详细协议见 [specialization.md](specialization.md)。

## 已知限制

- `compile-file` 和 FASL：只有 `compile`、`eval`、`load` 源文件。
- 代码回收：函数对象不再被引用后，代码和它的表也不会释放。
- `compile` 的前端开销：每次都新建 session。
- `compile` 编出的函数名是 `(lambda)`；`load` 逐个读取形式再求值，没有文件和位置。
- 运行期的 `defstruct`（[stdlib.md](stdlib.md)）。
- `defsetf` 的长形式（带 lambda list 和存储变量的那种）在 image 里求值时出错，报 `No variable-description for V`（V 是存储变量）。原因在 Common-macros 的 `expand-long-defsetf`：展开出的 `define-setf-expander` 直接把用户写的存储变量当作存储变量返回，但 body 里的 `,v` 要在展开时求值，那里 `v` 没有绑定。正确的展开要为每个存储变量生成 gensym，在 body 外把存储变量绑定到它。短形式没有问题。
