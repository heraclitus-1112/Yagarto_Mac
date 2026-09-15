# YAGARTO 小端32位内存窗口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前逐字节内存页改成默认 `0x00008000`、自动刷新、每行四个小端32位字的 YAGARTO 风格内存窗口。

**Architecture:** `YagartoCore` 保存112字节观察请求并在停止快照中读取；`AppViewModel` 采用快照内存并管理地址提交；`YagartoAppSupport` 将原始字节映射为固定7行的小端word；原生 `NSTableView` 渲染6列。现有严格MI校验、系统AX代理装饰和调试状态机继续复用。

**Tech Stack:** Swift 6.3、Swift Concurrency、SwiftUI、AppKit `NSTableView`、GDB/MI、XCTest。

---

## 文件结构

- `MemoryTablePresentation.swift`：默认窗口、地址规范化/步进、7行小端word模型。
- `DebugSnapshot.swift`、`DebuggerController.swift`：默认112字节请求和只配置不读取的请求入口。
- `ServiceProtocols.swift`、`CoreDebugAdapter.swift`：把待观察地址传给当前或下一调试器。
- `AppViewModel.swift`：停止快照自动更新内存，按状态提交地址。
- `MemoryHexTable.swift`：18个字节列改为6列小端word表。
- `WorkbenchView.swift`：默认地址、步进、自动提交和小端提示，移除长度/读取控件。

### Task 1: 固定窗口和小端word展示模型

**Files:**
- Modify: `Sources/YagartoAppSupport/MemoryTablePresentation.swift`
- Modify: `Tests/YagartoAppSupportTests/MemoryTablePresentationTests.swift`
- Modify: `Tests/YagartoAppSupportTests/AppModelsTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
func testYagartoWindowDefaultsAndAddressNormalization() throws {
    XCTAssertEqual(MemoryWindowLayout.defaultAddressText, "0x00008000")
    XCTAssertEqual(MemoryWindowLayout.byteCount, 112)
    XCTAssertEqual(MemoryWindowLayout.rowCount, 7)
    XCTAssertEqual(try MemoryWindowAddress.normalized("0x8000"), "0x00008000")
    XCTAssertEqual(try MemoryWindowAddress.stepped("0x00008000", byRows: 1), "0x00008010")
    XCTAssertEqual(try MemoryWindowAddress.stepped("0x00008000", byRows: -1), "0x00007FF0")
    XCTAssertThrowsError(try MemoryWindowAddress.normalized("$sp"))
    XCTAssertThrowsError(try MemoryWindowAddress.normalized("0xffffffffffffffff"))
}

func testWordRowsAlwaysContainSevenRowsAndDecodeLittleEndian() throws {
    let block = MIMemoryBlock(
        begin: MIRawNumeric(raw: "0x8000"), offset: MIRawNumeric(raw: "0"),
        end: MIRawNumeric(raw: "0x8010"),
        contents: "fcfdeeff010000000200000003000000"
    )
    let rows = try MemoryWordTableFormatter.rows(from: [block], baseAddress: 0x8000)
    XCTAssertEqual(rows.count, 7)
    XCTAssertEqual(rows[0].addressText, "0x00008000")
    XCTAssertEqual(rows[0].wordTexts,
        ["0xFFEEFDFC", "0x00000001", "0x00000002", "0x00000003"])
    XCTAssertEqual(rows[0].asciiText, "................")
    XCTAssertEqual(rows[1].wordTexts, ["", "", "", ""])
}
```

另加短尾测试：三个字节 `010203` 的word文本为空，辅助值为“数据不完整”，ASCII前三位为点；窗口末地址溢出必须报错。

- [ ] **Step 2: 确认红测试**

```bash
swift test --filter MemoryTablePresentationTests
swift test --filter AppModelsTests.testYagartoWindowDefaultsAndAddressNormalization
```

Expected: 新类型尚不存在导致失败。

- [ ] **Step 3: 实现稳定接口**

```swift
public enum MemoryWindowLayout {
    public static let defaultAddress: UInt64 = 0x8000
    public static let defaultAddressText = "0x00008000"
    public static let bytesPerRow = 16
    public static let wordsPerRow = 4
    public static let rowCount = 7
    public static let byteCount = bytesPerRow * rowCount
}

public enum MemoryWindowAddress {
    public static func normalized(_ input: String) throws -> String
    public static func value(_ input: String) throws -> UInt64
    public static func valueOrDefault(_ input: String) -> UInt64
    public static func stepped(_ input: String, byRows rows: Int) throws -> String
}

public struct MemoryWordTableRow: Equatable, Sendable {
    public let address: UInt64
    public let bytes: [UInt8?] // 固定16项
    public var addressText: String { get }
    public var wordTexts: [String] { get } // 固定4项
    public var wordAccessibilityValues: [String] { get }
    public var asciiText: String { get }
}

public enum MemoryWordTableFormatter {
    public static func rows(
        from blocks: [MIMemoryBlock], baseAddress: UInt64,
        rowCount: Int = MemoryWindowLayout.rowCount
    ) throws -> [MemoryWordTableRow]
}
```

