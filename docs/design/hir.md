# HIR：词法语义与求值

HIR 保存 Common Lisp 形式的词法绑定、函数、声明、多值与退出作用域。前端从 CST 构造 HIR，完成词法捕获准备后，同一份 HIR 可以直接交给 HIR 求值器，也可以构造成 [MIR](mir.md)。原生编译的类型推导、调用摘要、逃逸、内联及表示选择均在 MIR 上进行，随后输出 LIR，由 Rust 降级为 KIR。

## 职责边界

宏展开和词法作用域必须在构图前确定：同名变量可能属于不同绑定，默认参数形式只能看到先前参数，局部函数和退出点也各有定义范围。HIR 因此直接引用变量、函数和退出点的定义对象，而不让后续消费者重新按名字解析。

原生优化会合并函数、克隆主体或删除路径。若直接改写共享 HIR，已有求值器闭包的帧位置和捕获关系就可能失效。MIR 构建器保留 HIR 的词法边界，在独立的 CFG 和 SSA 上做这些变换；HIR 求值器将帧槽和退出分派记录在自己的消费状态中。多次原生编译同一份 HIR 不改变已有求值器闭包。

HIR 的树边是节点的子形式；变量、函数及退出点引用属于定义边。`hir-map-children` 遍历子形式，`hir-map-function` 访问函数主体和可选、关键字参数的默认式。需要跨定义遍历的消费者显式处理定义边，避免将局部函数引用误当成另一份函数定义。

## 数据结构

前端和 MIR 需要频繁构造和读取节点。HIR 的节点、变量、函数和退出点使用[原生结构对象](objects.md)，以单个对象紧排字段，避免标准实例的 rack 间接载入。节点以小整数 `kind` 分派；已知长度的实参和子形式使用 simple-vector，增量构造的变量表和队列使用带计数的可增长向量。源码文件编号及起止偏移压入 fixnum，节点同时保留宏展开来源和优化策略，构造完成后不必持有整棵 CST。

| 实体 | 主要内容 |
|---|---|
| `hir-var` | 名字、词法 owner、函数内绑定编号、引用次数、声明、策略及赋值／捕获／cell／ignorable／dynamic-extent 标志 |
| `hir-fun` | 名字、词法 parent、参数协议、主体、special 参数、自由变量、退出点、变量表、绑定编号计数、策略、源码和来源、局部函数绑定及加载期初始化表 |
| `hir-exit` | 名字、词法 owner、共享退出组、是否被跨函数引用、令牌变量及 tagbody 段编号 |
| `hir-node` | 种类、子形式或定义引用、源码、策略及展开来源 |

变量编号在所属函数内单调分配。绑定的 `type` 保存声明而不是推导结果；局部收窄声明保存在对应引用的作用域信息中。用户类型别名在当前环境中展开，同时保留原始声明供环境查询和诊断。MIR 据此生成检查，再由自己的类型事实决定是否可以省略。

特殊变量使用独立的读、写和动态绑定节点。参数声明为 special 时仍先用词法临时值保存实参，再按参数顺序建立动态绑定，保证后续默认式能看到先前参数。

### 节点

所有节点有 `kind`、`source`。种类：

| 节点 | 内容 |
|---|---|
| `constant` | 对象；交叉编译的槽存储数组常量保留定义它的符号 |
| `var-ref`、`var-set` | `var`；引用保留作用域内的类型声明，赋值保留值形式 |
| `special-ref`、`special-set` | 符号；值 |
| `global-function` | 函数名（`#'f`、`(setf f)`） |
| `function` | `fun`（lambda 或对局部函数的 `#'`） |
| `call` | 被调用者：全局函数名、局部 `fun`、或任意表达式；参数向量 |
| `primop` | `%primop` 的关键字和参数向量 |
| `if` | 测试、then、else |
| `progn` | 子节点向量 |
| `let` | `var` 的向量、初始化形式的向量、主体 |
| `bind` | 特殊变量的动态绑定：符号、值、主体 |
| `local-functions` | `flet`/`labels`：`fun` 的向量、主体（`flet` 的作用域在转换时就处理完，这里不区分） |
| `block`、`return-from` | `exit`；主体 / 值 |
| `tagbody`、`go` | 段的向量（每段一个 `exit` 和一串语句）/ `exit` |
| `catch`、`throw` | 标签、主体 / 标签、值 |
| `unwind-protect` | 保护的形式、cleanup |
| `multiple-value-call`、`multiple-value-prog1` | 函数、参数 / 第一个形式、其余 |
| `the` | 类型、形式 |
| `load-time-value` | 形式、read-only-p |
| `progv` | 符号、值、主体 |

`macrolet`、`symbol-macrolet`、`locally`、`eval-when`（非顶层）、`flet` 和 `labels` 的作用域、`let*` 的顺序在转换时就消化掉，不出现在 HIR 里。

函数的隐式同名 `block` 只包围执行主体。`&optional`、`&key` 和 `&aux` 的
初始化形式继承外层块环境，并可引用已经建立的参数或辅助绑定；`&aux` 按
顺序形成包围主体块的 `let*`／动态绑定。初始化中的同名 `return-from` 因而
指向外层块，主体中的同名返回指向函数自己的块。跨函数引用通过通常的退出
令牌捕获和动态展开传递多值，途经清理与 special 绑定按相应作用域恢复。

## 转换与词法准备

