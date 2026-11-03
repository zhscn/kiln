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

## 待定问题

- 捕获续延的 handler 的具体 API：是扩展 `handler-bind`，还是新增一个 `with-effect-handler`？
- 调度器作为标准库的一部分，还是作为独立的系统？
- 续延跨 OS 线程迁移（work stealing）时，处于 `without-preemption` 区域或持有 OS 锁的续延如何处理？
- 一个 fiber 在 debugger 里挂起时，持有的锁和它所在 scope 的取消要怎么处理？
