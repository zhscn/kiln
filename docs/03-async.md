# 03 异步模型

**状态**：方向已定。ANSI 自举完成之前不实现，但底层约束必须遵守（见 [02-runtime-constraints.md](02-runtime-constraints.md)）。

## 决定

- **对外语义**：一次性定界续延（one-shot delimited continuation），和 CL 的 condition 系统统一，风格类似 OCaml 5 的 effect handler。
- **底层实现**：stackful 栈切换。
- **调度器**：作为库实现在续延之上，不是语言的核心部分。
- **stackless 状态机**：只作为 seal 之后的一种优化，不对用户暴露。

## 为什么必须是 stackful

ANSI CL 里大量构造的生命周期挂在栈上：

- special 变量的绑定；
- `unwind-protect`；
- `handler-bind`、`handler-case`、`restart-case`；
- `catch`/`throw`、`block`/`return-from`、`tagbody`/`go`；
- `dynamic-extent`。

stackful 保留了整个栈，这些构造在挂起和恢复之后自然正确。debugger 也能看到完整的栈。

### 否决：stackless async/await

编译器把 async 函数改写成状态机，这是 Rust、C#、JS 的做法。CL 里已有的尝试是 cl-cont 和 cl-async + blackbird。

否决的理由：

1. **函数染色在 CL 里格外严重。** 标准库到处接收函数参数：`mapcar`、`sort`、`find-if`、`maphash`、`reduce`，还有 `print-object` 方法、reader macro、method combination、`call-next-method`。回调里一旦要 `await`，整条链都得是 async，而标准函数都不是。结果要么维护两套标准库，要么规定这些地方不能挂起。
2. **每个动态范围构造都要补一份跨挂起点的规范**：动态环境存进状态机帧并在恢复时重装，取消时按 drop 语义执行 cleanup，handler 沿 awaiter 链查找，`dynamic-extent` 对象改为堆分配。
3. debugger 需要重建逻辑栈。

### 其他被否决的方案

| 方案 | 否决理由 |
|---|---|
| 只用 OS 线程和阻塞 I/O | 语义正确，但线程数受限，难以取消，没有结构化并发。仍然作为基础设施保留 |
| 事件循环加回调 | condition 上下文在回调边界丢失，出错时没有可用的栈，和 kiln 的核心卖点冲突 |
| 全程序 CPS | 整体性能下降，FFI 和 C 栈交互困难，栈图复杂 |
| 多次可重入续延（`call/cc`） | 和 `unwind-protect` 的语义冲突，实现代价高，没有必要 |

## 和 condition 系统的统一

CL 的 condition 系统本来就是可恢复的 effect：`signal` 时，handler 在信号点之上运行，可以选择 restart 继续执行。它唯一缺的能力是**捕获续延**，也就是让 handler 能把信号点之后的计算挂起，交给别人以后恢复。

kiln 增加一种能捕获一次性续延的 handler。示意（API 待定）：

```lisp
(with-prompt (p)
  (handler-bind ((io-wait
                   (lambda (c)
                     (suspend-to p (lambda (k) (scheduler-park k (io-wait-fd c)))))))
    (read-line socket)))
```

`yield`、`await`、generator、取消都用这一个原语表达：

| 功能 | 表达方式 |
|---|---|
| 阻塞 I/O 挂起 | signal 一个 `io-wait` 类的 condition，调度器的 handler 捕获续延并挂起 |
| generator | `yield` signal 一个 condition，消费者的 handler 捕获续延 |
| fiber 取消 | 不恢复续延，而是从续延内部展开到 prompt，沿途执行 cleanup |
| 调度器 | 一个建立 prompt 和 handler 的普通库 |

续延是一次性的：恢复两次会 signal 错误。丢弃一个没有恢复的续延时，runtime 必须展开它，执行 cleanup，或者至少在开发期报警告。

## 语义要点

### special 变量

每个续延有自己的动态值表（见 C1）。挂起时保存，恢复时重装，O(1)。

**待定**：续延恢复时，prompt 之外的那部分动态环境用捕获时的还是恢复时的？倾向用恢复点的，这和 OCaml 5 的行为一致，但需要写例子验证直觉。

