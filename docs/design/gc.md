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
- 栈溢出：有 guard page，但还没有把 SIGSEGV 转成 `storage-condition`，context 里也还没有 stack limit。

## 测试

`tools/test.sh` 对每个用例跑三遍：JIT、JIT 加 GC 压力（`MMTK_GC_TRIGGER=FixedHeapSize:1048576`，迫使频繁的移动式回收；CLOS 测试用 8 MiB，慢测试和快照测试另有设定）、AOT。`tests/m0/gc.lisp` 覆盖跨 GC 存活的列表、深递归中每一帧都持有活对象、堆对象作 catch tag、throw 的值是堆对象并经过一个会分配的 cleanup。`tests/m0/stacks.lisp` 覆盖多栈：新栈和旧栈上的活数据跨越 GC、嵌套 5 层新栈、从新栈 throw 到旧栈上的 catch 并依次执行两边的 cleanup、跨 3 层栈的 throw、展开之后段信息已经恢复。
