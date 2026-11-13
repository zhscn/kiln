# 降级：HIR 到 KIR

本文描述现在的实现。cons/symbol 固定字段使用 schema 字段 ID，由 Rust 展开偏移；普通函数对象调用使用 `invoke`，apply 使用 `invoke-list`，由 Rust 安排参数展开、传递区和机器参数；数值原语、错误分派及一般 runtime 服务也使用由 Rust 展开的具名操作；其他布局与控制流发射仍由 Lisp 负责。目标设计里降级分成两段（[compiler.md](compiler.md)）：Lisp 的 MIR 完成表示选择后输出 LIR（[mir.md](mir.md)、[lir.md](lir.md)），kiln-cg 把 LIR 降级成 KIR。下面的闭包、退出点、多值、常量和分配规则届时分别归入 MIR 的表示选择（存储、闭包转换、退出令牌）和 Rust 的 LIR 降级（布局、条目、payload、静态数据）；“降级时的改写”改由 MIR 的类型驱动改写实现。

`lisp/hir/lower.lisp` 按 HIR 节点的整数 kind 分派（`hir-lower-mv`），返回保存结果的 KIR 操作数；模块、函数、调用、特殊变量、非局部退出、分配和常量的发射工具在 `lisp/lower.lisp`、`lisp/values.lisp` 和 `lisp/primitives.lisp`。输入是前端的输出（[front-end.md](front-end.md)、[hir.md](hir.md)），输出的 KIR 见 [codegen.md](codegen.md)，ABI 见 [abi.md](abi.md)。

## HIR 输入

顶层形式保存 `hir-fun`。变量的 lowering 字段记录所属函数中的 KIR 变量，跨函数引用按照 free 向量的下标读取 self 的环境。需要 cell 的变量在绑定时装箱，函数入口先保护所有实参，再分配参数的 cell。

降级用下面的多值、动态环境、常量和原语工具。退出点自己的 lowering 字段保存目标块及动态作用域；只有跨函数退出才分配令牌。`load-time-value` 的形式在空词法环境中转换为独立函数，在模块初始化时调用一次并存入 GC root cell。已知局部函数通过代码标签直接调用，同时传递承载闭包环境的 self。

降级期间的当前调用位置保持 HIR 的打包 fixnum 表示，子节点缺少位置时继承外层位置。
仅在发射调用的 `:loc` 记录时提取起止偏移，避免每经过一个节点都分配范围 cons。
模块初始化按固定大小顺序收集顶层形式，每个形式只在分块时访问一次，保持执行顺序。

## 函数、变量和闭包

- **函数**：每个 `hir-fun` 编译成一个 KIR 函数。没有自由变量的函数用静态函数对象（大多数顶层 `defun` 都是这种），闭包按捕获布局的长度分配，再填写 env。已证明身份留在词法绑定内的闭包可使用固定栈槽，其他闭包使用堆存储。一组局部函数（`flet`、`labels`）先全部分配，再逐个填写，所以互相递归的函数能捕获彼此。
- **变量**：每个变量对应它所属 KIR 函数里的一个 `obj` 变量；别的函数引用它时，从 self 的 env 里按 free 向量的下标读。
- **闭包变量用到时再读**：如果在函数入口读出全部捕获变量，它们跨调用存活，会被溢出到栈上。闭包环境不可变（被赋值的变量在 cell 里），所以每次引用时直接从函数对象读。
- **cell**：用一个 cons，car 存值。
- **函数的标签**：取函数体里第一个 block 的名字，没有 block 的局部函数沿用外层函数的名字，例如 `kiln_f_G10660_AUTOMATON_2D_TRANSITION_clos_1466`。profile 和 perf map 里能看出是哪个函数。函数的调试信息另见 [debugging.md](debugging.md)。

## `block` 和 `tagbody`

先扫描主体，看有没有来自嵌套函数（闭包）的 `return-from`/`go`。

- **没有**：只用本地跳转，跳转前弹出途经的条目，内联执行 cleanup。
- **有**：每次进入时分配一个新的**令牌**（一个 cons），建立一个退出点条目（kind 5），tag 就是令牌；令牌存进 block 的变量，闭包通过静态环境拿到它。闭包里的 `return-from`/`go` 调用 `kiln_rt_exit_to(ctx, token, value)`：runtime 在动态环境链上找 tag 为这个令牌的退出点条目，找不到就报错（退出点已失效），找到了就展开到它。`go` 传递的值是目标标签所在段的下标；落地后 tagbody 把条目重新链上（runtime 展开到目标时会摘掉它），再按下标分派。

