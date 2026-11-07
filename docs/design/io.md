# 流、文件、读入和打印

这些都编进 CLOS 模块，用 intrinsic 接口：CL 的流、读入、打印、FORMAT 函数就是 Cyclosis、Eclector、Incless、Invistra、Inravina 的函数。kiln 的 client 在 `lisp/target/clos/` 下，vendor 的补丁见 `vendor/README.md`。

## 系统接口

- `kiln_rt_fd_read`、`kiln_rt_fd_write`（`%primop :fd-read`/`:fd-write`）：参数是 `(unsigned-byte 8)` 向量的原生存储。
- `kiln_rt_sys(op, a, b, c)`（`%primop :sys`）按 `op` 分派文件系统调用和时钟：open、close、lseek、unlink、rename、mkdir、rmdir、stat、fstat、getcwd、realpath、getenv、列目录、strerror、单调时钟、Unix 时间、进程 CPU 时间、sleep、exit。
  - 文件名以 UTF-8 八位组的 simple vector 传入。
  - 返回名字的调用把结果存进作为最后一个参数传入的 simple vector，返回值是结果的长度；长度超过向量时什么也不存，Lisp 侧换一个更长的向量重试。
  - 失败时返回负的 errno。
  - 用一个入口而不是每个系统调用各导入一个函数，KIR 和 kiln-cg 都不必为新调用改动。所有系统调用经过同一个入口，以后的记录与回放也依赖这一点。

## 流（Cyclosis）

- Cyclosis 用 Trinsic 的 `make-define-interface` 生成 CL 的流函数和宏，展开在 kiln 的 client 文件（`streams.lisp`）里。
- 上游的 intrinsic 接口在自己的包里遮蔽 `stream`、`close`、`streamp` 等名字，加载时再 `shadowing-import` 进 CL；kiln 的运行期包是宿主包的镜像，这一步做不了，所以补丁让 Cyclosis 直接使用这些 CL symbol。需要 client 参数的函数（`open`、`peek-char` 等）仍然遮蔽。
- **标准流**：文件描述符 0、1、2 上的 POSIX 文件流，经 synonym stream 绑定到 `*standard-input*`、`*standard-output*`、`*error-output*` 等。标准流**没有缓冲**：runtime 的 `print` 和错误信息直接写 fd，Lisp 这边一缓冲，两边的输出顺序就会乱。`stream-write-string` 一次编码整个字符串、只写一次，`stream-write-octets` 按块拷贝。
- `nontrivial-gray-streams`：kiln 定义 `ngray` 包，转出 Cyclosis 中同名的 Gray 流 symbol（`ngray.lisp`），补上 `stream-element-type`、`stream-external-format`、`stream-line-length`。
- 字符串输出流按倍数增长（上游每次只加长 32，写入是平方级）。
- 上游修正：UTF-8 编码时三字节的上界、解码时的移位方向、`stream-advance-to-column` 写换行而不是空格。

## pathname 和文件

**pathname**（`pathnames.lisp`）是标准对象，它的类以内建类 `pathname`（或 `logical-pathname`）为超类，做法和 Regalia 的数组一样。

- 物理 pathname 按 SBCL 在 Unix 上的规则解析：`~/` 是 `(:absolute :home)`，`..` 是 `:up`；`*` 和 `**` 是 `:wild` 和 `:wild-inferiors`，名字里带 `*` 的串是通配模式；以点开头的文件名没有类型；有名字时版本是 `:newest`。`..` 作为文件名时名字就是 `".."`（SBCL 解析成名字 `"."`、类型 `""`）。
- 逻辑 pathname：`logical-pathname-translations` 登记 host，`translate-logical-pathname` 按第一条匹配的转换翻译，翻译到物理 pathname 时转成小写。
- `pathname-match-p`、`translate-pathname` 支持 `:wild`、`:wild-inferiors` 和名字里的 `*`。
- `equal` 和 `equalp` 按分量比较 pathname（kernel 的 `equal` 对标准实例调用 `*instance-equal*`）。
- 文件系统函数：`probe-file`、`truename`、`file-write-date`、`delete-file`、`rename-file`、`ensure-directories-exist`、`directory`、`user-homedir-pathname`。`*default-pathname-defaults*` 在启动时（包括从快照启动时）设为当前目录。
- 限制：只支持 Unix 的物理 pathname，没有 host 对象（物理 pathname 的 host 是 NIL），名字里不能用反斜杠转义；`directory` 不解析符号链接；编译器不支持 pathname 常量。

**文件流**（`files.lisp`）：`kiln-file-stream` 是 Cyclosis 的 `posix-file-stream` 加一个 8 KiB 缓冲。

- Cyclosis 的转码器逐个八位组读写，没有缓冲的话每个八位组都是一次系统调用。
- 同一个缓冲先用于读还是写，取决于下一个操作：写之前把预读的部分用 lseek 退回，读之前先写出待写的部分。`finish-output`、`force-output`、`close`、`file-position`、`file-length` 之前都先写出缓冲。
- `file-position` 扣除 `unread-char` 退回的字符（源码位置依赖它，[front-end.md](front-end.md)）。字符流的 `file-position` 以八位组计。
- `make-file-stream` 是 kiln client 的方法：`:supersede` 和 `:rename-and-delete` 直接截断文件，不写临时文件；`:rename` 把原文件改名为 `原名.bak`；`:new-version`（输出的默认值）和 `:error` 一样，文件存在就报错，和 SBCL 一样。

**时间**（`time.lisp`）：`get-internal-real-time` 和 `get-internal-run-time` 以微秒计，`get-universal-time`、`sleep`。没有时区，所以没有 `decode-universal-time`、`get-decoded-time`。`sleep` 期间其他线程不能做 GC（现在还没有其他线程）。

