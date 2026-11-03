# 06 M0：ABI 与 KIR

**状态**：M0 已完成（2026-11）。本文记录 M0 定下来的 ABI 决定，以及 SBCL 侧编译器和 Rust 侧代码生成器之间的交换格式 KIR。这些决定在 M1 之后都会继续沿用；M0 的前端只是脚手架，到 M2 会换成基于 Common-boot 的前端。

## 1. 组成

```
SBCL: lisp/m0-compiler.lisp   M0 子集 → KIR（s-expression 文本）
        ↓ .kir
Rust: kiln-cg                 KIR → Cranelift
        ├─ jit：cranelift-jit，在进程内运行（链接 kiln-rt）
        └─ obj：cranelift-object 产出 .o
                ↓
              cc x.o libkiln_launcher.a → 可执行文件
Rust: kiln-rt                 runtime：context、unwinder、运行时函数
Rust: kiln-launcher           staticlib，提供 C main，链接 kiln-rt
```

运行测试：`tools/m0-test.sh`。它用 SBCL 把 `tests/m0/*.lisp` 编译成 KIR，再分别走 JIT 和 AOT 两条路径运行，并和 `.expected` 比对。

## 2. 决定：交换格式用 KIR，不用 CLIF 文本

[04-bootstrap.md](04-bootstrap.md) 原计划早期用 CLIF 文本做交换格式。M0 改成了 KIR，原因：

- **cranelift-frontend 只能通过 API 使用。** 它负责从可变变量构建 SSA（`Variable`、`def_var`/`use_var`），以及在 safepoint 处为 GC 引用插入溢出和重载（user stack maps，C5）。直接写 CLIF 文本就绕过了它，SBCL 侧得自己构建 SSA、自己做溢出。
- **对象布局的知识留在 Lisp 侧。** KIR 是接近 Cranelift 的低级 IR：tag、偏移、kind 编号都由 Lisp 编译器决定。kiln-cg 只负责调用约定、`try_call` 和异常表、栈图声明、trampoline。以后编译器自举进 kiln 时，kiln-cg 作为 runtime 里的代码生成库继续使用，不用改。
- 调试时仍然可以看 CLIF：`kiln-cg jit FILE.kir --dump-clif`。

## 3. 值的表示（M0 子集）

| 低位 | 含义 |
|---|---|
| `...0` | fixnum，63 位，值 = word >> 1 |
| `101` | 一般对象指针，地址 = word − 5 |

一般对象的第一个字是 header，M0 里只存 kind：`1` 是 symbol（布局 `[header, 名字指针, 名字长度]`），`2` 是 function（布局 `[header, 入口地址]`）。NIL 和 T 是 runtime 里静态分配的 symbol（`kiln_nil`、`kiln_t`）。

