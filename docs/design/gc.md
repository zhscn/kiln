# GC、栈图和栈

对象表示见 [objects.md](objects.md)，context 和动态环境条目见 [abi.md](abi.md)。

## MMTk binding（`rust/kiln-rt/src/gc.rs`）

- 使用 mmtk 0.33（crates.io），关闭默认 feature，因此不带内置日志。
- 默认 plan 是 **SemiSpace**（移动式），固定堆 1 GiB，GC 线程数等于 CPU 核数，最多 8 个。都可以用 `MMTK_PLAN`、`MMTK_GC_TRIGGER`、`MMTK_THREADS` 等环境变量覆盖。
- MarkSweep 和 Immix 也可用。分配快路径用 plan 默认分配器的 bump pointer（SemiSpace 的 bump 分配器、Immix 的 Immix 分配器）；MarkSweep 的默认分配器没有 bump pointer，快路径总是失败，走 MMTk 的分配。MarkSweep 不移动对象，CLOS 测试在 8 MiB 的 GC 压力堆里会因碎片而内存不足。Immix 在自举上比 SemiSpace 慢约 5%。
- **没有写屏障，所以分代 plan（GenCopy、GenImmix、StickyImmix 等）不能用。** 有写屏障之前只能用非分代 plan。写屏障的做法：生成的代码里每个往堆对象写指针的地方，以及 runtime 里修改堆对象的地方，都先检查源对象的 log bit（side metadata），没登记的就登记，即 MMTk 的 object barrier。
- **对象引用就是 header 的地址。** forwarding pointer 写在 header 字里，forwarding bit 和 mark bit 放在 side metadata（header 的低字节是 kind，不能像 OpenJDK 那样把 forwarding bit 放进 header 的低位）。
- **Slot 类型 `KilnSlot`**：槽里存的是带 tag 的值。
  - load 时去掉 tag；fixnum、立即数和静态对象（地址不在 MMTk 的堆范围内）返回 `None`，GC 不处理。用地址范围判断，不用 `is_in_mmtk_spaces`（它要查 SFT 表，慢）。
  - store 时保留原来的 tag。
- **mutator**：每个 context 绑定一个 MMTk mutator，tls 就是 context 的地址。
- **分配不清零**：MMTk 交出的内存已经是零：kiln 用到的 plan 建空间时都传 `zeroed = true`，空间每次取得新页时清零（mutator 的 bump 块、大对象、GC 复制的目标块都是这样来的）；Immix 的分配器重用 recyclable line 时也清零，free-list 分配器清零每个 cell。所以 `kiln_rt_alloc` 只写 header（debug 构建检查首尾两个字是零）。编译出的代码的内联快路径（`emit-alloc`）仍然逐字写零，这些写也是多余的，可以去掉。反过来，MMTk 的清零才是大头（自举时约 2.5% 的 CPU，其中 GC 复制目标块的清零完全白做），但它在 MMTk 里写死，要改 MMTk。
- **root 分包**：交给 MMTk 的 root 槽每包最多 `EDGES_WORK_BUFFER_SIZE`（4096）个。一个包由一个 worker 处理，它要复制并扫描包里所有槽指向的对象；编译器会话里 static root 约 11 万个，原来放在一个包里，回收的这一部分只有一个 worker 在做（实测停顿没有变化，瓶颈不在这里）。static root 里只把指向堆的字交出去。
- **统计**：`KILN_GC_STATS=1` 在进程退出时向 stderr 打印回收次数、停顿时间、分配量、每次回收后的存活量、GC worker 和整个进程的 CPU 时间（`rust/kiln-rt/src/gcstats.rs`）；值是文件名时另外每次回收写一行。加 `MMTK_COUNT_LIVE_BYTES_IN_GC=true` 时存活量是 MMTk 数出的对象字节数，否则是回收后在用的页。SemiSpace 下再加 `KILN_GC_AGES=1`，把每次复制的字节分成“上次回收之后分配的”和“上次回收复制过的”，即 nursery GC 会复制的部分和分代 plan 不再复制的部分（用一张覆盖堆地址范围的位图，会拖慢回收）。