复用现有严格hex解码。每个完整word按 `b0 | b1<<8 | b2<<16 | b3<<24` 合成，格式为 `0x` 加8位大写hex；缺失或不完整word保持空白。始终生成7行骨架。

- [ ] **Step 4: 验证并提交**

```bash
swift test --filter MemoryTablePresentationTests
swift test --filter AppModelsTests
git diff --check
git add Sources/YagartoAppSupport/MemoryTablePresentation.swift Tests/YagartoAppSupportTests/MemoryTablePresentationTests.swift Tests/YagartoAppSupportTests/AppModelsTests.swift
git commit -m "feat: format memory as little-endian words"
```

### Task 2: 调试后端保存自动观察请求

**Files:**
- Modify: `Sources/YagartoCore/DebugSnapshot.swift`
- Modify: `Sources/YagartoCore/DebuggerController.swift`
- Modify: `Sources/YagartoAppSupport/ServiceProtocols.swift`
- Modify: `Sources/YagartoAppSupport/CoreDebugAdapter.swift`
- Modify: `Tests/YagartoCoreTests/DebuggerControllerTests.swift`
- Modify: `Tests/YagartoAppSupportTests/CoreServiceIntegrationTests.swift`

- [ ] **Step 1: 写失败测试**

断言 `DebugMemoryRequest.yagartoWindow == DebugMemoryRequest(address:"0x8000", byteCount:112)`；首次停止快照发送 `-data-read-memory-bytes 0x8000 112`。调用 `controller.setMemoryRequest(address:"0x9000", byteCount:112)` 后，下次停止使用 `0x9000 112`。Adapter 测试覆盖launch前保存和活动会话立即转发。

- [ ] **Step 2: 确认红测试**

```bash
swift test --filter DebuggerControllerTests
swift test --filter CoreServiceIntegrationTests
```

- [ ] **Step 3: 实现请求传播**

```swift
public static let yagartoWindow = DebugMemoryRequest(address: "0x8000", byteCount: 112)

public func setMemoryRequest(_ request: DebugMemoryRequest) throws {
    try validate(request)
    memoryRequest = request
}
```

把controller默认值改为 `.yagartoWindow`。在 `DebugServicing` 加 `setMemoryRequest`；测试/预览替身可用默认空实现，但 `CoreDebugAdapter` 保存 `memoryRequest`，新controller在launch前应用，活动controller立即接收，stop后重置默认。

- [ ] **Step 4: 验证并提交**

```bash
swift test --filter DebuggerControllerTests
swift test --filter CoreServiceIntegrationTests
git diff --check
git add Sources/YagartoCore/DebugSnapshot.swift Sources/YagartoCore/DebuggerController.swift Sources/YagartoAppSupport/ServiceProtocols.swift Sources/YagartoAppSupport/CoreDebugAdapter.swift Tests/YagartoCoreTests/DebuggerControllerTests.swift Tests/YagartoAppSupportTests/CoreServiceIntegrationTests.swift
git commit -m "feat: track automatic memory window requests"
```

### Task 3: 停止快照接入App状态

**Files:**
- Modify: `Sources/YagartoAppSupport/AppViewModel.swift`
- Modify: `Tests/YagartoAppSupportTests/AppViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

测试 `.stateChanged(.stopped)` 后的 `.snapshot(memory:[block])` 会令 `model.memory == [block]`。测试 `setMemoryWindowAddress("0x9000")`：stopped时配置并立即read；running时只配置不read，之后采用停止快照；非法/溢出地址不调用service；stop/工程/profile切换仍清空。

- [ ] **Step 2: 确认红测试**

```bash
swift test --filter AppViewModelTests
```

- [ ] **Step 3: 实现状态流**

```swift
public func setMemoryWindowAddress(_ rawAddress: String) async -> String? {
    do {
        let normalized = try MemoryWindowAddress.normalized(rawAddress)
        let request = DebugMemoryRequest(address: normalized, byteCount: MemoryWindowLayout.byteCount)
        try await debugService.setMemoryRequest(request)
        memory = state == .stopped ? try await debugService.readMemory(request) : []
        errorMessage = nil
        return normalized
    } catch {
        present(error)
        return nil
    }
}
```

在stopped快照事件中加入 `memory = newSnapshot.memory`。保留旧 `readMemory(address:length:)` 兼容接口。

- [ ] **Step 4: 验证并提交**

```bash
swift test --filter AppViewModelTests
git diff --check
git add Sources/YagartoAppSupport/AppViewModel.swift Tests/YagartoAppSupportTests/AppViewModelTests.swift
git commit -m "feat: refresh memory from debugger snapshots"
```

### Task 4: 原生表格改为6列小端word

**Files:**
- Modify: `Sources/YagartoAppSupport/MemoryHexTable.swift`
- Modify: `Tests/YagartoAppSupportTests/MemoryHexTableTests.swift`

- [ ] **Step 1: 写6列表格失败测试**

```swift
XCTAssertEqual(table.tableColumns.count, 6)
XCTAssertEqual(table.tableColumns.map(\.title), ["Address", "0", "4", "8", "C", "ASCII"])
XCTAssertEqual(cells.map { $0.textField?.stringValue },
    ["0x00008000", "0xFFEEFDFC", "0x00000001", "0x00000002", "0x00000003", "................"])
