# CLOS

CLOS 是 CLOS 模块的前半部分（`lisp/target/clos/`，加上 vendor 的 Clostrophilia）。实例、rack、funcallable instance 和结构对象的表示见 [objects.md](objects.md)；对 Clostrophilia 的调研见 [clostrophilia.md](../research/clostrophilia.md)。

## 决定

1. **vendor 一份 Clostrophilia，打针对性的补丁，再加上 kiln 自己写的引导代码。** 不原样使用，也不自己从头写 CLOS。
   - 原样保留的部分（约 3500 行）：类层次，类、槽定义、方法、泛函的初始化，类终结，方法组合，`compute-applicable-methods-using-classes`，自动机的构造和最小化，增删方法，dependent 维护。这些代码忠于 AMOP，没有 SICL 特有的东西。
   - 打补丁的部分：运行期 `compile` 的调用点、funcallable instance 的 SICL 特有槽、过时实例的处理、分派的性能（见下文）。补丁列在 `vendor/README.md`。
   - kiln 自己写的部分：braid 和 early 函数、`make-instance` 和它的快路径、`ensure-class`/`ensure-generic-function`/`ensure-method`、EQL specializer 的登记、方法组合模板的登记、`class-of`、Common-macros 的 client 方法、`+1` 别名、`change-class`、类的重定义。
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
7. **内建类**：`t`、`symbol`、`cons`、`fixnum`、`integer`、`character`、`simple-vector`、`simple-string` 等（元类 `built-in-class`）。`class-of` 对标准实例取 rack 里的类，对结构对象取 layout 里的类，其他对象按 tag 和 kind 对应到内建类。非实例对象的类和 stamp 在切换之后按类型下标缓存在 simple vector 里（内建类不会重定义）。

运行期的 `make-symbol` 和 `gensym` 是 primop（在堆上分配 symbol），Clostrophilia 在运行期生成有效方法的形式时会用到。

## 分派

### 自动机和调用历史

- 用 Clostrophilia 的调用历史和自动机（`add-path`、`extract-transition-information`、`make-transfer-groups`），然后解释执行，不生成 `tagbody`。状态是展平的 simple vector（`start end target` 三个一组，按 stamp 排序），每个特化的必需参数走一次转移，用二分查找；查不到就调用 `default-discriminating-function`。终态直接保存有效方法。
- 转移（`automaton-transition`）和取 stamp（`argument-stamp`）是宏，在判别函数里展开；参数数目固定时每个特化参数的转移都按位置展开。
- **未命中时不总是重建**：Clostrophilia 每次未命中都把整个调用历史重新加进一个新的自动机，`add-path` 每加一条路径还要线性查找转移，代价是 N³（AST walker 的泛函调用历史有上千项）。现在未命中时，如果调用历史里已有这组类，就直接调用它的有效方法；未命中的次数达到上次构建时历史长度的四分之一才重建。这组类在调用历史里按 `eq` 查找。
- 在未命中路径里读泛函和方法的槽时，用 kiln 的 `%slot` 直接读，不调用读取器：读取器本身是泛函，可能也未命中，否则会无限递归。`%slot` 按槽列表和名字缓存位置。

### 展开调用和快速方法函数

AMOP 的方法函数接收参数列表和后续方法，有效方法接收一个参数列表，所以每次泛函调用都要构造 `&rest` 列表。kiln 在常见情况下免去这些分配：

