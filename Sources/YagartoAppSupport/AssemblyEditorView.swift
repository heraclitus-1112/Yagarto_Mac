// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

public struct AssemblyEditorView: NSViewRepresentable {
    private let text: String
    private let breakpoints: Set<Int>
    private let currentLine: Int?
    private let selectionRequest: NSRange?
    private let isEditable: Bool
    private let onTextChange: @MainActor (String) -> Void
    private let onToggleBreakpoint: @MainActor (Int) -> Void

    public init(
        text: String,
        breakpoints: Set<Int>,
        currentLine: Int?,
        selectionRequest: NSRange?,
        isEditable: Bool,
        onTextChange: @escaping @MainActor (String) -> Void,
        onToggleBreakpoint: @escaping @MainActor (Int) -> Void
    ) {
        self.text = text
        self.breakpoints = breakpoints
        self.currentLine = currentLine
        self.selectionRequest = selectionRequest
        self.isEditable = isEditable
        self.onTextChange = onTextChange
        self.onToggleBreakpoint = onToggleBreakpoint
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = AssemblyNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("source-editor")
        textView.setAccessibilityLabel("ARM 汇编源码编辑器")
        textView.setAccessibilityHelp("编辑 .s 或 .S 源码；按 Command 反斜杠切换当前行断点。")
        textView.onToggleCurrentBreakpoint = { [weak textView] in
            guard let textView else { return }
            let line = SourceLineMap(textView.string)
                .lineNumber(atUTF16Offset: textView.selectedRange().location)
            context.coordinator.parent.onToggleBreakpoint(line)
        }
        scrollView.documentView = textView

        let ruler = AssemblyLineRulerView(textView: textView)
        ruler.onToggleBreakpoint = { line in
            context.coordinator.parent.onToggleBreakpoint(line)
        }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.applyPresentation()
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.previousText = text
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        context.coordinator.applyPresentation()
        if let selectionRequest,
           selectionRequest.location <= (textView.string as NSString).length,
           textView.selectedRange() != selectionRequest {
            textView.setSelectedRange(selectionRequest)
            textView.scrollRangeToVisible(selectionRequest)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: AssemblyEditorView
        fileprivate weak var textView: NSTextView?
        fileprivate weak var ruler: AssemblyLineRulerView?
        fileprivate var previousText: String
        private var highlightTask: Task<Void, Never>?

        fileprivate init(parent: AssemblyEditorView) {
            self.parent = parent
            previousText = parent.text
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let updated = textView.string
            previousText = updated
            parent.onTextChange(updated)
            ruler?.source = updated
            ruler?.needsDisplay = true
            scheduleHighlight()
        }

        fileprivate func applyPresentation() {
            guard let textView else { return }
            highlightTask?.cancel()
            AssemblySyntaxStyler.apply(to: textView)
            applyExecutionLine(to: textView)
            ruler?.source = textView.string
            ruler?.breakpoints = parent.breakpoints
            ruler?.currentLine = parent.currentLine
            ruler?.updateAccessibility()
            ruler?.needsDisplay = true
            if let currentLine = parent.currentLine,
               let range = SourceLineMap(textView.string).range(forLine: currentLine) {
                textView.scrollRangeToVisible(range)
            }
        }

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                AssemblySyntaxStyler.apply(to: textView)
                self.applyExecutionLine(to: textView)
            }
        }

        private func applyExecutionLine(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            guard let line = parent.currentLine,
                  let range = SourceLineMap(storage.string).range(forLine: line) else {
                textView.setAccessibilityHelp("编辑 .s 或 .S 源码；按 Command 反斜杠切换当前行断点。当前未停在此文件。")
                return
            }
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16),
                range: range
            )
            textView.setAccessibilityHelp(
                "编辑 .s 或 .S 源码；按 Command 反斜杠切换当前行断点。当前执行第 \(line) 行。"
            )
        }
    }
}

@MainActor
final class AssemblyNSTextView: NSTextView {
    var onToggleCurrentBreakpoint: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\\" {
            onToggleCurrentBreakpoint?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AssemblyLineRulerView: NSRulerView {
    weak var textView: NSTextView?
    var source = ""
    var breakpoints: Set<Int> = []
    var currentLine: Int?
    var onToggleBreakpoint: ((Int) -> Void)?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 54
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("行号与断点栏")
        setAccessibilityHelp("点击行号左侧可切换断点；三角形表示当前执行行。")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let visibleRect = rect.intersection(bounds)
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return }
        NSColor.windowBackgroundColor.setFill()
        visibleRect.fill()
        guard let textView else { return }
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? 17
        let scrollY = scrollView?.contentView.bounds.minY ?? 0
        let inset = textView.textContainerInset.height
        let map = SourceLineMap(source)
        guard lineHeight.isFinite, lineHeight > 0, scrollY.isFinite, inset.isFinite else { return }
        let firstOffset = max(0, visibleRect.minY + scrollY - inset) / lineHeight
        let lastOffset = max(0, visibleRect.maxY + scrollY - inset) / lineHeight
        let first = max(1, min(map.lineCount, Int(min(firstOffset, CGFloat(map.lineCount))) + 1))
        let last = min(map.lineCount, Int(min(lastOffset, CGFloat(map.lineCount))) + 2)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        guard first <= last else { return }
        for line in first...last {
            let y = inset + CGFloat(line - 1) * lineHeight - scrollY
            if breakpoints.contains(line) {
                ("◆" as NSString).draw(at: NSPoint(x: 4, y: y), withAttributes: attributes)
            }
            if currentLine == line {
                ("▶" as NSString).draw(at: NSPoint(x: 17, y: y), withAttributes: attributes)
            }
            let number = "\(line)" as NSString
            number.draw(
                at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 5, y: y),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? 17
        let scrollY = scrollView?.contentView.bounds.minY ?? 0
        if let line = GutterLineMapper.line(
            atY: point.y,
            lineHeight: lineHeight,
            verticalScrollOffset: scrollY,
            topInset: textView.textContainerInset.height
        ), line <= SourceLineMap(source).lineCount {
            onToggleBreakpoint?(line)
        }
    }

    func updateAccessibility() {
        setAccessibilityValue(EditorAccessibility.gutterValue(
            breakpoints: breakpoints,
            currentLine: currentLine
        ))
    }
}
