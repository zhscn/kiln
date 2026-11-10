# kiln 的 IR：从 CST 直接到可分析的中间表示（草案）

状态：**IR 是唯一的前端**。原生结构对象、KIR `:switch` 和 CST → IR → KIR 路径都已接入；旧的 Iconoclast 前端、Common-boot 的 HIR 求值器以及它们的依赖（Common-boot、Iconoclast、s-expression-syntax、parser.packrat、builder 协议）已经删除。cross-client 的编译期求值用 IR 求值器（`lisp/ir/eval.lisp`，见下面“编译期求值”），image-client 用 Maclina。宏展开结果里原样传下来的用户子形式，在转换第一次遇到普通 cons 时才按顶层形式 CST 惰性建一次 `eq` 表取源码位置，不再调用 `cst:reconstruct`。调试信息上和旧前端的差别：没有 `let` 改写出的多余 lambda，只调用一次的局部函数内联后不再单独成帧。现在的流水线见 [front-end.md](front-end.md) 和 [lowering.md](lowering.md)。

## 当前实现

`lisp/ir/data.lisp` 定义节点、变量、函数、退出点和可增长向量。节点是统一的结构，保存整数 kind、源码位置、四个操作数、类型提示和遍历标记。调用和序列的子节点使用 simple-vector；引用保存定义对象，遍历不沿定义边走。

`ir-buffer` 用容量向量和有效长度表示可增长序列。分析变量时直接遍历有效区间，
固定遍历开始时的数据向量和长度；只修改元素属性，或向其他函数的缓冲区追加。
需要将构造结果作为独立序列保存时才调用 `ir-vector` 复制有效区间。

`environment.lisp` 的词法环境由结构组成，实现 Trucler 查询。`convert.lisp` 按特殊形式的名字选择手写转换器，直接处理 CST 子节点；宏展开结果作为普通形式转换，继承最近的源码位置。词法和特殊绑定、FLET/LABELS 的作用域、symbol macro、局部宏及声明都在这里解析。宏展开函数继续通过 client 运行，局部宏的展开函数由 client 的编译期求值器构造（`ir-local-macro-expander`）。

`analyze.lisp` 在一次树遍历中完成局部内联、传递捕获、cell 和退出令牌分析。只含必需参数、未作为值使用、且在定义函数中只有一个已知调用点的局部函数，可以移到调用点；参数数量必须匹配。已经分析的函数保留，避免移动后重复遍历函数体或重复登记 `load-time-value`。内联不复制节点，变量和退出点的 owner 随作用域调整。

`lower.lisp` 按 kind 降级，复用已有的 KIR 分配、多值和展开工具。自由变量向量确定闭包的 env 下标；互递归函数先分配全部函数对象，再填写 env。已知局部调用使用代码标签直接调用，self 函数对象仍传递闭包环境。可选及关键字参数的初始化按参数顺序进行，特殊参数的动态绑定覆盖后续初始化形式。

源码位置使用 62 位非负 fixnum：文件编号 12 位、起止偏移各 25 位。文件表属于编译会话，最多 4096 个文件，起止字符偏移分别小于 2^25；超出范围时报错，不截断位置。IR 不保存 CST 对象。

可重复的验证命令：

```sh
sbcl --noinform --non-interactive --load tools/env.lisp \
  --eval '(ql:quickload "kiln" :silent t)' --load tools/test-ir.lisp
tools/test.sh
tools/bootstrap.sh
```

模型检查覆盖 use-def、传递捕获、cell、退出令牌、内联后的 owner、树的独占子节点和语法错误；端到端验证比较程序行为，自举要求各阶段闭合。内存 KIR 交接仍是后续步骤。模型检查里还有一组 IR 求值器的用例，逐个和宿主的 `eval` 比较结果。

## 为什么要换

（2026-11 换掉之前）从 CST 到 KIR 要经过：

```
CST ─ s-expression-syntax（运行期的 packrat 语法引擎，逐个特殊形式解析）
    ─ builder 协议（architecture.builder-protocol，每个节点一串泛函调用）
    ─ Iconoclast AST（CLOS 实例）
    ─ simplify-ast（18 遍 Iconoclast 变换，每遍完整遍历、每遍一张“已访问”哈希表、改写时新建节点）
    ─ ast-facts（再遍历一次，把分析结果记在旁边的哈希表里）
    ─ 降级
```

