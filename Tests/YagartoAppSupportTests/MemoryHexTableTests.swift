// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XCTest
import YagartoCore
@testable import YagartoAppSupport

@MainActor
final class MemoryHexTableTests: XCTestCase {
    func testNativeTableExposesColumnsRowCellsGeometryAndSelectableText() throws {
        let controller = MemoryNativeTableController()
        controller.update(rows: try formattedRows())

        try withWindow(contentView: controller.scrollView) {
            let table = controller.tableView
            XCTAssertEqual(table.accessibilityIdentifier(), "memory-table")
            XCTAssertEqual(table.accessibilityRole(), .table)
            XCTAssertEqual(table.tableColumns.count, 18)
            XCTAssertTrue(controller.scrollView.hasHorizontalScroller)
            XCTAssertTrue(controller.scrollView.hasVerticalScroller)

            let expectedHeaderIdentifiers = [
                "memory-table-header-address"
            ] + (0..<16).map {
                "memory-table-header-byte-\($0)"
            } + [
                "memory-table-header-ascii"
            ]
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.accessibilityIdentifier() },
                expectedHeaderIdentifiers
            )

            let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
            XCTAssertEqual(rowView.accessibilityIdentifier(), "memory-table-row-0")
            XCTAssertEqual(rowView.accessibilityRole(), .row)

            let addressCell = try cell(in: table, column: 0, row: 0)
            let firstByteCell = try cell(in: table, column: 1, row: 0)
            let emptyByteCell = try cell(in: table, column: 5, row: 0)
            let asciiCell = try cell(in: table, column: 17, row: 0)
            XCTAssertEqual(addressCell.accessibilityIdentifier(), "memory-table-row-0-address")
            XCTAssertEqual(firstByteCell.accessibilityIdentifier(), "memory-table-row-0-byte-0")
            XCTAssertEqual(emptyByteCell.textField?.stringValue, " ")
            XCTAssertEqual(emptyByteCell.accessibilityValue() as? String, "空")
            XCTAssertEqual(asciiCell.accessibilityIdentifier(), "memory-table-row-0-ascii")

            for cellView in [addressCell, firstByteCell, asciiCell] {
                XCTAssertEqual(cellView.accessibilityRole(), .cell)
                XCTAssertTrue(try XCTUnwrap(cellView.textField).isSelectable)
                assertNonZeroAccessibilityFrame(cellView)
            }
            assertNonZeroAccessibilityFrame(table)
            assertNonZeroAccessibilityFrame(rowView)
            assertNonZeroAccessibilityFrame(try XCTUnwrap(table.headerView))

            // XCTest exposes the native table from the scroll view, but does not
            // return realized NSTableRowView/NSTableCellView objects as its AX children.
            let nativeAX = accessibilitySnapshot(from: controller.scrollView)
            XCTAssertTrue(nativeAX.identifiers.contains("memory-table"))
        }
    }

    func testEquivalentRowsDoNotReloadOrReplaceNativeRowAndCell() throws {
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
            XCTAssertIdentical(
                table.rowView(atRow: 0, makeIfNecessary: true),
                firstRow
            )
            XCTAssertIdentical(
                table.view(atColumn: 0, row: 0, makeIfNecessary: true),
                firstCell
            )
        }
    }

    func testEmptyContentsResolveToEmptyState() {
        XCTAssertEqual(
            MemoryHexTableContent(blocks: [block(begin: "0x8000", contents: "")]),
            .empty
        )
    }

    func testMalformedContentsResolveToErrorState() {
        let content = MemoryHexTableContent(
            blocks: [block(begin: "0x8000", contents: "GG")]
        )

        guard case .error(let message) = content else {
            return XCTFail("Expected malformed contents to produce an error state")
        }
        XCTAssertEqual(message, "内存块 0x8000 包含无效的十六进制数据。")
    }

    func testPublicWrapperHostsPopulatedNativeTableWithIdentifiersAndContents() throws {
        try withHostedMemoryHexTable(blocks: [
            block(begin: "0x8000", contents: "fcfdeeff")
        ]) { hosting in
            let table = try XCTUnwrap(findView(
                ofType: NSTableView.self,
                identifier: "memory-table",
                in: hosting
            ))
            XCTAssertEqual(table.numberOfRows, 1)
            XCTAssertEqual(table.tableColumns.count, 18)
            XCTAssertEqual(
                table.tableColumns.map { $0.headerCell.accessibilityIdentifier() },
                ["memory-table-header-address"]
                    + (0..<16).map { "memory-table-header-byte-\($0)" }
                    + ["memory-table-header-ascii"]
            )

            let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
            XCTAssertEqual(rowView.accessibilityIdentifier(), "memory-table-row-0")

            let cells = try (0..<18).map { try cell(in: table, column: $0, row: 0) }
            XCTAssertEqual(
                cells.map { $0.accessibilityIdentifier() },
                ["memory-table-row-0-address"]
                    + (0..<16).map { "memory-table-row-0-byte-\($0)" }
                    + ["memory-table-row-0-ascii"]
            )
            XCTAssertEqual(
                cells.map { $0.textField?.stringValue },
                ["0x00008000"]
                    + ["FC", "FD", "EE", "FF"]
                    + Array(repeating: " ", count: 12)
                    + ["....            "]
            )
        }
    }

    func testPublicWrapperHostsEmptyInputAndContentsAsNativeSecondaryPrompt() throws {
        let emptyInputs: [[MIMemoryBlock]] = [
            [],
            [block(begin: "0x8000", contents: "")]
        ]

        for blocks in emptyInputs {
            try withHostedMemoryHexTable(blocks: blocks) { hosting in
                let emptyLabel = try XCTUnwrap(findView(
                    ofType: NSTextField.self,
                    identifier: "memory-table-empty",
                    in: hosting
                ))

                XCTAssertEqual(emptyLabel.stringValue, "输入地址和长度，然后在程序暂停时读取内存。")
                XCTAssertEqual(emptyLabel.textColor, .secondaryLabelColor)
                XCTAssertNotNil(findView(
                    ofType: NSView.self,
                    identifier: "memory-table",
                    in: hosting
                ))
                XCTAssertNil(findView(ofType: NSTableView.self, in: hosting))
            }
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

    private func formattedRows() throws -> [MemoryTableRow] {
        try MemoryTableFormatter.rows(from: [
            block(begin: "0x8000", contents: "fcfdeeff")
        ])
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
        operation: (NSView) throws -> Void
    ) throws {
        let hosting = NSHostingView(rootView: MemoryHexTable(blocks: blocks).frame(
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
