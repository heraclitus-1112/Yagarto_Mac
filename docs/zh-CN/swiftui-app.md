# YAGARTO Mac 原生应用

YAGARTO Mac App 是 macOS 15 及以上系统的非官方 YAGARTO 兼容实现，采用 SwiftUI 工作区与 AppKit `NSTextView` 源码编辑器。它直接复用 `YagartoCore` 的配置、工具探测、构建规划、构建执行、调试规划和 GDB/MI 控制器；应用层不会启动第二套 shell/MI 解析流程。

## 构建与启动

不修改源码的用户可直接从 [GitHub Releases](https://github.com/heraclitus-1112/Yagarto_Mac/releases) 下载 `YagartoMacApp-0.6.0-macOS-arm64.zip` 和 `SHA256SUMS.txt`。预构建 App 不包含 CLI、ARM 工具链或调试后端；首次启动的环境向导会显示每种 profile 的真实可用状态。

构建无 Developer ID 签名的本机应用：

```sh
scripts/build-app.sh Debug
scripts/build-app.sh Release
scripts/audit-release-no-fakes.sh dist/Release/YagartoMacApp.app
```

默认产物分别位于：

```text
dist/Debug/YagartoMacApp.app
dist/Release/YagartoMacApp.app
```

脚本优先使用 checked-in `YagartoMacApp.xcodeproj` 与共享 `YagartoMacApp` scheme。若 `xcodebuild` 在读取工程前因本机 Apple 开发工具插件损坏而不可用，脚本会明确打印环境警告，再用 SwiftPM 的同一应用 target 组装等价 `.app`；普通编译错误不会触发回退。

应用没有 Developer ID 分发签名、未公证，也没有 DMG、遥测或自动更新。Apple Silicon 链接器可能在 Mach-O 中生成本机 ad-hoc 签名；它不是开发者身份签名，也不能替代公证。首次从 Finder 打开时，macOS 可能要求用户在系统安全界面明确允许；不要用关闭 Gatekeeper 的方式绕过系统提示。

## 新建、导入、打开与保存

空白页和“文件”菜单提供“新建工程…”与“导入现有源码…”：

- 新建工程只需填写工程名、父目录和 profile。应用记住上次位置与目标，自动生成 `工程名/工程名.s` 和 `yagarto.json`，再打开源码；不会自动构建。
- 导入可选择多个 `.s/.S`，也可选择一个目录并只扫描当前层。所有输入统一选择一次 profile，每个源码成为一个独立工程，结束后只显示汇总，不切换当前文档。
- 导入不会就地改写原文件；UTF-8 之外的 GBK/GB18030、Windows-1252 或 ISO-8859-1 文本会在工程副本中无损转换为 UTF-8，并在汇总中明确提示。工程校验并发布成功后才删除原文件。读取使用不跟随链接的文件快照，删除前重新核对文件身份与字节；若文件变化或删除失败，会保留两份并明确警告，不会丢失源码。动态预处理、宏或条件汇编决定入口时会安全跳过，由用户通过兼容 `init` 流程显式配置。
- 同名工程不会被覆盖，而是自动使用 `-2`、`-3` 后缀。符号链接、硬链接、非普通文件、无法无损识别的文本、含二进制控制字符的文件、过大文件和已有工程内的源码会被拒绝。

快捷键 `Command-N` 打开新建向导，`Command-Shift-I` 打开批量导入。构建、调试或工程整理期间冲突操作均禁用；整理期间关闭窗口或退出应用会被明确拒绝。切换工程前若有未保存内容，会询问保存、不保存或取消。

“打开”支持两类目标：

- 包含 `yagarto.json` 的工程目录；侧栏按配置顺序显示全部 `sources`，初始打开第一项。
- 位于已配置工程中的 `.s` 或 `.S` 文件；profile、entry 与构建源码列表仍来自相邻 `yagarto.json`。

多源码工程按需读取文件内容。每个已打开源码保留独立的未保存文本、光标选择和断点；切换源码不会重建调试会话。`Command-S` 和构建前自动保存都会保存全部已修改源码，任一文件保存失败时不会启动构建，其余尚未写入的缓冲继续保持“已修改”。

左侧工程导航器在单文件和多文件工程中都会显示，并只列出 `yagarto.json` 的 `sources`。目录树由相对路径派生，不扫描或显示 `.yagarto` 构建目录。底部 `+` 菜单可以在工程内新建空白 `.s/.S`，或把一个或多个现有汇编文件复制进工程；复制不会移动原文件，同名项使用 `-2`、`-3` 后缀且不会覆盖。旧编码文本会在工程副本中转换为 UTF-8，并在完成提示中列出。右键源码可重命名、复制相对路径、在 Finder 中显示或移到废纸篓。重命名只改变当前目录中的文件名；首版不支持拖拽排序、新建文件夹或跨目录移动。

文件结构操作只在未运行调试器的空闲/就绪状态开放。移到废纸篓不能删除最后一个源码；脏文件会询问保存最新内容、放弃修改或取消。配置写入或文件操作失败时，应用会恢复原工程结构并显示具体错误。`Command-S` 与工具栏均显示“保存全部”。

空状态和“文件 → 打开最近工程”显示最近 10 个成功打开或创建的工程。列表只保存在本机，按规范化路径去重，不会启动时自动恢复；失效路径会被移除。

空状态的“打开多文件示例”来自应用内打包的原创 ARM7 数组寻址工程，入口代码与数组数据分别位于两个源码。首次点击会复制到 `~/Library/Application Support/YAGARTO Mac/Examples/ARM7 多文件数组寻址示例` 后再打开，因而可以正常编辑；后续点击复用该工作副本，绝不会覆盖旧的单文件示例或用户已保存的修改。

工程内部源码统一保存为 UTF-8，外部导入兼容 UTF-8、GBK/GB18030、Windows-1252 和 ISO-8859-1，默认上限为 4 MiB。中文与空格路径受支持。保存会在构建前自动执行；符号链接、链接数大于 1 的源码或配置文件会被拒绝，避免保存跟随到其他文件。编辑、profile 切换或源码行增删会令文档进入“已修改”状态；插入行会移动该行及后续断点，删除覆盖断点时会把它折叠到保留区起点并去重。

窗口或应用关闭时，未保存内容会出现“保存并退出 / 不保存 / 取消”确认。活动调试器会在退出前进行有界停止；应用不会无限等待 GDB、QEMU 或 OpenOCD。

停止操作超过界面等待时间时会保持“正在停止”，继续禁用构建和编辑；只有调试后端确认进程已清理后才恢复“就绪”。窗口关闭也不会在清理完成前放行。

## 工作区与快捷键

窗口上部依次为常驻工程导航器、源码与断点 gutter、寄存器；可拖动分隔线，工具栏按钮可折叠导航器。下部为控制台、栈、内存和反汇编标签页。构建诊断可以点击，并自动切换到对应源码的 1-based 行列。运行中禁止构建、profile 切换、源码编辑和切换文件；暂停后允许只读切换，但不允许改变工程结构。

首次启动会显示可跳过的环境检查。它直接复用 CLI 的 `doctor` 能力报告，但不会执行安装命令；ARM7 的精确 GDB simulator、ARM926/QEMU 兼容回退、Cortex-M4 QEMU 和 STM32F4 真板工具链分别显示，不会混写为同一种能力。可随时从“帮助 → 检查开发环境…”重新打开。

| 操作 | 快捷键 |
| --- | --- |
| 新建工程 | Command-N |
| 导入现有源码 | Command-Shift-I |
| 新建工程源码 | Command-Option-N |
| 添加现有源码到工程 | Command-Option-I |
| 打开 | Command-O |
| 保存全部 | Command-S |
| 构建 | Command-B |
| 运行 | Command-R |
| 启动调试 | Command-D |
| 暂停 | Command-Shift-P |
| 单步指令 | Command-I |
| 单步越过 | Command-Shift-N |
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

XCUITest 会向真实 `XCUIApplication` 同时传入 `--ui-testing` 参数与专用 `YAGARTO_UI_TEST_SESSION` 环境标记，使用仅在 Debug 编译中存在的本地确定性 fixture，不触碰硬件或网络。缺少任一门控都会使用生产服务；Release 构建完全排除 fake，即使传入同名参数也不会启用。正常生产启动不会启用测试后端。脚本只在能识别的 GUI/辅助权限环境限制下报告 `ENVIRONMENT SKIP`；若 Xcode 自身必需插件无法加载，会报告 `ENVIRONMENT BLOCKED`，不会把未运行的 UI 测试写成通过。CI 明确接受环境门控时可以使用：

```sh
scripts/test-app.sh --allow-environment-skip
```

该选项仍会运行严格 Swift 测试和本机 `.app` 打包，并在输出中保留 XCUITest 未运行的事实。

即使 Xcode 在加载插件阶段失败，脚本也会先用项目相同的 Swift 6、完整严格并发和 warnings-as-errors 参数独立编译 XCUITest 源码。UI 流程同时覆盖正常构建/调试，以及一次启动失败、一次调试器意外退出后再次构建、启动和停止的恢复路径。测试 fixture 使用带随机 ownership marker 的专属临时目录，并在应用正常退出和测试 teardown 时清理；不满足 marker 与直接父目录校验的路径绝不会删除。

## 关于与许可

“YagartoMacApp → 关于 YAGARTO Mac”明确显示“非官方 YAGARTO 兼容实现”和 `GNU GPL-3.0-or-later`。本项目不隶属于原 YAGARTO 项目、Arm、STMicroelectronics 或 GNU。
