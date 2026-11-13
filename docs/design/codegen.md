# KIR 和 kiln-cg

## 组成

```text
Lisp 编译器（SBCL 或 kiln） → 独立 LIR（类型化语义操作与 CFG）
        ├─ .kir：诊断文本输入
        ├─ .lir：规范化二进制封套
        └─ image：compile-program（一次性记录）/ compile-packet（序列化载荷）
                              ↓ 类型与 CFG 验证、布局及 ABI 展开
kiln-cg（rust/kiln-cg）      内存 KIR → Cranelift
        ├─ jit：cranelift-jit，在进程内运行
        └─ obj：cranelift-object 产出 .o
                cc x.o libkiln_launcher.a → 可执行文件
kiln-rt（rust/kiln-rt）      context、GC、unwinder、栈和运行时函数
kiln-launcher               staticlib，提供 C main，链接 kiln-rt 和 kiln-cg
```

Lisp 编译器输出布局无关的 LIR（[lir.md](lir.md)），通过[结构化编译协议](compiler-protocol.md)交接。kiln-cg 按 kiln-rt 的布局把 LIR 降级成内部 KIR，再调用 Cranelift。本文描述内部 KIR 及其诊断文本接口，分层理由见 [compiler.md](compiler.md)。

`target/debug/kiln-cg jit kernel.kir prog.kir` 运行程序，加 `--dump-clif` 查看生成的 CLIF；`kiln-cg obj ... -o prog.o` 生成目标文件。

编译器中的模块对象还记录 `replayable-p`，供顶层原生产物缓存判断初始化函数是否可重复执行。引入 `load-time-value` 单元的降级会清除此标志，保持不同编译结果的静态 cell 独立；该元数据不写入 KIR 文本。

## 当前 KIR 与目标后端接口

生产文件以独立 LIR 的二进制 packet 交接，image 使用结构化记录或序列化载荷；文本输入保留用于诊断和迁移对照。KIR 保留为 Rust 内部表示，原因如下：

- **cranelift-frontend 只能通过 API 使用。** 它负责从可变变量构建 SSA（`Variable`、`def_var`/`use_var`），以及在 safepoint 处为 GC 引用插入溢出和重载（user stack maps，C5）。直接写 CLIF 文本就绕过了它，Lisp 侧得自己构建 SSA、自己做溢出。
- **布局与机器后端分层。** 内部 KIR 已确定 tag、偏移和调用序列。对象布局、参数和返回值传递、动态条目及 roots 均由 Rust 展开。kiln-cg 继续负责 Cranelift 调用、异常表、栈图、trampoline 和调试表。

## KIR 语法

```
(module "名字"
  (init "初始化函数对象的数据名")
  (import-func "名字" 参数个数 返回值个数 [unwinds] [noreturn])
  (import-data "名字")
  (data "名字" (words W ...))      ; W: 整数 | (data "名字" [addend]) | (func "名字") | (:literal i)
  (data "名字" (bytes "..."))      ; 末尾自动补 NUL
  (root "数据名" 字下标)            ; 静态 GC root
  (shared "名字" ...)               ; 可被多个模块以相同内容定义的数据和函数
  (func "名字"
    (vars (v obj|raw|f64 [下标]) ...)  ; obj 会登记进栈图；下标：源码变量名（debugging.md）
    (slots (s 字节数) ...)
    [(debug W) | (debug-ref "数据名" 偏移)]  ; 函数的调试信息对象
    (block b 语句...) ...))        ; 第一个 block 是入口
```

预定义变量：`ctx self nargs a0 a1 a2 a3`（入口参数）、`exn0 exn1`（handler 收到的 payload）。

