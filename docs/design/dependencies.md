# 依赖追踪

在 image 里求值的定义会记下编译期用到的定义（宏、内联函数、`setf` 展开器、常量）；其中之一被重新定义时，依赖它的定义自动重新求值，或者报告为过时。没有它的话，在活 image 里重定义宏之后，已经编好的使用者仍按旧的展开运行（SBCL 就是这样，用户常常因此踩坑）。这也是“重定义任何东西都立即对所有调用者生效”在优化之后仍然成立的前提（[editor.md](editor.md) 的“重定义始终立即生效”）。

实现在 `lisp/target/compiler/dependencies.lisp`，记录点在前端。AOT 编出的模块还没有依赖记录（见“不追踪的”）。增量编译的做法取自 Zig，对照见 [zig-incremental.md](../research/zig-incremental.md)。

## 决定

- **粒度是定义**：`eval` 拿到的一个定义形式（`defun`、`defmacro`、`defmethod` 等，名字的规则同 [debugging.md](debugging.md) 的 `definition-name`），是一个单位。宏展开结果里的定义（例如用户的定义宏展开成的 `progn` 里的 `defun`）各自是一个单位。不是定义的顶层形式（REPL 里的表达式）只运行一次，不记录。
- **自动重新求值**：只用于再求值一次的效果只是替换它所定义的东西的定义：`defun`、`defmacro`、`defmethod`、`define-compiler-macro`、`deftype`、`defsetf`、`define-setf-expander`、`define-modify-macro`。重新求值时绑定原来的 `*package*`。
- **其他定义只报告**：`defvar`、`defparameter`、`defclass` 以及用户自己的定义宏等，再求值一次会有别的效果（`defparameter` 会重设值），这类定义发出 `kiln.sys:stale-definition` 警告（style-warning），由用户决定是否重新求值。重新编译出错的定义也报告这个警告，同时保留旧代码。
- **用户求值的定义总是传播**：用户求值一个定义（`eval`、`load`、后端协议），依赖它的定义就要更新，即使新旧定义的源码相同。重新求值一个没变的宏，正好可以用来传播宏展开函数调用的辅助函数的改动（见“不追踪的”）。
- **更新中的定义提前截断**：自动重新求值的定义如果编出的代码和原来相同，依赖它的定义不再更新（见“一次更新：顺序和提前截断”）。

## 依赖的种类

依赖用 `(种类 名字)` 表示。CL 包和关键字包的名字不记录，因为重定义它们是未定义行为。

| 键 | 记录的时机 | 失效的时机 |
|---|---|---|
| `(:macro m)` | 展开了全局宏 `m`；或者编译时 `m` 还没有定义（以后的 `defmacro` 会改变这个形式的含义） | `(setf macro-function)`，即每次 `defmacro` |
| `(:inline f)` | 内联展开了 `f` | `f` 有了新的内联展开，或者被声明为 `notinline` |
| `(:setf f)` | 编译了位置 `(f ...)` 的 `setf` | `defsetf`、`define-setf-expander` |
| `(:constant c)` | 引用了常量 `c`（值折叠进了代码） | `defconstant` 改变了它的值（不 `eql`） |
| `(:class c)` | 代码用到了类 `c` 的布局或优先级列表 | `c` 重新 finalize（重定义、`make-instances-obsolete`） |
| `(:methods g)` | 代码用到了泛函 `g` 的方法集或方法组合 | 往 `g` 增删方法，或者 `g` 重定义 |
| `(:type name)` | 代码用到了类型 `name` 的展开或类名映射 | `deftype`、`(setf find-class)`、类的重新 finalize |
| `(:initialization c)` | 代码用到了类初始化协议对 `c` 的适用方法 | 往 `allocate-instance`、`initialize-instance`、`shared-initialize` 增删方法 |
| `(:function f)` | 代码依赖 `f` 的定义 | `f` 重定义 |

后五行（`(:class c)` 等）是 [specialization.md](specialization.md) 的假设：每次 `change-assumption` 都把键交给同一个重定义钩子，所以它们和宏、内联函数一样能成为在 image 里编译的定义的依赖。现在编译器还没有记录这些键（调用点特化、生成的判别函数才会记），但报告和 `kiln.sys:dependents` 已经认识它们。

在哪里记录：
- 前端查询全局环境时（`lisp/target/compiler/client.lisp` 的 `run-time-environment`）：IR 转换展开宏、宏用 `&environment` 调用 `macro-function`，都会经过这里。查到宏、查不到定义、查到常量时记下依赖。
- `front.lisp`：内联展开时（`convert-maybe-inline`）。检查内联函数体里的名字是否被局部遮蔽，这些查询不算依赖。
- image-client 的 `get-setf-expansion`。
- `native-eval` 自己展开顶层宏形式时（定义的宏本身）。

收集器是 `*dependencies*`。只有原生 `eval` 在求值定义时才绑定它，所以交叉编译和 KIR 都不受影响（SBCL 和 kiln 编出的 KIR 仍然相同）。

## 失效和更新

- 重定义点调用 `kiln.kernel::*redefinition-hook*`。宏、setf 展开器、常量和函数绑定的变更都经过 `change-assumption`（`lisp/target/assumptions.lisp`），由它把键交给钩子。`deftype`、`(setf find-class)`、类的终结与重初始化、方法增删和泛函重初始化也经过这个入口。前端的 `note-inline-definition` 和 `notinline` 声明只在编译进 image 时改变 inline 假设。compiler 模块载入时设置这个钩子（`lisp/target/compiler/dependencies.lisp`）。
- 钩子只把键放进待处理队列。最外层的 `eval` 返回后，再更新依赖这些键的定义：一个 `defmacro` 会在编译期和载入时各通知一次，在编译中途重新编译别的定义也不安全。不在 `eval` 里、也不在编译中时，钩子立即更新。
- 依赖关系保存在 compiler 模块的全局表里，存 image 时一起保存。每个单位保存这些内容：
  - 定义形式、`*package*`、定义的先后次序；
  - 依赖的键；
  - **输出**：求值时通知过的键，例如 `defmacro m` 的输出是 `(:macro m)`；
  - **指纹**：为它编出的 KIR（去掉带编号的模块名）和 literal。

  重新求值会替换原来的记录，次序不变。

