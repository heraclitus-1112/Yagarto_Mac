// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XCTest
import YagartoCore
@testable import YagartoAppSupport

@MainActor
final class MemoryHexTableTests: XCTestCase {
    func testNativeTableExposesSixWordColumnsCourseContentsAndSelectableGeometry() throws {
        let controller = MemoryNativeTableController()
        controller.update(rows: try formattedRows())

        try withWindow(contentView: controller.scrollView) {
            let table = controller.tableView
            XCTAssertEqual(table.accessibilityIdentifier(), "memory-table")
            XCTAssertEqual(table.accessibilityRole(), .table)
            XCTAssertEqual(table.tableColumns.count, 6)
            XCTAssertEqual(
                table.tableColumns.map(\.identifier.rawValue),
                ["memory-address-column"]
                    + (0..<4).map { "memory-word-column-\($0)" }
                    + ["memory-ascii-column"]
            )
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.stringValue },
                ["Address", "0", "4", "8", "C", "ASCII"]
            )
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.accessibilityIdentifier() },
                ["memory-table-header-address"]
                    + (0..<4).map { "memory-table-header-word-\($0)" }
                    + ["memory-table-header-ascii"]
            )
            XCTAssertTrue(controller.scrollView.hasHorizontalScroller)
            XCTAssertTrue(controller.scrollView.hasVerticalScroller)

            let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
            XCTAssertEqual(rowView.accessibilityIdentifier(), "memory-table-row-0")
            XCTAssertEqual(rowView.accessibilityRole(), .row)

            let cells = try (0..<6).map { try cell(in: table, column: $0, row: 0) }
            XCTAssertEqual(
                cells.map { $0.accessibilityIdentifier() },
                ["memory-table-row-0-address"]
                    + (0..<4).map { "memory-table-row-0-word-\($0)" }
                    + ["memory-table-row-0-ascii"]
            )
            XCTAssertEqual(
                cells.map { $0.textField?.stringValue },
                [
                    "0x00008000", "0xFFEEFDFC", "0x00000001",
                    "0x00000002", "0x00000003", "................"
                ]
            )

            for cellView in cells {
                XCTAssertEqual(cellView.accessibilityRole(), .cell)
                XCTAssertTrue(try XCTUnwrap(cellView.textField).isSelectable)
                assertNonZeroAccessibilityFrame(cellView)
            }
            assertNonZeroAccessibilityFrame(table)
            assertNonZeroAccessibilityFrame(rowView)
            assertNonZeroAccessibilityFrame(try XCTUnwrap(table.headerView))

            let nativeAX = accessibilitySnapshot(from: controller.scrollView)
            XCTAssertTrue(nativeAX.identifiers.contains("memory-table"))
        }
    }

    func testEquivalentRowsPreserveNativeIdentityWhileChangedBaseOrRowsReload() throws {
        let rows = try formattedRows()
        let controller = MemoryNativeTableController()
        controller.update(rows: rows)

        try withWindow(contentView: controller.scrollView) {
            let table = controller.tableView
            let firstRow = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
            let firstCell = try cell(in: table, column: 0, row: 0)
            let reloadCount = controller.reloadCount

            controller.update(rows: rows)
            controller.scrollView.layoutSubtreeIfNeeded()

            XCTAssertEqual(controller.reloadCount, reloadCount)
            XCTAssertIdentical(controller.tableView, table)
            XCTAssertIdentical(table.rowView(atRow: 0, makeIfNecessary: true), firstRow)
            XCTAssertIdentical(
                table.view(atColumn: 0, row: 0, makeIfNecessary: true),
                firstCell
            )

            controller.update(rows: try formattedRows(contents: "01000000"))
            XCTAssertEqual(controller.reloadCount, reloadCount + 1)

            controller.update(rows: try formattedRows(
                baseAddress: 0x9000,
                contents: "01000000"
            ))
            XCTAssertEqual(controller.reloadCount, reloadCount + 2)
        }
    }

    func testParameterizedAccessibilityCellPathDecoratesAllSixSystemProxies() throws {
        let controller = MemoryNativeTableController()
        controller.update(rows: try formattedRows(contents: "010203"))

        try withWindow(contentView: controller.scrollView) {
            let table = controller.tableView
            XCTAssertEqual(try cell(in: table, column: 1, row: 0).textField?.stringValue, " ")
            XCTAssertEqual(try cell(in: table, column: 2, row: 0).textField?.stringValue, " ")
            let cells = try (0..<6).map { column in
                try accessibilityObject(
                    from: XCTUnwrap(table.accessibilityCell(forColumn: column, row: 0)),
                    description: "cell column \(column)"
                )
            }
            XCTAssertEqual(cells.map(accessibilityRole), Array(repeating: .cell, count: 6))
            XCTAssertEqual(cells.map { accessibilityString("AXDescription", of: $0) }, [
                "Address", "0", "4", "8", "C", "ASCII"
            ])
            cells.forEach { assertNonZeroAccessibilityFrame($0) }

            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-address",
                expected: [
                    "AXIdentifier": "memory-table-row-0-address",
                    "AXDescription": "Address",
                    "AXValue": "0x00008000"
                ]
            )
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-word-0",
                expected: [
                    "AXIdentifier": "memory-table-row-0-word-0",
                    "AXDescription": "0",
                    "AXValue": "数据不完整"
                ]
            )
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-word-1",
                expected: [
                    "AXIdentifier": "memory-table-row-0-word-1",
                    "AXDescription": "4",
                    "AXValue": "空"
                ]
            )
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-ascii",
                expected: [
                    "AXIdentifier": "memory-table-row-0-ascii",
                    "AXDescription": "ASCII",
                    "AXValue": "...             "
                ]
            )
            let cellRecords = controller.accessibilityOverrideRecords
                .filter { $0.key.hasPrefix("memory-table-row-0-") }
            XCTAssertEqual(cellRecords.count, 6)
            XCTAssertTrue(cellRecords.values.flatMap { $0 }.allSatisfy(\.succeeded))
        }
    }

    func testRowAccessibilityChildrenPathDecoratesExactlySixSystemCellProxies() throws {
        let controller = MemoryNativeTableController()
        controller.update(rows: try formattedRows(contents: "010203"))
        XCTAssertTrue(controller.accessibilityOverrideRecords.isEmpty)

        try withWindow(contentView: controller.scrollView) {
            let rows = try rawAccessibilityObjects(
                from: controller.tableView,
                selectorName: "accessibilityRows"
            )
            let row = try accessibilityObject(
                from: XCTUnwrap(rows.first),
                description: "row"
            )
            XCTAssertEqual(accessibilityRole(of: row), .row)
            assertNonZeroAccessibilityFrame(row)
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0",
                expected: ["AXIdentifier": "memory-table-row-0", "AXDescription": "内存行"]
            )

            let cellValues = try rawAccessibilityObjects(from: row, attribute: "AXChildren")
            let cells = try cellValues.enumerated().map { column, value in
                try accessibilityObject(
                    from: value,
                    description: "row child column \(column)"
                )
            }

            XCTAssertEqual(cells.count, 6)
            XCTAssertEqual(cells.map(accessibilityRole), Array(repeating: .cell, count: 6))
            cells.forEach { assertNonZeroAccessibilityFrame($0) }

            let cellRecords = controller.accessibilityOverrideRecords
                .filter { $0.key.hasPrefix("memory-table-row-0-") }
            XCTAssertEqual(cellRecords.count, 6)
            XCTAssertTrue(cellRecords.values.flatMap { $0 }.allSatisfy(\.succeeded))
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-word-0",
                expected: [
                    "AXIdentifier": "memory-table-row-0-word-0",
                    "AXDescription": "0",
                    "AXValue": "数据不完整"
                ]
            )
            assertAccessibilityOverrides(
                in: controller,
                identifier: "memory-table-row-0-word-1",
                expected: [
                    "AXIdentifier": "memory-table-row-0-word-1",
                    "AXDescription": "4",
                    "AXValue": "空"
                ]
            )
        }
    }

    func testHeaderAccessibilityProxyDecoratesExactlySixItems() throws {
        let controller = MemoryNativeTableController()
        controller.update(rows: try formattedRows())

        try withWindow(contentView: controller.scrollView) {
            let header = try accessibilityObject(
                from: XCTUnwrap(accessibilityAttribute("AXHeader", of: controller.tableView)),
                description: "header container"
            )
            let headerValues = try rawAccessibilityObjects(from: header, attribute: "AXChildren")
            let headers = try headerValues.enumerated().map { index, value in
                try accessibilityObject(from: value, description: "header \(index)")
            }

            XCTAssertEqual(headers.count, 6)
            XCTAssertEqual(headers.map { accessibilityString("AXDescription", of: $0) }, [
                "Address", "0", "4", "8", "C", "ASCII"
            ])
            headers.forEach { assertNonZeroAccessibilityFrame($0) }

            let headerRecords = controller.accessibilityOverrideRecords
                .filter { $0.key.hasPrefix("memory-table-header-") }
            XCTAssertEqual(headerRecords.count, 6)
            XCTAssertTrue(headerRecords.values.flatMap { $0 }.allSatisfy(\.succeeded))
            XCTAssertEqual(
                Set(headerRecords.keys),
                Set(["memory-table-header-address"]
                    + (0..<4).map { "memory-table-header-word-\($0)" }
                    + ["memory-table-header-ascii"])
            )
        }
    }

    func testEmptyBlocksAndContentsResolveToSevenRowSkeletonAtDefaultBase() throws {
        for blocks in [[], [block(begin: "0x8000", contents: "")]] {
            let content = MemoryHexTableContent(blocks: blocks)
            guard case .rows(let rows) = content else {
                return XCTFail("Expected empty data to produce the fixed word-table skeleton")
            }

            XCTAssertEqual(rows.count, 7)
            XCTAssertEqual(rows.map(\.addressText), [
                "0x00008000", "0x00008010", "0x00008020", "0x00008030",
                "0x00008040", "0x00008050", "0x00008060"
            ])
            XCTAssertTrue(rows.allSatisfy {
                $0.wordTexts == Array(repeating: "", count: 4)
                    && $0.wordAccessibilityValues == Array(repeating: "空", count: 4)
                    && $0.asciiText == String(repeating: " ", count: 16)
            })
        }
    }

    func testCustomBaseAddressCreatesSevenRowsBeginningAtThatAddress() {
        let content = MemoryHexTableContent(blocks: [], baseAddress: 0x9000)
        guard case .rows(let rows) = content else {
            return XCTFail("Expected custom base address to produce rows")
        }
        XCTAssertEqual(rows.first?.addressText, "0x00009000")
        XCTAssertEqual(rows.last?.addressText, "0x00009060")
    }

    func testMalformedContentsAndOverflowingBaseResolveToErrorState() {
        let malformed = MemoryHexTableContent(
            blocks: [block(begin: "0x8000", contents: "GG")]
        )
        guard case .error(let malformedMessage) = malformed else {
            return XCTFail("Expected malformed contents to produce an error state")
        }
        XCTAssertEqual(malformedMessage, "内存块 0x8000 包含无效的十六进制数据。")

        let overflowing = MemoryHexTableContent(
            blocks: [],
            baseAddress: UInt64.max - UInt64(MemoryWindowLayout.byteCount - 2)
        )
        guard case .error(let overflowMessage) = overflowing else {
            return XCTFail("Expected overflowing base to produce an error state")
        }
        XCTAssertEqual(
            overflowMessage,
            "内存块 \(UInt64.max - UInt64(MemoryWindowLayout.byteCount - 2)) 的地址范围超出 UInt64。"
        )
    }

    func testPublicWrapperHostsPopulatedNativeWordTableWithCourseContents() throws {
        try withHostedMemoryHexTable(blocks: [
            block(
                begin: "0x8000",
                contents: "fcfdeeff010000000200000003000000"
            )
        ]) { hosting in
            let table = try XCTUnwrap(findView(
                ofType: NSTableView.self,
                identifier: "memory-table",
                in: hosting
            ))
            XCTAssertEqual(table.numberOfRows, 7)
            XCTAssertEqual(table.tableColumns.count, 6)
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.stringValue },
                ["Address", "0", "4", "8", "C", "ASCII"]
            )
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.accessibilityIdentifier() },
                ["memory-table-header-address"]
                    + (0..<4).map { "memory-table-header-word-\($0)" }
                    + ["memory-table-header-ascii"]
            )
            let cells = try (0..<6).map { try cell(in: table, column: $0, row: 0) }
            XCTAssertEqual(
                cells.map { $0.accessibilityIdentifier() },
                ["memory-table-row-0-address"]
                    + (0..<4).map { "memory-table-row-0-word-\($0)" }
                    + ["memory-table-row-0-ascii"]
            )
            XCTAssertEqual(
                cells.map { $0.textField?.stringValue },
                [
                    "0x00008000", "0xFFEEFDFC", "0x00000001",
                    "0x00000002", "0x00000003", "................"
                ]
            )
        }
    }

    func testPublicWrapperHostsEmptyDataAsSevenRowsWithoutEmptyStatusView() throws {
        for blocks in [[], [block(begin: "0x8000", contents: "")]] {
            try withHostedMemoryHexTable(blocks: blocks) { hosting in
                let table = try XCTUnwrap(findView(
                    ofType: NSTableView.self,
                    identifier: "memory-table",
                    in: hosting
                ))
                XCTAssertEqual(table.numberOfRows, 7)
                XCTAssertNil(findView(
                    ofType: NSTextField.self,
                    identifier: "memory-table-empty",
                    in: hosting
                ))

                let firstCells = try (0..<6).map { try cell(in: table, column: $0, row: 0) }
                XCTAssertEqual(firstCells.map { $0.textField?.stringValue }, [
                    "0x00008000", " ", " ", " ", " ", String(repeating: " ", count: 16)
                ])
                let lastAddress = try cell(in: table, column: 0, row: 6)
                XCTAssertEqual(lastAddress.textField?.stringValue, "0x00008060")
            }
        }
    }

    func testPublicWrapperUsesCustomBaseAddress() throws {
        try withHostedMemoryHexTable(blocks: [], baseAddress: 0x9000) { hosting in
            let table = try XCTUnwrap(findView(
                ofType: NSTableView.self,
                identifier: "memory-table",
                in: hosting
            ))
            XCTAssertEqual(
                try cell(in: table, column: 0, row: 0).textField?.stringValue,
                "0x00009000"
            )
            XCTAssertEqual(
                try cell(in: table, column: 0, row: 6).textField?.stringValue,
                "0x00009060"
            )
        }
    }

    func testPublicWrapperHostsMalformedContentsAsNativeOrangeWarning() throws {
        try withHostedMemoryHexTable(blocks: [
            block(begin: "0x8000", contents: "GG")
        ]) { hosting in
            let errorLabel = try XCTUnwrap(findView(
                ofType: NSTextField.self,
                identifier: "memory-table-error",
                in: hosting
            ))
            let warningIcon = try XCTUnwrap(findView(
                ofType: NSImageView.self,
                identifier: "memory-table-error-icon",
                in: hosting
            ))

            XCTAssertEqual(errorLabel.stringValue, "内存块 0x8000 包含无效的十六进制数据。")
            XCTAssertEqual(errorLabel.textColor, .systemOrange)
            XCTAssertNotNil(warningIcon.image)
            XCTAssertEqual(warningIcon.contentTintColor, .systemOrange)
            XCTAssertNotNil(findView(
                ofType: NSView.self,
                identifier: "memory-table",
                in: hosting
            ))
        }
    }

    private func formattedRows(
        baseAddress: UInt64 = MemoryWindowLayout.defaultAddress,
        contents: String = "fcfdeeff010000000200000003000000"
    ) throws -> [MemoryWordTableRow] {
        try MemoryWordTableFormatter.rows(
            from: [block(begin: "0x\(String(baseAddress, radix: 16))", contents: contents)],
            baseAddress: baseAddress
        )
    }

    private func block(begin: String, contents: String) -> MIMemoryBlock {
        MIMemoryBlock(
            begin: MIRawNumeric(raw: begin),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: begin),
            contents: contents
        )
    }

    private func cell(
        in table: NSTableView,
        column: Int,
        row: Int
    ) throws -> NSTableCellView {
        try XCTUnwrap(
            table.view(atColumn: column, row: row, makeIfNecessary: true)
                as? NSTableCellView
        )
    }

    private func withWindow(
        contentView: NSView,
        operation: () throws -> Void
    ) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        contentView.frame = window.contentView?.bounds ?? .zero
        contentView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        try operation()
    }

    private func withHostedMemoryHexTable(
        blocks: [MIMemoryBlock],
        baseAddress: UInt64 = MemoryWindowLayout.defaultAddress,
        operation: (NSView) throws -> Void
    ) throws {
        let hosting = NSHostingView(rootView: MemoryHexTable(
            blocks: blocks,
            baseAddress: baseAddress
        ).frame(
            width: 800,
            height: 320
        ))
        try withWindow(contentView: hosting) {
            try operation(hosting)
        }
    }

    private func findView<ViewType: NSView>(
        ofType type: ViewType.Type,
        identifier: String? = nil,
        in root: NSView
    ) -> ViewType? {
        if let view = root as? ViewType,
           identifier == nil || view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in root.subviews {
            if let match = findView(ofType: type, identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func assertNonZeroAccessibilityFrame(
        _ view: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = view.accessibilityFrame()
        XCTAssertGreaterThan(frame.width, 0, "AX frame: \(frame)", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, "AX frame: \(frame)", file: file, line: line)
    }

    private func assertNonZeroAccessibilityFrame(
        _ object: NSObject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard
            let position = accessibilityAttribute("AXPosition", of: object) as? NSValue,
            let size = accessibilityAttribute("AXSize", of: object) as? NSValue
        else {
            return XCTFail(
                "System proxy \(type(of: object)) does not expose AXPosition and AXSize",
                file: file,
                line: line
            )
        }
        let frame = NSRect(origin: position.pointValue, size: size.sizeValue)
        XCTAssertGreaterThan(frame.width, 0, "AX frame: \(frame)", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, "AX frame: \(frame)", file: file, line: line)
    }

    private func accessibilityObject(
        from value: Any,
        description: String
    ) throws -> NSObject {
        try XCTUnwrap(
            value as? NSObject,
            "System \(description) proxy has runtime type \(type(of: value))"
        )
    }

    private func accessibilityRole(of object: NSObject) -> NSAccessibility.Role? {
        guard let rawValue = accessibilityString("AXRole", of: object) else {
            return nil
        }
        return NSAccessibility.Role(rawValue: rawValue)
    }

    private func accessibilityString(_ attribute: String, of object: NSObject) -> String? {
        accessibilityAttribute(attribute, of: object) as? String
    }

    private func accessibilityAttribute(_ attribute: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: attribute)?.takeUnretainedValue()
    }

    private func rawAccessibilityObjects(
        from object: NSObject,
        selectorName: String
    ) throws -> [Any] {
        let selector = NSSelectorFromString(selectorName)
        let rawValue = try XCTUnwrap(
            object.perform(selector)?.takeUnretainedValue(),
            "Selector \(selectorName) returned nil"
        )
        let array = try XCTUnwrap(
            rawValue as? NSArray,
            "Selector \(selectorName) returned \(type(of: rawValue)) instead of NSArray"
        )
        return array.map { $0 }
    }

    private func assertAccessibilityOverrides(
        in controller: MemoryNativeTableController,
        identifier: String,
        expected: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let records = controller.accessibilityOverrideRecords[identifier] ?? []
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: records.map { ($0.attribute, $0.value) }),
            expected,
            file: file,
            line: line
        )
        XCTAssertTrue(records.allSatisfy(\.succeeded), file: file, line: line)
    }

    private func rawAccessibilityObjects(
        from object: NSObject,
        attribute: String
    ) throws -> [Any] {
        let rawValue = try XCTUnwrap(
            accessibilityAttribute(attribute, of: object),
            "Attribute \(attribute) returned nil"
        )
        let array = try XCTUnwrap(
            rawValue as? NSArray,
            "Attribute \(attribute) returned \(type(of: rawValue)) instead of NSArray"
        )
        return array.map { $0 }
    }

    private struct AccessibilitySnapshot {
        var identifiers: Set<String> = []
        var visited: Set<ObjectIdentifier> = []
    }

    private func accessibilitySnapshot(from root: NSView) -> AccessibilitySnapshot {
        var snapshot = AccessibilitySnapshot()
        collectAccessibility(from: root, snapshot: &snapshot)
        return snapshot
    }

    private func collectAccessibility(
        from object: NSObject,
        snapshot: inout AccessibilitySnapshot
    ) {
        guard snapshot.visited.insert(ObjectIdentifier(object)).inserted else { return }

        let identifier: String?
        let children: [Any]
        if let view = object as? NSView {
            let value = view.accessibilityIdentifier()
            identifier = value.isEmpty ? nil : value
            children = view.accessibilityChildren() ?? []
        } else if let element = object as? NSAccessibilityElement {
            identifier = element.accessibilityIdentifier()
            children = element.accessibilityChildren() ?? []
        } else if let cell = object as? NSCell {
            let value = cell.accessibilityIdentifier()
            identifier = value.isEmpty ? nil : value
            children = cell.accessibilityChildren() ?? []
        } else {
            return
        }

        if let identifier {
            snapshot.identifiers.insert(identifier)
        }
        for case let child as NSObject in children {
            collectAccessibility(from: child, snapshot: &snapshot)
        }
    }

}
