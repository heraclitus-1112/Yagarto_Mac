// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoCore

enum MemoryHexTableContent: Equatable {
    case empty
    case rows([MemoryTableRow])
    case error(String)

    init(blocks: [MIMemoryBlock]) {
        guard !blocks.isEmpty else {
            self = .empty
            return
        }

        do {
            let rows = try MemoryTableFormatter.rows(from: blocks)
            self = rows.isEmpty ? .empty : .rows(rows)
        } catch {
            self = .error(error.localizedDescription)
        }
    }
}

public struct MemoryHexTable: View {
    private let content: MemoryHexTableContent

    public init(blocks: [MIMemoryBlock]) {
        content = MemoryHexTableContent(blocks: blocks)
    }

    @ViewBuilder
    public var body: some View {
        switch content {
        case .empty:
            VStack {
                Text("输入地址和长度，然后在程序暂停时读取内存。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory-table-empty")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory-table")
        case .rows(let rows):
            NativeMemoryTable(rows: rows)
        case .error(let message):
            VStack {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("memory-table-error")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memory-table")
        }
    }
}

private struct NativeMemoryTable: NSViewRepresentable {
    let rows: [MemoryTableRow]

    func makeCoordinator() -> MemoryNativeTableController {
        MemoryNativeTableController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows)
    }
}

@MainActor
final class MemoryNativeTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: Equatable {
        case address
        case byte(Int)
        case ascii

        var title: String {
            switch self {
            case .address:
                return "地址"
            case .byte(let index):
                return "+\(String(index, radix: 16, uppercase: true))"
            case .ascii:
                return "ASCII"
            }
        }

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .address:
                return NSUserInterfaceItemIdentifier("memory-address-column")
            case .byte(let index):
                return NSUserInterfaceItemIdentifier("memory-byte-column-\(index)")
            case .ascii:
                return NSUserInterfaceItemIdentifier("memory-ascii-column")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .address:
                return "memory-table-header-address"
            case .byte(let index):
                return "memory-table-header-byte-\(index)"
            case .ascii:
                return "memory-table-header-ascii"
            }
        }

        var width: CGFloat {
            switch self {
            case .address:
                return 112
            case .byte:
                return 38
            case .ascii:
                return 152
            }
        }
    }

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    private(set) var reloadCount = 0

    private var rows: [MemoryTableRow] = []
    private let columns: [Column] = [
        .address
    ] + (0..<16).map {
        .byte($0)
    } + [
        .ascii
    ]

    override init() {
        super.init()
        configureTable()
        configureScrollView()
    }

    func update(rows: [MemoryTableRow]) {
        guard rows != self.rows else { return }
        self.rows = rows
        reloadCount += 1
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard
            rows.indices.contains(row),
            let tableColumn,
            let column = columns.first(where: { $0.identifier == tableColumn.identifier })
        else {
            return nil
        }

        let cell = tableView.makeView(
            withIdentifier: column.identifier,
            owner: nil
        ) as? MemoryNativeTableCellView ?? MemoryNativeTableCellView()
        cell.identifier = column.identifier

        let value = text(for: column, row: rows[row])
        cell.update(
            text: value,
            accessibilityIdentifier: cellAccessibilityIdentifier(for: column, row: row),
            accessibilityLabel: column.title,
            accessibilityValue: value.isEmpty ? "空" : value
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MemoryNativeTableRowView()
        rowView.setAccessibilityIdentifier("memory-table-row-\(row)")
        rowView.setAccessibilityLabel("内存行")
        return rowView
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityIdentifier("memory-table")
        tableView.setAccessibilityLabel("内存十六进制表格")

        for column in columns {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.width = column.width
            tableColumn.minWidth = column.width
            tableColumn.resizingMask = .userResizingMask

            let headerCell = NSTableHeaderCell(textCell: column.title)
            headerCell.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .semibold
            )
            headerCell.alignment = column == .address ? .left : .center
            headerCell.setAccessibilityElement(true)
            headerCell.setAccessibilityRole(.column)
            headerCell.setAccessibilityIdentifier(column.accessibilityIdentifier)
            headerCell.setAccessibilityLabel(column.title)
            tableColumn.headerCell = headerCell
            tableView.addTableColumn(tableColumn)
        }
    }

    private func configureScrollView() {
        scrollView.documentView = tableView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
    }

    private func text(for column: Column, row: MemoryTableRow) -> String {
        switch column {
        case .address:
            return row.addressText
        case .byte(let index):
            let text = row.byteTexts[index]
            return text.isEmpty ? " " : text
        case .ascii:
            return row.asciiText
        }
    }

    private func cellAccessibilityIdentifier(for column: Column, row: Int) -> String {
        let prefix = "memory-table-row-\(row)"
        switch column {
        case .address:
            return "\(prefix)-address"
        case .byte(let index):
            return "\(prefix)-byte-\(index)"
        case .ascii:
            return "\(prefix)-ascii"
        }
    }
}

@MainActor
private final class MemoryNativeTableRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class MemoryNativeTableCellView: NSTableCellView {
    private let valueField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        valueField.isSelectable = true
        valueField.isEditable = false
        valueField.isBezeled = false
        valueField.drawsBackground = false
        valueField.lineBreakMode = .byClipping
        valueField.maximumNumberOfLines = 1
        valueField.setAccessibilityElement(false)
        textField = valueField
        addSubview(valueField)

        NSLayoutConstraint.activate([
            valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        text: String,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        valueField.stringValue = text
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(accessibilityValue)
    }
}