| 语句 | 含义 |
|---|---|
| `(set v E)` | 赋值 |
| `(store A 偏移 V)`、`(store32 A 偏移 V)` | 存一个字、存 32 位 |
| `(jump b)` / `(br C b1 b2)` | 跳转；C 非零走 b1 |
| `(switch E 默认块 ((整数 块)...))` | 按 64 位整数分派；没有匹配时走默认块，重复键非法；密集区间生成跳转表 |
| `(return V0 NV)` | 返回 |
| `(call-lisp v0 nv ENTRY (ctx self nargs a...) H [(loc 起始 结束)])` | 调用 Lisp 函数；H 是 handler block 名，或 `nil`；`loc` 是调用形式的源码范围 |
| `(tail-call-lisp ENTRY (ctx self nargs a...))` | 尾调用 Lisp 函数（Cranelift 的 `return_call_indirect`），被调函数的值就是本函数的值；是终结语句。只能用在本函数没有活动的动态环境条目（`catch`、`unwind-protect`、special 绑定）的地方：funcallable instance 的跳板和 CLOS 的分派代码（`%primop :tail-funcall`、`:tail-funcall-function`） |
| `(call-rt "名字" (结果...) (参数...) H [(loc 起始 结束)])` | 调用 runtime 函数；只有 `unwinds` 的函数才使用 H |
| `(add-ovf r o A B)` / `sub-ovf` / `mul-ovf` | 带溢出标志的有符号运算 |
| `(trap)` | 不可达 |

| 表达式 | 含义 |
|---|---|
| 整数、变量名 | |
| `(add A B)` `sub` `mul` `and` `or` `xor` | |
| `(sdiv A B)` `srem` | 有符号除法和余数，向零截断；B 不能是 0，A 是 i64 最小值时 B 不能是 −1 |
| `(f64-add A B)` `f64-sub` `f64-mul` `f64-div` | A、B 和结果是 IEEE binary64 的 64 位位模式；采用严格浮点运算，不进行装箱或 Lisp 条件检查。位模式须放在 `raw` 变量中，避免被 GC 当作对象引用 |
| `(f64-compare A B)` | A、B 为 binary64 位模式，结果为有符号整数 −1、0、1；小于、相等、大于分别对应这三个值。正负零相等，不可排序的 NaN 比较返回 0，与运行期浮点比较一致 |
| `(shl A n)` `sar` `shr` | 立即数移位 |
| `(shlv A B)` `sarv` | 按 B 的值移位，B 必须在 0..64 之内 |
| `(eq A B)` `ne` `lt` `le` `gt` `ge` | 有符号比较，结果 0/1 |
| `(load A 偏移)`、`(load32 A 偏移)` | 读一个字；读 32 位，零扩展 |
| `(addr "名字" [addend])` | 数据或函数的地址 |
| `(fp)` | 当前帧指针 |
| `(slot s)` | 栈槽地址 |
| `(select C A B)` | |

`obj` 变量登记为 GC 根，`raw` 变量不登记。`f64` 保存 binary64 位模式，
在后端使用浮点寄存器；表达式读取和赋值仍交换 64 位位模式。
目标为 `f64` 时，算术、常量和载入按浮点类型直接降级，中间量保留浮点表示，
在需要整数位模式的边界才转换寄存器类别。带调试名字且活过调用的 `f64`
通过前端的 safepoint spill 机制保存，供调试器读取，但其槽从运行期 GC 根表排除。
带源码名字的此类变量使用 `(:double-bits 名字)` 调试描述。GC 规则见 [gc.md](gc.md)。

## 多模块

- 共享定义：`(shared ...)` 列出本模块里可能被别的模块以相同内容定义的数据和函数：symbol 对象、它的名字字符串和未定义函数对象、`(setf f)` 的 cell、包名字符串、`kiln_undefined_function`。其他名字（函数、常量、`load-time-value` 的 cell、init 函数）都带模块名前缀，不会冲突。所以 symbol 在模块之间保持同一身份。
- kiln-cg 一次接受多个 KIR 文件，先合并成一个模块：导入去重，共享定义只保留第一份，其他名字重复就报错，root 去重，各模块的 init 函数按给出的顺序执行。runtime 登记静态 root 时也会去重。
- 分别生成的目标文件之间的链接（共享定义用 weak 链接、launcher 汇总多个模块信息）还没有做，kiln 的模块总是一起交给 kiln-cg。

## 模块信息

kiln-cg 输出的模块带一个 `kiln_module_info`（88 字节），runtime 启动时据此登记：

