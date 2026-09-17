// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum BuildDiagnosticSeverity: String, Equatable, Sendable {
    case error
    case warning
    case note
}

public struct BuildDiagnostic: Equatable, Identifiable, Sendable {
    public let severity: BuildDiagnosticSeverity
    public let file: URL?
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(
        severity: BuildDiagnosticSeverity,
        file: URL? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String
    ) {
        self.severity = severity
        self.file = file?.standardizedFileURL
        self.line = line
        self.column = column
        self.message = message
    }

    public var id: String {
        [severity.rawValue, file?.path ?? "", line.map(String.init) ?? "", column.map(String.init) ?? "", message]
            .joined(separator: ":")
    }

    public func sourceSelection(in source: String) -> NSRange? {
        guard let line, let range = SourceLineMap(source).range(forLine: line) else { return nil }
        let columnOffset = max(0, (column ?? 1) - 1)
        return NSRange(location: min(NSMaxRange(range), range.location + columnOffset), length: 0)
    }
}

public struct BuildDiagnosticReport: Equatable, Sendable {
    public let diagnostics: [BuildDiagnostic]
    public let output: String
    public let wasTruncated: Bool

    public init(diagnostics: [BuildDiagnostic], output: String, wasTruncated: Bool) {
        self.diagnostics = diagnostics
        self.output = output
        self.wasTruncated = wasTruncated
    }
}

public enum BuildDiagnosticParser {
    public static let defaultOutputLimit = 64 * 1_024
    public static let defaultDiagnosticLimit = 200

    public static func parse(
        _ rawOutput: String,
        projectDirectory: URL,
        outputLimit: Int = defaultOutputLimit,
        diagnosticLimit: Int = defaultDiagnosticLimit
    ) -> BuildDiagnosticReport {
        let limit = max(1, outputLimit)
        let bytes = Array(rawOutput.utf8)
        let wasTruncated = bytes.count > limit
        var output = String(decoding: bytes.prefix(limit), as: UTF8.self)
        while output.utf8.count > limit, !output.isEmpty {
            output.removeLast()
        }
        let expression = try? NSRegularExpression(
            pattern: #"^(.+?):([0-9]+):(?:([0-9]+):)?[ \t]*(?:(error|warning|note):[ \t]*)?(.*)$"#,
            options: [.caseInsensitive]
        )
        var diagnostics: [BuildDiagnostic] = []
        for rawLine in output.split(whereSeparator: \Character.isNewline).map(String.init) {
            guard diagnostics.count < max(1, diagnosticLimit) else { break }
            let range = NSRange(location: 0, length: (rawLine as NSString).length)
            if let match = expression?.firstMatch(in: rawLine, range: range), match.range.location != NSNotFound {
                let path = capture(match, index: 1, in: rawLine)
                let line = capture(match, index: 2, in: rawLine).flatMap(Int.init)
                let column = capture(match, index: 3, in: rawLine).flatMap(Int.init)
                let severityText = capture(match, index: 4, in: rawLine)?.lowercased()
                let message = capture(match, index: 5, in: rawLine) ?? rawLine
                let fileURL: URL?
                if let path, !path.isEmpty, path.lowercased() != "ld" {
                    fileURL = NSString(string: path).isAbsolutePath
                        ? URL(fileURLWithPath: path)
                        : projectDirectory.appendingPathComponent(path)
                } else {
                    fileURL = nil
                }
                diagnostics.append(BuildDiagnostic(
                    severity: severity(from: severityText, message: rawLine),
                    file: fileURL,
                    line: line,
                    column: column,
                    message: message.trimmingCharacters(in: .whitespaces)
                ))
            } else if rawLine.localizedCaseInsensitiveContains("error")
                        || rawLine.localizedCaseInsensitiveContains("undefined reference") {
                diagnostics.append(BuildDiagnostic(severity: .error, message: rawLine))
            } else if rawLine.localizedCaseInsensitiveContains("warning") {
                diagnostics.append(BuildDiagnostic(severity: .warning, message: rawLine))
            }
        }
        if wasTruncated, diagnostics.count < max(1, diagnosticLimit) {
            diagnostics.append(BuildDiagnostic(
                severity: .note,
                message: "工具输出已截断，只显示前 \(limit) 字节。"
            ))
        }
        return BuildDiagnosticReport(diagnostics: diagnostics, output: output, wasTruncated: wasTruncated)
    }

