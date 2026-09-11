// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
public enum AssemblySyntaxStyler {
    @discardableResult
    static func apply(
        spans: [AssemblySyntaxSpan],
        for snapshot: String,
        to textView: NSTextView
    ) -> Bool {
        guard !textView.hasMarkedText(),
              let storage = textView.textStorage,
              storage.string == snapshot else { return false }
        let selectedRanges = textView.selectedRanges
        let fullRange = NSRange(location: 0, length: storage.length)
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            undoManager?.enableUndoRegistration()
            textView.selectedRanges = selectedRanges
        }

        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        for span in spans {
            storage.addAttribute(.foregroundColor, value: color(for: span.kind), range: span.range)
        }
        storage.endEditing()
        return true
    }

    private static func color(for kind: AssemblySyntaxKind) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .string: return .systemBrown
        case .label: return .systemTeal
        case .directive: return .systemPurple
        case .mnemonic: return .systemBlue
        case .register: return .systemIndigo
        case .number: return .systemOrange
        }
    }
}
