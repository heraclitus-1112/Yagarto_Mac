# YAGARTO Mac

YAGARTO Mac 是一个面向 macOS 的非官方 YAGARTO 兼容命令行层，不隶属于原 YAGARTO 项目或 Arm，也不分发旧版 YAGARTO 二进制。

它提供 `yagarto.json` 项目配置、Arm GNU Toolchain 构建、ELF 反汇编，以及 `run`、`debug`、`flash`。三个 profile 都使用参数数组启动工具；GDB 与 QEMU/OpenOCD 通过 stdio pipe 连接，不占用固定 TCP 端口。

## 后端与边界

| profile | 首选后端 | 能力边界 |
| --- | --- | --- |
| `arm7tdmi` | 支持 `target sim` 的 GDB | 最接近旧课件里的 GDB simulator。普通 `arm-none-eabi-gdb` 只有在能力探测实际成功后才会被采用。 |
| `arm7tdmi` 回退 | QEMU `integratorcp` + ARM926 | ARM926 是 ARM7TDMI 的兼容超集，不是精确 ARM7TDMI 模型；命令会明确给出中文警告。 |
| `cortex-m4` | QEMU `mps2-an386` | 适合运行本项目生成的 Cortex-M4 裸机 ELF；它不是 STM32F407 外设模型。 |
| `stm32f4-discovery` | OpenOCD + `stm32f4discovery.cfg` | 面向连接到 Mac 的真实开发板和调试器，不是 STM32 外设模拟器。`run`/`debug` 只 attach/reset，不写 Flash；烧录只能通过带确认门的 `flash`。 |

`cortex-m4` 和 `stm32f4-discovery` 构建会自动加入内置向量表与 `Reset_Handler`。前者链接到 MPS2 的 0 地址代码区并使用 `0x20400000` 初始栈顶；后者链接到 `0x08000000` Flash 并使用 `0x20020000` 初始栈顶。启动代码会复制 `.data`、清零 `.bss`，再调用 `yagarto.json` 中的用户 `entry`。

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

对 `stm32f4-discovery`，请先通过 `flash --yes` 明确完成写入，再使用 `run`/`debug` attach。OpenOCD 调试日志使用随机文件名，并在启动前以排他、禁止跟随符号链接的方式创建。

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

已自行下载固定归档时可增加 `--archive /absolute/path/gdb-17.2.tar.xz`；SHA-256 仍然必填。

也可对现有 GDB 单独重跑相同的完整自测（不会下载或编译 GDB）：

```sh
scripts/bootstrap-gdb-sim.sh --verify-gdb /absolute/path/to/arm-none-eabi-gdb
```

内置链接脚本、启动文件通过 SwiftPM 的 `Bundle.module` 资源包加载。请通过 `swift run` 或完整 SwiftPM 构建产物运行；不要只复制裸可执行文件而遗漏资源包。

本项目采用 GNU General Public License v3.0 or later，详见 `LICENSE`。
