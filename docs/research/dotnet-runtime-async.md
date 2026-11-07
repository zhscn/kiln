# .NET 的 runtime async

**日期**：2026-11。依据 dotnet/runtime 源码（commit 59e1f8f3a95，2026-11）的阅读，未经运行验证。

主要来源（dotnet/runtime 仓库里的路径）：`docs/design/specs/runtime-async.md`、`docs/design/coreclr/botr/runtime-async-codegen.md`、`clr-abi.md` 的 Async 一节、JIT 的 `async.cpp`、CoreLib 的 `AsyncHelpers.CoreCLR.cs`。

## 机制

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

## 对 kiln 的取舍

kiln 的异步模型见 [async.md](../design/async.md)。

| .NET | kiln |
|---|---|
| 不挂起时零分配，只多一次判空 | 印证"stackful 为默认、stackless 只做 seal 后优化"的决定：它的代价是染色、禁止跨挂起点的构造、恢复后没有逻辑调用者的原生帧，这些正是本文否决 stackless 的理由 |
| 每帧由自己的代码按 liveness 保存活变量，布局精确 | 可以替代 Loom 式拷栈里的"原样拷贝整段栈"。栈图已经给出每个调用点的活值，seal 时可以为每个调用点生成保存和恢复代码；做不到的地方仍然整段拷贝。调试信息记录变量在栈块里的位置（[debugging.md](../design/debugging.md)） |
| 由调度器逐帧恢复，结果写进调用者的槽 | 对应 Loom 的"按需解冻"：恢复时只解冻最里层一帧，返回时再解冻下一帧，恢复只需要常数量的栈操作 |
| 复用 continuation，只重存变过的值 | 拷栈方案里，再次冻结时复用栈块，只重写解冻后改过的槽 |
| 只有带 handler 的帧才有异常槽 | 冻结的栈上做非局部退出时，按栈图标出处在 `unwind-protect`、`handler-bind`、`catch` 里的帧，其余的跳过、不解冻 |
| 动态环境是不可变映射，挂起时只存一个指针 | kiln 的特殊变量是浅绑定（TLS 值格加绑定栈）。stackful 时每个 fiber 换一整个绑定栈；seal 后的 stackless 区域需要能整体换出的绑定环境。目标是"每次挂起只换一个指针" |
| 隐藏的"已挂起"返回值 | seal 后 stackless 区域的调用约定可以照搬：用多值返回或 ctx 上的一个字段作为信号，配合栈图 |
| 不支持的构造只在挂起路径上禁止 | seal 时的 stackless 分析可以用同样的划分：挂起路径上没有这些构造的调用图区域才变换，其他地方仍是 stackful |
