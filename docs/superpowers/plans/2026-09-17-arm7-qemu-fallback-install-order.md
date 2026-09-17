# ARM7 QEMU Fallback and Install Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ARM7 QEMU 回退调试稳定停在 ELF 入口并可立即单步，同时保证完整安装流程在首次打开 App 前安装并验收 GDB simulator。

**Architecture:** `DebugPlanner` 根据 ARM7 后端和模式分别生成启动命令：GDB simulator 保留 `tbreak/run`，QEMU `debug` 只连接已由 `-S` 暂停的目标，QEMU `run` 才继续。真实 E2E 通过 `GDBMISession` 驱动普通 ARM GDB 与带 PID 标记的 QEMU wrapper，验证入口、单步和进程回收；文档契约测试锁定安装顺序。

**Tech Stack:** Swift 6.3、XCTest、GDB/MI、QEMU `integratorcp`/ARM926、Markdown、zsh。

---

## 文件结构

- `Sources/YagartoCore/DebugPlanner.swift`：生成区分 simulator/QEMU 与 debug/run 的 ARM7 启动命令。
- `Tests/YagartoCoreTests/DebugPlannerTests.swift`：锁定四种启动语义，不允许 QEMU debug 重新续跑。
- `Tests/YagartoCoreTests/CLIIntegrationTests.swift`：锁定 CLI dry-run 对 QEMU debug/run 的实际计划输出。
- `Tests/YagartoCoreTests/ARM7QEMUFallbackE2ETests.swift`：真实构建 ARM7 ELF，验证 QEMU 入口停止、单步和进程清理。
- `Tests/YagartoCoreTests/InstallGuideContractTests.swift`：验证 simulator、doctor、安装/打开 App 的顺序与 PATH 段唯一性。
- `docs/install-from-github.zh-CN.md`：完整安装顺序、失败门槛、排障和交叉引用。

### Task 1: 修正 ARM7 QEMU 启动计划

**Files:**
- Modify: `Tests/YagartoCoreTests/DebugPlannerTests.swift`
- Modify: `Tests/YagartoCoreTests/CLIIntegrationTests.swift`
- Modify: `Sources/YagartoCore/DebugPlanner.swift`

- [ ] **Step 1: 写规划层失败测试**

把 `testARM7FallsBackToExplicitARM926CompatibleQEMUPipe` 的 debug 期望改成只包含 `file` 和 `target remote | exec ... -S ...`，并明确断言：

```swift
XCTAssertEqual(plan.initCommands.count, 2)
XCTAssertFalse(plan.initCommands.contains(where: { $0.hasPrefix("tbreak ") }))
XCTAssertFalse(plan.initCommands.contains("continue"))
```

新增 run 计划测试：

```swift
let plan = try planner(qemu: "/tools/qemu-system-arm").plan(
    mode: .run,
    configuration: .default,
    elf: elf,
    projectDirectory: project
)
XCTAssertEqual(plan.initCommands.last, "continue")
```

- [ ] **Step 2: 运行 RED**

Run:

```bash
swift test --filter DebugPlannerTests
```

Expected: debug 计划仍包含 `tbreak start` 和 `continue`，新断言失败。

- [ ] **Step 3: 写 CLI dry-run 失败测试**

在隔离 PATH 中提供普通 GDB 和 QEMU、让 `target sim` 探测失败，分别调用：

```swift
["debug", "firmware.elf", "--profile", "arm7tdmi", "--dry-run", "--format", "json"]
["run", "firmware.elf", "--profile", "arm7tdmi", "--dry-run", "--format", "json"]
```

断言 debug JSON 的 `initCommands` 不含 `tbreak`/`continue`，run JSON 末项为 `continue`。

- [ ] **Step 4: 运行 CLI RED**

Run:

```bash
swift test --filter CLIIntegrationTests.testARM926Fallback
```

Expected: debug JSON 仍暴露 `tbreak start`/`continue`，测试失败。

- [ ] **Step 5: 最小实现**

在 ARM7 QEMU 分支中只给 run 模式追加 `continue`：

```swift
var commands = [fileCommand, "target remote | exec \(pipe)"]
if mode == .run {
    commands.append("continue")
}
```

不要改 simulator、Cortex-M4 或 STM32 分支。

- [ ] **Step 6: 运行 GREEN 并提交**

Run:

```bash
swift test --filter DebugPlannerTests
swift test --filter CLIIntegrationTests.testARM926Fallback
git diff --check
```

Expected: 全部通过。

Commit:

```bash
git add Sources/YagartoCore/DebugPlanner.swift Tests/YagartoCoreTests/DebugPlannerTests.swift Tests/YagartoCoreTests/CLIIntegrationTests.swift
git commit -m "fix: keep ARM7 QEMU debug stopped at entry"
```

### Task 2: 真实 QEMU 入口、单步与回收测试

**Files:**
- Create: `Tests/YagartoCoreTests/ARM7QEMUFallbackE2ETests.swift`

- [ ] **Step 1: 写可跳过的真实工具测试**

