// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public indirect enum MIValue: Equatable, Sendable {
    case constant(String)
    case tuple(MIResults)
    case list(MIList)

    public var constant: String? {
        guard case .constant(let value) = self else { return nil }
        return value
    }
}

public enum MIList: Equatable, Sendable {
    case values([MIValue])
    case results(MIResults)
}

public struct MIResult: Equatable, Sendable {
    public let variable: String
    public let value: MIValue

    public init(variable: String, value: MIValue) {
        self.variable = variable
        self.value = value
    }
}

/// Ordered, lossless MI results. Duplicate variables are retained; keyed lookup
/// deliberately returns the first value while `values(for:)` exposes all of them.
public struct MIResults: Equatable, Sendable {
    public let fields: [MIResult]

    public init(_ fields: [MIResult] = []) {
        self.fields = fields
    }

    public subscript(variable: String) -> MIValue? {
        fields.first(where: { $0.variable == variable })?.value
    }

    public func values(for variable: String) -> [MIValue] {
        fields.lazy.filter { $0.variable == variable }.map(\.value)
    }
}

public enum MIResultClass: String, Equatable, Sendable {
    case done
    case running
    case connected
    case exit
    case error
}

public enum MIAsyncKind: Character, Equatable, Sendable {
    case exec = "*"
    case status = "+"
    case notify = "="
}

public enum MIStreamKind: Character, Equatable, Sendable {
    case console = "~"
    case target = "@"
    case log = "&"
}

public struct MIResultRecord: Equatable, Sendable {
    public let token: UInt64?
    public let resultClass: MIResultClass
    public let results: MIResults

    public init(
        token: UInt64?,
        resultClass: MIResultClass,
        results: MIResults = MIResults()
    ) {
        self.token = token
        self.resultClass = resultClass
        self.results = results
    }
}

public struct MIAsyncRecord: Equatable, Sendable {
    public let token: UInt64?
    public let kind: MIAsyncKind
    public let asyncClass: String
    public let results: MIResults

    public init(
        token: UInt64?,
        kind: MIAsyncKind,
        asyncClass: String,
        results: MIResults = MIResults()
    ) {
        self.token = token
        self.kind = kind
        self.asyncClass = asyncClass
        self.results = results
    }
}

public struct MIStreamRecord: Equatable, Sendable {
    public let kind: MIStreamKind
    public let text: String

    public init(kind: MIStreamKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum MIRecord: Equatable, Sendable {
    case result(MIResultRecord)
    case asynchronous(MIAsyncRecord)
    case stream(MIStreamRecord)
    case prompt
}

public enum MIParseError: Error, Equatable, Sendable {
    case emptyLine
    case invalidUTF8
    case lineTooLong(limit: Int)
    case depthLimitExceeded(limit: Int)
    case invalidToken
    case unknownRecordPrefix(UInt8)
    case unknownResultClass(String)
    case malformed(position: Int)
    case invalidEscape(position: Int)
    case trailingGarbage(position: Int)
}

public struct MIRawNumeric: Equatable, Sendable {
    public let raw: String
    public let numeric: UInt64?

    public init(raw: String, numeric: UInt64? = nil) {
        self.raw = raw
        self.numeric = numeric ?? Self.parse(raw)
    }

    private static func parse(_ raw: String) -> UInt64? {
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw, radix: 10)
    }
}

public enum MIStopReason: Equatable, Sendable {
    case breakpointHit
    case endSteppingRange
    case signalReceived
    case exitedNormally
    case exited
    case exitedSignalled
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "breakpoint-hit": self = .breakpointHit
        case "end-stepping-range": self = .endSteppingRange
        case "signal-received": self = .signalReceived
        case "exited-normally": self = .exitedNormally
        case "exited": self = .exited
        case "exited-signalled": self = .exitedSignalled
        default: self = .unknown(raw)
        }
    }
}

public struct MIFrame: Equatable, Sendable {
    public let address: MIRawNumeric?
    public let function: String?
    public let file: String?
    public let fullName: String?
    public let line: MIRawNumeric?

    public init(
        address: MIRawNumeric? = nil,
        function: String? = nil,
        file: String? = nil,
        fullName: String? = nil,
        line: MIRawNumeric? = nil
    ) {
        self.address = address
        self.function = function
        self.file = file
        self.fullName = fullName
        self.line = line
    }
}