### 多 mutator 和握手

现在 GC 只会由唯一的 mutator 发起：分配失败，或者 `kiln_rt_gc` 调用 `handle_user_collection_request`。

MMTk 收到请求后立刻开始回收，而发起请求的 mutator 这时还在离开分配器的路上：它要释放自己的页预留，栈也还没有静止。所以 `stop_all_mutators` 要等所有 mutator 都进入 `block_for_gc`：每个 mutator 在那里登记自己，`BLOCKED_MUTATORS` 加一并通知。假定 mutator 已经阻塞的话，GC 可能先清空空间的页计数，MMTk 的调试断言 `_prev >= pages` 会偶发失败。

多线程或多 fiber 时需要真正的 safepoint 协议：poll 标志（C4）加上等待所有 mutator 到达 safepoint。

## Root

1. **每个 mutator 的每个栈段上的 Lisp 帧**。当前段从最近一次 safepoint 的 trampoline 帧指针（`ctx.safepoint_fp`）出发，沿 FP 链走到段底（`ctx.stack_base_fp`，由 `kiln_enter` 记录）；挂起的段记录在 `ctx.segments` 链上，各自带有段顶和段底。对每一帧：
   - 返回地址是 `[fp+8]`；
   - 调用方在这个调用点的 SP 是 `fp + 16`。这一点成立，是因为 Lisp 调用约定的所有参数都放在寄存器里（[abi.md](abi.md)）；
   - 用返回地址查栈图，得到存放 Lisp 对象的槽位（相对 SP 的偏移）。
2. **动态环境链上每个条目的 `tag` 和 `pend_value` 字段。**
3. **静态 root**：模块登记的静态字（symbol 的包、函数、值、TLS 下标、plist、setf 函数槽，`load-time-value` 的格子，运行期编出的模块的字面量字，NIL 和 T 的几个字）。
4. **每个 context 的 TLS 表**里已分配的项。
5. **传递区的前 `ctx.values_live` 个字**。
6. **堆快照区里指向堆的字**（[heap-image.md](heap-image.md)）。

## 栈图

- kiln-cg 对 KIR 里所有 `obj` 类型的变量调用 `declare_var_needs_stack_map`。cranelift-frontend 会在每个调用点之前把活跃的引用溢出到栈槽，调用之后再重新加载，所以 **GC 移动对象后，代码看到的是新地址**。寄存器里不会有跨调用点存活的引用。
- 每个函数编译完后，kiln-cg 读出 `user_stack_maps`，按调用点的返回地址偏移记录下来，并检查每个栈图确实位于某个调用点的返回地址上。JIT 直接用绝对地址注册，AOT 写进模块信息（[codegen.md](codegen.md)）。
- 调试信息用同一组栈槽找变量（[debugging.md](debugging.md)）。栈图、调用点表、调试记录都按返回地址索引，以后可以合并成统一的调用点描述符。

## 编译器必须遵守的规则

- **`raw` 变量不能跨 safepoint 持有堆地址。** 任何调用都是 safepoint。栈图只覆盖 `obj` 变量，raw 变量里的堆地址在 GC 之后会失效。分配之后要在下一个 safepoint 之前给地址加上 tag，存进 `obj` 变量。
- **分配协议**：`kiln_rt_alloc(ctx, bytes, header)` 返回未加 tag 的地址，载荷字全部清零（也就是 fixnum 0），header 已经写好。编译器在下一个 safepoint 之前写完各个字段、加上 tag。分配是 safepoint，所以作为 `unwinds` 函数经过 trampoline 调用，trampoline 的帧指针就是栈遍历的起点。
- **动态环境条目的所有 Lisp 对象字段都要初始化**（没有值时写 0）。
- **分配期间还在传递区里的值**要用 `values_live` 登记（[abi.md](abi.md)）。runtime 函数自己分配多个对象时同理：例如除法先分配余数并登记为 root，再分配商。
- 堆对象不能指向栈帧内部（C5）。

