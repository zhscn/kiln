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
| M4.5 | Predicament（condition 系统），然后依次接入 Salmagundi（哈希表）、Parcl（包）、Regalia（数组）、Anatomicl（`defstruct`）、ctype |

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
