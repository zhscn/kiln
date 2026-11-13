# 标准库：condition、哈希表、包、类型、数组、结构、LOOP

这些都编进 CLOS 模块，放在 CLOS 之后（[modules.md](modules.md)）。流、文件、打印和读入见 [io.md](io.md)。vendor 的模块的补丁见 `vendor/README.md`。

## 列表和序列

kernel 的列表与序列函数在 `lisp/target/kernel.lisp`、`sequences.lisp` 和 `types.lisp`。树替换先比较整个子树，命中后直接返回替换值；`subst`、`sublis` 及其谓词变体保留未变化的子树，破坏性变体更新原 cons。

`make-sequence` 展开 `deftype`，接受序列类和具体的列表、向量类型，检查长度约束并按元素类型分配。`map`、`merge` 和 `concatenate` 使用同一套结果类型检查；`concatenate` 的列表结果是新列表。`elt` 按有效序列长度检查下标，`map-into` 按目标向量容量写入并更新 fill pointer。`nsubstitute` 更新原序列，向量的 `sort` 和 `stable-sort` 写回原向量；`replace` 返回原目标对象，内部存储快路径保留目标的元素类型约束。

## condition 系统（Predicament）

Predicament 按 `predicament-common.asd` 的顺序加载。实现方要提供的部分照 SICL 的 `Code/Conditions/` 来写（`lisp/target/clos/conditions.lisp`）：

- **类**：元类 `condition-class` 是 `standard-class` 的子类，槽访问和初始化的方法都直接适用；`condition` 是它的实例。报告函数存在实例的 `%report` 槽里（SICL 用 class 分配的槽，所有 condition 类会共用一个格子）。
- **`define-condition`** 展开成 `defclass`，带 `(:metaclass condition-class)`，`:report` 变成 default initarg。`make-condition` 经 `*condition-maker*` 对 condition 类做 `make-instance`。
- **early 阶段的 condition**：kernel 的 early `define-condition` 记下的定义（Ecclesia、Clostrophilia 的约 80 个）在 Predicament 之后建成真正的 condition 类（`early-conditions.lisp`），之后 Clostrophilia 报出的错误可以被 handler 捕获。
- **运行期错误**：编译出的代码和 kernel 发现的错误经 `%runtime-error` 变成 condition（[kernel.md](kernel.md)）。
- **报告**：条件的 `print-object` 在不转义时打印报告。Predicament 给 `error`、`parse-error`、`program-error`、`control-error`、`reader-error`、`warning`、`style-warning`、`storage-condition` 定义的、不看条件内容的报告在 kiln 下去掉了：Khazern 的条件同时继承 `parse-error` 和 `acclimation:condition`，类优先级里 `parse-error` 在前，它的“A parse error has occurred.”会盖住 Acclimation 的本地化报告。没有报告的条件打印成“Condition X was signalled.”，和 SBCL 一样。
- **条件参数和 restart 报告**：simple condition 的格式参数默认是 NIL；`error`、`signal`、`warn` 支持函数形式的格式控制，`warn` 要求最终条件属于 `warning`。`cerror` 的附加参数用于 continuation 报告，条件对象自身不接收这些参数。restart 在不转义打印时调用报告函数；`:no-error` 子句接受普通 lambda list。
- **默认 debugger**：打印报告和 backtrace 后退出（[debugging.md](debugging.md)）；后端协议里是嵌套的 debug 层（[backend-protocol.md](backend-protocol.md)）。
- 前端为它做的：编译期的 `macroexpand` 按 kiln 的环境展开（`restart-case` 展开时要判断信号形式是不是 `error`、`signal`）；`restart-bind` 和 `restart-case` 所在的文件以 `:compile-time-too` 加载。

## 哈希表（Salmagundi）

用 Salmagundi 的 `bucket-hash-table` 类（名字没改），但表本身已经改成开放寻址（补丁）。接口层由 kiln 自己写（`hash-tables.lisp`），不用 Trinsic：`cl:make-hash-table`、`cl:sxhash`、`cl:with-hash-table-iterator` 由 kiln 定义，`gethash` 等直接就是 CL 的符号。

