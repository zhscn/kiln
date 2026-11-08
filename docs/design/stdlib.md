# 标准库：condition、哈希表、包、类型、数组、结构、LOOP

这些都编进 CLOS 模块，放在 CLOS 之后（[modules.md](modules.md)）。流、文件、打印和读入见 [io.md](io.md)。vendor 的模块的补丁见 `vendor/README.md`。

## condition 系统（Predicament）

Predicament 按 `predicament-common.asd` 的顺序加载。实现方要提供的部分照 SICL 的 `Code/Conditions/` 来写（`lisp/target/clos/conditions.lisp`）：

- **类**：元类 `condition-class` 是 `standard-class` 的子类，槽访问和初始化的方法都直接适用；`condition` 是它的实例。报告函数存在实例的 `%report` 槽里（SICL 用 class 分配的槽，所有 condition 类会共用一个格子）。
- **`define-condition`** 展开成 `defclass`，带 `(:metaclass condition-class)`，`:report` 变成 default initarg。`make-condition` 经 `*condition-maker*` 对 condition 类做 `make-instance`。
- **early 阶段的 condition**：kernel 的 early `define-condition` 记下的定义（Ecclesia、Clostrophilia 的约 80 个）在 Predicament 之后建成真正的 condition 类（`early-conditions.lisp`），之后 Clostrophilia 报出的错误可以被 handler 捕获。
- **运行期错误**：编译出的代码和 kernel 发现的错误经 `%runtime-error` 变成 condition（[kernel.md](kernel.md)）。
- **报告**：条件的 `print-object` 在不转义时打印报告。Predicament 给 `error`、`parse-error`、`program-error`、`control-error`、`reader-error`、`warning`、`style-warning`、`storage-condition` 定义的、不看条件内容的报告在 kiln 下去掉了：Khazern 的条件同时继承 `parse-error` 和 `acclimation:condition`，类优先级里 `parse-error` 在前，它的“A parse error has occurred.”会盖住 Acclimation 的本地化报告。没有报告的条件打印成“Condition X was signalled.”，和 SBCL 一样。
- **默认 debugger**：打印报告和 backtrace 后退出（[debugging.md](debugging.md)）；后端协议里是嵌套的 debug 层（[backend-protocol.md](backend-protocol.md)）。
- 前端为它做的：编译期的 `macroexpand` 按 kiln 的环境展开（`restart-case` 展开时要判断信号形式是不是 `error`、`signal`）；`restart-bind` 和 `restart-case` 所在的文件以 `:compile-time-too` 加载。

## 哈希表（Salmagundi）

用 Salmagundi 的 `bucket-hash-table` 类（名字没改），但表本身已经改成开放寻址（补丁）。接口层由 kiln 自己写（`hash-tables.lisp`），不用 Trinsic：`cl:make-hash-table`、`cl:sxhash`、`cl:with-hash-table-iterator` 由 kiln 定义，`gethash` 等直接就是 CL 的符号。

- EQ、EQL、EQUAL、EQUALP 的默认哈希函数是 `default-hash-function` 上的 EQL 方法。EQ 哈希用身份哈希（[objects.md](objects.md)），所以对象移动后表仍然有效，不需要 rehash。
- `eq`、`eql`、`equal` 表的散列函数直接处理 fixnum、字符、符号、字符串和 cons，不走 Salmagundi 逐步累加、为每次散列生成闭包的路径。混合一步用 `%primop :hash-mix`：在 fixnum 上做一步按 64 位截断的 FNV-1a，大整数按 62 位一段依次混入（Salmagundi 的 FNV 每一步都会产生 bignum）。
- **开放寻址**，和 CPython 的 dict 一样：条目按插入顺序放在三个向量里（键、值、哈希）；一个索引向量，长度是 2 的幂、至多用一半，按哈希线性探测映射到条目，探测时先比较存下的哈希。每个条目不分配任何对象；向量满了就加倍（`make-hash-table` 的 rehash size 和 threshold 只是提示，CLHS 允许）。
- **迭代顺序**按插入顺序，和 SBCL 一样。宏展开函数会遍历哈希表（Khazern 的解构临时变量），kiln 编译 kiln 必须得到 SBCL 的 KIR；按哈希顺序遍历的话，身份哈希每次运行都不同。`tests/m4/clos-hash-model.lisp` 用一个模型和 SBCL 的迭代顺序检查表。
- 查找要用的数据放在一个 simple vector 里，按固定位置从实例读出，eq、eql、equal 内联比较；`gethash`、`(setf gethash)`、`remhash` 遇到这种表时直接调用它的函数，不经过泛函。
- `sxhash` 仍走 Salmagundi 的累加闭包，没有 `equal` 表散列函数那样的快路径，很慢。
- 还没有弱表。

## 包（Parcl）

Parcl 以 intrinsic 方式加载：`parcl-low`（泛函协议和默认方法）、`parcl-low-class`（包是带槽的类）、`parcl` 公共层直接定义 `cl:intern`、`cl:find-symbol`、`cl:export`、`cl:use-package`、`cl:make-package` 等。kiln 的 client 和引导在 `package-system.lisp`。运行期的包怎样从模块的符号表建起来见 [modules.md](modules.md)。

