# 10 M4：CLOS 引导

**状态**：进行中（2026-11），M4.1–M4.4 已完成（§5、§8、§9），M4.5 进行中（§10）。本文记录 M4 的决定和分步计划。依据是对 Clostrophilia（HEAD 9d0e86c，2026-08-29）的调研，结论记在 §2。

## 1. 决定

1. **vendor 一份 Clostrophilia，打针对性的补丁，再加上 kiln 自己写的引导代码。** 不原样使用，也不自己从头写 CLOS。
   - 原样保留的部分（约 3500 行）：类层次，类、槽定义、方法、泛函的初始化，类终结，方法组合，`compute-applicable-methods-using-classes`，自动机的构造和最小化，增删方法，dependent 维护。这些代码忠于 AMOP，没有 SICL 特有的东西。
   - 打补丁的部分：运行期 `compile` 的调用点（§3）、funcallable instance 的 SICL 特有槽、过时实例的处理。
   - kiln 自己写的部分（估计 1000–1500 行）：braid 和 early 函数、`make-instance`、`ensure-class`/`ensure-generic-function`/`ensure-method`、EQL specializer 的登记、方法组合模板的登记、`class-of`、Common-macros 的 client 方法、`+1` 别名、早期的 `define-condition`/`error`/`format` 桩。