- `enter`：`kiln_enter`；
- `inits`、`ninits`：各模块 init 函数对象的数组；
- 调用点表（`kiln_callsites`：返回地址、handler、frame_offset，函数地址用重定位）；
- 栈图（`kiln_stackmaps` 和 `kiln_stackmap_offsets`）；
- 静态 root 表（`kiln_roots`）；
- 函数的调试记录和个数（[debugging.md](debugging.md)）；
- `exports`、`nexports`：`[C 字符串名字, 地址]` 对的数组，见下文“运行期编译”。

JIT 不写这些表，编译完直接用绝对地址注册。调用点表、栈图表、static root 表都按地址排序；新模块的地址在已有模块之上时，登记只需追加。

## 编译速度

- 编译器把模块的顶层形式每 16 个分成一块（`*toplevel-chunk-size*`），各块编成单独的函数，由 init 函数依次调用。寄存器分配对函数大小是超线性的，整个模块的顶层形式放在一个函数里会很慢。
- kiln-cg 先串行构造各函数的 CLIF（声明函数引用需要 `&mut Module`），再在所有核上并行生成机器码（`KILN_CG_THREADS` 可改），最后按顺序用 `define_function_bytes` 定义，调用点表和栈图照旧从编译结果里取。JIT 和目标文件两条路径都适用。处理小模块时不开线程，ISA 也只建一次。
- dev profile 下 kiln-cg、kiln-rt 和依赖库（Cranelift、MMTk）都用 opt-level 2；debug 断言对 kiln 自己的 crate 保持打开，对 MMTk 关掉（它的断言检查每次 side metadata 访问，GC 慢很多）。
- **写出 KIR 文本**：在 kiln 上，编译器把模块的 KIR 逐个形式交给运行时的 `kiln_rt_write_kir`（`rust/kiln-rt/src/kirtext.rs`，经 `kiln.sys::%write-kir`），由它直接遍历列表结构、写到文件描述符；宿主（SBCL）仍用 `lisp/kir.lisp` 的 `out-kir`。两边的输出必须逐字节相同，自举时比较。
- 环境变量：`KILN_VERIFY=1` 打开 Cranelift 的 IR verifier（默认关闭）；`KILN_CG_OPT` 设定 Cranelift 的 opt_level；`KILN_TIME=1` 打印各阶段耗时；`KILN_PERF_MAP=1` 让 JIT 写出 perf map。

## 确定性

kiln-cg 的输出只取决于 KIR：函数里 landing block（`try_call` 的异常入口）按创建顺序填充，不按哈希表的遍历顺序，SSA 编号和寄存器分配因此稳定。自举要求 kiln0 和 kiln1 两个可执行文件逐字节相同，依赖这一点（[bootstrap.md](bootstrap.md)）。

## 内存

- JIT 把代码和数据放进同一块预留区。模块很大时，malloc 来的几块内存可能相距超过 2 GB，32 位 PC 相对重定位会溢出。
- 运行期编出的模块放在 kiln-rt 管理的固定地址区域（`rust/kiln-rt/src/code.rs`，见 [heap-image.md](heap-image.md)）。

## 运行期编译

当前一次性原生编译使用 `kiln_rt_compile_program`：复制结构化记录并核验目标，直接构造内存 KIR。序列化载荷使用 `kiln_rt_compile_packet`，接收 simple-vector octets 和 literal 向量，复制、校验并解码后进入同一操作路径。下述 `kiln_rt_jit` 是保留的文本兼容入口。封套版本与所有权见 [compiler-protocol.md](compiler-protocol.md)。

kiln-cg 作为库链进 `libkiln_launcher.a`，运行期的入口是 `kiln_rt_jit`（`rust/kiln-cg/src/jit.rs`）：解析 KIR，编进内存，登记调用点、栈图、static root 和调试记录，把字面量向量的元素写进模块的字面量字，返回 init 函数对象（还没调用）。KIR 编不过时打印原因并返回 NIL。只有引用了它的程序（含 compiler 模块的程序）链接时才带进 Cranelift。

编进运行中 image 的代码要和 image 共用一些定义（未定义函数的入口、funcallable instance 的跳板），所以这类模块把它们写成 `import-data`。kiln-cg 链接时按名字解析：每个模块导出 `kiln_rt::EXPORTED_NAMES` 中它定义的那些名字（模块信息的 `exports`），kiln-rt 记下地址。Lisp 这一侧的做法见 [eval-compile.md](eval-compile.md)。
