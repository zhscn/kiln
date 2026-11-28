# 流、文件、读入和打印

这些都编进 CLOS 模块，用 intrinsic 接口：CL 的流、读入、打印、FORMAT 函数就是 Cyclosis、Eclector、Incless、Invistra、Inravina 的函数。kiln 的 client 在 `lisp/target/clos/` 下，vendor 的补丁见 `vendor/README.md`。

## 系统接口

- `kiln_rt_fd_read`、`kiln_rt_fd_write`（`%primop :fd-read`/`:fd-write`）：参数是 `(unsigned-byte 8)` 向量的原生存储。
- `kiln_rt_sys(op, a, b, c)`（`%primop :sys`）按 `op` 分派文件系统调用和时钟：open、close、lseek、unlink、rename、mkdir、rmdir、stat、fstat、getcwd、realpath、getenv、列目录、strerror、单调时钟、Unix 时间、进程 CPU 时间、sleep、exit。
  - 文件名以 UTF-8 八位组的 simple vector 传入。
  - 返回名字的调用把结果存进作为最后一个参数传入的 simple vector，返回值是结果的长度；长度超过向量时什么也不存，Lisp 侧换一个更长的向量重试。
  - 失败时返回负的 errno。
  - 用一个入口而不是每个系统调用各导入一个函数，KIR 和 kiln-cg 都不必为新调用改动。所有系统调用经过同一个入口，以后的记录与回放也依赖这一点。

## 进程环境

`kiln.sys:getenv` 返回环境变量的字符串值，缺失时返回 NIL，空值保留为空字符串。
`kiln.sys:getcwd` 返回进程当前目录的绝对目录 pathname。
`kiln.sys:getpid` 返回当前进程 ID。
`kiln.sys:command-line-arguments` 返回当前进程的参数列表，首项为可执行文件名；
这些查询在恢复快照后仍读取当前进程，不保存构建期的环境值。

## 同步子进程

`kiln.sys:run-process` 接受非空字符串列表，首项为程序名，其余各项原样传递给
子进程。调用者可显式使用 `("/bin/sh" "-c" 命令)` 执行 shell 语法。默认继承标准流。
传入 `:output` 字符流时，子进程从空设备读入，标准输出先写入匿名文件，等待结束后
按 UTF-8 解码并写入该流。标准错误仍继承。使用匿名文件可以让子进程在调用方等待
期间继续输出，容量受操作系统资源约束。

接口返回退出状态，信号终止返回 128 加信号号，启动或等待失败发出错误。等待期间
当前 Lisp 执行流阻塞。UIOP 的同步执行沿用其 shell 转义、重定向和退出状态处理。

## 环境信息

环境查询函数从当前运行进程获取机器和操作系统信息，恢复堆快照后仍查询当前主机。系统接口 20 把选择器 `a` 对应的 UTF-8 字符串写入缓冲区 `b`：0 为 Cargo 包版本，1 为操作系统名，2 为内核发行版本，3 为主机名，4 为架构名，5 为 CPU 型号。CPU 型号来自 Linux 的 `/proc/cpuinfo`；无法获取时 `machine-version` 返回 NIL。架构名采用 SBCL 的拼写，例如 `X86-64`。

`lisp-implementation-type` 返回 `"kiln"`。`short-site-name` 和 `long-site-name` 返回各自的运行期配置变量，初始为 NIL。

`room` 将运行中的 MMTk 堆统计写到 `*standard-output*`。NIL 只报告使用量，`:default` 增加堆容量、空闲页字节数和已完成的 GC 次数，T 再报告静态根槽数。系统接口 22 的选择器 0、1、2、3 分别返回使用字节数、空闲字节数、堆容量和静态根槽数；前三项按 MMTk 页粒度计量。`room` 返回零个值。

## 日期和时区

`decode-universal-time` 和 `encode-universal-time` 在 Lisp 层做公历换算，支持秒精度的有理数时区。显式时区不应用夏令时；缺省时区通过系统接口 19 查询指定 Unix 秒的向西偏移（选择器 0）或夏令时标志（选择器 1），查询失败返回负 errno。解码返回的时区是标准时偏移，夏令时单独返回。