## 内联分配

- context 的 `alloc_cursor` 和 `alloc_limit` 字段是该 context 的 MMTk 默认分配器里 cursor 和 limit 字段的地址，`Context::new` 绑定 mutator 后填入（`gc::bump_pointer_fields`）。分配器属于 mutator，地址不变。
- `emit-alloc`（`lisp/lower.lisp`）对大小为常量、不超过 128 字节（`*inline-alloc-limit*`）的对象生成快路径：读 cursor，加上大小，和 limit 比较；够的话写回 cursor，再写 header 并把其余的字清零；不够才调用 `kiln_rt_alloc`。
- `kiln_rt_alloc` 自己也先直接移动 bump 指针，空间不够时才走 MMTk 的分配函数（MMTk 的分配路径要锁一次 GC 计数的互斥量、查 allocator、调用 `post_alloc`）。
- MMTk 的分配器里 cursor 总是 8 字节对齐。GC 之后 MMTk 会重置分配器，cursor 和 limit 都变成 0，于是下一次分配进入慢路径。生成的代码每次都从内存里读这两个字段，不需要和 runtime 同步。

## 栈和栈段（C2、C8）

`rust/kiln-rt/src/stack.rs`。

- **Lisp 线程**：Lisp 程序不在主线程上跑（主线程只有 8 MiB，以后还要交给 GUI 的平台层，[rust-interop.md](rust-interop.md)）。`run_module` 起一个名为 `lisp` 的线程，栈默认 64 MiB，环境变量 `KILN_STACK_SIZE`（字节数）可调。kiln 编译自己时 Common-boot 的 HIR 求值器给长指令链建 thunk，递归约 3500 层，每层要经过泛函分派、`:around` 方法和 `call-next-method`，约 14 个帧、2.4 KB 栈。
- **栈对象**：用 mmap 分配，下方带一个 guard page，默认 1 MiB，`MAP_NORESERVE`，按需提交物理页（[async.md](async.md) 里“初期方案”的做法）。
- **栈段**：一个 context 的 Lisp 帧分成若干段。每段从一个 trampoline 帧（段顶）延伸到一个 `kiln_enter` 帧（段底）。当前段的两端记在 context 里，挂起的段链接在 `ctx.segments` 上。GC、unwinder、调试信息的走栈都遍历所有段。
- **`(kiln.sys:%call-on-new-stack f arg)`**（只用于测试）：
  1. 把当前段压进 `ctx.segments`；
  2. 在动态环境链上插入一个栈边界条目（kind 4）；
  3. 切换到新栈，并把 rbp 清零，让新栈的 FP 链在这里终止，然后经过 `kiln_enter` 调用 `f`；
  4. 返回时切回旧栈，弹出边界条目和段，释放新栈。
- **跨栈展开**：见 [abi.md](abi.md) 的展开算法。每个栈各自用自己的 FP 链寻找目标帧，展开停在帧标记上（C3）。
- fiber 和 runtime 回调 Lisp 都会用同一套栈段机制：回调时压入一个段即可，但还没有实际的回调路径。
- 栈耗尽：函数入口按 `ctx.stack_limit` 检查，发出 `kiln.sys:stack-exhausted`（`storage-condition`），见 [abi.md](abi.md) 的“Poll 点”。guard page 只兜住检查不到的 Rust 递归。

## Generational GC plan

还没有实现，这一节是设计。测量（自举时 GC 的次数、停顿、存活量、复制量里新老对象的比例）见 [performance.md](../research/performance.md) 的“GC”。结论：SemiSpace 每次回收都把全部存活数据再复制一遍，而编译器的存活集几百 MiB、每次回收之间新分配的对象只有很小一部分活下来，所以 GC 的工作量绝大部分是反复复制老对象。分代 plan 只复制 nursery 里活下来的对象，老对象只在少数几次 full GC 里处理。

### 选哪个 plan

MMTk 有三个可用的分代 plan，都用同一种写屏障（object barrier，见下文），所以屏障做一次，三个都能试：

