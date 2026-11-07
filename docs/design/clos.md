# CLOS

CLOS 是 CLOS 模块的前半部分（`lisp/target/clos/`，加上 vendor 的 Clostrophilia）。实例、rack 和 funcallable instance 的表示见 [objects.md](objects.md)；对 Clostrophilia 的调研见 [clostrophilia.md](../research/clostrophilia.md)。

## 决定

1. **vendor 一份 Clostrophilia，打针对性的补丁，再加上 kiln 自己写的引导代码。** 不原样使用，也不自己从头写 CLOS。
   - 原样保留的部分（约 3500 行）：类层次，类、槽定义、方法、泛函的初始化，类终结，方法组合，`compute-applicable-methods-using-classes`，自动机的构造和最小化，增删方法，dependent 维护。这些代码忠于 AMOP，没有 SICL 特有的东西。
   - 打补丁的部分：运行期 `compile` 的调用点、funcallable instance 的 SICL 特有槽、过时实例的处理、分派的性能（见下文）。补丁列在 `vendor/README.md`。
   - kiln 自己写的部分：braid 和 early 函数、`make-instance`、`ensure-class`/`ensure-generic-function`/`ensure-method`、EQL specializer 的登记、方法组合模板的登记、`class-of`、Common-macros 的 client 方法、`+1` 别名、`change-class`。
2. **单一环境、目标端引导。** SICL 在宿主里构造多层环境（E1 到 E4），让宿主运行未修改的 MOP 代码生成目标 metaobject。kiln 从第一天起就有自己的 runtime，所以用 PCL 式的 early 函数：先用非泛函的引导函数建出核心类和泛函，再切换到完整的 MOP。SICL 拒绝这条路是出于追求优雅，不是因为不可行。SICL 的 `+1` 名字在 tie the knot 之后都是同名函数的别名，所以在单一环境里直接把它们绑定到不带 `+1` 的函数上。
3. **判别函数和有效方法是闭包，不在运行期编译。** Clostrophilia 在运行期调用 `compile nil` 生成判别函数、有效方法和访问器方法函数；kiln 的 CLOS 先于编译器存在，所以改为：
   - 判别函数：遍历最小化后的自动机的闭包；
   - 有效方法：为方法组合产生的形式构建闭包（`call-method`、`make-method`、`progn`、`multiple-value-prog1`、`if`、`quote`、`and`、`or` 和全局函数调用），覆盖 standard 方法组合和所有内建的短形式；其他运算符可以经 `*effective-method-operators*` 登记解释方式（ctype 的 `surely` 就是这样）；
   - 访问器方法：直接读写槽位置的闭包。

   原生 `compile` 已经有了（[eval-compile.md](eval-compile.md)），编译出来的判别函数、有效方法和构造器是性能工作的下一步（[roadmap.md](../roadmap.md)），解释执行的版本仍然保留，作为没有编译器时的路径。
4. **否决：在宿主里 satiation，把生成的代码作为目标代码输出。** 生成的形式把活的堆对象（泛函、方法函数、槽位置的 cons）当作字面量嵌入，只能改成加载时查找；stamp 来自运行期计数器，宿主必须精确复现目标端的类终结顺序。这实际上又回到了 SICL 的多层环境方案。

## 引导

源文件和顺序在 `lisp/driver.lisp` 的 `*clos-files*`，大致参照 SICL 的 Phase 4，但只有一个环境。