**为什么不直接让闭包持有条目的栈地址**：那样堆对象就指向了栈帧内部，违反 C5，以后拷栈（fiber、续延）时无法修正。而且同一个栈地址会被后来的另一次进入重用，已经失效的闭包会错误地退出到新的那次进入里。令牌只在需要非局部退出的 block 上分配，代价是每次进入一个 cons。

`catch`、`throw`、`unwind-protect`、特殊变量绑定和 `progv` 都按 [abi.md](abi.md) 的动态环境条目降级。PROGV 的两个列表先按源码顺序求值，并检查 proper list 与符号类型；随后提交列表和区域，由 Rust 保存完整的旧绑定链后再链接条目并写入新值。保存期间的分配若发生退出，尚未改变任何动态值。正常或本地退出使用后端恢复操作，非局部展开由 runtime 恢复，Lisp 不遍历恢复链。

## apply

Lisp 先按源码顺序求值函数设计符、固定参数和最后的列表，检查函数设计符后，提交 `invoke-list`。固定参数以操作数向量传给 Rust；后端依次展开列表，检查 dotted 尾部与总参数容量，再安排调用。展开过程有目标参数上限，填充传递区后到调用之间没有 safepoint。类型错误与参数数量错误沿当前动态区域展开，调用位置沿用 apply 形式的位置。

## 入口参数

生产发射的 `receive-prefix` 提交位置参数的目标变量列表和实参数量变量。Rust 在首个可能复用传递区的操作之前保存整个前缀，缺失位置填 NIL；独立 LIR 的 `receive` 声明使用同一实现。Lisp 根据这些普通变量检查参数数量、绑定 supplied-p 并求值默认式，不读取参数寄存器或 `nargs`。

funcallable trampoline 使用 `forward-incoming` 转交未改写的入口实参。Rust 从目标函数对象取得入口并生成尾调用，传递区保持原有内容，整个转发路径没有 safepoint。

## 入口 rest 列表

生产发射以 `rest-list` 提交后缀起始位置与候选栈 cons 槽。Rust 保存所需的入口寄存器实参并保护未读取的传递区，倒序构造列表；整个列表能放进候选槽时使用栈存储，否则使用堆存储，完成后撤销传递区 roots。候选槽由生成方按逃逸证明选择并在入口登记，地址选择与分配循环在后端展开。

独立 LIR 通过函数的 `rest` 声明表达同一需求，Rust 同时建立候选栈槽及根条目，负责返回、尾调用和非局部展开时的清理。位置参数仍由 `receive` 保存，默认式、special 绑定和关键字处理保持源码求值顺序。

## Poll

Lisp 在入口和循环控制流中提交 `poll`，由 Rust 决定检查、runtime 签名和慢路径。参数尚未保存的寄存器入口使用重试模式；共享 helper 保存有效参数并清零无效寄存器，poll 后尾调用原函数。已保存实参的入口和循环使用普通模式，栈耗尽时调用当前 `%stack-exhausted` 定义。独立 LIR 通过 CFG 分析选择循环 poll，使用同一检查与慢路径实现。

## 固定角色入口

普通和 SETF 函数格的未定义占位对象、funcallable 转发及未设置目标时的错误入口由 Rust 生成。Lisp 按角色和 file/image 作用域声明所需入口；静态或动态占位对象提交其所属 symbol，funcallable 分配提交 rack。后端决定捕获字段、入口引用和初始调用目标。函数格的未定义检测使用 `undefined-function-p`，不比较代码地址。

## Runtime 服务

普通 runtime 服务提交 `runtime-op`，包含操作名、已求值对象、动态 handler 和源码位置。Rust 的闭合表定义调用名称、参数数量、签名和 safepoint 效果，补齐 imports，并为身份哈希保留缓存快路径。Lisp 发射不声明这些函数的 ABI，也不选择哪些服务需要 safepoint trampoline。生产路径的帧指针操作表达为后端 token，不在 Lisp 中构造地址。

GC、packet 编码和跨栈 Lisp 调用可能 safepoint 或覆盖传递区；独立 LIR 验证器使旧多值视图失效并传播异常边。其余服务遵守当前 runtime 的 NoSafepoint 合同，保留传递区内容。运行期编译的批量快照、代码安装和 literal 绑定期间不调用 Lisp。

## 数值与错误分派

整数和实数 runtime 原语提交具名 `numeric-op`。操作码、调用签名、context 参数和返回个数在 Rust 中选择，除法余数按 runtime 约定转换成多值结果；Lisp 不读取余数所在的传递区槽。普通数值快路径仍由 HIR 类型和区间事实选择，后端接口不重新进行语言类型推导。

可恢复错误提交 `signal-error`，包含语义错误码、已求值对象、动态 handler 和源码位置。Rust 查找当前 `%runtime-error` 定义，安排 Lisp 调用，并在定义不可用或返回时调用 fatal runtime 入口。该操作终结当前块；条件系统引发的非局部退出沿原有 handler 展开。

