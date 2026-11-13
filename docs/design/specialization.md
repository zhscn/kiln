# 推测、守卫和失效：统一的特化框架

开发期的 kiln 保留 CL 的全部动态性：类可以重定义，方法随时增删，函数和类型可以重新定义，实例可以 `change-class`。性能靠的是在这些动态性之上加快路径。这些快路径原来是各自手写的，每个都自己决定缓存什么、自己负责失效；现在它们都经过同一个模型：有名字、带版本的**假设**，用**守卫**确认仍然成立，假设变化时**失效**。

状态：统一假设、调用点缓存和热点代码生成已接入。常量槽名的 `slot-value`、常量类名及 initarg 名的 `make-instance` 有调用点路径；原生编译器载入后，热点构造器可编成机器码。泛函调用不做调用点缓存（见“调用点特化”）。顶层 `eval` / `load` 有有界的原生产物缓存。seal 时的守卫折叠依赖 seal 本体。

## 假设

假设是一个有名字、带版本的事实，键是 `(KIND NAME)`，`KIND` 和 `NAME` 按 `eq` 比较；`:function` 和 `:inline` 的 `(setf symbol)` 名字先规范化，因此分别构造的等价名字指向同一假设。读取版本或登记依赖时才建立**版本格**（一个 fixnum），从 0 开始，此后事实改变时加一。没有被观察的事实仍通知观察者和依赖追踪，但不分配版本格。

| 键 | 事实 | 版本格 | 改变的时机 |
|---|---|---|---|
| `(:class C)` | 类 C 的布局、优先级列表、是否 finalize | 每个类一个 | `finalize-inheritance`、类的 `reinitialize-instance`、`make-instances-obsolete` |
| `(:methods G)` | 泛函 G 的方法集和方法组合 | 每个泛函一个 | 增删方法、泛函的 `reinitialize-instance` 和 `ensure-generic-function` |
| `(:type NAME)` | `deftype` 的展开、`find-class` 的映射 | **所有类型共用一个** | `deftype`、`(setf find-class)`、类的重定义 |
| `(:initialization C)` | 和 C 的实例初始化有关的方法集 | **所有类共用一个** | 往 `allocate-instance`、`initialize-instance`、`shared-initialize` 增删方法或重初始化这些泛函 |
| `(:function F)`、`(:macro M)`、`(:setf F)`、`(:inline F)`、`(:constant C)` | 定义 | 每个定义一个 | 函数绑定的设置与解除、宏和 setf 展开器的设置、inline 定义或声明变化、常量变化 |

两个共用的版本格是第一步里“先粗后细”的选择：原来这些缓存就是全局的（类重新 finalize 时清空所有 `typep` 表、增删初始化协议的方法时让所有类的构造判断失效），粒度再细只会减少不必要的失效，不会更正确。细化的做法见“待定”。

## 守卫

守卫是特化代码或缓存项在使用前做的便宜检查，两种：

- **检查式**：把版本格的值记在缓存项里，用的时候比较。每次使用一次载入和比较，不需要登记，也不会漏通知。适合以对象为键的缓存（调用点的 `typep`、构造器的快路径）。
- **推送式**：把一段失效代码登记为假设的依赖者；假设改变时由失效过程运行它，登记随之丢弃。快路径上零开销，但所有改变都必须经过 `change-assumption`，而且特化代码重新出现时要重新登记。适合全局事实（判别闭包的调用历史）和以后再重新特化的代码（调用点特化、生成的判别函数）。

以对象为键的用检查式；全局事实用推送式，并集中到一个“改变假设”的函数上。

## 失效

改变的入口只有一个：`kiln.kernel::change-assumption`。它做三件事：

1. 版本加一；
2. 运行登记在这个假设上的**过渡依赖者**（transient dependents：一段函数，运行后丢弃）；
3. 通知**观察者**（watchers：按种类登记，收到一批变化的名字）和依赖追踪的钩子 `kiln.kernel::*redefinition-hook*`。

三种依赖者：

1. **定义单元**（依赖追踪已有）：重新求值。`change-assumption` 把键交给重定义钩子，所以 `(:class c)` 这类键和 `(:macro m)` 一样可以成为在 image 里编译的定义的依赖。
2. **缓存**：观察者清空。判别闭包缓存和 `typep` 的全表都是这样，它们无法枚举自己依赖的所有假设。
3. **特化代码**：过渡依赖者把调用入口换回通用版本；下次需要时再重新特化。

