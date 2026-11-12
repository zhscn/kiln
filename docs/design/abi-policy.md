# ABI 的稳定性和演进

ABI 本身见 [abi.md](abi.md)、[objects.md](objects.md)、[codegen.md](codegen.md)；本文说明 kiln 对 ABI 做什么承诺、不做什么承诺。和 Swift ABI 稳定化的对照见 [swift-abi.md](../research/swift-abi.md)。

编译边界的 LIR schema、runtime ABI 指纹及后端管线版本分别校验。内存和文件使用同一二进制编码；FASL 与包含编译数据的快照记录兼容键，不匹配时重建可丢弃缓存或拒绝加载，见 [compiler-protocol.md](compiler-protocol.md)。

## ABI 的使用者

| 使用者 | 之间的契约 | 是否同一构建 |
|---|---|---|
| kiln-cg 和 kiln-rt | 值表示、context 布局、运行时函数、栈图、unwind | 是 |
| Lisp 编译器和 kiln-cg（目标设计，[lir.md](lir.md)） | LIR 版本、目标描述（表示类、字段名、错误码、fixnum 范围），带 ABI 指纹 | 开发期是；指纹不符时 kiln-cg 拒绝 |
| image 里的各个模块（kernel、CLOS、frontend、eval、compiler、用户代码） | 符号和函数对象布局、调用约定、内联函数和宏 | 开发期是 |
| seal 之后的交付产物 | 无：WPO 后静态链接成一个封闭的二进制 | — |
| 外部 C 代码（FFI） | C 的 ABI | 不需要 kiln 的承诺 |

kiln 的 ABI 是**同一构建内部的契约**，不是对外承诺。开发期是活 image，模块都由同一版本的 kiln 编译；交付期 seal 之后整体优化、静态链接，不存在独立升级的二进制组件。CL 实现的惯例也一样：SBCL 不保证跨版本的 FASL 兼容，升级后重新编译。

## 决定

- **不承诺跨版本的二进制兼容**，至少在 1.0 之前不承诺。ABI（值的 tag、对象头、context 布局、调用约定）可以随时修改，当前修改时先改设计文档，再同步 `rust/kiln-rt/src/{object,context}.rs` 和 `lisp/abi.lisp` 两处常量。LIR 接入后由 Rust 生成 Lisp 所需的目标能力描述，不再复制 tag 和偏移。
- **ABI 指纹**（还没有实现）：由 ABI 常量表算出一个哈希，写进每个 KIR 模块和目标文件。kiln-cg 和 kiln-rt 加载模块时校验，不一致就拒绝加载并报告，不让版本不匹配表现为静默崩溃。Rust 宿主模块也用它核对（[rust-interop.md](rust-interop.md)）。现在只有堆快照有自己的指纹（[heap-image.md](heap-image.md)）。
- **冻结得越晚越好**：Swift 在 ABI 稳定之前改过多次布局和调用约定，许多性能改进都依赖这种自由。kiln 在 1.0 之前同样保持 ABI 可以自由修改；ABI 指纹保证这种自由不会变成难以诊断的崩溃。
- **内联函数和宏是编译期依赖**：一个模块内联了另一个模块的函数，或者展开了它的宏，前者就依赖后者的定义，而不只是它的名字。在 image 里求值的定义已经记录这些依赖，重定义时自动更新（[dependencies.md](dependencies.md)）；AOT 编出的模块还没有记录。
- **seal 相当于整体冻结**：函数经 fdefinition 间接调用、类可以重定义（实例靠 stamp 和实例更新协议迁移）、槽位按名字查位置，这些都是开发期的“可演进”。seal（[positioning.md](positioning.md)）把整个世界一次冻结：之后可以直接调用、固定槽偏移、内联、裁掉用不到的元对象。待定：seal 之前是否也允许局部冻结（sealed class、sealed generic function），在开发期就拿到一部分 seal 之后的性能。
