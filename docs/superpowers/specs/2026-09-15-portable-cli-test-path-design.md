# CLI 集成测试工具路径可移植性设计

## 问题

`CLIIntegrationTests` 的父测试进程用真实环境确认 ARM 工具存在，但 CLI 子进程统一使用 `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`。工具链安装在其他目录时，预检查成功而子进程找不到同一工具，造成只在部分电脑出现的测试失败。

## 方案

默认 CLI 测试环境只保留 `/usr/bin:/bin`，不假定 Homebrew 前缀。使用假工具或验证缺工具行为的测试继续显式覆盖 `PATH`。

需要真实 ARM 构建工具的测试通过 `ToolResolver` 解析 assembler、linker、objcopy 和 objdump 的实际可执行路径，按首次出现顺序提取并去重父目录，再追加 `/usr/bin:/bin`，把结果显式传给 CLI 子进程。预检查与子进程由此使用同一组工具。

## 边界

- 不继承整个宿主 `PATH`，避免无关工具污染隔离测试。
- 不修改生产代码、App 工具发现或 CLI 行为。
- 缺少真实工具时仍使用 `XCTSkip`，不伪造通过。
- 路径包含空格时仍作为 `Process.environment` 的单个字符串值传递，不经过 shell 拼接。

## 验证

- 回归测试证明默认环境不包含固定 Homebrew 目录。
- 回归测试用非标准、含空格的工具目录证明动态 PATH 生成。
- 所有真实 ARM 构建 CLI 测试显式使用生成的环境。
- CLI 集成测试和完整 Swift 测试通过。
