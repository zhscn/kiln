# 后端协议

`kiln.sys:serve`（`lisp/target/eval/server.lisp`）：给程序用的 REPL，使用者是工具、编辑器（[editor.md](editor.md)）和 agent。不是 MCP，也不是 Swank；以后可以在它上面接这些。它建立在帧接口（[debugging.md](debugging.md)）上。

## 模型

- 每个请求作为一个任务求值。任务未处理的错误不会结束任务：
  1. 服务端发出 condition、restart 和帧；
  2. 在 debugger 里接着处理新的请求。这一层 debugger 与出错的计算在同一个栈上，嵌套在它上面，称为一个 debug 层。
- 新请求在当前层里求值，可以再出错，于是又嵌套一层。
- 用 restart 离开一层。离开的方式取决于 restart：
  - 继续出错的计算：任务最终正常完成，或者再次出错；
  - 中止任务：每个任务都有自己的 ABORT restart；
  - 跳到外层任务的 restart：经过的任务都算中止。
- 这就是 SLIME 的 sldb 加上 `eval-in-frame` 的模型，不需要 fiber。fiber（[async.md](async.md)）以后用来同时挂起多个出错的任务，协议不变。

## 消息

请求和回复都是 S 表达式。

- 回复只用到列表、关键字、整数、`nil` 和字符串。
- 字符串里的反斜杠、双引号、换行（`\n`）、回车（`\r`）、制表符（`\t`）都转义，所以每条回复正好占一行。
- Emacs Lisp 可以直接 `read` 回复；CL 的读取器会把 `\n` 读成 `n`。
- 服务端每次读请求之前发出 `(:waiting 层)`。客户端发出一个请求之后，读回复直到这一行为止。一个请求可能引出多条回复，例如一个 restart 中止了几个任务。

| 请求 | 回复 |
|---|---|
| `(:eval ID "文本")` | 依次求值文本中的形式：`(:ok ID ("值"...) "输出")`；出错时 `(:debug ID 层 "类型" "报告" ((序号 "名字" "说明")...) (帧...) "输出")` |
| `(:frame ID 序号)` | `(:frame ID 帧)`；帧是 `(序号 "名字" "文件" 行 列 (("变量" "值")...))` |
| `(:eval-in-frame ID 序号 "文本")` | 把该帧已知的变量绑定为词法变量，在这个环境里求值文本（值是拷贝，赋值不会写回帧）；回复同 `:eval` |
| `(:restart ID 序号 ["文本"])` | 调用当前层第 N 个 restart，文本中形式的值作为参数；回复是被它继续或中止的任务的结果：`:ok`、`:debug` 或 `(:aborted ID "输出")` |
| `(:package ID "名字")` | 设置 `*package*` |
| `(:quit ID)` | `(:bye ID)`，中止所有任务，`serve` 返回 |

- 任务期间，`*standard-output*`、`*error-output*` 和 `*trace-output*` 的输出都收集起来，放进任务的结果里。
- 值用 `prin1` 打印。打印帧中的变量时，`*print-length*` 为 20，`*print-level*` 为 4。
- 返回的帧最多 30 个，去掉了两部分：
  - 发出 condition 的部分：`error`、`signal`、`%runtime-error` 等函数，以及 Clostrophilia 的分派（`debugger-frames`）；
  - 服务端求值的部分（`task-frames`）。

## 从 shell 驱动

- 设了 `KILN_SERVE` 时，构建程序（kiln1）不做构建，在标准输入输出上运行 `serve`。kiln1 链接了全部五个模块，所以 `eval` 产出原生代码。
- `tools/kiln-server.sh`：
  - `start [EXE]`：用一个 FIFO 作输入，回复追加到文件里；
  - `eval`、`frame`、`eval-in-frame`、`restart`、`package`、`send`：发出请求，打印回复直到 `(:waiting ...)`；
  - `stop`。
  
  agent 用它就够了，不需要 MCP。

```
$ tools/kiln-server.sh start
$ tools/kiln-server.sh eval '(defun h (x) (let ((y (+ x 1))) (check y) (list x y)))'
$ tools/kiln-server.sh eval '(h 9)'
(:debug 3 1 "SIMPLE-ERROR" "check 10" ((0 "ABORT" "Abort task 3.")) ((0 "CHECK" ...) (1 "H" nil nil nil (("X" "9") ("Y" "10"))) ...) "")
(:waiting 1)
$ tools/kiln-server.sh eval-in-frame 1 '(* x y)'
(:ok 4 ("90") "")
(:waiting 1)
$ tools/kiln-server.sh restart 0
(:aborted 3 "")
(:waiting 0)
```

## 测试

`tests/m6/co-server.lisp`：

- 用字符串流运行 `serve`，覆盖：定义、输出、出错、嵌套任务、帧、在帧中求值、带参数和不带参数的 restart、未知请求；
- 帧只比较函数名，因为帧中有文件名和地址。

## 限制

- 不能打断正在运行的任务（要经 poll 点，C4），任务运行期间也没有流式输出：输出在任务结束时一起返回。
- 没有定义表、跳转到定义、who-calls（[debugging.md](debugging.md) 的定义记录）。
- 没有单步、从帧返回、重新执行帧。
- 依赖追踪的警告和重编的打印都进入任务的输出（[dependencies.md](dependencies.md)）。