- **展开调用**：泛函的 lambda list 只有必需参数、至多 6 个时（`spread-arity`），判别函数就是 `(lambda (a0 a1) ...)` 这样的闭包，调用历史里的有效方法函数也直接接收参数。有效方法是单个方法时：访问器方法直接读写槽（读到未绑定的槽时调用 `slot-unbound`）；有快速函数的方法直接用快速函数；其他有效方法（`:before`、`:around` 等组合）仍通过列表调用解释出来的闭包。
- **快速方法函数与单次编译**（`lisp/macro-client.lisp` 的 `method-lambda-forms`）：lambda list 只有必需参数（至多 6 个）的方法，编译期只生成一个快速函数，慢槽 `%function` 在运行期由 `method-function-from-fast` 包装快速函数得到，不再把方法体编译两遍。快速函数存在 `method` 的槽 `%fast-function` 里（Clostrophilia 补丁），按方法体是否使用 `call-next-method` / `next-method-p` 分三种形状：
  - 方法体不引用 `call-next-method` 和 `next-method-p`（绝大多数方法）：`%fast-function` 直接就是接收方法参数的 `(lambda (a1 ... an) ...)`，没有 `next-methods` 首参（因此 3 参数方法也能走寄存器参数的提前 poll），`spread-method-call` 直接返回这个函数本身，不再分配一层包装闭包；
  - 方法体只以零参数调用 `(call-next-method)` 和 `(next-method-p)`：`%fast-function` 记为 `(:next-function . (lambda (next-fn a1 ... an) ...))`，`spread-method-call` 在构造有效方法时就递归算好下一个方法的展开调用函数 `next-fn` 并用闭包绑定，调用时不再每次从方法实例读 `%fast-function` / `%function` 槽；
  - 其余情况（带参数的 `(call-next-method ...)` 或 `#'call-next-method`）：`%fast-function` 是 `(lambda (next-methods a1 ... an) ...)`。只以调用形式出现时，`call-next-method` 和 `next-method-p` 是局部宏；作为函数值出现时才是局部闭包。`bench/compare.lisp` 上 `call-next-method` 40.6 → 18.5 → 9.6 ns。
- 走 `next-methods` 列表的慢路径需要读下一个方法的 `%function` 和 `%fast-function` 槽时，两个槽的位置按最近见到的槽列表缓存（方法几乎都是 `standard-method`），不走 `%slot` 的查找。

### 缓存

- **判别闭包的缓存表**：只按一个或两个参数分派的泛函，判别闭包带一张直接映射表，以 stamp 的低位（两个 stamp 时是 `3·s1 xor s2`）为下标，大小是不小于调用历史长度的 2 的幂（4 到 256）。stamp 是连续分配的类编号，低位分布均匀。lambda list 里有 `&optional`、`&rest`、`&key` 的泛函，只按一个参数分派时也用同样的表（`make-single-dispatch-list-closure`），有效方法仍然接收参数列表。未命中的路径（查自动机、填表）放在单独的函数里：放在闭包里时，命中路径也要为它保存 callee-saved 寄存器、开一个大栈帧。
- **EQL 特化**：参数的类不能确定适用方法时，Clostrophilia 每次调用都重新计算适用方法和有效方法。kiln 的缓存条目是 `#(有效方法 spec0 spec1 ...)`，每个参数的 spec 是 NIL（不特化）、`(对象)`（等于某个 EQL 对象）或类的 stamp（参数不是任何 EQL 对象）。判别函数在自动机未命中时先逐条比较，比较时不分配内存；命中的条目移到表头（`eql-dispatch-lookup`：有几十个 EQL 方法的泛函原来每次都扫完整个表）。缓存跟着泛函走（`*eql-dispatch-caches*`），判别函数重算时保留，方法改变时清空；每个泛函至多 256 条。
- **单分派的判别闭包是两个闭包，命中时尾调用**（PCL 的判别函数也是比较之后直接跳到方法）：快闭包只为标准实例、funcallable instance 和结构就地取 stamp（其他对象的 stamp 要调用 `stamp+1`），用不检查边界的 `svref` 探表，命中就尾调用有效方法（`%primop :tail-funcall-function`，KIR 的 `tail-call-lisp`）；其余情况（其他对象、未命中、融合读取器的槽未绑定）尾调用慢闭包，慢闭包做完整的查表、填表，最后同样尾调用。快闭包里因此没有普通调用，不保存 callee-saved 寄存器，帧只有入口检查用的一点；`spread-method-call` 在没有 `call-next-method` 时直接返回方法函数本身（有 `call-next-method` 时包装闭包也是尾调用），funcallable instance 的跳板也是。按两个参数分派的判别闭包（`make-double-dispatch-closure`）同样拆成快、慢两个；带 `&optional` 等的单分派闭包和通用的自动机闭包命中后也尾调用有效方法。一次单态调用从“调用者 → 跳板 → 判别闭包 → 有效方法闭包 → 方法”四层调用变成一层调用加两次跳转：`bench/compare.lisp` 上单态 13.7 → 6.3 ns，多态（3 类）18.9 → 9.3 ns，读取器 10.4 → 5.4 ns，写入器 11.1 → 6.8 ns。代价是 backtrace 里看不到分派代码的帧，方法的帧直接接在调用者下面（未命中时是 `default-discriminating-function`）。
- **读取器和写入器融进缓存**：`spread-method-call` 把读写局部槽的闭包和槽的位置记在一张直接映射表里。只有一个参数的泛函（或两个参数、按第二个参数分派的 `(setf reader)` 泛函），判别闭包的缓存项存的是槽的位置而不是闭包，命中时自己读写槽；读取器遇到未绑定槽时仍经闭包，由它调用 `slot-unbound`。