1. **宏的展开**：`defclass`、`defgeneric`、`defmethod` 用 Common-macros 的展开，通过 client 方法（`lisp/macro-client.lisp`）展开成对 `kiln.sys:%defclass`、`%defgeneric`、`%defmethod` 的调用。特化符以标识的形式传入（类名，或 `(eql 对象)`），这样类还不存在的时候 `defmethod` 也能求值。
2. **类的描述**（`early.lisp`）：braid 建成之前，`%defclass` 只记录参数，`%defgeneric`、`%defmethod` 推迟执行。
3. **建 braid**（`braid.lisp`）：Clostrophilia 的类层次加上 kiln 的内建类（`built-in-classes.lisp`）一次建好。`build-classes`：
   - 用 Clostrophilia 的算法（照原样移植）计算优先级列表、有效槽和槽位置、default initargs，结果必须和它的 `compute-class-precedence-list`、`compute-slots` 相同，因为以后真正的 MOP 会基于这些槽位置；
   - 先分配所有类对象，再按元类的有效槽填写（从 initarg 取值，否则调用 initfunction），最后补上派生的槽：优先级列表、有效槽、实例大小、unique number（stamp）、已终结、直接子类和 prototype；
   - 有效槽定义里槽名和位置记下来，之后 early 代码按槽名经 rack 的槽列表读写元对象，不经过泛函。
   
   然后执行推迟的定义。
4. **early 泛函**：真正的 `standard-generic-function` 实例，判别函数是 `early-discriminate`：按每个必需参数的 `class-of` 和优先级列表计算适用方法，按特化程度排序，按 standard 方法组合执行，不缓存。它很慢，但已经是完整的分派，足以运行 Clostrophilia 自己的初始化和终结方法。braid 里的类，访问器方法是真正的 `standard-reader-method`/`standard-writer-method`。在 early 阶段，`make-instance` 只按 initarg 和 initform 填槽，不调用 `initialize-instance`。
5. **Clostrophilia 的其余部分**：槽访问、方法组合、对象初始化、类终结、泛函调用、dependent 维护，以及泛函、类、方法、槽定义的初始化。`define-method-combination` 的展开函数要调用 Clostrophilia 自己的函数，这几个文件以 `:compile-time-too` 加载。Ecclesia 此时还编不了（要用哈希表和 `ignore-errors`），Clostrophilia 运行期要用的四个函数先用 `clos/ecclesia.lisp` 的简化版代替，它们不检查 lambda list。kiln 的引导代码和 Clostrophilia 在同一个包里，引导代码自己的辅助函数都以 `early-` 开头。
6. **切换**（`switchover.lisp`）：
   - 所有 early 泛函换上 standard 方法组合，清空调用历史；
   - **satiation**：early 判别函数还装着的时候，对每个泛函，按它的方法在每个特化位置可能遇到的类做笛卡尔积，对每组类调用 `compute-applicable-methods-using-classes`，有主方法的组合加进调用历史。组合数超过 `*satiation-limit*`（4000）的泛函跳过；
   - 先算好所有泛函的判别函数，再一次性装上。之后调用遇到新的类，走 `default-discriminating-function`；它自己调用的泛函对现有的元类都已经 satiated，所以不会无限递归；
   - `*switched-p*` 置真。此后 `make-instance` 走 `allocate-instance-using-class`（按需终结类，补上 default initargs）再 `initialize-instance`；`ensure-class` 是 `make-instance` 元类再登记 `find-class`；`ensure-generic-function` 通过 `find-method-combination` 取方法组合；`ensure-method` 是 `make-instance` 方法类再 `add-method`。
7. **内建类**：`t`、`symbol`、`cons`、`fixnum`、`integer`、`character`、`simple-vector`、`simple-string` 等（元类 `built-in-class`）。`class-of` 对实例取 rack 里的类，其他对象按 tag 和 kind 对应到内建类。非实例对象的类和 stamp 在切换之后按类型下标缓存在 simple vector 里（内建类不会重定义）。

运行期的 `make-symbol` 和 `gensym` 是 primop（在堆上分配 symbol），Clostrophilia 在运行期生成有效方法的形式时会用到。

## 分派

### 自动机和调用历史