2026-11 的 profile（kiln 编译自身，约 128 秒）里，这一段占一半以上：特殊形式的解析和 builder 约 35%，simplify-ast 约 15%，分析约 4%。原因是结构上的，不是哪个函数写得慢：

- **通用引擎做写死的事**：特殊形式只有 25 个左右，语法固定，却在运行期由语法引擎解析，每次解析还新建一张 `equal` 哈希表做 memo。
- **AST 是语法树，不是为分析设计的**：变量引用要到名字节点里找定义，没有 use-def，节点上没有放分析结果的地方，子节点要靠反射式的 slot 描述来枚举。每个分析都只能整棵树重走、用哈希表去重。上一轮修掉的平方级遍历（`assigned-in-p`）就是这个问题的症状。
- **改写式的多遍变换**：`let` 变 `labels`、`flet` 变 `labels`、拆分 `setq`、赋值转换、block 转换、闭包转换……每一遍都重建一部分树，而这些信息在构造时就已经知道了。
- **宏展开的结果再转回 CST**（`reconstruct`、`cst-from-expression`），只是为了带上源码位置。

## 范围

**替换**：s-expression-syntax、parser.packrat（在编译路径上）、builder 协议、Common-boot 的 `cst-to-ast`、Iconoclast 的 AST 和变换、`simplify-ast`、`ast-facts`，以及降级的输入端。

**保留**：

- Eclector 读入（只占约 4%）；
- `lisp/front.lisp` 在 CST 层做的顶层形式处理（`progn`、`eval-when`、顶层宏展开、`in-package`）；
- 编译期环境：cross-client 的 Clostrum 环境、image-client 的运行期环境；宏函数的 `&environment` 仍然是 Trucler 协议的对象；
- KIR 和其后的一切。降级的输出不变，只换输入。

编译期求值：cross-client 原来用 Common-boot 的 HIR 求值器（`cb:eval-cst`），它依赖 Common-boot 的 `cst-to-ast` 和 Iconoclast。现在由 IR 求值器取代（见“编译期求值”一节）。

## 数据结构基础（先做）

IR 会有几百万个节点，前端和降级的时间大部分花在分配节点、读写节点的字段、按节点种类分派上。所以先把 kiln 的这三样基础操作做快，它们同样惠及用户程序。

### 原生的结构对象

用标准实例表示 `defstruct` 时，实例是一个 `[header, rack]` 对象加一个 `[header, class, stamp, 有效槽列表, 槽...]` 的 rack。每次分配两个对象、至少 6 个字；每次读槽两次载入；访问函数用 `eq` 比较类，`:include` 的子类型实例走慢路径（完整的 `typep`）。

新增的对象 kind 是 `structure-instance`：

```
[header, layout, 槽 0, 槽 1, ...]
```

- **一个对象、一次载入**：槽 *i* 在第 *i* + 2 个字。header 的长度字段是槽数。
- **layout** 是结构类的一个不变的描述对象：所属的类、继承深度、`inherits` 向量（按深度存放各层祖先及自身的 layout）、槽数、stamp，以及供反射访问使用的有效槽列表。当前用不可变的 simple-vector 表示，顺序为 `#(class stamp slots depth inherits slot-count)`。
- **类型检查 O(1)**：结构是单继承，所以“x 是不是结构 S 的实例”就是：kind 是 `structure-instance`，且 `inherits(layout(x))[depth(S)]` 是 S 的 layout。这正是 SBCL 的做法。访问函数内联这一检查，`:include` 的子类型实例也走快路径。
- **构造函数**：一次内联分配（`emit-alloc` 的 bump pointer 快路径）加逐个写槽，不经过 `allocate-instance`。
- **CLOS 里的位置**：`class-of` 取 layout 的类，分派用的 stamp 取 layout 里的 stamp，`typep`、打印、`equalp`、`copy-structure`、对结构用 `slot-value`（按位置）都要认这个 kind。Rust 侧：GC 扫描全部槽（layout 是静态对象或堆对象，也要扫描）、打印、堆快照。
- **重定义**：CL 不定义不兼容地重新 `defstruct` 的后果。新定义得到新的 layout，旧实例保留旧 layout，不做实例更新。结构不能 `change-class`（CLHS 只对 `standard-object` 定义了它）。