- symbol 表和包注册表都是 `equal` 哈希表；`store-package` 检查重名。`find-package` 是 Parcl 的泛函，kiln 为包、字符串、symbol、字符各加一个方法；按名字查找时先看当前包的局部昵称，所以读入 `a:foo` 也会用到它们。
- 在 KEYWORD 里 intern 的 symbol 设为外部 symbol，并以自身为值。`keywordp` 比较 `kiln.kernel::*keyword-package*`。
- kiln 自己写的：`list-all-packages`、`packagep`、`rename-package`、`delete-package`、`unintern`、`find-all-symbols`、`do-symbols`、`do-external-symbols`、`do-all-symbols`、`with-package-iterator`（先把要遍历的 symbol 收集成列表）。
- **运行期的 `defpackage` 和 `in-package`**：`%defpackage` 按 CLHS 的顺序建立或更新包（昵称、shadow、shadowing import、use 列表、import、intern、export、包局部昵称）；包已存在时就地更新，不检查和原定义的差异；没有 `:use` 时 use 列表为空，和 SBCL 一样；忽略 `:documentation` 和 `:size`。`in-package` 展开成对 `*package*` 的赋值。模块里顶层的这两个宏只在编译期执行（[front-end.md](front-end.md)）。
- 启动时 `*package*` 是 `COMMON-LISP-USER`。
- 限制：冲突时的 restart 只有 Parcl 原有的那些（`use-package` 冲突直接报 `package-error`）；`do-symbols` 对有 use 列表的包是平方复杂度（Parcl 的 `map-symbols` 用列表去重）。

## 类型（ctype）和 `deftype`

- **`deftype`**：Common-macros 的 `deftype` 通过 client 钩子生成 `(kiln.sys::%deftype 'name expander)`，外面套一层三种时机都有的 `eval-when`。编译期环境里的 `%deftype` 把展开函数登记到编译期环境，kernel 里的把它存到名字的 plist 上。
- **ctype** 按 `ctype.asd` 的顺序加载，但 `host.lisp` 和 `runtime.lisp` 换成 kiln 的 client（`ctype-client.lisp`，原文件在加载时用宿主的 `subtypep` 和类计算常量），`interface.lisp` 换成 `ctype-interface.lisp`，定义 `cl:subtypep`、`cl:upgraded-array-element-type`、`cl:upgraded-complex-part-type`。
- client 的取值：浮点只有 single-float 和 double-float（short-float 归入 single，long-float 归入 double）；正负零是不同的值；数组的 UAET 按 Regalia 的类划分；base-char 是 0–127，与 kernel 的 `typep` 一致。
- ctype 的泛函用长形式方法组合 `basic`，它生成 `(surely (call-method ...) ...)` 这样的有效方法；ctype 的 client 经 `*effective-method-operators*` 登记 `surely` 的解释（依次调用各个方法，直到第二个值为真），所以不需要运行期编译器。
- **缓存**：类型说明符的解析结果和 `subtypep` 的答案缓存在 `equal` 哈希表里；两个符号的 `subtypep` 缓存在第一个符号的 plist 上，带缓存代号（`*type-cache-epoch*`）。`deftype` 或定义类时清空（`invalidate-type-caches`）。写每个字符的流操作都要调用 `subtypep`，所以缓存是必要的。
- ctype 里特化在 `complex` 上的部分（`ccomplex.lisp`）仍用 `#-kiln` 去掉（接入时 kiln 还没有 complex）：`subtypep` 不懂 complex 类型；`typep` 对 complex 类型由 kernel 回答。

## 数组（Regalia）

**混合表示**：元素为 T 的一维 simple vector 和 simple string 是原生对象，`svref`、`schar` 和 kernel 的快路径不变；其余数组都是 Regalia 的标准类的实例。

- **类层次**：CL 的 `array`、`simple-array`、`vector`、`simple-vector`、`string`、`simple-string`、`bit-vector`、`simple-bit-vector` 都是内建类，原生对象的类是 `simple-vector` 和 `simple-string`。Regalia 的类在 `regalia` 包里，补丁遮蔽同名的 CL 符号；它的 `array` 以 `standard-object` 和 `cl:array` 为父类。简单与否由实例的状态决定（不可调整、没有 fill pointer、没有 displaced），类本身不区分。
- **存储**：元素存在 `contents` 槽里的原生向量中（补丁加了 `%contents` 和 `%adjustable` 两个槽）。字符数组用字符串存，其他元素类型都用 simple-vector 存，特化类型在写入时检查元素类型。displaced 数组没有存储，读写时转到目标数组，加上偏移。
- **kernel 的钩子**：kernel 的 `stringp`、`vectorp`、`arrayp`、`length`、`aref`、`char`、`row-major-aref`、`array-rank`、`array-dimensions` 等先处理原生向量，其余对象交给 `*complex-array-kind*`（把对象映射为 `:string`、`:vector`、`:array` 或 NIL）和 `*complex-array-op*`（按关键字执行操作）。kernel 在泛函分派内部也会问种类（`gethash` 的分派会调用 `stringp`），所以这里不能调用泛函：种类按 stamp 查一张向量。
- kernel 内部用 `make-simple-vector` 构造向量；`make-array` 对元素类型为 T 或 character 的简单情况直接返回原生对象，不调用 `subtypep`。一维、没有位移的可调向量增长时直接换掉原生存储（`resize-vector`）。
- **kiln 自己写的**（`arrays.lisp`，Regalia 的这些部分不完整或有错）：`make-array` 的全部关键字参数；`aref`/`row-major-aref` 及其 setf，检查下标；fill pointer 和 `vector-push-extend` 等；`adjust-array`；`array-displacement` 等查询；`bit`、`sbit`；`upgraded-array-element-type`（bit、8/16/32/64 位有符号和无符号整数、single-float、double-float、character，其余是 T）。从 Regalia 加载的是类层次、`class-name-from-element-type`、维度检查和 condition 类型。
- 限制：序列函数对非 simple 向量返回 simple 向量；没有 `bit-and` 等位数组运算。

