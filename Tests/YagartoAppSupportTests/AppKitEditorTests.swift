// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XCTest
@testable import YagartoAppSupport

@MainActor
final class AppKitEditorTests: XCTestCase {
    func testApplyingHighlightPreservesStringSelectionAndUndoHistory() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        textView.allowsUndo = true
        textView.string = "MOV r0, #1\n"
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText("S", replacementRange: NSRange(location: 3, length: 0))
        textView.setSelectedRange(NSRange(location: 5, length: 2))
        let before = textView.string
        let selection = textView.selectedRange()
        let canUndo = try XCTUnwrap(textView.undoManager).canUndo

        AssemblySyntaxStyler.apply(to: textView)

        XCTAssertEqual(textView.string, before)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(textView.undoManager?.canUndo, canUndo)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "MOV r0, #1\n")
    }

    func testSyntaxStylingDoesNotTouchRealMarkedTextComposition() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.allowsUndo = true
        textView.string = "MOV r0, #1"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setMarkedText(
            "中文",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        let before = NSAttributedString(attributedString: try XCTUnwrap(textView.textStorage))
        let selection = textView.selectedRange()
        let canUndo = textView.undoManager?.canUndo

        AssemblySyntaxStyler.apply(to: textView)

        XCTAssertEqual(textView.attributedString(), before)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(textView.undoManager?.canUndo, canUndo)
    }

    func testHostedEditorDefersHighlightUntilRealCompositionEnds() throws {
        let editor = AssemblyEditorView(
            text: "MOV r0, #1\n",
            breakpoints: [],
            currentLine: nil,
            selectionRequest: nil,
            isEditable: true,
            onTextChange: { _ in },
            onToggleBreakpoint: { _ in }
        )
        let hosting = NSHostingView(rootView: editor.frame(width: 600, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: hosting))
        let insertion = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: insertion, length: 0))
        textView.setMarkedText(
            ".word",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        let compositionRange = textView.markedRange()
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertTrue(textView.hasMarkedText())
        let whileMarked = textView.textStorage?.attribute(
            .foregroundColor,
            at: compositionRange.location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertNotEqual(whileMarked, NSColor.systemPurple)

        textView.unmarkText()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let afterComposition = textView.textStorage?.attribute(
            .foregroundColor,
            at: insertion,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(afterComposition, NSColor.systemPurple)
    }

    func testLineEditTransformFeedsOneBasedBreakpointStrategy() {
        let insertion = LineEditTransform.between(
            oldText: "a\nb\nc\n",
            newText: "a\nx\ny\nb\nc\n"
        )
        let deletion = LineEditTransform.between(
            oldText: "a\nb\nc\nd\n",
            newText: "a\nd\n"
        )

        XCTAssertEqual(insertion, LineEditTransform(startLine: 2, oldLineCount: 0, newLineCount: 2))
        XCTAssertEqual(deletion, LineEditTransform(startLine: 2, oldLineCount: 2, newLineCount: 0))
        XCTAssertEqual(
            BreakpointLines([2, 4]).applying(insertion).lines,
            [4, 6]
        )
    }

    func testEditorAccessibilityDescribesBreakpointsAndCurrentLineWithoutColor() {
        XCTAssertEqual(
            EditorAccessibility.gutterValue(breakpoints: [2, 8], currentLine: 8),
            "断点：第 2、8 行；当前执行：第 8 行"
        )
        XCTAssertEqual(EditorAccessibility.lineValue(line: 8, isBreakpoint: true, isCurrent: true), "第 8 行，断点，当前执行")
    }

    func testHostedEditorKeepsInitialTextWithoutReportingUserEdit() throws {
        var reportedChanges: [String] = []
        let editor = AssemblyEditorView(
            text: "MOV r0, #1\nMOV r1, #2\n",
            breakpoints: [],
            currentLine: nil,
            selectionRequest: nil,
            isEditable: true,
            onTextChange: { reportedChanges.append($0) },
            onToggleBreakpoint: { _ in }
        )
        let hosting = NSHostingView(rootView: editor.frame(width: 600, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let textView = try XCTUnwrap(findTextView(in: hosting))
        XCTAssertEqual(textView.string, "MOV r0, #1\nMOV r1, #2\n")
        XCTAssertTrue(reportedChanges.isEmpty)
        XCTAssertGreaterThan(textView.frame.width, 500)
        XCTAssertGreaterThan(textView.frame.height, 250)
        let glyphRange = try XCTUnwrap(textView.layoutManager).glyphRange(for: try XCTUnwrap(textView.textContainer))
        let glyphBounds = textView.layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer!)
        XCTAssertGreaterThan(glyphBounds?.height ?? 0, 0)
        let color = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertGreaterThan(color.alphaComponent, 0.9)
        XCTAssertNotEqual(color, NSColor.textBackgroundColor)
        XCTAssertNotNil(textView.textColor)

        let hierarchyBitmap = try cacheOffscreen(hosting)
        XCTAssertGreaterThan(
            darkPixelCount(in: hierarchyBitmap, rect: NSRect(x: 60, y: 0, width: 300, height: 300)),
            20,
            "完整 SwiftUI/AppKit 层级必须在行号栏右侧画出源码字形，不能被裁切或遮挡"
        )
    }

    func testOfficialScrollableTextViewRendersSourceGlyphPixelsOffscreen() throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.string = "MOV r0, #1\nMOV r1, #2\n"
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .white
        textView.drawsBackground = true
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()

        let bitmap = try renderOffscreen(textView)

        XCTAssertGreaterThan(
            darkPixelCount(in: bitmap, rect: NSRect(x: 0, y: 0, width: 240, height: 80)),
            20,
            "官方 scrollableTextView 对照必须能在源码区域画出字形像素"
        )

        let hierarchyBitmap = try cacheOffscreen(scrollView)
        XCTAssertGreaterThan(
            darkPixelCount(in: hierarchyBitmap, rect: NSRect(x: 0, y: 0, width: 300, height: 300)),
            20,
            "官方 scrollableTextView 层级必须能缓存出源码字形像素"
        )
    }

    func testHostedAssemblyEditorRendersSourceGlyphPixelsOffscreen() throws {
        let editor = AssemblyEditorView(
            text: "MOV r0, #1\nMOV r1, #2\n",
            breakpoints: [],
            currentLine: nil,
            selectionRequest: nil,
            isEditable: true,
            onTextChange: { _ in },
            onToggleBreakpoint: { _ in }
        )
        let hosting = NSHostingView(rootView: editor.frame(width: 600, height: 300))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: hosting))

        let bitmap = try renderOffscreen(textView)

        XCTAssertGreaterThan(
            darkPixelCount(in: bitmap, rect: NSRect(x: 0, y: 0, width: 240, height: 80)),
            20,
            "AssemblyEditorView 必须在源码区域实际画出字形，不能只有 textStorage/glyph 元数据"
        )

    }

    func testCurrentManualScrollConfigurationRendersSourceGlyphPixels() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        let textView = AssemblyNSTextView()
        textView.string = "MOV r0, #1\nMOV r1, #2\n"
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        let ruler = AssemblyLineRulerView(textView: textView)
        ruler.source = textView.string
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.layoutSubtreeIfNeeded()

        let bitmap = try cacheOffscreen(scrollView)

        XCTAssertGreaterThan(
            darkPixelCount(in: bitmap, rect: NSRect(x: 60, y: 0, width: 300, height: 300)),
            20,
            "当前手工 NSScrollView 配置必须在行号栏右侧实际画出源码字形"
        )
    }

    func testHostedEditorRendersGlyphPixelsAfterScrollingToObservedClipOffset() throws {
        let source = (1...30).map { "MOV r0, #\($0)" }.joined(separator: "\n")
        let editor = AssemblyEditorView(
            text: source,
            breakpoints: [],
            currentLine: nil,
            selectionRequest: nil,
            isEditable: true,
            onTextChange: { _ in },
            onToggleBreakpoint: { _ in }
        )
        let hosting = NSHostingView(rootView: editor.frame(width: 600, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let textView = try XCTUnwrap(findTextView(in: hosting))
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        scrollView.contentView.scroll(to: NSPoint(x: -54, y: 98))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        let bitmap = try cacheOffscreen(hosting)

        XCTAssertGreaterThan(
            darkPixelCount(in: bitmap, rect: NSRect(x: 60, y: 0, width: 300, height: 300)),
            20,
            "滚动到真实窗口观察到的 clip offset 后仍必须画出源码字形"
        )
    }
}

@MainActor
private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for child in view.subviews {
        if let found = findTextView(in: child) { return found }
    }
    return nil
}

@MainActor
private func renderOffscreen(_ view: NSView) throws -> NSBitmapImageRep {
    let width = max(1, Int(ceil(view.bounds.width)))
    let height = max(1, Int(ceil(view.bounds.height)))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    view.bounds.fill()
    view.displayIgnoringOpacity(view.bounds, in: context)
    context.flushGraphics()
    return bitmap
}

@MainActor
private func cacheOffscreen(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

private func darkPixelCount(in bitmap: NSBitmapImageRep, rect: NSRect) -> Int {
    let minX = max(0, Int(rect.minX))
    let maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX)))
    let minY = max(0, Int(rect.minY))
    let maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY)))
    var count = 0
    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent < 0.65,
               color.greenComponent < 0.65,
               color.blueComponent < 0.65,
               color.alphaComponent > 0.5 {
                count += 1
            }
        }
    }
    return count
}
