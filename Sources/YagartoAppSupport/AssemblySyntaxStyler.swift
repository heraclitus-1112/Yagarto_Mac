// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@MainActor
public enum AssemblySyntaxStyler {
    private struct AttributeChange {
        var range: NSRange
        let color: NSColor
    }

    private static let maximumChunkLength = 32 * 1_024
    private static let maximumChangesPerTransaction = 128

    @discardableResult
    static func apply(
        spans: [AssemblySyntaxSpan],
        for snapshot: String,
        to textView: NSTextView,
        priorityRanges: [NSRange] = [],
        shouldContinue: @escaping @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Bool {
        let plan = AssemblySyntaxStylePlanner.make(
            spans: spans,
            utf16Length: (snapshot as NSString).length
        )
        return await apply(
            plan: plan,
            for: snapshot,
            to: textView,
            priorityRanges: priorityRanges,
            shouldContinue: shouldContinue
        )
    }

    @discardableResult
    static func apply(
        plan: AssemblySyntaxStylePlan,
        for snapshot: String,
        to textView: NSTextView,
        priorityRanges: [NSRange] = [],
        shouldContinue: @escaping @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Bool {
        guard shouldContinue(),
              !textView.hasMarkedText(),
              let storage = textView.textStorage,
              storage.string == snapshot else { return false }
        let length = plan.utf16Length
        guard length == storage.length else { return false }
        guard length > 0 else { return true }
        let runs = plan.runs
        let segments = orderedSegments(length: length, priorityRanges: priorityRanges)

        for segment in segments {
            var location = segment.location
            let segmentEnd = NSMaxRange(segment)
            while location < segmentEnd {
                guard shouldContinue(),
                      !textView.hasMarkedText(),
                      storage.length == length else { return false }
                let chunk = NSRange(
                    location: location,
                    length: min(maximumChunkLength, segmentEnd - location)
                )
                var runIndex = firstRunIndex(overlapping: chunk, in: runs)
                let runEnd = firstRunIndex(atOrAfter: NSMaxRange(chunk), in: runs)
                while runIndex < runEnd {
                    guard shouldContinue(),
                          !textView.hasMarkedText(),
                          storage.length == length else { return false }
                    let batchEnd = min(runIndex + maximumChangesPerTransaction, runEnd)
                    let changes = attributeChanges(
                        in: chunk,
                        runs: runs,
                        runRange: runIndex..<batchEnd,
                        storage: storage
                    )
                    var changeIndex = 0
                    while changeIndex < changes.count {
                        guard shouldContinue(),
                              !textView.hasMarkedText(),
                              storage.length == length else { return false }
                        let end = min(changeIndex + maximumChangesPerTransaction, changes.count)
                        commit(Array(changes[changeIndex..<end]), to: textView, storage: storage)
                        changeIndex = end
                        await Task.yield()
                    }
                    if changes.isEmpty { await Task.yield() }
                    runIndex = batchEnd
                }
                location = NSMaxRange(chunk)
            }
        }
        return shouldContinue() && !textView.hasMarkedText() && storage.length == length
    }

    private static func orderedSegments(length: Int, priorityRanges: [NSRange]) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: length)
        let priorities = priorityRanges
            .map { NSIntersectionRange($0, fullRange) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
            .reduce(into: [NSRange]()) { result, range in
                if let last = result.last, range.location <= NSMaxRange(last) {
                    result[result.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
                } else {
                    result.append(range)
                }
            }
        guard !priorities.isEmpty else { return [fullRange] }
        var remainder: [NSRange] = []
        var cursor = 0
        for priority in priorities {
            if cursor < priority.location {
                remainder.append(NSRange(location: cursor, length: priority.location - cursor))
            }
            cursor = NSMaxRange(priority)
        }
        if cursor < length {
            remainder.append(NSRange(location: cursor, length: length - cursor))
        }
        return priorities + remainder
    }

    private static func attributeChanges(
        in chunk: NSRange,
        runs: [AssemblySyntaxStyleRun],
        runRange: Range<Int>,
        storage: NSTextStorage
    ) -> [AttributeChange] {
        var result: [AttributeChange] = []
        var index = runRange.lowerBound
        while index < runRange.upperBound, runs[index].range.location < NSMaxRange(chunk) {
            let run = runs[index]
            let desiredRange = NSIntersectionRange(run.range, chunk)
            let desiredColor = color(for: run.kind)
            var location = desiredRange.location
            while location < NSMaxRange(desiredRange) {
                var effectiveRange = NSRange()
                let existing = storage.attribute(
                    .foregroundColor,
                    at: location,
                    longestEffectiveRange: &effectiveRange,
                    in: desiredRange
                ) as? NSColor
                let boundedRange = NSIntersectionRange(effectiveRange, desiredRange)
                guard boundedRange.length > 0 else { break }
                if existing?.isEqual(desiredColor) != true {
                    append(AttributeChange(range: boundedRange, color: desiredColor), to: &result)
                }
                location = NSMaxRange(boundedRange)
            }
            index += 1
        }
        return result
    }

    private static func append(_ change: AttributeChange, to changes: inout [AttributeChange]) {
        if let last = changes.last,
           last.color.isEqual(change.color),
           NSMaxRange(last.range) == change.range.location {
            changes[changes.count - 1].range.length += change.range.length
        } else {
            changes.append(change)
        }
    }

    private static func firstRunIndex(
        overlapping range: NSRange,
        in runs: [AssemblySyntaxStyleRun]
    ) -> Int {
        var lower = 0
        var upper = runs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(runs[middle].range) <= range.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func firstRunIndex(
        atOrAfter location: Int,
        in runs: [AssemblySyntaxStyleRun]
    ) -> Int {
        var lower = 0
        var upper = runs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if runs[middle].range.location < location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func commit(
        _ changes: [AttributeChange],
        to textView: NSTextView,
        storage: NSTextStorage
    ) {
        let selectedRanges = textView.selectedRanges
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        for change in changes {
            storage.addAttribute(.foregroundColor, value: change.color, range: change.range)
        }
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        textView.selectedRanges = selectedRanges
    }

    private static func color(for kind: AssemblySyntaxKind?) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .string: return .systemBrown
        case .label: return .systemTeal
        case .directive: return .systemPurple
        case .mnemonic: return .systemBlue
        case .register: return .systemIndigo
        case .number: return .systemOrange
        case nil: return .labelColor
        }
    }
}