本地时区使用操作系统的时区数据库。与 SBCL 一致，超出有符号 32 位 Unix 时间范围的日期按距三月一日的年内偏移映射到 1903 或 2035 年后查询时区。编码先估算偏移，再按所得 UTC 时刻修正；夏令时跳变处沿用 SBCL 的两次查询策略。两位年份按当前年份前后五十年的窗口解释。

## 流（Cyclosis）

`peek-char` 的 peek-type 为 T 时，按当前 `*readtable*` 的语法类型跳过空白；`set-syntax-from-char` 对空白语法的修改立即生效。 字符流的 peek 先查看 `unread-char` 缓冲；字符串流的 `file-position` 和读入结束索引指向下一个字符，设置位置会丢弃回退字符。

对字符串输出流写入字符串时，`write-sequence` 与 `write-string` 共用追加路径。已验证的原生来源和未位移字符缓冲区在容量充足时一次遍历完成复制和光标更新。需要扩容时按几何比例增大缓冲区，再复制指定区间；其他字符串表示使用通用复制路径。

- Cyclosis 用 Trinsic 的 `make-define-interface` 生成 CL 的流函数和宏，展开在 kiln 的 client 文件（`streams.lisp`）里。
- 上游的 intrinsic 接口在自己的包里遮蔽 `stream`、`close`、`streamp` 等名字，加载时再 `shadowing-import` 进 CL；kiln 的运行期包是宿主包的镜像，这一步做不了，所以补丁让 Cyclosis 直接使用这些 CL symbol。需要 client 参数的函数（`open`、`peek-char` 等）仍然遮蔽。
- **标准流**：文件描述符 0、1、2 上的 POSIX 流，经 synonym stream 绑定到 `*standard-input*`、`*standard-output*`、`*error-output*` 等。标准输入使用读缓冲。标准输出和标准错误写入后立即交给描述符，保持和 runtime 输出的顺序。`stream-write-string` 按块编码 UTF-8，并交给 `stream-write-octets` 写出。以字符串为输入的 `write-sequence` 在内建字符文件流上复用这条路径，保留指定的字符串范围和输出光标。
- `nontrivial-gray-streams`：kiln 定义 `ngray` 包，转出 Cyclosis 中同名的 Gray 流 symbol（`ngray.lisp`），补上 `stream-element-type`、`stream-external-format`、`stream-line-length`。
- 字符串输出流按倍数增长（上游每次只加长 32，写入是平方级）。
- 上游修正：UTF-8 编码时三字节的上界、解码时的移位方向、`stream-advance-to-column` 写换行而不是空格。

## 会话记录

`dribble` 将标准输入读到的内容、标准输出和错误输出写入记录文件。输入通过
echo stream 记录，两个输出通过 broadcast stream 复制，原有流保持可用。
传入 pathname 开始记录，省略参数或传 NIL 停止；两种操作均返回零个值。
`:if-exists` 默认是 `:append`，也可指定文件覆盖策略。

每次开始记录都会保存当前记录文件和三条标准流，支持嵌套。停止时关闭当前记录
文件，并恢复上一层的绑定。新文件和包装流全部准备成功后才切换；启动失败保持
原状态。关闭记录文件时发生错误也会恢复流绑定，并尝试释放当前文件资源。
没有活动记录时调用停止操作会报告错误。

## pathname 和文件

**pathname**（`pathnames.lisp`）是标准对象，它的类以内建类 `pathname`（或 `logical-pathname`）为超类，做法和 Regalia 的数组一样。

