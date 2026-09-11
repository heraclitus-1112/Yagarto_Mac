// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct SourceLineMap: Equatable, Sendable {
    private let utf16Length: Int
    private let lineStarts: [Int]
    private let lineContentEnds: [Int]

    public init(_ source: String) {
        let nsSource = source as NSString
        utf16Length = nsSource.length
        var starts = [0]
        var ends: [Int] = []
        var cursor = 0
        while cursor < nsSource.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsSource.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            ends.append(contentsEnd)
            cursor = lineEnd
            if cursor < nsSource.length { starts.append(cursor) }
        }
        if nsSource.length == 0 {
            ends = [0]
        } else if source.hasSuffix("\n") || source.hasSuffix("\r") {
            starts.append(nsSource.length)
            ends.append(nsSource.length)
        }
        lineStarts = starts
        lineContentEnds = ends
    }

    public var lineCount: Int { lineStarts.count }

    public func lineNumber(atUTF16Offset offset: Int) -> Int {
        let clamped = min(max(0, offset), utf16Length)
        let index = lineStarts.partitioningIndex { $0 > clamped }
        return max(1, index)
    }

    public func range(forLine line: Int) -> NSRange? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let index = line - 1
        return NSRange(
            location: lineStarts[index],
            length: max(0, lineContentEnds[index] - lineStarts[index])
        )
    }
}

public enum AssemblySyntaxKind: String, CaseIterable, Sendable {
    case comment
    case string
    case label
    case directive
    case mnemonic
    case register
    case number
}

