// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ObjectiveC
import SwiftUI
import YagartoCore

enum MemoryHexTableContent: Equatable {
    case rows([MemoryWordTableRow])
    case error(String)

    init(
        blocks: [MIMemoryBlock],
        baseAddress: UInt64 = MemoryWindowLayout.defaultAddress
    ) {
        do {
            self = .rows(try MemoryWordTableFormatter.rows(
                from: blocks,
                baseAddress: baseAddress
            ))
        } catch {
            self = .error(error.localizedDescription)
        }
    }
}

public struct MemoryHexTable: View {
    private let content: MemoryHexTableContent

    public init(
        blocks: [MIMemoryBlock],
        baseAddress: UInt64 = MemoryWindowLayout.defaultAddress
    ) {
        content = MemoryHexTableContent(blocks: blocks, baseAddress: baseAddress)
    }

    @ViewBuilder
    public var body: some View {
        switch content {
        case .rows(let rows):
            NativeMemoryTable(rows: rows)
        case .error(let message):
            NativeMemoryStatus(content: .error(message))
        }
    }
}

private enum NativeMemoryStatusContent {
    case error(String)
}

private struct NativeMemoryStatus: NSViewRepresentable {
    let content: NativeMemoryStatusContent

    func makeNSView(context: Context) -> MemoryNativeStatusView {
        MemoryNativeStatusView()
    }

    func updateNSView(_ view: MemoryNativeStatusView, context: Context) {
        view.update(content: content)
    }
}

@MainActor
private final class MemoryNativeStatusView: NSView {
    private let stack = NSStackView()
    private let warningIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("memory-table")
        setAccessibilityLabel("内存")

        warningIcon.translatesAutoresizingMaskIntoConstraints = false
        warningIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "警告"
        )
        warningIcon.imageScaling = .scaleProportionallyDown
        warningIcon.setAccessibilityIdentifier("memory-table-error-icon")
        warningIcon.setAccessibilityLabel("警告")

        statusLabel.isSelectable = true
        statusLabel.isEditable = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(warningIcon)
        stack.addArrangedSubview(statusLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            warningIcon.widthAnchor.constraint(equalToConstant: 16),
            warningIcon.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let fittingSize = stack.fittingSize
        return NSSize(width: fittingSize.width + 16, height: fittingSize.height + 16)
    }

    func update(content: NativeMemoryStatusContent) {
        switch content {
        case .error(let message):
            warningIcon.isHidden = false
            warningIcon.contentTintColor = .systemOrange
            statusLabel.stringValue = message
            statusLabel.textColor = .systemOrange
            statusLabel.setAccessibilityIdentifier("memory-table-error")
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        invalidateIntrinsicContentSize()
    }
}

private struct NativeMemoryTable: NSViewRepresentable {
    let rows: [MemoryWordTableRow]

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

private struct MemoryNativeAccessibilityMetadata {
    let identifier: String
    let label: String
    let value: String?
}

struct MemoryNativeAccessibilityOverrideRecord: Equatable {
    let attribute: String
    let value: String
    let succeeded: Bool
}

@MainActor
private protocol MemoryNativeTableAccessibilityProviding: AnyObject {
    func accessibilityMetadataForRow(_ row: Int) -> MemoryNativeAccessibilityMetadata?
    func accessibilityMetadataForCell(
        column: Int,
        row: Int
    ) -> MemoryNativeAccessibilityMetadata?
    func accessibilityMetadataForHeader(column: Int) -> MemoryNativeAccessibilityMetadata?
}

@MainActor
private final class MemoryNativeTableView: NSTableView {
    weak var accessibilityMetadataProvider: (any MemoryNativeTableAccessibilityProviding)?
    private(set) var accessibilityOverrideRecords:
        [String: [MemoryNativeAccessibilityOverrideRecord]] = [:]

    private var isDecoratingAccessibility = false

    @objc(accessibilityRows)
    func rawAccessibilityRows() -> NSArray? {
        guard let proxies = systemAccessibilityRows() else { return nil }
        for (row, proxy) in proxies.enumerated() {
            if let metadata = accessibilityMetadataProvider?.accessibilityMetadataForRow(row) {
                decorate(proxy, with: metadata)
            }
            guard let rowObject = proxy as? NSObject else { continue }
            for (column, cellProxy) in accessibilityObjects(
                attribute: "AXChildren",
                from: rowObject
            ).enumerated() {
                decorateCellProxy(cellProxy, column: column, row: row)
            }
        }
        return proxies
    }

