# YAGARTO Mac

YAGARTO Mac 是一个面向 macOS 的非官方 YAGARTO 兼容层，不隶属于原 YAGARTO 项目或 Arm。

当前 Task 1 提供 Swift 核心库与命令行基础：`yagarto.json` 项目配置、工具链检查、`arm7tdmi`、`cortex-m4`、`stm32f4-discovery` 构建规划、汇编/链接/产物生成，以及 ELF 反汇编。当前版本不包含运行、调试或烧录后端。

本地使用：

```sh
swift run yagarto-mac doctor
swift run yagarto-mac init --profile arm7tdmi
swift run yagarto-mac profile set cortex-m4
swift run yagarto-mac build
swift run yagarto-mac build path/to/demo.s --format json
swift run yagarto-mac disassemble
swift run yagarto-mac disassemble path/to/demo.elf --format json
```

所有非交互子命令均支持 `--format text`（默认）或 `--format json`。

内置链接脚本通过 SwiftPM 的 `Bundle.module` 资源包加载。请通过 `swift run` 或 SwiftPM 构建产物运行；单独复制可执行文件而不携带其资源包不属于当前 Task 1 的支持方式，资源打包发布验证将在后续发布任务完成。

本项目采用 GNU General Public License v3.0 or later，详见 `LICENSE`。