- EQ、EQL、EQUAL、EQUALP 的默认哈希函数是 `default-hash-function` 上的 EQL 方法。EQ 哈希用身份哈希（[objects.md](objects.md)），所以对象移动后表仍然有效，不需要 rehash。
- `eq`、`eql`、`equal` 表的散列函数直接处理 fixnum、字符、符号、字符串和 cons，不走 Salmagundi 逐步累加、为每次散列生成闭包的路径。混合一步用 `%primop :hash-mix`：在 fixnum 上做一步按 64 位截断的 FNV-1a，大整数按 62 位一段依次混入（Salmagundi 的 FNV 每一步都会产生 bignum）。
- **开放寻址**，和 CPython 的 dict 一样：条目按插入顺序放在三个向量里（键、值、哈希）；一个索引向量，长度是 2 的幂、至多用一半，按哈希线性探测映射到条目，探测时先比较存下的哈希。每个条目不分配任何对象；向量满了就加倍（`make-hash-table` 的 rehash size 和 threshold 只是提示，CLHS 允许）。
- **迭代顺序**按插入顺序，和 SBCL 一样。宏展开函数会遍历哈希表（Khazern 的解构临时变量），kiln 编译 kiln 必须得到 SBCL 的 KIR；按哈希顺序遍历的话，身份哈希每次运行都不同。`tests/m4/clos-hash-model.lisp` 用一个模型和 SBCL 的迭代顺序检查表。
- 查找要用的数据放在一个 simple vector 里，按固定位置从实例读出，eq、eql、equal 内联比较；`gethash`、`(setf gethash)`、`remhash` 遇到这种表时直接调用它的函数，不经过泛函。`(setf gethash)` 在探测过程中记下第一个墓碑槽，未命中时直接写入，不再二次探测。
- 标准测试（`eq`、`eql`、`equal`、`equalp`）的 `make-hash-table` 直接分配实例并填写槽（`make-bucket-hash-table`），不走 `make-instance`；符号的 `equal` 哈希缓存在自身的身份哈希字段里。
- `sxhash` 对 fixnum、字符、符号和原生简单字符串直接混合，不分配累加闭包；复合对象和其他字符串保留累加实现。快慢路径使用相同种子、混合顺序、字符预算和结果掩码，哈希值保持一致。
- `equalp` 哈希对向量使用活动长度，对其他数组使用维度；嵌套内容的散列受深度预算约束。哈希表的各键值对分别混合，再用可交换的累加方式合并，因此插入顺序和表容量不会影响结果。标准测试的键使用对应的散列函数，值按 `equalp` 散列。
- 还没有弱表。

## 包（Parcl）

Parcl 以 intrinsic 方式加载：`parcl-low`（泛函协议和默认方法）、`parcl-low-class`（包是带槽的类）、`parcl` 公共层直接定义 `cl:intern`、`cl:find-symbol`、`cl:export`、`cl:use-package`、`cl:make-package` 等。kiln 的 client 和引导在 `package-system.lisp`。运行期的包怎样从模块的符号表建起来见 [modules.md](modules.md)。

- symbol 表和包注册表都是 `equal` 哈希表；`store-package` 检查重名。`find-package` 是 Parcl 的泛函，kiln 为包、字符串、symbol、字符各加一个方法；按名字查找时先看当前包的局部昵称，所以读入 `a:foo` 也会用到它们。
- 在 KEYWORD 里 intern 的 symbol 设为外部 symbol，并以自身为值。`keywordp` 比较 `kiln.kernel::*keyword-package*`。
- kiln 自己写的：`list-all-packages`、`packagep`、`rename-package`、`delete-package`、`unintern`、`find-all-symbols`、`do-symbols`、`do-external-symbols`、`do-all-symbols`、`with-package-iterator`（先把要遍历的 symbol 收集成列表）。
- **运行期的 `defpackage` 和 `in-package`**：`%defpackage` 按 CLHS 的顺序建立或更新包（昵称、shadow、shadowing import、use 列表、import、intern、export、包局部昵称）；包已存在时就地更新，不检查和原定义的差异；没有 `:use` 时 use 列表为空，和 SBCL 一样；忽略 `:documentation` 和 `:size`。`in-package` 展开成对 `*package*` 的赋值。模块里顶层的这两个宏只在编译期执行（[front-end.md](front-end.md)）。
- 包操作返回标准规定的值；`intern` 接受一般字符串并使用其有效内容。只有外部 symbol 会被继承，`shadowing-import` 直接安装指定 symbol，`import` 保留已存在 symbol 的内外部状态。
- 包迭代宏的 `return` 退出整个迭代，声明也作用于结果式。`with-package-iterator` 必须至少指定一种 symbol 状态。
- `defpackage` 检查重复的 `:size`、`:documentation` 和必须互斥的 symbol 名列表。导入不存在的 symbol 时提供 `intern` restart；删除不存在的包或仍被使用的包时提供 `continue`。`make-package` 遇到已占用的名字或昵称时，`continue` 返回已有包，与 SBCL 一致。
- `apropos-list` 按名称忽略大小写搜索可访问符号，按身份去重并排序；包参数为 NIL 时搜索所有包。支持 SBCL 的第三个可选参数 `external-only`，指定包时只保留属于该包的外部符号。`apropos` 打印结果及绑定摘要，返回零个值。
- 启动时 `*package*` 是 `COMMON-LISP-USER`。
- 限制：冲突时的 restart 只有 Parcl 原有的那些（`use-package` 冲突直接报 `package-error`）；`do-symbols` 对有 use 列表的包是平方复杂度（Parcl 的 `map-symbols` 用列表去重）。

