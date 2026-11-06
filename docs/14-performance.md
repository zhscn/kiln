# 14 性能：和 SBCL 的差距在哪里

**状态**：测量和分析（2026-11），还没有开始改。自举本身的优化见 [11](11-m5-self-hosting.md) §10.2。

## 1. 测量方法

`bench/compare.lisp` 是一组可移植的 CL 代码，在 kiln 和 SBCL 上运行同样的操作，输出每次操作的纳秒数：
- kiln：复制成 `clos-*.lisp` 交给 `tools/test.sh`，取 AOT 的输出；
- SBCL：`sbcl --script bench/compare.lisp`，默认优化级别，没有类型声明。

几纳秒的项目只能看数量级，SBCL 那边的计时器分辨率是微秒。

## 2. 结果（2026-11）

### 2.1 编译器生成的基础代码：和 SBCL 持平

| 操作 | kiln (ns) | SBCL (ns) | 倍数 |
|---|---|---|---|
| 普通调用（1 个参数） | 2.4 | 2 | 1.2× |
| `&optional` 调用 | 3.5 | 4 | 0.9× |
| 闭包调用 | 3.9 | 4 | 1.0× |
| 特殊变量绑定 | 3.8 | 3 | 1.3× |
| `cons` | 3.2 | 3 | 1.1× |
| 未声明类型的 `+`（fixnum） | 3.0 | 3 | 1.0× |
| `fib 20` | 52 µs | 75 µs | 0.7× |
| fixnum 求和循环（1000 次） | 1.6 µs | 3.0 µs | 0.5× |

调用约定、寄存器分配、fixnum 算术和控制流已经和 SBCL 相当。GVN、LICM 这类通用的 SSA 优化 Cranelift 已经在做，再加一层通用中端，改变不了这里的数字，也解决不了 §2.2 的差距。

### 2.2 库和运行时：差距所在

| 操作 | kiln (ns) | SBCL (ns) | 倍数 | 原因 |
|---|---|---|---|---|
| `(format nil "~a" i)` | 13373 | 30 | 446× | Invistra、Incless 每一步都是泛函，每个字符经过 Gray stream 协议 |
| `princ-to-string` 一个 fixnum | 11816 | 30 | 394× | 同上 |
| `find` 一个字符（100 个字符的字符串） | 2290 | 10 | 229× | Consecution 的通用实现：每次解析关键字参数，逐元素调用泛函 |
| `make-instance`（2 个 initarg） | 1189 | 10 | 119× | 每次都按 initarg 走完整的初始化协议；SBCL 有预编译的构造器（PCL 的 ctor）。kiln 只缓存了初始化计划（10 §27） |
| `defstruct` 的构造函数 | 546 | 7 | 78× | 本该是一次分配加几次写入，现在走 CLOS 实例的路径 |
| `read-from-string` | 43401 | 400 | 109× | Eclector 加 CLOS 流 |
| 双精度浮点求和（1000 次） | 203 µs | 7 µs | 29× | 每次运算都装箱，再经 `kiln_rt_number_op` 进 Rust；SBCL 也装箱，但运算是内联的 |
| `member :test #'equal` | 306 | 13 | 24× | 带关键字时走通用路径（不带关键字的已经改成两个参数的专用函数，11 §10.2） |
| `typep x '(integer 0 10)` | 13.6 | 1 | 14× | 运行期解释类型说明符；SBCL 在编译期展开成比较 |
| `intern` 已有的符号 | 338 | 30 | 11× | Parcl 的协议层 |
| `call-next-method` | 98 | 9 | 11× | 有效方法是解释执行的闭包，每次分配参数列表 |
| `handler-case`（不发出信号） | 73 | 9 | 8× | 建立 handler 要在堆上分配；SBCL 在栈上 |
| `sort` 20 个 fixnum | 2922 | 440 | 6.6× | 序列函数的通用实现，比较函数经 `funcall` |
| `&key` 调用（1 个关键字） | 31 | 5 | 6.2× | 运行期扫描关键字列表 |
| `gethash` / `(setf gethash)`（eq） | 19 / 21 | 3 / 5 | 4–6× | Salmagundi 的协议层（泛函、客户端对象） |
| `gethash`（equal，字符串键） | 85 | 21 | 4.0× | 同上 |
| 泛函调用（单态 / 3 个类的多态） | 14 / 22 | 5 / 5 | 3–4× | 分派闭包和缓存表（10 §27） |
| `slot-value` / 访问器 | 22 / 11 | 5 / 4 | 3–5× | 按槽位置的缓存，没有内联到调用点 |
| `catch`/`throw` | 34 | 7 | 4.9× | |
| `&rest`（3 个参数） | 39 | 24 | 1.6× | |
| `defstruct` 的访问器 | 3.4 | 2 | 1.7× | |