    override func layout() {
        super.layout()
        decorateAccessibilityRowsAndHeaders()
    }

    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        guard let proxy = super.accessibilityCell(forColumn: column, row: row) else {
            return nil
        }
        decorateCellProxy(proxy, column: column, row: row)
        return proxy
    }

    private func decorateCellProxy(_ proxy: Any, column: Int, row: Int) {
        if let metadata = accessibilityMetadataProvider?.accessibilityMetadataForCell(
            column: column,
            row: row
        ) {
            decorate(proxy, with: metadata)
        }
    }

    private func decorateAccessibilityRowsAndHeaders() {
        guard !isDecoratingAccessibility else { return }
        isDecoratingAccessibility = true
        defer { isDecoratingAccessibility = false }

        _ = rawAccessibilityRows()

        guard let headerView else { return }
        for (column, proxy) in accessibilityObjects(
            attribute: "AXChildren",
            from: headerView
        ).enumerated() {
            if let metadata = accessibilityMetadataProvider?.accessibilityMetadataForHeader(
                column: column
            ) {
                decorate(proxy, with: metadata)
            }
        }
    }

    private func decorate(_ proxy: Any, with metadata: MemoryNativeAccessibilityMetadata) {
        guard let object = proxy as? NSObject else { return }
        var records = [
            overrideAccessibilityAttribute("AXIdentifier", to: metadata.identifier, on: object),
            overrideAccessibilityAttribute("AXDescription", to: metadata.label, on: object)
        ]
        if let value = metadata.value {
            records.append(overrideAccessibilityAttribute("AXValue", to: value, on: object))
        }
        accessibilityOverrideRecords[metadata.identifier] = records
    }

    private func overrideAccessibilityAttribute(
        _ attribute: String,
        to value: String,
        on object: NSObject
    ) -> MemoryNativeAccessibilityOverrideRecord {
        let selector = NSSelectorFromString("accessibilitySetOverrideValue:forAttribute:")
        guard object.responds(to: selector), let implementation = object.method(for: selector) else {
            return MemoryNativeAccessibilityOverrideRecord(
                attribute: attribute,
                value: value,
                succeeded: false
            )
        }
        typealias OverrideMethod = @convention(c) (
            AnyObject,
            Selector,
            AnyObject?,
            AnyObject
        ) -> Bool
        let method = unsafeBitCast(implementation, to: OverrideMethod.self)
        let didOverride = method(object, selector, value as NSString, attribute as NSString)
        // AppKit exposes override values to external AX clients. Its in-process
        // legacy getter continues to report the proxy's original value.
        return MemoryNativeAccessibilityOverrideRecord(
            attribute: attribute,
            value: value,
            succeeded: didOverride
        )
    }

    private func systemAccessibilityRows() -> NSArray? {
        let selector = NSSelectorFromString("accessibilityRows")
        guard
            let superclass = class_getSuperclass(MemoryNativeTableView.self),
            let method = class_getInstanceMethod(superclass, selector)
        else {
            return nil
        }
        typealias RowsMethod = @convention(c) (
            AnyObject,
            Selector
        ) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let rowsMethod = unsafeBitCast(implementation, to: RowsMethod.self)
        return rowsMethod(self, selector)?.takeUnretainedValue() as? NSArray
    }

    private func accessibilityObjects(attribute: String, from object: NSObject) -> [Any] {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard
            object.responds(to: selector),
            let rawValue = object.perform(selector, with: attribute)?.takeUnretainedValue(),
            let array = rawValue as? NSArray
        else {
            return []
        }
        return array.map { $0 }
    }