| plan | nursery | mature | 对 kiln 的影响 |
|---|---|---|---|
| GenCopy | 复制式（bump 分配） | SemiSpace | 分配快路径和现在完全一样；full GC 复制全部存活数据，mature 要预留一半空间，8 GiB 堆实际可用一半 |
| GenImmix | 复制式（bump 分配） | Immix（mark-region，按需整理） | 分配快路径和现在一样；mature 不需要复制预留，full GC 主要是标记 |
| StickyImmix | 不单独分区：新对象直接分配在 Immix 空间里，用 sticky mark bit 区分新老 | Immix | 分配走 Immix 分配器，line 粒度的回收利用；kiln 试过 Immix，比 SemiSpace 慢约 5% |

**选 GenImmix 作为目标，GenCopy 作为第一步。**
- 两者的 nursery 都是 copy space，默认分配器是 `BumpAllocator`：`gc::bump_allocator` 已经按这两个 plan 取 bump 指针，编译出的代码的内联分配（`ctx.alloc_cursor`/`alloc_limit`）不用改。StickyImmix 走 `ImmixAllocator`，等于把 Immix 那 5% 的分配开销带进来。
- GenCopy 的 mature 也是 SemiSpace，所有对象仍然都会移动，和现在的测试覆盖（GC 压力测试专门测移动）一致，最适合先验证屏障是否完整：漏掉一个屏障，nursery GC 就会留下悬空指针，GC 压力测试很快会撞上。
- GenImmix 的 mature 不需要一半的复制预留，同样 8 GiB 的堆可用空间几乎翻倍（现在峰值 RSS 约 10 GB），full GC 只标记、按需整理。屏障验证完之后改为默认。
- Immix 慢的原因（line 粒度的空洞、分配器在 recyclable line 间跳转）只影响 mature 空间的分配，在 GenImmix 里只有晋升时的复制会遇到，不在 mutator 的快路径上。

需要的 binding 改动：`ObjectModel::copy` 已经按 `CopySemantics` 分配（晋升是 `CopySemantics::PromoteToMature`），不用改。Immix 的整理也用 `copy`，`copy_to` 仍不需要。`ObjectModel::GLOBAL_LOG_BIT_SPEC` 已经是 `side_first()`。`kiln_rt_alloc` 和内联快路径都不调用 `post_alloc`：nursery 的 copy space 在没有 `vo_bit` feature 时 `post_alloc` 什么都不做，GenCopy 和 GenImmix 可以照旧；StickyImmix 的 Immix 空间要先核对它的 `post_alloc`。`gc::bump_allocator` 已经按 GenCopy、GenImmix 取 `BumpAllocator`，按 StickyImmix 取 `ImmixAllocator`。

### 屏障的语义

MMTk 的 object barrier（`ObjectBarrier` 加 `GenObjectBarrierSemantics`）：
- 每个对象在 side metadata 里有一个 **unlog bit**（每 8 字节 1 位）。1 表示“未登记”：这个对象是老对象，写它之前要登记。nursery 里的新对象是 0，所以写新对象永远走不到慢路径。
- 对象晋升到 mature 时 MMTk 把它的位置成 1（copy space 的 `post_copy`；LOS 在 nursery GC 时处理新的大对象）。
- **快路径**：向对象 `o` 的某个字写入一个 Lisp 值之后，读 `o` 的 unlog bit；是 1 就进慢路径。
- **慢路径**：原子地把位清零（已经是 0 就什么都不做），把 `o` 放进 mutator 的 modbuf。modbuf 满了或 GC 开始时交给 MMTk。nursery GC 把 modbuf 里的每个对象整个扫描一遍作为根，再把它们的位重新置 1。
- 记的是对象，不是槽：同一个对象在两次 GC 之间写多少次都只登记一次，代价是 nursery GC 要扫描整个对象。大向量（例如哈希表的向量，放在 LOS）被写一次就要全扫；真成为问题时再考虑 field barrier 或按区间登记（`memory_region_copy`）。
- 屏障可以放在 store 之后（post barrier）：kiln 的 GC 是 stop-the-world，只在 safepoint 发生，屏障自身不分配、不是 safepoint，store 和屏障之间不会插进 GC。

