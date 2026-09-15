# YAGARTO 风格内存十六进制表格 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把原生 App 的连续内存十六进制字符串替换为每行 16 字节、带地址和 ASCII 列的 YAGARTO 风格表格。

**Architecture:** 保持 `YagartoCore` 的 GDB/MI 内存读取协议不变，在 `YagartoAppSupport` 中加入纯格式化器和独立 SwiftUI 表格视图。`WorkbenchView` 只把现有 `[MIMemoryBlock]` 交给表格，不改变地址校验、调试状态或读取时机。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit `NSHostingView`、Swift Package Manager、XCTest。

---

## 文件结构

- 新建 `Sources/YagartoAppSupport/MemoryTablePresentation.swift`：把 MI 内存块严格转换为 16 字节展示行，并负责地址、十六进制和重叠校验。
- 新建 `Sources/YagartoAppSupport/MemoryHexTable.swift`：渲染地址、`+0...+F`、ASCII、空状态和格式错误。
- 新建 `Tests/YagartoAppSupportTests/MemoryTablePresentationTests.swift`：覆盖课程数据、非对齐地址、分块及损坏输入。
- 新建 `Tests/YagartoAppSupportTests/MemoryHexTableTests.swift`：在真实 `NSHostingView` 中检查表格的可访问结构。
- 修改 `Sources/YagartoMacApp/WorkbenchView.swift:303`：用新表格替换连续字符串输出。

### Task 1: 用纯格式化器生成 16 字节内存行

**Files:**
- Create: `Tests/YagartoAppSupportTests/MemoryTablePresentationTests.swift`
- Create: `Sources/YagartoAppSupport/MemoryTablePresentation.swift`

- [ ] **Step 1: 写课程数据、换行和 ASCII 的失败测试**

创建测试文件：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import YagartoCore
@testable import YagartoAppSupport

