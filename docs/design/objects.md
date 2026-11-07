# 值和对象的表示

两侧的定义在 `rust/kiln-rt/src/object.rs` 和 `lisp/abi.lisp`，修改时必须同步（[abi-policy.md](abi-policy.md)）。对象的布局知识留在 Lisp 编译器里，kiln-cg 不知道 tag 和偏移（[codegen.md](codegen.md)）。

## 值

一个值是一个 64 位的字，低 3 位是 tag：

| 低位 | 含义 |
|---|---|
| `...0` | fixnum，63 位，值 = word >> 1 |
| `001` | cons 指针，地址 = word − 1 |
| `101` | 其他堆对象的指针，地址 = word − 5 |
| `011` | 立即数，第 3–7 位是立即数的种类，第 8 位起是载荷 |
| `111` | 保留 |

立即数：

| 低 8 位 | 种类 | 载荷 |
|---|---|---|
| `0x0B` | character | Unicode 码点（第 8 位起） |
| `0x13` | UNBOUND：未绑定的全局值，不是一等值 | — |
| `0x1B` | single-float | 第 32–63 位是 IEEE 754 单精度 |
| `0x23` | NO_TLS：TLS 表的空项，不是一等值 | — |
| `0x2B` | 标准对象里未绑定的槽（Clostrophilia 的 `+unbound-slot-value+`） | — |

`0x2B` 和 UNBOUND 不同，所以它可以作为变量 `+unbound-slot-value+` 的值。

## 堆对象

- **每个对象都以一个 header 字开头，cons 也不例外。** header 的低 8 位是 kind，第 8–39 位是长度（含义随 kind 而定），第 40–63 位是身份哈希。
- 对象 8 字节对齐，大小都是 8 的倍数。
- 对象引用（MMTk 的 `ObjectReference`）就是 header 的地址。

**为什么 cons 也带 header**：MMTk 要能从对象本身算出它的大小（`get_current_size`），而对象引用里不带 tag。没有 header 的话，就得为 cons 单独开一个 space，或者用 side metadata 记录类型，这两种做法在 MMTk 的标准 plan 下都很麻烦。代价是每个 cons 多占 8 字节。以后如果需要，可以给 cons 专门做一个按大小分类的 space。

| kind | 类型 | 布局 | 长度字段 | GC 扫描 |
|---|---|---|---|---|
| 1 | symbol | `[header, name, package, function, value, TLS 下标, plist, setf 函数]` | — | name 到 setf 函数 |
| 2 | function | `[header, 入口, env...]` | env 字数 | env |
| 3 | cons | `[header, car, cdr]` | — | car、cdr |
| 4 | simple-vector | `[header, 元素...]` | 元素个数 | 全部元素 |
| 5 | simple-character-string | `[header, UTF-32 码点...]`，按 8 字节补齐 | 字符个数 | 否 |
| 6 | bignum | `[header, 64 位数字...]`，二进制补码，小端，最短 | 数字个数 | 否 |
| 7 | ratio | `[header, 分子, 分母]` | — | 分子、分母 |
| 8 | double-float | `[header, IEEE 754 位模式]` | — | 否 |
| 9 | standard-instance | `[header, rack]` | — | rack |
| 10 | funcallable-instance | `[header, 入口, rack, 安装的函数]` | — | rack、安装的函数 |
| 11 | rack | `[header, class, stamp, 有效槽列表, 槽...]` | 字数 | 全部 |
| 12 | complex | `[header, 实部, 虚部]` | — | 实部、虚部 |

超过当前 plan 普通分配上限的对象，`kiln_rt_alloc` 改用 MMTk 的 large object space。

### symbol

- `name` 是字符串对象。
- `package` 是包对象，未 intern 的 symbol 是 NIL。编译器生成的静态 symbol 在这个槽里先存包名字符串，包系统启动时把它换成包对象（[stdlib.md](stdlib.md) 的“包”）。在那之前 `keywordp` 和 runtime 的打印器靠包名判断。
- **`function` 槽就是函数 cell。** 调用全局函数：从 symbol 读出函数对象，再读入口地址，`call_indirect`。`(setf fdefinition)` 直接写这个槽，重定义因此立即生效。
- **未定义函数**：每个 symbol 的 `function` 槽初始指向一个“未定义函数”对象。它是一个 env 长度为 1 的函数对象，入口是 `kiln_undefined_function`，env 里放着这个 symbol，所以出错时能报告函数名。调用点不需要额外检查。未定义的 `(setf f)` 有单独的报错入口。
- `value` 槽是全局值，未绑定时是 UNBOUND。keyword 的值是它自己。
- **TLS 下标**按 fixnum 存放（下标 << 1），所以 symbol 的所有字段都是合法的 Lisp 值，GC 可以统一扫描堆上的 symbol。0 表示还没有分配。TLS 表项地址 = 表基址 + 存放的值 << 2。
- `setf 函数` 槽存名为 `(setf symbol)` 的函数，`fdefinition`、`(setf fdefinition)`、`fboundp` 都接受 setf 名字。编译期已知的 `(setf f)` 也可以有单独的静态 cell。
- NIL 和 T 是 runtime 里的静态对象（`kiln_nil`、`kiln_t`）。名字字符串在 runtime 启动时填写（Rust 的常量求值不能做指针加 tag）；它们的 plist、包、函数槽登记为 GC root，函数槽在 kernel 启动时放上未定义函数对象。

