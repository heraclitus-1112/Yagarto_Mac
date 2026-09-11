# YAGARTO Mac 原生应用

YAGARTO Mac App 是 macOS 15 及以上系统的非官方 YAGARTO 兼容实现，采用 SwiftUI 工作区与 AppKit `NSTextView` 源码编辑器。它直接复用 `YagartoCore` 的配置、工具探测、构建规划、构建执行、调试规划和 GDB/MI 控制器；应用层不会启动第二套 shell/MI 解析流程。

## 构建与启动

构建无 Developer ID 签名的本机应用：

```sh
scripts/build-app.sh Debug
scripts/build-app.sh Release
```

默认产物分别位于：

```text
dist/Debug/YagartoMacApp.app
dist/Release/YagartoMacApp.app
```

脚本优先使用 checked-in `YagartoMacApp.xcodeproj` 与共享 `YagartoMacApp` scheme。若 `xcodebuild` 在读取工程前因本机 Apple 开发工具插件损坏而不可用，脚本会明确打印环境警告，再用 SwiftPM 的同一应用 target 组装等价 `.app`；普通编译错误不会触发回退。

应用没有 Developer ID 分发签名、未公证，也没有 DMG、遥测或自动更新。Apple Silicon 链接器可能在 Mach-O 中生成本机 ad-hoc 签名；它不是开发者身份签名，也不能替代公证。首次从 Finder 打开时，macOS 可能要求用户在系统安全界面明确允许；不要用关闭 Gatekeeper 的方式绕过系统提示。

## 打开与保存

“打开”支持两类目标：

- 包含 `yagarto.json` 的工程目录；编辑器打开配置中的第一项 `sources`。
- 位于已配置工程中的 `.s` 或 `.S` 文件；profile、entry 与构建源码列表仍来自相邻 `yagarto.json`。

源码必须是 UTF-8，默认上限为 4 MiB。中文与空格路径受支持。保存会在构建前自动执行；符号链接、链接数大于 1 的源码或配置文件会被拒绝，避免保存跟随到其他文件。编辑、profile 切换或源码行增删会令文档进入“已修改”状态；插入行会移动该行及后续断点，删除覆盖断点时会把它折叠到保留区起点并去重。

窗口或应用关闭时，未保存内容会出现“保存并退出 / 不保存 / 取消”确认。活动调试器会在退出前进行有界停止；应用不会无限等待 GDB、QEMU 或 OpenOCD。

## 工作区与快捷键

窗口上部左侧是源码与断点 gutter，右侧是寄存器；可拖动分隔线。下部为控制台、栈、内存和反汇编标签页。构建诊断可以点击，若文件与当前源码的 canonical 路径相同，会跳到对应的 1-based 行列。运行中禁止构建、profile 切换和源码编辑；停止后重新允许。

| 操作 | 快捷键 |
| --- | --- |
| 打开 | Command-O |
| 保存 | Command-S |
| 构建 | Command-B |
| 运行 | Command-R |
| 启动调试 | Command-D |
| 暂停 | Command-Shift-P |
| 单步指令 | Command-I |
| 单步越过 | Command-N |
| 继续 | Command-G |
| 停止 | Command-Shift-. |
| 当前行断点 | Command-\ |

toolbar 图标有至少 44 × 44 pt 点击区域、可读 label 和 hint。断点以菱形、当前执行行以三角形表示；寄存器变化同时显示箭头与“已变化”，不会只靠颜色传达状态。编辑器、gutter、当前行、寄存器与关键按钮都提供 VoiceOver 信息。

## 调试后端限制

应用不会自动安装工具，也不会在缺少后端时伪装成功：

- `arm7tdmi` 优先使用经过完整能力探测、支持 `target sim` 的 GDB；回退 QEMU 时是 ARM926 兼容超集，不是精确 ARM7TDMI。
- `cortex-m4` 使用 QEMU `mps2-an386`，不是 STM32F407 外设模型。
- `stm32f4-discovery` 使用 OpenOCD 连接真实开发板；应用调试只 attach/reset，不执行烧录。

工具缺失、没有 QEMU、没有板卡或 OpenOCD 失败都会显示中文可操作错误。内存地址只接受 `$sp` 或 `0x` 开头的十六进制值，长度限制为 1 到 4096 字节。

## 测试

AppSupport 与 AppKit 逻辑通过 SwiftPM 测试：

```sh
swift test -c debug \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

swift test -c release \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

应用与真实 XCUITest host 位于 checked-in Xcode project：

```sh
xcodebuild \
  -project YagartoMacApp.xcodeproj \
  -scheme YagartoMacApp \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

也可运行统一脚本：

```sh
scripts/test-app.sh
```

XCUITest 会向真实 `XCUIApplication` 传入精确参数 `--ui-testing`，使用本地确定性 fixture，不触碰硬件或网络。正常生产启动不会启用测试后端。脚本只在能识别的 GUI/辅助权限环境限制下报告 `ENVIRONMENT SKIP`；若 Xcode 自身必需插件无法加载，会报告 `ENVIRONMENT BLOCKED`，不会把未运行的 UI 测试写成通过。CI 明确接受环境门控时可以使用：

```sh
scripts/test-app.sh --allow-environment-skip
```

该选项仍会运行严格 Swift 测试和本机 `.app` 打包，并在输出中保留 XCUITest 未运行的事实。

## 关于与许可

“YagartoMacApp → 关于 YAGARTO Mac”明确显示“非官方 YAGARTO 兼容实现”和 `GNU GPL-3.0-or-later`。本项目不隶属于原 YAGARTO 项目、Arm、STMicroelectronics 或 GNU。
