# 19 Rust 宿主模块和双向互操作

**状态**：设计草案（2026-11），还没有实现。它是 [02](02-runtime-constraints.md) C6 在 Rust 一侧的具体化，编辑器的 GUI 前端（[16](16-editor.md) §4.5.4、§5.7）是第一个用户。通用的 C FFI 以后建在它上面（§8）。

## 1. 为什么不必走 C 的语义

kiln 的 runtime（kiln-rt）和 launcher 都是 Rust，和用 Rust 写的宿主模块在同一个 cargo 工作区里一起编译。要区分两个层面：
- **机器层面的调用约定**：仍然是 `extern "C"`（SysV 一类）。Rust 自己的 `extern "Rust"` 没有固定的调用约定，Cranelift 没法可靠地调用它。kiln-rt 的 runtime 函数现在就是这样：`extern "C" fn kiln_rt_xxx(ctx: *mut Context, obj: u64, ...)`。这一层只是寄存器怎么放参数，没有额外开销。
- **类型和语义层面**：不必是 C 的。接口直接用 kiln 的对象模型（带标签的值、ctx、condition、GC 的规则），宿主模块直接使用 kiln-rt 的 Rust 类型。

**跨越边界的只有 C ABI 的东西**：带标签的 64 位字、ctx 指针、函数指针。Rust 没有稳定的 ABI；更要紧的是，宿主模块不能自己链接一份 kiln-rt，否则进程里会有两份 runtime 的全局状态（MMTk 堆、根表、符号表）。所以：
- kiln-rt 导出一张带版本号的**服务表**（`extern "C"` 的函数指针）：分配、登记和释放根、`funcall`、发出 condition、读写特殊变量、切换 `in-native` 状态、创建外部对象等。
- 宿主模块导出一个入口 `kiln_module_init(api: &KilnApi, registry: &mut Registry) -> u32`：先核对 API 版本和值表示（ABI 指纹，[12](12-abi-policy.md)），再登记它的函数和类。
- **包装 crate**（下文的 `kiln::`）编进宿主模块，只经服务表和 runtime 打交道。`Ctx`、`Value<'cx>`、`Handle` 和借用检查器给的 GC 安全（§3）都在宿主模块内部成立。

这是 PyO3、mlua、Rustler 的结构：它们面对的 runtime 对外是 C 接口，Rust 风格的类型和安全保证由编进扩展的包装 crate 提供。静态链接和动态载入（§7）走同一张服务表，只有一套机制；要求只是“同一个 kiln API 版本”，和编译宿主模块的 rustc 版本无关。

参考：PyO3（Python）、mlua（Lua）、Rustler（Erlang NIF）、jlrs（Julia）、napi-rs（Node）、gc-arena（带品牌生命周期的 GC 句柄）。这些是按已有了解列的，具体采用某个做法时再读它们的源码核对。

## 2. Lisp 调用 Rust

```rust
#[kiln::defun("text-width")]
fn text_width(cx: &Ctx, font: Handle<Font>, s: &LispStr) -> Result<i64, Error> { ... }
```

过程宏生成：
- **桥接函数**：`extern "C"`，按 kiln 的值表示检查参数并拆箱（fixnum 直接取值，类型不对就发出 Lisp 的 `type-error`），把 `Err` 转成 Lisp condition，用 `catch_unwind` 把 panic 转成 Lisp 错误。panic 不能越过桥接函数。
- **登记信息**：名字、lambda list、参数和结果的类型。launcher 初始化时把各宿主模块的登记信息装进一张表，Lisp 侧得到普通的函数对象：能 `funcall`，在 backtrace 里有名字（[17](17-debugging.md)），能被重定义和 advice。
- **给 Lisp 编译器的声明**：签名在编译期已知，kiln-cg 可以在调用点直接调用桥接函数，内联类型检查和拆箱，省掉通用的参数检查（.NET `LibraryImport` 的思路）。签名变了，调用点按 [18](18-dependencies.md) 的方式失效。

kiln-rt 现在手写的 runtime 函数（`kiln_rt_sys` 的操作号、`call-rt` 的各个目标）以后也可以用这套机制定义。

## 3. GC 安全：用借用检查器静态保证