自举时编译器主要在做 §2.2 后半部分的事：泛函分派、槽访问、`make-instance`、哈希表、`&rest`、`&key`（11 §10.2 的 profile）。kiln 编译自己比 SBCL 慢 6 倍左右，原因就在这里。GC 占的约 13%，也主要来自这些地方的分配：`&rest` 列表、浮点装箱、初始化时的 initarg 列表、堆上的 handler。所以只换 GC 解决不了根本问题。

## 3. 需要的优化

SBCL 快在它的前端，即 Lisp 语义层的变换和类型推导，而不是通用中端。按收益排：

1. **`defstruct` 直接分配**：构造函数和访问器直接编成内联的分配和读写，不经过 CLOS。改动小，收益大。
2. **调用点上的变换**：`find`、`position`、`member`、`assoc`、`typep` 等在参数和类型已知时，于编译期展开成循环或比较（相当于 SBCL 的 `deftransform` 和编译器宏）；对已知函数的 `&key` 调用，在编译期解析关键字。覆盖 §2.2 一半以上的项目。
3. **CLOS 运行时编译化**：有了 M5.5 的原生 `compile`（11 §11）才能做。判别函数、有效方法、`make-instance` 的构造器在运行期编成机器码，替代现在解释执行的闭包。`call-next-method`、`make-instance`、泛函调用、`slot-value` 都靠这个。这一项对自举提速最多。
4. **库的快速路径**：打印 fixnum 和字符串、`format` 的常见指令、字符串流的批量写入，绕开逐字符的泛函调用。
5. **类型推导和浮点拆箱**：局部推导出 double 之后不再装箱，算术内联（13 §4）。
6. **`dynamic-extent` 和逃逸分析**：`&rest` 列表、handler、闭包在栈上分配，同时减轻 GC（13 §4）。

## 4. 测量时发现的问题

- **浮点解码函数缺失（已修复）**：kiln 原来没有 CLHS 12.2 的 `integer-decode-float`、`decode-float`、`scale-float`、`float-sign`、`float-digits`、`float-precision`、`float-radix`。kiln 的 Quaviver 替身（`lisp/target/clos/quaviver.lisp`）也只支持以 10 为底。Invistra 的 `~F` 在舍入遇到恰好是 5 的那一位时，要用以 2 为底的精确表示来判断，于是报错。现在这些函数按位实现在 kernel 里，以 2 为底时用 `integer-decode-float`。测试 `tests/m4/clos-float-decode`，结果和 SBCL 一致。非规格化数 kiln 打印成最短的等价形式（`5.0d-324`），SBCL 打印成 `4.9406564584124654d-324`。
- **Invistra 的舍入 bug（上游，未修）**：`(format nil "~,1f" 0.05f0)` 和 `(format nil "~,1f" 0.05d0)` 给出 `"0.0"`，应该是 `"0.1"`：两者的精确值都略大于 0.05。在 SBCL 上配原版 Quaviver 运行 Invistra，结果也一样，所以不是 kiln 的问题（vendor/README.md）。