位的地址：`GLOBAL_LOG_BIT_SPEC` 是全局 side metadata 的第一个规格，`log_bytes_in_region = 3`、每个区域 1 位，所以对象地址 `a` 的位在字节 `LOG_BASE + (a >> 6)` 的第 `(a >> 3) & 7` 位。`LOG_BASE` 是 MMTk 在 64 位上固定的地址（`GLOBAL_LOG_BIT_SPEC.as_spec().extract_side_spec().get_absolute_offset()`）。它进 `lisp/abi.lisp` 作常量，runtime 启动时断言两边相等，和其他 ABI 常量一样两处同步。

### 快路径的代码

对象 `x` 是带 tag 的值，`u = x - tag`（tag 在编译期已知：cons 是 1，其他是 5）：

```
store [u + off], v
; 只对 MMTk 堆里的对象做 side metadata 检查
t = u - HEAP_START
if t >=u HEAP_SIZE goto outside        ; 静态数据或快照区，见下文
b = load.u8 [LOG_BASE + (u >> 6)]
if (b >> ((u >> 3) & 7)) & 1 goto slow ; 冷路径
...
slow:  call kiln_rt_write_barrier(ctx, x)
```

- x86-64 上约 8 条指令（减法、比较、两个移位、一次字节读、`bt`、两个分支），两个分支几乎总是同一方向。
- **堆范围检查是必须的**：静态数据（模块的数据段，非 PIE 时在低地址）和快照区（`0x3000_0000_0000`）不在 MMTk 的地址范围内，它们的 side metadata 没有映射，直接读会段错误。另一种做法是 runtime 给数据段和快照区映射全零的 log-bit 页，省掉范围检查；但这块地址是 MMTk 的元数据保留区，要先确认 MMTk 不会在那里另作映射，留作以后的优化。
- `kiln_rt_write_barrier` 不是 safepoint，不经过 trampoline，也不需要栈图；它调用 `mutator.barrier().object_reference_write_slow(src, slot, target)`（`slot` 和 `target` 对 object barrier 无用，传任意值即可）。可以在 kiln-cg 里把冷路径放到函数末尾。
- **编译期省掉屏障**：
  - 初始化写（刚分配、中间没有 safepoint 的对象，见下面清单的 B 类）不需要屏障：新对象在 nursery 里，位是 0。
  - 写入的值在编译期已知不是堆指针（fixnum、字符、NIL、T 和其他静态对象、`+unbound+`）时不需要：老对象指向静态对象不会形成 old→young 指针。
  - 目标在编译期已知是静态 symbol（AOT 的 `(:addr sym)`）时不需要：那些字是 static root，每次 GC 都扫描。
- 运行期写入的值是 fixnum 等立即数时可以先跳过（再加一个 tag 检查），是否值得等测出写入值的分布再定。

KIR 只有 `:store` 和 `:store32` 两条写内存的语句（kiln-cg 的 `Stmt::Store`、`Stmt::Store32`，在 `codegen.rs` 里降成普通的 Cranelift store）。建议加一条 `(:store-obj obj tag off val)`：lowering 在需要屏障的地方用它，kiln-cg 负责展开快路径。这样屏障的指令序列只写在 kiln-cg 一处，lowering 只决定“这里要不要屏障”，以后换成 card marking 或 field barrier 也只改 kiln-cg。

### 所有写指针的地方

**A. 需要屏障：向已存在的对象写入可能是堆指针的值**

