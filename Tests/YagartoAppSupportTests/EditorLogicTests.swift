// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class EditorLogicTests: XCTestCase {
    func testLineMappingUsesUTF16OffsetsAndReturnsCurrentLineRange() {
        let map = SourceLineMap("MOV r0, #1\n标签: .word 2\n")

        XCTAssertEqual(map.lineNumber(atUTF16Offset: 0), 1)
        XCTAssertEqual(map.lineNumber(atUTF16Offset: 12), 2)
        XCTAssertEqual(map.range(forLine: 2), NSRange(location: 11, length: 11))
        XCTAssertNil(map.range(forLine: 4))
    }

    func testSyntaxScannerClassifiesAssemblerTokensWithoutOverlap() {
        let source = "start: MOV r0, #0x2A // note\n.word \"hi\"\n"
        let spans = AssemblySyntaxScanner.spans(in: source)

        XCTAssertTrue(spans.contains { $0.kind == .label && substring(source, $0.range) == "start:" })
        XCTAssertTrue(spans.contains { $0.kind == .mnemonic && substring(source, $0.range) == "MOV" })
        XCTAssertTrue(spans.contains { $0.kind == .register && substring(source, $0.range) == "r0" })
        XCTAssertTrue(spans.contains { $0.kind == .number && substring(source, $0.range) == "0x2A" })
        XCTAssertTrue(spans.contains { $0.kind == .comment && substring(source, $0.range) == "// note" })
        XCTAssertTrue(spans.contains { $0.kind == .directive && substring(source, $0.range) == ".word" })
        XCTAssertTrue(spans.contains { $0.kind == .string && substring(source, $0.range) == "\"hi\"" })
        for pair in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(pair.0.range), pair.1.range.location)
        }
    }

    func testBreakpointLinesShiftAndCollapseAcrossEdits() {
        let breakpoints = BreakpointLines([2, 4, 8])

        XCTAssertEqual(
            breakpoints.applyingEdit(startLine: 3, oldLineCount: 0, newLineCount: 2).lines,
            [2, 6, 10]
        )
        XCTAssertEqual(
            breakpoints.applyingEdit(startLine: 3, oldLineCount: 4, newLineCount: 1).lines,
            [2, 3, 5]
        )
        XCTAssertEqual(breakpoints.toggling(4).lines, [2, 8])
        XCTAssertEqual(breakpoints.toggling(6).lines, [2, 4, 6, 8])
    }

    func testCanonicalFileMatchingAndGutterLineMapping() throws {
        let fixture = try AppTemporaryDirectoryForEditor()
        let source = fixture.url.appendingPathComponent("main.s")
        try Data().write(to: source)

        XCTAssertTrue(SourceLocationMatcher.matches(
            debuggerFile: "./main.s",
            documentURL: source,
            projectDirectory: fixture.url
        ))
        XCTAssertFalse(SourceLocationMatcher.matches(
            debuggerFile: "other.s",
            documentURL: source,
            projectDirectory: fixture.url
        ))
        XCTAssertEqual(GutterLineMapper.line(atY: 30, lineHeight: 20, verticalScrollOffset: 10), 3)
        XCTAssertNil(GutterLineMapper.line(atY: -30, lineHeight: 20, verticalScrollOffset: 0))
    }

    private func substring(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }
}

private struct AppTemporaryDirectoryForEditor {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
