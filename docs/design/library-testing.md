# 第三方库兼容性与迭代成本

第三方库验证同时检查语言兼容性、数值正确性和开发反馈时间。能读入源码、完成
编译、加载 FASL 和通过上游测试是不同结果；构建系统或实现扩展缺失时，先记录
阻塞所在的接口，不能把它归为优化器性能问题。

## 样本与版本

`tests/libraries.json` 固定样本的仓库和修订。样本从 awesome-cl 选择，按使用的
语言机制分组，另列构建系统和测试框架等依赖。上游源码放在外部 corpus，归档发布的依赖另固定下载地址、归档和源码校验和。
清单中的兼容补丁在原始修订上应用，报告记录补丁校验和；已有兼容修改不会重复应用。

`tools/test-libraries.py fetch` 获取并检查版本，已有目录不会被重置。
使用 `--corpus` 选择目录；测试输出留在忽略的 `build/` 目录。

| 样本 | 主要覆盖 |
|---|---|
| Alexandria、Iterate | 宏、编译期环境、代码遍历及求值顺序 |
| FiveAM、Closer-MOP | condition、测试执行和 MOP 可移植接口 |
| CL-PPCRE | 生成闭包、动态编译、字符串及数组访问 |
| Jzon、FSet | 解析、哈希表、持久集合与递归算法 |
| Babel、Flexi-streams、Local-time | 编码、专用数组、Gray streams、时间与文件接口 |
| Lisp-Stat 及 num-utils、statistics、special-functions | 数值算法、统计误差、泛型接口和综合依赖 |
| Float-features | 非 ANSI 的 IEEE 浮点接口及实现适配 |
| Maxima | 符号运算、有理数、bignum、任意精度浮点与大型系统构建 |

主系统和测试系统可以依赖 corpus 之外已安装的库。宿主模式继承 ASDF 注册表，
因此其日志与源码顺序用于检查实际选中的依赖；固定主仓库修订不等于已经锁定
整个依赖闭包。复现实验时还需保留依赖版本和实现配置。

## 分层运行

先在 SBCL 上运行上游的加载和测试，确认样本版本及测试依赖可用：

```sh
python3 tools/test-libraries.py fetch
python3 tools/test-libraries.py sbcl alexandria cl-ppcre iterate --tests \
  --output build/libraries/host
python3 tools/test-libraries.py asdf asdf --kiln build/boot/kiln1 \
  --output build/libraries/asdf
```

宿主运行每个系统使用独立进程和单独的 FASL 输出目录。首次使用新输出目录得到
冷缓存数据；重复使用会复用 ASDF 产物，不能把两者混作同一条件。
`--tests` 调用上游的 ASDF `test-op`。有些上游测试只打印失败而不向 ASDF 发出
错误，因此报告的 `test_op_completed` 仅表示操作正常返回，还必须核对上游摘要。
缺失测试依赖与主库加载失败分别记录。

ASDF 探测默认使用 vendored ASDF/UIOP，`--asdf-directory` 可选择其他副本。
它显式识别 kiln，使用 `kiln.sys` 的进程查询和退出接口；环境修改、子进程、
动态库及可执行镜像导出仍需各自的平台实现。生成 bundle 后也可在 image 中执行：

```lisp
(require :asdf '("tools/load-asdf.lisp"))
```

加载器只在 ASDF 源码初始化期间选择 HIR 求值，返回后恢复调用方的原生编译设置。
库的编译与测试直接经过目标 ASDF：

```sh
python3 tools/test-libraries.py kiln alexandria cl-ppcre iterate --tests \
  --kiln build/boot/kiln1 --output build/libraries/target
```

独立进程分别记录主库加载和上游测试操作是否完成。出现错误或超时时保留进度日志。
目标进程共享同一批次的 FASL 缓存，按编译器可执行文件校验和及后端指纹隔离；
编译器改变后重新编译依赖。已内置的 Closer-MOP 兼容接口登记为不可重载的预加载系统。
通用的测试操作正常返回仍不足以判断通过：工具额外检查 FiveAM、Parachute 等摘要
中的失败数、Stefil 的失败详情和 RT 的意外失败数，其他框架的摘要仍需逐项核对。
对明确声明为可移植的样本，可以用源码探测进一步隔离问题：

```sh
python3 tools/test-libraries.py source alexandria cl-ppcre iterate \
  --kiln build/boot/kiln1 --plan-directory build/libraries/host \
  --output build/libraries/native
```

源码探测使用 SBCL 的 ASDF 加载顺序，只接受全部源码均属于该项目的计划。
kiln 顺序执行原生 `compile-file` 和 FASL `load`，随后运行小型功能断言。
它检查编译器和库的部分基本行为，不证明 kiln 的 ASDF 支持，也不替代上游套件。
宿主与目标的 reader feature 条件和系统操作仍可能不同；含实现专用组件的库
不能直接借用宿主计划。

每个探测设置超时并在首个错误处停止。逐文件的开始标记及编译、加载时间直接
写入进度日志，超时后仍可找到正在处理的文件。报告保留主仓库修订、目标可执行
文件校验和、堆配置、源码校验和和 FASL 大小。源码路径只出现在本地测量产物中。

## 数值验证

[Lisp-Stat 的安装说明](https://lisp-stat.dev/docs/getting-started/installation/)以 SBCL 为开发和支持平台，并指出 CCL 存在未修复的数值
问题。其 special-functions 测试包含 Boost 来源的参考数据，分别检查最大、平均
和 RMS 误差。保留各数据集的有效范围和容限，不用统一放宽阈值掩盖差异。
上游禁用的用例也应单独检查其原因，不能把未执行的部分视为通过。

数值适配先运行纯 Lisp 的 num-utils、statistics 和 special-functions，再接入
数据框及完整 Lisp-Stat。绘图、HTTP、BLAS 或其他外部依赖造成的阻塞单独处理。
对发现的差异提取小型回归用例，比较 HIR 求值与原生代码，并覆盖不同优化策略，
区分 reader、数值 runtime、算法及 MIR 改写的问题。精确整数与有理数逐值比较；
浮点采用对应测试的误差定义，并检查负零、次正规数、上下溢、复数分支及格式差异。
SBCL 提供行为参照，高精度或独立参考数据用于判断数值精度。

Maxima 使用自身构建系统，单独按其构建说明建立 SBCL 参照。其 core 与 share
套件分别记录；启动测试时禁用用户初始化文件，核对实际执行的文件、题目及已知
失败，不能只根据进程退出码判断通过。Maxima 的任意精度计算补充机器浮点测试，
但不能代替底层浮点原语的边界测试。

## 控制迭代成本

分别记录进程启动、源码编译、FASL 加载和测试运行。kiln 的目标 FASL 保存 LIR，
加载会执行后端代码生成，加载时间因此也是原生编译成本的一部分。宿主 FASL
格式不同，比较时应同时展示编译与加载，而非只比较 `compile-file`。

调试一个库时复用现有编译器可执行文件，只重跑所选库和最小失败用例；修改
runtime 或编译器才重建对应基础环境。先衡量首次加载、重复加载、单文件修改及
单函数重编译，再选择缓存或优化工作。完整自举吞吐不能替代这些迭代场景。
性能测量遵守 [compiler-performance.md](compiler-performance.md) 的隔离、预热和
重复条件，避免同时运行多个编译或重型测试。单次探测用于发现热点，不作为稳定
性能结论。