public struct AssemblySyntaxSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: AssemblySyntaxKind

    public init(range: NSRange, kind: AssemblySyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

public enum AssemblySyntaxScanner {
    private static let patterns: [(AssemblySyntaxKind, String, NSRegularExpression.Options)] = [
        (.comment, #"//[^\r\n]*|;[^\r\n]*|@[^\r\n]*"#, []),
        (.string, #"\"(?:\\.|[^\"\\])*\""#, []),
        (.label, #"(?m)^[ \t]*[A-Za-z_.$][A-Za-z0-9_.$]*:"#, []),
        (.directive, #"\.[A-Za-z][A-Za-z0-9_]*"#, [.caseInsensitive]),
        (.mnemonic, #"\b(?:adc|add|and|asr|b|bic|bl|bx|cmp|eor|ldr|ldm|lsl|lsr|mov|mvn|orr|pop|push|ror|rrx|rsb|rsc|sbc|stm|str|sub|teq|tst)(?:eq|ne|cs|hs|cc|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?s?\b"#, [.caseInsensitive]),
        (.register, #"\b(?:r(?:1[0-5]|[0-9])|sp|lr|pc|cpsr|xpsr|msp|psp|control|primask)\b"#, [.caseInsensitive]),
        (.number, #"\b(?:0x[0-9a-f]+|0b[01]+|[0-9]+)\b"#, [.caseInsensitive])
    ]

    public static func spans(in source: String) -> [AssemblySyntaxSpan] {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        var accepted: [AssemblySyntaxSpan] = []
        for (kind, pattern, options) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                continue
            }
            for match in expression.matches(in: source, range: fullRange) {
                var range = match.range
                if kind == .label {
                    let matched = (source as NSString).substring(with: range)
                    let leading = matched.prefix { $0 == " " || $0 == "\t" }.utf16.count
                    range = NSRange(location: range.location + leading, length: range.length - leading)
                }
                guard !accepted.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else {
                    continue
                }
                accepted.append(AssemblySyntaxSpan(range: range, kind: kind))
            }
        }
        return accepted.sorted {
            if $0.range.location == $1.range.location { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
    }
}

public struct BreakpointLines: Equatable, Sendable {
    public let lines: Set<Int>

    public init(_ lines: Set<Int> = []) {
        self.lines = Set(lines.filter { $0 > 0 })
    }

    public init(_ lines: [Int]) {
        self.init(Set(lines))
    }

    public func toggling(_ line: Int) -> BreakpointLines {
        guard line > 0 else { return self }
        var updated = lines
        if updated.contains(line) { updated.remove(line) } else { updated.insert(line) }
        return BreakpointLines(updated)
    }

    public func applyingEdit(
        startLine: Int,
        oldLineCount: Int,
        newLineCount: Int
    ) -> BreakpointLines {
        guard startLine > 0, oldLineCount >= 0, newLineCount >= 0 else { return self }
        let delta = newLineCount - oldLineCount
        let oldEnd = startLine + max(0, oldLineCount - 1)
        var transformed = Set<Int>()
        for line in lines {
            if oldLineCount == 0 {
                transformed.insert(line >= startLine ? line + delta : line)
            } else if line < startLine {
                transformed.insert(line)
            } else if line <= oldEnd {
                if newLineCount > 0 { transformed.insert(startLine) }
            } else {
                transformed.insert(line + delta)
            }
        }
        return BreakpointLines(transformed)
    }

    public func applying(_ transform: LineEditTransform) -> BreakpointLines {
        applyingEdit(
            startLine: transform.startLine,
            oldLineCount: transform.oldLineCount,
            newLineCount: transform.newLineCount
        )
    }
}

public struct LineEditTransform: Equatable, Sendable {
    public let startLine: Int
    public let oldLineCount: Int
    public let newLineCount: Int

    public init(startLine: Int, oldLineCount: Int, newLineCount: Int) {
        self.startLine = startLine
        self.oldLineCount = oldLineCount
        self.newLineCount = newLineCount
    }

    public static func between(oldText: String, newText: String) -> LineEditTransform {
        let oldLines = oldText.components(separatedBy: .newlines)
        let newLines = newText.components(separatedBy: .newlines)
        var prefix = 0
        while prefix < oldLines.count,
              prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1] {
            suffix += 1
        }
        return LineEditTransform(
            startLine: prefix + 1,
            oldLineCount: oldLines.count - prefix - suffix,
            newLineCount: newLines.count - prefix - suffix
        )
    }
}

public enum SourceLocationMatcher {
    public static func matches(
        debuggerFile: String?,
        documentURL: URL,
        projectDirectory: URL
    ) -> Bool {
        guard let debuggerFile, !debuggerFile.isEmpty else { return false }
        let candidate: URL
        if NSString(string: debuggerFile).isAbsolutePath {
            candidate = URL(fileURLWithPath: debuggerFile)
        } else {
            candidate = projectDirectory.appendingPathComponent(debuggerFile)
        }
        return candidate.standardizedFileURL.resolvingSymlinksInPath()
            == documentURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public enum GutterLineMapper {
    public static func line(
        atY y: Double,
        lineHeight: Double,
        verticalScrollOffset: Double,
        topInset: Double = 0
    ) -> Int? {
        guard lineHeight > 0 else { return nil }
        let contentY = y + verticalScrollOffset - topInset
        guard contentY >= 0 else { return nil }
        return Int(contentY / lineHeight) + 1
    }
}

public enum EditorAccessibility {
    public static func gutterValue(breakpoints: Set<Int>, currentLine: Int?) -> String {
        var parts: [String] = []
        if !breakpoints.isEmpty {
            let lines = breakpoints.sorted().map(String.init).joined(separator: "、")
            parts.append("断点：第 \(lines) 行")
        } else {
            parts.append("无断点")
        }
        if let currentLine { parts.append("当前执行：第 \(currentLine) 行") }
        return parts.joined(separator: "；")
    }

    public static func lineValue(line: Int, isBreakpoint: Bool, isCurrent: Bool) -> String {
        var parts = ["第 \(line) 行"]
        if isBreakpoint { parts.append("断点") }
        if isCurrent { parts.append("当前执行") }
        return parts.joined(separator: "，")
    }
}

private extension Array where Element == Int {
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
