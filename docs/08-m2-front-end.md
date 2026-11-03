# 08 M2：Common-boot 前端和 AST 降级

**状态**：M2 第一步已完成（2026-11）。前端已经换成 Eclector + Common-boot + Iconoclast，M0 的脚手架编译器已删除，M0、M1 的测试全部改走新前端。特殊变量的动态绑定、多值、`&optional`/`&rest`/`&key` 还没有做，见 §7。

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
- `locally`、`macrolet`、`symbol-macrolet` 的主体暂时不按顶层形式处理（§7）。

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
| symbol | `[header, 名字指针, 名字长度, function, value]`，40 字节，仍然只有静态分配 |
| function | `[header(env 长度 << 8), 入口地址, env...]`，GC 扫描 env，跳过入口地址 |

- **函数 cell 就是 symbol 的 `function` 槽。** 调用全局函数：从 symbol 读出函数对象，再读入口地址，`call_indirect`。`(setf fdefinition)` 直接写这个槽，重定义因此立即生效。`(setf f)` 形式的函数名各有一个单独的静态 cell。
- **未定义函数**：每个 symbol 的 `function` 槽初始指向一个静态的“未定义函数”对象。它是一个 env 长度为 1 的函数对象，入口是 `kiln_undefined_function`，env 里放着这个 symbol，所以出错时能报告函数名。调用点不需要额外检查。
- **`value` 槽**：全局值，未绑定时是 `UNBOUND`（`0x13`，tag `011` 的立即数，GC 不处理）。keyword 的值是它自己。NIL 和 T 是 runtime 里的静态对象，它们的 `function`、`value` 槽不使用。
- **静态 root**：symbol 的 `function`、`value` 槽可能指向堆上的闭包和数据，所以编译器用 KIR 的 `(root "数据名" 字下标)` 把它们登记为 GC root。kiln-cg 把这些地址写进 `kiln_roots` 表（JIT 时直接注册），`kiln_module_info` 增加 `roots`、`nroots` 两个字段，大小变为 64 字节。GC 每次都扫描并更新它们。
- **常量**：fixnum、symbol 和由它们组成的 cons 树。cons 常量作为静态数据输出，GC 不移动也不扫描（它们只指向静态数据）。字符串、字符等还不支持。

## 4. 调用约定的补充：超过 3 个参数