    private static func capture(_ match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }

    private static func severity(from raw: String?, message: String) -> BuildDiagnosticSeverity {
        switch raw {
        case "warning": return .warning
        case "note": return .note
        case "error": return .error
        default:
            return message.localizedCaseInsensitiveContains("warning") ? .warning : .error
        }
    }
}

public enum AppCommand: String, CaseIterable, Sendable {
    case open
    case newProject
    case importProjects
    case save
    case build
    case run
    case debug
    case pause
    case stepInstruction
    case stepOver
    case `continue`
    case stop
    case changeProfile
    case edit
}

public enum AppCommandAvailability {
    public static func isEnabled(
        _ command: AppCommand,
        state: DebuggerState,
        hasDocument: Bool,
        isDirty: Bool,
        isProjectOperationInProgress: Bool = false
    ) -> Bool {
        if isProjectOperationInProgress { return false }
        switch command {
        case .open, .newProject, .importProjects:
            return state == .idle || state == .ready
        case .save:
            return hasDocument && isDirty && (state == .idle || state == .ready)
        case .build, .changeProfile, .edit:
            return hasDocument && (state == .idle || state == .ready)
        case .run, .debug:
            return hasDocument && state == .ready
        case .pause:
            return state == .running
        case .stepInstruction, .stepOver, .continue:
            return state == .stopped
        case .stop:
            return state == .launching || state == .stopped || state == .running || state == .terminating
        }
    }
}

public enum CloseAction: Equatable, Sendable {
    case allow
    case confirmUnsaved
    case stopThenClose
    case denyProjectOperation
}

public enum ClosePolicy {
    public static func action(
        isDirty: Bool,
        state: DebuggerState,
        isProjectOperationInProgress: Bool = false
    ) -> CloseAction {
        if isProjectOperationInProgress { return .denyProjectOperation }
        if isDirty { return .confirmUnsaved }
        switch state {
        case .launching, .stopped, .running, .terminating:
            return .stopThenClose
        case .idle, .building, .ready:
            return .allow
        }
    }
}

public enum ProjectProfilePreference {
    public static func selected(lastRawValue: String, current: ProfileID?) -> ProfileID {
        ProfileID(rawValue: lastRawValue) ?? current ?? .arm7tdmi
    }
}

public enum MemoryRequestValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress
    case invalidLength

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "内存地址必须是十六进制地址（例如 0x20001000）或 $sp。"
        case .invalidLength: return "内存长度必须是 1 到 4096 之间的十进制整数。"
        }
    }
}

public enum MemoryRequestValidator {
    public static func request(address: String, length: String) throws -> DebugMemoryRequest {
        guard let count = Int(length), (1...4_096).contains(count) else {
            throw MemoryRequestValidationError.invalidLength
        }
        if address == "$sp" {
            return DebugMemoryRequest(address: "$sp", byteCount: count)
        }
        let normalized = address.replacingOccurrences(of: "_", with: "")
        guard normalized.range(of: #"^0x[0-9A-Fa-f]+$"#, options: .regularExpression) != nil else {
            throw MemoryRequestValidationError.invalidAddress
        }
        return DebugMemoryRequest(address: normalized, byteCount: count)
    }
}

public struct MemoryWindowControlState: Equatable, Sendable {
    public struct Submission: Equatable, Sendable {
        public let token: UInt64
        public let normalizedAddress: String
    }

    public private(set) var editableAddressText = MemoryWindowLayout.defaultAddressText
    public private(set) var displayedBaseAddress = MemoryWindowLayout.defaultAddress
    public private(set) var confirmedBaseAddress = MemoryWindowLayout.defaultAddress
    private var displayedAddressText = MemoryWindowLayout.defaultAddressText
    private var confirmedAddressText = MemoryWindowLayout.defaultAddressText
    private var submissionGeneration: UInt64 = 0
    private var editRevision: UInt64 = 0
    private var pendingEditRevision: UInt64 = 0