## 读入（Eclector）

Eclector 同时是宿主前端的 reader 和目标端的 reader。CLOS 模块里有 base、readtable、simple readtable 和 reader；parse result 和 CST 读取器在 frontend 模块。kiln 的接口在 `reader.lisp`。

- Eclector 的源码读进宿主里已有的 Eclector 包，其中 `eclector.readtable` 遮蔽了 CL 的 readtable 函数和 `*readtable*`。所以 CL 的 `read`、`read-from-string`、`read-preserving-whitespace`、`read-delimited-list` 和各个 readtable 函数都转调 Eclector 的同名函数；kiln 的 Eclector client 让 `cl:*readtable*` 读写和绑定 CL 的变量；`get-macro-character` 和 `get-dispatch-macro-character` 把 Eclector 存的符号换成函数；`with-standard-io-syntax` 绑定 Eclector 的标准 readtable。
- kiln 的 Eclector client 只在 CL 的读入函数里绑定，不全局设置：Eclector 的其他入口用 `(or *client* 默认 client)` 选 client，全局设置会让 CST 读取器用错 client。
- simple readtable 的类以内建类 `cl:readtable` 为超类，`readtablep` 成立。
- 读入的 `` ` `` 形式是 Eclector 的 `quasiquote` 宏调用，运行期可以展开。

## 打印器（Incless）

Incless 定义 `write`、`prin1`、`princ`、`print`、`print-object`、`print-unreadable-object`、`write-to-string` 等，源码没有改动。kiln 的 client 在 `printer.lisp`：`class-slot-names` 用 Clostrophilia 的 `class-slots`，`write-identity` 打印身份哈希。

`printer-support.lisp` 补充：打印和读入的变量、`with-standard-io-syntax`、`readtable-case`、标准语法中的宏字符（判断 symbol 名字要不要转义）、实例的 `type-of`（类名）、`char-name`、`name-char`、`standard-char-p`；`readtable` 等作为内建类，因为 Incless 在它们上面特化了方法。

**Quaviver 的替身**（`quaviver.lisp`）：Incless 和 Invistra 只用到 Quaviver 的三个函数，kiln 自己实现：

- `float-triple`：最短往返十进制表示，由 runtime 的 `kiln_rt_float_decimal`（`%primop :float-decimal`）用 Rust 的浮点格式化计算；以 2 为底时用 `integer-decode-float`；
- `write-digits`：照搬 Quaviver 的语义（小数点位置、前导零、数字分组）；
- `count-digits`。

真正的 Quaviver 有 7000 行，还没有接入。非规格化数打印成最短的等价形式（`5.0d-324`，SBCL 打印成 `4.9406564584124654d-324`）。

**编译器原语 `print`**：AOT 和交叉编译的模块里，单参数的 `print` 仍由编译器内联成 runtime 的打印器：先打印对象再换行，不经过 `*standard-output*`、`print-object` 和打印变量。测试的期望输出依赖这个格式。`#'print` 和编进 image 的代码用的是 Incless 的正确版本。

## FORMAT（Invistra）

`format` 和 `formatter` 都是 Invistra 的。kiln 的 client 在 `format.lisp`，它同时是打印器的 client（Invistra 通过 Incless 打印对象）。

- 依赖：Quaviver（替身）、nontrivial-gray-streams（`ngray`）、Acclimation（English）、Inravina。
- 补丁：
  - `formatter` 展开成在运行期解释控制串的函数，返回 NIL 而不是剩余参数，因为 Invistra 的格式编译器是目标端代码，宏展开时不可用；
  - 宏展开要用的 `unique-name` 在编译期也定义；
  - 浮点的无穷和 NaN 通过 `float-triple` 判断；
  - 输出到带 fill pointer 的字符串时，先在它上面开一个字符串输出流；
  - 控制串的解析结果按内容缓存。
- Cyclosis 的 `y-or-n-p` 经 Trinsic 的 `cell-value` 取 `format`，kiln 的 client 提供这个方法。输入按字符读，回答后面的换行也算一次无效回答，会多提示一次；`clear-input` 对 POSIX 流不起作用。
- 编译期不编译控制串（编译器宏被忽略），每次调用都解释。
- 上游的舍入问题（未修）：`(format nil "~,1f" 0.05f0)` 给出 `"0.0"`，应该是 `"0.1"`；在 SBCL 上配原版 Quaviver 也一样。

## 美化打印（Inravina）

CL 的美化打印函数和宏都是 Inravina 的（`pprint-logical-block`、`pprint-newline`、`pprint-dispatch`、`*print-pprint-dispatch*` 等）。kiln 的接口在 `pprint.lisp`：

- client 类 `inravina-intrinsic:kiln-client` 继承 Incless 的 client 和 `inravina:client`，替换掉 `incless::*client*`；Invistra 的 client 继承它。接口里不是 CL symbol 的名字（标准 dispatch 表、`pretty-stream-p`）放在 `inravina-intrinsic` 包里。
- `with-standard-io-syntax` 把 `*print-pprint-dispatch*` 绑定为标准表。
- `logical-block.lisp` 在编译期也求值，因为 `pprint-logical-block` 的展开函数在宏展开时调用。
- 补丁：识别 Eclector 的反引号符号，`` `(a ,b ,@c) `` 打印成反引号形式。
- kernel 加了 `special-operator-p` 和总是返回 NIL 的 `function-lambda-expression`。
- 和 SBCL 的差异：Inravina 允许一行恰好写到 `*print-right-margin*` 列，SBCL 在到达这一列之前就换行。`*print-pretty*` 的默认值是 NIL。
