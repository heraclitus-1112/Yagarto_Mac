# 目标差异、示例与排障

## 四层能力不要混为一谈

| 层次 | 能回答的问题 | 本项目对应能力 |
| --- | --- | --- |
| 编译/链接 | 源码能否变成 ARM ELF | Arm GNU Toolchain + `build` |
| 指令级运行 | 寄存器和指令执行结果是否正确 | GDB simulator 或 QEMU |
| 芯片/板级外设 | GPIO、时钟、LED 是否像真芯片 | 真实 STM32F4-Discovery；通用 M4 QEMU 不等价 |
| 硬件调试/烧录 | 是否能写 Flash、停核、单步真板 | ST-Link + OpenOCD + 显式 `flash --yes` |

Apple Silicon 的 AArch64 主机只是运行工具的平台，不能直接执行课程的 AArch32/Thumb ELF。Arm GNU Toolchain 也只保证生成目标代码；安装了编译器并不自动获得 simulator。

## profile 的真实边界

### ARM7TDMI

- 源码使用 ARM state、`r0`–`r15` 与 CPSR。
- 支持 `target sim` 且通过完整自测的 GDB 是精确首选。
- 找不到 simulator 时可回退到 QEMU `integratorcp` 的 ARM926。ARM926 是兼容超集，不是 ARM7TDMI 的精确模型，CLI 与 Emacs 都会显示 warning。
- 若两者都没有，`build`/`disassemble` 仍可用，`run`/`debug` 应以退出码 5 明确失败。

### Cortex-M4

- 用户源是 Thumb；core 自动注入向量表和 `Reset_Handler`。
- 通用运行后端是 QEMU `mps2-an386`，不是 STM32F407 外设模型。
- QEMU 缺失时不应安装或伪造运行结果；保留 build/ELF 检查，把运行列为环境验收。

### STM32F4-Discovery

- core 同样注入 Cortex-M4 启动代码，但链接地址是 STM32F407 的 Flash/RAM。
- OpenOCD 使用系统安装的 `stm32f4discovery.cfg`，目标是连接到 Mac 的真实板。
- `run`/`debug` 只 attach/reset；必须先由用户执行 `flash --yes` 才会写 Flash。
- 没有板时，dry-run 可审阅命令，真实 flash 会明确失败。不能把“构建成功”或“OpenOCD 已安装”写成“LED 已在真板点亮”。

## CPSR 与 Cortex-M 系统状态

ARM7 的 CPSR 同时承载条件标志、控制位、处理器状态和模式信息，例如 N/Z/C/V 与 ARM/Thumb 的 T 位。Cortex-M 的程序状态组织成 xPSR 视图，并把栈和中断控制拆到专用寄存器：

- `xPSR`：APSR/EPSR/IPSR 的组合视图，包含条件标志、Thumb 状态和异常号；
- `MSP`：主栈指针，复位和异常处理默认使用；
- `PSP`：进程栈指针，可供线程模式选择；
- `CONTROL`：选择线程模式权限与所用栈；
- `PRIMASK`：屏蔽可配置优先级异常的单比特控制。

因此不要把 ARM7 的 `mrs r0, cpsr` 原样迁移到 Cortex-M。M4 示例分别读取 `xpsr`、`msp`、`psp`、`control`、`primask`，正是为了让差异可观察。

## 原创示例索引

| profile | 示例 | 可审计结果 |
| --- | --- | --- |
| ARM7 | `examples/arm7tdmi/arithmetic-cpsr` | `r0 = 256 + 67 = 323`，`r1 = CPSR` |
| ARM7 | `examples/arm7tdmi/conditional-branch` | 输入 7 走 `bgt`，`r1 = 1` |
| ARM7 | `examples/arm7tdmi/array-addressing` | 缩放下标 3 读取 32 位值 40 |
| ARM7 | `examples/arm7tdmi/stack-subroutine` | full-descending 栈保存/恢复，`r0 = 42` |
| Cortex-M4 | `examples/cortex-m4/minimal-entry` | core 向量/启动 + Thumb 用户入口，读取系统状态 |
| STM32F4 | `examples/stm32f4-discovery/pd12-led` | 真板上配置 PD12；仿真不宣称可见 LED |

每个目录都有独立 `yagarto.json`、原创 `.s` 和短 README。完整静态验收：

```sh
swift build
scripts/test-examples.sh
```

脚本真实调用 `yagarto-mac build`，检查 ELF 为 ARM、入口、`.text`、DWARF、入口符号和 listing；算术示例还检查反汇编中的 `mov r0, #256` 与 `adds r0, r0, #67`。这能证明指令序列和数学结果，但只有在 simulator 中实际单步后才能声称“运行得到 r0=323”。

## 排障顺序

1. 运行 `yagarto-mac doctor --format text`，先区分构建工具缺失还是运行后端缺失。
2. 运行 `yagarto-mac build`。若失败，直接看 assembler/linker 原始诊断和 `.s` 行号。
3. 运行 `yagarto-mac disassemble`，确认 ELF 架构、ARM/Thumb 指令和入口。
4. 运行 `run/debug --dry-run --format json`，审阅 backend、GDB、warning 和 stdio pipe 参数。
5. 只有后端存在时才实际 `run`/`debug`；只有真板、USB 与目标确认无误时才 `flash --yes`。

当前仓库可以在没有 QEMU、没有 STM32F4-Discovery 真板的环境完成编译、ERT、shell 与 ELF 静态验证。QEMU 实际启动和硬件 LED/烧录仍必须在具备相应环境时单独验收，不能由静态测试代替。
