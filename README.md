# YAGARTO Mac

YAGARTO Mac 是一个面向 macOS 的非官方 YAGARTO 兼容命令行层，不隶属于原 YAGARTO 项目或 Arm，也不分发旧版 YAGARTO 二进制。

> **非官方兼容实现：** 本项目不是原 YAGARTO 的 macOS 版本，也不隶属于 YAGARTO、Arm、STMicroelectronics 或 GNU。它通过当前工具链复现课程所需工作流，但不会把近似模拟写成精确硬件行为。

它提供 `yagarto.json` 项目配置、Arm GNU Toolchain 构建、ELF 反汇编，以及 `run`、`debug`、`flash`。三个 profile 都使用参数数组启动工具；GDB 与 QEMU/OpenOCD 通过 stdio pipe 连接，不占用固定 TCP 端口。

## 文档与示例

- [中文快速入门](docs/quick-start.zh-CN.md)：安装、doctor、项目命令、产物与退出码。
- [Emacs 30.2 集成指南](docs/emacs.zh-CN.md)：安全安装、快捷键、GDB/MI、内存与进程清理。
- [目标差异与排障](docs/targets-and-troubleshooting.zh-CN.md)：AArch64/ARM32、CPSR/xPSR、各后端边界和环境验收。
- [原创示例](examples/)：四个 ARM7、一个 Cortex-M4、一个 STM32F4-Discovery 项目。

Apple Silicon Mac 使用 AArch64，不能直接运行课程的 ARM32 ELF；Arm GNU Toolchain 能编译并不等于能模拟。选择后端前先运行 `yagarto-mac doctor`。

Emacs 集成不会静默修改 init 文件。先审阅 `scripts/install-emacs.sh --print`，再由用户明确执行 `--install` 并在 TTY 输入 `yes`；完整行为见 Emacs 指南。

## 后端与边界

| profile | 首选后端 | 能力边界 |
| --- | --- | --- |
| `arm7tdmi` | 支持 `target sim` 的 GDB | 最接近旧课件里的 GDB simulator。普通 `arm-none-eabi-gdb` 只有在能力探测实际成功后才会被采用。 |
| `arm7tdmi` 回退 | QEMU `integratorcp` + ARM926 | ARM926 是 ARM7TDMI 的兼容超集，不是精确 ARM7TDMI 模型；命令会明确给出中文警告。 |
| `cortex-m4` | QEMU `mps2-an386` | 适合运行本项目生成的 Cortex-M4 裸机 ELF；它不是 STM32F407 外设模型。 |
| `stm32f4-discovery` | OpenOCD + `stm32f4discovery.cfg` | 面向连接到 Mac 的真实开发板和调试器，不是 STM32 外设模拟器。`run`/`debug` 只 attach/reset，不写 Flash；烧录只能通过带确认门的 `flash`。 |

`cortex-m4` 和 `stm32f4-discovery` 构建会自动加入内置向量表与 `Reset_Handler`。前者链接到 MPS2 的 0 地址代码区并使用链接器定义的 `0x20400000` 初始栈顶；后者链接到 `0x08000000` Flash 并使用链接器定义的 `0x20020000` 初始栈顶。两套链接脚本都把可用 RAM 与独立 4 KiB `STACK` MEMORY region 物理拆开。可写段采用显式命名契约：带初值的数据放在 `.data` 或 `.data.*`，需清零的数据放在 `.bss` 或 `.bss.*`，需跨复位保留且不进入镜像的数据放在 `.noinit` 或 `.noinit.*`。启动代码复制 `.data`、清零 `.bss`、保留 `.noinit`，再调用 `yagarto.json` 中的用户 `entry`；未分类的 orphan section 会在链接时明确报错，不会被静默放入 RAM 或膨胀 Flash 镜像。

## 使用

```sh
swift run yagarto-mac doctor
swift run yagarto-mac doctor --format json
swift run yagarto-mac init --profile arm7tdmi
swift run yagarto-mac profile set cortex-m4
swift run yagarto-mac build
swift run yagarto-mac disassemble

# 先审阅完整启动计划；ELF 省略时从配置推导
swift run yagarto-mac debug --dry-run --format json
swift run yagarto-mac run firmware.elf --profile cortex-m4 --dry-run

# 实际交互运行继承终端 stdin/stdout/stderr；Ctrl-C 返回 130
swift run yagarto-mac debug
swift run yagarto-mac run

# 烧录也可先审阅计划；dry-run 不探测开发板且不要求 --yes
swift run yagarto-mac flash firmware.elf --profile stm32f4-discovery --dry-run --format json

# 实际烧录只支持真实 STM32F4 Discovery，且必须显式确认
swift run yagarto-mac flash firmware.elf --profile stm32f4-discovery --yes
```

对 `stm32f4-discovery`，请先通过 `flash --yes` 明确完成写入，再使用 `run`/`debug` attach。OpenOCD 的诊断直接写入继承的标准错误流；GDB remote 协议仍独占管道标准输出，不会在项目目录创建或重开日志路径。debug 只启用 pipe GDB 端口，flash/probe 则禁用 GDB、Tcl、telnet 全部网络服务，不监听默认的 3333/4444/6666 端口。