- 用 Clostrophilia 的调用历史和自动机（`add-path`、`extract-transition-information`、`make-transfer-groups`），然后解释执行，不生成 `tagbody`。状态是展平的 simple vector（`start end target` 三个一组，按 stamp 排序），每个特化的必需参数走一次转移，用二分查找；查不到就调用 `default-discriminating-function`。终态直接保存有效方法。
- 转移（`automaton-transition`）和取 stamp（`argument-stamp`）是宏，在判别函数里展开；参数数目固定时每个特化参数的转移都按位置展开。
- **未命中时不总是重建**：Clostrophilia 每次未命中都把整个调用历史重新加进一个新的自动机，`add-path` 每加一条路径还要线性查找转移，代价是 N³（AST walker 的泛函调用历史有上千项）。现在未命中时，如果调用历史里已有这组类，就直接调用它的有效方法；未命中的次数达到上次构建时历史长度的四分之一才重建。这组类在调用历史里按 `eq` 查找。
- 在未命中路径里读泛函和方法的槽时，用 kiln 的 `%slot` 直接读，不调用读取器：读取器本身是泛函，可能也未命中，否则会无限递归。`%slot` 按槽列表和名字缓存位置。

### 展开调用和快速方法函数

AMOP 的方法函数接收参数列表和后续方法，有效方法接收一个参数列表，所以每次泛函调用都要构造 `&rest` 列表。kiln 在常见情况下免去这些分配：

- **展开调用**：泛函的 lambda list 只有必需参数、至多 6 个时（`spread-arity`），判别函数就是 `(lambda (a0 a1) ...)` 这样的闭包，调用历史里的有效方法函数也直接接收参数。有效方法是单个方法时：访问器方法直接读写槽（读到未绑定的槽时调用 `slot-unbound`）；有快速函数的方法直接调用快速函数；其他有效方法（`:before`、`:around` 等组合）仍通过列表调用解释出来的闭包。
- **快速方法函数**（`lisp/front.lisp` 的 `method-lambda-forms`）：lambda list 只有必需参数（至多 6 个）的方法另有一个 `(lambda (next-methods a1 ... an) ...)`。它的 `call-next-method` 不带参数时，若下一个方法也有快速函数就直接调用，否则才构造列表。快速函数存在 `method` 的槽 `%fast-function` 里（Clostrophilia 补丁）。
- 方法体没有出现 `call-next-method`、`next-method-p` 时，不生成这两个局部函数（它们是闭包，每次调用都要分配）。

### 缓存

- **判别闭包的缓存表**：只按一个或两个参数分派的泛函，判别闭包带一张直接映射表，以 stamp 的低位（两个 stamp 时是 `3·s1 xor s2`）为下标，大小是不小于调用历史长度的 2 的幂（4 到 256）。stamp 是连续分配的类编号，低位分布均匀。lambda list 里有 `&optional`、`&rest`、`&key` 的泛函，只按一个参数分派时也用同样的表（`make-single-dispatch-list-closure`），有效方法仍然接收参数列表。未命中的路径（查自动机、填表）放在单独的函数里：放在闭包里时，命中路径也要为它保存 callee-saved 寄存器、开一个大栈帧。
- **EQL 特化**：参数的类不能确定适用方法时，Clostrophilia 每次调用都重新计算适用方法和有效方法。kiln 的缓存条目是 `#(有效方法 spec0 spec1 ...)`，每个参数的 spec 是 NIL（不特化）、`(对象)`（等于某个 EQL 对象）或类的 stamp（参数不是任何 EQL 对象）。判别函数在自动机未命中时先逐条比较，比较时不分配内存。缓存跟着泛函走（`*eql-dispatch-caches*`），判别函数重算时保留，方法改变时清空；每个泛函至多 256 条。

### 过时实例

类重定义后，旧实例 rack 里的 stamp 和类当前的 unique number 不一致。Clostrophilia 的 `default-discriminating-function` 没有检查这一点（注释说要检查，代码没有），stamp 过时的实例会让分派死循环。kiln 的补丁在慢路径里先检查特化参数里有没有过时的实例，有就先更新（换 rack）再重新分派，这是重定义屏障（C4）在 CLOS 上的落实。类的重定义还不支持，所以目前的“更新”是报错。