`kiln.kernel::defer-assumption-changes` 把一个操作里的所有改变攒成一批：类的重新 finalize 会改变一批类的 `(:class c)` 和 `(:type name)`，观察者因此只看到一次（一遍扫描，而不是每个类一遍），重定义钩子也在一批改变都生效之后才收到通知。同一键在批次中只通知一次，版本仍随每次改变增加。非局部退出也会发送已经发生的变更；某个依赖者或观察者退出时，清理路径继续通知其余依赖者和观察者。通知期间的新变更会建立自己的批次，不会遗留在已发送的批次中。观察者名单在发送一批通知时取快照。

**约束**：

- 每个特化都必须有一条通用路径可以退回。守卫失败时走通用路径，而不是报错。
- 失效只影响之后的调用。正在执行的帧继续用旧代码，和 CL 对重定义的语义一致（重定义在下一次调用时生效）。因此不需要栈上替换（OSR）或去优化。所有特化都放在函数入口或调用点上。
- 登记的生命周期由所有者管理：过渡依赖者在假设改变时消费，也可用返回的登记凭据主动撤销；消费和撤销都会清除回调及版本格引用。观察者在所属组件退出时主动注销。
- 版本格的全局登记表只保存被观察的事实。所有者退役时可调用 `release-assumption`：先移除键，再递增旧格的版本并通知旧依赖者；回调可以为同一键建立新格。旧格的守卫因此失败，其他键的格保持身份和版本。共享的类型和初始化版本格贯穿 image 生命周期，不能释放。

## 现在的快路径

| 快路径 | 守卫 | 依赖 |
|---|---|---|
| 判别闭包的缓存（单分派、双分派） | 参数的 stamp | `(:class C)` 的观察者 → `forget-call-caches`（把提到这些类的调用缓存从所有泛函的调用历史里删掉，让判别函数失效） |
| 读函数融合：缓存项是槽的位置 | stamp | 同上（类的重新 finalize 换掉 stamp，旧项不再命中） |
| 常量类名 `make-instance` 的构造器对象 | 类的 unique number、类变化版本（`*class-change-version*`）和初始化版本 | 按类和 initarg 形状共享描述符；类名映射、布局或初始化协议变化后重新填入 |
| `typep` 的全局表 | 按 stamp 直接映射，表在类型假设改变时清空 | `(:type NAME)` 的观察者 → `invalidate-type-caches` |
| ctype 的解析结果和 `subtypep` 答案 | `(:type ...)` 的版本 | 同上（原来是自己检查 `*type-caches-valid*` 和 `*type-cache-epoch*`） |
| 调用点上的单项 `typep` 缓存 | `(:type ...)` 的版本（检查式） | 数据段里的缓存 cons：car 是全局表的项，cdr 是填入时的版本；版本不同就重新查全局表。这修掉了原来“被淘汰的实例在这个调用点上拿到旧类的答案”的问题 |
| 常量槽名的 `slot-value`、`(setf (slot-value ...))` 调用点 | 对象的 stamp（检查式） | 数据段里的缓存 cons：car 是对象类的 stamp，cdr 是槽的位置。stamp 属于一次类终结，位置在它下面不会变；类重定义、`change-class`、实例更新都换 stamp，缓存自然失效。见“调用点特化” |
| 内联函数、宏、setf 展开器、常量 | — | 依赖追踪：重定义钩子让依赖者重新求值 |

原来的 `*construction-epoch*`、`invalidate-type-caches` 的计数器、`forget-call-caches` 的调用点都不再是各自独立的入口：增删方法、类重新 finalize、`deftype`、`(setf find-class)` 都只调用 `change-assumption`。

类终结和结构性重初始化的通知在协议方法上完成，覆盖直接 MOP 调用。只更新类名或文档时保留实例布局与类假设版本；指定超类、槽或默认 initarg 等结构选项时则通知依赖者。泛函重初始化会清空调用历史、重算特化参数的位置并使判别函数失效；初始化协议泛函的变更同时改变初始化假设；它们使用非标准方法组合时，构造器走通用协议。函数绑定通过 `(setf fdefinition)`、`(setf symbol-function)` 和 `fmakunbound` 通知；编译器直接写函数格的路径也执行通知，启动早期则检查通知函数是否已定义。

## 热点代码生成

