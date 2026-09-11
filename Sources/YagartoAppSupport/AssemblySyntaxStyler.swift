// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
public enum AssemblySyntaxStyler {
    public static func apply(to textView: NSTextView) {
        guard !textView.hasMarkedText() else { return }
        guard let storage = textView.textStorage else { return }
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
        for span in AssemblySyntaxScanner.spans(in: storage.string) {
            storage.addAttribute(.foregroundColor, value: color(for: span.kind), range: span.range)
        }
        storage.endEditing()
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
