# 定位和 seal

## 一句话

kiln 开发时是一个完整的、可以随时修改的 CL 活环境，交付时编译成静态链接的原生二进制。

它不改 CL 的语义，主要补 CL 生态缺的两样东西：**交付裁剪**和**结构化异步**。

## 技术选型

| 方面 | 选择 |
|---|---|
| 语言 | Common Lisp，以 ANSI 为主；可以额外提供一个 staging 库 |
| 复用 | SICL 生态的独立模块（Eclector、Clostrum、Common-boot 等），详见 [modules.md](modules.md) |
| 开发期代码生成 | cranelift-jit |
| 交付期代码生成 | cranelift-object，AOT |
| Runtime | Rust 写的小 runtime，静态链接 |
| GC | MMTk |
| 异步 | 底层用 stackful 栈切换，对外暴露和 condition 系统统一的一次性续延，详见 [async.md](async.md) |
| 早期宿主 | SBCL |

## 和现有实现的区别

| | SBCL/CCL | ECL/Clasp | Go | kiln |
|---|---|---|---|---|
| 开发体验 | image + SLIME | 较弱 | 无 | image + SLY，能看到 fiber |
| 交付产物 | 整个 image | 依赖 C/C++ 运行时 | 静态二进制 | 整体优化、裁剪后的静态二进制 |
| 异步 | 线程 + 库 | 线程 | goroutine | stackful，condition 语义完整 |

卖点不在峰值性能，而在这三点：

1. 出错时（包括在 fiber 里）**不退栈**，就地修好后选一个 restart 继续运行。
2. 交付物小。
3. 部署时不需要 image。

## 必须保留的开发体验

- condition/restart 系统：出错时不退栈，就地修复后继续运行。
- 活对象重定义：类改了以后，已有实例自动更新（`update-instance-for-redefined-class`、`change-class`）。
- 函数和方法的重定义立即生效。
- 围绕 image 的 REPL，以及 SLIME/SLY 的开发体验。
- REPL 中断（C-c C-c）能打断任意正在运行的代码，进入 debugger。

## 两个阶段

### 开发期

完整保留动态语义：condition/restart、重定义、`change-class`、MOP、`eval`/`compile`。代码由 cranelift-jit 即时编译。

### seal

用户显式声明世界封闭。之后不再允许重定义，编译器可以假设看到了全部程序。

整体优化（WPO）依赖这个承诺：

- 泛函数去虚化、方法内联；
- 删除没有用到的函数、类、方法、`format` 指令和 `loop` 子句的实现；
- 把满足条件的 async 函数编译成状态机（见 [async.md](async.md)）。

### 交付期

用 cranelift-object 编译成目标文件，和 Rust runtime 静态链接。默认不带 `compile`/`eval`。如果确实需要，作为可选模块链接进来，代价是体积变大。

## seal 的语义必须写进规范

否则裁剪会悄悄改变程序的行为。至少要定义下面这些情况：

| 情况 | 需要规定的行为 |
|---|---|
| seal 之后调用 `eval`/`compile` | 不带编译器时报错；带编译器时允许，但新代码不能重定义已经 seal 的定义 |
| `intern` 一个新符号 | 允许，但 `find-symbol` 找不到被裁掉的符号 |
| `find-class`、`fdefinition` 的参数只在运行期才知道 | 需要用户声明保留集合（类似 GraalVM 的 reflection config），否则报错 |
| 重定义一个已经 seal 的函数或类 | signal 一个明确的 condition |
| 通过 `symbol-function` 动态调用 | 同 `find-class` |

## 目标

- 完整的 ANSI CL。
- 在开发期提供 SBCL 级别的交互式开发体验。
- 交付期产出静态链接的原生二进制。
- 异步和 condition、restart、`unwind-protect`、special 变量正确配合。
- 自举完成后不再依赖 SBCL，但始终保留从 SBCL 构建的路径。

## 非目标

- 早期不追求峰值性能超过 SBCL。
- 交付期不支持任意的运行期重定义。
- 不实现 `call/cc` 那种多次可重入的续延，只做一次性续延。
- 不追求和 SBCL 的扩展（`sb-ext` 等）二进制兼容。需要的地方提供兼容层。
- ANSI 自举完成之前不做异步。底层约束先留好，见 [runtime-constraints.md](runtime-constraints.md)。

## 待定问题

- staging 库的范围：只给 WPO 提供提示，还是作为一种一等的多阶段编程设施？
- seal 的粒度：是整个程序，还是可以按系统或按包分别 seal？编辑器的需求是至少支持“整个程序 seal，但列出的定义保持开放”（[editor.md](editor.md) 的“扩展模型和 seal”）。
- 交付期的可选编译器模块：只带字节码解释器，还是带完整的 Cranelift？
