# 堆快照

`kiln.sys:save-image` 把 image 存成文件，相当于 SBCL 的 `save-lisp-and-die`，但保存后进程不退出。从快照启动时不再执行各模块的 init 函数。它是构建期初始化（[modern-practices.md](../research/modern-practices.md) 的第 1 项）的第一步；seal 时在构建期执行初始化、写进目标文件，还没有做。

## 用法

```lisp
(kiln.sys:save-image "app.img" :toplevel #'main)                 ; 只写快照
(kiln.sys:save-image "app" :toplevel #'main :executable t)       ; 可执行文件加快照
```

- 同一个可执行文件用环境变量 `KILN_IMAGE=app.img` 启动时，映射快照，调用 `main`，不再执行各模块的 init 函数。`main` 返回后进程退出。
- `:executable t` 把当前可执行文件复制一份，快照接在末尾。新文件启动时自己找到快照。如果当前进程本身就是从这样的文件启动的，复制时会去掉原来的快照。
- 快照里保存的是全局状态：从静态根（符号的函数、值、属性表等，见下文“设计”）可达的一切对象。栈、动态绑定、多值都不保存。在 `let` 绑定特殊变量期间保存的话，保存的是全局值。
- `kiln.sys:*save-hooks*` 在保存前依次调用，`kiln.sys:*init-hooks*` 在从快照启动、调用 toplevel 之前依次调用。CLOS 模块用后者重新取当前目录（`*default-pathname-defaults*`）。标准流没有缓冲区，保存前不需要另外刷新。
- 从快照启动的进程可以再保存快照，例如载入编译器、改几个函数后存一份，下次从那里开始。

只有 AOT 可执行文件能保存快照，kiln-cg 的 JIT 模式（`kiln-cg jit`）不行。运行期 `compile`、`eval` 编出的代码也会保存。从快照启动的时间和快照大小见 [performance.md](../research/performance.md)。

## 设计

**为什么能用固定地址**：kiln 的可执行文件不是位置无关的，代码和静态数据（编译器输出的符号、常量）的地址每次运行都一样。快照只对写出它的那个可执行文件有效，所以快照里可以直接存最终地址，加载时不需要重定位。文件头里有一个指纹（模块信息的地址和全部静态根的地址），对不上就拒绝加载。

**快照区**：快照里的对象映射在固定地址 `IMAGE_BASE = 0x3000_0000_0000`。它在 MMTk 的堆范围（`0x0200_0000_0000`–`0x2200_0000_0000`）之上，在内核分给 `mmap` 的地址之下。映射发生在 MMTk 初始化之前，MMTk 的保留区不会占到这里。

**保存**（`rust/kiln-rt/src/image.rs`）：
1. 从静态根和 toplevel 函数出发，按 Cheney 算法把可达的对象复制进一个缓冲区，地址换算成 `IMAGE_BASE` 加偏移。
2. 堆里的对象和当前快照区里的对象都要复制。静态数据（模块的数据段、NIL、T）留在原处，指向它们的指针不变。
3. 遍历时检查函数对象的入口地址是否在可执行文件的代码段里（`__executable_start` 到 `etext`）。
4. 文件布局：一页文件头，然后是对象（按页对齐），最后是静态根的（地址, 值）对。
5. 运行时的两个计数器也存进文件头：TLS 下标和 identity hash。
6. 先写临时文件再改名，所以正在运行的可执行文件也可以覆盖自己。

**静态根就是静态数据里所有会变的字**：符号的包、函数、值、TLS 下标、属性表、setf 函数，`load-time-value` 的格子，NIL 和 T 的几个字。TLS 下标本身是 fixnum，不需要作为 GC 根，但它和其他字一样会在运行时改变，所以也登记为根，保存时一起存下来。编译器输出的常量（字符串、cons、向量等）是不可变的，不用存。静态对象的 identity hash 按地址计算，也不会改写对象头。

**运行期编出的代码**：原生 `compile` 和 `eval` 编出的代码和数据放在另一块固定地址的区域（`CODE_BASE = 0x3800_0000_0000`，预留 16 GiB，`rust/kiln-rt/src/code.rs`）。kiln-cg 的 JIT 从这里按页分配，每种内存（代码、只读数据、可写数据）一块；模块定稿后设好页面权限，并把调用点、栈图、static root 登记给 runtime，同时在 kiln-rt 里留一份副本。保存时，把这块区域已分配的页面原样写进快照，再写这些段和表的描述。加载时读回同样的地址，恢复页面权限，重新登记这些表。这块区域里的字面量字是 static root，所以它们的值也随静态根保存。指纹只计算可执行文件自己的静态根，运行期登记的根不算在内。

**加载**（`run_module_here`）：
1. 照常登记代码表。
2. 映射快照，读回运行期代码区域并登记它的表，写回静态根，恢复两个计数器。
3. 创建 context，调用 toplevel 函数。

**identity hash**：堆对象的 hash 存在对象头里（[objects.md](objects.md)）。快照区的对象也走这条路径，保存前已经分配的 hash 会原样保留，`eq` 哈希表在恢复后仍然有效。

## GC 和快照区

快照区不属于 MMTk 的任何空间：里面的对象不移动、不回收，GC 也不追踪它们（`KilnSlot::load` 对堆范围以外的地址返回 `None`）。但它们是可变的，可能指向后来分配的堆对象。所以每次回收都线性扫描整个快照区，把指向堆的字作为根交给 MMTk（`image::heap_slots`）。

这比把长期存活的对象留在堆里好：SemiSpace 每次都要复制它们一遍，快照区每次只是读一遍。要连这一遍也省掉，需要写屏障加 card table，记下哪些快照页被写过。这和分代 GC 是同一项工作，以后一起做。

## 测试

`tools/test.sh` 里，`NAME.lisp` 旁边有 `NAME.image` 文件的测试，只跑 AOT，并且在构建目录里运行：
1. 程序运行时写出 `NAME.img`，也可以写出 `NAME.exe`，输出和 `.expected` 比较。
2. 再用 `KILN_IMAGE` 从快照启动两次，一次用默认堆，一次用小堆做 GC 压力测试；`NAME.exe` 存在的话也运行它。三次的输出都和 `NAME.image` 比较。
3. 如果从快照启动的进程又保存了 `NAME-2.img`，再从它启动一次，输出和 `NAME.image2` 比较。

`tests/m6/clos-image` 覆盖：
- 闭包、`eq` 和 `equal` 哈希表（键分别是堆符号、静态符号、cons、实例）、bignum、gensym、`intern`；
- 恢复后新增方法、新建实例、`defstruct`、条件系统、reader；
- 新对象只被快照区引用时能活过 GC；
- 第二代快照。

`tests/m6/co-image` 覆盖：从快照启动后原生 `compile` 和 `eval`；编过代码之后再保存快照，从新快照启动后调用这些代码、经过 GC、再编新的代码。

`KILN_COMPILER=... tools/test.sh` 用快照跳过“kiln 编五个模块”这一步，见 [bootstrap.md](bootstrap.md) 的“测试”。这个快照约 360 MB，里面是编完五个模块后的整个编译会话，也有运行期编出的代码。

## 限制

- 只有 AOT 可执行文件能保存；JIT 不行。
- 每次 GC 都扫描整个快照区，要省掉需要写屏障和 card table。
- 可执行文件必须不是位置无关的（PIE）。改成 PIE 时快照要带重定位信息。
- 快照只对写出它的那个可执行文件有效。
