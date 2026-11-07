# Clostrophilia 调研

**日期**：2026-11。依据 Clostrophilia HEAD 9d0e86c（2026-08-29）。kiln 怎样使用它见 [clos.md](../design/clos.md)；它在 SICL 里的位置见 [sicl-survey.md](sicl-survey.md) 的 4.2、4.3。

- 规模：16 个 ASDF 系统，约 5250 行，其中约 780 行是 `define-condition`。
- 唯一的库依赖是 Ecclesia。不用哈希表，不用 closer-mop。
- 需要 condition 系统（75 处 `error`，带自己的 condition 类型），加载时就会调用 `format` 和 `(setf documentation)`。75 处 `loop`。
- 不是完整的 CLOS：没有 `make-instance`、`class-of`、`find-class`、`ensure-*` 系列、EQL specializer 的登记、`change-class`、`update-instance-for-redefined-class`、`print-object`。`defclass`/`defgeneric`/`defmethod` 宏来自 Common-macros，通过 client 钩子接入。SICL 用 `Code/CLOS/` 里约 530 行补上这些。
- 实现方要提供的原语：`allocate-general-instance`、`standard-instance-access` 及其 `setf`（位置 −2 是 stamp，−1 是有效槽列表，0 起是槽）、`+unbound-slot-value+`、`stamp`、`class-of`、`find-class`、`small-integer=`/`small-integer<`、`set-funcallable-instance-function`、`make-method-instance`、方法组合模板的查找和登记、`subtypep-1`。
- 运行期 `compile` 的调用点：判别函数（`compute-discriminating-function.lisp:482`）、有效方法（`:319`、`:392`，以及 `compute-effective-method.lisp` 里 `call-method`、`make-method` 的展开函数）、访问器方法函数（`maybe-replace-method.lisp:35,56`）。
- 方法函数的形式是 `(lambda (参数列表 next-methods))`，有效方法接受一个参数列表，所以每次泛函调用都会构造 `&rest` 列表。
- 没有假设堆不移动：只用 `eq`、`assoc`、`member`，不取地址。
- **缺陷**：`default-discriminating-function` 不检查过时实例（注释说要检查，代码没有），stamp 过时的实例可能导致死循环。
- 每次分派未命中都把整个调用历史重新加进一个新的自动机，`add-path` 每加一条路径还要线性查找转移，调用历史长时总代价是 N³。
- 参数的类不足以确定适用方法时（有 EQL 特化），每次调用都重新计算适用方法和有效方法。