final class MemoryTablePresentationTests: XCTestCase {
    func testCourseBytesProduceSixteenByteRowsWithoutEndianReordering() throws {
        let block = MIMemoryBlock(
            begin: MIRawNumeric(raw: "0x8000"),
            offset: MIRawNumeric(raw: "0x0"),
            end: MIRawNumeric(raw: "0x8014"),
            contents: "fcfdeeff01000000020000000300000004000000"
        )

        let rows = try MemoryTableFormatter.rows(from: [block])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].addressText, "0x00008000")
        XCTAssertEqual(
            rows[0].byteTexts,
            ["FC", "FD", "EE", "FF", "01", "00", "00", "00",
             "02", "00", "00", "00", "03", "00", "00", "00"]
        )
        XCTAssertEqual(rows[0].asciiText, "................")
        XCTAssertEqual(rows[1].addressText, "0x00008010")
        XCTAssertEqual(Array(rows[1].byteTexts.prefix(4)), ["04", "00", "00", "00"])
        XCTAssertEqual(Array(rows[1].byteTexts.suffix(12)), Array(repeating: "", count: 12))
    }

    func testPrintableASCIIAndNonAlignedAddressArePreserved() throws {
        let block = MIMemoryBlock(
            begin: MIRawNumeric(raw: "0x8003"),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: "0x8015"),
            contents: "4142207e001f7f3031323334353637383930"
        )

        let rows = try MemoryTableFormatter.rows(from: [block])

        XCTAssertEqual(rows.map(\.addressText), ["0x00008003", "0x00008013"])
        XCTAssertEqual(String(rows[0].asciiText.prefix(7)), "AB ~...")
        XCTAssertEqual(Array(rows[1].byteTexts.prefix(2)), ["39", "30"])
    }

    func testContiguousBlocksMergeButGapsStartANewRow() throws {
        let blocks = [
            block(begin: "0x1000", contents: "0102"),
            block(begin: "0x1002", contents: "0304"),
            block(begin: "0x2000", contents: "0506")
        ]

        let rows = try MemoryTableFormatter.rows(from: blocks)

        XCTAssertEqual(rows.map(\.addressText), ["0x00001000", "0x00002000"])
        XCTAssertEqual(Array(rows[0].byteTexts.prefix(4)), ["01", "02", "03", "04"])
        XCTAssertEqual(Array(rows[1].byteTexts.prefix(2)), ["05", "06"])
    }

    func testMalformedContentsOverflowAndConflictingOverlapFailExplicitly() {
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: [block(begin: "bad", contents: "00")])) {
            XCTAssertEqual($0 as? MemoryTableFormattingError, .invalidAddress("bad"))
        }
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: [block(begin: "0x10", contents: "0")])) {
            XCTAssertEqual($0 as? MemoryTableFormattingError, .oddHexDigitCount(address: "0x10"))
        }
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: [block(begin: "0x10", contents: "GG")])) {
            XCTAssertEqual($0 as? MemoryTableFormattingError, .invalidHex(address: "0x10"))
        }
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: [block(begin: "0xffffffffffffffff", contents: "0001")])) {
            XCTAssertEqual($0 as? MemoryTableFormattingError, .addressOverflow("0xffffffffffffffff"))
        }
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: [
            block(begin: "0x20", contents: "01"),
            block(begin: "0x20", contents: "02")
        ])) {
            XCTAssertEqual($0 as? MemoryTableFormattingError, .conflictingByte(address: 0x20))
        }
    }

    private func block(begin: String, contents: String) -> MIMemoryBlock {
        let start = MIRawNumeric(raw: begin)
        return MIMemoryBlock(
            begin: start,
            offset: MIRawNumeric(raw: "0"),
            end: start,
            contents: contents
        )
    }
}
```

- [ ] **Step 2: 运行测试并确认因类型尚不存在而失败**

Run:

```bash
swift test --filter MemoryTablePresentationTests
```

Expected: 编译失败，包含 `cannot find 'MemoryTableFormatter' in scope`。

- [ ] **Step 3: 实现严格的内存表格格式化器**

创建 `Sources/YagartoAppSupport/MemoryTablePresentation.swift`：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

public enum MemoryTableFormattingError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress(String)
    case oddHexDigitCount(address: String)
    case invalidHex(address: String)
    case addressOverflow(String)
    case conflictingByte(address: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "调试器返回了无效内存地址：\(address)"
        case .oddHexDigitCount(let address):
            return "地址 \(address) 的内存数据缺少半个字节。"
        case .invalidHex(let address):
            return "地址 \(address) 的内存数据不是有效十六进制。"
        case .addressOverflow(let address):
            return "地址 \(address) 的内存范围发生溢出。"
        case .conflictingByte(let address):
            return String(format: "调试器为地址 0x%llX 返回了互相冲突的数据。", address)
        }
    }
}

public struct MemoryTableRow: Equatable, Sendable {
    public let address: UInt64
    public let bytes: [UInt8]

    public init(address: UInt64, bytes: [UInt8]) {
        precondition((1...16).contains(bytes.count))
        self.address = address
        self.bytes = bytes
    }

    public var addressText: String {
        String(format: "0x%08llX", address)
    }

    public var byteTexts: [String] {
        bytes.map { String(format: "%02X", $0) }
            + Array(repeating: "", count: 16 - bytes.count)
    }

    public var asciiText: String {
        let visible = bytes.map { byte in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(visible) + String(repeating: " ", count: 16 - bytes.count)
    }
}

public enum MemoryTableFormatter {
    public static func rows(from blocks: [MIMemoryBlock]) throws -> [MemoryTableRow] {
        var memory: [UInt64: UInt8] = [:]
        for block in blocks {
            guard let begin = block.begin.numeric else {
                throw MemoryTableFormattingError.invalidAddress(block.begin.raw)
            }
            let encoded = Array(block.contents.utf8)
            guard encoded.count.isMultiple(of: 2) else {
                throw MemoryTableFormattingError.oddHexDigitCount(address: block.begin.raw)
            }
            for byteIndex in stride(from: 0, to: encoded.count, by: 2) {
                guard let high = hexNibble(encoded[byteIndex]),
                      let low = hexNibble(encoded[byteIndex + 1]) else {
                    throw MemoryTableFormattingError.invalidHex(address: block.begin.raw)
                }
                let delta = UInt64(byteIndex / 2)
                let (address, overflow) = begin.addingReportingOverflow(delta)
                guard !overflow else {
                    throw MemoryTableFormattingError.addressOverflow(block.begin.raw)
                }
                let value = high << 4 | low
                if let existing = memory[address], existing != value {
                    throw MemoryTableFormattingError.conflictingByte(address: address)
                }
                memory[address] = value
            }
        }

        let ordered = memory.sorted { $0.key < $1.key }
        guard let first = ordered.first else { return [] }
        var rows: [MemoryTableRow] = []
        var rowAddress = first.key
        var rowBytes: [UInt8] = []

        for (address, byte) in ordered {
            let expected = rowAddress.addingReportingOverflow(UInt64(rowBytes.count))
            if rowBytes.count == 16 || expected.overflow || address != expected.partialValue {
                rows.append(MemoryTableRow(address: rowAddress, bytes: rowBytes))
                rowAddress = address
                rowBytes = []
            }
            rowBytes.append(byte)
        }
        if !rowBytes.isEmpty {
            rows.append(MemoryTableRow(address: rowAddress, bytes: rowBytes))
        }
        return rows
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
```