这一项和 [roadmap.md](../roadmap.md) 性能计划里的“`defstruct` 直接分配”是同一件事，现在编译器自己的 `kblock`、`kfunc`、`context` 等结构也会立刻受益。

### 按种类分派

IR 的遍历按节点种类分派。三种做法：

| 做法 | 代价 |
|---|---|
| 泛函（现在的 `lower`、`walk-ast-node`） | 每次一次分派闭包，命中路径约十几条指令，加上 spread 的中转 |
| `etypecase` 结构类型 | 有了 O(1) 的结构类型检查后，是一串比较，平均要比较一半的种类 |
| 节点的 `kind` 槽（小整数）加 `case` | 一次载入加一次跳转表 |

**决定**：节点带一个 fixnum 的 `kind` 槽，遍历和降级用 `case` 分派；为此 KIR 加一个 `:switch` 语句（Cranelift 的 `br_table`），降级把“同一个变量和一串 fixnum 常量比较”的 `case`（嵌套的 `if` + `eql`）识别成 `:switch`。用户代码的 `case` 也因此变快。泛函仍可用于不在热路径上的处理（打印、调试）。

### 其他

- **可增长的向量**：调用的参数、`progn` 的子形式在构造时数量已知，用 simple-vector。构造中需要追加的（函数里的变量表、待处理队列），用“simple-vector 加计数”的结构，不用 Regalia 的可调整向量（等 [roadmap.md](../roadmap.md) 里原生的 fill-pointer 向量做了再换）。
- **分析结果放在节点上**：变量的“被赋值”“被闭包捕获”、退出点的“从闭包里退出”，都是节点上的位标志（一个 fixnum 槽），不放在旁边的哈希表里。
- **遍历不需要去重**：IR 是树（加上从引用指向定义的边，遍历时不沿这些边走），没有共享的子树，不需要“已访问”表。需要标记的遍历用节点上的标记槽加全局的遍历编号。
- **源码位置**：文件编号和起止偏移压成一个 fixnum，存在节点上；不保留 CST 对象。
- **名字和常量**：符号直接存；常量节点直接存对象。

## IR

### 三种实体

**变量**（`var`）：每个词法变量绑定一个对象。

| 字段 | 内容 |
|---|---|
| name | 符号（调试信息用） |
| owner | 定义它的函数（`fun`） |
| flags | 被赋值、被内层函数引用、需要 cell（两者都有）、`ignorable`、`dynamic-extent` |
| refs | 引用次数（以后做死代码消除、内联用） |
| type | 声明的类型（现在只是提示，留给类型推导） |
| lowering | 降级时的 KIR 变量，由降级填写 |

特殊变量不是 `var`：对特殊变量的读写、绑定在转换时就分出来，是单独的节点（`special-ref`、`special-set`、`bind`）。

**函数**（`fun`）：每个 lambda、`flet`/`labels` 的局部函数、顶层形式本身各一个。

| 字段 | 内容 |
|---|---|
| name | 调试和标签用的名字 |
| parent | 外层函数 |
| lambda-list | 必需参数、`&optional`（变量、初始化形式、supplied 变量）、`&rest`、`&key`（关键字、变量、初始化形式、supplied 变量）、`&allow-other-keys`；`&aux` 转成 `let` |
| body | 主体节点 |
| free | 闭包转换的结果：按 env 下标排列的自由变量向量 |
| exits | 需要令牌的退出点（被内层函数使用的 block 和 tagbody） |
| flags | 是闭包、会逃逸、只被调用一次、可以直接调用（只在调用位置出现，没被当作值） |
| policy | `optimize` 声明 |
| source | 源码位置 |

**退出点**（`exit`）：每个 `block` 一个，每个 `tagbody` 的每个标签一个（同一个 `tagbody` 的标签共享一个令牌）。字段：所属函数、“从内层函数退出”标志、降级用的令牌变量。

### 节点

所有节点有 `kind`、`source`。种类：

| 节点 | 内容 |
|---|---|
| `constant` | 对象 |
| `var-ref`、`var-set` | `var`；值 |
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