### 过时实例

类重定义后，旧实例 rack 里的 stamp 和类当前的 unique number 不一致。Clostrophilia 的 `default-discriminating-function` 没有检查这一点（注释说要检查，代码没有），stamp 过时的实例会让分派死循环。kiln 的补丁在慢路径里先检查特化参数里有没有过时的实例，有就先更新再重新分派，这是重定义屏障（C4）在 CLOS 上的落实。

## 类定义检查

`defclass` 在宏展开时检查直接槽名和默认 initarg 名的唯一性。槽的 `:initform`、`:allocation`、`:type` 和 `:documentation` 只能出现一次，重复时报告 `program-error`；`:initarg`、`:reader`、`:writer` 和 `:accessor` 可以重复，用于声明多个初始化入口或访问函数。

## 类的重定义

`redefinition.lisp`，按 CLHS 4.3.6：

- `mop-ensure-class` 遇到已有的类（不是前向引用）时调用 `redefine-class`：元类必须相同；先删掉旧的直接槽的读写方法，再用新的 initargs `reinitialize-instance` 这个类。`defclass` 没写的选项（`:direct-default-initargs`、`:documentation`、`:direct-slots`）取默认值，而不是沿用旧值。
- 然后重新终结这个类和它所有已终结的子类（`refinalize`）。Clostrophilia 的 `finalize-inheritance` 每次都给类一个新的 unique number，所以之前创建的实例 stamp 都过时了。
- **假设**：重新 finalize 的每个类，它的 `(:class c)` 假设改变，它的名字的 `(:type name)` 假设也改变（[specialization.md](specialization.md)）。一批类的改变攒成一批：观察者只看到一次，重定义钩子也只收到一批通知。
- **调用历史**：`:class` 的观察者从所有泛函（`*early-generic-functions*`，switchover 之后新建的也加进去）的调用历史里删掉提到这些类的项，并让判别函数失效。这些项的可用方法可能已经变了（优先级列表变了），而且按旧 stamp 建的自动机只会匹配过时的实例。
- **过时实例的更新**：判别函数的未命中路径发现过时实例时调用 `update-obsolete-instance`。实例的 rack 里还留着它创建时的槽列表，所以旧槽可以按旧位置读出。新建一个当前类的实例，同名的局部槽照搬，新类没有的局部槽把名字放进 discarded、值放进属性表，新增的局部槽放进 added；实例接管新实例的 rack（和 `change-class` 一样），然后调用 `update-instance-for-redefined-class`，默认方法用 added 调用 `shared-initialize`。
- 还有 `find-method`、`make-instances-obsolete`、`slot-exists-p`。
- **限制**：只在泛函分派时检查过时实例。`slot-value` 直接按实例自己的槽列表找位置，所以过时实例在下次分派之前，用 `slot-value` 读到的仍是旧布局（值是对的，只是还没有更新）。类名 `typep` 的调用点缓存以 stamp 为键，过时实例在更新之前，在已经见过它的调用点上得到的是旧类的结果（全局缓存在重定义时清空，没有这个问题）。泛函的重定义（`defgeneric` 改 lambda list 等）还没有做。结构重定义创建新的类和 layout，旧实例保留旧类、stamp 和槽布局，不走过时实例更新。结构的访问器是 inline 函数，已编译的调用者不会跟着变。


## 对象重建形式

`make-load-form` 是泛函。类对象按已注册的名字生成 `find-class` 形式；标准对象、结构对象和 condition 的默认方法报错，由具体类提供重建协议。`make-load-form-saving-slots` 返回分配形式和槽恢复形式，支持指定槽名；默认保存实例槽，保留槽的未绑定状态，供调用方在分配对象后执行恢复形式。实现位于 `lisp/target/clos/load-forms.lisp`。

## 实例

直接调用 `allocate-instance` 也会先 finalize 类，随后按布局分配未绑定的槽。槽读取和标准读取器只保留 `slot-unbound` 的主值，包括缓存命中的路径和类槽；没有返回值时得到单个 NIL。缺少槽时，`slot-missing` 的主值按对应访问操作返回；setter 传入 `setf` 和新值，`slot-makunbound` 返回原实例。`remove-method` 返回其泛函，并保留不属于该泛函的方法与原泛函的关联。

