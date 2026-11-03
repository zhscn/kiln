# 02 底层约束

这些约束从第一行代码起就必须遵守。它们大多数在早期没有直接用处，但一旦写死，以后加 GC 精确扫描、异步、抢占或重定义时，就要改动整个 runtime 和编译器。

每条约束都写了理由，以及以后哪些功能依赖它。

## C1 动态环境全部通过 context 指针访问

**约束**

- special 变量的动态值、handler 链、restart 链、catch 链、unwind-protect 链、当前 dynamic-extent 帧链，全部挂在一个 `context` 对象上。
- 编译后的代码通过固定寄存器或第一个隐式参数拿到 `context`。
- runtime 不能用 Rust 的 `thread_local!` 或全局变量保存上述状态。

**special 变量的实现**：采用 TLS 索引方案（参考 SBCL）。M2 已实现，见 [08 §5.2](08-m2-front-end.md#52-特殊变量c1-的-tls-下标方案)。

- 每个 symbol 在第一次被动态绑定时分配一个 index。
- 每个 context 有一张动态值表，按 index 查找。表项为空时回退到 symbol 的全局值。
- 绑定和解绑在 context 的绑定栈上记录旧值。

**否决的方案**：浅绑定加切换时回滚。它的切换开销和绑定深度成正比，fiber 频繁切换时代价不可接受。

**依赖它的功能**：多线程、fiber 和续延的切换。切换只需换一个指针，O(1)。

## C2 不假设一个 OS 线程只有一个栈

**约束**

- 栈抽象成 runtime 对象，记录上下界、guard page 和所属 context。
- GC 扫描 root 时遍历一个栈列表，不能直接取当前线程的栈。
- 栈溢出检查读 context 里的 limit。
- 栈溢出要 signal `storage-condition`，能进 debugger，不能直接 segfault。

早期每个线程只有一个栈，列表里只有一项。

**依赖它的功能**：fiber、续延、拷栈。

## C3 非局部退出能停在帧标记上

**约束**

- `throw`、`return-from`、`go` 跨帧时，以及 unwind，都实现成“展开到某个帧标记为止”。
- 不能依赖“栈底就是线程入口”之类的假设。
- 展开时按顺序执行沿途的 `unwind-protect` cleanup、恢复 special 绑定、弹出 handler 和 restart。

**已决定（M0）**：用 Cranelift 的 `try_call` 和异常表，加上 kiln 自己的 unwinder，详见 [06-m0-abi.md §6](06-m0-abi.md#6-非局部退出c3-的决定)。下表保留当时的比较。

| 方案 | 优点 | 缺点 |
|---|---|---|
| Cranelift 的 `try_call` 和异常表 | 正常路径零开销 | 依赖较新的 Cranelift 特性，需要确认 JIT 和 object 两条路径都支持 |
| 返回值带退出标记，每个调用点检查 | 实现简单，可移植 | 每个调用点多一次分支 |
| 类似 setjmp/longjmp 的保存点 | 容易理解 | 和精确栈图、帧可搬动（C5）配合不好 |

**依赖它的功能**：fiber 取消（展开到 fiber 的入口标记）、续延的 prompt 边界、debugger 的 abort restart。

## C4 从第一天起插入 poll 点

**约束**

- 编译器在函数入口和循环回边插入 poll。
- poll 检查 context 里的一个标志字，为零时直接继续（快路径）。不为零时调用 runtime 的慢路径。
- 慢路径按标志位分派。

| 标志位 | 用途 | 何时需要 |
|---|---|---|
| GC 请求 | 停在 safepoint，配合 MMTk | M1 |
| REPL 中断 | 进入 debugger（C-c C-c） | M6 |
| 重定义屏障 | 类或方法表更新时 stop-the-world | M4 |
| 抢占 | fiber 时间片用完时让出 | 异步阶段 |

同一套机制承担四件事。栈图也只需要在调用点和 poll 点生成。

**配套约束**：提供 `without-interrupts` 和（以后的）`without-preemption`。持锁或修改 runtime 内部结构的代码在这些区域里只延迟处理标志，不响应。

## C5 精确栈图，栈帧可搬动

**约束**

- 所有调用点和 poll 点都生成 stack map（使用 Cranelift 的 user stack maps），GC 精确扫描 Lisp 帧。
- 堆对象不能持有指向栈帧内部的指针。
- `dynamic-extent` 分配的对象不能逃逸到堆里，编译器负责检查。证明不了不逃逸时，退回堆分配。
- 不对 Lisp 帧做保守扫描。

**依赖它的功能**：

- MMTk 的移动式 GC（栈上的指针能被修正）；
- Loom 式拷栈：fiber 挂起时把帧拷到堆上；
- 一次性续延。

## C6 FFI 一律经过 trampoline

**约束**

- 从 Lisp 调用 native 代码，或 native 回调进 Lisp，都必须经过 runtime 生成的 trampoline。
- trampoline 在 context 上切换状态：`in-lisp` 或 `in-native`。处于 `in-native` 状态的线程视为 GC-safe，GC 不需要等它（类似 JNI）。
- native 帧里不能直接持有 Lisp 对象指针，只能通过 handle 引用。

早期只切换状态位，其他什么都不做。

**依赖它的功能**：

- GC 不必等待长时间阻塞在 C 里的线程；
- 以后的 sysmon：检测到 FFI 调用阻塞太久，就把这个 OS 线程让给它，另起线程继续跑调度器。“阻塞检测”和“GC 协作”用同一个状态机。

**待定**：栈上夹着 C 帧时（FFI 回调进 Lisp），是只允许用 handle，还是对 C 帧区域做保守扫描。倾向只允许用 handle。

## C7 condition 的 handler 查找由 runtime 自己控制

**约束**

- handler cluster 和 restart 是普通的数据结构，挂在 context 的链上（见 C1）。
- `signal`、`invoke-restart` 的遍历逻辑由 kiln 自己实现，不借用宿主语言或 C 的机制。
- handler cluster 带一个类型字段，为以后的 handler 类型留位置。

**依赖它的功能**：能捕获一次性续延的 handler（见 [03-async.md](03-async.md)），以及 debugger 列出某个 fiber 的 restart。

## C8 早期验证：`%switch-stack` 测试

**已完成（M1）**：实现为 `%call-on-new-stack`，见 [07-m1-gc.md §8](07-m1-gc.md#8-栈和栈段c2c8)。第 3 项的语义定为：handler 查找沿动态环境链进行，与栈无关，所以在新栈上 signal 时可以找到旧栈上建立的 handler（等 condition 系统实现后再测）。

在 runtime 的测试里实现一个最小的 `%switch-stack` 原语，不对用户暴露。它在 M1 阶段完成，用来尽早验证 C2、C3、C5：

1. 两个栈上各有存活对象，触发一次（移动式）GC，确认两个栈都被正确扫描，指针也被修正。
2. 在切换后的栈上 `throw` 到分界点，确认 `unwind-protect` 的 cleanup 执行了，并且展开在分界点停下，没有越界。
3. 在切换后的栈上 signal 一个 condition，handler 在另一个栈上建立，确认查找结果符合预期（这个行为的语义需要先定）。

代码量估计几百行。这些假设在异步阶段之前很难被别的测试覆盖，越晚发现错误，代价越大。

## 检查清单

写 runtime 或编译器代码时逐项对照：

- [ ] 新的动态状态挂在 context 上了吗？（C1）
- [ ] 有没有隐含“当前线程只有一个栈”的假设？（C2）
- [ ] 新的非局部控制流能停在帧标记上吗？（C3）
- [ ] 新增的循环结构有 poll 点吗？（C4）
- [ ] 有没有让堆对象持有栈内指针？（C5）
- [ ] native 调用经过 trampoline 了吗？（C6）
- [ ] 新的 handler 或 restart 机制是不是放在 runtime 自己的数据结构里？（C7）