- [ ] **Step 4: 运行格式化器测试并修正编译细节**

Run:

```bash
swift test --filter MemoryTablePresentationTests
```

Expected: `MemoryTablePresentationTests` 全部通过。

- [ ] **Step 5: 提交纯格式化器**

```bash
git add Sources/YagartoAppSupport/MemoryTablePresentation.swift \
  Tests/YagartoAppSupportTests/MemoryTablePresentationTests.swift
git commit -m "feat: format debugger memory as hex rows"
```

### Task 2: 构建可访问的 YAGARTO 风格 SwiftUI 表格

**Files:**
- Create: `Tests/YagartoAppSupportTests/MemoryHexTableTests.swift`
- Create: `Sources/YagartoAppSupport/MemoryHexTable.swift`

- [ ] **Step 1: 写表头、数据行、空状态和错误状态的失败测试**

创建 `Tests/YagartoAppSupportTests/MemoryHexTableTests.swift`：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XCTest
import YagartoCore
@testable import YagartoAppSupport

@MainActor
final class MemoryHexTableTests: XCTestCase {
    func testTableExposesAddressSixteenByteColumnsASCIIAndRow() throws {
        let block = MIMemoryBlock(
            begin: MIRawNumeric(raw: "0x8000"),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: "0x8004"),
            contents: "fcfdeeff"
        )
        let hosting = host(MemoryHexTable(blocks: [block]))

        let identifiers = accessibilityIdentifiers(in: hosting)

        XCTAssertTrue(identifiers.contains("memory-table"))
        XCTAssertTrue(identifiers.contains("memory-table-header-address"))
        for index in 0..<16 {
            XCTAssertTrue(identifiers.contains("memory-table-header-byte-\(index)"))
        }
        XCTAssertTrue(identifiers.contains("memory-table-header-ascii"))
        XCTAssertTrue(identifiers.contains("memory-table-row-0"))
    }

    func testEmptyAndMalformedBlocksExposeDifferentStates() {
        let empty = host(MemoryHexTable(blocks: []))
        XCTAssertTrue(accessibilityIdentifiers(in: empty).contains("memory-table-empty"))

        let malformed = MIMemoryBlock(
            begin: MIRawNumeric(raw: "0x8000"),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: "0x8001"),
            contents: "GG"
        )
        let error = host(MemoryHexTable(blocks: [malformed]))
        XCTAssertTrue(accessibilityIdentifiers(in: error).contains("memory-table-error"))
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_200, height: 280)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return hosting
    }

    private func accessibilityIdentifiers(in root: NSView) -> Set<String> {
        var result: Set<String> = []
        var visited: Set<ObjectIdentifier> = []

        func visit(_ object: Any) {
            if let view = object as? NSView {
                let identity = ObjectIdentifier(view)
                guard visited.insert(identity).inserted else { return }
                if let identifier = view.accessibilityIdentifier(), !identifier.isEmpty {
                    result.insert(identifier)
                }
                view.subviews.forEach(visit)
                view.accessibilityChildren()?.forEach(visit)
            } else if let element = object as? NSAccessibilityElement {
                let identity = ObjectIdentifier(element)
                guard visited.insert(identity).inserted else { return }
                if let identifier = element.accessibilityIdentifier(), !identifier.isEmpty {
                    result.insert(identifier)
                }
                element.accessibilityChildren()?.forEach(visit)
            }
        }

        visit(root)
        return result
    }
}
```

- [ ] **Step 2: 运行视图测试并确认因表格类型尚不存在而失败**

Run:

```bash
swift test --filter MemoryHexTableTests
```

Expected: 编译失败，包含 `cannot find 'MemoryHexTable' in scope`。

- [ ] **Step 3: 实现表格、空状态和错误状态**

创建 `Sources/YagartoAppSupport/MemoryHexTable.swift`：

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import YagartoCore

public struct MemoryHexTable: View {
    private let blocks: [MIMemoryBlock]

    public init(blocks: [MIMemoryBlock]) {
        self.blocks = blocks
    }

    public var body: some View {
        Group {
            if blocks.isEmpty {
                Text("输入地址和长度，然后在程序暂停时读取内存。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory-table-empty")
            } else {
                formattedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("memory-table")
    }

    @ViewBuilder
    private var formattedContent: some View {
        switch formattedRows {
        case .success(let rows):
            table(rows)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("memory-table-error")
        }
    }

    private var formattedRows: Result<[MemoryTableRow], Error> {
        Result { try MemoryTableFormatter.rows(from: blocks) }
    }

    private func table(_ rows: [MemoryTableRow]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 5) {
                GridRow {
                    header("地址", identifier: "memory-table-header-address")
                    ForEach(0..<16, id: \.self) { index in
                        header(String(format: "+%X", index), identifier: "memory-table-header-byte-\(index)")
                    }
                    header("ASCII", identifier: "memory-table-header-ascii")
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        cell(row.addressText)
                        ForEach(Array(row.byteTexts.enumerated()), id: \.offset) { _, byte in
                            cell(byte.isEmpty ? "  " : byte)
                        }
                        cell(row.asciiText)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memory-table-row-\(index)")
                }
            }
            .padding(8)
        }
        .textSelection(.enabled)
    }

    private func header(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier)
    }

    private func cell(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
    }
}
```

