# 12 ABI 的稳定性和演进

**状态**：方针（2026-11）。ABI 本身的内容见 [06-m0-abi.md](06-m0-abi.md)、[07-m1-gc.md](07-m1-gc.md)、[08-m2-front-end.md](08-m2-front-end.md)；本文说明 kiln 对 ABI 做什么承诺、不做什么承诺，以及和 Swift ABI 稳定化的对照。

## 1. ABI 的使用者

| 使用者 | 之间的契约 | 是否同一构建 |
|---|---|---|
| kiln-cg 和 kiln-rt | 值表示、context 布局、运行时函数、栈图、unwind | 是 |
| image 里的各个模块（kernel、CLOS、frontend、eval、compiler、用户代码） | 符号和函数对象布局、调用约定、内联函数和宏 | 开发期是 |
| seal 之后的交付产物 | 无：WPO 后静态链接成一个封闭的二进制 | — |
| 外部 C 代码（FFI） | C 的 ABI | 不需要 kiln 的承诺 |

kiln 的 ABI 是**同一构建内部的契约**，不是对外承诺。开发期是活 image，模块都由同一版本的 kiln 编译；交付期 seal 之后整体优化、静态链接，不存在独立升级的二进制组件。CL 实现的惯例也一样：SBCL 不保证跨版本的 FASL 兼容，升级后重新编译。

## 2. 决定

- **不承诺跨版本的二进制兼容**，至少在 1.0 之前不承诺。ABI（值的 tag、对象头、context 布局、调用约定）可以随时修改，修改时先改 06/07/08，再同步 `rust/kiln-rt/src/{object,context}.rs` 和 `lisp/abi.lisp` 两处常量。
- **ABI 指纹**（待实现）：由 ABI 常量表算出一个哈希，写进每个 KIR 模块和目标文件。kiln-cg 和 kiln-rt 加载模块时校验，不一致就拒绝加载并报告，不让版本不匹配表现为静默崩溃。
- **内联函数和宏是编译期依赖**：一个模块内联了另一个模块的函数，或者展开了它的宏，前者就依赖后者的定义，而不只是它的名字。开发期在 image 里重定义这样的函数或宏时，用到旧定义的代码不会自动改变（SBCL 的行为也是这样，用户常常因此踩坑）。待定：模块记录它用到的内联函数和宏（以及定义的版本），重定义时提示哪些模块需要重编，或者让它们自动失效。

## 3. 和 Swift 的对照

Swift 5（2019）实现了 ABI 稳定，花了几年。它的前提是标准库随操作系统发布，几年前编译的 App 要能和新系统的库一起运行，所以必须保证跨版本的二进制兼容。kiln 没有这个前提（§1），Swift 为此付出的大部分机制不需要；但它的几个概念和 kiln 的设计正好对应。

### 3.1 不需要的部分

- **resilient 布局**：跨模块访问结构体字段时，由运行期的 metadata 给出大小和偏移，库可以在不破坏客户端的前提下增删字段。
- **value witness table**：经由函数表复制、销毁布局未知的值。
- **稳定的 mangling**：kiln 的符号标签（`kiln_sym_PKG_3A_NAME` 这类转义名）只需在同一构建内确定、可逆。

### 3.2 resilience 边界和 seal

Swift 跨模块默认是 resilient 的：不暴露布局，以后可以演进；`@frozen` 声明放弃演进，换取直接访问和内联。

CL 的动态重定义要求本质上是同一件事：

- 函数经 fdefinition 间接调用，可以重定义；
- 类可以重定义，实例靠 stamp 和实例更新协议迁移；
- 槽位按名字查位置（`%slot-location` 的缓存，docs/11 §9.4）。

seal（[01-positioning.md](01-positioning.md)）相当于把整个世界一次标成 `@frozen`：之后可以直接调用、固定槽偏移、内联、裁掉用不到的元对象。Swift 的划分是逐个声明的；kiln 可以考虑在 seal 之前也允许局部冻结（sealed class、sealed generic function），在开发期就拿到一部分 seal 之后的性能。待定。

### 3.3 `@inlinable` 和内联依赖

Swift 的 `@inlinable` 让函数体成为模块接口的一部分：库改了函数体，已经编译的客户端仍然执行旧的副本。§2 的“内联函数和宏是编译期依赖”是同一个问题。Swift 的做法是把它显式写进接口（`.swiftinterface`），由开发者承诺；kiln 是活 image，可以做得更进一步，记录依赖并在重定义时处理。

### 3.4 错误的传递

Swift 的 `throws` 不走 unwind：错误经专用寄存器返回，调用方检查一次，开销接近普通返回。kiln 的非局部退出（`return-from`、`throw`、`handler-case` 的退出）走 `try_call` 和 unwinder（[06-m0-abi.md](06-m0-abi.md)）。CL 代码里这类控制流很常见；如果 profile 显示 unwind 的开销明显，可以把编译期已知目标、只跨少数几层的退出改走返回值通道。这属于中端优化，不需要改 ABI。

### 3.5 async

Swift 的 async 是无栈的：函数被拆成续体，经专用的 async context 寄存器传递状态。好处是任务的内存密度高、和同步代码零开销互操作；代价是函数着色（async 函数只能在 async 上下文里调用）和编译器的复杂度。

kiln 的 [03-async.md](03-async.md) 选的是有栈的一次性续延（参考 OCaml 5 的 fiber）：不用给函数着色，和 CL 的动态特性、special 绑定、condition 系统更契合；代价是每个 fiber 都要有栈，还要处理扩栈。到实现 async 时，以 Swift 的取舍作对照再评估一次。

### 3.6 冻结得越晚越好

Swift 在 ABI 稳定之前改过多次布局和调用约定，许多性能改进都依赖这种自由。kiln 在 1.0 之前同样保持 ABI 可以自由修改；ABI 指纹（§2）保证这种自由不会变成难以诊断的崩溃。