这只是 M0 的最小集合。M1 接入 MMTk 时要定完整的对象表示，倾向 [05 §7.1](05-sicl-survey.md#71-采纳) 里的 rack 间接方案。cons 的 tag 等到那时再定。

## 4. 调用约定

- **所有 Lisp 函数使用 Cranelift 的 `tail` 调用约定。** 它支持尾调用。更关键的是，`try_call` 调用 `tail` 函数时，异常边上所有寄存器都视为被破坏，所以 unwinder 恢复时不需要还原 callee-saved 寄存器。
- **统一签名**：`(ctx, self, nargs, a0, a1, a2, a3) -> (v0, nvals)`，全部是 i64。
  - `ctx`：context 指针（C1），作为显式的第一个参数。没有用 Cranelift 的 pinned register，这样更可移植，调用 Rust 时也不用特殊处理。
  - `self`：被调用的函数对象，以后闭包从这里取环境。
  - `nargs`：实际参数个数（裸整数）。被调方在入口检查。
  - `a0`–`a3`：前 4 个参数，多余的寄存器传 0。超过 4 个参数时放进 context 里的溢出区，**M1 再实现**，M0 的前端会直接报错。
  - 返回 `v0` 和 `nvals`：主值和值的个数。第二个及之后的值放在 `ctx.values` 里，**多值在 M0 里还没用到**。
- **调用全局函数**：从函数 cell 读出函数对象，从函数对象读出入口地址，再 `call_indirect`。重定义时只改 cell。call-site manager 留到以后（[05 §3.5](05-sicl-survey.md#35-call-site-manager只有设计代码是空壳)）。
- **帧指针**：`preserve_frame_pointers = true`。unwinder 依靠 FP 链遍历栈帧，以后 GC 扫描栈也要用。
- **从 runtime 进入 Lisp**：kiln-cg 在每个模块里生成 System V 调用约定的 `kiln_enter(ctx, fobj, entry)`，在里面转成 `tail` 约定调用。

## 5. Context 布局（C1）

| 偏移 | 字段 | 说明 |
|---|---|---|
| 0 | `poll_flag` | 非零时 poll 点进入慢路径（C4） |
| 8 | `dynenv` | 最内层的动态环境条目 |
| 16 | `values[64]` | 第二个及之后的返回值（M0 未使用） |

两侧的定义：`rust/kiln-rt/src/context.rs` 和 `lisp/abi.lisp`，修改时必须同步。

## 6. 非局部退出（C3 的决定）

**决定：用 Cranelift 的 `try_call` 加上 kiln 自己的 unwinder。** 正常路径零开销。异常表和 GC 栈图都按“调用点返回地址”组织，属于同一类元数据，相当于 SICL 的调用点描述符（[05 §3.5](05-sicl-survey.md#35-call-site-manager只有设计代码是空壳)）。

### 6.1 动态环境条目

`catch` 和 `unwind-protect` 在建立它们的帧里，用栈槽分配一个 48 字节的条目，链接到 `ctx.dynenv` 上：

| 偏移 | 字段 |
|---|---|
| 0 | kind：1 是 catch，2 是 unwind-protect |
| 8 | prev |
| 16 | fp：建立条目那一帧的帧指针（`get_frame_pointer`） |
| 24 | tag（只有 catch 用） |
| 32 | 待继续的展开目标（cleanup 运行期间使用） |
| 40 | 待继续的展开值 |

### 6.2 调用点

- 在有活跃条目的区域里，所有可能展开的调用都编译成 `try_call`，带一个 default handler。可能展开的调用包括：Lisp 函数调用，以及声明为 `unwinds` 的 runtime 函数。
- 每个调用点只有一个 handler。handler 收到两个 payload：`exn0` 是目标条目的地址，`exn1` 是传递的值。handler 先把 `exn0` 和本区域的条目比较：相同就进入本区域的落地代码，否则跳到同一帧里外层区域的 handler。所以同一帧里嵌套多个区域也能正确分派。
- kiln-cg 编译完每个函数后，从 Cranelift 读出带 handler 的调用点，记录（返回地址偏移、handler 偏移、frame_offset）。
  - JIT：直接用绝对地址注册到 runtime。
  - AOT：写进目标文件的 `kiln_callsites` 表（函数地址用重定位），由 `kiln_module_info` 指向，启动时注册。

### 6.3 展开算法（`rust/kiln-rt/src/unwind.rs`）

1. 从 `ctx.dynenv` 栈顶开始逐个弹出条目，直到目标：
   - 中间的 catch：跳过；
   - 中间的 unwind-protect：把展开目标和值保存在这个条目里，然后恢复进它所在的帧，执行 cleanup。cleanup 结束时调用 `kiln_rt_continue_unwind`，继续展开；
   - 到达目标 catch：恢复进它所在的帧，`exn1` 就是 catch 的返回值。
2. **恢复进一个帧**：从 trampoline 的帧指针出发沿 FP 链往上走，找到“调用者 FP 等于目标帧 FP”的那一帧，取它的返回地址，也就是目标帧当前活跃的调用点。查表得到 handler 和 frame_offset，然后设置 SP = FP − frame_offset、FP、两个 payload 寄存器（x86-64 上是 rax、rdx），跳转到 handler。做法和 wasmtime 的 unwinder 一致。

只会恢复进 dynenv 里记录的帧，中间没有条目的帧直接越过，不需要扫描它们的表。

### 6.4 会展开的 runtime 函数要经过 trampoline

用 `try_call` 调用 System V 函数时，Cranelift 假设 callee-saved 寄存器在异常边上依然有效，但 Rust 函数被跳出时不会恢复它们。所以 KIR 里标记为 `unwinds` 的 runtime 函数，kiln-cg 会为它生成一个 `tail` 约定的 trampoline（`__kiln_t_<名字>`）。Lisp 代码 `try_call` 这个 trampoline，trampoline 再调用 Rust 函数，并把自己的帧指针作为最后一个参数传过去，作为 unwinder 遍历 FP 链的起点。

这条规则以后同样适用于 FFI 回调和 debugger：**凡是可能展开的 native 调用，都经过 `tail` trampoline。** 这和 C6 的 FFI trampoline 是同一套机制。

### 6.5 本地退出

`return-from` 和 `go` 在同一个函数里时直接跳转。跳转前按从内到外的顺序弹出经过的条目，遇到 unwind-protect 就把 cleanup 内联执行。跨函数的 `return-from`（来自闭包）要等闭包实现以后再做，届时 block 也会建立一个动态环境条目。

## 7. Poll 点（C4）

函数入口和每个 tagbody 标签（也就是循环头）都会插入 poll：读取 `ctx.poll_flag`，非零就调用 `kiln_rt_poll`。`kiln_rt_poll` 声明为 `unwinds`，所以经过 trampoline、按 `try_call` 编译，因为以后慢路径可能进入 debugger 并展开。M0 里慢路径只是把标志清零。

## 8. KIR 语法

```
(module "名字"
  (init "初始化函数对象的数据名")
  (import-func "名字" 参数个数 返回值个数 [unwinds] [noreturn])
  (import-data "名字")
  (data "名字" (words W ...))      ; W: 整数 | (data "名字" [addend]) | (func "名字")
  (data "名字" (bytes "..."))      ; 末尾自动补 NUL
  (func "名字"
    (vars (v obj|raw) ...)         ; obj 会登记进栈图
    (slots (s 字节数) ...)
    (block b 语句...) ...))        ; 第一个 block 是入口
```

预定义变量：`ctx self nargs a0 a1 a2 a3`（入口参数）、`exn0 exn1`（handler 收到的 payload）。

| 语句 | 含义 |
|---|---|
| `(set v E)` | 赋值 |
| `(store A 偏移 V)` | 存一个字 |
| `(jump b)` / `(br C b1 b2)` | 跳转；C 非零走 b1 |
| `(return V0 NV)` | 返回 |
| `(call-lisp v0 nv ENTRY (ctx self nargs a...) H)` | 调用 Lisp 函数；H 是 handler block 名，或 `nil` |
| `(call-rt "名字" (结果...) (参数...) H)` | 调用 runtime 函数；只有 `unwinds` 的函数才使用 H |
| `(add-ovf r o A B)` / `sub-ovf` / `mul-ovf` | 带溢出标志的有符号运算 |
| `(trap)` | 不可达 |

| 表达式 | 含义 |
|---|---|
| 整数、变量名 | |
| `(add A B)` `sub` `mul` `and` `or` `xor` | |
| `(shl A n)` `sar` `shr` | 立即数移位 |
| `(eq A B)` `ne` `lt` `le` `gt` `ge` | 有符号比较，结果 0/1 |
| `(load A 偏移)` | 读一个字 |
| `(addr "名字" [addend])` | 数据或函数的地址 |
| `(fp)` | 当前帧指针 |
| `(slot s)` | 栈槽地址 |
| `(select C A B)` | |

## 9. M0 前端支持的子集

`defun`（最多 4 个必需参数）、`if`、`let`、`let*`、`setq`、`progn`、`block`、`return-from`、`tagbody`、`go`、`catch`、`throw`、`unwind-protect`、`quote`（fixnum 和 symbol）、同一文件内定义的函数调用，以及原语 `+ - * < > <= >= = eq null not print`。只有词法变量，没有闭包。

## 10. 遗留到 M1 的事项

- MMTk 接入、对象分配、cons，以及完整的对象表示和 tag 方案。
- 栈图已经声明（obj 变量调用了 `declare_var_needs_stack_map`），但还没有导出给 runtime，GC 也还没有用它。要和调用点表合并成统一的“调用点描述符”。
- C8 的 `%switch-stack` 测试。
- 超过 4 个参数时的溢出区、`&optional`/`&rest`/`&key`、多值。
- special 变量（TLS 索引，C1），以及绑定在展开时的恢复（动态环境条目再加一种 kind）。
- 跨函数的 `return-from`。
- 多模块：trampoline 和 `kiln_enter` 目前每个模块各生成一份，`kiln_module_info` 也只支持一个模块。
- 未定义函数：M0 在编译期报错。运行期重定义需要给函数 cell 一个默认的“未定义函数”入口。
