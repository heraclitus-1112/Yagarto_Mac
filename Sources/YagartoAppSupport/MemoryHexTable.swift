// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import YagartoCore

public struct MemoryHexTable: View {
    private enum State {
        case empty
        case rows([MemoryTableRow])
        case error(String)
    }

    private let state: State

    public init(blocks: [MIMemoryBlock]) {
        if blocks.isEmpty {
            state = .empty
            return
        }

        do {
            state = .rows(try MemoryTableFormatter.rows(from: blocks))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    public var body: some View {
        visualContent
            .accessibilityHidden(true)
            .overlay {
                AccessibilityLayer(state: state)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private var visualContent: some View {
        Group {
            switch state {
            case .empty:
                Text("输入地址和长度，然后在程序暂停时读取内存。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory-table-empty")
            case .rows(let rows):
                table(rows: rows)
            case .error(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("memory-table-error")
            }
        }
    }

    private func table(rows: [MemoryTableRow]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("地址")
                        .accessibilityIdentifier("memory-table-header-address")
                    ForEach(0..<16, id: \.self) { column in
                        Text("+\(String(column, radix: 16, uppercase: true))")
                            .accessibilityIdentifier("memory-table-header-byte-\(column)")
                    }
                    Text("ASCII")
                        .accessibilityIdentifier("memory-table-header-ascii")
                }
                .accessibilityElement(children: .contain)

                Divider()
                    .gridCellColumns(18)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        Text(row.addressText)
                        ForEach(Array(row.byteTexts.enumerated()), id: \.offset) { _, byteText in
                            Text(byteText.isEmpty ? " " : byteText)
                        }
                        Text(row.asciiText)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memory-table-row-\(index)")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
    }

    private struct AccessibilityLayer: NSViewRepresentable {
        let state: State

        // Selectable SwiftUI Text becomes SelectionTextField on macOS and drops
        // per-Text identifiers, so expose one stable, non-duplicated AX tree.
        func makeNSView(context: Context) -> AccessibilityTreeView {
            AccessibilityTreeView()
        }

        func updateNSView(_ view: AccessibilityTreeView, context: Context) {
            view.update(state: state)
        }
    }

    private final class AccessibilityTreeView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityIdentifier("memory-table")
            setAccessibilityLabel("内存十六进制表格")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(state: State) {
            let children: [NSAccessibilityElement]
            switch state {
            case .empty:
                children = [element(
                    identifier: "memory-table-empty",
                    label: "输入地址和长度，然后在程序暂停时读取内存。",
                    parent: self
                )]
            case .error(let message):
                children = [element(
                    identifier: "memory-table-error",
                    label: "警告：\(message)",
                    parent: self
                )]
            case .rows(let rows):
                children = headerElements() + rows.enumerated().map { index, row in
                    rowElement(row, index: index)
                }
            }
            setAccessibilityChildren(children)
        }

        private func headerElements() -> [NSAccessibilityElement] {
            [element(
                identifier: "memory-table-header-address",
                label: "地址",
                parent: self
            )] + (0..<16).map { column in
                element(
                    identifier: "memory-table-header-byte-\(column)",
                    label: "+\(String(column, radix: 16, uppercase: true))",
                    parent: self
                )
            } + [element(
                identifier: "memory-table-header-ascii",
                label: "ASCII",
                parent: self
            )]
        }

        private func rowElement(_ row: MemoryTableRow, index: Int) -> NSAccessibilityElement {
            let rowIdentifier = "memory-table-row-\(index)"
            let rowElement = element(
                identifier: rowIdentifier,
                label: "内存行",
                role: .group,
                parent: self
            )
            let byteElements = row.byteTexts.enumerated().map { column, byteText in
                let value = byteText.isEmpty ? "空" : byteText
                return element(
                    identifier: "\(rowIdentifier)-byte-\(column)",
                    label: "+\(String(column, radix: 16, uppercase: true)) \(value)",
                    parent: rowElement
                )
            }
            rowElement.setAccessibilityChildren([
                element(
                    identifier: "\(rowIdentifier)-address",
                    label: "地址 \(row.addressText)",
                    parent: rowElement
                )
            ] + byteElements + [
                element(
                    identifier: "\(rowIdentifier)-ascii",
                    label: "ASCII \(row.asciiText)",
                    parent: rowElement
                )
            ])
            return rowElement
        }

        private func element(
            identifier: String,
            label: String,
            role: NSAccessibility.Role = .staticText,
            parent: Any
        ) -> NSAccessibilityElement {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(role)
            element.setAccessibilityIdentifier(identifier)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(parent)
            return element
        }
    }
}