## 类型（ctype）和 `deftype`

- **`deftype`**：Common-macros 的 `deftype` 通过 client 钩子生成 `(kiln.sys::%deftype 'name expander)`，外面套一层三种时机都有的 `eval-when`。编译期环境里的 `%deftype` 把展开函数登记到编译期环境，kernel 里的把它存到名字的 plist 上。Ecclesia 为省略初始值的可选参数和关键字参数生成被引用的 `*`，显式初始值按形式求值。
- **ctype** 按 `ctype.asd` 的顺序加载，但 `host.lisp` 和 `runtime.lisp` 换成 kiln 的 client（`ctype-client.lisp`，原文件在加载时用宿主的 `subtypep` 和类计算常量），`interface.lisp` 换成 `ctype-interface.lisp`，定义 `cl:subtypep`、`cl:upgraded-array-element-type`、`cl:upgraded-complex-part-type`。
- client 的取值：浮点只有 single-float 和 double-float（short-float 归入 single，long-float 归入 double）；正负零是不同的值；数组的 UAET 按 Regalia 的类划分；base-char 是 0–127，extended-char 是其余 Unicode 码点；standard-char 仅含换行和 ASCII 可打印字符。三者与 kernel 的 `typep` 一致，类型判断依赖具体字符，不按类缓存。`character` 接受字符、有效长度为一的字符串和名字长度为一的符号，其他输入报告类型错误。
- ctype 的泛函用长形式方法组合 `basic`，它生成 `(surely (call-method ...) ...)` 这样的有效方法；ctype 的 client 经 `*effective-method-operators*` 登记 `surely` 的解释（依次调用各个方法，直到第二个值为真），所以不需要运行期编译器。
- **缓存**：类型说明符的解析结果和 `subtypep` 的答案缓存在 `equal` 哈希表里；键复制说明符语法，但 `eql` 和 `member` 的字面量参数用 EQL 身份令牌表示，自定义 `deftype` 的带参数形式不缓存，对类型假设的一个版本有效；两个符号的 `subtypep` 缓存在第一个符号的 plist 上，带那个版本。`deftype`、`(setf find-class)` 或类的重新 finalize 改变类型假设（[specialization.md](specialization.md)），缓存在下一次使用时清空。写每个字符的流操作都要调用 `subtypep`，所以缓存是必要的。
- 复数分量类型升级保留空类型 NIL，并区分 rational、single-float、double-float、float 和 real；`typep` 与 `coerce` 共用这些升级结果。
- ctype 里特化在 `complex` 上的部分（`ccomplex.lisp`）仍用 `#-kiln` 去掉（接入时 kiln 还没有 complex）：`subtypep` 不懂 complex 类型；`typep` 对 complex 类型由 kernel 回答。

## 数组（Regalia）

**混合表示**：元素为 T 的一维 simple vector 和 simple string 是原生对象，`svref`、`schar` 和 kernel 的快路径不变；其余数组都是 Regalia 的槽存储实例。

- **类层次**：CL 的 `array`、`simple-array`、`vector`、`simple-vector`、`string`、`simple-string`、`bit-vector`、`simple-bit-vector` 都是内建类，原生对象的类是 `simple-vector` 和 `simple-string`。Regalia 的类在 `regalia` 包里，补丁遮蔽同名的 CL 符号；它的 `array` 以私有 `slot-object` 和 `cl:array` 为父类。存储类本身不区分简单性；公开 `class-of` 按实例的简单性、元素类型和秩返回内建数组类，内部槽访问及分派使用物理存储类。
- **存储**：元素存在 `contents` 槽里的原生向量中（补丁加了 `%contents` 和 `%adjustable` 两个槽）。字符数组用字符串存，其他元素类型都用 simple-vector 存，特化类型在写入时检查元素类型。displaced 数组没有存储，读写时转到目标数组，加上偏移。
- **kernel 的钩子**：kernel 的 `stringp`、`vectorp`、`arrayp`、`length`、`aref`、`char`、`row-major-aref`、`array-rank`、`array-dimensions` 等先处理原生向量，其余对象交给 `*complex-array-kind*`（把对象映射为 `:string`、`:vector`、`:array` 或 NIL）和 `*complex-array-op*`（按关键字执行操作）。kernel 在泛函分派内部也会问种类（`gethash` 的分派会调用 `stringp`），所以这里不能调用泛函：种类按 stamp 查一张向量。
- 编译后的单下标 `aref` 及其 setf 在非原生数组上调用固定参数读写钩子，避免构造下标列表和通用行主序计算。边界检查使用实际维度，存储访问仍检查元素类型并处理位移；内部检查与存储辅助函数内联到调用处。
- kernel 内部用 `make-simple-vector` 构造向量；`make-array` 对元素类型为 T 或 character 的简单情况直接返回原生对象，不调用 `subtypep`。一维、没有位移的可调向量增长时直接换掉原生存储（`resize-vector`）。
- **kiln 自己写的**（`arrays.lisp`，Regalia 的这些部分不完整或有错）：`make-array` 的全部关键字参数；`aref`/`row-major-aref` 及其 setf，检查下标；fill pointer 和 `vector-push-extend` 等；`adjust-array`；`array-displacement` 等查询；`bit`、`sbit`；`upgraded-array-element-type`。整数升级保留 unsigned-byte 的 2/4/7/8/15/16/31/32/62/63/64 位、signed-byte 的 8/16/32/64 位、fixnum 及 bit；空类型 NIL、base-char、character 和浮点类型分别保留。存储类按同一升级结果选择，缓存遵循类型假设版本和字面量身份；显式环境绕过缓存。从 Regalia 加载类层次、存储类选择、维度检查和 condition 类型。
- base-char 使用独立的数组与字符串存储类，写入时检查字符范围；NIL 元素数组不允许读取或写入元素。原生字符串的存储元素类型为 character；simple-string 和 simple-base-string 谓词及 `schar` 同时支持原生与槽存储表示。`string` 保留已有字符串的对象身份；需要原生缓冲区的内部操作单独转换表示。`array-has-fill-pointer-p` 对非数组报告类型错误。
- 限制：序列函数对非 simple 向量返回 simple 向量；没有 `bit-and` 等位数组运算。