## 结构（Anatomicl）

**Anatomicl 在编译期运行**：它把 `defstruct` 形式解析成描述对象，再生成普通的 Lisp 代码，生成的代码不引用 Anatomicl 自己。所以它是宿主库（kiln 上编进 compiler 模块），`defstruct` 是受保护的宿主宏（[front-end.md](front-end.md)）。kiln 的 client 在 `lisp/structures.lisp`：

- **`:include` 的槽布局**：Anatomicl 默认通过 closer-mop 读被包含结构的类，可编译期没有目标端的类。kiln 在编译会话里记下每个结构的槽布局（`session-structures`）：先是被包含结构的槽（访问器名按本结构的 `conc-name` 重新生成，`:include` 给出的槽描述覆盖原有的），再是本结构自己的直接槽。
- **类定义**：生成目标端的 `defclass`，元类是 `structure-class`，每个槽都有 initarg；`:print-object` 选项生成 `print-object` 方法。
- **访问器**是 inline 的普通函数，可写的槽还有 inline 的 setf 函数。槽的位置就是它在布局里的序号（`defclass` 里也是这个顺序，Clostrophilia 按这个顺序分配位置）。结构的类存在包 `kiln.structures` 的一个变量里：实例的类就是这个类时直接读写槽，否则（包含它的结构的实例）先检查类型（`%structure-ref`/`%structure-set`）。
- 复制函数调用 `cl:copy-structure`；typed 结构（`:type list`/`vector`）的描述也记在会话里，只生成访问器。
- 构造函数、谓词、BOA lambda list 用 Anatomicl 的原样代码：构造函数调用 `allocate-instance` 和 `(setf slot-value)`。
- **目标端**（`lisp/target/clos/structures.lisp`）：`structure-class` 是 `standard-class` 的子类，`structure-object` 是 `standard-object` 的子类；`copy-structure` 逐个复制已绑定的槽；`structure-class` 上的 `allocate-instance :before` 方法负责 finalize 类（Anatomicl 的构造函数直接调用 `allocate-instance`）。
- 限制：构造函数走 CLOS 实例的路径，很慢；`equalp` 不比较结构的槽；重定义结构走类的重定义（[clos.md](clos.md)），但 inline 的访问器在已编译的调用者里不会跟着变；运行期（`eval` 里）的 `defstruct` 不支持：会话里的结构布局没有传给 image 里的编译器。

## LOOP（Khazern）

Khazern 同时用于宿主和目标端：

- 交叉编译时，LOOP 由编译期环境里宿主的 Khazern（extrinsic）展开，展开结果只用标准运算符。
- 目标端：Khazern 编进 CLOS 模块，kiln 自己的 `loop.lisp` 代替它的 intrinsic 接口，只在加载期设定 `loop` 和 `loop-finish` 的宏函数（二者共用一个 epilogue 标签）。`define-interface` 会用 `defmacro` 定义 `cl:loop`，而那在编译期也生效，会换掉编译期的展开函数。
- 运行期的 LOOP 展开和宿主在编译期的展开逐一一致，只允许未 intern 符号的一致改名（`tests/m4/clos-loop.lisp`）。
- 补丁：累积变量的初值和数值类型里去掉 complex 和 pathname。

## 其他小库

- **alexandria**：Eclector 要用，alexandria-1 编进 CLOS 模块。宿主 alexandria 的宏不能直接当作编译期的展开函数（`once-only` 的展开结果里含有 SBCL 的反引号对象），所以除 `conditions`、`features`、`io`、`numbers` 之外的文件都以 `:compile-time-too` 加载，宏在编译期由编译期求值器执行。
- **Trinsic**：Cyclosis 和打印器模块用它的 `make-define-interface` 生成 CL 层的接口，作为目标端代码编译进 CLOS 模块。
- **trivial-package-locks**：`with-unlocked-packages` 定义成 `progn`。
- **trivial-with-current-source-form**：kiln 的条件还不记源码形式，`with-current-source-form` 展开成 `progn`。
- **Acclimation**：用于条件报告的本地化，只加载 English 部分。
