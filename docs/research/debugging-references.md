# 调试设施的参考

**日期**：2026-11。按文档和已有了解整理。kiln 的做法见 [debugging.md](../design/debugging.md)。

## 定义记录

**LispWorks 的 dspec**（*LispWorks User Guide* 第 7 章）：

- **名字**：dspec 是定义的名字，不要求定义存在。规范形式是 `(类 主名字 . 限定)`，用 `equal` 比较。例：`car`、`(setf car)`、`(defclass standard-object)`、`(defmethod foo :around (integer t))`。
- **类即名字空间**：顶层类对应不同的全局名字空间，例如 `variable` 下分出 `defvar` 和 `defconstant`。每个类提供 `definedp`（是否已定义）和 `undefiner`（怎样撤销定义）。
- **别名**：`defparameter` 是 `defvar` 的别名，因为二者的效果无法区分。用户的定义宏展开成系统定义时，也要声明别名。
- **定义之间的关系**：
  - 子定义：`defstruct` 展开出的访问函数用 `def` 记为外层定义的子形式。查 `foo-bar` 时返回 `((defstruct foo) 文件)`。
  - 分布式定义：方法是泛函的“部分”，主名字是泛函的名字，限定部分用来区分不同的方法。
- **局部函数**：`(subfunction 子名字 父dspec)`，`flet`/`labels` 有简写。trace 和 advice 用它找局部函数。
- **位置**：文件路径、`:listener`、`:unknown`，以及子定义的 `:inside`。
- **记录时检查**：`record-definition` 在定义执行时记录位置，同时检查同名定义是否来自另一个位置，按 `*redefinition-action*` 警告或报错；还能保护包，例如禁止给 CL 包的外部符号下定义。
- **form parser**：编辑器只看源码不执行，靠 form parser 从顶层形式算出 dspec。默认规则是：car 以 `DEF` 开头的形式，取第二个元素作名字。

**Emacs Lisp**：

- `load-history` 按文件记录这个文件定义了什么，元素形如 `(defun . f)`、`(cl-defmethod 名字 限定 . 特化)`、`(provide . 特性)`。
- 不记录在文件中的位置。`find-function` 打开文件后，按定义种类用正则表达式重新搜索（`find-function-regexp-alist`）。宏展开出的定义还可以按展开结果去匹配。
- 在另一个定义里面定义的东西，用符号的 `definition-name` 属性指向外层定义的名字，这和 LispWorks 的子定义是一个意思。
- `unload-feature` 按 `load-history` 撤销定义，对应 LispWorks 的 `undefiner`。
- 教训：不记位置、靠搜索找回来，宏生成的定义就很难找。

## 宏展开的追踪和来源

- Racket 的展开器在展开过程中发出事件流，macro stepper（Culpepper）和 DrRacket 用它显示展开过程，并支持隐藏策略：只看用户自己的宏，不看库里的宏。syntax 对象带 `origin` 属性，记录它由哪些宏生成。
- Emacs 29 起，字节编译器读入的符号带位置（symbols with position），所以展开后的警告也能定位到源码。
- LispWorks 的源码级调试要求宏展开结果里的子形式和原来的参数 `eq`；宏复制了子形式时，用 `replacement-source-form` 补救。

## 单步和断点

**Clordane**（SICL 生态的 debugger 原型，文档附录“Implementing poll points”）：

- 每个线程有一个调试标志、一张按 PC 索引的断点表，以及一张约 1024 位的摘要位表（PC 取模）。
- 用高 debug 级别编译时，在每个源码形式的前后插入对一个局部小例程的廉价调用。例程先看调试标志，再看位表，最后才查断点表。
- 线程不在调试时，开销只是一次标志检查。
- 通用版本保留所有变量的栈槽、不做类型传播。