MMTk 是移动式 GC（[07](07-m1-gc.md)），持有 Lisp 值的 Rust 代码要保证 GC 时这些值能被找到、被更新。
- **可能触发 GC 的操作都要求 `&mut Ctx`**：分配、调用 Lisp、poll 点。
- **未登记为根的值是 `Value<'cx>`**，借用自 `&Ctx`。拿着它就拿不到 `&mut Ctx`，也就不可能跨过一次 GC。“未登记的值跨过 GC”在编译期就会报错。
- **要跨过 GC 的值换成 `Root`/`Handle`**：登记在 ctx 上的根表里，GC 时更新。作用域式的句柄（类似 V8 的 HandleScope）在离开作用域时整批释放。
- **零拷贝借用**：Rust 可以把 Lisp 的字节向量、字符串借成 `&[u8]`、`&str` 一类的视图。借用期间没有 `&mut Ctx`，不会分配，GC 不会在此期间移动这个对象，所以不需要钉住。显示列表就是这样借给渲染器的（[16](16-editor.md) §4.5.4）。
- **长时间的计算或阻塞**：先放下所有借用，再切换到 `in-native` 状态（C6），让别的线程能做 GC。这也写进类型：`cx.blocking(|| ...)` 的闭包拿不到 `Ctx`。等待输入事件就用它。

和 C 的 FFI 相比，这是走 Rust 原生接口最大的收益：C 那边只能靠约定和文档。

## 4. Rust 调用 Lisp

`cx.funcall(f, &[a, b])`、`cx.call("NAME", ...)`、读写特殊变量。

**非局部退出不能直接穿过 Rust 帧**：Rust 帧上可能有要运行的 `Drop`，kiln 的 unwinder 也不认识这些帧。做法：
- `cx.funcall` 在边界上拦住 Lisp 的 `throw`、`return-from`、`go` 和 restart 造成的非局部退出，转成 `Err(Unwind(令牌))`；
- Rust 代码用 `?` 一路返回，途中 `Drop` 正常执行；
- 回到 Lisp 侧的桥接函数时，用令牌把原来的展开继续下去。

condition 本身不需要特殊处理：`signal` 在 Lisp 侧查找 handler（C7），handler 在原来的栈上运行，Rust 帧夹在中间也没关系。只有 handler 决定非局部退出时，才走上面的路径。

这也回答了 C6 的待定问题：栈上夹着 Rust 帧时，不需要保守扫描，也不需要 unwinder 认识这些帧。Rust 帧里只能持有根（§3），非局部退出在边界上转换。

## 5. Rust 对象放进 Lisp

- Rust 的值装箱后包进一种 Lisp 外部对象，带类型标识（`TypeId`），并登记一个 CLOS 类，`print-object`、`typep`、方法分派都能用。
- 对象被回收时运行 `Drop`，靠 MMTk 的终结机制。需要确定性释放的资源（窗口、文件）另外提供显式的关闭操作。
- Rust 的方法可以导出成泛函的方法。
- 相当于 PyO3 的 `#[pyclass]`。GUI 里的字体、图片、窗口都以这种句柄交给 Lisp（[16](16-editor.md) §4.5.4）。

## 6. 线程

- **平台层在主线程**：winit 一类的库要求事件循环在主线程上（macOS 上是强制的）。kiln-rt 已经把 Lisp 跑在单独起的线程上（`run_module`），主线程可以交给宿主模块。launcher 要提供一个钩子：宿主模块需要时，由它接管主线程。
- **宿主模块自己的线程**（例如渲染线程）不是 Lisp 线程，没有 ctx，不能接触 Lisp 值，只通过拷贝或借出的数据和 Lisp 交流。要调用 Lisp 时，先给这个线程挂上 ctx，类似 JNI 的 `AttachCurrentThread`；这一步等 Lisp 的多线程和内存模型定下来再做（[13](13-modern-practices.md)）。
- **唤醒**：宿主模块产生事件后要唤醒等待中的 Lisp 线程。fiber 之前，`cx.blocking` 里阻塞等待；有了调度器，改成唤醒等待的 fiber。

## 7. 构建、开发期和交付

- **静态链接**：宿主 crate 和 launcher 一起编译，链进可执行文件，启动时调用它的入口登记（§2）。快照（[15](15-heap-image.md)）里保存的函数对象在启动后重新连到桥接函数。具体做法见 §7.1。
- **seal**：优先静态链接，宿主模块和 Lisp 一起参与 WPO，没有用到的导出函数被裁掉。
- **动态载入**：单独编译成动态库，在活 image 里 `dlopen`（例如 `(kiln.sys:load-host-module "libfoo.so")`），调用同一个入口登记。适合开发期和插件。
  - **不卸载**：已有的外部对象的 `Drop` 和方法、已登记的函数都指向库里的代码，和 Python 扩展一样从不 `dlclose`。
  - **有限度的热重载**：改过的 Rust 代码编成新文件名的库再载入一次，重新登记。Lisp 侧经函数格的调用立即生效；按签名直接调用的调用点按 [18](18-dependencies.md) 失效重编。旧库留在内存里，旧版本创建的外部对象 `TypeId` 不同，算作另一个类。
  - **内存分配器**：每个库用自己的全局分配器，所以 Rust 分配的内存只由同一个库释放。外部对象的 `Drop` 由登记它的库提供。
  - **帧**：release 构建的 Rust 代码通常省略帧指针。边界在 ctx 上留下记录，`frame-list` 和 unwinder 直接跳过外部帧段；非局部退出本来就在边界上转换（§4）。
