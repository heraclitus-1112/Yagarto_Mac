# GitHub 下载与全量安装指南设计

## 目标与读者

为第一次接触本项目的用户提供一条可以逐项复制执行的完整流程，从一台干净的 Apple Silicon Mac 开始，最终能够打开 YAGARTO Mac、新建工程、编译并使用 ARM7TDMI 与 Cortex-M4 仿真后端；连接 STM32F4-Discovery 后还能够使用 OpenOCD。

默认环境固定为 Apple Silicon、macOS 15 或更高版本。Intel Mac 和旧版 macOS 不在本指南的承诺范围内。

## 文档结构

新增 `docs/install-from-github.zh-CN.md`，并从 README 与中文快速入门链接到该文档。安装流程按严格顺序编排：

1. 检查 Mac 架构与系统版本。
2. 安装 Xcode Command Line Tools，并验证 Swift。
3. 安装 Homebrew。
4. 通过 Homebrew 一次安装 Git、Arm GNU Toolchain、普通 ARM GDB、QEMU、OpenOCD，以及构建 GDB 15.2 simulator 所需的 GNU Make、GCC 15、GMP、MPFR、Readline、Texinfo 和 GNU sed。
5. 从 GitHub 克隆仓库。
6. 构建 Release App，运行仓库提供的发布审计，将 App 复制到 `/Applications`。
7. 说明未签名、未公证版本的首次打开方式，不推荐关闭系统级 Gatekeeper。
8. 下载并校验 GNU GDB 15.2 源码，使用仓库脚本构建带 `target sim` 的 ARM GDB。
9. 使用 `yagarto-mac doctor` 验证 Arm 工具、GDB simulator、QEMU、OpenOCD 和板卡配置。
10. 在 App 中新建 ARM7TDMI 工程并完成构建、调试和单步；再给出 Cortex-M4 与 STM32F4-Discovery 的切换步骤。
11. 给出更新、卸载和常见故障处理方式。

## 安装策略

所有软件依赖均进入主流程，不使用“可选安装”措辞。真实 STM32F4-Discovery 板卡本身不可能通过软件安装，因此只把“连接板卡并烧录”标记为需要实体硬件；OpenOCD 仍然默认安装并由 `doctor` 验证。

普通 `arm-none-eabi-gdb` 与带 simulator 的 `arm-none-eabi-gdb-sim` 同时保留：前者服务 QEMU/OpenOCD，后者服务精确 ARM7 指令级模拟。文档明确两者职责，避免用户用 GDB 17.x 的普通版本执行 `target sim`。

安装命令优先使用可审计的官方工具与 Homebrew formula。GDB 源码必须来自 GNU 官方发布源，并在构建前进行 SHA-256 校验；不使用未经校验的第三方二进制。

## 安全与错误处理

- 不提供 `sudo spctl --master-disable` 或全局关闭 Gatekeeper 的命令。
- 复制 App 使用明确的源路径和 `/Applications/YagartoMacApp.app` 目标路径。
- 不把“工具已安装”写成“仿真或硬件已经成功运行”；每个阶段都给出验证命令和预期关键输出。
- `doctor` 的缺失项必须对应到具体重装或路径排查命令。
- STM32 烧录保留 `flash --yes` 的显式确认要求。
- 更新流程在执行 `git pull` 前要求工作区干净；卸载流程分别说明 App、源码和用户工具链目录的边界，不给出宽泛递归删除命令。

## 验证标准

- 所有 shell 代码块使用一致的 `zsh`/POSIX 兼容语法，并通过静态语法检查。
- 仓库内路径、脚本名、CLI 命令和 profile 名与当前实现逐项核对。
- Homebrew formula 名称通过当前 Homebrew 元数据核实。
- Release 构建与安全审计命令在当前仓库实际执行成功。
- 文档链接检查通过，README 能在两次点击以内到达完整安装流程。
- 文档明确当前 GitHub 尚无预构建 Release，用户执行的是“下载源码后本机构建”。