```

空blocks也必须显示7行骨架；短word可见为空且AX值“数据不完整”。真实 `NSTableRow -> AXChildren` 路径改为每行6个系统cell proxy。

- [ ] **Step 2: 确认红测试**

```bash
swift test --filter MemoryHexTableTests
```

- [ ] **Step 3: 更新原生表格**

`MemoryHexTable` 增加 `baseAddress` 参数，成功/空数据都由 `MemoryWordTableFormatter` 生成7行。列枚举改为 `.address/.word(0...3)/.ascii`，word标题固定 `0/4/8/C`，标识为 `memory-word-column-N` 与 `memory-table-row-N-word-N`。继续原位装饰系统row/cell/header proxy，不得恢复虚拟proxy。

- [ ] **Step 4: 验证并提交**

```bash
swift test --filter MemoryHexTableTests
swift test --filter MemoryTablePresentationTests
git diff --check
git add Sources/YagartoAppSupport/MemoryHexTable.swift Tests/YagartoAppSupportTests/MemoryHexTableTests.swift
git commit -m "feat: show little-endian words in memory table"
```

### Task 5: 工作台地址栏和自动交互

**Files:**
- Modify: `Sources/YagartoMacApp/WorkbenchView.swift`
- Modify: `Tests/YagartoAppSupportTests/AccessibilityIdentifierContractTests.swift`

- [ ] **Step 1: 写控件契约失败测试**

契约必须包含 `memory-address`、`memory-address-stepper`、`memory-endianness`，不再包含 `memory-length`、`memory-read`；纯地址辅助方法断言默认 `0x00008000` 和 `±0x10`。

- [ ] **Step 2: 确认红测试**

```bash
swift test --filter AccessibilityIdentifierContractTests
```

- [ ] **Step 3: 替换控件**

删除 `memoryLength`，地址状态默认 `MemoryWindowLayout.defaultAddressText`。顶部使用 Address标签、等宽TextField、16字节步进Stepper和 `Target is LITTLE endian`；提交和步进统一异步调用 `model.setMemoryWindowAddress`。表格传入 `model.memory` 与当前解析的baseAddress。工程/profile变化以及调试状态回到ready时重置为默认地址。

- [ ] **Step 4: 验证并提交**

```bash
swift build --product YagartoMacApp
swift test --filter AccessibilityIdentifierContractTests
swift test --filter AppViewModelTests
swift test --filter MemoryHexTableTests
git diff --check
git add Sources/YagartoMacApp/WorkbenchView.swift Tests/YagartoAppSupportTests/AccessibilityIdentifierContractTests.swift
git commit -m "feat: automate YAGARTO memory window controls"
```

### Task 6: 严格回归和课程验收

**Files:**
- Verify only.

- [ ] **Step 1: 运行严格全量测试**

```bash
mkdir -p .build/little-endian-final-tmp
TMPDIR="$PWD/.build/little-endian-final-tmp" SWIFT_TREAT_WARNINGS_AS_ERRORS=1 swift test
```

- [ ] **Step 2: 构建Release App**

```bash
scripts/build-app.sh Release
file dist/Release/YagartoMacApp.app/Contents/MacOS/YagartoMacApp
```

- [ ] **Step 3: 课程工程验收**

打开 `/Users/macbookair/ARM7/test-2`，首次停在 `start` 后无需点击读取，首行必须为：

```text
Address       0           4           8           C           ASCII
0x00008000    0xFFEEFDFC  0x00000001  0x00000002  0x00000003  ................
```

单步后表格自动刷新；地址步进到 `0x00008010` 后首行同步变化。

- [ ] **Step 4: 终态检查**

```bash
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: 测试0失败、Release App存在、工作树为空。