- [ ] **Step 4: 运行视图测试并确认通过**

Run:

```bash
swift test --filter MemoryHexTableTests
```

Expected: `MemoryHexTableTests` 全部通过，辅助遍历能够同时发现 `NSView` 与 `NSAccessibilityElement` 上的标识。

- [ ] **Step 5: 提交表格视图**

```bash
git add Sources/YagartoAppSupport/MemoryHexTable.swift \
  Tests/YagartoAppSupportTests/MemoryHexTableTests.swift
git commit -m "feat: add accessible memory hex table"
```

### Task 3: 接入工作台内存页

**Files:**
- Modify: `Sources/YagartoMacApp/WorkbenchView.swift:303-327`

- [ ] **Step 1: 先构建当前 App，建立接入前基线**

Run:

```bash
swift build --product YagartoMacApp
```

Expected: 构建成功，证明后续失败来自工作台接入改动。

- [ ] **Step 2: 用表格替换连续字符串区域**

把 `memoryPane` 中原来的第二个 `ScrollView`：

```swift
ScrollView {
    VStack(alignment: .leading) {
        ForEach(Array(model.memory.enumerated()), id: \.offset) { _, block in
            Text("\(block.begin.raw): \(block.contents)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

替换为：

```swift
MemoryHexTable(blocks: model.memory)
```

地址、长度、读取按钮和 `.disabled(model.state != .stopped)` 保持原样。

- [ ] **Step 3: 构建 App 并运行相关测试**

Run:

```bash
swift build --product YagartoMacApp
swift test --filter MemoryTablePresentationTests
swift test --filter MemoryHexTableTests
swift test --filter AppModelsTests.testMemoryValidationAcceptsHexAndStackButRejectsUnsafeInput
```

Expected: App 构建成功，三个测试选择均通过。

- [ ] **Step 4: 提交工作台接入**

```bash
git add Sources/YagartoMacApp/WorkbenchView.swift
git commit -m "feat: show YAGARTO-style memory table"
```

### Task 4: 完整回归和课程示例验收

**Files:**
- Verify only; no planned production file changes.

- [ ] **Step 1: 运行严格完整测试**

Run:

```bash
SWIFT_TREAT_WARNINGS_AS_ERRORS=1 swift test
```

Expected: 全部测试通过，无编译警告。

- [ ] **Step 2: 构建 Release App 包**

Run:

```bash
scripts/build-app.sh Release
```

Expected: `dist/Release/YagartoMacApp.app` 构建成功。

- [ ] **Step 3: 使用课程工程进行手工冒烟验收**

打开 `/Users/macbookair/ARM7/test-2`，启动调试并暂停，在“内存”页输入：

```text
地址：0x8000
长度：52
```

点击“读取”，逐项确认：

```text
首行地址：0x00008000
首四字节：FC FD EE FF
随后四字节：01 00 00 00
行地址依次：0x00008000、0x00008010、0x00008020、0x00008030
最后一行不足 16 字节的单元格为空
```

再把地址改为 `$sp`、长度改为 `64`，确认合法栈地址能够使用同一表格读取；若该示例没有初始化可读栈，则应显示调试器原始读取错误，而不是 App 崩溃。

- [ ] **Step 4: 检查提交和工作树**

Run:

```bash
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: `git diff --check` 无输出，工作树为空，分支包含设计提交及三个功能提交。