### 一次更新：顺序和提前截断

做法取自 Zig 的增量编译，名字都按定义名：
- **标记**：
  - 变了的键的直接依赖者是**过时**的；
  - 依赖过时定义的输出的定义，是**可能过时**的，这样递归下去；
  - 每个过时或可能过时的定义带一个计数，即它还在等几个定义更新完。
- **顺序**：
  - 每次取计数为 0 的过时定义里最早定义的那个；
  - 都在等的时候（循环依赖），取最早定义的那个；
  - 一次更新里每个定义至多求值一次。
- **截断**：一个定义重新求值以后，判断它的输出变了没有。
  - 宏和 `setf` 展开器：比较指纹，代码相同就算没变。literal 用 `eql` 比较；字符串、cons、向量按内容比较；无包的符号（展开里的 gensym）按名字比较。
  - 常量和内联函数：钩子本来就只在值或展开变了时才通知。
  - 变了：等它的定义计数减一，可能过时的变成过时。
  - 没变：等它的定义计数减一，可能过时的计数到 0 就直接算作最新，并且这个"没变"继续向下传递。
- **出错**：重新编译出错的定义保留旧代码，对下游来说就是没变。只报告的定义（`defparameter` 等）也算没变。

例（`tests/m6/co-dependencies`）：
- `k` 变了，`m1` 和 `use-k` 都依赖 `k`，`use-k` 还依赖 `m1`：先编 `m1`，再编 `use-k`，`use-k` 只编一次。
- `two` 变了，但 `add-two` 重新编出的代码相同：`add-two` 的使用者不再重编。
- `ping` 和 `pong` 的展开函数互相使用：每个只编一次，就停下来。

`defconstant` 的展开在载入时也调用 `%define-constant`，因为原生 `eval` 不执行 `:compile-toplevel` 部分。

image 里所有的编译会话共用一张内联函数表（`*image-inline-functions*`），一个 `eval` 里声明的内联函数，后面的 `eval` 都能用，所以内联也需要追踪。

## 不追踪的

追踪只能做到尽力而为：宏展开函数可以调用任意函数、读特殊变量，CL 的文件是按顺序执行的脚本，没法像 Zig 那样靠限制编译期求值来保证完整。反过来，全局函数调用经过函数格，替换函数本身就对所有调用者生效，这部分不需要追踪。

- **AOT 编出的模块**：kiln 自己的五个模块和测试程序由交叉编译器编译，没有记录。在 image 里重定义 kernel 的宏，kernel 里已经编好的代码不会更新。要支持它，得在 KIR 里记下每个函数的依赖，模块初始化时装进同一张表（定义表也要这样做，[debugging.md](debugging.md) 的定义记录）。
- **宏展开函数在展开时调用的函数**：展开函数调用的辅助函数被重新定义后，不会自动更新。重新求值那个宏就会传播（见“决定”）。
- **`compile` 编出的函数**：没有可以重新求值的定义形式。
- **类型**：`typep` 对非标准的类型在运行期按类型缓存（`%typep-cached`），不在编译期展开 `deftype`，不需要追踪；调用点的 `typep` 缓存自己检查类型假设的版本。`defstruct` 在运行期还没有实现。CLOS 分派和调用点特化还没有把假设记成依赖，以后加上时用同一套键。
- **宏改成函数**：`defun` 不清除名字上的宏函数（原来就是这样），这种重定义目前不起作用。

## 接口

- `(kiln.sys:dependents kind name)`：依赖 `(kind name)` 的定义的名字，按定义的先后；`kind` 包括上面表里的所有种类。
- `(kiln.sys:dependencies name)`：定义 `name` 的依赖。
- `kiln.sys:*recompile-verbose*`：为真时，每次重新求值都在 `*error-output*` 上打印一行，例如 `; compiling USE-TWICE again: the macro TWICE changed`；编出的代码相同时再打印一行，例如 `; (MACRO-FUNCTION ADD-TWO) is the same`。
- `kiln.sys:stale-definition`：警告，见“决定”。

后端协议（[backend-protocol.md](backend-protocol.md)）里，这些警告和打印都进入任务的输出。

## 测试

`tests/m6/co-dependencies` 覆盖以下情况：
- 宏重定义后使用者跟着更新；
- 先用后定义的宏；
- 展开函数里用到别的宏，形成连锁更新；
- 跨 `eval` 的内联函数，包括重定义和直接改 `fdefinition`（后者内联的调用者看不到）；
- 先用位置后定义 `defsetf`；
- 常量改值；
- 只报告的 `defparameter`；
- 重新编译失败时保留旧代码；
- 展开函数互相使用时的终止；
- 更新的顺序（等依赖的定义更新完再编）；
- 代码没变时的截断。

## 待定

- 用户重新求值的定义是否也做提前截断。这样重新载入大文件时可以省掉一层重复的编译，但会挡住“用户求值的定义总是传播”的用法。
- “名字是否存在”的依赖：现在编译时还没定义的名字记成 `(:macro m)`，应拆成单独的种类，普通的 `defun` 也就不必通知。

要做的事（KIR 里的依赖记录、重新载入文件、按需就地更新、优化的假设作为依赖）见 [roadmap.md](../roadmap.md)。