| 位置 | 操作 | 目标 |
|---|---|---|
| `lisp/primitives.lisp`：`(setf car)`、`(setf cdr)`、`rplaca`、`rplacd` | cons 的 car/cdr | 任何 cons（含快照区的） |
| `lisp/lower.lisp`：`write-cell-ast` | cell（cons）的 car | 堆上的 cell，可能已经是老对象 |
| `lisp/values.lisp`：`emit-nreverse` | cdr | `multiple-value-call` 和 `multiple-value-prog1` 逐个 push 的 cons；push 之间有调用，前面的 cons 可能已经晋升 |
| `lisp/primitives.lisp`：`:set-svref`，内联的 `(setf svref)` 和 `%set-aref-1` 的 simple-vector 快路径 | 向量元素 | 堆或快照区的 simple-vector |
| `lisp/primitives.lisp`：`:set-symbol-function`、`:set-symbol-setf-function`、`:set-symbol-plist`、`:set-symbol-package`、`:set-symbol-global-value` | symbol 的字 2–7 | 堆 symbol（`make-symbol`、运行期 `intern`）、快照区 symbol、静态 symbol（不需要，运行期按地址范围跳过） |
| `lisp/primitives.lisp`：`emit-undefined-function-cells`（`:make-symbol`、`:init-function-cells`、`:unbind-function`、`:unbind-setf-function`） | 新分配的 undefined-function 对象写进函数格、setf 函数格 | 即使在 `:make-symbol` 里也不是初始化写：symbol 分配之后又分配了 undefined-function 对象，中间是 safepoint |
| `lisp/lower.lisp`：`emit-set-symbol-value` 的全局分支 | 特殊变量的全局值 | 静态 symbol（AOT）或字面量 symbol（JIT、eval） |
| `lisp/lower.lisp`：常量名的 `(setf fdefinition)`（`function-cell-place`） | 函数格或 setf 函数格 | 同上 |
| `lisp/lower.lisp`：`emit-note-symbol-table` | `*module-symbol-tables*` 的值格 | 同上 |
| `lisp/lower.lisp`：`set-static-environment-ast` | 闭包的 env 字 | `labels` 先分配所有闭包，再求值并写入 env，中间可能有调用：不是初始化写 |
| `lisp/primitives.lisp`：`:set-instance-rack` | instance、funcallable instance 的 rack | `change-class`、类重定义 |
| `lisp/primitives.lisp`：`:set-standard-instance-access` | rack 的字：槽（位置 ≥ 0）、class（−3）、stamp（−2）、有效槽列表（−1） | CLOS 的所有槽写入，`defstruct` 的访问器也经过它 |
| `lisp/primitives.lisp`：`:set-funcallable-instance-function` | funcallable instance 的安装函数 | |

`REPLACE`、`FILL` 等库函数都经过上面的原语，没有直接的块复制；KIR 没有 CAS、交换或 memcpy。

**B. 初始化写：刚分配的对象，分配和写入之间没有 safepoint，不需要屏障**

- `emit-alloc` 的内联快路径（header 和清零）、`emit-cons`（car、cdr；`cons`、`list`、`list*`、cell、`progv` 的列表、出口 token、`&rest` 列表、`emit-push-values` 都经过它）。
- 闭包的入口地址（代码地址，不是 Lisp 值）。
- `:make-string`（码点，不是指针）、`:make-simple-vector` 的填充循环（循环里没有 poll，不会有 GC）。
- `:make-symbol` 的 name、package、function、setf（NIL）、value（`+unbound+`）、plist（NIL）；undefined-function 对象的入口和 env[0]。
- `:make-complex`、`emit-allocate-rack` 的 class 字、`:allocate-general-instance` 和 `:allocate-general-funcallable-instance` 的 rack 等字。
- runtime：`gc::alloc` 的 header，`bignum.rs` 写数字，`number.rs` 写 double 的位和 ratio 的分子分母（ratio 刚分配）。

要保持的规则（写进“编译器必须遵守的规则”）：**初始化写只能发生在分配和下一个 safepoint 之间**。现在的代码满足；以后的优化（例如把 `make-symbol` 的多次分配合并、内联更多构造函数）如果在分配之后插入调用，就必须改用带屏障的写。还有一点：nursery 对象的 unlog bit 是 0 只对 nursery 成立。大对象（> `max_non_los_default_alloc_bytes`）直接分配在 LOS，在生成代码看来同样是新对象；MMTk 的分代 plan 不给新分配的 LOS 对象置位（`unlog_allocated_object` 只有 ConcurrentImmix 用），nursery GC 时才把活下来的大对象置位，所以对 LOS 新对象的初始化写也不需要屏障。实现时用 GC 压力测试确认。