- **异步**（以后）：Rust 的 future 完成时唤醒 kiln 的 fiber，fiber 也可以等待 Rust 的 future。Rustler 处理 BEAM 调度器的方式可以参考。

### 7.1 静态链接的构建

有源码的 Rust 代码（项目自己的宿主 crate，以及经它们用到的整个 crates.io 生态）在交付时静态链进可执行文件。由项目工具（[13](13-modern-practices.md) §11）完成：

- **只生成一个 staticlib**：每个 Rust staticlib 都自带一份 std 和它依赖的 crate；分别编译再链接，会有重复的符号，或者两份 kiln-rt 的全局状态。所以项目工具按项目生成一个胶水 crate：它依赖 kiln-launcher 和项目的所有宿主 crate，`cargo build` 出唯一的 staticlib，再和 kiln-cg 产出的目标文件链接。现在的 `libkiln_launcher.a` 就是这个位置，以后变成按项目生成的 launcher。
- **显式登记**：不依赖 `inventory` 一类借链接器收集的静态构造（静态库里没被引用的目标文件会被链接器丢掉）。胶水 crate 按顺序显式调用每个宿主模块的 `kiln_module_init`，和动态载入走同一个入口（§1）。
- **签名先于 Lisp 编译**：过程宏编译 Rust 时同时产出一份声明：函数名、lambda list、参数和结果的类型、桥接函数的符号名。项目工具先编 Rust，再把声明交给 Lisp 编译器，kiln-cg 在调用点直接 `call` 桥接函数的符号（§2），静态链接时是一次直接调用，不经过函数格。这也定了 §9 的一个待定问题：声明由构建产出。
- **静态时绕过服务表**：静态链接时同一个 crate 图里只有一份 kiln-rt，包装 crate 打开一个 feature 后直接调用 kiln-rt 的函数，Rust 侧的 LTO 能把分配、根的登记、类型检查内联进桥接函数。动态库仍走服务表，源码不变，只是编译选项不同。Cranelift 不产出 LLVM IR，Lisp 和 Rust 之间没有跨语言 LTO，边界上的代价是一次 C ABI 调用。
- **裁剪**：seal 知道 Lisp 侧引用了哪些导出函数，生成的胶水只登记它们；没有登记的桥接函数不再被引用，由 Rust 的 LTO 和链接器的 `--gc-sections` 删掉。
- **开发期和交付期同一份源码**：开发时同一个 crate 编成 cdylib，在活 image 里载入、热重载（上面的“动态载入”）；`build --release` 和 seal 时静态链接。项目清单只声明“这是宿主 crate”，链接方式由构建模式决定。
- **依赖和锁文件**：Rust 的依赖仍由 Cargo（`Cargo.toml`、`Cargo.lock`）管理，kiln 的锁文件只记下 Cargo 工作区和 `Cargo.lock` 的哈希，不重复做 Rust 的版本解析。构建缓存的键包括 rustc 版本和 `Cargo.lock` 的哈希。

这样 Rust 生态里的库（解析器、压缩、加密、网络、GUI 的 winit/wgpu）经一层宿主模块就能给 kiln 用，交付时仍是一个静态链接的可执行文件。

## 8. 和 C FFI 的关系

通用的 C FFI（调用任意 C 库、回调）以后建在这层上：
- 按签名生成的 C 调用桩、C 回调的入口，本身就是宿主模块里的桥接函数，GC 状态切换（C6）和非局部退出的转换（§4）都复用。
- C 帧在栈上的规则和 Rust 帧一样：只持有根，非局部退出默认在边界上拦住。
- 交给 C 的 Lisp 对象要钉住或放在不移动的空间，这一点 Rust 不需要（§3 的零拷贝借用靠类型保证），C 需要，到时候再定。

C FFI 的需求来自调用现有的 C 库，排在后面。Rust 宿主模块的需求来自编辑器的 GUI，可以先做。

## 9. 待定问题

- 根的形式：作用域式句柄、显式的 `Root`，还是两者都要？和 MMTk 的根扫描怎么接？
- 外部对象的终结：MMTk 的终结机制的代价和时机，要不要单独的不移动空间？
- ~~宿主模块的 Lisp 侧声明：由过程宏生成一份 Lisp 源码随构建产出，还是初始化时从登记信息动态建立？~~ 由构建产出（§7.1）；动态载入的模块在初始化时按登记信息建立。
- 胶水 crate 的生成和 cargo 的调用方式：项目工具直接生成一个 Cargo 工作区成员，还是借 `build.rs`？
- 服务表的版本策略：只增不改、按版本号协商，还是每次 ABI 指纹变化都要求重新编译宿主模块？
- launcher 交出主线程的接口，以及没有 GUI 时的行为。