### unwind-protect 和取消

- 取消按非局部退出处理：从续延内部展开到 prompt，所有 cleanup 都执行。
- cleanup 里再次挂起：允许，但取消期间的挂起有超时限制（参考 Trio 的 shielded cancel scope）。

### 结构化并发

参考 Trio 的 nursery 和 Java Loom 的 StructuredTaskScope：

- 子任务必须在 scope 内创建，scope 退出时等待所有子任务结束。
- 子任务出错时，取消同一 scope 内的兄弟任务，错误传播给 scope 的所有者。
- 不支持脱离 scope 的“野”任务，避免 Go 那样的 goroutine 泄漏。

**待定**：子任务出错时，是先在子任务内进 debugger（不退栈），还是先传播？倾向开发期先进 debugger：挂起出错的这个 fiber，其他 fiber 照常运行，用户可以选择 restart 就地修复，或者选择“传播给 scope”。

### debugger 和 SLY/SLIME

这是 kiln 能超过 Go 的地方：

- fiber 出错时只挂起这一个 fiber，进入 debugger 时可以看到完整的栈和 restart 列表。
- 修好后选一个 restart，fiber 就地继续。
- 把 Swank/SLYNK 的线程视图扩展成 fiber 视图：列出 fiber、切换到某个 fiber 看栈、打断某个 fiber。
- REPL 中断（C-c C-c）走 poll 点（C4），可以打断任意 fiber。

## 调度器（库）

- M:N 调度：每个 OS 线程一个调度器，加上 work stealing。
- I/O：Linux 用 io_uring，BSD/macOS 用 kqueue。
- 阻塞的 FFI 调用：fiber 在 FFI 期间钉在当前 OS 线程上。sysmon 检测到调用阻塞过久，就把这个线程让给它，另起一个线程继续跑调度器（参考 Go 的 sysmon）。依赖 C6 的状态机。
- 抢占：poll 点（C4）检查时间片标志。纯协作式调度里，一个死循环会饿死整个调度线程，poll 点抢占解决这个问题。

## 栈的实现

| 阶段 | 方案 | 说明 |
|---|---|---|
| 初期 | 每个 fiber 用 mmap 预留一大块虚拟地址，按需提交物理页，加 guard page | 实现最简单，64 位地址空间够用，fiber 很多时多占一些内存 |
| 以后 | Loom 式拷栈：挂起时把栈帧拷进堆上的 stack chunk 对象，由 MMTk 管理，恢复时按需拷回 | 每个挂起的 fiber 内存占用小。依赖 C5（精确栈图、栈内无内部指针） |

否决分段栈：有 hot split 问题（Go 早期的教训）。

## seal 之后的 stackless 优化

WPO 阶段如果能证明某个异步函数满足下列条件，就编译成状态机，省掉栈切换和栈内存：

- 所有挂起点都在函数自身的帧内；
- 挂起点不跨越高阶函数调用；
- 挂起点不处在未内联的泛函数调用里。

用户可见的语义不变。封闭世界让这种分析可以做。

## 参考：.NET 的 runtime async

依据 dotnet/runtime 源码（commit 59e1f8f3a95，2026-11）的阅读，未经运行验证。主要来源：`docs/design/specs/runtime-async.md`、`docs/design/coreclr/botr/runtime-async-codegen.md`、`clr-abi.md` 的 Async 一节、JIT 的 `async.cpp`、CoreLib 的 `AsyncHelpers.CoreCLR.cs`。

它是 **stackless** 的，但状态机不由 C# 编译器生成，而是 JIT 在正常编译之后、lowering 之前变换出来的。
- **调用约定**：
  - 多一个隐藏参数 `Continuation`：普通调用传 null；非 null 表示"从这里恢复"，其他参数都不用。
  - 多一个隐藏返回值，放在一个普通结果不用的寄存器里（x64 是 `rcx`）：null 表示正常完成，非 null 表示"我挂起了"，做法类似 Swift 的错误寄存器。
  - 不挂起的 await 只多一次判空加分支。