    func resetAccessibilityOverrideRecords() {
        accessibilityOverrideRecords.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class MemoryNativeTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    MemoryNativeTableAccessibilityProviding {
    private enum Column: Equatable {
        case address
        case word(Int)
        case ascii

        var title: String {
            switch self {
            case .address:
                return "Address"
            case .word(let index):
                return String(index * 4, radix: 16, uppercase: true)
            case .ascii:
                return "ASCII"
            }
        }

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .address:
                return NSUserInterfaceItemIdentifier("memory-address-column")
            case .word(let index):
                return NSUserInterfaceItemIdentifier("memory-word-column-\(index)")
            case .ascii:
                return NSUserInterfaceItemIdentifier("memory-ascii-column")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .address:
                return "memory-table-header-address"
            case .word(let index):
                return "memory-table-header-word-\(index)"
            case .ascii:
                return "memory-table-header-ascii"
            }
        }

        var width: CGFloat {
            switch self {
            case .address:
                return 112
            case .word:
                return 112
            case .ascii:
                return 152
            }
        }
    }

    let scrollView = NSScrollView()
    let tableView: NSTableView
    private(set) var reloadCount = 0
    var accessibilityOverrideRecords: [String: [MemoryNativeAccessibilityOverrideRecord]] {
        (tableView as? MemoryNativeTableView)?.accessibilityOverrideRecords ?? [:]
    }

    private var rows: [MemoryWordTableRow] = []
    private let columns: [Column] = [
        .address
    ] + (0..<MemoryWindowLayout.wordsPerRow).map {
        .word($0)
    } + [
        .ascii
    ]

    override init() {
        let nativeTableView = MemoryNativeTableView()
        tableView = nativeTableView
        super.init()
        nativeTableView.accessibilityMetadataProvider = self
        configureTable()
        configureScrollView()
    }

    func update(rows: [MemoryWordTableRow]) {
        guard rows != self.rows else { return }
        self.rows = rows
        (tableView as? MemoryNativeTableView)?.resetAccessibilityOverrideRecords()
        reloadCount += 1
        tableView.reloadData()
        tableView.needsLayout = true
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

        let presentation = cellPresentation(for: column, row: rows[row])
        cell.update(
            text: presentation.text,
            accessibilityIdentifier: cellAccessibilityIdentifier(for: column, row: row),
            accessibilityLabel: column.title,
            accessibilityValue: presentation.accessibilityValue
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

    private func cellPresentation(
        for column: Column,
        row: MemoryWordTableRow
    ) -> (text: String, accessibilityValue: String) {
        switch column {
        case .address:
            return (row.addressText, row.addressText)
        case .word(let index):
            let text = row.wordTexts[index]
            return (
                text.isEmpty ? " " : text,
                row.wordAccessibilityValues[index]
            )
        case .ascii:
            return (row.asciiText, row.asciiText)
        }
    }

    private func cellAccessibilityIdentifier(for column: Column, row: Int) -> String {
        let prefix = "memory-table-row-\(row)"
        switch column {
        case .address:
            return "\(prefix)-address"
        case .word(let index):
            return "\(prefix)-word-\(index)"
        case .ascii:
            return "\(prefix)-ascii"
        }
    }

    fileprivate func accessibilityMetadataForRow(
        _ row: Int
    ) -> MemoryNativeAccessibilityMetadata? {
        guard rows.indices.contains(row) else { return nil }
        return MemoryNativeAccessibilityMetadata(
            identifier: "memory-table-row-\(row)",
            label: "内存行",
            value: nil
        )
    }

    fileprivate func accessibilityMetadataForCell(
        column: Int,
        row: Int
    ) -> MemoryNativeAccessibilityMetadata? {
        guard columns.indices.contains(column), rows.indices.contains(row) else {
            return nil
        }
        let tableColumn = columns[column]
        let presentation = cellPresentation(for: tableColumn, row: rows[row])
        return MemoryNativeAccessibilityMetadata(
            identifier: cellAccessibilityIdentifier(for: tableColumn, row: row),
            label: tableColumn.title,
            value: presentation.accessibilityValue
        )
    }

    fileprivate func accessibilityMetadataForHeader(
        column: Int
    ) -> MemoryNativeAccessibilityMetadata? {
        guard columns.indices.contains(column) else { return nil }
        let tableColumn = columns[column]
        return MemoryNativeAccessibilityMetadata(
            identifier: tableColumn.accessibilityIdentifier,
            label: tableColumn.title,
            value: nil
        )
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