2. **不在运行期编译：分派和有效方法改为解释执行。** Clostrophilia 在运行期调用 `compile nil` 生成判别函数、有效方法和访问器方法函数，kiln 在 M5 之前没有编译器。改法：
   - 判别函数：一个遍历最小化后的自动机的闭包，每一层对排好序的 stamp 区间做二分查找；
   - 有效方法：为方法组合产生的形式（`call-method`、`make-method`、`progn`、`multiple-value-prog1`、`and`、`or`、普通的运算符调用）构建闭包，覆盖 standard 方法组合和所有内建的短形式；
   - 访问器方法：直接是两个闭包。

   用户写的长形式 `define-method-combination` 产生任意代码，等 M5 有了编译器再支持。M5 之后保留一个开关，允许用编译器生成热点泛函的判别函数（seal 和 AOT 时有用）。

   **否决：在宿主里 satiation，把生成的代码作为目标代码输出。** 生成的形式把活的堆对象（泛函、方法函数、槽位置的 cons）当作字面量嵌入，kiln 没有堆快照（[04 关键选择 3](04-bootstrap.md#关键选择)），只能改成加载时查找。stamp 来自运行期计数器，宿主必须精确复现目标端的类终结顺序。这实际上又回到了 SICL 的多层环境方案。
3. **单一环境、目标端引导。** SICL 的 `+1` 名字在 tie the knot 之后都是同名函数的别名，所以在 kiln 的单一环境里，直接把它们绑定到不带 `+1` 的函数上。

## 2. 调研结论（Clostrophilia）

- 规模：16 个 ASDF 系统，约 5250 行，其中约 780 行是 `define-condition`。
- 唯一的库依赖是 Ecclesia。不用哈希表，不用 closer-mop。
- 需要 condition 系统（75 处 `error`，带自己的 condition 类型），加载时就会调用 `format` 和 `(setf documentation)`。
- 不是完整的 CLOS：没有 `make-instance`、`class-of`、`find-class`、`ensure-*` 系列、EQL specializer 的登记、`change-class`、`update-instance-for-redefined-class`、`print-object`。`defclass`/`defgeneric`/`defmethod` 宏来自 Common-macros，通过 client 钩子接入。SICL 用 `Code/CLOS/` 里约 530 行补上这些。
- 实现方要提供的原语：`allocate-general-instance`、`standard-instance-access` 及其 `setf`（位置 −2 是 stamp，−1 是有效槽列表，0 起是槽）、`+unbound-slot-value+`、`stamp`、`class-of`、`find-class`、`small-integer=`/`small-integer<`、`set-funcallable-instance-function`、`make-method-instance`、方法组合模板的查找和登记、`subtypep-1`。
- 运行期 `compile` 的调用点：判别函数（`compute-discriminating-function.lisp:482`）、有效方法（`:319`、`:392`，以及 `compute-effective-method.lisp` 里 `call-method`、`make-method` 的展开函数）、访问器方法函数（`maybe-replace-method.lisp:35,56`）。
- 方法函数的形式是 `(lambda (参数列表 next-methods))`，有效方法接受一个参数列表，所以每次泛函调用都会构造 `&rest` 列表。
- 没有假设堆不移动：只用 `eq`、`assoc`、`member`，不取地址。
- **缺陷**：`default-discriminating-function` 不检查过时实例（注释说要检查，代码没有），stamp 过时的实例可能导致死循环。kiln 的重定义屏障（C4）本来就要处理这件事。

## 3. 对象表示

| kind | 类型 | 布局 |
|---|---|---|
| 9 | standard-instance | `[header, rack]` |
| 10 | funcallable-instance | `[header, 入口, rack, 安装的函数]` |
| 11 | rack | `[header(长度), class, stamp, 有效槽列表, 槽...]` |

- **类指针放在 rack 里**（[05 §4.1](05-sicl-survey.md) 里 SICL 在考虑的替代设计）：`change-class` 和实例更新只需要替换 rack 指针这一个字。header 里空出的位以后存身份哈希（Salmagundi 的 EQ 哈希表需要它）。
- `standard-instance-access` 的位置 *loc* 对应 rack 的第 *loc* + 4 个字（第 0 个字是 header，第 1 个字是 class），所以 −2 是 stamp、−1 是有效槽列表、0 起是槽。
- **funcallable instance 就是函数**：kind 10 和 kind 2 只差第 3 位，调用点用 `(kind & 0xF7) == 2` 同时接受两者，`funcall`、`apply` 不需要特殊处理。它的入口是一个共享的跳板，从对象里取出安装的函数，按原样转交所有参数（包括传递区里的参数，跳板里没有 safepoint）。
- 非标准对象的 stamp：`class-of` 按对象的 kind 和 tag 查一张表得到内建类，stamp 是这个类的唯一编号。

## 4. 分步

| 步骤 | 内容 |
|---|---|
| M4.1 | 实例、rack、funcallable instance 的表示和原语（`allocate-general-instance`、`standard-instance-access`、`stamp`、`set-funcallable-instance-function`），调用点接受 funcallable instance |
| M4.2 | 宿主侧执行目标源码里的 `defpackage`（只为读入；运行期仍然没有包）；vendor Clostrophilia（原样一个提交）；早期的 `define-condition`/`error`/`format`/`documentation` 桩 |
| M4.3 | braid 和 early 函数；`make-instance`、`ensure-*`；把 Clostrophilia 编译成一个模块；分派和有效方法的解释执行补丁 |
| M4.4 | 切换到完整的 MOP：satiation（在目标端，用解释执行的分派），安装判别函数，early 访问器换成真正的泛函；用户程序的 `defclass`/`defgeneric`/`defmethod` 测试 |
| M4.5 | Predicament（condition 系统），然后依次接入 Salmagundi（哈希表）、Parcl（包）、ctype（类型；Regalia 选数组类要用 `subtypep`，所以提前）、Regalia（数组）、Anatomicl（`defstruct`） |

## 5. M4.1 的实现记录

- runtime：kind 9–11 的大小、GC 扫描（rack 扫描全部字；funcallable instance 跳过入口地址，扫描 rack 和安装的函数）和打印。
- 原语（`%primop`）：`:allocate-general-instance`、`:allocate-general-funcallable-instance`（参数和 Clostrophilia 的 `allocate-general-instance` 一致：类和 rack 里 class 之后的格数，含 stamp 和槽列表）、`:standard-instance-access` 及其 setter、`:instance-rack`/`:set-instance-rack`（换 rack 是一次存储）、`:instance-class`、`:set-funcallable-instance-function`、`:standard-instance-p`、`:funcallable-instance-p`。
- funcallable instance 的入口是共享的跳板 `kiln_funcallable_trampoline`：从对象的第 3 个字取出安装的函数，用原来的 `nargs` 和寄存器参数调用它，返回它的全部值。跳板里没有 safepoint，传递区里的参数原样传下去。新建的 funcallable instance 安装的是一个调用即报错的函数。
- 编译器里所有“是不是函数”的检查（`funcall`、`apply`、`functionp`、函数标识）改为 `(kind & 0xF7) == 2`。
- `tests/m4/instances.lisp`：rack 的读写和替换、跨 GC、funcallable instance 的调用（0 到 6 个参数、`apply`、`multiple-value-call`、`mapcar`、多值返回）。

## 6. M4.2：编译 Clostrophilia 之前的准备

- **LOOP**：Clostrophilia 有 75 处 `loop`。在宿主里加载 khazern-extrinsic，把它的 `loop`、`loop-finish` 宏函数装进编译期环境作为 `cl:loop`、`cl:loop-finish`。Khazern 的展开结果只用标准运算符，不引用它自己的运行期函数，所以目标端不需要加载 Khazern。`tests/m3/loop-macro.lisp`。
- **`defpackage`**：顶层的 `defpackage` 在宿主里求值，不编译任何东西。宿主里已有的包（比如 Ecclesia 的）不动。
- **early 桩**（`lisp/target/early.lisp`，kernel 的一部分）：`error` 和 `cerror` 打印参数后终止程序（错误码 20）；`warn` 只打印；`format` 的目标是 NIL 时直接返回控制串；`assert`；`define-condition` 把定义（initform 和 `:report` 都做成函数）记在 `*early-condition-types*` 里，留给以后的 condition 系统；`documentation` 和它的 `setf` 把文档存在 symbol 的 plist 上。
- **运行期的 `(setf f)` 函数名**：symbol 加了第 8 个字，存名为 `(setf symbol)` 的函数。`fdefinition`、`(setf fdefinition)`、`fboundp` 都改成 kernel 函数，可以接受 setf 名字。early 引导要在运行期按名字创建写访问器的泛函，所以需要这个。
- **未绑定的槽**：立即数 `0x2b`，它和 `+unbound+` 不同，所以可以作为变量 `+unbound-slot-value+` 的值。
- NIL 和 T 是 runtime 里的静态对象，它们的 plist 以前不是 GC 根，而类 `t`、`null` 的描述就挂在这两个 plist 上。现在已经登记为根。

## 7. 引导方案（M4.3、M4.4 的设计）

实现记录见 §8。

按 PCL 的思路，在目标端用 early 函数引导，顺序参照 SICL 的 Phase 4（`Code/New-boot/Phase-4/boot.lisp`），但只有一个环境：

1. **宿主侧准备**：目标源码里的 `defpackage` 在宿主里执行，只是为了读入后面的源码（运行期仍然没有包，M4.5 接入 Parcl 后补上）。
2. **kernel 的 CLOS 原语**：`allocate-general-instance`、`standard-instance-access`、`stamp`、`small-integer=`/`<`、`+unbound-slot-value+`、方法组合模板的登记表（symbol 的 plist）、`find-class`（类名到类对象，也放在 symbol 的 plist）、`+1` 别名。
3. **early `ensure-class`**：`defclass` 由 Common-macros 展开成对 `ensure-class` 的调用。加载 Clostrophilia 的 `Class-hierarchy` 时，early `ensure-class` 只记录类的描述（名字、直接超类、直接槽、元类、default initargs），不创建对象。
4. **建 braid**：类层次全部记录之后，一次性创建所有类的元对象：
   - 按 Clostrophilia 的算法计算每个类的优先级列表和有效槽（必须和它的 `compute-class-precedence-list`、`compute-slots` 给出相同的结果，因为以后真正的 MOP 会基于这些槽位置）；
   - 每个元对象按它的元类的有效槽分配，用 early `make-instance` 填写：对每个有效槽，从 initarg 取值，否则调用 initfunction。槽定义对象、类对象都这样建；
   - 再按槽名直接填写派生的槽：优先级列表、有效槽、实例大小、唯一编号（stamp）、已终结标志、直接子类。
5. **early 泛函**：`defgeneric`/`defmethod` 展开成 `ensure-generic-function`/`ensure-method`。early 版本用 early `make-instance` 创建泛函（funcallable instance）和方法，并安装一个 **early 判别函数**：按每个必需参数的 `class-of` 和优先级列表计算适用方法，按特化程度排序，按 standard 方法组合执行（around、before、primary、after）。它很慢，但已经是完整的分派，足以运行 Clostrophilia 自己的初始化和终结方法。
6. **加载 Clostrophilia 的其余部分**：槽访问、对象初始化、类终结、方法组合、泛函调用（已打上解释执行的补丁）。
7. **切换**：对所有泛函做 satiation（用 Clostrophilia 的 `compute-discriminating-function`，此时它不再需要编译器），安装真正的判别函数；early 访问器换成真正的泛函。之后 `defclass` 走真正的 `ensure-class`。
8. **过时实例**：类重定义后，旧实例 rack 里的 stamp 和类当前的 unique number 不一致。M4.4 装真正的判别函数时，在 `default-discriminating-function` 的慢路径里补上这项检查：发现过时实例就先更新（`update-instance-for-redefined-class`，换 rack），再重新分派。这样可以避免 §2 里说的死循环，也就是重定义屏障 C4 在 CLOS 上的落实。
9. **内建类**：kiln 自己定义 `t`、`symbol`、`cons`、`fixnum`、`integer`、`character`、`string` 等内建类（元类 `built-in-class`），`class-of` 按对象的 tag 和 kind 查表。

## 8. M4.3 的实现记录

CLOS 是单独的模块（`kiln:compile-clos`，在 kernel 之后加载），源文件和顺序在 `lisp/driver.lisp` 的 `*clos-files*` 里。`tests/m4/clos-*.lisp` 和这个模块一起运行。

- **宏的展开**：`defclass`、`defgeneric`、`defmethod` 用 Common-macros 的展开，通过 client 方法（`lisp/front.lisp`）展开成对 `kiln.sys:%defclass`、`%defgeneric`、`%defmethod` 的调用。特化符以标识的形式传入：类名，或 `(eql 对象)`。这样类还不存在的时候 `defmethod` 也能求值。`call-next-method` 通过 `kiln.sys:%method-function` 取下一个方法的函数。
- **类的描述**（`lisp/target/clos/early.lisp`）：braid 建成之前，`%defclass` 只记录参数，`%defgeneric`、`%defmethod` 推迟执行。`build-classes` 从描述出发：
  - 用 Clostrophilia 的算法（照原样移植）计算优先级列表、有效槽和槽位置、default initargs；
  - 先分配所有类对象，再按元类的有效槽填写，最后补上派生的槽：优先级列表、有效槽、实例大小、unique number、已终结、直接子类和 prototype；
  - 槽定义对象也按描述创建。有效槽定义里槽名和位置所在的位置记下来，之后 early 代码按槽名经 rack 的槽列表（位置 −1）读写元对象，不经过泛函。
- **braid**（`braid.lisp`）：Clostrophilia 的类层次加上 kiln 的内建类（`built-in-classes.lisp`），一次建好，再执行推迟的定义。之后每个 early `defclass` 单独走 `build-classes`，暂不支持类的重定义。
- **early 泛函**：它们是真正的 `standard-generic-function` 实例（funcallable instance），判别函数是 `early-discriminate`：按优先级列表计算适用方法，按 standard 方法组合执行，不缓存。braid 里的类，其访问器方法是真正的 `standard-reader-method`/`standard-writer-method`，方法函数按槽名读写。
- **`class-of`**：实例取 rack 里的类；其他对象按 tag 和 kind 对应到内建类。`stamp`：实例取 rack 里的 stamp，其他对象取它的类的 unique number。
- **Clostrophilia 的其余部分**：braid 之后按 SICL Phase 4 的顺序加载，包括槽访问、方法组合、对象初始化、类终结、泛函调用、dependent 维护，以及泛函、类、方法、槽定义的初始化。它们的 `defgeneric`/`defmethod` 都成为 early 泛函和方法。在 early 阶段，`make-instance` 只按 initarg 和 initform 填槽，不调用 `initialize-instance`。
- **编译期也求值的文件**：`define-method-combination` 的展开函数要调用 Clostrophilia 自己的函数（`short-form-expander` 等），这几个文件以 `(:compile-time-too 路径)` 的形式给出，前端把它们的形式当作在 `(eval-when (:compile-toplevel :load-toplevel :execute))` 里处理。宿主的 Ecclesia 函数也导入了编译期环境。
- **Ecclesia**：它的实现要用哈希表和 `ignore-errors`，暂时编译不了。Clostrophilia 运行期要用的四个函数（`proper-list-p`、两个 `canonicalize-*-lambda-list`、`extract-required`）先用 `clos/ecclesia.lisp` 的简化版代替，它们不检查 lambda list。
- **实现方提供的函数**（`clos/support.lisp`）：`make-instance`（early 版）、`make-method-instance`、`allocate-general-instance`、方法组合模板的登记和查找（放在 symbol 的 plist 上）、`subtypep-1`（只用于类）、`shared-initialize-aux-1`。`compile` 目前是调用即报错的桩，M4.4 的解释执行补丁会去掉对它的调用。
- **名字冲突**：kiln 的引导代码和 Clostrophilia 在同一个包里，引导代码自己的辅助函数都以 `early-` 开头。`method-more-specific-p` 曾经和 Clostrophilia 的同名函数冲突。
- **Clostrophilia 的补丁**（`vendor/README.md`）：`*class-unique-number*` 改为 `defvar`，因为 braid 的类在这个文件加载之前就已经编号；`add-method` 的 `(setf documentation)` 不求值。
- 测试：`tests/m4/clos-braid.lisp` 检查优先级列表、有效槽的顺序和位置、元类、`class-of`、访问器的分派。`tests/m4/clos-early.lisp` 在用户程序里用 `defclass`/`defgeneric`/`defmethod`，覆盖 before、after、around 方法，`call-next-method`、`next-method-p`，EQL 特化，setf 泛函，以及经过 Clostrophilia 的 `slot-value`、`slot-boundp`。

### 分派和有效方法的解释执行（Clostrophilia 补丁）

- **判别函数**：仍用 Clostrophilia 的调用历史和自动机（`add-path`、`extract-transition-information`、`make-transfer-groups`），然后解释执行，不生成 `tagbody`。内部状态是按 stamp 排好序的区间向量 `(start end 目标)`，每个特化的必需参数走一次转移，用二分查找；查不到就调用 `default-discriminating-function`。终态直接保存有效方法。
- **有效方法**：`compute-effective-method` 仍返回形式，`effective-method-function` 把它变成闭包。支持 `call-method`、`make-method`、`progn`、`multiple-value-prog1`、`if`、`quote`、`and`、`or` 和全局函数调用，覆盖 standard 方法组合和所有短形式。长形式产生的其他代码要等 M5 的编译器。
- **访问器方法**：`maybe-replace-method` 产生的方法，其函数直接是读写槽位置的闭包。
- **过时实例**：`default-discriminating-function` 先检查特化参数里有没有 stamp 和它的类的 unique number 不一致的实例，有就先更新再重新分派。类重定义还不支持，所以目前的“更新”是报错，它保证 stamp 过时的实例不会让分派死循环。

## 9. M4.4 的实现记录：切换到 MOP

`lisp/target/clos/switchover.lisp`，在 CLOS 模块的最后执行：

1. 所有 early 泛函（`*early-generic-functions*`）换上 standard 方法组合，清空调用历史。
2. **satiation**：early 判别函数还装着的时候，对每个泛函，按它的方法在每个特化位置可能遇到的类（当前所有类里，优先级列表包含某个方法的特化符的那些；EQL 特化符取对象的类）做笛卡尔积。对每组类调用 Clostrophilia 的 `compute-applicable-methods-using-classes`，有主方法的组合用 `add-call-cache` 加进调用历史。组合数超过 `*satiation-limit*`（4000）的泛函跳过。
3. 先算好所有泛函的判别函数，再一次性装上。之后调用遇到新的类，走 `default-discriminating-function`；它自己调用的泛函（`call-history`、`compute-applicable-methods-using-classes`、`compute-effective-method` 等），对现有的元类都已经 satiated，所以不会无限递归。
4. `*switched-p*` 置真。此后 `%defclass`、`%defgeneric`、`%defmethod`、`make-instance`、`ensure-generic-function+1` 走 MOP：
   - `make-instance`：`allocate-instance-using-class`（按需终结类，补上 default initargs），然后 `initialize-instance`；
   - `ensure-class`：`make-instance` 元类，再登记 `find-class`；
   - `ensure-generic-function`：通过 `find-method-combination` 取方法组合；
   - `ensure-method`：`make-instance` 方法类，再 `add-method`。

`make-instance` 现在是普通函数，还不是泛函。类和泛函的重定义也还不支持。

其他改动：

- **运行期的 `make-symbol` 和 `gensym`**：Clostrophilia 在运行期生成有效方法的形式时会用到。原语 `:make-symbol` 在堆上分配 symbol，两个函数格都放上未定义函数对象。未定义的 `(setf f)` 有单独的报错入口（错误码 21）。
- **GC 压力测试的堆**：CLOS 的存活数据（元对象、satiated 的调用历史）超过 1 MiB，所以 `clos-*` 测试用 4 MiB 的堆。
- **构建**：debug 构建里依赖库（Cranelift、MMTk）也按 `opt-level = 2` 编译。否则 JIT 编译 kernel 和 CLOS 模块要 10 秒，现在约 1.6 秒（release 版 0.9 秒）。

`tests/m4/clos-mop.lisp` 覆盖：

- `initialize-instance :after`、`reinitialize-instance`、`:default-initargs`；
- `list`、`+`、`progn`（`:most-specific-last`）、`and` 这几种方法组合；
- 一个泛函上的十几种类和 EQL 特化；
- 先定义方法、后定义的子类；
- 两个特化参数加 `:around` 方法；
- setf 泛函；
- `class-direct-subclasses`、`class-finalized-p`。

## 10. M4.5：condition 系统（Predicament）

Predicament vendor 在 `vendor/Predicament`，补丁见 `vendor/README.md`。它在 CLOS 模块的末尾加载，顺序按 `predicament-common.asd`。实现方要提供的部分照 SICL 的 `Code/Conditions/` 来写（`lisp/target/clos/conditions.lisp`）：

- **类**：元类 `condition-class` 是 `standard-class` 的子类，这样槽访问和初始化的方法都直接适用；`condition` 是它的实例。报告函数存在实例的 `%report` 槽里（SICL 用 class 分配的槽，所有 condition 类会共用一个格子）。
- **`define-condition`** 展开成 `defclass`，带 `(:metaclass condition-class)`，`:report` 变成 default initarg。
- **`make-condition`**：Predicament 的 `make-condition` 调用 `*condition-maker*`，kiln 的实现是对 condition 类做 `make-instance`。
- **默认 debugger**（`*default-debugger*`）：还没有流和 REPL，所以它以错误码 20 结束程序，信息里有 condition 的类名和各个槽的值。泛函和实例按名字或类名显示。
- **类名作为类型**：kernel 的 `typep` 遇到不认识的原子类型，交给 `*class-typep*`；CLOS 把它设成“按类查优先级列表”。`typecase`、`handler-case` 和 `check-type` 都依赖它。
- **early 阶段的 condition**：kernel 的 early `define-condition` 记下的定义（Ecclesia、Clostrophilia 的约 80 个）在 Predicament 之后建成真正的 condition 类（`early-conditions.lisp`），之后 Clostrophilia 报出的错误可以被 handler 捕获。
- **流变量**：`*error-output*`、`*query-io*` 等先在 kernel 里定义为 NIL，等 Cyclosis 接入后再赋值。

前端为此做的修改：

- **Trucler 的缓存**：Trucler 的 reference 环境会把查到的全局函数、变量描述缓存在环境对象里。会话的环境在多个文件之间是同一个，后来的模块重新定义的宏（比如 CLOS 模块重新定义 kernel 的 early `define-condition`）会被缓存挡住，所以每个顶层形式之前都清空缓存。
- **编译期的 `macroexpand`/`macroexpand-1`**：按 kiln 的环境展开。Predicament 的 `restart-case` 展开时，要用它判断信号形式是不是 `error`、`signal` 之类。
- `restart-bind` 和 `restart-case` 所在的文件以 `:compile-time-too` 加载，因为它们的展开函数要调用同文件里的函数。

Clostrophilia 也为此打了补丁：standard 方法组合不再要求必须有主方法。只有辅助方法的有效方法，在真正调用到主方法时才报错。Predicament 对 symbol 类型的 datum 只定义了 `:around` 方法，它不调用 `call-next-method`。

**运行期错误也是 condition**：

- **生成的代码**：编译器生成的报错代码（类型检查、参数个数、未定义函数、未绑定变量、下标越界等）不再直接调用 runtime 结束程序，而是调用 kernel 的 `%runtime-error`，传入错误码（fixnum）和出错的对象。kernel 里 `%runtime-error` 的定义仍然是结束程序；CLOS 模块（`runtime-errors.lisp`）把它重定义为按错误码 `error` 出对应的 condition：`type-error`、`undefined-function`、`unbound-variable`、`division-by-zero`、`program-error` 等。这是普通的 Lisp 调用，调用链上没有 Rust 帧，handler 的非局部退出照常工作。
- **还没定义时**：`%runtime-error` 还没定义的时候（kernel 加载完之前），报错代码先检查它的函数格，未定义就直接结束程序。`:lisp-error`（early `error` 和默认 debugger 用的）始终直接结束程序。
- **数值运算**：runtime 的数值运算（Rust）发现的错误没法变成 condition，所以 kernel 在调用 runtime 之前先在 Lisp 里检查：`two-arg-*` 系列检查参数是不是实数，除法和 `truncate`、`floor` 等检查除数是不是零。

还没有接入的部分：

- `warn` 没有被 muffle 时的输出、报告函数和 `print-object` 都要等流和打印器；
- `invoke-debugger` 也还没有交互式 debugger。

`tests/m4/clos-conditions.lisp` 覆盖：`handler-case`、`handler-bind`、`signal`、`restart-case` 和 `invoke-restart`、`muffle-warning`、`ignore-errors`、`with-simple-restart`，condition 类型的 `typep`，带清理的非局部退出，嵌套的 handler，以及 Clostrophilia 报出的 `no-applicable-method-error`。还覆盖编译代码和 runtime 发现的错误：`car` 的类型错误、未定义函数、除零、参数个数不对、未绑定变量、下标越界、非数值参与运算。

## 11. M4.5：哈希表（Salmagundi）

Salmagundi vendor 在 `vendor/Salmagundi`，补丁都放在 `#+kiln` 分支里（见 `vendor/README.md`）。用的是它的 bucket 哈希表，接口层由 kiln 自己写（`lisp/target/clos/hash-tables.lisp`），没有用 Trinsic：

- `cl:make-hash-table`、`cl:sxhash`、`cl:with-hash-table-iterator` 由 kiln 定义；
- EQ、EQL、EQUAL、EQUALP 的默认哈希函数是 `default-hash-function` 上的 EQL 方法；
- `gethash` 等直接就是 CL 的符号（kiln 的补丁只遮蔽了 `make-hash-table` 和 `sxhash`）。

**身份哈希**：header 的第 40–63 位存身份哈希，长度字段限制为 32 位（第 8–39 位）。`%primop :identity-hash` 调用 runtime 的 `kiln_rt_identity_hash`：

- MMTk 堆里的对象第一次用到时分配一个哈希（计数器经 Fibonacci 散列得到的 24 位数，写进 header），GC 复制对象时连同 header 一起复制，所以对象移动后哈希不变；
- 静态对象（模块数据、runtime 的静态对象）不会移动，立即数没有 header，这两类都按位模式计算哈希。

Rust 和编译器里所有从 header 读长度的地方都改为只取 32 位（`header_length`）。

**哈希状态**：Salmagundi 的 FNV 实现每一步都会产生 bignum，kiln 的 client 改用 `%primop :hash-mix`：在 fixnum 上做一步按 64 位截断的 FNV-1a，大整数按 62 位一段依次混入。

为此做的通用修改：

- **读入用目标端的 features**：Eclector 读目标源码时，`*features*` 绑定为 kiln 的列表（`:kiln :common-lisp :64-bit :x86-64 ...`），不再用宿主 SBCL 的，否则 `#+sbcl` 的分支会被读进 kiln 的代码。
- **`defconstant`**（kernel 宏）：编译期把名字登记为编译期环境里的常量，引用处直接编译成值；加载时给 symbol 设值。kernel 定义了 `most-positive-fixnum`、`most-negative-fixnum`。
- **setf 展开器**：kiln 的 client 实现了 Common-macros 的 `get-setf-expansion`（展开 symbol macro 和宏形式、查 setf 展开器），`define-setf-expander` 在编译期把展开器登记到 Clostrum 环境。kernel 用它定义了 `getf` 和 `ldb` 的展开器。
- **声明里的函数类型**：Iconoclast 没有 `(function ...)`、`(values ...)` 这类复合类型的 AST，前端在转换之前把 `declare` 里的这类类型降级为 `function` 或 `t`，并去掉 `ftype` 声明。它们目前只是提示，不影响语义。
- **类型**：`typep` 对 `complex`、`pathname`、`bit-vector`、`structure-object` 等现在还没有对象的标准类型返回 NIL。kernel 加了 `byte`、`ldb`、`dpb`、`mask-field`、`ldb-test`，以及按一维向量实现的 `array-rank`、`array-dimensions`、`array-total-size`、`row-major-aref`。

`tests/m4/clos-hash-tables.lisp` 覆盖：四种测试函数；实例、symbol、cons 作 EQ 键，并在大量分配和 GC 之后查找；bignum、浮点、字符作 EQL 键；字符串和列表作 EQUAL 键；大小写无关的字符串和不同类型的数作 EQUALP 键；扩容、`remhash`、`maphash`、`clrhash`、迭代器和 `sxhash`。

## 12. M4.5：包（Parcl）

Parcl vendor 在 `vendor/Parcl`，以 intrinsic 方式加载：`parcl-low`（泛函协议和默认方法）、`parcl-low-class`（包是带槽的类）、`parcl` 公共层直接定义 `cl:intern`、`cl:find-symbol`、`cl:export`、`cl:use-package`、`cl:make-package` 等。kiln 的 client 和引导在 `lisp/target/clos/package-system.lisp`，Parcl 的补丁见 `vendor/README.md`。

**运行期的包镜像宿主的包**：目标源码由宿主 Eclector 读进宿主的包（`defpackage` 在宿主执行，见 §6），所以宿主的包结构就是目标程序的包结构。

- **编译期**：每个模块编译完后，编译器生成一张 symbol 表，记下两类宿主包，即模块里 symbol 的 home 包和模块的 `defpackage` 新建的包。每个包记录：
  - 名字、昵称、use 列表（只保留运行期存在的包）；
  - 模块里每个在该包中 present 的 symbol 及其状态（internal/external、是否 shadowing、该包是否是它的 home 包）；
  - 包局部昵称（同样只保留指向运行期存在的包的，按昵称排序）。没有这一项时，kiln 上交叉编译 eval 模块会读不了 `ecc:`：`KILN.CMD` 在运行期的包没有局部昵称（docs/11 §9）。
  
  `defpackage` 新建的包，它的外部 symbol，以及它从运行期存在的包 import 的 symbol，都会放进表里，哪怕模块没有引用（import 的宏在编译时已经展开，代码里不再出现，但运行期在这个包里读源码时要用到：kiln 上交叉编译 compiler 模块，parser.packrat 的 `with-current-source-form`，docs/11 §9）。kernel 额外带上 CL 的全部 978 个外部 symbol，这样运行期每个标准 symbol 都存在。宿主的 `KILN-USER`（测试程序读入的包）在运行期叫 `COMMON-LISP-USER`，昵称 `CL-USER`。
- **加载时**：模块的 init 函数第一件事是把这张表推到 `kiln.kernel::*module-symbol-tables*`，然后如果 `%register-module-symbols` 已经定义就调用它。CLOS 模块加载完 Parcl 和 client 后自己调用一次，把 kernel 和 CLOS 模块的表登记成包对象。登记过程：
  - 新建 Parcl 的包对象，填好符号表、use 列表和包局部昵称（宿主已经检查过冲突，所以直接写入，不走 `use-package` 的检查）；
  - 把每个 symbol 的 `package` 槽从包名字符串换成 home 包对象；
  - NIL 和 T 由 runtime 定义，单独登记。
  
  之后加载的模块在 init 开头就完成登记。
- **symbol 的 `package` 槽**：静态 symbol 的这个槽登记为 GC root，因为登记后它指向堆上的包对象；NIL 和 T 的同样登记为 root。新 primop 有两个：`:set-symbol-package`，以及 `:set-symbol-global-value`（新的 keyword 以自身为值）。
- **keyword**：`keywordp` 比较 `kiln.kernel::*keyword-package*`，包系统就位之前比较包名字符串。runtime 的打印器在 `package` 槽是字符串时比较名字，否则看 symbol 的值是不是它自己（T 除外）。

**kiln 的 client**：
- symbol 表是 `equal` 哈希表；
- 包注册表是另一张 `equal` 哈希表，把名字和昵称映射到包，`store-package` 检查重名；
- `find-package` 是 Parcl 定义的泛函，kiln 为包、字符串、symbol、字符各加一个方法；
- 在 KEYWORD 里 intern 的 symbol 设为外部 symbol，并以自身为值。

Parcl 没有提供的部分由 kiln 自己写：`list-all-packages`、`packagep`、`rename-package`、`delete-package`、`unintern`、`find-all-symbols`、`do-symbols`、`do-external-symbols`、`do-all-symbols`、`with-package-iterator`。其中 `with-package-iterator` 先把要遍历的 symbol 收集成列表。启动时 `*package*` 是 `COMMON-LISP-USER`。

**还没做**（运行期的 `defpackage`、`in-package` 和包局部昵称见 §23）：
- 冲突时的 restart 只有 Parcl 原有的那些（`use-package` 冲突直接报 `package-error`）；
- `do-symbols` 对有 use 列表的包是平方复杂度（Parcl 的 `map-symbols` 用列表去重）。

`tests/m4/clos-packages.lisp` 覆盖：
- 静态 symbol 的 home 包、继承来的 symbol、CL 的 978 个外部 symbol；
- 新 keyword、新包，`export`/`use-package` 后的继承，`use-package` 的冲突；
- `shadow`、`unintern`、`import` 无 home 包的 symbol；
- `do-symbols`、`with-package-iterator`、`rename-package`、`delete-package`、`find-all-symbols`。

## 13. M4.5：类型（ctype）和 `deftype`

顺序调整：Regalia 选数组类要用 `subtypep`，所以先接 ctype，再接 Regalia。

**`deftype`**：Common-macros 的 `deftype` 通过 client 钩子 `setf-type-function-wrapper` 生成 `(kiln.sys::%deftype 'name expander)`，外面套一层三种时机都有的 `eval-when`：
- 编译期环境里的 `%deftype` 把展开函数登记到 Clostrum；
- kernel 里的 `%deftype` 把它存到名字的 plist 上。

kernel 的 `typep` 自己认识内建的原子类型和常用的复合类型，其余的先用 `typexpand-1` 展开 `deftype` 定义的名字。展开不了的，symbol 交给 CLOS（类名），复合类型交给 ctype（`kiln.kernel::*ctype-typep*`）。`(setf compiler-macro-function)` 也在 kernel 里，编译器还不调用编译器宏。

**ctype** vendor 在 `vendor/ctype`，按 `ctype.asd` 的顺序加载，但有两处替换：
- `host.lisp` 和 `runtime.lisp` 换成 kiln 的 client（`lisp/target/clos/ctype-client.lisp`），因为原文件在加载时用宿主的 `subtypep` 和类计算常量；
- `interface.lisp` 换成 `ctype-interface.lisp`，它定义 `cl:subtypep`、`cl:upgraded-array-element-type`、`cl:upgraded-complex-part-type`。

client 的取值：
- 浮点只有 single-float 和 double-float，short-float 归入 single-float，long-float 归入 double-float；
- 正负零是不同的值；
- 数组目前只有元素为 T 的 simple-vector 和字符串（`string-uaets` 是 `(character)`），Regalia 接入后再扩充；
- base-char 是 0–127，与 kernel 的 `typep` 一致。

ctype 的泛函用长形式 method combination `basic`，它生成 `(surely (call-method ...) ...)` 这样的有效方法。Clostrophilia 的解释器加了 `*effective-method-operators*` 扩展点（补丁），ctype 的 client 用它登记 `surely` 的解释：依次调用各个方法，直到第二个值为真。这样 ctype 不需要运行期编译器。

还没有 complex：ctype 里特化在 `complex` 类上的方法用 `#-kiln` 去掉了，`(typep x '(complex ...))` 总是 NIL。顺便补上了 kernel 的 `substitute` 系列（`:start`、`:end`、`:count`、`:from-end`）和 `array-element-type`，`typep` 对数组类型也会检查维度。

测试：
- `tests/m3/deftype.lisp`：kernel 里的 `deftype`，不依赖 ctype；
- `tests/m4/clos-types.lisp`：
  - `subtypep` 覆盖整数范围、`member`/`eql`、`or`/`and`/`not`、列表和序列、浮点、类、`nil`/`t`、`satisfies`（结果不确定）、`keyword`、`deftype` 定义的名字；
  - 复合类型的 `typep`，以及 `upgraded-array-element-type`。

## 14. M4.5：数组（Regalia）

**混合表示**：
- 元素为 T 的一维 simple vector 和 simple string 仍是原生对象，`svref`、`schar` 和 kernel 的快路径不变。
- 其余数组都是 Regalia 的标准类的实例：多维数组、特化元素类型的数组，以及可调整、带 fill pointer 或 displaced 的数组。

**类层次**：
- CL 的 `array`、`simple-array`、`vector`、`simple-vector`、`string`、`simple-string`、`bit-vector`、`simple-bit-vector` 都是内建类。
- 原生对象的类是 `simple-vector` 和 `simple-string`，后者以前叫 `string`。
- Regalia 的类在 `regalia` 包里，补丁把同名的 CL 符号遮蔽掉。它的 `array` 以 `standard-object` 和 `cl:array` 为父类，`vector`、`string`、`bit-vector` 再分别加上对应的 CL 类。
- 简单与否由实例的状态决定：不可调整、没有 fill pointer、没有 displaced 的才是 simple。类本身不区分。

**存储**：Regalia 实例的元素存在 `contents` 槽里的原生向量中，补丁给 `array` 加了 `%contents` 和 `%adjustable` 两个槽。字符数组用字符串存，其他元素类型都用 simple-vector 存，特化类型在写入时检查元素类型。displaced 数组没有存储，读写时转到目标数组，加上偏移。

**kernel 的钩子**：kernel 的 `stringp`、`vectorp`、`arrayp`、`length`、`aref`、`char`、`row-major-aref`、`array-rank`、`array-dimensions` 等先处理原生向量，其余对象交给两个钩子：
- `*complex-array-kind*`：把对象映射为 `:string`、`:vector`、`:array` 或 NIL。kernel 在泛函分派内部也会问这个问题（`gethash` 的分派会调用 `stringp`），所以这里不能再调用泛函。答案来自加载时预先算好的「类 → 种类」alist，算之前先 finalize 每个类。
- `*complex-array-op*`：按关键字执行具体操作。

`string` 把非 simple 的字符串复制成 simple 的，所以字符串函数照旧用 `schar`。kernel 内部改用 `make-simple-vector` 构造向量，因为 `cl:make-array` 被数组层重新定义了，而它会经由 ctype 的 `subtypep` 间接构造向量。另外，`make-array` 对元素类型为 T 或 character 的简单情况直接返回原生对象，不调用 `subtypep`。

**kiln 自己写的部分**（`lisp/target/clos/arrays.lisp`）。Regalia 的这些部分不完整或有错，没有加载：
- `make-array`：从不设置 fill pointer；displaced 的读写忽略偏移；adjustable 分支递归调用自己时把参数原样传下去。
- `aref` 只有读，没有写。

kiln 自己实现的有：
- `make-array` 的全部关键字参数；
- `aref`/`row-major-aref` 及其 setf，并检查下标；
- `fill-pointer`、`vector-push`、`vector-push-extend`、`vector-pop`；
- `adjust-array`：可调整的数组就地修改，保留新旧维度都合法的元素；
- `array-displacement`、`array-in-bounds-p`、`array-row-major-index`、`adjustable-array-p`、`array-has-fill-pointer-p`；
- `bit`、`sbit`、`bit-vector-p`；
- `upgraded-array-element-type`：按 Regalia 的类划分，有 bit、8/16/32/64 位有符号和无符号整数、single-float、double-float、character，其余是 T。

从 Regalia 加载的有：类层次、`class-name-from-element-type`、维度检查、condition 类型。ctype 的 `upgraded-array-element-type` 和 `simple-array-p` 也改用这一层。

Common-macros 的展开式在运行期要用的 `ecase-type-error` 等 condition 类和 `check-type-error` 也在这一步补上了（`runtime-errors.lisp`）。

**还没做**：
- 打印器不认识 Regalia 数组；
- 序列函数对非 simple 向量先转成列表，结果是 simple 向量；
- `bit-and` 等位数组运算。

`tests/m4/clos-arrays.lisp` 覆盖：
- 原生对象的快路径；
- 多维数组和越界错误；
- fill pointer 和 `vector-push-extend`；
- 带 fill pointer 的字符串参与字符串函数；
- bit 和 `(unsigned-byte 8)` 数组，以及写入时的类型检查；
- displaced 数组、`adjust-array`、数组类型的 `subtypep`。

## 15. M4.5：结构（Anatomicl）

**Anatomicl 在宿主里运行**。它把 `defstruct` 形式解析成描述对象，再生成普通的 Lisp 代码，生成的代码不引用 Anatomicl 自己。所以 kiln 把它作为宿主库加载（`kiln.asd` 依赖 `anatomicl`），编译期环境里的 `defstruct` 宏直接调用它展开，不 vendor，也不打补丁。

kiln 的 client（`lisp/structures.lisp`）覆盖这几处：
- **`:include` 的槽布局**：Anatomicl 默认通过 closer-mop 读被包含结构的类，可编译期没有目标端的类。kiln 在编译会话里记下每个结构的槽布局（`session-structures`），据此计算：
  - 先是被包含结构的槽，访问器名按本结构的 `conc-name` 重新生成，`:include` 给出的槽描述覆盖原有的；
  - 再是本结构自己的直接槽。
- **类定义**：生成目标端的 `defclass`，元类是 `structure-class`。每个槽都有 initarg。`:print-object` 选项生成 `print-object` 方法。
- **访问器**（M5.1 之后，[11 §6](11-m5-self-hosting.md)）：访问器是 inline 的普通函数，不是泛函；可写的槽还有 inline 的 setf 函数。
  - 槽的位置就是它在布局里的序号：被包含结构的槽在前，`defclass` 里也是这个顺序，Clostrophilia 按这个顺序分配位置。
  - 结构的类存在包 `kiln.structures` 的一个变量里。实例的类就是这个类时直接读写槽；否则（包含它的结构的实例）先检查类型（`kiln.sys::%structure-ref`/`%structure-set`）。
- **复制函数**生成对 `cl:copy-structure` 的调用。
- **typed 结构**（`:type list`/`vector`）的描述也记在会话里，供 `:include` 使用，只生成访问器。

构造函数、谓词、BOA lambda list 的处理都用 Anatomicl 的原样代码：构造函数调用 `allocate-instance` 和 `(setf slot-value)`。

**目标端**（`lisp/target/clos/structures.lisp`）：
- `structure-class` 是 `standard-class` 的子类，`structure-object` 是 `standard-object` 的子类；
- `copy-structure` 逐个复制已绑定的槽；
- `structure-class` 上有一个 `allocate-instance :before` 方法，负责 finalize 类，因为 Anatomicl 的构造函数直接调用 `allocate-instance`，而它不像 `make-instance` 那样会 finalize。

顺带补上了 kernel 的 `make-sequence` 和 `(setf elt)`（typed 结构要用）。

**还没做**：
- `equalp` 不比较结构的槽；
- 没有 `#S(...)` 的打印和读入；
- ~~结构的访问器是泛函，不是普通函数，比较慢~~（M5.1 之后改成了 inline 函数）；
- 重定义结构和重定义类一样，还不支持。

`tests/m4/clos-structures.lisp` 覆盖：
- 默认构造函数、访问器、`setf`、谓词、复制；
- `conc-name`、BOA 构造函数（带默认值的 `&optional`）、只读槽、自定义谓词名；
- `:include` 及覆盖父结构槽的初值；
- `:type list` 和 `:type vector :named`；
- `copy-structure`；
- 在结构上定义方法，以及把结构用作哈希键。

至此 M4.5 计划中的模块都已接入：Predicament、Salmagundi、Parcl、ctype、Regalia、Anatomicl。

## 16. 流（Cyclosis）

Cyclosis vendor 在 `vendor/Cyclosis`，用的是 intrinsic 接口：CL 的流函数都是 Cyclosis 的。kiln 的 client 在 `lisp/target/clos/streams.lisp`，补丁见 `vendor/README.md`。

**Trinsic**：Cyclosis 和后面的打印器模块都用 Trinsic 的 `make-define-interface` 生成 CL 层的接口，所以 Trinsic 作为目标端代码编译进 CLOS 模块。它的宏在编译期环境里展开，生成 `define-interface` 宏，后者在 kiln 的 client 文件里展开成全部 CL 流函数和宏。展开式外面包着 `trivial-package-locks:with-unlocked-packages`，kiln 把它定义成 `progn`。

**和包的关系**：上游的 intrinsic 接口依赖加载时的包操作。Cyclosis 在自己的包里遮蔽 `stream`、`close`、`streamp` 等名字，加载时再把这些 symbol `shadowing-import` 进 CL。kiln 的源码由宿主读进宿主的包，运行期的包又是宿主包的镜像（§12），这一步做不了，所以补丁让 Cyclosis 直接使用这些 CL symbol，并去掉运行期的 `shadowing-import`/`export`。需要 client 参数的函数（`open`、`peek-char` 等）仍然遮蔽。展开函数（`expand-with-output-to-string` 等）在宏展开时要用，补丁把它们放进 `eval-when`。宿主的 `alexandria:parse-body` 已登记到编译期环境。

**标准流**：
- 文件描述符 0、1、2 上的 POSIX 文件流，经 synonym stream 绑定到 `*standard-input*`、`*standard-output*`、`*error-output*` 等；
- 读写通过两个新的 runtime 函数 `kiln_rt_fd_read` 和 `kiln_rt_fd_write`（`%primop :fd-read`/`:fd-write`），参数是 `(unsigned-byte 8)` 向量的原生存储；
- Cyclosis 每个字符都直接调用一次 `write(2)`，不缓冲，所以和 runtime 的 `print`（每次写一整行）的输出不会互相错乱。以后加缓冲时要一起处理。

**上游的错误**（已打补丁）：
- UTF-8 编码时把三字节的上界写成了 `#x1000`；
- 解码时移位方向是反的。

**编译器**：调用的参数个数受 ABI 限制（寄存器参数加上 transfer 区，共 67 个）。超过这个数的 `list`、`list*`、`vector` 调用改写成分块的 `list*` 嵌套（`vector` 再加一次 `coerce`），`nconc`、`append` 改写成嵌套调用。其他函数超过时报出函数名。

kernel 补上了全部 CxR 及其 setf 函数，还有 `*features*` 和 `nunion`。

**还没做**：
- `open`，因为还没有 pathname；
- 输出不缓冲；
- `print` 仍然是 runtime 的打印器，接 Incless 之后改为写 `*standard-output*`；
- `y-or-n-p`/`yes-or-no-p` 在接入 FORMAT 后可以用（§18），但输入按字符读：回答后面的换行也算一次无效回答，会多提示一次；`clear-input` 对 POSIX 流不起作用。

`tests/m4/clos-streams.lisp` 覆盖：
- 标准输出和标准错误输出；
- `with-output-to-string`、字符串输出流和输入流、`read-line` 的两个值和 EOF；
- broadcast stream、concatenated stream；
- `fresh-line`、UTF-8 编码、`end-of-file`。

## 17. 打印器（Incless）

Incless vendor 在 `vendor/Incless`，用的是 intrinsic 接口，源码没有改动。它定义了 `write`、`prin1`、`princ`、`print-object`、`print-unreadable-object`、`write-to-string`、`prin1-to-string` 和 `princ-to-string`。kiln 的 client 在 `lisp/target/clos/printer.lisp`：
- `class-slot-names` 用 Clostrophilia 的 `class-slots`；
- `write-identity` 打印身份哈希。

**`print` 还没有换**：`print` 仍由编译器内联成 runtime 的打印器（`kiln_rt_print`），测试的输出格式因此不变。Incless 定义的 `cl:print` 只有通过 `#'print` 调用时才会用到。等测试的 expected 统一迁移时再把内联去掉。

**Quaviver 的替身**（`lisp/target/clos/quaviver.lisp`）。Incless 只用到 Quaviver 的三个函数：
- `float-triple`：最短往返十进制表示，由 runtime 的 `kiln_rt_float_decimal`（`%primop :float-decimal`）用 Rust 的浮点格式化计算，分别取出有效数字、指数和符号；
- `write-digits`：照搬 Quaviver 的语义（小数点位置、前导零、数字分组）；
- `count-digits`。

真正的 Quaviver 有 7000 行，还依赖 `integer-decode-float` 等 kiln 还没有的函数，以后再换上。

**其他补充**（`printer-support.lisp`）：
- 打印和读入的变量（`*print-base*` 等）；
- `with-standard-io-syntax`；
- `readtable-case`：没有 readtable，固定返回 `:upcase`；
- `get-macro-character`：标准语法中的宏字符，用来判断 symbol 名字要不要转义；
- 实例的 `type-of`：类名，通过 kernel 的 `*instance-type-of*` 钩子；
- `complex`、`pathname`、`logical-pathname`、`random-state`、`readtable` 作为暂时没有实例的内建类，因为 Incless 在它们上面特化了方法；
- kernel 加了 `char-name`、`name-char`、`standard-char-p`。

**Common-boot 的一个错误**：对全局 special 变量，`augment-environment-with-binding-variable` 返回 `unless` 的 NIL，`let*` 之后的绑定和主体于是在 NIL 环境里转换，结果找不到 `let` 等运算符。Common-boot 是宿主侧的库（kiln 的前端），为此 vendor 到 `vendor/Common-boot`，ASDF 先于 `deps/` 找到它（`tools/env.lisp`），补丁见 `vendor/README.md`。

`tests/m4/clos-printer.lisp` 覆盖：
- 整数（含 bignum）、ratio、各种浮点（定点和指数形式、`-0.0`、double 的 `d0`）；
- 字符、带转义的字符串；
- symbol：keyword、需要 `|...|` 的名字、未 intern 的 symbol、包前缀；
- 点对列表、向量、多维数组、bit vector、带 fill pointer 的向量；
- `princ`、`:base`/`:radix`、`:case`、`*print-length*`、`*print-level*`；
- 结构的 `#S(...)`、用户定义的 `print-object` 和 `print-unreadable-object`。

## 18. FORMAT（Invistra）

Invistra vendor 在 `vendor/Invistra`，用的是 intrinsic 接口：`format` 和 `formatter` 都是 Invistra 的。kiln 的 client 在 `lisp/target/clos/format.lisp`，它同时也是打印器的 client（Invistra 通过 Incless 打印对象），并替换掉 `incless::*client*`。

**依赖**：
- Quaviver：只用到 §17 替身里的三个函数；
- nontrivial-gray-streams：kiln 定义了 `ngray` 包，转出 Cyclosis 中同名的 Gray 流 symbol（`ngray.lisp`）；
- Acclimation：用于条件报告的本地化，只加载 English 部分，作为目标端代码编译；
- Inravina（美化打印）：§25。最初没有加载，补丁走 SICL 那条不用 Inravina 的分支；接入 Inravina 后撤掉了这个补丁，`~<...~:>`、`~_`、`~I` 和 `~:T` 都可以用。

**补丁**（见 `vendor/README.md`）：
- `formatter` 展开成在运行期解释控制串的函数，返回 NIL 而不是剩余参数，因为 Invistra 的格式编译器是目标端代码，宏展开时不可用；
- 宏展开要用的 `unique-name` 在编译期也定义；
- 浮点的无穷和 NaN 通过 `float-triple` 判断；
- 输出到带 fill pointer 的字符串时，先在它上面开一个字符串输出流（上游直接把字符串当成了流）。

**其他补充**：
- Cyclosis 的 `y-or-n-p` 通过 Trinsic 的 `cell-value` 取 `format`，kiln 的 client 提供这个方法；
- Cyclosis 的 `stream-advance-to-column` 写的是换行而不是空格，导致 `~T` 输出换行（补丁）；
- `change-class`（`change-class.lisp`）：Invistra 解析指令时用它改变实例的类。实例的类、stamp 和槽都在 rack 里，所以做法是：先建一个新类的实例，复制同名的槽，原实例接管这个新实例的 rack，再用 initarg 初始化新增的槽；
- 条件的 `print-object`：不转义时打印它的报告；
- kernel 加了 `parse-integer`、`complexp`（总是 NIL），以及 `(setf (values ...))` 的 setf 展开器；
- 编译期环境里的 `(setf compiler-macro-function)` 什么也不做。之前用的是宿主的函数，会改掉宿主 SBCL 的编译器宏；而如果真把编译器宏登记进 Clostrum，Common-boot 又会去调用它尚未实现的 `expand-compiler-macro`；
- Common-macros 的 `with-output-to-string` 在给出字符串时调用 client 提供的构造函数，kiln 返回 Cyclosis 的字符串输出流。

**kiln-cg 变快**：接入流、打印器和 FORMAT 之后，CLOS 模块的 KIR 有 45 MB，debug 构建下每个 CLOS 测试启动要 32 秒，几乎都花在 kiln-cg 上。改动有三处：
- 编译器把模块的顶层形式每 16 个分成一块，各块编成单独的函数，由 init 函数依次调用（`*toplevel-chunk-size*`）。原来整个模块的顶层形式都在一个 6 MB 的函数里，而寄存器分配对函数大小是超线性的。
- kiln-cg 先串行构造各函数的 CLIF，再在所有核上并行生成机器码，最后按顺序用 `define_function_bytes` 定义，调用点表和栈图照旧从编译结果里取。JIT 和目标文件两条路径都适用。
- dev profile 下 kiln-cg 和 kiln-rt 也用 opt-level 2，debug 断言保持打开。Cranelift 的 IR verifier 默认关闭，`KILN_VERIFY=1` 打开；`KILN_CG_OPT` 设定 Cranelift 的 opt_level；`KILN_TIME=1` 打印各阶段耗时。

改完后启动约 10 秒：读入 KIR 2 秒，构造 CLIF 3 秒，生成机器码 3 秒，运行 2 秒。下一步可以把 CLIF 的构造也并行化（目前需要 `&mut Module` 来声明函数引用），或者让模块分别编译后再链接，这样 CLOS 模块只需编译一次。

`tests/m4/clos-format.lisp` 覆盖：
- `~A`/`~S`、`~D` 的宽度、填充字符和逗号分组，`~B`/`~O`/`~X`/`~R`；
- 英文基数词和序数词、罗马数字；
- `~F`/`~E`/`~$`、`~C`、`~%`/`~&`；
- 迭代、条件、大小写转换、`~*`、`~?`、`~P`、对齐；
- 输出目标：`t`、流、带 fill pointer 的字符串；
- `formatter`、格式错误的条件、条件报告。

## 19. 已知的缺口和偏差（汇总）

各节「还没做」的汇总，以 M4.5 结束、REPL 之前的状态为准。详细原因见括号里的章节。

**与 CL 不一致的行为**：
- **`formatter`**（§18）：展开成在运行期解释控制串的函数，没有在编译期编译控制串；返回 NIL，而不是剩余的参数。
- **`print`**（§17）：仍由编译器内联成 runtime 的打印器：先打印对象再换行，而不是 CL 的「先换行、再打印对象、后跟空格」；不经过 `*standard-output*`、`print-object` 和打印变量。`#'print` 是 Incless 的正确版本。
- **编译器宏**（§18）：编译期的 `define-compiler-macro` 被忽略，运行期只记在 plist 上，编译器从不调用。因此 `format` 的控制串也不会在编译期编译。
- **`y-or-n-p`**（§16）：一次无效回答之后会多提示一次。
- **reader**（§22）：没有运行期的 `eval`，所以 `#.` 报错；读入的 `` ` `` 形式是 Eclector 的 `quasiquote` 宏调用，运行期可以展开。
- **`complexp`**（§13、§18）：总是 NIL。`complex`、`pathname`、`logical-pathname`、`random-state`、`readtable` 只是没有实例的内建类，`(typep x '(complex ...))` 总是 NIL。
- **`make-array`**（§14）：结果在可以用原生对象时就是原生对象；序列函数对非 simple 向量返回 simple 向量。
- **结构**（§15）：`equalp` 不比较结构的槽；访问器是泛函。
- **`change-class`**（§18）：只复制同名的槽并初始化新增的槽，不调用 `update-instance-for-different-class`。
- **标准条件的报告**（§25）：Predicament 给 `error`、`parse-error` 等 8 个标准条件定义的、不看条件内容的报告去掉了，没有报告的条件打印成「Condition X was signalled.」，和 SBCL 一样。
- **pathname**（§21）：只支持 Unix 的物理 pathname，没有 host 对象（物理 pathname 的 host 是 NIL），名字里不能用反斜杠转义；`directory` 不解析符号链接；`:if-exists :new-version`（输出的默认值）在文件已存在时报错，和 SBCL 一样；字符流的 `file-position` 以八位组计。
- **时间**（§21）：没有时区，所以没有 `decode-universal-time`、`get-decoded-time`；`sleep` 期间其他线程不能做 GC（现在还没有其他线程）。
- **运行期的宏展开**（§20）：`macroexpand` 只看全局宏，没有 symbol macro，环境参数被忽略；运行期的宏只有目标代码里 `defmacro` 定义的那些和 LOOP，标准宏（Common-macros）只在编译期存在。

**还没有的功能**：
- 运行期的 `eval`/`compile`，REPL 的前提（reader 已有，§22）。
- 标准流的输出缓冲（§21：文件流有缓冲，标准流没有）。
- 类、泛函、结构的重定义（§7、§15）。
- 浮点的 `integer-decode-float` 等，以及真正的 Quaviver（§17）。
- 位数组运算（`bit-and` 等），打印器以外对 Regalia 数组的完整支持（§14）。

## 20. M4.6：LOOP（Khazern）和运行期的宏环境

M4.6 为 M5 补齐编译器在目标端运行所需的东西，顺序是 LOOP、pathname 和文件流、reader、运行期的包操作，最后测一次前端在目标端的性能。

**运行期的宏环境**：此前 `(setf macro-function)` 是编译器原语，在运行期什么也不做。现在它是 kernel 的函数，把展开函数记在符号 plist 的 `macro-function` 下；kernel 还加了 `macro-function`、`macroexpand-1`、`macroexpand`、`*macroexpand-hook*` 和 `constantp`。

- `defmacro` 在加载期也会调用 `(setf macro-function)`，所以它是 kernel 的第一个定义，只用原语（经过同样只用原语的 `%put`）。
- `defconstant` 在加载期给符号做常量标记，`constantp` 据此判断。
- 编译期仍然用前端自己的 `macro-function`（Clostrum 环境），两者互不影响。

**Khazern**：vendor 在 `vendor/Khazern`，同时用于宿主和目标端。
- 宿主：交叉编译时 LOOP 仍然由宿主里的 Khazern（extrinsic）展开（docs/08）。
- 目标端：Khazern 编译进 CLOS 模块，kiln 自己的 `loop.lisp` 代替它的 intrinsic 接口。`define-interface` 会用 `defmacro` 定义 `cl:loop`，这在编译期也生效，会把编译期环境里宿主的展开函数换成一个调用目标端代码的展开函数；所以 `loop.lisp` 只在加载期设定 `loop` 和 `loop-finish` 的宏函数，二者共用一个 epilogue 标签。
- 补丁：累积变量的初值和数值类型里去掉 complex 和 pathname（`#-kiln`）。

**closer-mop**：用 closer-mop 的库（Khazern、以后的 Eclector 等）在宿主里读入，读到的是宿主 CLOSER-MOP 包的符号，它们大多属于 SB-MOP。宏 `kiln.sys::closer-mop-aliases`（前端，`expand-closer-mop-aliases`）展开成一次 `kiln.sys::%alias-names` 调用：对 CLOSER-MOP 的每个外部符号，取 Clostrophilia 里可访问的同名符号（不要求导出：Clostrophilia 没有导出 `generic-function-methods` 等），运行期在后者有定义时，把函数、setf 函数和类给前者（`closer-mop.lisp`）。这种做法依赖宿主是 SBCL，等 kiln 自己读入源码（M5）时，改成定义真正的 CLOSER-MOP 包。

**trivial-with-current-source-form**：kiln 的条件还不记源码形式，`with-current-source-form` 展开成 `progn`。

**Common-macros**：vendor 在 `vendor/Common-macros`（宿主库）。Khazern 的源码里有一个单独写成符号的槽描述（上游的笔误，但合法），Common-macros 把它展开成 `(:name 'g)`，在运行期被当成对 `:name` 的调用。补丁改成 `(list :name 'g)`。

**测试**：
- GC 压力测试里 CLOS 模块的堆从 4 MiB 改成 8 MiB，因为加入 Khazern 后常驻的 metaobject 变多了。
- 各测试共用一个编译会话，所以测试里定义的宏和函数名字要避免冲突。

`tests/m4/clos-loop.lisp` 覆盖：
- 运行期 `macroexpand-1` 的 LOOP 展开，和宿主 Khazern 在编译期的展开逐一比较，只允许未 intern 符号的一致改名。涵盖算术、列表、向量和哈希表迭代，以及解构、累积、`named`、`thereis`、`loop-finish`；
- 语法错误时 Khazern 的条件，以及经 closer-mop 从 `parse-clause` 的方法里收集的预期关键字；
- 程序里 `defmacro` 定义的宏在运行期可以展开，`macroexpand` 会展开到底。

## 21. M4.6：pathname、文件流和时间

**runtime**：`kiln_rt_sys(op, a, b, c)`（`%primop :sys`）按 `op` 分派文件系统调用和时钟：open、close、lseek、unlink、rename、mkdir、rmdir、stat、getcwd、realpath、getenv、列目录、fstat、strerror、单调时钟、Unix 时间、进程 CPU 时间、sleep。
- 文件名以 UTF-8 八位组的 simple vector 传入。
- 返回名字的调用把结果存进作为最后一个参数传入的 simple vector，返回值是结果的长度；长度超过向量时什么也不存，Lisp 侧换一个更长的向量重试。
- 失败时返回负的 errno。
- 用一个入口而不是每个系统调用各导入一个函数，KIR 和 kiln-cg 都不必为新调用改动。

**pathname**（`lisp/target/clos/pathnames.lisp`）：pathname 是标准对象，它的类以内建类 `pathname`（或 `logical-pathname`）为超类，做法和 Regalia 的数组一样。
- 物理 pathname 按 SBCL 在 Unix 上的规则解析：
  - `~/` 是 `(:absolute :home)`，`..` 是 `:up`；
  - `*` 和 `**` 是 `:wild` 和 `:wild-inferiors`，名字里带 `*` 的串是通配模式；
  - 以点开头的文件名没有类型；
  - 有名字时版本是 `:newest`。
- `..` 作为文件名时，名字就是 `".."`（SBCL 把它解析成名字 `"."`、类型 `""`）。
- 逻辑 pathname：`logical-pathname-translations` 登记 host，`translate-logical-pathname` 按第一条匹配的转换翻译，翻译到物理 pathname 时转成小写。
- 通配符：`pathname-match-p`、`translate-pathname` 支持 `:wild`、`:wild-inferiors` 和名字里的 `*`，按顺序把匹配到的部分填进目标的通配位置。
- `equal` 和 `equalp` 按分量比较 pathname：kernel 的 `equal` 对标准实例调用 `*instance-equal*`。Salmagundi 的 `equal-hash` 本来就按分量散列 pathname。
- 文件系统函数：`probe-file`、`truename`、`file-write-date`、`delete-file`、`rename-file`、`ensure-directories-exist`、`directory`、`user-homedir-pathname`。`*default-pathname-defaults*` 在启动时设为当前目录。

**文件流**（`files.lisp`）：`kiln-file-stream` 是 Cyclosis 的 `posix-file-stream` 加一个 8 KiB 缓冲。
- Cyclosis 的转码器逐个八位组读写，没有缓冲的话每个八位组都是一次系统调用。
- 同一个缓冲先用于读还是写，取决于下一个操作：写之前把预读的部分用 lseek 退回，读之前先写出待写的部分。
- `finish-output`、`force-output`、`close`、`file-position`、`file-length` 之前都会先写出缓冲。
- `make-file-stream` 是 kiln client 的方法，代替 Cyclosis 只给 SBCL 写的那个：
  - `:supersede` 和 `:rename-and-delete` 直接截断文件，不写临时文件；
  - `:rename` 把原文件改名为 `原名.bak`；
  - `:new-version` 和 `:error` 一样，文件存在就报错。
- 标准流仍然没有缓冲，这样它们的输出和 runtime 直接写出的错误信息顺序不变。

**时间**（`time.lisp`）：`get-internal-real-time` 和 `get-internal-run-time` 以微秒计，`get-universal-time`、`sleep`。

**性能**：写这个测试时发现，往字符串流或文件写一个字符要 1 ms 左右，`format` 一次要 10 ms。泛函调用本身不慢，实测约 0.5 µs；慢在下面几处：
- Cyclosis 的字符串输出流每次只把字符串加长 32，写入变成平方级（补丁：按倍数增长）；
- 可调数组的增长走完整的 `make-array`，其中要经过 ctype 求 `upgraded-array-element-type`。现在一维、没有位移的可调向量直接换掉原生存储（`resize-vector`）。元素类型按类、按类型说明符缓存；
- 写每个字符都要调用 `check-character-stream`，里面有 `subtypep`，而 `subtypep` 每次都重新解析类型说明符。现在解析结果和 `subtypep` 的答案缓存在 `equal` 哈希表里，`deftype` 或定义类时清空（`invalidate-type-caches`）；
- Invistra 每次都重新解析控制串（补丁：按内容缓存解析结果）。

改完后，往文件写一个字符约 30 µs，`format` 一次 0.3–0.7 ms，`princ-to-string` 约 0.4 ms。这些仍然偏慢，留到 M4.6 最后的性能实验一起看。

`tests/m4/clos-files.lisp` 覆盖：
- 各种名字串的解析和 namestring、合并、`enough-namestring`、匹配和翻译、`:case :common`；
- pathname 作为 `equal` 哈希表的键，打印成 `#P`；
- 逻辑 pathname；
- 文本文件的写入、读回、`:append`、`:supersede`、`file-position`、`file-length`、UTF-8，以及 `file-exists` 和 `file-does-not-exist`；
- 二进制文件；
- 超过缓冲大小的文件；
- `probe-file`、`rename-file`、`directory`、`delete-file`。

## 22. M4.6：reader（Eclector）

Eclector vendor 在 `vendor/Eclector`，同时是宿主前端的 reader 和目标端的 reader。目标端编进 CLOS 模块的有 base、readtable、simple readtable 和 reader，不含 parse result 和 CST（M5 的前端才需要它们）。kiln 的接口在 `lisp/target/clos/reader.lisp`。

**接口**：Eclector 的源码读进宿主里已有的 Eclector 包，其中 `eclector.readtable` 遮蔽了 CL 的 readtable 函数和 `*readtable*`。所以：
- CL 的 `read`、`read-from-string`、`read-preserving-whitespace`、`read-delimited-list`，以及各个 readtable 函数，都转调 Eclector 的同名函数。readtable 参数位置不同，设计符号 NIL 表示标准 readtable。
- kiln 的 Eclector client 让 `cl:*readtable*` 这一状态读写和绑定 CL 的变量。
- `get-macro-character` 和 `get-dispatch-macro-character` 把 Eclector 存的符号换成函数。
- `with-standard-io-syntax` 绑定 Eclector 的标准 readtable。

**补丁**：
- simple readtable 的类以内建类 `cl:readtable` 为超类，这样 `readtablep` 和 `(typep x 'readtable)` 成立；
- `#P` 出错时的替代值 `#P"."` 改成 `(pathname ".")`，因为编译器还不支持 pathname 常量。

**alexandria**：Eclector 的源码用到 alexandria 的宏和函数，所以 alexandria-1 也编进 CLOS 模块。
- 宿主 alexandria 的宏不能直接当作编译期的展开函数：`once-only` 的展开结果里含有 SBCL 自己的反引号对象。
- 所以除 `conditions`、`features`、`io`、`numbers` 之外的文件都以 `:compile-time-too` 加载，宏在编译期由 HIR 求值器执行。排除的四个文件里有 `define-condition`、`*features*` 和 `defconstant`，宏用不到它们。

**前端的改动**：
- **受保护的宿主宏**：`quasiquote`/`unquote`/`unquote-splicing`、`loop`/`loop-finish`、`defstruct` 在编译期用宿主的展开函数（`host-macro`），编译期的 `(setf macro-function)` 不覆盖它们。否则 Eclector 的 `defmacro quasiquote` 会把编译期的反引号换成一个调用目标端函数的展开函数。
- **`#.`**：读入目标源码时，`#.` 在编译期环境里由 HIR 求值器求值（Eclector client `source-reader-client`），不再禁止。
- **编译期的 `*features*`**：编译期环境里也有这个变量，值是目标端的 features。
- **`(load-time-value form read-only-p)`**：转换前去掉 read-only-p，Common-boot 处理不了它。
- **Common-boot 补丁**：`load-time-value` 的子形式在一个只含全局环境的词法环境里转换（上游直接用全局环境，里面的 `lambda` 无法加入局部函数和变量）。

**kernel 的补充**：
- 标准常量：`lambda-list-keywords`、`call-arguments-limit`（1024，docs/06）、`lambda-parameters-limit`、`multiple-values-limit`（1022）、`char-code-limit`、浮点的极值和 epsilon、`pi`；
- `nstring-upcase`/`downcase`/`capitalize`，以及 `string-upcase` 等的 `:start`/`:end` 参数；
- `make-sequence` 和 `coerce` 支持位向量等其他向量类型。

`tests/m4/clos-reader.lisp` 覆盖：
- 整数、进制、bignum、比率、浮点、符号（转义、包前缀、关键字）、字符串、字符、列表、点对、quote、`#'`、向量、位向量、反引号、`#:`、`#+`/`#-`、注释、`#P`、`#2A`、`#1=`/`#1#`；
- `read-from-string` 的第二个值和 `:start`，从流读入；
- 读入错误；
- readtable：`readtable-case`（`:preserve`、`:invert`）、`set-macro-character`、`set-dispatch-macro-character`、`set-syntax-from-char`、`copy-readtable`、`with-standard-io-syntax`；
- 打印再读回；
- 运行期展开读入的反引号形式。

## 23. M4.6：运行期的 `defpackage`、`in-package` 和包局部昵称

编译的模块仍然从 symbol 表得到它们的包（§12），顶层的 `defpackage` 和 `in-package` 照旧只在宿主里执行。新增的部分用于运行期执行的代码，在 `package-system.lisp` 的末尾：

- **`%defpackage`**：按 CLHS 的顺序建立或更新包。
  - 顺序：昵称（`rename-package`）、shadow、shadowing import、use 列表、import、intern、export，最后是包局部昵称。
  - 包已存在时就地更新，不检查和原定义的差异。
  - 没有 `:use` 时 use 列表为空，和 SBCL 一样。
  - 忽略 `:documentation` 和 `:size`。
- **宏**：运行期的 `defpackage` 展开成对 `%defpackage` 的调用，`in-package` 展开成对 `*package*` 的赋值，都包在 `eval-when` 里。它们和 LOOP 一样只在加载期设定。
- **编译期**：不在顶层的 `defpackage`（比如在函数体里）由前端展开成同样的 `%defpackage` 调用（受保护的宿主宏，§22）。原来用的是 Common-macros 的展开，它需要 client 提供局部昵称的函数名，而 kiln 没有提供。
- **包局部昵称**：`find-package` 按名字查找时，先看当前包的局部昵称，所以读入 `a:foo` 也会用到它们。`parcl::package-local-nicknames` 返回 `(昵称 . 包)` 的列表。

`tests/m4/clos-defpackage.lisp` 覆盖：
- 函数里的 `defpackage`：`:use`、`:nicknames`、`:export`、`:shadow`、`:shadowing-import-from`、`:import-from`、`:intern`、`:local-nicknames`；
- 重复定义时更新包；
- 局部昵称对 `find-package` 和 reader 的作用；
- 函数里的 `in-package`、运行期展开这两个宏，以及包不存在时报 `package-error`。

## 24. M4.6：前端在目标端的性能实验

**做法**：把前端的一部分编进目标端，看 CLOS 密集的代码在 kiln 上有多慢。
- 前端的这一部分是 Concrete-Syntax-Tree 和 Eclector 的 parse-result、CST 读取器，编成第三个模块 `frontend`（`kiln:compile-frontend`）。它不进 CLOS 模块，以免拖慢所有测试的启动；`tests/*/fe-*.lisp` 和它一起运行。
- 基准是 `bench/fe-read.lisp`，由 `tools/bench-fe-read.sh` 运行：在 kiln（JIT）和 SBCL 上用同一份 Eclector 代码把 `lisp/target/kernel.lisp`（891 行，307 个形式）读成 CST。`BENCH=文件` 只在 kiln 上运行别的基准。
- profile 用 AOT 产物加 `perf record -e cpu-clock`。这台机器上 perf 不能记录调用栈；函数名是 gensym，可以按「函数对象存进哪个 symbol 的函数格」对回全局函数名。

**正确性**（`tests/m4/fe-read.lisp`）：用 `read` 和 CST 读取器分别读入测试文件自身，结果一致，源码位置正确。为此把 kiln 的 Eclector client 改成只在 CL 的读入函数里绑定、不全局设置：Eclector 的其他入口用 `(or *client* 默认 client)` 选 client，全局设置会让 CST 读取器用错 client，丢掉 parse result。

**结果**（每次读完整个文件，毫秒）：

| 阶段 | `read` | CST 读取 | `read-line` |
|---|---|---|---|
| 开始 | 9379 | 9964 | 1441 |
| 自动机二分查找不再调用 runtime 的 `floor` | 4228 | 4559 | 545 |
| 哈希函数和 `subtypep` 的快速路径 | 3902 | 4119 | 230 |
| runtime 的分配快速路径 | 2229 | 2360 | 177 |
| EQL 特化调用的有效方法缓存 | 664 | 807 | 178 |
| `svref`/`length` 内联，自动机转移内联 | 493 | 615 | 131 |
| SBCL（同一份 Eclector；`read` 是 SBCL 自己的） | 0.7 | 6.3 | 0.0 |

之后按下面的建议 1–3 继续做（§26、docs/07 §11、docs/08 §8）：

| 阶段 | `read` | CST 读取 | `read-line` |
|---|---|---|---|
| 展开调用的判别函数和快速方法函数 | 363 | 460 | 106 |
| 判别函数里的 EQL 缓存 | 161 | 253 | 108 |
| 内联分配，GC 扫描改为判断地址范围，256 MiB 堆 | 135 | 205 | 100 |
| inline 声明，`eql` 原语少调用 kernel | 120 | 187 | 68 |

这时 CST 读取约是 SBCL 的 30 倍。

CST 读取现在约是 SBCL 的 100 倍，开始时是 1600 倍。各项改动：
- **fixnum 除法**：KIR 加了 `sdiv`/`srem`。`floor`、`truncate`、`mod`、`rem` 对两个 fixnum 内联计算，原来每次都调用 runtime。自动机二分查找里的 `floor` 曾让每次按实例分派的调用花 0.5 µs，现在是 0.08 µs。
- **哈希**：`eq`、`eql`、`equal` 表的散列函数直接处理 fixnum、字符、符号、字符串和 cons，不再走 Salmagundi 那套逐步累加、为每次散列生成闭包的路径。`gethash` 从 5.6 µs 降到约 1 µs。
- **`subtypep`**：两个符号的情况缓存在第一个符号的 plist 上，带缓存代号（`*type-cache-epoch*`），定义类型或类时递增。从 6 µs 降到 0.15 µs，每读写一个字符都要调用它一次（`check-character-stream`）。
- **分配**：`kiln_rt_alloc` 先直接移动 MMTk 默认 bump 分配器的指针，空间不够时才走 MMTk 的分配函数。原来每次分配都要锁一次 GC 计数的互斥量、查 allocator、调用 `post_alloc`。
- **EQL 特化**：Clostrophilia 在参数的类不足以确定适用方法时（有 EQL 特化），每次调用都重新计算适用方法和有效方法。补丁按类和 EQL 对象缓存有效方法，方法改变时清空。Eclector 的 `state-value` 等泛函都属于这种情况。
- **原语**：`svref`、`(setf svref)`、`length` 对 simple vector 内联（`length` 也对字符串内联），其他情况调用 kernel 的函数；`third` 也成了原语。自动机转移和取 stamp 直接用 primop。

**剩下的开销**：Lisp 代码约 55%，其中分派约 25%（自动机转移、判别闭包、取 stamp），其余是 `member`、`assoc`、`equal`、`get` 等调用；GC 和分配约 37%。

**对 M5 的估计和建议**：照现在的速度，在 kiln 上跑交叉编译器会比在 SBCL 上慢大约两个数量级，对自举来说太慢。M5 之前或期间要做：
1. **编译出来的判别函数**：kiln 自己的编译器能在运行期编译之后，按 Clostrophilia 原本的设计生成判别函数，免去解释自动机，也免去每次调用为 `&rest` 参数列表分配内存。
2. **在生成代码里内联分配快速路径**（bump 指针放在 context 里），以及更大的或分代的堆。默认 64 MiB 的 SemiSpace 下，GC 占了不少时间；堆加到 256 MiB 能快约 20%。
3. **内联小函数**：kiln 现在忽略 `inline` 声明。`standard-instance-access`、`stamp`、`instancep`、`first` 之类的小函数，每次都是一次全局调用。
4. 以后每做一步都用这个基准，再加上把前端更多部分（Trucler、Clostrum、Common-boot）搬到目标端后的基准，来衡量进展。

## 25. 美化打印（Inravina）

Inravina vendor 在 `vendor/Inravina`，用的是 intrinsic 接口。CL 的美化打印函数和宏都是 Inravina 的，包括 `pprint-logical-block`、`pprint-newline`、`pprint-indent`、`pprint-tab`、`pprint-fill` 等，以及 `pprint-dispatch`、`set-pprint-dispatch`、`copy-pprint-dispatch` 和 `*print-pprint-dispatch*`。kiln 的接口在 `lisp/target/clos/pprint.lisp`：
- client 类 `inravina-intrinsic:kiln-client` 继承 Incless 的 client 和 `inravina:client`，替换掉 `incless::*client*`；Invistra 的 client 改成继承它。
- 接口里不是 CL symbol 的名字（标准 dispatch 表、`pretty-stream-p`）放在 `inravina-intrinsic` 包里，和上游的 intrinsic 接口一样。若放在 `inravina` 包里，接口定义的单参数 `pretty-stream-p` 会覆盖 Inravina 自己的同名泛函。
- `with-standard-io-syntax` 把 `*print-pprint-dispatch*` 绑定为标准表（`kiln.kernel::*standard-pprint-dispatch*`，由 `pprint.lisp` 设置）。

**加载顺序**：Incless、`printer.lisp`、`ngray.lisp`、Inravina、`pprint.lisp`，然后才是 Acclimation 和 Invistra。`logical-block.lisp` 在编译期也求值，因为 `pprint-logical-block` 宏的展开函数 `expand-logical-block` 在宏展开时调用。`ngray` 包补上了 `stream-element-type`、`stream-external-format` 和 `stream-line-length`，它们都是 CL 的泛函。

**补丁**（见 `vendor/README.md`）：
- Inravina 识别 Eclector 的反引号符号（`eclector.reader:quasiquote`、`unquote`、`unquote-splicing`），所以 `` `(a ,b ,@c) `` 打印成反引号形式。
- Invistra 撤掉 §18 里「不用 Inravina」的补丁，`format-tab` 的编译器宏也恢复。
- Common-boot：lambda list 所在函数体里声明中的名字也解析成引用，和 `let` 的处理一样。上游只在 `let` 里这样做。带 `&optional` 的 lambda list 被 Iconoclast 改写成 `let*` 时，未解析的名字会让它拆分声明的步骤出错。Inravina 的 `pprint-macro-char` 就是这种情况：有 `&optional` 参数，又有 `(declare (special *quasiquote*))`。
- Predicament：`error`、`parse-error`、`program-error`、`control-error`、`reader-error`、`warning`、`style-warning`、`storage-condition` 的报告不看条件内容，在 kiln 下去掉。原因是 Khazern 的条件同时继承 `parse-error` 和 `acclimation:condition`，类优先级里 `parse-error` 在前，它的「A parse error has occurred.」会盖住 Acclimation 的本地化报告。没有报告的条件不转义打印时，按 SBCL 的样子输出「Condition X was signalled.」（`format.lisp`）。

**kernel**：加了 `special-operator-p`，Inravina 用它判断能否取宏或函数的 lambda list；还加了 `function-lambda-expression`，总是返回 NIL。

**和 SBCL 的差异**：Inravina 允许一行恰好写到 `*print-right-margin*` 列，SBCL 则在到达这一列之前就换行。所以宽度正好等于右边距的行，两边的布局会不同。`*print-pretty*` 的默认值仍是 NIL，测试的输出因此不变。

`tests/m4/clos-pprint.lisp` 覆盖：
- 列表的填充换行，`defun`、`let`、`cond`、`quote`、`function`、反引号的标准布局；
- 用户写的 `pprint-logical-block`、`pprint-pop`、`pprint-exit-if-list-exhausted`、`pprint-newline`；
- 逻辑块里的 `*print-length*`、`*print-level*`；
- 在复制的表上 `set-pprint-dispatch`；
- FORMAT 的 `~<...~:>`、`~:<...~:>`、`~@<...~:@>`、`~_`、`~:_`、`~:@_`、`~:I`；
- `pprint`，以及 Khazern 的条件报告。

除右边距那一处外，输出和 SBCL 逐行一致。

## 26. 泛函分派：不再为参数分配列表

§24 的建议 1。kiln 还没有运行期编译器，所以判别函数和有效方法仍是闭包，没有按 Clostrophilia 原本的设计编译成代码。但调用路径不再分配内存，EQL 特化也有了缓存。

**方法函数**（`lisp/front.lisp` 的 `method-lambda-forms`）：
- 方法函数仍按 AMOP 的约定接收参数列表和后续方法。
- 方法体没有出现 `call-next-method`、`next-method-p` 时，不再生成这两个局部函数。它们是闭包，原来每次调用方法都要分配两个。
- lambda list 只有必需参数（至多 6 个）的方法另有一个**快速函数** `(lambda (next-methods a1 ... an) ...)`，直接接收参数本身。它的 `call-next-method` 不带参数时，若下一个方法也有快速函数就直接调用，否则才构造列表。快速函数保存在 `method` 的新槽 `%fast-function` 里（Clostrophilia 补丁），由 `kiln.sys:%method-fast-function` 读取。`make-method-lambda-wrapper` 返回 `(:kiln-method-lambdas 方法函数 快速函数)`，由 `ensure-method-wrapper` 拆开传给 `%defmethod`。

**判别函数**（Clostrophilia 补丁，`compute-discriminating-function.lisp`）：
- **展开调用**：泛函的 lambda list 只有必需参数、至多 6 个时（`spread-arity`），判别函数就是 `(lambda (a0 a1) ...)` 这样的闭包，调用历史里的有效方法函数也直接接收参数。有效方法是单个方法时：
  - 访问器方法（`maybe-replace-method` 换成的直接按位置读写槽的方法）直接读写槽，读到未绑定的槽时调用 `slot-unbound`；
  - 有快速函数的方法直接调用快速函数；
  - 其他有效方法（`:before`、`:around` 等组合）仍通过列表调用解释出来的闭包。
- **自动机**：状态改为展平的 simple vector（`start end target` 三个一组）。转移（`automaton-transition`）和取 stamp（`argument-stamp`）改成宏，在判别函数里展开。参数数目固定，每个特化参数的转移都按位置展开。
- **EQL 特化**：参数的类不能确定适用方法时（有 EQL 特化），原来每次调用都要走默认判别函数：重新调用 `compute-applicable-methods-using-classes`，再用 `equal` 查以列表为键的缓存。现在缓存条目是 `#(有效方法 spec0 spec1 ...)`，每个参数的 spec 是 NIL（不特化）、`(对象)`（等于某个 EQL 对象）或类的 stamp（参数不是任何 EQL 对象）。判别函数在自动机未命中时先逐条比较，比较时不分配内存。缓存跟着泛函走（`*eql-dispatch-caches*`），判别函数重算时保留，方法改变时清空；每个泛函至多 256 条。
- 在未命中路径里读泛函和方法的槽时，用 kiln 的 `%slot` 直接读，不调用读取器。读取器本身是泛函，可能也未命中，否则会无限递归。

**内建类的 stamp**（`early.lisp`）：非实例对象的类和 stamp 原来每次都要经过一串类型判断、`find-class`，再按名字在槽表里查 `%unique-number`。现在按类型下标缓存在 simple vector 里，switchover 之后才缓存，因为内建类不会重定义。

**顺带修正**：
- `coerce` 到 `simple-vector` 原来用 `(apply #'vector list)`，列表超过 `call-arguments-limit`（67）时报 program-error，现在改为逐个填入。展平的自动机状态触发了这个问题。
- 编译器给函数的标签加上名字：取函数体里第一个 block 的名字，没有 block 的局部函数（闭包）沿用外层函数的名字。例如 `kiln_f_G10660_AUTOMATON_2D_TRANSITION_clos_1466`，profile 里能看出是哪个函数。

**结果**：`bench/gf.lisp` 测单次调用的耗时，`bench/gf-misses.lisp` 统计读文件时哪些泛函未命中。

| 调用（µs） | 之前 | 之后 |
|---|---|---|
| 普通函数 | 0.003 | 0.003 |
| 1 个参数，按类分派 | 0.089 | 0.037 |
| 1 个参数，fixnum | 0.128 | 0.039 |
| 2 个参数 | 0.107 | 0.035 |
| 读取器 / 写入器 | 0.035 / 0.046 | 0.020 / 0.022 |
| `call-next-method` | 0.128 | 0.112 |
| `:around` 加 `:before` | 0.203 | 0.153 |
| `&key` | 0.268 | 0.209 |
| EQL 特化 | 1.904 | 0.043 |

读一遍 `kernel.lisp`，`state-value` 原来有 42856 次未命中，`call-with-state-value` 有 4615 次，现在都是 0。`bench/fe-read.lisp`：`read` 从 507 ms 降到 161 ms，CST 读取从 656 ms 降到 253 ms（SBCL 6.3 ms）。

**还剩下的**：
- 判别闭包本身约占 17%。主要开销是 kiln 生成的代码溢出到栈上，以及类型检查。
- 方法组合（`call-next-method`、`:before`、`:around`）的有效方法仍要构造参数列表，用到 `call-next-method` 的方法每次调用仍要分配两个局部函数闭包。
- 真正编译出来的判别函数要等运行期编译器（M5）。

## 27. 实例初始化和类名的 TYPEP（M5 自举的性能）

kiln 编译自己时（docs/11 §10.2），CLOS 的通用机制占了大部分时间。这一节是其中 CLOS 这边的两处修改。

**`shared-initialize` 的计划**（`support.lisp`，`shared-initialize-aux-1`）：
- 元类是 `standard-class` 的类，在切换到 MOP 之后不再调用 Clostrophilia 的 `shared-initialize-aux`。那里对每个槽调用 `slot-definition-initargs` 和 `(setf slot-value-using-class)`，两个都是泛函。
- 现在按类的槽列表做一个计划：每个槽四项，initargs、位置、名字、initfunction，存在 simple vector 里。初始化时按计划直接读写槽位置。
- 计划放在直接映射的缓存里，以槽列表为键，按它的 identity hash 取下标，冲突时覆盖。类变化时槽列表会被整个换掉，所以缓存不会过时。不用哈希表，因为切换到 MOP 时 Salmagundi 还没有加载。
- 和访问器方法一样，假定没有对 `standard-class` 适用的 `slot-value-using-class` 方法（AMOP 不允许可移植程序定义这样的方法）。
- `bench/gf.lisp`：`make-instance` 1.06 → 1.01 µs，`reinitialize-instance` 0.48 → 0.43 µs（一个槽的类）。

**类名的 `typep`**：
- 原来 `(typep x 'name)` 的类型如果不是标准类型名，就要经过 `typep` 的整个 `case` → `other-typep` → `typexpand-1`（用 `get` 查 deftype）→ `class-typep`（`find-class`，再在优先级列表里找）。Regalia 自己的 `vector`、`array` 类，以及 `typecase`、`check-type` 用到的类名，都走这条路径。
- 现在编译器把类型是常量符号、又不在 CL 和 KEYWORD 包里的 `typep`，改成调用 `kiln.kernel::%typep-cached`（`lower.lisp`，`lower-cached-typep`）。每个调用点带一个缓存：数据段里的一个静态 cons。
- kernel 里的 `%typep-cached` 就是 `typep`。CLOS 模块（`conditions.lisp`）把它换成带缓存的版本：类型名是类、又不是 deftype 时，结果只取决于对象的类。所以缓存的 car 存“上一个对象的 stamp 乘 2，结果为真再加 1”，是一个 fixnum，一次写入。
- 缓存里不存指针，GC 不需要扫描它。

**`slot-value`**：对象是元类为 `standard-class` 的标准实例时，按 `%slot-location` 的缓存（键是槽列表和槽名）直接读写槽位置。原来要在 `class-slots` 里用 `find` 按名字找槽定义（键函数 `slot-definition-name` 是泛函），再调用 `slot-value-using-class`。

**类名 `typep` 的全局缓存**：多态的调用点（AST walker 里的 `(typep node 'some-ast)`）总是不命中只有一项的调用点缓存。所以在它后面再加一个所有调用点共用的直接映射缓存，每项是 `(键 类型)`，下标由 stamp 和类型符号的 identity hash 异或得到。

**判别闭包的缓存表**：只按一个或两个参数分派的泛函，原来的判别闭包只缓存上一次的 stamp 和函数。AST walker 的泛函面对几十个类，几乎每次都不命中，然后在自动机里二分查找。现在每个判别闭包带一张直接映射表，以 stamp 的低位（两个 stamp 时是 `3·s1 xor s2`）为下标，大小是不小于调用历史长度的 2 的幂（4 到 256）。stamp 是连续分配的类编号，低位分布均匀。未命中的路径（查自动机、填表）放在单独的函数里：放在闭包里时，命中路径也要为它保存 callee-saved 寄存器、开一个大栈帧。

lambda list 里有 `&optional`、`&rest`、`&key` 的泛函（`stream-write-string`、`shared-initialize`、builder protocol 的 `relate`），原来的判别闭包没有任何缓存，每次调用都在自动机里查找。只按一个参数分派时，现在也用同样的缓存表（`make-single-dispatch-list-closure`），有效方法仍然接收参数列表。

kiln 编 CLOS 模块：148 秒 → 129 秒（加上 docs/11 §10.2 里其他改动之后是 88 秒）。