`macrolet`、`symbol-macrolet`、`locally`、`eval-when`（非顶层）、`flet` 和 `labels` 的作用域、`let*` 的顺序在转换时就消化掉，不出现在 IR 里。

## 转换：CST 到 IR

- **每个特殊形式一个转换函数**，按符号查表。语法检查手写，错误带源码位置，信息要不比 s-expression-syntax 的差。
- **词法环境**用 kiln 自己的结构表示（变量名到 `var`、函数名到 `fun`、局部宏、symbol macro、`block` 名到 `exit`、声明），同时实现 Trucler 的查询协议，宏函数的 `&environment` 参数拿到的就是它。
- **宏展开**照常通过 client：先查环境里的宏，再查 Common-macros 的宏；编译器宏（宿主库的那些）和 inline 展开也在这里。展开的结果是普通形式，转换时源码位置取最近的、有位置的外层形式，不再转回 CST。
- **构造时就完成的分析**：
  - 引用变量时，若当前函数不是变量的 owner，标记“被内层函数引用”；`setq` 标记“被赋值”；
  - `return-from`、`go` 若跨越函数，标记退出点“从内层函数退出”；
  - 局部函数被当作值（`#'f`）时标记“会逃逸”，记下调用次数。
- **构造完成后的一遍**（每个顶层形式一次，后序遍历）：计算每个函数的自由变量和 env 布局（闭包转换），决定哪些变量要 cell，内联只调用一次的局部函数（就地修改节点，不重建）。这一遍取代 simplify-ast 的 18 遍。

## 降级

降级按节点的 `kind` 分派，其余规则和现在的 [lowering.md](lowering.md) 相同：函数、闭包（env 从 `fun` 的 `free` 得到，不再要 `set-static-environment` 节点）、cell、退出点和令牌、多值、分支、`load-time-value`、常量、原语和 `%primop`、调用点上的改写。

有了 `fun` 的“可以直接调用”标志，降级可以把对已知局部函数的调用编成直接调用（不经过函数对象），这是旧前端做不到的（局部函数是持有函数对象的变量）。

## 编译期求值

cross-client 在编译期求值的形式（`eval-when` 的 `:compile-toplevel`、宏定义的编译期部分、`#.`、编译期环境里的 `eval`）和局部宏的展开函数，都由 `lisp/ir/eval.lisp` 执行。入口是 front.lisp 的泛函 `evaluate-at-compile-time` 和 convert.lisp 的 `ir-local-macro-expander`，按 client 分派：cross-client 走 IR 求值器，其他 client 走 `cb:eval-cst`（image-client 的方法是 Maclina）。

做法是闭包编译：形式先用同一个转换器和分析（`ir-convert`、`analyze-ir`，关闭 inline 展开和编译器宏）变成 IR，再按节点构造宿主闭包，每个节点一个，`kind` 只在构造时分派一次。运行时没有解释循环，也不再分派。

- **帧**：每次调用一个 simple-vector，0 号槽是函数的闭包环境，其余槽按 `fun` 的变量编号。分析标了 cell 的变量（被捕获且被赋值）在槽里放一个 cons，绑定时新建，所以循环里的 `let` 每次都是新的绑定。
- **闭包**：环境是一个 simple-vector，按 `free` 的顺序在创建函数对象时复制自由变量的值（cell 变量复制 cell）。`flet`/`labels` 先建好所有函数对象并绑定，再填环境，互相引用没有问题。函数对象就是宿主函数，宏展开函数之类的由宿主直接调用；只有必需参数（至多三个）的函数直接用宿主的参数表，其他的用 `&rest` 解析 `&optional`、`&key`（含 `:allow-other-keys` 和参数错误），默认值形式按顺序求值，特殊参数的绑定包住后面的部分，和降级的顺序相同。
- **全局定义**：都在编译期环境里，和 HIR 求值器一样在构造时取 Clostrum 的 cell：函数调用读 operator cell 的 car，特殊变量读写 variable cell 的 car（cdr 是未绑定标记）。`funcall`、`multiple-value-call` 收到符号时在编译期环境里查函数。`%primop` 在编译期执行时报错。
- **动态绑定**：浅绑定，新值写进 cell，`unwind-protect` 退出时恢复（`progv` 同样，值不够的符号变成未绑定）。HIR 求值器用的是自己的深绑定链表，编译期环境里的 `symbol-value`、`boundp` 看不到其中的绑定；浅绑定下它们看到的是当前值。
- **退出**：`catch`、`throw`、`unwind-protect` 直接用宿主的。`block` 和 `tagbody` 在构造时记下有没有不在尾位置的退出：`return-from` 在其 `block` 主体的尾位置时只是返回值；`go` 在其 `tagbody` 某个语句的尾位置时返回目标的标记（`tagbody` 私有的 cons，带目标语句的序号），由语句循环识别。尾位置经过 `if`、`progn` 的最后一个形式、`let`、动态绑定、`block`、`catch` 和 `unwind-protect` 的主体传递，进入函数、实参、`tagbody` 时清空。其他退出（嵌套函数里的、非尾位置的）需要每次进入时新建一个 catch 标签，存在退出点的令牌变量里，`return-from` 和 `go` 对它 `throw`。
- **`load-time-value`**：构造闭包时求值一次。
- **局部宏**：展开函数在只含外层局部宏、symbol macro 和特殊声明的环境里求值（`ir-macrolet-environment`），看不到词法变量、局部函数、block 和 tag。

