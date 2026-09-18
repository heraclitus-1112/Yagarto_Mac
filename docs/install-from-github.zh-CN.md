# 从 GitHub 下载、安装并使用 YAGARTO Mac

本文面向一台尚未配置开发环境的 Apple Silicon Mac。普通用户可以直接下载预构建 App；需要 CLI、修改源码或构建精确 ARM7 GDB simulator 时，再使用后面的完整源码流程。

预构建版本不包含 CLI 或 ARM 工具链，也没有 DMG 和自动更新。App 可以先用于查看示例和编辑源码；构建、仿真与真板调试仍需安装对应 profile 的外部工具。

## 最快免费安装：下载预构建 App

打开 [GitHub Releases](https://github.com/heraclitus-1112/Yagarto_Mac/releases)，在 `v0.6.0` 中下载：

- `YagartoMacApp-0.6.0-macOS-arm64.zip`
- `SHA256SUMS.txt`

把两个文件放在同一目录，在“终端”进入该目录并核对下载内容：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

必须看到 ZIP 后面的 `OK`。随后解压并安装：

```sh
ditto -x -k YagartoMacApp-0.6.0-macOS-arm64.zip .
if [ -e /Applications/YagartoMacApp.app ]; then
  echo "请先退出旧版本，并在 Finder 中将它移到废纸篓。"
else
  ditto YagartoMacApp.app /Applications/YagartoMacApp.app
fi
open /Applications/YagartoMacApp.app
```

Release App 未签名、未公证。若 macOS 阻止首次打开，请在 Finder 中按住 Control 点击 App 并选择“打开”；仍被阻止时，到“系统设置 → 隐私与安全性”选择“仍要打开”。不要全局关闭 Gatekeeper。

首次启动的环境向导只检查本机、复制安装命令和打开本文，不会自行运行 Homebrew 或网络脚本。环境未完整时可以跳过，继续编辑源码；不可用的构建或调试能力会保持明确标记。

若只需要最快的 ARM7 兼容运行路径，安装普通 ARM GNU 工具和 QEMU 后，App 可以明确使用 ARM926 兼容回退；它不是精确 ARM7TDMI。课程要求精确 ARM7 指令级行为时，继续完成第 4、5、7、8 节。

## 1. 确认电脑符合要求

打开“终端”，执行：

```sh
uname -m
sw_vers -productVersion
```

App 运行要求和从源码构建要求不同：

- 预构建 App：`uname -m` 输出 `arm64`，macOS 不低于 15；
- 从源码构建：`uname -m` 输出 `arm64`，macOS 不低于 26.2。

App 包本身的部署目标是 macOS 15，但仓库使用 Swift 6.3。根据 [Apple 当前 Xcode 系统要求](https://developer.apple.com/support/xcode/)，包含 Swift 6.3 的 Xcode 26.5/26.6 需要 macOS 26.2 或更高版本。因此，“预构建 App 能在 macOS 15 运行”不等于“macOS 15 能从源码构建 App”。本指南不承诺 Intel Mac 能够构建或运行。

## 2. 安装 Xcode 和 Swift 6.3（仅源码构建）

从 Mac App Store 安装当前完整版本的 Xcode。首次安装后执行：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcode-select -p
swift --version
xcodebuild -version
```

关键检查：

- `xcode-select -p` 应输出 `/Applications/Xcode.app/Contents/Developer`；
- `swift --version` 必须显示 Swift 6.3；
- `xcodebuild -version` 应正常显示 Xcode 版本，不能报“需要完整 Xcode”。

如果终端提示尚未接受许可，打开一次 Xcode 并按界面完成许可和组件安装，再重新运行上述命令。

如果 Mac App Store 提示当前系统不能安装包含 Swift 6.3 的 Xcode，请先把 macOS 更新到 26.2 或更高版本。App 的最低运行版本与“从源码构建所需的 Xcode 主机版本”是两个不同条件。

## 3. 安装 Homebrew

使用 [Homebrew 官方安装命令](https://brew.sh/zh-cn/)：

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Apple Silicon Mac 安装完成后，把 Homebrew 加入 zsh 环境并立即生效：

```sh
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew --version
brew doctor
```

`brew doctor` 可能提示与本项目无关的本机配置建议；只要 `brew --version` 能正常输出，即可继续安装依赖。

## 4. 一次安装全部软件依赖

执行：

```sh
brew update
brew install git arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd \
  make gcc@15 gmp mpfr readline texinfo gnu-sed
```

这些软件分别用于：

| 软件 | 用途 |
| --- | --- |
| Git | 下载和更新仓库 |
| `arm-none-eabi-gcc` | ARM 汇编、预处理、链接及二进制工具 |
| `arm-none-eabi-gdb` | 连接 QEMU 或 OpenOCD 的普通 GDB |
| QEMU | ARM926 兼容模式和 Cortex-M4 MPS2 仿真 |
| OpenOCD | 连接 STM32F4-Discovery 实体开发板 |
| GNU Make、GCC 15、GMP、MPFR、Readline、Texinfo、GNU sed | 从源码构建带 ARM simulator 的 GDB 15.2 |

逐项验证：

```sh
git --version
arm-none-eabi-gcc --version
arm-none-eabi-as --version
arm-none-eabi-gdb --version
qemu-system-arm --version
openocd --version
gmake --version
makeinfo --version
gsed --version
"$(brew --prefix gcc@15)/bin/gcc-15" --version
```

再确认 QEMU 和 OpenOCD 包含本项目需要的目标：

```sh
qemu-system-arm -machine help | grep -E 'integratorcp|mps2-an386'
test -f "$(brew --prefix open-ocd)/share/openocd/scripts/board/stm32f4discovery.cfg"
```

第一条应同时找到 `integratorcp` 和 `mps2-an386`；第二条无输出且退出状态为 0 表示板卡配置存在。可以紧接着执行 `echo $?` 查看退出状态。

## 5. 从 GitHub 下载源码

统一把仓库放在 `~/Developer/Yagarto_Mac`：

```sh
mkdir -p "$HOME/Developer"
git clone https://github.com/heraclitus-1112/Yagarto_Mac.git \
  "$HOME/Developer/Yagarto_Mac"
cd "$HOME/Developer/Yagarto_Mac"
git status --short
```

首次克隆后，`git status --short` 应没有输出。

如果该目录已经存在，不要重复执行 `git clone`，请使用本文后面的“更新版本”流程。

## 6. 构建 CLI 和 Release App

仍在仓库根目录执行：

```sh
swift build -c release --product yagarto-mac
scripts/build-app.sh Release
scripts/audit-release-no-fakes.sh dist/Release/YagartoMacApp.app
```

成功后：

- CLI 位于 `.build/release/yagarto-mac`；
- App 位于 `dist/Release/YagartoMacApp.app`；
- 最后一条审计命令应输出 `Release UI fake exclusion: PASS`。

不要只把 `.build/release/yagarto-mac` 这个裸文件复制到其他目录，因为 CLI 需要旁边的 SwiftPM resource bundle。

把完整构建目录加入当前用户的 PATH：

```sh
echo 'export PATH="$HOME/Developer/Yagarto_Mac/.build/release:$PATH"' >> "$HOME/.zprofile"
export PATH="$HOME/Developer/Yagarto_Mac/.build/release:$PATH"
yagarto-mac --version
```

## 7. 构建 ARM7 指令级 GDB simulator（必做）

Homebrew 的普通 `arm-none-eabi-gdb` 用于 QEMU 和 OpenOCD，但现代 GDB 已经移除了 ARM simulator。项目固定从 GNU 官方地址下载 GDB 15.2，并在编译前核对归档 SHA-256。

在仓库根目录执行：

```sh
cd "$HOME/Developer/Yagarto_Mac"
scripts/bootstrap-gdb-sim.sh \
  --prefix "$HOME/.local/share/yagarto-mac/toolchains/gdb-15.2-sim" \
  --sha256 '83350ccd35b5b5a0cba6b334c41294ea968158c573940904f00b92f76345314d'
```

这个步骤会下载约 24 MiB 的源码并进行较长时间的本地编译。脚本会自动使用刚才安装的 GNU GCC 15、GNU Make、GMP、MPFR、Readline、Texinfo 和 GNU sed，随后实际验证 `target sim`、加载、断点、单步、`r0`–`r12`、`sp`、`lr`、`pc` 和 `cpsr`。只有全部通过才会生成：

```text
~/.local/share/yagarto-mac/toolchains/gdb-15.2-sim/bin/arm-none-eabi-gdb-sim
```

再次验证已有安装：

```sh
scripts/bootstrap-gdb-sim.sh --verify-gdb \
  "$HOME/.local/share/yagarto-mac/toolchains/gdb-15.2-sim/bin/arm-none-eabi-gdb-sim"
```

App 和 CLI 会自动查找这个默认路径，不需要修改系统 GDB，也不需要手工设置环境变量。

如果构建、自测或别名生成任一步失败，请停在这里排障；不要打开 App 进行 ARM7 调试，也不要把普通 `arm-none-eabi-gdb` 当作 simulator。

## 8. 用 doctor 做安装门槛验收（必做）

执行：

```sh
cd "$HOME/Developer/Yagarto_Mac"
yagarto-mac doctor
```

应确认：

- assembler、compiler、linker、objcopy、objdump 全部“已找到”；
- Simulator GDB 已找到，且 `target sim` 显示“支持”；
- QEMU 与 OpenOCD 已找到；
- STM32F4 Discovery board config 已找到；
- `arm7tdmi` 选择 `gdb-simulator`；
- `cortex-m4` 选择 `qemu-mps2-an386`；
- `stm32f4-discovery` 选择 `openocd-stm32f4-discovery`。

也可以保存机器可读报告：

```sh
yagarto-mac doctor --format json > "$HOME/Desktop/yagarto-doctor.json"
```

“工具已找到”只证明安装和能力探测通过，不代表真实 STM32 开发板已经连接或运行。

上述任一项失败时停止安装流程并先完成排障。特别是 `Simulator GDB target sim` 不支持，或 `arm7tdmi` 没有选择 `gdb-simulator` 时，不要继续首次 ARM7 调试；否则 App 会进入 ARM926/QEMU 兼容回退模式。

## 9. 安装源码构建的 App

首次安装前确认目标位置还没有同名 App：

```sh
if [ -e /Applications/YagartoMacApp.app ]; then
  echo "已存在旧版本，请先退出 App 并将旧版本移到废纸篓。"
else
  echo "目标位置可用，可以安装。"
fi
```

从源码构建 App 的用户可以复制本地产物；若已经使用顶部的预构建 ZIP 安装，则跳过本节：

```sh
sudo ditto "$HOME/Developer/Yagarto_Mac/dist/Release/YagartoMacApp.app" \
  /Applications/YagartoMacApp.app
open /Applications/YagartoMacApp.app
```

如果第一条检查发现已经存在旧版本，请先退出 YAGARTO Mac，在 Finder 的“应用程序”中把旧版本移到废纸篓，再执行复制命令。

当前 App 没有 Developer ID 分发签名，也没有经过 Apple 公证。若 macOS 阻止首次打开：

1. 在 Finder 中打开“应用程序”；
2. 按住 Control 点击 `YagartoMacApp`，选择“打开”；
3. 再次确认“打开”；
4. 如果仍被阻止，进入“系统设置 → 隐私与安全性”，在对应提示旁选择“仍要打开”。

不要全局关闭 Gatekeeper。

## 10. 在 App 中完成第一个精确 ARM7 工程

开始本节前必须完成第 7 节 simulator 自测和第 8 节 `doctor` 验收；失败时停止，不要把 ARM926/QEMU 兼容回退写成精确 ARM7TDMI。

1. 打开 `/Applications/YagartoMacApp.app`。
2. 点击“新建工程…”，工程名填写 `arm7-first`。
3. 父目录选择“文稿”，profile 选择 `ARM7TDMI`。
4. 点击“创建工程”。App 会自动生成源码和 `yagarto.json`，不需要手写配置。
5. 点击工具栏的锤子“构建”。
6. 点击瓢虫“启动调试”，程序会停在 `start`。
7. 使用“单步指令”观察 `r0`–`r15` 和 `CPSR`。
8. 点击“继续”后，默认模板会进入停止循环；需要结束时点击“暂停”，再点击“停止”。

也可以使用 CLI 完成同一流程：

```sh
mkdir -p "$HOME/Documents/YAGARTO"
cd "$HOME/Documents/YAGARTO"
yagarto-mac new arm7-first --profile arm7tdmi --parent "$PWD"
cd arm7-first
yagarto-mac build
yagarto-mac debug
```

进入 GDB 后可以输入 `stepi`、`info registers` 和 `quit`。

## 11. 验证 Cortex-M4 仿真

在 App 中新建工程时选择 `Cortex-M4`，构建后点击“启动调试”。后端应为 QEMU `mps2-an386`，程序从向量表进入 `Reset_Handler`，再进入 `main`。

对应 CLI 流程：

```sh
cd "$HOME/Documents/YAGARTO"
yagarto-mac new cortex-first --profile cortex-m4 --parent "$PWD"
cd cortex-first
yagarto-mac build
yagarto-mac debug
```

Cortex-M4 显示的是 `xPSR`、MSP、PSP、CONTROL 和 PRIMASK，不应把它们称为 ARM7 的 CPSR。MPS2 是通用 Cortex-M4 仿真环境，不模拟 STM32F407 的全部外设。

## 12. 验证 STM32F4-Discovery 工具链

先创建并构建工程：

```sh
cd "$HOME/Documents/YAGARTO"
yagarto-mac new stm32-first --profile stm32f4-discovery --parent "$PWD"
cd stm32-first
yagarto-mac build
yagarto-mac flash --dry-run --format json
```

到这里可以在没有开发板时验证构建和烧录计划，但不能声称程序已经在实体芯片运行。

需要真实烧录时，将 STM32F4-Discovery 通过数据线连接到 Mac，然后执行：

```sh
system_profiler SPUSBDataType | grep -A 12 -i 'ST-Link'
yagarto-mac flash --yes
yagarto-mac debug
```

`flash --yes` 会真实改写开发板 Flash；项目故意要求显式确认。`debug` 只连接、复位和调试，不会代替烧录。

## 13. 更新到 GitHub 最新版本

普通用户优先从 Releases 下载新 ZIP，核对新的 `SHA256SUMS.txt`，退出旧 App 并将旧包移到废纸篓后再完整复制。以下命令面向保留源码仓库的开发者。

先退出 App，并确认仓库没有自己尚未提交的修改：

```sh
cd "$HOME/Developer/Yagarto_Mac"
git status --short
```

必须确认没有输出，再执行：

```sh
git pull --ff-only
brew update
brew upgrade git arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd \
  make gcc@15 gmp mpfr readline texinfo gnu-sed
swift build -c release --product yagarto-mac
scripts/build-app.sh Release
scripts/audit-release-no-fakes.sh dist/Release/YagartoMacApp.app
```

构建成功后，在 Finder 中退出 YAGARTO Mac，并把 `/Applications/YagartoMacApp.app` 旧版本移到废纸篓。确认“应用程序”中已不存在同名 App，再执行完整复制：

```sh
sudo ditto "$HOME/Developer/Yagarto_Mac/dist/Release/YagartoMacApp.app" \
  /Applications/YagartoMacApp.app
open /Applications/YagartoMacApp.app
```

先移走旧包再复制，避免 `ditto` 合并目录时残留旧版本独有资源。如果更新说明要求重新构建 GDB simulator，再重复第 7 节的构建命令；一般的 App 源码更新不需要重复编译 GDB。

## 14. 卸载边界

优先使用 Finder 将 `/Applications/YagartoMacApp.app` 移到废纸篓。源码位于 `~/Developer/Yagarto_Mac`，GDB simulator 位于 `~/.local/share/yagarto-mac/toolchains/gdb-15.2-sim`；它们是互相独立的目录，不会因为删除 App 自动消失。

如果确定这些工具不再被其他项目使用，可以让 Homebrew卸载本指南安装的软件：

```sh
brew uninstall arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd \
  make gcc@15 gmp mpfr readline texinfo gnu-sed
```

Git 和 Xcode 常被其他开发工作使用，本指南不建议仅为卸载 YAGARTO Mac 而删除它们。源码和用户 GDB 目录也建议通过 Finder 移到废纸篓，避免在终端对用户目录执行宽泛的递归删除命令。

## 15. 常见问题

### `brew: command not found`

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
```

然后检查 `~/.zprofile` 中是否已经包含相同的 `brew shellenv` 行。

### Swift 版本低于 6.3

更新完整 Xcode，再执行：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
swift --version
```

### `doctor` 找不到工具

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
brew list --versions arm-none-eabi-gcc arm-none-eabi-gdb qemu open-ocd
yagarto-mac doctor
```

### ARM7 没有选择 `gdb-simulator`

```sh
cd "$HOME/Developer/Yagarto_Mac"
scripts/bootstrap-gdb-sim.sh --verify-gdb \
  "$HOME/.local/share/yagarto-mac/toolchains/gdb-15.2-sim/bin/arm-none-eabi-gdb-sim"
yagarto-mac doctor
```

### QEMU 后端不可用

```sh
qemu-system-arm -machine help | grep -E 'integratorcp|mps2-an386'
brew reinstall qemu
```

### App 被 macOS 阻止

使用第 9 节的“Control 点击 → 打开”或“系统设置 → 隐私与安全性 → 仍要打开”。不要关闭整个系统的 Gatekeeper。

### STM32F4 无法连接

先确认使用支持数据传输的 USB 线，并检查：

```sh
system_profiler SPUSBDataType | grep -A 12 -i 'ST-Link'
openocd -f board/stm32f4discovery.cfg -c 'init; shutdown'
```

没有实体板卡时，`flash` 返回“未检测到开发板”是正确行为，不是编译器故障。

更多说明见[中文快速入门](quick-start.zh-CN.md)、[原生 SwiftUI 应用](zh-CN/swiftui-app.md)和[目标差异与排障](targets-and-troubleshooting.zh-CN.md)。