## 结构（Anatomicl）

**Anatomicl 在编译期运行**：它把 `defstruct` 形式解析成描述对象，再生成普通的 Lisp 代码，生成的代码不引用 Anatomicl 自己。所以它是宿主库（kiln 上编进 compiler 模块），`defstruct` 是受保护的宿主宏（[front-end.md](front-end.md)）。kiln 的 client 在 `lisp/structures.lisp`：

- **typed 选项检查**：显式指定 predicate 的 typed 结构必须有 `:named`；named vector 的元素类型必须包含 `symbol`，不能只靠数组元素类型升级后能够容纳名字。选项不兼容时在宏展开期报告 `simple-error`。
- **`:include` 的槽布局**：Anatomicl 默认通过 closer-mop 读被包含结构的类，可编译期没有目标端的类。kiln 在编译会话里记下每个结构的槽布局（`session-structures`）：先是被包含结构的槽（访问器名按本结构的 `conc-name` 重新生成，`:include` 给出的槽描述覆盖原有的），再是本结构自己的直接槽。
- **类定义与原生表示**：生成目标端的 `defclass`，元类是 `structure-class`；实例是原生结构对象（`+kind-structure-instance+`），第一个字指向布局向量，其后按位置紧排各槽，不需要单独的 rack 对象。`:print-object` 选项生成 `print-object` 方法。
- **访问器、谓词和构造函数**：布局向量存在包 `kiln.structures` 的全局变量里，经 `%primop :symbol-global-value` 直接读取（不经过 TLS 查找）。访问器、可写槽的 setf 函数、类型谓词（`%structure-typep`，按布局向量里的深度和祖先表做 O(1) 判断）以及至多 8 个槽的标准构造函数都声明为 `inline`；标准构造函数直接生成 `%primop :allocate-structure` 和按位置的 `:set-structure-slot`（调用点上内联展开时，关键字参数也在编译期解析）。
- 复制函数调用 `cl:copy-structure`；typed 结构（`:type list`/`vector`）的描述也记在会话里，只生成访问器。BOA 构造函数用 Anatomicl 生成的 lambda list，分配和写槽同样走 `:allocate-structure` 和 `:set-structure-slot`。
- **目标端**（`lisp/target/clos/structures.lisp`）：`structure-class` 是 `standard-class` 的子类，`structure-object` 是 `standard-object` 的子类；`%ensure-structure-layout` 在类终结后建立布局向量；`copy-structure` 直接分配同长度的原生结构对象并逐槽复制。
- `#S`：每次结构定义把第一个标准关键字构造函数登记到类型名上；重新定义时更新登记。Eclector 的运行期与原生编译器 reader client 共用构造协议，把槽名转成 keyword 后调用该构造函数，保留默认值和继承槽。没有标准构造函数的结构和未定义的类型报告关联输入流的 `reader-error`。随机状态有私有标准构造函数，打印形式可回读并保持生成序列。
- 运行期 `defstruct` 使用 image 共用的结构布局表，宏展开和访问器生成与编译器前端一致。重定义结构走类的重定义（[clos.md](clos.md)），inline 访问器在已编译的调用者中不会自动更新。typed 结构的位置构造器按完整布局分配，保留初始偏移、名字标记和槽位置。

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