- 物理 pathname 按 SBCL 在 Unix 上的规则解析：`~/` 是 `(:absolute :home)`，`..` 是 `:up`；`*` 和 `**` 是 `:wild` 和 `:wild-inferiors`，名字里带 `*` 的串是通配模式；以点开头的文件名没有类型；有名字时版本是 `:newest`。`..` 作为文件名时名字就是 `".."`（SBCL 解析成名字 `"."`、类型 `""`）。
- 逻辑 pathname 的设备是 `:unspecific`，省略目录时为 `(:absolute)`，显式 `:newest` 版本保留在 namestring 中。`open` 后流的 pathname 保留逻辑组件；文件系统调用使用翻译后的物理名字。`logical-pathname-translations` 登记 host，`translate-logical-pathname` 按第一条匹配的转换翻译，翻译到物理 pathname 时转成小写。
- `pathname-match-p`、`translate-pathname` 支持 `:wild`、`:wild-inferiors` 和名字里的 `*`。
- `equal` 和 `equalp` 按分量比较 pathname（kernel 的 `equal` 对标准实例调用 `*instance-equal*`）。
- `file-author` 用系统接口 21 查询文件所有者：`stat` 取得 UID，`getpwuid_r` 解析用户名，再写入调用方的八位组缓冲区。普通符号链接查询目标的所有者，悬空或自指链接查询链接本身。与 SBCL 一致，UID 没有对应账户时报告错误；不存在的文件、系统查询失败和通配路径报 `file-error`。
- 文件系统函数：`probe-file`、`truename`、`file-write-date`、`delete-file`、`rename-file`、`ensure-directories-exist`、`directory`、`user-homedir-pathname`。`*default-pathname-defaults*` 在启动时（包括从快照启动时）设为当前目录。
- 限制：只支持 Unix 的物理 pathname，没有 host 对象（物理 pathname 的 host 是 NIL），名字里不能用反斜杠转义；`directory` 不解析符号链接；编译器不支持 pathname 常量。

**文件流**（`files.lisp`）：`kiln-file-stream` 是 Cyclosis 的 `posix-file-stream` 加一个容量为 8192 八位组的缓冲，底层使用 simple vector。
标准输入复用文件流的输入缓冲和 UTF-8 字符快路径。标准输出和标准错误直接写入描述符。
恢复快照时，标准输入丢弃保存进程的预读字节和字符游标，因为新进程使用自己的描述符。

文件流把字节缓冲、输入起止、待输出长度和 UTF-8 分类缓存放在原生结构
`file-buffer-state` 中。ASCII 字符快路径只获取一次该结构，直接读取或更新字段；
Cyclosis 的外层方法仍负责 unread 和游标，非 ASCII、缓冲补充及其他外部格式仍走
转换器。文件位置、读写切换和输出刷新共享同一份缓冲状态。
默认字符流的 `read-line` 用原生字符串积累字符，缓冲写满时扩容，返回时裁成实际行长。
调用者可以直接用 `schar` 读取结果。输入在换行前结束时，第二返回值为真。
八位组文件流与专用八位组向量之间的 `write-sequence` 直接分块写入缓冲。
FASL 的包向量先检查元素范围。较大的 simple-vector 八位组区间先刷新待写数据，
再由 runtime 分块打包并写入描述符。分块限制临时字节缓冲的大小，每次写入后
更新文件位置。读入较大的 simple-vector 八位组区间时，先用完缓冲中的预读数据，
再由 runtime 分块直接填入目标区间。读到文件末尾时返回已填到的位置。
其他序列及元素宽度沿用通用流方法。

- Cyclosis 的转码器逐个八位组读写，没有缓冲的话每个八位组都是一次系统调用。
- 同一个缓冲先用于读还是写，取决于下一个操作：写之前把预读的部分用 lseek 退回，读之前先写出待写的部分。`finish-output`、`force-output`、`close`、`file-position`、`file-length` 之前都先写出缓冲。
- `file-position` 扣除 `unread-char` 退回的字符（源码位置依赖它，[front-end.md](front-end.md)）。字符流的 `file-position` 以八位组计。
- `make-file-stream` 是 kiln client 的方法：`:supersede` 和 `:rename-and-delete` 直接截断文件，不写临时文件；`:rename` 把原文件改名为 `原名.bak`；`:new-version`（输出的默认值）和 `:error` 一样，文件存在就报错，和 SBCL 一样。