## 实例

- **`shared-initialize` 的计划**（`support.lisp`，`shared-initialize-aux-1`）：元类是 `standard-class` 的类，切换之后不再调用 Clostrophilia 的 `shared-initialize-aux`（那里对每个槽调用 `slot-definition-initargs` 和 `(setf slot-value-using-class)`，两个都是泛函）。现在按类的槽列表做一个计划：每个槽四项（initargs、位置、名字、initfunction），存在 simple vector 里，初始化时按计划直接读写槽位置。计划放在直接映射的缓存里，以槽列表为键、按它的 identity hash 取下标，冲突时覆盖。类变化时槽列表会被整个换掉，所以缓存不会过时。不用哈希表，因为切换时 Salmagundi 还没有加载。
- **`slot-value`**：对象是元类为 `standard-class` 的标准实例时，按 `%slot-location` 的缓存（键是槽列表和槽名）直接读写槽位置。
- 上面两处和访问器方法一样，假定没有对 `standard-class` 适用的 `slot-value-using-class` 方法（AMOP 不允许可移植程序定义这样的方法）。
- **`change-class`**（`change-class.lisp`）：实例的类、stamp 和槽都在 rack 里，所以先建一个新类的实例，复制同名的槽，原实例接管新实例的 rack，再用 initarg 初始化新增的槽。funcallable instance 也可以。不调用 `update-instance-for-different-class`。
- **前向引用的超类**：先是 `forward-referenced-class`；定义时，这个对象本身经 `change-class` 和 `initialize-instance` 成为真正的类，子类的 CPL 和特化在它上面的方法看到的是同一个对象。
- `:allocation :class` 的槽一开始是未绑定的，initform 才起作用（上游一开始就绑定为 NIL，已打补丁）。
- standard 方法组合不要求必须有主方法：只有辅助方法的有效方法，真正调用到主方法时才报错（Predicament 对 symbol 类型的 datum 只定义了 `:around` 方法）。
- 调用带 `&key` 的方法时，上游在参数后追加 `:allow-other-keys t`，方法的 `&rest` 参数也看得到它。kiln 改为在方法 lambda 的 lambda list 里加 `&allow-other-keys`。

## 类名的 `typep`

- 编译器把类型是常量符号、又不在 CL 和 KEYWORD 包里的 `typep` 改成调用 `%typep-cached`，每个调用点带一个缓存（[lowering.md](lowering.md)）。CLOS 模块（`conditions.lisp`）的版本：类型名是类、又不是 deftype 时，结果只取决于对象的类，所以缓存的 car 存“上一个对象的 stamp 乘 2，结果为真再加 1”，是一个 fixnum，一次写入，GC 不需要扫描。
- 多态的调用点（AST walker 里的 `(typep node 'some-ast)`）总是不命中只有一项的调用点缓存，所以后面再加一个所有调用点共用的直接映射缓存，每项是 `(键 类型)`，下标由 stamp 和类型符号的 identity hash 异或得到。
- 其他情况下，类名作为类型时经 kernel 的 `*class-typep*` 按类查优先级列表。`typecase`、`handler-case` 和 `check-type` 都依赖它。

## 已知限制

- 类、泛函和结构的重定义不支持；过时实例的更新是报错。
- `make-instance` 是普通函数，不是泛函；没有预编译的构造器。
- `change-class` 不调用 `update-instance-for-different-class`。
- 用户写的长形式 `define-method-combination`，产生的代码里有解释器不认识的运算符时不能用。
- 方法组合（`call-next-method`、`:before`、`:around`）的有效方法仍要构造参数列表，用到 `call-next-method` 的方法每次调用仍要分配两个局部函数闭包。