使用 `ToolResolver` 解析 `.assembler/.linker/.objdump/.gdb/.qemuSystemARM`；任何工具缺失时 `XCTSkip`。在临时目录写入：

```asm
.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
start:
    mov r0, #1
    add r0, r0, #1
.Lhalt:
    b .Lhalt
```

用 `BuildPlanner` 与 `BuildExecutor` 生成真实 ARM7 ELF。创建可执行 QEMU wrapper，将 `$$` 写入测试专属 PID 文件后 `exec` 真实 QEMU。用没有 simulator path 的 `DebugPlanner` 生成 `.debug` 计划并启动 `GDBMISession`。

- [ ] **Step 2: 加入有界停止事件等待**

订阅 `session.events()`，使用任务组把等待限制在 5 秒；只接受 `*stopped` 且 frame address 等于 ELF 入口。旧计划会 `continue` 进入 `.Lhalt`，因此此测试必须先失败或超时。

- [ ] **Step 3: 验证一次单步**

发送：

```swift
_ = try await session.send("-exec-step-instruction")
```

等待下一次 `*stopped`，断言地址比入口增加 4，并读取寄存器确认 `r0 == 1`。

- [ ] **Step 4: 验证有界清理**

调用：

```swift
await session.shutdown(timeout: .seconds(2))
```

轮询 wrapper PID 最多 2 秒，断言 `kill(pid, 0)` 返回 `ESRCH`；测试 defer 中仍执行 shutdown，防止失败路径残留进程。

- [ ] **Step 5: 运行并提交**

Run:

```bash
swift test --filter ARM7QEMUFallbackE2ETests
pgrep -fal 'arm-none-eabi-gdb|qemu-system-arm'
```

Expected: 测试通过，`pgrep` 没有测试残留。

Commit:

```bash
git add Tests/YagartoCoreTests/ARM7QEMUFallbackE2ETests.swift
git commit -m "test: exercise real ARM7 QEMU fallback"
```

### Task 3: 锁定并修正文档安装顺序

**Files:**
- Create: `Tests/YagartoCoreTests/InstallGuideContractTests.swift`
- Modify: `docs/install-from-github.zh-CN.md`

- [ ] **Step 1: 写文档契约失败测试**

从 `#filePath` 向上三级得到仓库根目录，读取安装文档并断言标题出现顺序：

```swift
XCTAssertLessThan(index("构建 ARM7 指令级 GDB simulator"), index("用 doctor 做最终验收"))
XCTAssertLessThan(index("用 doctor 做最终验收"), index("将 App 安装到“应用程序”"))
```

再断言 `open /Applications/YagartoMacApp.app` 只出现在 doctor 之后，以及 `.zprofile` 的 Release PATH 追加命令只出现一次。

- [ ] **Step 2: 运行 RED**

Run:

```bash
swift test --filter InstallGuideContractTests
```

Expected: 当前 App 安装/打开章节位于 simulator 与 doctor 之前，且 PATH 块重复，测试失败。

- [ ] **Step 3: 重排并强化文档**

将章节重排为：

```text
6. 构建 CLI 和 Release App
7. 构建 ARM7 指令级 GDB simulator（必做）
8. 用 doctor 做安装门槛验收（必做）
9. 将 App 安装到“应用程序”并首次打开
10. 在 App 中完成第一个 ARM7 工程
```

在 simulator 与 doctor 章节明确失败即停止；从构建章节删除重复 PATH 段；更新“App 被 macOS 阻止”等交叉引用。

- [ ] **Step 4: 运行 GREEN 并提交**

Run:

```bash
swift test --filter InstallGuideContractTests
git diff --check
```

Expected: 文档契约通过。

Commit:

```bash
git add docs/install-from-github.zh-CN.md Tests/YagartoCoreTests/InstallGuideContractTests.swift
git commit -m "docs: require simulator verification before app launch"
```

### Task 4: 最终回归与真实 App 验收

**Files:**
- Verify only.

- [ ] **Step 1: 严格全量测试**

```bash
mkdir -p .build/qemu-fallback-final-tmp
TMPDIR="$PWD/.build/qemu-fallback-final-tmp" SWIFT_TREAT_WARNINGS_AS_ERRORS=1 swift test
```

Expected: 0 failures。

- [ ] **Step 2: 构建 Release App**

```bash
scripts/build-app.sh Release
file dist/Release/YagartoMacApp.app/Contents/MacOS/YagartoMacApp
```

Expected: arm64 Mach-O App。

- [ ] **Step 3: 强制 QEMU 后端做 App 验收**

在不暴露 simulator 候选的隔离环境中启动 Release App，打开 ARM7 测试工程。确认：

- 后端警告明确显示 ARM926 兼容模式；
- 初次调试停在 `start`；
- “单步指令”立即可用，执行后 PC 增加 4；
- 停止后回到“就绪”，没有红色停止失败提示；
- App 退出后没有专属 GDB/QEMU 残留。

- [ ] **Step 4: 终态检查**

```bash
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: diff clean，工作树干净，提交完整。