### 函数和 funcallable instance

- 函数对象 `[header(env 长度 << 8), 入口地址, env...]`。没有自由变量的函数用静态函数对象，闭包在堆上分配。GC 扫描 env，跳过入口地址。
- **funcallable instance 就是函数**：kind 10 和 kind 2 只差第 3 位，所有“是不是函数”的检查（调用点、`funcall`、`apply`、`functionp`）都用 `(kind & 0xF7) == 2`。它的入口是共享的跳板 `kiln_funcallable_trampoline`：从对象的第 3 个字取出安装的函数，用原来的 `nargs` 和寄存器参数调用它，返回它的全部值。跳板里没有 safepoint，传递区里的参数原样传下去。新建的 funcallable instance 安装的是一个调用即报错的函数。

### 实例和 rack

- 类指针放在 rack 里，不在 header 里（SICL 规范里考虑过的替代设计，见 [sicl-survey.md](../research/sicl-survey.md)）：`change-class` 和实例更新只需要替换 rack 指针这一个字；header 空出来的位存身份哈希。
- `standard-instance-access` 的位置 *loc* 对应 rack 的第 *loc* + 4 个字（第 0 个字是 header，第 1 个字是 class），所以 −2 是 stamp、−1 是有效槽列表、0 起是槽。
- 非实例对象的类和 stamp：`class-of` 按对象的 tag 和 kind 查表得到内建类，stamp 是这个类的唯一编号（[clos.md](clos.md)）。

### 数

- fixnum 范围（63 位）之外的整数是 bignum，长度最短。fixnum 范围内的整数永远是 fixnum，所以整数的 `eql` 就是 fixnum 的 `eq` 或 bignum 的值相等。
- ratio 总是约分过，分母大于 1；分母为 1 时就是整数。分子、分母可能是 bignum。
- single-float 是立即数，`eql` 对它就是 `eq`（`0.0` 和 `-0.0` 位模式不同，因此不 `eql`，符合 CLHS）。double-float 装箱。默认浮点格式是 single-float。
- complex 只由 kernel 的 `complex` 构造，所以总是规范的（CLHS 12.1.5）：两部分都是有理数且虚部不为 0，或者是同一格式的两个浮点数。`class-of` 是内建类 `complex`，编译期常量编译成静态对象。

### 字符串和数组

- 只有一种 UTF-32 的 `simple-character-string`，每个字符 4 字节。`base-string` 以后作为它的子类型单独一个 kind。
- 原生的数组只有元素为 T 的一维 simple-vector 和 simple string。其余数组（多维、特化元素类型、可调整、带 fill pointer、displaced）都是 Regalia 的标准实例（[stdlib.md](stdlib.md) 的“数组”）。

## 静态对象

NIL、T，以及编译器输出到数据段里的 symbol、函数对象和常量，都在 MMTk 的 space 之外，GC 不会移动也不会扫描它们。

- 判断一个指针是不是静态对象，看地址是否落在 MMTk 的堆地址范围内（`vm_layout` 的 `heap_start`..`heap_end`）。MMTk 分配的对象都在这个范围里，静态数据（模块数据、JIT 内存、AOT 的数据段、malloc 出来的内存、堆快照区）都不在。
- 静态对象里会变的字（symbol 的包、函数、值、TLS 下标、plist、setf 函数，`load-time-value` 的格子）登记为**静态 root**，GC 每次扫描并更新它们（[gc.md](gc.md) 的“root”）。
- 编译器输出的常量（字符串、cons、向量、bignum、ratio、double、complex）是不可变的，只指向静态数据，不用扫描。它们的 header 仍然可写（身份哈希，见下文）。

## 身份哈希

header 的第 40–63 位。`%primop :identity-hash` 在 header 里已有哈希时内联读出，否则调用 `kiln_rt_identity_hash`：

- MMTk 堆里的对象第一次用到时分配一个哈希（计数器经 Fibonacci 散列得到的 24 位数，写进 header）。GC 复制对象时连同 header 一起复制，所以对象移动后哈希不变。
- 静态对象（模块数据、NIL、T）不会移动，哈希按地址算出，但同样写进 header。这样编译出的代码下次在 header 里就能读到，不必调用 runtime：槽名等常量符号经常被哈希（`%slot` 的位置缓存），原来每次都进 runtime。地址每次运行都一样，所以哈希也一样；从快照启动时 header 是可执行文件里的原值，重新算出的也相同。
- 立即数没有 header，按位模式计算哈希。
- 堆快照保存计数器和已分配的哈希，`eq` 哈希表在恢复后仍然有效（[heap-image.md](heap-image.md)）。

长度字段因此限制为 32 位，Rust 和编译器里从 header 读长度都只取 32 位（`header_length`）。