同一项目、同一 profile 的并发 `build` 使用 `.yagarto/build/.<profile>.lock` 串行化：后启动者会阻塞等待当前构建完成，再进行残留清理和发布；不同 profile 使用不同锁，可以并行。锁描述符不会继承给工具进程，构建失败或 CLI 被信号终止时由进程关闭并释放；锁文件本身会保留供后续构建复用。

取得锁后，构建会在同卷私有 staging 目录完成并验证所有产物，再以原子目录交换发布；文件系统不支持该能力时会在启动工具前失败。发布前会把 `.map`/`.lst` 中的 staging 路径改回稳定最终路径，并只清理当前 profile 且严格匹配 UUID 命名的陈旧 staging/old/swap-probe 目录。

实际烧录前会先通过 macOS `system_profiler` 只读枚举 ST-Link USB VID/PID。明确没有匹配设备时返回 6，且不会启动 OpenOCD；枚举失败，或已有 ST-Link 候选但 OpenOCD 报告 open/权限/占用/配置等错误时返回 4 并保留原始诊断。`flash --dry-run` 不会执行 USB 枚举、OpenOCD 探测或烧录。

`doctor` 分别报告常规 GDB、simulator GDB 候选、二者的 `target sim` 能力、QEMU、OpenOCD、`stm32f4discovery.cfg`，并列出三个 profile 将采用的 backend 与 GDB。JSON 报告带 `schemaVersion`，可与 `run/debug --dry-run --format json` 的选择交叉检查。

非交互输出支持 `--format text`（默认）或 `--format json`，错误使用统一 JSON envelope。实际 `run`/`debug` 会把终端直接交给 GDB，因此只允许 `--format text`；若指定 JSON 会在启动任何后端前以退出码 2 拒绝。需要 JSON 时使用 `--dry-run`。父 CLI 通过 kqueue 监听 `SIGINT`、`SIGTERM` 和 `SIGHUP`，按“原信号、短暂宽限、`SIGTERM`、短暂宽限、`SIGKILL`”有界清理整个受控进程组并回收组长；退出状态分别遵循 130、143 和 129。

项目不会自动安装 QEMU。若要使用 QEMU 后端，请通过你信任的包管理器安装 `qemu-system-arm`，再用 `doctor` 确认路径。`arm7tdmi` 只在没有可用 GDB simulator 时回退到 ARM926；`cortex-m4` 则要求 QEMU 提供 `mps2-an386` machine。

测试套件在检测到 QEMU 时验证上述 machine；未安装 QEMU 时只跳过这一项环境相关 E2E，后端参数、pipe quoting 和缺工具错误仍由不依赖 QEMU 的测试覆盖。

## 构建支持 `target sim` 的 GDB

部分现代 Arm GNU Toolchain 所带 GDB 没有内置 simulator。辅助脚本固定使用 GNU GDB 17.2 源码，并且不会跳过源码校验：调用者必须从可信渠道取得该发布包的 SHA-256。

脚本会检查 `gmake`、GMP、MPFR 和 Texinfo，配置 `--target=arm-none-eabi`，保留 simulator。安装后它使用 `arm-none-eabi-as`/`arm-none-eabi-ld` 生成最小 ARM7 ELF，并依次验证 `target sim`、`file`/`load`、断点命中、`stepi`，以及读取 `r0`–`r12`、GDB 的规范别名 `sp`/`lr`/`pc` 和 `cpsr`；全部成功后才提供 `arm-none-eabi-gdb-sim` 别名。此过程会进行较长时间的本地编译。

```sh
scripts/bootstrap-gdb-sim.sh \
  --prefix "$PWD/.tools/gdb-sim" \
  --sha256 '<gdb-17.2.tar.xz 的 64 位 SHA-256>'

export YAGARTO_MAC_GDB_SIM="$PWD/.tools/gdb-sim/bin/arm-none-eabi-gdb-sim"
```

已自行下载固定归档时可增加 `--archive /absolute/path/gdb-17.2.tar.xz`；SHA-256 仍然必填。脚本会先把本地归档复制到权限为 0700 的唯一临时工作目录，之后只校验并解压这一份私有快照，因此调用者路径在校验后被替换也不会改变本次构建输入。

也可对现有 GDB 单独重跑相同的完整自测（不会下载或编译 GDB）：

```sh
scripts/bootstrap-gdb-sim.sh --verify-gdb /absolute/path/to/arm-none-eabi-gdb
```

完整 GDB 自测默认限时 30 秒；需要在较慢机器上调整时，可设置正整数环境变量 `YAGARTO_GDB_VERIFY_TIMEOUT_SECONDS`。源码校验、依赖探测、configure/make/install 与 GDB 自测等可能阻塞的阶段都在独立受控进程组运行；脚本收到 `SIGHUP`、`SIGINT` 或 `SIGTERM` 时会转发原信号，经过短暂宽限后有界升级并清理临时目录。

内置链接脚本、启动文件通过 SwiftPM 的 `Bundle.module` 资源包加载。请通过 `swift run` 或完整 SwiftPM 构建产物运行；不要只复制裸可执行文件而遗漏资源包。

本项目采用 GNU General Public License v3.0 or later，详见 `LICENSE`。
