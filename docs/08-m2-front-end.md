# 08 M2：Common-boot 前端和 AST 降级

**状态**：M2 进行中（2026-11）。前端已经换成 Eclector + Common-boot + Iconoclast，M0 的脚手架编译器已删除，M0、M1 的测试全部改走新前端。特殊变量的动态绑定（§5.2）、多值（§5.3）、`&optional`/`&rest`/`&key`（§5.4）已经实现，CL 的 25 个特殊操作符都能降级（§5.5）。剩下的见 §7。

## 1. 流水线

```
源文件
  │ Eclector（eclector.concrete-syntax-tree:read）
  ▼
CST ── 顶层形式处理（lisp/front.lisp，CLHS 3.2.3.1）
  │      progn / eval-when / 宏展开在这里做，编译期求值交给 HIR 求值器
  ▼
Common-boot cst-to-ast ──► Iconoclast AST
  │ simplify-ast（Common-boot AST-to-HIR 里的一串 Iconoclast 变换）
  ▼
简化后的 AST ── 降级（lisp/lower.lisp、lisp/primitives.lisp）
  ▼
KIR ── kiln-cg ──► Cranelift（JIT / 目标文件）
```

交接点按 [05 §7.1](05-sicl-survey.md#71-采纳) 的结论定在 `simplify-ast` 的输出。这时：

- 闭包已经转换：自由变量的值通过 `set-static-environment` 存进函数对象，函数体里用 `(static-environment)` 和 `read-static-environment` 读出；
- 被闭包捕获又被赋值的变量已经放进 cell（`make-cell`、`read-cell`、`write-cell`）；
- `let`/`let*` 变成一串 `let-temporary`，`flet` 和 lambda 都变成 `labels`，函数名字空间被消除（局部函数就是持有函数对象的变量）；
- 每个 `block`、`tagbody` 都带一个变量，表示它的退出点；`return-from`、`go` 引用这个变量；
- 只调用一次的局部函数已经内联，没有用到的 block 已经删除。

## 2. 顶层形式处理和编译期环境

Common-boot 本身的顶层处理不完整：`*compile-time-too*` 从来不会被设为真，`eval-when` 的 `:compile-toplevel` 不起作用。SICL 加载文件时是逐个形式 `eval-cst`，相当于 `load` 语义，不是 `compile-file` 语义。所以 kiln 在 CST 层自己做顶层处理（`lisp/front.lisp`）：

- `progn`：逐个子形式递归处理。
- `eval-when`：按 CLHS 3.2.3.1 的表格决定是编译、编译期求值，还是两者都做。
- 宏形式：先查环境里的宏（`trucler:describe-function`），再查 Common-macros 的宏（`cmd:macroexpand-1`），展开后用 `cst:reconstruct` 保留源码位置，再递归处理。
- 其他形式：在 compile-time-too 模式下先求值，然后 `cst-to-ast`、`simplify-ast`，加入顶层 AST 列表。
- `locally`、`macrolet`、`symbol-macrolet`：主体按顶层形式处理，局部宏加进 Trucler 环境；主体以声明开头时整体编译。

**编译期求值**用 Common-boot 的 HIR 求值器（`cb:eval-cst`），在一个 Clostrum 编译期环境里执行：

- `cb:create-environment` 已经把 Common-macros 的宏装进环境。
- kiln 再把宿主 CL 包里所有的函数导入环境，宏展开函数就可以直接调用它们。
- 和全局环境打交道的函数换成访问 Clostrum 环境的版本：`macro-function`、`(setf macro-function)`、`fdefinition`、`(setf fdefinition)`、`fboundp`、`symbol-value`、`(setf symbol-value)`、`boundp`、`proclaim`，以及接受符号作为函数标识的 `funcall`、`apply`。

所以 `defmacro` 定义的宏在同一个文件后面就能使用，`(eval-when (:compile-toplevel ...) (defun ...))` 定义的函数也能被宏展开函数调用。

**未定义函数的警告**推迟到文件末尾（CLHS 3.2.2.3）：Common-boot 遇到未知函数时发出的 `no-function-description` 先被屏蔽、记录下来；文件处理完后，去掉本文件 `defun` 过的函数（通过 `cmd:defun-compile-time-action` 记录）和原语，剩下的作为一个 style-warning 报告。

**宏定义在运行期没有效果**：`defmacro` 展开后同时会被编译进目标代码，其中的 `(setf macro-function)` 在运行期是空操作，`proclaim` 也一样。目标端还没有宏环境，到 M4 前后再处理。

## 3. 对象布局的扩展

在 [07 §1](07-m1-gc.md#1-值和对象的表示) 的基础上：

| kind | 布局 |
|---|---|
| symbol | `[header, 名字指针, 名字长度, function, value, TLS 下标]`，48 字节，仍然只有静态分配 |
| function | `[header(env 长度 << 8), 入口地址, env...]`，GC 扫描 env，跳过入口地址 |

- **函数 cell 就是 symbol 的 `function` 槽。** 调用全局函数：从 symbol 读出函数对象，再读入口地址，`call_indirect`。`(setf fdefinition)` 直接写这个槽，重定义因此立即生效。`(setf f)` 形式的函数名各有一个单独的静态 cell。
- **未定义函数**：每个 symbol 的 `function` 槽初始指向一个静态的“未定义函数”对象。它是一个 env 长度为 1 的函数对象，入口是 `kiln_undefined_function`，env 里放着这个 symbol，所以出错时能报告函数名。调用点不需要额外检查。
- **`value` 槽**：全局值，未绑定时是 `UNBOUND`（`0x13`，tag `011` 的立即数，GC 不处理）。keyword 的值是它自己。NIL 和 T 是 runtime 里的静态对象，它们的 `function`、`value` 槽不使用。
- **静态 root**：symbol 的 `function`、`value` 槽可能指向堆上的闭包和数据，所以编译器用 KIR 的 `(root "数据名" 字下标)` 把它们登记为 GC root。kiln-cg 把这些地址写进 `kiln_roots` 表（JIT 时直接注册），`kiln_module_info` 增加 `roots`、`nroots` 两个字段，大小变为 64 字节。GC 每次都扫描并更新它们。
- **常量**：fixnum、symbol 和由它们组成的 cons 树。cons 常量作为静态数据输出，GC 不移动也不扫描（它们只指向静态数据）。字符串、字符等还不支持。

## 4. 调用约定的补充：超过 3 个参数

[06 §4](06-m0-abi.md#4-调用约定) 预留的溢出区现在实现了，复用 context 的 `values` 区（偏移 56，64 个字）：

- 调用方先求出所有参数，然后把第 4 个及之后的参数写进 `ctx.values[0..]`，紧接着调用。
- 被调方在入口处、第一个 safepoint 之前（poll 和参数个数检查的出错路径之前）把它们读进自己的变量。
- 这段时间里没有 safepoint，所以这些字不需要作为 GC root。以后多值返回也用这块区域，两者的使用时段不重叠。

上限是 3 + 64 = 67 个参数（CLHS 要求 `call-arguments-limit` 至少 50）。`apply` 和 `multiple-value-call` 在运行期按列表长度分配寄存器和传递区，超过上限时报错。

`&rest` 的列表在入口处构造，这会分配内存，而传递区里还有没读出的参数。所以构造期间把 `ctx.values_live`（偏移 568）设为传递区里的参数个数，GC 把这些字当作 root，构造完再清零（§5.3）。

## 5. 降级

`lisp/lower.lisp` 的 `lower` 是按 AST 类分派的泛函，返回保存结果的 KIR 操作数。

- **函数**：每个 `local-function-ast` 编译成一个 KIR 函数。`labels` 为每个绑定的函数建立函数对象：没有自由变量的函数用静态函数对象（大多数顶层 `defun` 都是这种），闭包按 env 长度在堆上分配，再由 `set-static-environment` 填写 env。env 长度从对应的 `set-static-environment-ast` 得到。
- **变量**：每个变量定义对应当前 KIR 函数里的一个 `obj` 变量。闭包转换保证变量只在定义它的函数里被引用，降级时会检查这一点。
- **cell**：用一个 cons，car 存值。
- **`block`/`tagbody`**：先扫描主体，看有没有来自嵌套函数（闭包）的 `return-from`/`go`。
  - 没有：只用本地跳转，和 M0 一样，跳转前弹出途经的条目，内联执行 cleanup。
  - 有：每次进入时分配一个新的**令牌**（一个 cons），建立一个退出点条目（动态环境条目 kind 5），tag 就是令牌；令牌存进 block 的变量，闭包通过静态环境拿到它。闭包里的 `return-from`/`go` 调用 `kiln_rt_exit_to(ctx, token, value)`：runtime 在动态环境链上找 tag 为这个令牌的退出点条目，找不到就报错（退出点已失效），找到了就按 [06 §6.3](06-m0-abi.md#63-展开算法rustkiln-rtsrcunwindrs) 展开到它。`go` 传递的值是目标标签所在段的下标；落地后 tagbody 把条目重新链上（runtime 展开到目标时会摘掉它），再按下标分派。
  - **为什么不直接让闭包持有条目的栈地址**：那样堆对象就指向了栈帧内部，违反 C5，以后拷栈（fiber、续延）时无法修正。而且同一个栈地址会被后来的另一次进入重用，已经失效的闭包会错误地退出到新的那次进入里。令牌只在需要非局部退出的 block 上分配，代价是每次进入一个 cons。
- **`catch`/`throw`/`unwind-protect`**：沿用 M0 的做法（[06 §6](06-m0-abi.md#6-非局部退出c3-的决定)）。
- **特殊变量**：见 §5.2。

### 5.2 特殊变量（C1 的 TLS 下标方案）

`rust/kiln-rt/src/special.rs`。

- symbol 第一次被动态绑定时，runtime（`kiln_rt_tls_index`）给它分配一个 TLS 下标，写进 symbol 的第 6 个字。下标从 1 开始，0 表示还没有分配。
- 每个 context 有一张 TLS 表（`ctx.tls`，偏移 48，目前固定 4096 项）。表项是 `NO_TLS_VALUE`（`0x23`，立即数）表示这个 context 里没有绑定，回退到 symbol 的全局值。第 0 项永远是 `NO_TLS_VALUE`，所以读一个从没被绑定过的 symbol 时不需要先判断下标是否为 0。
- **读**：`v = tls[sym.index]`，是 `NO_TLS_VALUE` 就读 `sym.value`，最后检查 `UNBOUND`。**写**（`setq`、`(setf symbol-value)`）：TLS 表项有值就写表项，否则写全局值。
- **绑定**：在栈上建立一个绑定条目（动态环境条目 kind 6）：tag 是 symbol，`pend_target` 是下标，`pend_value` 是旧的表项（GC root）。然后写入新值。正常离开和本地退出（`return-from`、`go`）时从条目恢复旧值；展开经过绑定条目时，unwinder 恢复旧值。
- 绑定条目没有 handler，它所在区域里的调用使用外层区域的 handler。
- GC 扫描每个 context 的 TLS 表里已分配的项。
- 切换 context（以后的线程、fiber）只需换一张表，O(1)，符合 C1。

### 5.3 多值

- **返回约定**沿用 [06 §4](06-m0-abi.md#4-调用约定)：返回主值和值的个数，第二个及之后的值在 `ctx.values` 里。`(values)` 的主值是 NIL。
- **编译器**：`lower-mv` 返回主值的操作数和值的个数（整数或 raw 变量）。会把值传递出去的形式（`progn`、`if`、`let`、`labels`、`block`、`catch`、`unwind-protect`、绑定、函数调用等）实现 `lower-mv`，它们的 `lower` 只取主值。函数体用 `lower-mv`，所以函数返回它最后一个形式的全部值。
- `ctx.values` 会被下一次调用覆盖。需要跨过可能调用函数的代码保留多值时（cleanup、`multiple-value-prog1` 的其余形式、`return-from` 途经的 cleanup、为 `multiple-value-call` 收集参数），只有一个值就直接保存它，否则先把值转成列表，事后再展开回 `ctx.values`。
- 转成列表要分配，而值还在 `ctx.values` 里：转换期间 `ctx.values_live` 是值的个数减一，GC 把这些字当作 root。平时它是 0，GC 不扫描 `ctx.values`（那里多半是失效的旧值）。
- `multiple-value-call` 把所有值收集成一个列表，再按 `apply` 的方式调用。
- **经过展开传递多值**（`throw`、闭包里的 `return-from`）：runtime 的待传值只有一个字。值的个数不是 1 时，先像跨 cleanup 时那样把值转成列表，再传这个列表，并带一个“已打包”标志。标志放在目标条目地址的第 0 位（条目 8 字节对齐）：到达时在 payload 寄存器 exn0 里，cleanup 拦截期间在 `pend_target` 里。handler 分派时先屏蔽这一位再比较条目，落地代码看到标志就把列表展开回多值。`go` 传递的段下标不打包。

### 5.4 lambda list

`lexify-lambda-list` 之后，每个 `&optional` 和 `&key` 参数都有 supplied-p 变量，默认值在函数体里根据 supplied-p 计算，所以函数入口只需要：

1. 读出位置参数：必需参数和 `&optional` 参数，按 `nargs` 选择实参或 NIL，同时设置 supplied-p。这一步在第一个 safepoint 之前，因为后面的参数在传递区里。
2. 检查参数个数。
3. 有 `&rest` 或 `&key` 时构造剩余参数的列表（§4）。
4. `&key`：检查列表长度是偶数；没有 `&allow-other-keys` 时，除非参数里有 `:allow-other-keys` 且值为真，否则遇到未知关键字报错；每个关键字参数取第一次出现的值。

原语作为函数对象使用时，`list` 和 `values` 这类可变参数原语的包装函数也用同样的方式构造参数列表。

### 5.5 `progv`、`load-time-value` 和其他特殊操作符

- **`progv`**：绑定的个数运行期才知道，没法每个绑定占一个栈上条目。所以只建立一个 progv 条目（动态环境条目 kind 7），tag 是一个 `(symbol . 旧 TLS 值)` 的列表。先把所有旧值存进列表，再链接条目，最后写入新值，所以展开时看到的列表总是完整的。值不够时，多出来的 symbol 变为未绑定。离开时（正常、本地退出、unwinder）按列表恢复。
- **`load-time-value`**：降级每个顶层形式之前，先找出其中所有的 `load-time-value`，在模块的 init 函数里求值，存进静态 root cell；引用处读这个 cell。所以它在包含它的顶层形式执行之前、在空词法环境里求值一次。
- **`symbol-macrolet`**：简化之后展开已经代入，只剩主体。`macrolet` 被 `macrolet-to-locally` 变成 `locally`。`flet`、`let`、`let*`、`function` 都被简化掉了。
- **对 symbol macro 做 `setq`**：Common-boot 没有对应的方法（`finalize-variable-name-ast-from-description` 不接受 symbol macro 的描述），会展开成 `setq` 的 `setf` 也一样。CLHS 3.1.2.1.1 要求这时按对展开式的 `setf` 处理。kiln 在自己的 client 上给 `cb::convert` 加了一个 `:around` 方法：转换之前把这样的 `setq` 改写成 `(setf 展开式 值)`，不需要修改 Common-boot。`with-slots`、`with-accessors` 依赖这一点。

`tests/m2/special-forms.lisp` 在非顶层位置覆盖了全部 25 个特殊操作符。

### 5.1 原语

`lisp/primitives.lisp` 定义了编译器直接展开的函数（另有 `values`、`values-list`、`apply`、`nth`、`nthcdr`）：fixnum 的 `+ - * 1+ 1- < > <= >= = zerop plusp minusp`，`eq eql null not`，类型谓词，cons 操作（`cons car cdr first rest second cadr cddr endp rplaca rplacd list list*`），`funcall`、`fdefinition`、`(setf fdefinition)`、`symbol-value`、`(setf symbol-value)`、`boundp`、`print`，以及 `kiln.sys` 里的测试用原语。

- CL 的函数不能被重定义（CLHS 11.1.2.1.2），所以内联是合法的。
- 原语被当作函数对象使用时（`#'car`），读 symbol 的函数 cell；M3 起由 kernel 为每个原语定义真正的函数（[09 §4](09-m3-kernel.md#4-primop)），M2 时生成的包装函数已删除。
- 这是过渡做法。M3 交叉编译内核库以后，这些函数大多变成用 `%primop` 写的普通函数，这里只保留内联。

## 6. 测试

`tools/test.sh` 编译 `tests/*/*.lisp`，每个用例跑 JIT、GC 压力（1 MiB 堆）、AOT 三遍。`tests/m2/`：

- `closures.lisp`：计数器、共享 cell 的两个闭包、递归和互相递归的局部函数、跨 GC 存活的闭包列表、原语和全局函数作为值；
- `exits.lisp`：闭包里的非局部 `return-from`、`go`，非局部退出经过 `unwind-protect`，`catch` 和 `unwind-protect` 里的本地退出；
- `macros.lisp`：用户宏、编译期定义的辅助函数、`cond`/`dolist`/`dotimes`/`and`/`or`/`when`/`unless`/`case`/`push`、`defvar`/`defparameter`；
- `values.lisp`：多值经过各种形式和 cleanup、`multiple-value-call`/`-prog1`/`-bind`、`nth-value`、`values-list`、`apply`、GC 期间的多值列表；
- `lambda-lists.lisp`：`&optional`（默认值引用前面的参数和特殊变量）、`&rest`（含传递区里的参数、GC）、`&key`（重复关键字、改名、`:allow-other-keys`）、闭包的 lambda list；
- `special-forms.lisp`：全部特殊操作符，含 `progv`（值不够时变为未绑定、`throw` 穿过时恢复）、`load-time-value` 只求值一次；
- `specials.lisp`：嵌套绑定、绑定内的 `setq`、经过 `throw`/非局部和本地 `return-from`/`go` 退出时恢复绑定、闭包不捕获动态绑定、`boundp`、跨栈展开时恢复绑定、cleanup 里的绑定。

本地开发时用 `KILN_DEPS_DIR` 或 `deps` 符号链接指向依赖目录，见 [04 的 Lisp 依赖](04-bootstrap.md#lisp-依赖)一节。

## 7. 遗留事项

按计划的顺序：

1. ~~特殊变量的动态绑定~~（已完成，§5.2）。TLS 表的大小是固定的，以后需要能扩容。
2. ~~多值~~（已完成，§5.3），包括经过 `throw` 和非局部 `return-from`。
3. ~~lambda list~~（已完成，§5.4）。`&aux` 还没有确认 `lexify-lambda-list` 之后的形式。
4. ~~顶层的 `locally`、`macrolet`、`symbol-macrolet`~~（已完成）：主体按顶层形式处理，局部宏的展开函数用 HIR 求值器求值后加进 Trucler 环境（`process-toplevel-body`）。主体以声明开头时仍然整体编译。
5. ~~`load-time-value`~~（已完成，§5.5）。字符串和字符常量要等 M3 定下它们的对象表示。
8. ~~对 symbol macro 的 `setq`~~（已解决，§5.5）。
9. `progv`：已完成（§5.5）。
6. 跨环境的符号：现在目标符号就是宿主符号（在 `kiln-user` 包里读入），包系统等 M3 用 Parcl 做。
7. 运行期的宏环境：`(setf macro-function)`、`proclaim` 目前是空操作。