`lisp/target/clos/specialization.lisp` 的调用点先使用闭包。原生 compiler 模块载入后设置编译钩子；命中次数达到阈值时，使用 `native-compile` 晋升。默认阈值是 1000，`*specialization-threshold*` 控制它：编译一次要几毫秒，省下的是每次调用几十纳秒，调用次数少的形状不值得编。构造器对象按类和参数形状共享，挂在以类为键的表里，和类同生命周期，所以晋升过的形状对所有调用点一直有效（阈值是 32、按最近使用只留 64 项时，淘汰和失效带来的反复重编占了自编译的约 15%）。生成期间动态绑定 `*generating-specialization*`，编译器自身的调用不能递归触发生成。`kiln.kernel::*compile-function*` 动态绑定为 NIL 的字节码求值上下文也延迟晋升，恢复原生编译后可继续尝试。

- **构造器**：生成固定 lambda list，按定义顺序求缺失的 default initargs，分配实例，并按固定位置展开槽初始化。类分配槽仍通过共享位置访问，只在未绑定时运行 initform。适用的方法和方法组合必须满足原有构造快路径的条件；其他情况调用通用 `make-instance`。

生成前后的假设必须相同，才会发布生成结果。编译失败保留闭包，在该调用点的假设变化之前不重复尝试；诊断保存在有界的 `*specialization-last-error*` 字符串中。构造器不检查共享的类型版本：它在每次 `defclass`、`deftype` 时都变，用它做守卫会让所有构造器一起失效。它检查 `*class-change-version*`，这个数只在已有的类变化时（重新终结，或类名指向另一个类）才加一，定义新类不变。同理，类第一次终结不算变化，不通知 `(:class C)` 和 `(:type NAME)`：之前没有实例，没有缓存会提到它。生成临时变量用独立的未 intern 符号，不消耗用户的 gensym 计数。

## 顶层编译产物缓存

`lisp/target/compiler/cache.lisp` 缓存原生 `eval` / `load` 中每个顶层编译单元的初始化函数。每次仍执行宏展开、前端和降级，重放编译期效果，再判断是否能复用已生成的机器码；每次命中仍运行初始化函数，求值的副作用和返回值照常发生。

匹配条件是当前包、readtable、去掉编号模块名的 KIR、literal 和已记录的依赖版本格。程序 literal 按 `eql` 保留身份，不能把两个内容相同而身份不同的引用对象混用；编译器新建的调试记录按结构比较。依赖格必须保持身份和版本，退役或重定义会使旧条目失效。宏根据外部状态产生不同代码时，KIR 或 literal 的差异也会导致未命中。含 `load-time-value` 单元的模块每次独立编译，保持旧函数所引用的 load-time cell 独立。

缓存按最近使用顺序保留至多 `kiln.sys:*compilation-cache-limit*` 项，默认 64；0 表示禁用并清除缓存引用。`kiln.sys:clear-compilation-cache` 清空条目和统计，`kiln.sys:compilation-cache-statistics` 返回命中数、未命中数和条目数。淘汰只释放缓存持有的引用，运行时注册的代码和 literal root 仍遵循现有代码生命周期。前端和降级的结果尚未跨调用复用。

## 调用点特化

降级（`lisp/lower.lisp`）把槽名是常量的 `(slot-value x 'slot)` 和 `(setf (slot-value x 'slot) v)` 改写成调用 `kiln.kernel::%slot-value-cached` / `%set-slot-value-cached`，每个调用点带一个数据段里的 cons：car 是上一个对象的 stamp，cdr 是槽的位置。命中路径是一次 stamp 比较加一次槽的载入；未命中走 `fast-slot-location`（`support.lisp`），把位置填进缓存，类分配槽、非标准实例、结构的槽都退回 `slot-value` 的通用路径。这就是 PCL 置换向量的做法在单一环境里的对应：置换向量按 wrapper 找位置，这里按 stamp 找位置，stamp 就是 wrapper 的编号。用检查式守卫而不是推送式：以对象为键的缓存不需要登记，也不会漏通知；类只在一个 stamp 下有一种布局，所以位置不用版本格。

`bench/compare.lisp` 的 AOT 输出（同一台机器，改动前后各三次）：`slot-value` 24.7 → 9.9 ns，和访问器方法（10.4 ns）相当。数字见 [performance.md](../research/performance.md)。

常量类名和 initarg 名的 `(make-instance 'class :key value ...)` 被改写为先获取构造器对象的 callable，再传递已求值的值。每个调用点的静态 cons 的 car 是构造器描述符，登记为 GC root。描述符保存类对象、布局 stamp、类变化版本和初始化版本、关键字形状及 callable；变化时整个替换。所有原参数在查询构造器之前按原顺序求值，initarg 的重复、默认值和类名重新映射由原有构造协议处理。

kernel 和 CLOS 模块里的 `make-instance` 保持普通调用：构造协议本身不能经过构造器对象。

