// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct MIParser: Sendable {
    public static let defaultMaxDepth = 32
    public static let defaultMaxLineBytes = 256 * 1_024

    public let maxDepth: Int
    public let maxLineBytes: Int

    public init(
        maxDepth: Int = MIParser.defaultMaxDepth,
        maxLineBytes: Int = MIParser.defaultMaxLineBytes
    ) {
        self.maxDepth = max(1, maxDepth)
        self.maxLineBytes = max(1, maxLineBytes)
    }

    public func parse(_ line: String) throws -> MIRecord {
        try parseBytes(Array(line.utf8))
    }

    public func parse(_ data: Data) throws -> MIRecord {
        guard data.count <= maxLineBytes else {
            throw MIParseError.lineTooLong(limit: maxLineBytes)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw MIParseError.invalidUTF8
        }
        return try parseBytes(Array(data))
    }

    private func parseBytes(_ originalBytes: [UInt8]) throws -> MIRecord {
        guard originalBytes.count <= maxLineBytes else {
            throw MIParseError.lineTooLong(limit: maxLineBytes)
        }
        var bytes = originalBytes
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { throw MIParseError.emptyLine }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw MIParseError.invalidUTF8
        }
        if bytes == Array("(gdb)".utf8) || bytes == Array("(gdb) ".utf8) {
            return .prompt
        }

        var cursor = Cursor(bytes: bytes, maxDepth: maxDepth)
        let token = try cursor.parseToken()
        guard let prefix = cursor.take() else {
            throw MIParseError.invalidToken
        }

        let record: MIRecord
        switch prefix {
        case UInt8(ascii: "^"):
            let className = try cursor.parseIdentifier()
            guard let resultClass = MIResultClass(rawValue: className) else {
                throw MIParseError.unknownResultClass(className)
            }
            record = .result(MIResultRecord(
                token: token,
                resultClass: resultClass,
                results: try cursor.parseOptionalResults()
            ))
        case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "="):
            guard let kind = MIAsyncKind(rawValue: Character(UnicodeScalar(prefix))) else {
                throw MIParseError.unknownRecordPrefix(prefix)
            }
            record = .asynchronous(MIAsyncRecord(
                token: token,
                kind: kind,
                asyncClass: try cursor.parseIdentifier(),
                results: try cursor.parseOptionalResults()
            ))
        case UInt8(ascii: "~"), UInt8(ascii: "@"), UInt8(ascii: "&"):
            guard token == nil,
                  let kind = MIStreamKind(rawValue: Character(UnicodeScalar(prefix))) else {
                throw MIParseError.malformed(position: cursor.position - 1)
            }
            record = .stream(MIStreamRecord(kind: kind, text: try cursor.parseCString()))
        default:
            throw MIParseError.unknownRecordPrefix(prefix)
        }
        guard cursor.isAtEnd else {
            throw MIParseError.trailingGarbage(position: cursor.position)
        }
        return record
    }
}

private struct Cursor {
    let bytes: [UInt8]
    let maxDepth: Int
    var position = 0

    var isAtEnd: Bool { position == bytes.count }

    mutating func take() -> UInt8? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    func peek() -> UInt8? {
        position < bytes.count ? bytes[position] : nil
    }

    mutating func parseToken() throws -> UInt64? {
        let start = position
        while let byte = peek(), byte.isASCIIDigit { position += 1 }
        guard position > start else { return nil }
        guard let token = UInt64(String(decoding: bytes[start..<position], as: UTF8.self)) else {
            throw MIParseError.invalidToken
        }
        return token
    }