    public init() {}

    public mutating func edit(_ rawAddress: String) {
        editRevision &+= 1
        editableAddressText = rawAddress
    }

    public mutating func beginSubmission(_ candidate: String) throws -> Submission {
        submissionGeneration &+= 1
        let normalized = try MemoryWindowAddress.normalized(candidate)
        return try startSubmission(normalized)
    }

    public mutating func step(byRows rowCount: Int) throws -> Submission {
        submissionGeneration &+= 1
        let normalized = try MemoryWindowAddress.stepped(displayedAddressText, byRows: rowCount)
        return try startSubmission(normalized)
    }

    public mutating func completeSuccess(token: UInt64, normalized: String) {
        guard token == submissionGeneration,
              let canonical = try? MemoryWindowAddress.normalized(normalized),
              canonical == displayedAddressText,
              let address = try? MemoryWindowAddress.value(canonical) else { return }
        submissionGeneration &+= 1
        if editRevision == pendingEditRevision {
            editableAddressText = canonical
        }
        displayedAddressText = canonical
        displayedBaseAddress = address
        confirmedAddressText = canonical
        confirmedBaseAddress = address
    }

    public mutating func completeFailure(token: UInt64) {
        guard token == submissionGeneration else { return }
        submissionGeneration &+= 1
        if editRevision == pendingEditRevision {
            editableAddressText = confirmedAddressText
        }
        displayedAddressText = confirmedAddressText
        displayedBaseAddress = confirmedBaseAddress
    }

    public mutating func reset() {
        submissionGeneration &+= 1
        editRevision &+= 1
        pendingEditRevision = editRevision
        editableAddressText = MemoryWindowLayout.defaultAddressText
        displayedAddressText = MemoryWindowLayout.defaultAddressText
        displayedBaseAddress = MemoryWindowLayout.defaultAddress
        confirmedAddressText = MemoryWindowLayout.defaultAddressText
        confirmedBaseAddress = MemoryWindowLayout.defaultAddress
    }

    private mutating func startSubmission(_ normalized: String) throws -> Submission {
        let address = try MemoryWindowAddress.value(normalized)
        pendingEditRevision = editRevision
        editableAddressText = normalized
        displayedAddressText = normalized
        displayedBaseAddress = address
        return Submission(token: submissionGeneration, normalizedAddress: normalized)
    }
}

public struct RegisterRow: Equatable, Identifiable, Sendable {
    public let name: String
    public let value: String
    public let hasChanged: Bool

    public init(name: String, value: String, hasChanged: Bool) {
        self.name = name
        self.value = value
        self.hasChanged = hasChanged
    }

    public var id: String { name }
    public var changeMarker: String { hasChanged ? "已变化" : "" }
    public var accessibilityValue: String {
        hasChanged ? "\(value)，已变化" : value
    }
}

public enum RegisterPresentation {
    public static func names(for profile: ProfileID) -> [String] {
        let general = (0...15).map { "r\($0)" }
        switch profile {
        case .arm7tdmi: return general + ["CPSR"]
        case .cortexM4, .stm32f4Discovery:
            return general + ["xPSR", "MSP", "PSP", "CONTROL", "PRIMASK"]
        }
    }

    public static func rows(
        current: [DebugRegister],
        previous: [DebugRegister]
    ) -> [RegisterRow] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.name.lowercased(), $0.value) })
        return current.map { register in
            let prior = old[register.name.lowercased()]
            let hasChanged = prior != nil && prior != register.value
            return RegisterRow(
                name: register.name,
                value: register.value?.raw ?? "—",
                hasChanged: hasChanged
            )
        }
    }
}

public struct BoundedConsole: Equatable, Sendable {
    public private(set) var entries: [DebugConsoleEntry] = []
    public private(set) var droppedCount = 0
    private let limit: Int

    public init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ entry: DebugConsoleEntry) {
        entries.append(entry)
        if entries.count > limit {
            let overflow = entries.count - limit
            entries.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    public mutating func replace(with entries: [DebugConsoleEntry]) {
        self.entries = Array(entries.suffix(limit))
        droppedCount += max(0, entries.count - limit)
    }
}