## 多值

`lower-mv` 返回主值的操作数和值的个数（整数或 raw 变量）。会把值传递出去的节点（`progn`、`if`、`let`、局部函数、`block`、`catch`、`unwind-protect`、绑定、函数调用等）在 `hir-lower-mv` 里传出全部值，`hir-lower` 只取主值。函数体用 `lower-mv`，所以函数返回它最后一个形式的全部值。`multiple-value-bind` 展开出的 `(multiple-value-call (lambda (&optional ... &rest g) (declare (ignore g)) ...) form)` 由 HIR 转换识别并归约为多值 `let` 节点（`hir-node-d` 为真），降级时直接按返回值个数用 `:select` 从主值和 `ctx.values` 取出绑定，不生成闭包，也不会让主体里的赋值或 `return-from`/`go` 变成跨函数的单元或非局部退出。`multiple-value-call` 在被调函数是 `#'list`（即 `multiple-value-list` 的展开）时直接把推入的值 `nreverse` 后返回，其余情况收集成列表再按 `apply` 调用。保留和传递多值的约定见 [abi.md](abi.md)。

生产发射通过 `values-list`、`push-values`、`save-values` 和 `restore-values` 表达列表收集、逆序累积和跨调用保存。Rust 与独立 LIR 共用遍历及分配实现，保护主值和传递区并检查用户提供列表的类型与多值上限。`unwind-values` 提交目标和主值、计数，`landed-values` 解码非局部落地值；多值 payload 的打包标志及 `continue-unwind` 的 runtime 调用序列均由 Rust 选择。

## 分支

谓词原语的结果是 `(:select c T NIL)`；放在 `if` 的测试位置时不先物化成 T/NIL 再和 NIL 比较，而是直接按 `c` 分支。`and`、`or`（展开成 `(let ((g x)) (if g g y))`）、`not`、嵌套的 `if`、常量在测试位置也都展开成分支（HIR 降级里是 `hir-lower-branch`；`or` 的临时变量只在只有这两处引用、没有赋值和捕获时才省掉）。

在产生值的位置，同一个词法变量与至少三个不同 fixnum 键比较的 `if` 链生成 `:switch`，包括 `case` 的单键和分组键分支。先检查输入是 fixnum，再去掉 tag；非 fixnum 直接走默认分支。重复键采用第一次出现的分支，多个键可以共用一个目标块，各分支保留全部返回值。Cranelift 按键的分布选择比较和跳转表。

## `load-time-value`

降级每个顶层形式之前，先找出其中所有的 `load-time-value`，在模块的 init 函数里求值，存进静态 root cell；引用处读这个 cell。所以它在包含它的顶层形式执行之前、在空词法环境里求值一次。

## 常量

- fixnum、字符、single-float、NIL、T 是立即数或静态对象。
- symbol 是静态 symbol（或运行期 image 里的符号，见 [eval-compile.md](eval-compile.md)）。
- cons 树、字符串、向量、bignum、ratio、double-float 作为静态数据输出，GC 不移动也不扫描。静态字符串常量按内容合并，cons 常量按 car 和 cdr 合并。编译进活 image 时，literal 表保留原对象身份。
- 降级时记录“绑定到常量且从不赋值”的临时变量，这样 `defun` 展开出的 `(funcall #'(setf fdefinition) f name)` 在函数名是编译期常量时直接写进对应的 cell。
- `defconstant` 的常量在编译期登记进编译期环境，引用处直接编译成值。

## 原语和 `%primop`

**原语**（`lisp/primitives.lisp`）是编译器直接展开的 CL 函数：fixnum 的 `+ - * 1+ 1- < > <= >= = /= zerop plusp minusp`、`logand`、`logior`、`logxor`，字符比较（`char= char/= char< char> char<= char>=`），`eq eql null not`，类型谓词，cons 操作（`cons car cdr first rest second third cadr cddr endp rplaca rplacd list list*`），`svref`、`(setf svref)`、`length`，`values`、`values-list`、`apply`、`funcall`、`nth`、`nthcdr`、`fdefinition`、`symbol-value`、`boundp` 及其 setf，以及 `kiln.sys` 里的测试用原语。