每个特殊形式有独立转换函数。转换器先验证列表形状、参数名和声明，再查询词法环境或生成节点。词法环境使用 kiln 的绑定对象，同时实现 Trucler 查询协议；宏的 `&environment` 看到同一份变量、函数、局部宏、symbol macro、退出点与声明信息。宏展开和编译器宏通过 client 执行，展开结果继续作为普通形式转换，源码位置继承最近的外层形式。

引用和赋值标记绑定的语义用途。`analyze-hir` 在完整函数树上重新计算自由变量和跨函数退出：内层函数使用外层绑定时，将它加入自由变量向量；既被捕获又可能赋值的绑定使用共享 cell。退出点被嵌套函数引用时，捕获其令牌变量。加载期形式另行收集为顶层初始化函数。局部函数的调用次数、函数值身份、类型范围和存储证明均由 MIR 重新分析。

HIR 求值器和 MIR 构建器共用这些词法准备结果，分别决定自己的执行位置和表示。`lisp/hir/consumer.lisp` 保存求值器的帧槽及退出分派；原生变量、函数标签和动态区域则属于 MIR 及 LIR 发射状态。

## 编译期求值

cross-client 和 image-client 在编译期求值的形式（`eval-when` 的 `:compile-toplevel`、宏定义的编译期部分、`#.`、编译期环境里的 `eval`）和局部宏的展开函数，都由 `lisp/hir/eval.lisp` 执行。入口是 front.lisp 的泛函 `evaluate-at-compile-time` 和 convert.lisp 的 `hir-local-macro-expander`，两个 client 共用转换、词法准备与闭包构造，按环境选择全局访问：cross-client 使用 Clostrum cell，image-client 访问运行中 image 的函数和变量。image 的 special 绑定通过 `progv` 进入运行时动态环境，包含未绑定值与非局部退出恢复。

做法是闭包编译：形式先用同一个转换器和词法准备（`hir-convert`、`analyze-hir`，关闭 inline 展开和编译器宏）变成 HIR，再按节点构造宿主闭包，每个节点一个，`kind` 只在构造时分派一次。运行时没有解释循环，也不再分派。

- **帧**：每次调用一个 simple-vector，0 号槽是函数的闭包环境，其余槽按 `fun` 的变量编号。分析标了 cell 的变量（被捕获且被赋值）在槽里放一个 cons，绑定时新建，所以循环里的 `let` 每次都是新的绑定。
- **闭包**：环境是一个 simple-vector，按 `free` 的顺序在创建函数对象时复制自由变量的值（cell 变量复制 cell）。`flet`/`labels` 先建好所有函数对象并绑定，再填环境，互相引用没有问题。函数对象就是宿主函数，宏展开函数之类的由宿主直接调用；只有必需参数（至多三个）的函数直接用宿主的参数表，其他的用 `&rest` 解析 `&optional`、`&key`（含 `:allow-other-keys` 和参数错误），默认值形式按顺序求值，特殊参数的绑定包住后面的部分，和 MIR 参数入口的顺序相同。
- **全局定义**：cross-client 在构造时取得编译期环境的 Clostrum cell：函数调用读 operator cell 的 car，特殊变量读写 variable cell 的 car（cdr 是未绑定标记）。`funcall`、`multiple-value-call` 收到符号时在编译期环境里查函数。`%primop` 在编译期执行时报错。
- **动态绑定**：浅绑定，新值写进 cell，`unwind-protect` 退出时恢复（`progv` 同样，值不够的符号变成未绑定）。编译期环境里的 `symbol-value`、`boundp` 因而看到当前绑定。
- **退出**：`catch`、`throw`、`unwind-protect` 直接用宿主的。`block` 和 `tagbody` 在构造时记下有没有不在尾位置的退出：`return-from` 在其 `block` 主体的尾位置时只是返回值；`go` 在其 `tagbody` 某个语句的尾位置时返回目标的标记（`tagbody` 私有的 cons，带目标语句的序号），由语句循环识别。尾位置经过 `if`、`progn` 的最后一个形式、`let`、动态绑定、`block`、`catch` 和 `unwind-protect` 的主体传递，进入函数、实参、`tagbody` 时清空。其他退出（嵌套函数里的、非尾位置的）需要每次进入时新建一个 catch 标签，存在退出点的令牌变量里，`return-from` 和 `go` 对它 `throw`。
- **`load-time-value`**：构造闭包时求值一次。
- **局部宏**：展开函数在只含外层局部宏、symbol macro 和特殊声明的环境里求值（`hir-macrolet-environment`），看不到词法变量、局部函数、block 和 tag。

## 语法诊断

转换器按特殊形式检查参数数量、有限 proper list、绑定名字、重复绑定、
lambda list 关键字顺序、参数规格、supplied-p 名字和 `eval-when` situations。
错误通过统一编译条件报告文件及 CST 范围；宏自身的语法错误由展开器报告。
新增语法入口时，先验证列表形状和名字，再查询环境或生成 HIR，避免将输入错误
暴露为实现内部的 `type-error`。

## 验证

`tools/test-hir.lisp` 验证词法捕获、参数与作用域、源码和声明保存，并将求值结果与宿主比较。`tools/test-hir-consumers.lisp` 与 `tools/test-hir-preparation.lisp` 验证重复原生编译不会破坏共享 HIR 和已有求值器闭包。MIR 的分析与优化使用各自的模型测试和端到端执行测试，见 [mir.md](mir.md)。