和 HIR 求值器相比还少了一层：HIR 求值器要经过 Common-boot 的 `cst-to-ast`（s-expression-syntax 解析、builder 协议、Iconoclast AST）、AST-to-HIR 和 thunk 构造，每个函数还要编一个参数解析器。kiln0 自编译时，编译期求值（转换、构造和执行，不含它调用的宏展开）在 profile 里从约 15% 降到约 1%，一个阶段从 45 秒降到 36 秒（[performance.md](../research/performance.md)）。

## 为以后留的位置

- **类型推导**：节点留一个“推导出的类型”槽，变量有声明的类型。`typep` 展开、`aref` 按已知类型内联、浮点拆箱都建在这上面。
- **内联**：现在 inline 记录的是函数的源码形式，调用处重新转换。以后可以记录 IR，在 IR 上复制。
- **局部函数**：直接调用、lambda lifting、逃逸分析和 `dynamic-extent`，都只需要 `fun` 上已有的标志。
- **image-client 的编译期求值**：IR 求值器现在只用于 cross-client。image-client 换成它（全局定义改用 image 本身，动态绑定用宿主的 `progv`）以后，运行期 `compile`/`eval` 定义的宏函数也不必再走 Maclina 字节码。
- **交接**：降级直接通过 `kiln_rt_*` 调用在 Rust 侧构建 KIR，不再打印成文本（[specialization.md](specialization.md) 的“编译结果的缓存”也以 KIR 为单位）。

## 实施步骤

1. **原生结构对象**：新 kind、layout、O(1) 类型检查、内联构造，以及 CLOS、打印、GC、堆快照的支持。用现有的测试和自举验证，测量自编译时间（编译器自己的结构会受益）。
2. **KIR 的 `:switch`**：kiln-cg 支持 `br_table`，降级识别 `case`。
3. **IR 和转换**（已完成）：`lisp/ir/`，定义结构、转换函数、构造后的那一遍。
4. **新的降级**（已完成）：从 IR 生成 KIR，验证方式是全量测试和自举闭合（stage1 和 stage2 逐字节相同，kiln0 和 kiln1 相同）。
5. **切换并删除旧路径**（已完成）：IR 成为唯一的前端，Iconoclast 的降级、`simplify-ast` 和 Common-boot 的钩子都已删除。
6. **IR 求值器**（已完成，cross-client）：取代 HIR 求值器。image-client 不在顶层的 `macrolet` 由 Maclina 从定义形式求值。compiler 模块不再带 Common-boot、Iconoclast、s-expression-syntax、parser.packrat 和 builder 协议。
7. **在内存里交接 KIR**。

每一步都测量自编译时间，记进 [performance.md](../research/performance.md)。

## 待定

- **inline 函数的跨模块表示**：记源码形式（现在）还是 IR（需要序列化进模块）。
- **调试信息**：变量的源码名字和作用域由 `var` 提供，帧里变量的位置由降级记录，和现在 [debugging.md](debugging.md) 的格式兼容。
- **错误信息的质量**：手写的语法检查还没有覆盖 s-expression-syntax 原来给出的全部诊断。