- **两种变体**：返回 Task 的方法都有普通变体和 async 变体，缺的那个由运行时自动生成桥接。函数染色仍然存在，同步代码只能拿到 Task。
- **挂起是惰性、逐帧的**：叶子发现任务没完成，就把 continuation 放进那个返回寄存器；沿栈往外，每个 async 调用者在自己的挂起块里：
  - 把**按 liveness 算出的活变量**存进自己的 continuation 对象。布局是精确的，引用排在前面，GC 把它当普通对象扫描。
  - 把它挂到链上，再返回自己的 continuation。
  - 一个方法所有的 await 共用一种布局。恢复后再次挂起时复用原来的对象，只重存变过的变量，所以循环里的 await 只分配一次。
- **恢复不重建原生栈**：
  - 调度器（`DispatchContinuations`）一次恢复一帧：经生成的恢复桩进入方法，方法按 `State` 跳到对应的恢复点，重新载入变量。
  - 这一帧完成后返回调度器，不返回它逻辑上的调用者；结果写进调用者 continuation 里的结果槽。
- **异常**：只有 await 处在 try 里面的帧才有异常槽。恢复后抛出的异常沿链找到第一个有异常槽的帧，在那里重新抛出；没有 handler 的帧直接跳过，不恢复。
- **动态环境**：`ExecutionContext`（含 `AsyncLocal`）是不可变的映射，挂起时只存一个指针，恢复前装回去。
- **禁止**：跨挂起点的 byref、`Span`、钉住的局部变量、`stackalloc`，以及在 catch、finally 里 await。
- **调试**：每个挂起点有调试信息，记录每个被存变量在 continuation 里的位置，所以调试器能显示挂起帧的变量。TLS 里有指向调度器记录的指针，从它可以找到整条逻辑栈。

**对 kiln 的取舍**：

| .NET | kiln |
|---|---|
| 不挂起时零分配，只多一次判空 | 印证"stackful 为默认、stackless 只做 seal 后优化"的决定：它的代价是染色、禁止跨挂起点的构造、恢复后没有逻辑调用者的原生帧，这些正是本文否决 stackless 的理由 |
| 每帧由自己的代码按 liveness 保存活变量，布局精确 | 可以替代 Loom 式拷栈里的"原样拷贝整段栈"。栈图已经给出每个调用点的活值，seal 时可以为每个调用点生成保存和恢复代码；做不到的地方仍然整段拷贝。调试信息记录变量在栈块里的位置（docs/17） |
| 由调度器逐帧恢复，结果写进调用者的槽 | 对应 Loom 的"按需解冻"：恢复时只解冻最里层一帧，返回时再解冻下一帧，恢复只需要常数量的栈操作 |
| 复用 continuation，只重存变过的值 | 拷栈方案里，再次冻结时复用栈块，只重写解冻后改过的槽 |
| 只有带 handler 的帧才有异常槽 | 冻结的栈上做非局部退出时，按栈图标出处在 `unwind-protect`、`handler-bind`、`catch` 里的帧，其余的跳过、不解冻 |
| 动态环境是不可变映射，挂起时只存一个指针 | kiln 的特殊变量是浅绑定（TLS 值格加绑定栈）。stackful 时每个 fiber 换一整个绑定栈；seal 后的 stackless 区域需要能整体换出的绑定环境。目标是"每次挂起只换一个指针" |
| 隐藏的"已挂起"返回值 | seal 后 stackless 区域的调用约定可以照搬：用多值返回或 ctx 上的一个字段作为信号，配合栈图 |
| 不支持的构造只在挂起路径上禁止 | seal 时的 stackless 分析可以用同样的划分：挂起路径上没有这些构造的调用图区域才变换，其他地方仍是 stackful |

## 待定问题

- 捕获续延的 handler 的具体 API：是扩展 `handler-bind`，还是新增一个 `with-effect-handler`？
- 调度器作为标准库的一部分，还是作为独立的系统？
- 续延跨 OS 线程迁移（work stealing）时，处于 `without-preemption` 区域或持有 OS 锁的续延如何处理？
- 一个 fiber 在 debugger 里挂起时，持有的锁和它所在 scope 的取消要怎么处理？