**C. 写的是根，不是堆对象：不需要屏障**

- context 的字段：`dynenv`、`values_live`、传递区 `values`、`poll_flag`、`stack_base_fp`。
- 动态环境条目（在栈上；`tag`、`pend_value` 是根）、TLS 表（`ctx.tls`，已分配的项是根）。
- `load-time-value` 的格子（`kiln_ltv_*`）、运行期编出的模块的字面量字（`kiln_literals`），都是 static root。
- 栈帧的槽（栈图）。

**D. runtime 写已存在的对象**

- 只写非指针：`kiln_rt_identity_hash` 写 header 的哈希位（堆、静态、快照区对象都有），`kiln_rt_tls_index` 写 symbol 的 TLS 下标（fixnum），`kiln_rt_fd_read`、`store_octets` 写 octet（fixnum），`list_frames` 写帧指针（8 字节对齐，看起来是 fixnum）。
- `object::init_statics` 写 NIL、T 的字，`image::load` 写回 static root：都发生在 MMTk 初始化之前或写的是根。
- 没有 runtime 代码把堆指针写进已存在的堆对象。以后加这样的代码（例如 runtime 里的哈希表、弱引用表、finalizer 队列）必须调用同一个慢路径函数。

### 静态对象、快照区和 remembered set

- **静态 symbol 的可变字**（字 2–7）、NIL 和 T 的几个字、`load-time-value` 格子都登记为 static root，每次 GC（包括 nursery GC）都扫描，所以写它们不需要屏障，快路径按地址范围跳过。代价是每次 nursery GC 都扫描全部 static root；自举时这个数量见 performance.md，扫描一遍远小于一次 nursery GC 的复制。以后要省掉，可以给数据段也做 card table（同下）。
- NIL 和 T 的值格现在没有登记为 root：`(setf (symbol-value nil) <堆对象>)` 本来就不允许，保持不变。
- **编译器输出的常量**（cons、向量、字符串等）不可变，GC 不扫描。对字面量的破坏性修改本来就是未定义行为，现在写进堆指针也已经不安全，分代以后不变。
- **快照区**：现在每次 GC 线性扫描整个快照区找指向堆的字（编译器会话的快照约 360 MB）。nursery GC 很频繁，每次都扫描整个快照区就抵消了分代的收益，所以快照区要和屏障一起改成 card table：
  - 快照区按 512 字节分 card，每 card 一个字节的脏标记，加载时分配；另加一张“每个 card 里第一个对象的起点”的表（加载时扫一遍建立，快照里的对象是连续排列的）。
  - 快路径的范围检查失败、地址又在快照区里时，内联地把对应 card 标脏（一次移位和一次字节写），不调用 runtime。
  - nursery GC：只扫描脏 card 里的对象，作为根交给 MMTk；扫描完清掉标记（nursery GC 之后 nursery 里的存活对象都已晋升，快照区不再有指向 nursery 的指针）。
  - full GC：仍像现在一样扫描整个快照区（mature 对象会移动或需要标记，快照区里所有指向堆的字都是根），然后清掉全部标记。full GC 很少，这一遍可以接受。
  - 保存快照时 card 表不保存，加载时全部置为干净。
- **栈、TLS、传递区、动态环境链**都是根，每次 GC 扫描，不需要屏障（栈图本来就覆盖所有帧，nursery GC 也要遍历整个栈；栈很深时可以以后再做 return barrier 或栈水位标记）。

### 屏障的代价