- CL 的函数不能被重定义（CLHS 11.1.2.1.2），所以内联是合法的。
- 数值原语内联 fixnum 的快路径；参数不是 fixnum 或者溢出时调用 kernel 的 `two-arg-+` 等函数。`floor`、`truncate`、`ceiling`、`round`、`mod`、`rem` 对两个 fixnum、`ash` 对 fixnum 也有内联的快路径（KIR 的 `sdiv`、`srem`、`shlv`、`sarv`），不调用 runtime。比较原语接受任意个参数，按相邻两两比较。
- `svref`、`length` 对 simple vector（`length` 也对字符串）内联，其他情况调用 kernel 的函数。
- `eql`：两个不同的一般对象，只在第一个是 bignum、ratio、double-float 时才调用 kernel 的 `eql-slow`，其他直接返回 NIL。
- 原语被当作函数对象使用时（`#'car`），读 symbol 的函数 cell：kernel 用 `(defun car (x) (car x))` 这种写法给每个原语一个真正的全局函数。
- 单参数的 `print` 是给没有流的早期测试用的原语（带流参数的 `print` 调用打印器的 `print`），直接调用 runtime 的打印函数（先打印对象再换行，不经过 `*standard-output*` 和 `print-object`）。编进运行中 image 的代码不用它。

**`%primop`**：`(kiln.sys:%primop :名字 参数...)` 是 kernel 代码访问底层操作的唯一入口（单一入口加关键字操作码，和 SICL 的做法一样）。它对前端来说是普通的函数调用，降级时按第一个参数（必须是 keyword 字面量）查 primop 表（`*primops*`），展开成内联代码，所以前端不需要改。例如分配和读写实例、`:identity-hash`、`:hash-mix`、`:fd-read`、`:sys`、`:jit`、浮点的位模式。

## 降级时的改写

在 `lower-global-call` 里：

- `append`：编译期合并相邻的 `list` 调用、去掉空列表和 `list` 后的尾随 `nil`（反引号展开大量产生这种形状），首参是 `list` 时改写成 `list*`，只剩两个参数时调用 `kiln.kernel::append-2`。
- `(eql x 常量)`：常量不是堆上的数时按 `eq` 降级。`case` 展开成这样的比较。
- 只有一个下标的 `aref` 和 `(setf aref)`：simple vector 就地读写，其他数组调用 kernel 的 `%aref-1`、`%set-aref-1`。
- `typep` 的类型是编译期常量时：原子类型直接换成对应的谓词调用（`*type-predicates*`）；fixnum 范围内的整数区间（`fixnum`、`bit`、`integer`、`mod`、`unsigned-byte`、`signed-byte`）、`t`、`nil`、`boolean`、`(eql c)`、`(member ...)`（至多 8 项）以及由它们组成的 `not`、`or`、`and` 直接在调用点展开成比较或分支（`emit-inline-typep`）。其他含不在 CL 和 KEYWORD 包里的常量符号的类型，改成调用 `kiln.kernel::%typep-cached`，每个调用点带一个缓存（数据段里的一个静态 cons，`lower-cached-typep`）：car 是全局 `typep` 表的项，cdr 是填入时的类型假设版本，版本变了就重新查（[clos.md](clos.md) 的“类名的 `typep`”）。
- `member` 和 `assoc` 不带关键字参数，或只带常量的 `:test #'eq` / `'eq` / `#'eql` / `'eql` 时，改成调用两个参数的 `%member-eq`、`%member-eql`、`%assoc-eq`、`%assoc-eql`。
- `slot-value` 和 `(setf (slot-value ...))` 的槽名是编译期常量的符号时，改成调用 `kiln.kernel::%slot-value-cached` / `%set-slot-value-cached`，每个调用点带一个位置缓存（数据段里的一个静态 cons：对象的 stamp 和槽的位置；位置在缓存里按 stamp 复核，见 [specialization.md](specialization.md) 的“调用点特化”）。
- 参数个数超过 `call-arguments-limit` 的 `list`、`list*`、`vector` 调用改写成分块的 `list*` 嵌套（`vector` 再加一次 `coerce`），`nconc`、`append` 改写成嵌套调用。其他函数超过时报出函数名。

## 分配

小对象的堆分配就地生成 bump pointer 快路径（`emit-alloc`），见 [gc.md](gc.md) 的“内联分配”。
词法 cons 和闭包在逃逸证明通过后也可使用固定栈槽，引用字段通过动态环境登记为精确根；
布局选择、调试器限制和保守回退见 [hir.md](hir.md) 的“保留身份的 cons 栈存储”。

## 还没有的优化

见 [roadmap.md](../roadmap.md) 的“性能”：更广的调用点变换、跨局部函数及对象包含关系的逃逸证明、关键字 rest 列表和局部函数组的栈存储，以及更多机器值表示。已证明身份的局部函数值使用直接入口，其他函数值仍采用间接调用。

常量类名及 initarg 名的 `make-instance` 调用通过带静态 GC root 的调用点描述符选择构造器，再传递求值后的值；细节见 [specialization.md](specialization.md)。泛函调用仍是普通的函数格调用（调用点缓存试过，比判别函数慢）。