- **`shared-initialize` 的计划**（`support.lisp`，`shared-initialize-aux-1`）：元类是 `standard-class` 的类，切换之后不再调用 Clostrophilia 的 `shared-initialize-aux`（那里对每个槽调用 `slot-definition-initargs` 和 `(setf slot-value-using-class)`，两个都是泛函）。现在按类的槽列表做一个计划：每个槽四项（initargs、位置、名字、initfunction），存在 simple vector 里，初始化时按计划直接读写槽位置。计划放在直接映射的缓存里，以槽列表为键、按它的 identity hash 取下标，冲突时覆盖。类变化时槽列表会被整个换掉，所以缓存不会过时。不用哈希表，因为切换时 Salmagundi 还没有加载。
- **`slot-value`**：对象是元类为 `standard-class` 的标准实例时，按 `%slot-location` 的缓存（键是槽列表和槽名）直接读写槽位置。槽名是常量的调用点由降级改写成带位置缓存的调用（`%slot-value-cached`，[specialization.md](specialization.md) 的“调用点特化”）：按对象的 stamp 直接找到位置，命中时和访问器方法一样快。
- **`make-instance` 的快路径**（`constructors.lisp`）：元类是 `standard-class`、实例适用的 `allocate-instance`、`initialize-instance`、`shared-initialize` 方法和一个普通标准对象的完全相同时，`make-instance` 直接分配 rack，补上 default initargs，再按初始化计划（`planned-shared-initialize`）填槽。这正是那三个方法做的事，省掉的是三次带 `&rest` 参数的泛函调用，以及 `allocate-instance-using-class` 里 initargs 的处理。
  - 判断结果按类缓存：直接映射的表，键是类的 unique number（重定义会改变它）和初始化假设的版本；往这三个泛函增删方法时 `note-method-change` 改变初始化假设（`add-method`、`remove-method` 的 `:after` 方法），所有类重新判断。
  - 判断时要调用 `compute-applicable-methods`，它可能又创建实例；判断期间的 `make-instance` 一律走通用路径，避免递归。
- 上面几处和访问器方法一样，假定没有对 `standard-class` 适用的 `slot-value-using-class` 方法（AMOP 不允许可移植程序定义这样的方法）。
- **`change-class`**（`change-class.lisp`）：实例的类、stamp 和槽都在 rack 里，所以先建一个新类的实例，复制同名的槽，原实例接管新实例的 rack，再用 initarg 初始化新增的槽。funcallable instance 也可以。不调用 `update-instance-for-different-class`。
- **前向引用的超类**：先是 `forward-referenced-class`；定义时，这个对象本身经 `change-class` 和 `initialize-instance` 成为真正的类，子类的 CPL 和特化在它上面的方法看到的是同一个对象。
- `:allocation :class` 的槽一开始是未绑定的，initform 才起作用（上游一开始就绑定为 NIL，已打补丁）。
- standard 方法组合不要求必须有主方法：只有辅助方法的有效方法，真正调用到主方法时才报错（Predicament 对 symbol 类型的 datum 只定义了 `:around` 方法）。
- 调用带 `&key` 的方法时，上游在参数后追加 `:allow-other-keys t`，方法的 `&rest` 参数也看得到它。kiln 改为在方法 lambda 的 lambda list 里加 `&allow-other-keys`。

## 结构对象

`defstruct` 的构造器按已知槽数直接分配原生结构对象，槽按位置读写。每个结构类有一个不可变的 layout，保存类、stamp、有效槽列表、继承深度、祖先 layout 向量和槽数；实例的 `class-of` 和分派 stamp 来自它。访问器内联比较祖先向量，`:include` 的实例使用同样的快速路径。

`slot-value`、`slot-boundp`、`slot-makunbound` 通过 layout 的有效槽列表找到位置，再直接访问实例。`copy-structure` 保留 layout，逐字浅复制槽，包括未绑定标记。`equalp` 对相同 layout 的结构逐槽递归比较。共享初始化确认 layout 中已有的槽列表，不能改写 layout；`change-class` 拒绝结构实例和结构类。

## 类名的 `typep`