[06 §4](06-m0-abi.md#4-调用约定) 预留的溢出区现在实现了，复用 context 的 `values` 区（偏移 48，64 个字）：

- 调用方先求出所有参数，然后把第 4 个及之后的参数写进 `ctx.values[0..]`，紧接着调用。
- 被调方在入口处、第一个 safepoint 之前（poll 和参数个数检查的出错路径之前）把它们读进自己的变量。
- 这段时间里没有 safepoint，所以这些字不需要作为 GC root。以后多值返回也用这块区域，两者的使用时段不重叠。

上限是 3 + 64 = 67 个参数。`apply` 和 `&rest` 实现时要重新考虑这个上限（CLHS 要求 `call-arguments-limit` 至少 50，所以够用）。

## 5. 降级

`lisp/lower.lisp` 的 `lower` 是按 AST 类分派的泛函，返回保存结果的 KIR 操作数。

- **函数**：每个 `local-function-ast` 编译成一个 KIR 函数。`labels` 为每个绑定的函数建立函数对象：没有自由变量的函数用静态函数对象（大多数顶层 `defun` 都是这种），闭包按 env 长度在堆上分配，再由 `set-static-environment` 填写 env。env 长度从对应的 `set-static-environment-ast` 得到。
- **变量**：每个变量定义对应当前 KIR 函数里的一个 `obj` 变量。闭包转换保证变量只在定义它的函数里被引用，降级时会检查这一点。
- **cell**：用一个 cons，car 存值。
- **`block`/`tagbody`**：先扫描主体，看有没有来自嵌套函数（闭包）的 `return-from`/`go`。
  - 没有：只用本地跳转，和 M0 一样，跳转前弹出途经的条目，内联执行 cleanup。
  - 有：建立一个退出点条目（动态环境条目 kind 5），把条目地址存进 block 的变量，闭包通过静态环境拿到它。闭包里的 `return-from`/`go` 调用 `kiln_rt_exit_to(ctx, entry, value)`：runtime 先确认这个条目还在动态环境链上（否则报错：退出点已失效），再按 [06 §6.3](06-m0-abi.md#63-展开算法rustkiln-rtsrcunwindrs) 展开到它。`go` 传递的值是目标标签所在段的下标；落地后 tagbody 把条目重新链上（runtime 展开到目标时会摘掉它），再按下标分派。
  - 条目地址是 8 字节对齐的栈地址，低位为 0，GC 把它当作 fixnum，不会处理。
- **`catch`/`throw`/`unwind-protect`**：沿用 M0 的做法（[06 §6](06-m0-abi.md#6-非局部退出c3-的决定)）。
- **特殊变量**：引用和 `setq` 直接读写 symbol 的 `value` 槽，读到 `UNBOUND` 时报错。动态绑定还没有实现。

### 5.1 原语

`lisp/primitives.lisp` 定义了编译器直接展开的函数：fixnum 的 `+ - * 1+ 1- < > <= >= = zerop plusp minusp`，`eq eql null not`，类型谓词，cons 操作（`cons car cdr first rest second cadr cddr endp rplaca rplacd list list*`），`funcall`、`fdefinition`、`(setf fdefinition)`、`symbol-value`、`(setf symbol-value)`、`boundp`、`print`，以及 `kiln.sys` 里的测试用原语。

- CL 的函数不能被重定义（CLHS 11.1.2.1.2），所以内联是合法的。
- 原语被当作函数对象使用时（`#'car`），按它的自然参数个数生成一个包装函数。
- 这是过渡做法。M3 交叉编译内核库以后，这些函数大多变成用 `%primop` 写的普通函数，这里只保留内联。

## 6. 测试

`tools/test.sh` 编译 `tests/*/*.lisp`，每个用例跑 JIT、GC 压力（1 MiB 堆）、AOT 三遍。`tests/m2/`：

- `closures.lisp`：计数器、共享 cell 的两个闭包、递归和互相递归的局部函数、跨 GC 存活的闭包列表、原语和全局函数作为值；
- `exits.lisp`：闭包里的非局部 `return-from`、`go`，非局部退出经过 `unwind-protect`，`catch` 和 `unwind-protect` 里的本地退出；
- `macros.lisp`：用户宏、编译期定义的辅助函数、`cond`/`dolist`/`dotimes`/`and`/`or`/`when`/`unless`/`case`/`push`、`defvar`/`defparameter`。

本地开发时用 `KILN_DEPS_DIR` 或 `deps` 符号链接指向依赖目录，见 [04 的 Lisp 依赖](04-bootstrap.md#lisp-依赖)一节。

## 7. 遗留事项

按计划的顺序：

1. **特殊变量的动态绑定**：按 C1 用 TLS 索引方案，展开时恢复绑定（动态环境再加一种条目）。`progv` 同时实现。
2. **多值**：`values`、`multiple-value-call`、`multiple-value-prog1`，`return-from`/`throw` 传递多值。返回约定已经预留了 `(v0, nvals)` 和 `ctx.values`。
3. **lambda list**：`&optional`、`&rest`、`&key`。`lexify-lambda-list` 之后的形式还要确认。
4. **顶层的 `locally`、`macrolet`、`symbol-macrolet`**：主体应按顶层形式处理。
5. `load-time-value`、字符串和字符常量。
6. 跨环境的符号：现在目标符号就是宿主符号（在 `kiln-user` 包里读入），包系统等 M3 用 Parcl 做。
7. 运行期的宏环境：`(setf macro-function)`、`proclaim` 目前是空操作。
