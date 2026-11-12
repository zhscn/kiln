# Rust interop

Rust interop 为 Lisp 与 Rust 提供受控的调用、对象和生命周期边界。首个使用者是编译器：Lisp 负责语义前端，Rust 接手 MIR 分析与降级。封装先于 MIR 接入实现，GUI 和其他 Rust 宿主模块随后复用。本文规定目标接口；当前 `kiln_rt_jit` 等低级 runtime 入口尚未组成这套安全封装。

## 层次与 ABI

计划中的 `kiln-interop` 提供安全 Rust API，底层使用 `extern C` 服务表。跨边界只交换固定宽度标量、带长度的缓冲区、opaque handle 和明确签名的函数指针；Rust 的 `Vec`、`String`、`Result`、trait object 和 Rust ABI 不进入稳定边界。

服务表头包含 major/minor、表大小、能力位和 runtime ABI 指纹。major 不兼容拒绝连接，新增可选服务通过大小与能力检测协商。编译请求有独立 schema 版本，见 [编译协议](compiler-protocol.md)。项目整体仍遵守 [ABI 版本政策](abi-policy.md)，不因此承诺跨发行版本的二进制兼容。

一个进程只有一份 kiln runtime、GC 和对象世界。静态模块通过显式注册入口连接同一服务表；交付时汇总为唯一链接产物。不能让各个 Rust 库各自链接并初始化一份 runtime。

## roots 与对象访问

短期引用放入作用域 `RootFrame`，长期引用使用可显式释放的持久 handle。handle 带所属 runtime 和代次校验，释放后不能重新解释为另一对象。移动 GC 更新 root 槽，Rust 持有稳定的 handle 身份，每次访问重新解析；不得长期保存 tagged word 或对象内部地址。

借用对象内容必须持有明确的 NoGc 访问保护，并遵守 mutator 状态与 safepoint 协议。Rust 生命周期只约束 Rust 借用，不能独自阻止其他线程发起移动 GC。保护区内禁止分配、调用 Lisp、poll 或其他可能 safepoint 的操作；需要这些服务时先结束借用，再通过 root 重新取得对象。

字符串 API 区分 Lisp 字符存储和 UTF-8 转换：原生字符串不能直接视作 `&str`，一般数组也不能假设为连续字节切片。API 提供受保护的专用视图或由调用者持有的复制缓冲区。

每份跨边界缓冲区由分配方提供释放函数。返回值、多值和 condition 对象也必须在返回前进入受管理的 roots。错误、取消和 panic 路径与成功路径使用同一所有权规则。

## 调用与非局部退出

完成协议区分正常多值、结构化失败、待恢复的非局部退出和 Rust 内部故障。普通 Rust 错误可转换成 condition，先返回并执行 Rust 清理，再由 Lisp 边界发出 condition。需要 Lisp handler 在 Rust 调用期间参与时，使用显式回调网关。

回调网关在进入 Lisp 前建立退出捕获边界。handler 正常返回时继续 Rust；发生非局部退出时，网关捕获带 roots 的退出 token 并返回 Rust。Rust 完成 `Drop` 和资源清理后，由外层 Lisp 网关恢复原退出。Lisp unwinder 不穿过仍有 Rust 清理责任的栈帧，Rust panic 也不跨 C/Lisp 边界。

这要求实现与 runtime 动态环境协作的边界，不能只用 Rust `catch_unwind` 代替 Lisp 退出捕获。嵌套回调、cleanup 自身退出、多值和条件处理器继续返回都属于接口测试范围。现有底层 JIT 入口不等于这些回调能力已经具备。

## 编译器接入

image 前端将 HIR 导出成自含请求，为 literal 建立 root frame。Rust 中端只访问请求数据和 literal ID，不访问对象地址或回调编译环境。请求完成后由安装层验证依赖、接管常量 roots 并发布代码；失败则释放请求和暂存产物。

SBCL 前端使用可移植数据适配器，不能使用 kiln 的对象 handles 表示 SBCL 对象。两个适配器共享编译协议与样本。纯 Rust MIR crate 不依赖 runtime，便于独立验证和开发。

初期 Lisp 服务和代码安装限定在 Lisp 所属线程。只有在请求不含借用对象指针、roots 已发布、runtime 状态正确切换后，Rust 的纯优化阶段才可作为 GC 安全的 native 工作执行。多线程 attach、跨线程 Lisp 回调和调度器协作另行扩展；两侧独立开发不以运行期并行编译为前提。

## 外部对象、image 与模块

Rust 外部对象使用模块、类型和 schema 的稳定标识；`TypeId` 仅可用于进程内检查。类型注册记录析构和访问协议，不能把 Rust 内部布局当作持久化格式。

编译请求 arena 属于临时资源，不随 image 保存。持久 native 资源必须提供序列化与恢复钩子，或在保存 image 时明确拒绝；裸地址和函数指针不能当作可恢复资源。运行期代码及 roots 按现有 image 机制登记。

动态模块加载、热重载、过程宏生成绑定、通用 C FFI、GUI 主线程分派和异步回调可以建立在此边界上。模块仍需保证 handle、代码和析构函数存活期，不能卸载仍被引用的库。

## 实施与验证

首先实现版本协商、缓冲区所有权、作用域和持久 roots，以及正常调用和退出完成协议。边界测试覆盖强制移动 GC、嵌套 roots、过期 handle、分配失败、回调退出和 Rust 清理。随后接入编译请求、产物安装与依赖失效，再扩展宿主模块 API。

设计分工与推进次序见 [编译器架构](compiler.md)，GC 与退出约束见 [runtime-constraints.md](runtime-constraints.md)。
