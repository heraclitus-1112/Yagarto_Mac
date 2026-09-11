# GDB/MI 调试核心

Phase 4A 在 `YagartoCore` 中提供与界面无关的 GDB/MI3 调试核心。它可以被后续 SwiftUI/AppKit 应用直接依赖，但本阶段没有实现窗口、编辑器或 Xcode 工程，不能据此宣称 GUI 已完成。

## 分层与入口

- `MIParser` 把单条 MI 输出解析为 `MIRecord`。记录覆盖 `^done`、`^running`、`^connected`、`^exit`、`^exited`、`^error`，`*`/`+`/`=` 异步记录，`~`/`@`/`&` 流记录和 `(gdb)` 提示符。
- `GDBMISession` actor 负责一个真实 GDB 进程、MI token、请求响应关联和事件分发。
- `DebuggerStateMachine` 定义固定生命周期图并对非法边返回 `DebuggerTransitionError`。
- `DebuggerController` actor 接收 `ProfileID` 与 `DebugLaunchPlan`，执行 UI 所需的控制命令，并在停止时生成 `DebugSnapshot`。

已有启动计划可以直接使用：

```swift
let controller = DebuggerController(plan: launchPlan)
let events = await controller.events()
try await controller.launch()

for await event in events {
    // Phase 4B 在 MainActor 上把 stateChanged/snapshot/diagnostic 映射到 UI。
}
```

如果 Phase 4B 同时负责编译，则先用 `DebuggerController(profile:)` 创建控制器，再依次调用 `buildStarted()` 与 `buildSucceeded(plan:)`；编译失败调用 `buildFailed()`。

## MI 数据与严格边界

`MIValue` 保留 constant、tuple 和 list；list 明确区分 value-list 与 result-list。`MIResults.fields` 保留原始顺序和重复变量，不会用字典覆盖信息；下标返回第一个值，`values(for:)` 返回全部同名值。这样既能处理 GDB 的 `stack=[frame=...,frame=...]`，也有确定的单值读取规则。

MI C-string 按字节解释 `\\`、`\"`、`\n`、`\r`、`\t`、GDB 用于 ESC（0x1B）的 `\e`、八进制和十六进制转义，随后严格解码 UTF-8。`parse(Data)` 遇到无效 UTF-8 会返回 `.invalidUTF8`，不会静默替换字符。默认单行上限为 256 KiB、嵌套深度为 32；超限、非法转义、未闭合值、未知记录/结果类别与尾随垃圾都是有类型的 `MIParseError`。

`MIResultRecord` 和 `MIAsyncRecord` 提供 error message、stop reason、frame、register names/values、stack、memory 与 disassembly 提取。地址、行号、寄存器值等通过 `MIRawNumeric` 同时保留 GDB 原字符串和可选 `UInt64`，界面不需要在显示与数值操作之间二选一。

## 进程与并发语义

`GDBMISession` 使用 executable、argv 数组和 cwd 直接启动进程，不经过 shell。底层用 `posix_spawn` file actions 把三根 `Pipe` 接到标准流，并用 `POSIX_SPAWN_SETPGROUP` 在 exec 前原子建立独立进程组。argv 归一化器按 GDB 参数语义扫描：只在顶层位置移除 `--interpreter`/`-i` 的分离或等号形式，再插入恰好一个 `--interpreter=mi3`；`-ex`/`--eval-command`、`-x`/`--command` 等需值选项及其紧随值作为不可拆分的一对原样保留，`--args` 或 `--` 后的参数也完全保留。因此即使命令文本或文件名长得像 `--interpreter=...`，也不会被误删。孤立的需值选项（包括空的长选项等号形式）会在启动前返回 `.missingOptionValue` 配置错误。`DebugLaunchPlan` 的所有 `-ex` 与 pipe 命令仍是原始独立 argv 元素。

每个 `send(_:)` 分配单调递增 token。并发请求可以乱序完成而不会串线；`^error` 抛出含 token、原命令、GDB message 与原始记录的 `GDBMISessionError.commandFailed`。取消一个调用只恢复该请求，EOF 或进程退出会恢复所有剩余请求一次。

`events()` 支持多个安全订阅者，并使用 `AsyncStream.bufferingNewest` 有界缓存。默认每个订阅保留 256 个事件；丢弃次数可由 `droppedEventCount` 读取，并以 `eventsDropped` 事件报告。stdout 单行也受 parser 字节上限约束；超长行被丢到下一个换行，后续 MI 仍可继续解析。stderr 及 MI console/target/log 分别事件化；进程终止且 stdout/stderr 都排空后，所有订阅会正常结束。

`shutdown()` 先发送 `-gdb-exit`。在有限等待内没有退出时，依次向独立进程组发送 TERM、KILL；即使 GDB 本身先退出，也会清理仍持有 pipe 的组内后代。唯一 waiter 使用 `waitpid` 回收组长。启动失败映射为 `YagartoExitCode.missingTool`（5）；生产 transport 不使用 Foundation `Process` 或 `terminationHandler`。

## 状态与 snapshot

固定状态图为：

```text
idle -> building -> ready -> launching -> stopped <-> running
                    ^             |          |          |
                    |             +----------+----------+
                    |                    terminating
                    +-------------------------+
```

编译失败回到 `idle`，启动失败回到 `ready`，termination 完成回到 `ready`。运行/停止状态只由 MI `*running` 和 `*stopped` 驱动；命令返回 `^done` 或 `^running` 不被当成 inferior 状态证据。

每次 `*stopped` 都刷新执行位置、寄存器、stack、默认 `$sp` 64-byte memory window、反汇编和有界 console。每条 snapshot 查询默认有 2 秒超时，也可由 controller 初始化参数缩短；超时请求会从 session pending 表移除。frame 或 register 失败产生 critical diagnostic；stack、memory、disassembly 等可选 pane 失败产生非关键 diagnostic。两者都保留 `stopped`，不会阻塞后续命令。

寄存器展示集合固定为：

- ARM7TDMI：`r0-r15` 与 `CPSR`。
- Cortex-M4 / STM32F4：`r0-r15`、`xPSR`、`MSP`、`PSP`、`CONTROL`、`PRIMASK`。

匹配按 GDB 返回的 register number 和 name 完成，允许返回顺序变化、空 name 或缺值；缺值在 snapshot 中为 `nil`。Cortex-M4/STM32F4 不会显示为 CPSR。

控制器公开 `launch`、`run`/`continue`、`pause`、`stepInstruction`、`stepOver`、`stop`、`readMemory`、`setBreakpoint` 和 `removeBreakpoint`。地址表达式、字节数、断点 ID 和换行控制字符都在写入 MI stdin 前验证。

## Phase 4B 消费约束

Phase 4B 应把 controller 保持在非 MainActor 服务层，并仅在 UI 边界消费 `DebuggerEvent`。界面应直接渲染 `DebugSnapshot` 的 raw 值和 diagnostics，不自行推断 GDB 运行状态，也不要另建一套寄存器命名规则。关闭窗口或取消调试任务时调用 `stop()`；不要只取消事件消费 Task 而留下 GDB 进程。
