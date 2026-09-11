# Emacs 30.2 集成指南

`emacs/yagarto-mac-mode.el` 只依赖 Emacs 30.2 内置的 `json`、`compile`、`comint` 和 `gdb-mi`。Emacs 已把 `.s` 与 `.S` 文件关联到 `asm-mode`，安装片段只需在该 mode hook 中启用次模式。

## 安装必须由你确认

先只打印片段并审阅；此操作不修改任何文件：

```sh
scripts/install-emacs.sh --print
```

交互安装默认选择已有的 `~/.emacs`，否则选择 `${XDG_CONFIG_HOME}/emacs/init.el` 或 `~/.emacs.d/init.el`：

```sh
scripts/install-emacs.sh --install
```

脚本只在 TTY 中收到完整的 `yes` 后修改文件。也可明确指定路径：

```sh
scripts/install-emacs.sh --install --init-file "/Users/me/配置 目录/init.el"
```

自动化场景只有在调用者显式写出 `--yes` 时才跳过询问：

```sh
scripts/install-emacs.sh --install --yes \
  --init-file "/Users/me/配置 目录/init.el"
```

安装器拒绝相对路径、符号链接、非普通文件和危险目录目标；首次修改已有文件时保留 `.yagarto-mac.bak`，再以同目录临时文件原子替换。带完整 begin/end 标记的重复安装不会再次写入。没有确认、输入非 `yes` 或安全检查失败时不会修改 init 文件。

也可以手动使用 `--print` 的四行片段。若 CLI 不在 `PATH`，在 init 中加入绝对路径：

```elisp
(setq yagarto-mac-command
      "/absolute/path/to/yagarto-mac/.build/release/yagarto-mac")
```

还可使用命令列表，每项保持独立 argv，例如包装器及其固定参数：

```elisp
(setq yagarto-mac-command
      '("/absolute/path/to/wrapper" "--fixed-option"))
```

字符串永远表示一个完整可执行文件名，不会按空格拆分。因此可执行路径包含中文或空格时直接写成一个字符串即可。

## 模式行与快捷键

打开项目内的 `.s`/`.S` 文件后，模式行持续显示当前 profile：

- `YAG[ARM7]`：`arm7tdmi`；
- `YAG[M4]`：`cortex-m4`；
- `YAG[STM32]`：`stm32f4-discovery`；
- `YAG[无项目]` 或 `YAG[配置错误]`：需要先创建/修复 `yagarto.json`。

配置文件修改时间变化、执行 profile set 或调用 `M-x yagarto-mac-refresh-profile` 后会刷新。固定快捷键如下：

| 快捷键 | 命令 | 行为 |
| --- | --- | --- |
| `C-c C-p` | `yagarto-mac-select-profile` | 用 CLI `profile set` 修改项目配置 |
| `C-c C-b` | `yagarto-mac-build` | 在项目根运行 text build |
| `C-c C-r` | `yagarto-mac-run` | 打开可交互 comint 运行缓冲区 |
| `C-c C-d` | `yagarto-mac-debug` | 读取 dry-run JSON 后启动 GDB/MI many-windows |
| `C-c C-i` | `yagarto-mac-disassemble` | 在 compilation 缓冲区显示反汇编 |
| `C-c C-m` | `yagarto-mac-memory` | 在活动 GDB/MI 会话中查看内存 |

## build、run 与 disassemble

build 固定调用：

```text
yagarto-mac build --format text
```

工作目录是向上找到的项目根。GNU as/ld 的 `文件:行:列: Error/Warning` 在专用 compilation mode 中可由 `next-error` 或鼠标跳转；regexp 是缓冲区局部值，不会向全局重复注册。

run 使用 `make-comint-in-buffer` 把程序和每个参数分别传入，固定为 text 交互，不会请求 JSON。进程缓冲区会显示出来；使用 `M-x yagarto-mac-stop` 停止最近会话，关闭缓冲区也会清理其进程。

disassemble 默认让 CLI 从配置推导 ELF。`C-u C-c C-i` 可明确选择另一个 ELF；输出同样使用可跳转、可滚动的 compilation 缓冲区。

## debug 与 many-windows

Emacs 不自行开启 TCP 监听端口。它先在项目根执行：

```text
yagarto-mac debug --dry-run --format json
```

解析器严格验证当前成功 schema 的 `profile`、`backend`、`gdbExecutable`、`gdbArguments`、`initCommands`、`warnings`、`elf`、`projectDirectory` 类型。CLI 返回非零时则读取现有错误 envelope。验证成功后，Emacs 为 GDB 参数加入 `-i=mi`，对每个 argv 单独安全引用，设置 `gdb-many-windows` 为 `t`，再交给内置 `gdb`。

入口临时断点由 CLI 计划提供。ARM7 若回退到 ARM926/QEMU，`ARM926 是 ARM7TDMI 兼容超集，非精确模型` 会在 GDB 启动前以醒目 warning 显示。

内存查看只在活动的 Emacs GDB/MI 会话中开放。命令接受正十六进制地址（如 `0x20000000`）或正十进制地址，以及正整数字节长度；它调用 Emacs 30.2 内置 memory buffer，以 1 字节单位精确请求该长度。任何表达式、负数、零或带 shell 字符的输入都会在发送给 GDB 前被拒绝。

## 常见错误

- “未找到 `yagarto.json`”：在项目根执行 `yagarto-mac init`，或确认当前 buffer/default-directory 位于项目树内。
- “找不到 YAGARTO Mac 命令”：设置 `yagarto-mac-command` 为构建产物的绝对路径。
- “项目配置 JSON 无法解析”：修正 JSON 后保存，再执行 `M-x yagarto-mac-refresh-profile`。
- “没有活动的 Emacs GDB/MI 会话”：先用 `C-c C-d` 成功启动并停在目标上，再打开 memory。
- M4 缺 QEMU、ARM7 无 simulator/QEMU、STM32 缺 OpenOCD/板：这是后端环境门槛，不是 Emacs 自动安装或绕过的条件；先运行 `yagarto-mac doctor`。

批量验证 Emacs 30.2、ERT 与 warning-as-error byte compilation：

```sh
scripts/test-emacs.sh
scripts/test-install-emacs.sh
```

测试脚本优先使用 `$EMACS`，否则自动发现 `/Applications/Emacs.app/Contents/MacOS/Emacs` 或 `PATH` 中的 `emacs`。
