# YAGARTO Mac 中文快速入门

YAGARTO Mac 是面向本仓库课程工作流的非官方兼容实现，不是原 YAGARTO 的 macOS 移植，也不隶属于 YAGARTO、Arm、STMicroelectronics 或 GNU 项目。

## 1. 先分清本机与目标机

Apple Silicon Mac 的处理器执行 AArch64 指令，常见寄存器名是 `x0`/`w0`；本课程示例是 32 位 Arm 目标代码，使用 `r0`–`r15`、ARM/Thumb 状态和目标处理器状态寄存器。Mac 能在本机编译这些文件，不代表 macOS 会直接运行生成的 ELF。

Arm GNU Toolchain 提供汇编器、链接器、objdump 和 GDB，但“能编译”不等于“已模拟”。ARM7 精确运行需要带 `target sim` 的 GDB 15.2（GDB 17.2 已移除 ARM simulator）；Cortex-M4 通用运行需要 QEMU；STM32F4-Discovery 外设效果需要真实板与 OpenOCD。

## 2. 构建本地 CLI

仓库要求 Swift 6.3 与 Arm GNU Toolchain。先在仓库根目录执行：

```sh
swift build -c release
.build/release/yagarto-mac doctor
```

不要只复制裸可执行文件：内置 linker/startup 资源由 SwiftPM resource bundle 提供。最简单的本地安装方式是保留整个构建目录，并把仓库的 `.build/release` 加到 `PATH`：

```sh
export PATH="/absolute/path/to/yagarto-mac/.build/release:$PATH"
yagarto-mac doctor
```

`doctor` 中 assembler/linker/objcopy/objdump 是构建必需项；GDB simulator、QEMU、OpenOCD 和板级配置按 profile 选用，可以缺少而不影响其他 profile 的静态构建。

## 3. 全自动创建或导入工程

新工程不需要手写 JSON 或先建子目录：

```sh
yagarto-mac new demo --profile arm7tdmi --parent "$PWD"
cd demo
yagarto-mac build
```

该命令会创建 `demo/demo.s` 与 `demo/yagarto.json`。ARM7 模板使用 `start`，Cortex-M4 和 STM32F4 模板使用 `main`；它们都包含可直接构建调试的停止循环，但不会自动构建。

已有多个互相独立的汇编文件时，可以一次整理：

```sh
yagarto-mac import ./ARM7 --profile arm7tdmi
```

目录只扫描当前一层。例如 `foo.s` 会移动为 `foo/foo.s` 并生成对应配置；源码内容不会被改写。同名目录会依次使用 `foo-2`、`foo-3`。入口优先识别 ARM7 的 `start` 或 M4/STM32 的 `main`，否则只有唯一的已定义全局符号才会被采用。入口不明确、危险链接、非 UTF-8、动态预处理/条件汇编入口或已经属于其他工程的文件会保持原位，并在汇总中说明原因；这类复杂文件仍可用兼容的 `init` 流程显式配置入口。

`import --format json` 固定输出 `schemaVersion`、`status`、`profile`、`created`、`skipped` 和 `warnings`。存在跳过项或原文件未能删除时仍保留完整报告并返回 2。

旧的 `init` 仍然可用，但它只在当前目录创建默认 `yagarto.json`，不会创建源码或文件夹：

```sh
yagarto-mac init --profile arm7tdmi
```

进入工程后使用日常命令：

```sh
yagarto-mac profile set cortex-m4
yagarto-mac build --format text
yagarto-mac disassemble --format text
```

三个有效 profile 是 `arm7tdmi`、`cortex-m4`、`stm32f4-discovery`。`yagarto.json` 当前只支持 `schemaVersion: 1`，源文件必须是项目内的相对 `.s`/`.S` 路径。

先审阅后端选择而不启动交互进程：

```sh
yagarto-mac run --dry-run --format json
yagarto-mac debug --dry-run --format json
```

实际交互必须使用 text 格式：

```sh
yagarto-mac run --format text
yagarto-mac debug --format text
```

实际 `run`/`debug` 不接受 JSON，因为终端要直接交给 GDB。dry-run JSON 才是 Emacs 等前端读取的稳定启动计划。

真实板烧录必须同时满足 profile、设备与显式确认：

```sh
yagarto-mac profile set stm32f4-discovery
yagarto-mac build
yagarto-mac flash --dry-run --format json
yagarto-mac flash --yes
```

`flash --yes` 会真实写入硬件；不要把它放进自动运行的编辑器 hook。`run`/`debug` 对 STM32 只 attach/reset，不会替你烧录。

## 4. 构建产物

产物在 `.yagarto/build/<profile>/`：

- `<outputName>.elf`：带调试信息的目标文件；
- `<outputName>.map`：链接映射；
- `<outputName>.bin`：裸二进制镜像；
- `<outputName>.lst`：带源码行的反汇编 listing。

目录名、源文件名和项目路径可以包含中文或空格。CLI 和 Emacs 集成都以独立 argv 传参；需要命令字符串的 Emacs API 会逐项使用 `shell-quote-argument`，不要自行拼接未经引用的文件名。

## 5. 退出码

| 退出码 | 含义 | 常见处理 |
| ---: | --- | --- |
| 0 | 成功 | 继续下一步 |
| 2 | 用法错误 | 检查选项、profile、`flash --yes` 或交互 JSON |
| 3 | 配置错误 | 修正 `yagarto.json`、路径或入口符号 |
| 4 | 构建/进程失败 | 阅读保留的工具诊断，修正源码或权限 |
| 5 | 缺少工具/后端 | 运行 `doctor`，安装该 profile 所需工具 |
| 6 | 当前环境不支持 | 检查内置资源或 STM32 真板连接 |
| 129 | 收到 SIGHUP | 进程组已清理 |
| 130 | Ctrl-C / SIGINT | 用户中断，进程组已清理 |
| 143 | SIGTERM | 进程组已清理 |

结构化错误写入 stderr，包含稳定的 `schemaVersion`、`success`、`exitCode` 和错误代码；人读场景直接使用默认 text 格式即可。

## 6. 下一步

- [Emacs 30.2 使用指南](emacs.zh-CN.md)
- [目标差异与排障](targets-and-troubleshooting.zh-CN.md)
- [原创示例目录](../examples/)
