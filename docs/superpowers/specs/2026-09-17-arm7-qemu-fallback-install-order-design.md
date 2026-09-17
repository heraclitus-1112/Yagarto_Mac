# ARM7 QEMU 回退与完整安装顺序修复设计

## 目标

修复两项会让新电脑无法可靠单步 ARM7 程序的问题：

1. ARM7 没有可用 GDB simulator 时，QEMU `integratorcp`/ARM926 调试路径会在已经停于 ELF 入口的情况下再次设置临时断点并继续，从而越过入口并可能跑入末尾死循环。
2. GitHub 安装文档在构建 GDB simulator 和运行 `doctor` 之前就要求打开 App，导致严格照流程操作的用户过早进入 QEMU 回退路径。

## 调试后端行为

ARM7 QEMU 仍使用 `-S -gdb stdio` 启动，并通过 GDB 管道管理生命周期。QEMU 使用 ELF `-kernel` 加载时，`-S` 会让 CPU 保持暂停，程序计数器位于 ELF 入口。因此：

- `debug` 模式连接后不再发送 `tbreak <entry>` 或 `continue`，直接保留停止状态；App 随后同步用户断点并允许单步。
- `run` 模式连接后仍发送 `continue`，保持一键运行语义。
- GDB simulator 模式继续使用 `target sim`、`load`、`tbreak <entry>`、`run`，因为 simulator 的启动协议不同。
- Cortex-M4 与 STM32F4-Discovery 的既有启动序列不在本次修改范围内。

不主动写 `$pc`。若 ELF 入口错误，应由构建、链接和入口校验暴露，不能由调试器静默掩盖。

## 进程生命周期

增加真实 QEMU 回归覆盖：使用临时 ARM7 ELF 和普通 `arm-none-eabi-gdb` 启动回退后端，确认初始 PC 位于入口、一次 `stepi` 前进到下一条指令，并通过现有有界停止路径退出。测试记录专属 QEMU 包装进程的 PID，停止完成后确认该进程已经消失，防止失败重试留下后台 QEMU。

若本机缺少普通 ARM GDB、QEMU 或 ARM 汇编工具，该项系统集成测试明确跳过；规划层和生命周期单元测试仍必须执行。

## 安装文档

完整安装顺序调整为：

1. 安装 Xcode、Homebrew 与全部依赖。
2. 克隆仓库并构建 CLI/Release App。
3. 构建并完整自测 GDB 15.2 ARM simulator。
4. 运行 `yagarto-mac doctor`，确认 Simulator GDB 支持 `target sim`，且 `arm7tdmi` 选择 `gdb-simulator`。
5. 只有验收通过后，才把 App 复制到 `/Applications` 并首次打开。
6. 进行 ARM7、Cortex-M4 和 STM32F4 工具验证。

文档明确 simulator 与 `doctor` 是“完整 ARM7 安装”的必做门槛。若 simulator 构建、自测或 `doctor` 验收失败，用户应停在当前步骤排障，不能继续首次 ARM7 调试。删除重复的 PATH 配置段，并更新交叉引用和常见问题编号。

## 测试与验收

- 规划测试先失败，证明旧计划仍包含 `tbreak start` 与 `continue`；修复后断言 ARM7 QEMU `debug` 计划只负责加载 ELF 和连接 QEMU，而 `run` 计划仍包含 `continue`。
- CLI dry-run 测试同时锁定 text/JSON 输出，防止以后重新引入入口续跑。
- 文档契约测试确认 simulator 和 `doctor` 章节位于安装/打开 App 之前，且不存在重复 PATH 配置块。
- 真实 QEMU 测试确认入口停止、单步成功、停止后无专属 GDB/QEMU 残留。
- 最终运行 warnings-as-errors 全量测试、Release 构建、ARM7 QEMU App 手工验收和进程残留检查。

## 非目标

- QEMU ARM926 仍是 ARM7TDMI 兼容超集，不声称为精确 ARM7TDMI 模型。
- 不把 GDB simulator 打包进 App，也不修改其 GPL 分发边界。
- 不改变真实 STM32 外设仿真能力或 OpenOCD 板卡流程。