- 编译器把类型是常量符号、又不在 CL 和 KEYWORD 包里的 `typep` 改成调用 `%typep-cached`，每个调用点带一个缓存（[lowering.md](lowering.md)）。CLOS 模块（`conditions.lisp`）的版本：类型名是类、又不是 deftype 时，结果只取决于对象的类，所以缓存的 car 存“上一个对象的 stamp 乘 2，结果为真再加 1”，是一个 fixnum，一次写入，GC 不需要扫描。缓存的 cdr 存填入时的类型假设版本：类型或类定义变了以后，过时实例还带着旧 stamp，调用点不能再用旧项，必须重新查全局表。
- 多态的调用点（AST walker 里的 `(typep node 'some-ast)`）总是不命中只有一项的调用点缓存，所以后面再加一个所有调用点共用的直接映射缓存，每项是 `(键 类型)`，下标由 stamp 和类型符号的 identity hash 异或得到。
- **全局缓存**（`*typep-cache*`，`%cached-typep`）：类型只取决于对象的类时，答案按 stamp 缓存，下标和调用点缓存的全局部分相同，两者共用一张表。kernel 的 `typep` 遇到 `or`、`and`、`not` 和不是标准类型名的 symbol 都先查它；类型不是常量、或者是复合类型（`(typep x '(or a-class b-class ...))`）时，调用点缓存帮不上忙，原来每次都要展开 `deftype`、`find-class`、再沿优先级列表找，这一处曾占自举时间的约 11%。
  - 哪些类型只取决于类（`class-determined-type-p`）：`typep` 用谓词判断、而谓词对一个内建类的对象全真或全假的 symbol（`null`、`cons`、`integer`、`character`、`function` 等）；其余命名了类又不是 deftype 的 symbol（`typep` 就是查优先级列表）；以及它们的 `or`、`and`、`not`。`keyword`、`bit` 这类不是类，字符串和向量类型只覆盖原生对象，都不缓存；`(integer 0 10)`、`satisfies`、`member` 也不缓存。判断过不能缓存的类型记在一张按 identity hash 直接映射的小表里，下次不再判断。
  - 以类型说明符本身（`eq`）为键，常量说明符因此每个调用点一项；运行期新构造的说明符只会不命中，结果仍然对。程序修改已经用过的类型说明符时缓存会过时（和修改常量一样不被允许）。
  - **失效**：`deftype`、`(setf find-class)` 和类的重新 finalize 都改变类型假设（`(:type name)`，[specialization.md](specialization.md)）；`:type` 的观察者清空这张表、不能缓存的记录和 ctype 的缓存。重定义要清空，是因为过时实例的 stamp 仍是旧的 unique number，清空之后它们按 `class-of` 得到新类的答案。新类第一次终结时拿到新的 unique number，不会碰上旧项。`change-class` 换掉实例的 rack，stamp 随之变成新类的。
  - `allocate-general-instance` 判断类是不是 funcallable 时也查这张表（`subclass-cached-p`，键是类的 unique number，类型是类对象），不再每次分配都沿优先级列表找。
  - 命中时一次 `typep` 约 18–26 ns（原来 `or` 约 90 ns，非常量的类名约 80 ns）。SBCL 用每个 layout 的 `inherits` 向量按继承深度 O(1) 判断子类；这里没有这样做，因为缓存命中后不再看优先级列表，剩下的未命中在自举里可以忽略。
- 不命中时，类名作为类型经 kernel 的 `*class-typep*` 按类查优先级列表。`typecase`、`handler-case` 和 `check-type` 都依赖它。

## 已知限制

- 泛函的重定义不支持；过时实例只在分派时更新（见“类的重定义”）。
- `slot-value` 在过时实例更新之前读的是旧布局（值是对的，只是还没更新）；类名 `typep` 的调用点缓存已经不是限制（它检查类型假设的版本）。
- `make-instance` 是普通函数，不是泛函；快路径之外通过通用构造协议；常量类名调用点的构造器可在原生编译器载入后晋升为机器码（[specialization.md](specialization.md)）。
- `change-class` 不调用 `update-instance-for-different-class`。
- 用户写的长形式 `define-method-combination`，产生的代码里有解释器不认识的运算符时不能用。
- 有效方法的形式不是 `spread-form-closure` 认得的那几种（`call-method`、`progn`、`multiple-value-prog1`、`make-method`）时，仍要构造参数列表；用 `#'call-next-method` 的方法每次调用仍要分配两个局部函数闭包；带参数的 `(call-next-method ...)` 仍要从 `next-methods` 列表里读下一个方法。
