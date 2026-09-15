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
            let asciiCell = try cell(in: table, column: 17, row: 0)
            XCTAssertEqual(addressCell.accessibilityIdentifier(), "memory-table-row-0-address")
            XCTAssertEqual(firstByteCell.accessibilityIdentifier(), "memory-table-row-0-byte-0")
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

    func testMemoryHexTableRendersInRealHostingView() throws {
        let hosting = NSHostingView(rootView: MemoryHexTable(blocks: [
            block(begin: "0x8000", contents: "fcfdeeff")
        ]).frame(width: 800, height: 320))

        try withWindow(contentView: hosting) {
            let bitmap = try render(hosting)
            XCTAssertEqual(bitmap.pixelsWide, 800)
            XCTAssertEqual(bitmap.pixelsHigh, 320)
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

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