public struct MIRegisterValue: Equatable, Sendable {
    public let number: Int
    public let value: MIRawNumeric

    public init(number: Int, value: MIRawNumeric) {
        self.number = number
        self.value = value
    }
}

public struct MIMemoryBlock: Equatable, Sendable {
    public let begin: MIRawNumeric
    public let offset: MIRawNumeric
    public let end: MIRawNumeric
    public let contents: String

    public init(begin: MIRawNumeric, offset: MIRawNumeric, end: MIRawNumeric, contents: String) {
        self.begin = begin
        self.offset = offset
        self.end = end
        self.contents = contents
    }
}

public struct MIInstruction: Equatable, Sendable {
    public let address: MIRawNumeric
    public let function: String?
    public let offset: MIRawNumeric?
    public let instruction: String

    public init(
        address: MIRawNumeric,
        function: String? = nil,
        offset: MIRawNumeric? = nil,
        instruction: String
    ) {
        self.address = address
        self.function = function
        self.offset = offset
        self.instruction = instruction
    }
}

public extension MIResultRecord {
    var errorMessage: String? { results["msg"]?.constant }
    var frame: MIFrame? { Self.frame(from: results["frame"]) }

    var registerNames: [String] {
        guard case .list(.values(let values))? = results["register-names"] else { return [] }
        return values.compactMap(\.constant)
    }

    var registerValues: [MIRegisterValue] {
        tuples(in: results["register-values"]).compactMap { tuple in
            guard let rawNumber = tuple["number"]?.constant,
                  let number = Int(rawNumber),
                  let rawValue = tuple["value"]?.constant else { return nil }
            return MIRegisterValue(number: number, value: MIRawNumeric(raw: rawValue))
        }
    }

    var memoryBlocks: [MIMemoryBlock] {
        tuples(in: results["memory"]).compactMap { tuple in
            guard let begin = tuple["begin"]?.constant,
                  let offset = tuple["offset"]?.constant,
                  let end = tuple["end"]?.constant,
                  let contents = tuple["contents"]?.constant else { return nil }
            return MIMemoryBlock(
                begin: MIRawNumeric(raw: begin),
                offset: MIRawNumeric(raw: offset),
                end: MIRawNumeric(raw: end),
                contents: contents
            )
        }
    }

    var instructions: [MIInstruction] {
        tuples(in: results["asm_insns"]).compactMap { tuple -> MIInstruction? in
            guard let address = tuple["address"]?.constant,
                  let instruction = tuple["inst"]?.constant else { return nil }
            return MIInstruction(
                address: MIRawNumeric(raw: address),
                function: tuple["func-name"]?.constant,
                offset: tuple["offset"]?.constant.map { MIRawNumeric(raw: $0) },
                instruction: instruction
            )
        }
    }

    var stackFrames: [MIFrame] {
        guard case .list(.results(let stack))? = results["stack"] else { return [] }
        return stack.values(for: "frame").compactMap(Self.frame(from:))
    }

    private func tuples(in value: MIValue?) -> [MIResults] {
        guard case .list(let list)? = value else { return [] }
        switch list {
        case .values(let values):
            return values.compactMap { value in
                guard case .tuple(let tuple) = value else { return nil }
                return tuple
            }
        case .results(let results):
            return results.fields.compactMap { result in
                guard case .tuple(let tuple) = result.value else { return nil }
                return tuple
            }
        }
    }

    fileprivate static func frame(from value: MIValue?) -> MIFrame? {
        guard case .tuple(let tuple)? = value else { return nil }
        return MIFrame(
            address: tuple["addr"]?.constant.map { MIRawNumeric(raw: $0) },
            function: tuple["func"]?.constant,
            file: tuple["file"]?.constant,
            fullName: tuple["fullname"]?.constant,
            line: tuple["line"]?.constant.map { MIRawNumeric(raw: $0) }
        )
    }
}

public extension MIAsyncRecord {
    var stopReason: MIStopReason? {
        results["reason"]?.constant.map(MIStopReason.init(raw:))
    }

    var frame: MIFrame? {
        MIResultRecord.frame(from: results["frame"])
    }
}
