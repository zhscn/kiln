# 10 M4：CLOS 引导

**状态**：进行中（2026-11），M4.1 已完成（§5）。本文记录 M4 的决定和分步计划。依据是对 Clostrophilia（HEAD 9d0e86c，2026-08-29）的调研，结论记在 §2。

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