    mutating func parseIdentifier() throws -> String {
        let start = position
        while let byte = peek(), byte.isMIIdentifierByte { position += 1 }
        guard position > start else {
            throw MIParseError.malformed(position: position)
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    mutating func parseOptionalResults() throws -> MIResults {
        guard peek() == UInt8(ascii: ",") else { return MIResults() }
        position += 1
        return try parseResults(until: nil, depth: 0)
    }

    mutating func parseResults(until terminator: UInt8?, depth: Int) throws -> MIResults {
        var fields: [MIResult] = []
        while true {
            fields.append(try parseResult(depth: depth))
            guard peek() == UInt8(ascii: ",") else { break }
            position += 1
            if peek() == terminator {
                throw MIParseError.malformed(position: position)
            }
        }
        return MIResults(fields)
    }

    mutating func parseResult(depth: Int) throws -> MIResult {
        let variable = try parseIdentifier()
        guard take() == UInt8(ascii: "=") else {
            throw MIParseError.malformed(position: position)
        }
        return MIResult(variable: variable, value: try parseValue(depth: depth + 1))
    }

    mutating func parseValue(depth: Int) throws -> MIValue {
        guard depth <= maxDepth else {
            throw MIParseError.depthLimitExceeded(limit: maxDepth)
        }
        switch peek() {
        case UInt8(ascii: "\""):
            return .constant(try parseCString())
        case UInt8(ascii: "{"):
            position += 1
            if peek() == UInt8(ascii: "}") {
                position += 1
                return .tuple(MIResults())
            }
            let results = try parseResults(until: UInt8(ascii: "}"), depth: depth)
            guard take() == UInt8(ascii: "}") else {
                throw MIParseError.malformed(position: position)
            }
            return .tuple(results)
        case UInt8(ascii: "["):
            return try parseList(depth: depth)
        default:
            throw MIParseError.malformed(position: position)
        }
    }

    mutating func parseList(depth: Int) throws -> MIValue {
        position += 1
        if peek() == UInt8(ascii: "]") {
            position += 1
            return .list(.values([]))
        }

        let list: MIList
        switch peek() {
        case UInt8(ascii: "\""), UInt8(ascii: "{"), UInt8(ascii: "["):
            var values: [MIValue] = []
            while true {
                values.append(try parseValue(depth: depth + 1))
                guard peek() == UInt8(ascii: ",") else { break }
                position += 1
            }
            list = .values(values)
        default:
            list = .results(try parseResults(until: UInt8(ascii: "]"), depth: depth))
        }
        guard take() == UInt8(ascii: "]") else {
            throw MIParseError.malformed(position: position)
        }
        return .list(list)
    }

    mutating func parseCString() throws -> String {
        guard take() == UInt8(ascii: "\"") else {
            throw MIParseError.malformed(position: position)
        }
        var decoded: [UInt8] = []
        while let byte = take() {
            if byte == UInt8(ascii: "\"") {
                guard let string = String(bytes: decoded, encoding: .utf8) else {
                    throw MIParseError.invalidUTF8
                }
                return string
            }
            guard byte >= 0x20, byte != 0x7F else {
                throw MIParseError.malformed(position: position - 1)
            }
            guard byte == UInt8(ascii: "\\") else {
                decoded.append(byte)
                continue
            }
            let escapePosition = position - 1
            guard let escaped = take() else {
                throw MIParseError.invalidEscape(position: escapePosition)
            }
            switch escaped {
            case UInt8(ascii: "\\"), UInt8(ascii: "\""):
                decoded.append(escaped)
            case UInt8(ascii: "n"): decoded.append(0x0A)
            case UInt8(ascii: "r"): decoded.append(0x0D)
            case UInt8(ascii: "t"): decoded.append(0x09)
            case UInt8(ascii: "e"): decoded.append(0x1B)
            case UInt8(ascii: "a"): decoded.append(0x07)
            case UInt8(ascii: "b"): decoded.append(0x08)
            case UInt8(ascii: "f"): decoded.append(0x0C)
            case UInt8(ascii: "v"): decoded.append(0x0B)
            case UInt8(ascii: "x"):
                let start = position
                while let hex = peek(), hex.hexValue != nil { position += 1 }
                guard position > start,
                      let value = UInt64(String(decoding: bytes[start..<position], as: UTF8.self), radix: 16),
                      value <= UInt8.max else {
                    throw MIParseError.invalidEscape(position: escapePosition)
                }
                decoded.append(UInt8(value))
            case let octal where octal.isOctalDigit:
                var digits = [octal]
                while digits.count < 3, let next = peek(), next.isOctalDigit {
                    digits.append(next)
                    position += 1
                }
                guard let value = UInt16(String(decoding: digits, as: UTF8.self), radix: 8),
                      value <= UInt8.max else {
                    throw MIParseError.invalidEscape(position: escapePosition)
                }
                decoded.append(UInt8(value))
            default:
                throw MIParseError.invalidEscape(position: escapePosition)
            }
        }
        throw MIParseError.malformed(position: position)
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isOctalDigit: Bool { self >= 0x30 && self <= 0x37 }
    var isMIIdentifierByte: Bool {
        (self >= 0x41 && self <= 0x5A)
            || (self >= 0x61 && self <= 0x7A)
            || isASCIIDigit
            || self == UInt8(ascii: "_")
            || self == UInt8(ascii: "-")
    }
    var hexValue: UInt8? {
        switch self {
        case 0x30...0x39: self - 0x30
        case 0x41...0x46: self - 0x41 + 10
        case 0x61...0x66: self - 0x61 + 10
        default: nil
        }
    }
}