泛函调用没有调用点缓存。试过一版（已知泛函的 1–6 参数调用先调选择器 `%generic-target-N`，检查函数和判别函数身份、方法版本、类变化版本和参数 stamp，再调有效方法），`bench/compare.lisp` 上单态调用 13.7 → 28.6 ns、多态 18.9 → 25.7 ns：多一层调用，还多三组版本检查，结构上就不会比泛函自己的判别函数快，于是去掉了。PCL 的缓存也挂在泛函上，不在调用点：判别函数按状态生成，失效时整个换掉，命中路径不检查版本。kiln 先走这条路；SICL 式的调用点内联（守卫生成在调用点的代码里、推送式失效）是以后的方向，见 [roadmap.md](../roadmap.md) 第 11 项。

后续可以结合类型推导，对方法特化参数的槽访问进一步减少 stamp 检查。

## seal：把假设固定下来（计划）

seal（[positioning.md](positioning.md)）之后，被 seal 的定义不再改变。对本框架来说，这意味着：

- 涉及被 seal 定义的假设，版本格变成常量：检查式守卫在编译期折叠掉，推送式的登记直接省掉。
- 通用路径、登记表、版本格，只要没有未 seal 的代码还需要，就被 tree shaking 去掉。
- 假设的清单正好回答了“seal 允许编译器假定什么”：单实现的泛函变成直接调用，访问函数变成按固定下标读槽，`make-instance` 变成直接分配，`typep` 变成常量或 stamp 比较。`kiln.sys:assumptions` 列出所有有版本格的假设。
- 保持开放的定义（编辑器要求的“整个程序 seal，但列出的定义保持开放”）保留守卫和通用路径。

开发期和交付期因此是同一份特化代码：开发期带守卫，交付期去掉守卫。

## 接口

- `kiln.kernel::change-assumption (kind name)`：事实改变了。
- `kiln.kernel::register-assumption-dependent (kind name function)`：登记过渡依赖者，返回登记凭据。
- `kiln.kernel::cancel-assumption-dependent (registration)`：撤销凭据，释放其回调；可重复调用。
- `kiln.kernel::unregister-assumption-watcher (kind function)`：注销观察者；可重复调用。
- `kiln.kernel::release-assumption (kind name)`：所有者退役时使旧格失效，并从登记表释放键。
- `kiln.kernel::register-assumption-watcher (kind function)`：登记观察者，它收到一批变化的名字。
- `kiln.kernel::defer-assumption-changes (thunk)`：把 THUNK 里的改变攒成一批。
- `(kiln.sys:assumption-version kind name)`：版本，新假设是 0。
- `(kiln.sys:assumptions)`：所有有版本格的假设，`(KIND NAME VERSION)` 的列表。

`tests/m4/clos-call-sites` 覆盖构造器调用点在类、方法和类名变化时的行为，`tests/m5/co-specialization` 覆盖原生晋升，`tests/m6/co-compilation-cache` 覆盖产物复用、宏副作用和缓存淘汰。

`tests/m4/clos-assumption-protocol` 覆盖协议入口、异常退出、重入通知、登记撤销、版本格退役和表扩容后的删除。定向验证可运行 `tools/test.sh tests/m4/clos-assumption-protocol.lisp tests/m4/clos-assumptions.lisp tests/m4/clos-slot-value-cache.lisp`。

测试是 `tests/m4/clos-assumptions`（假设、版本格、观察者、依赖者、各缓存的失效）和 `tests/m4/clos-slot-value-cache`（常量槽名的 `slot-value` 的位置缓存：子类、类重定义、`change-class`、类分配槽、未绑定槽、结构）。

## 待定

- **自动回收**：当前运行时没有弱引用。没有主动撤销或退役的登记仍被强引用；后续 GC 弱引用支持可让版本格随所有者自动回收。多线程和内存序见 [runtime-constraints.md](runtime-constraints.md)。
- **假设的粒度**：`(:type ...)` 和 `(:initialization ...)` 现在各是一个共用的版本格。细分成每个名字、每个类一个，可以减少不必要的失效（给 C 定义一个子类不该让所有 `typep` 缓存失效），代价是守卫要多找一个格子。先粗后细，按实际的失效频率调整。
- **缓存的回收**：缓存所有者需要在淘汰时撤销依赖登记；编译结果和机器码自身的回收还需要独立策略。
- **观察者和过渡依赖者同时存在**：判别闭包的缓存用观察者（无法枚举依赖的类），调用点特化用过渡依赖者（自己知道依赖什么）。两者的分工是按“能否枚举”来的，不是按缓存和代码分的。