- 每个 A 类写多出约 8 条指令和两个几乎不会预测失败的分支，加一次 side metadata 的字节读（每 64 字节堆共享一个元数据字节，局部性好）。Java 上的测量（Blackburn 和 Hosking 等人的 barrier 研究）中 object-remembering barrier 的 mutator 开销在 1–2% 左右。
- kiln 的写比 Java 程序更集中在 CLOS 的槽写入（Iconoclast 遍历 AST 时的 `set-slot`、实例初始化）和哈希表的向量：估计 mutator 开销 1–3%。编译期省掉初始化写和非指针值的写，能去掉相当一部分。
- 代码体积：每个屏障约 30 字节，冷路径另外算；A 类写在 kernel 和 CLOS 里有几千处。
- 收益见 performance.md：GC 约占自举 CPU 时间的六分之一，其中绝大部分是反复复制老对象。

### 实施步骤

1. **只加慢路径和常量**（runtime）：`kiln_rt_write_barrier`、`LOG_BASE` 和堆范围常量、启动时检查常量和 MMTk 的一致；`gc.rs` 的 `register` 把 `LOG_BASE` 交给 kiln-cg（JIT）。单元测试：对一个晋升过的对象调用慢路径，modbuf 非空。
2. **KIR 加 `:store-obj`，kiln-cg 展开快路径**。先让 lowering 对所有 A 类写都用它（不做编译期省略），plan 仍是 SemiSpace：SemiSpace 不映射 log bit 的元数据，所以这一步要在快路径前加“plan 是否分代”的 ctx 标志，或者直接用 GenCopy 测。测 mutator 的开销（自举时间，`perf` 看屏障指令的占比）。
3. **GenCopy 跑通**：`MMTK_PLAN=GenCopy` 跑 `tools/test.sh`（GC 压力那一遍用 1 MiB 堆，nursery 很小、晋升很频繁，最能暴露漏掉的屏障），再跑自举。漏掉屏障的典型症状是 nursery GC 之后老对象里留着 from-space 的地址：在 debug 构建里加一个校验（`KILN_GC_VERIFY=1`：每次 nursery GC 之后遍历 mature 空间和快照区，确认没有指向 nursery 的指针），定位到具体的对象和槽。
4. **新测试**：`tests/m0/gc-gen.lisp`（或类似名字）专门造 old→young 指针：建一个大的长寿命结构（向量、cons 链、实例、闭包 env、symbol 值格和 plist、heap symbol 的函数格），多次 `(kiln.sys:%gc)` 让它晋升，然后把新分配的对象写进去，再 GC 若干次并检查内容；每一类 A 类写各覆盖一次。快照测试（`tests/m6/clos-image`）加上写快照区对象再 GC。
5. **快照区的 card table**，替换 `image::heap_slots` 的全量扫描（nursery GC 只扫描脏 card）。`KILN_COMPILER=... tools/test.sh` 那条路径会从 360 MB 的快照启动，是现成的性能测试。
6. **编译期省略屏障**（初始化写、非指针值、静态 symbol），每省一类都跑一遍 GC 压力测试。
7. **换到 GenImmix**，比较 GenCopy、GenImmix、StickyImmix 的自举时间、GC 时间和峰值 RSS；调 nursery 大小（`MMTK_NURSERY`，默认按堆比例）。默认 plan 改为最快的那个，`MMTK_PLAN` 仍可改回 SemiSpace 对照。
8. 更新本文件、[abi.md](abi.md)（`:store-obj` 和常量）、[codegen.md](codegen.md)、roadmap。

## 测试

`tools/test.sh` 对每个用例跑三遍：JIT、JIT 加 GC 压力（`MMTK_GC_TRIGGER=FixedHeapSize:1048576`，迫使频繁的移动式回收；CLOS 测试用 8 MiB，慢测试和快照测试另有设定）、AOT。`tests/m0/gc.lisp` 覆盖跨 GC 存活的列表、深递归中每一帧都持有活对象、堆对象作 catch tag、throw 的值是堆对象并经过一个会分配的 cleanup。`tests/m0/stacks.lisp` 覆盖多栈：新栈和旧栈上的活数据跨越 GC、嵌套 5 层新栈、从新栈 throw 到旧栈上的 catch 并依次执行两边的 cleanup、跨 3 层栈的 throw、展开之后段信息已经恢复。