**时间**（`time.lisp`）：`get-internal-real-time` 和 `get-internal-run-time` 以微秒计；`get-universal-time`、公历换算和本地时区查询使用上文的日期接口。`time` 将实际经过时间和进程 CPU 时间写到 `*trace-output*`，保留原形式的词法环境和全部返回值，正常返回与非局部退出时都会报告。`sleep` 期间其他线程不能做 GC（现在还没有其他线程）。

## 读入（Eclector）

Eclector 同时是宿主前端的 reader 和目标端的 reader。CLOS 模块里有 base、readtable、simple readtable 和 reader；parse result 和 CST 读取器在 frontend 模块。kiln 的接口在 `reader.lisp`。

- Eclector 的源码读进宿主里已有的 Eclector 包，其中 `eclector.readtable` 遮蔽了 CL 的 readtable 函数和 `*readtable*`。所以 CL 的 `read`、`read-from-string`、`read-preserving-whitespace`、`read-delimited-list` 和各个 readtable 函数都转调 Eclector 的同名函数；kiln 的 Eclector client 让 `cl:*readtable*` 读写和绑定 CL 的变量；`get-macro-character` 和 `get-dispatch-macro-character` 把 Eclector 存的符号换成函数；`with-standard-io-syntax` 绑定 Eclector 的标准 readtable。
- kiln 的 Eclector client 只在 CL 的读入函数里绑定，不全局设置：Eclector 的其他入口用 `(or *client* 默认 client)` 选 client，全局设置会让 CST 读取器用错 client。
- simple readtable 的类以内建类 `cl:readtable` 为超类，`readtablep` 成立。
- 读入的 `` ` `` 形式是 Eclector 的 `quasiquote` 宏调用，运行期可以展开。常量模板识别同时遍历列表和非字符串向量，保留嵌套向量中逗号及拼接形式的求值。
- CST reader 对普通列表并行检查表达式和子结果，避免重复求长度和异常处理。根节点在构造时获得源码位置，尾节点保留默认位置；原始列表与子 CST 的身份保持不变。单个点对有直接构造分支，其余结构不匹配的 reader macro 结果使用完整的重建路径。
- 简单 readtable 的 ASCII 语法类型存放在每实例向量里；修改语法、安装宏字符和复制时同步更新，非 ASCII 仍走哈希查询。可变 readtable 之间不共享分类向量。
- 十进制浮点 token 先用尾数位数和指数证明是否必然落在最小次正规数的一半以下，或超过最大有限值。极端值使用有界的有理数代表量交给原有浮点转换，保留舍入与异常处理，避免构造巨大十进制幂；临界值继续精确转换。
- token 临时数组使用有界池，借出后从池中移除，嵌套读入使用不同数组；非局部退出归还数组。池最多保存八个不超过 4096 字符的数组，最终 token 始终复制成独立字符串。
- 编译器的 CST client 在重建 car、cdr 时共享只读的子 cons 索引，各自保留引用筛选、原子选择和构造表。其他 client 使用默认重建协议。

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
  - `formatter` 在运行期解析控制串并创建解释执行的函数，返回未消费的参数；`~^` 提前退出后仍从当前参数游标取得返回值。Invistra 的格式编译器是目标端代码，宏展开时不可用；
  - 宏展开要用的 `unique-name` 在编译期也定义；
  - 浮点的无穷和 NaN 通过 `float-triple` 判断；
  - 输出到带 fill pointer 的字符串时，先在它上面开一个字符串输出流；
  - 控制串的解析结果按内容缓存。
- Cyclosis 的 `y-or-n-p` 经 Trinsic 的 `cell-value` 取 `format`，kiln 的 client 提供这个方法。输入按字符读，回答后面的换行也算一次无效回答，会多提示一次。`clear-input` 丢弃标准输入已读入缓冲的字节和回退字符。
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
