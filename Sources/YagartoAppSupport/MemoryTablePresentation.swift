// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

public enum MemoryWindowLayout {
    public static let defaultAddress: UInt64 = 0x8000
    public static let defaultAddressText = "0x00008000"
    public static let bytesPerRow = 16
    public static let wordsPerRow = 4
    public static let rowCount = 7
    public static let byteCount = bytesPerRow * rowCount
}

public enum MemoryTableFormattingError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress(String)
    case oddHexDigitCount(address: String)
    case invalidHex(address: String)
    case addressOverflow(String)
    case conflictingByte(address: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "无法解析内存地址：\(address)。"
        case .oddHexDigitCount(let address):
            return "内存块 \(address) 的十六进制内容位数必须为偶数。"
        case .invalidHex(let address):
            return "内存块 \(address) 包含无效的十六进制数据。"
        case .addressOverflow(let address):
            return "内存块 \(address) 的地址范围超出 UInt64。"
        case .conflictingByte(let address):
            return "内存地址 \(Self.addressText(address)) 存在冲突字节。"
        }
    }

    private static func addressText(_ address: UInt64) -> String {
        let hex = String(address, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}

public enum MemoryWindowAddress {
    public static func normalized(_ address: String) throws -> String {
        addressText(try value(address))
    }

    public static func value(_ address: String) throws -> UInt64 {
        let normalized = address.replacingOccurrences(of: "_", with: "")
        guard normalized.range(of: #"^0x[0-9A-Fa-f]+$"#, options: .regularExpression) != nil else {
            throw MemoryTableFormattingError.invalidAddress(address)
        }
        guard let value = UInt64(normalized.dropFirst(2), radix: 16) else {
            throw MemoryTableFormattingError.addressOverflow(address)
        }
        try validateWindow(startingAt: value, source: address)
        return value
    }

    public static func valueOrDefault(_ address: String) -> UInt64 {
        (try? value(address)) ?? MemoryWindowLayout.defaultAddress
    }

    public static func stepped(_ address: String, byRows rowCount: Int) throws -> String {
        let current = try value(address)
        let magnitude = UInt64(rowCount.magnitude)
        let (offset, multiplicationOverflow) = magnitude.multipliedReportingOverflow(
            by: UInt64(MemoryWindowLayout.bytesPerRow)
        )
        guard !multiplicationOverflow else {
            throw MemoryTableFormattingError.addressOverflow(address)
        }

        let stepped: UInt64
        let arithmeticOverflow: Bool
        if rowCount >= 0 {
            (stepped, arithmeticOverflow) = current.addingReportingOverflow(offset)
        } else {
            (stepped, arithmeticOverflow) = current.subtractingReportingOverflow(offset)
        }
        guard !arithmeticOverflow else {
            throw MemoryTableFormattingError.addressOverflow(address)
        }

        try validateWindow(startingAt: stepped, source: address)
        return addressText(stepped)
    }

    private static func validateWindow(startingAt address: UInt64, source: String) throws {
        let (_, overflow) = address.addingReportingOverflow(UInt64(MemoryWindowLayout.byteCount - 1))
        guard !overflow else {
            throw MemoryTableFormattingError.addressOverflow(source)
        }
    }

    private static func addressText(_ address: UInt64) -> String {
        let hex = String(address, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}

public struct MemoryTableRow: Equatable, Sendable {
    public let address: UInt64
    public let bytes: [UInt8]

    public init(address: UInt64, bytes: [UInt8]) {
        precondition((1...16).contains(bytes.count), "MemoryTableRow requires 1...16 bytes")
        self.address = address
        self.bytes = bytes
    }

    public var addressText: String {
        let hex = String(address, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    public var byteTexts: [String] {
        bytes.map(Self.hexByte) + Array(repeating: "", count: 16 - bytes.count)
    }

    public var asciiText: String {
        let contents = bytes.map { byte in
            (0x20...0x7E).contains(byte)
                ? String(decoding: [byte], as: UTF8.self)
                : "."
        }.joined()
        return contents + String(repeating: " ", count: 16 - bytes.count)
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let hex = String(byte, radix: 16, uppercase: true)
        return byte < 0x10 ? "0" + hex : hex
    }
}

public struct MemoryWordTableRow: Equatable, Sendable {
    public let address: UInt64
    public let bytes: [UInt8?]

    public init(address: UInt64, bytes: [UInt8?]) {
        precondition(bytes.count == MemoryWindowLayout.bytesPerRow, "MemoryWordTableRow requires 16 bytes")
        self.address = address
        self.bytes = bytes
    }

    public var addressText: String {
        let hex = String(address, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    public var wordTexts: [String] {
        (0..<MemoryWindowLayout.wordsPerRow).map { wordText(at: $0) ?? "" }
    }

    public var wordAccessibilityValues: [String] {
        (0..<MemoryWindowLayout.wordsPerRow).map { wordIndex in
            let start = wordIndex * 4
            let wordBytes = bytes[start..<(start + 4)]
            if wordBytes.allSatisfy({ $0 == nil }) {
                return "空"
            }
            return wordText(at: wordIndex) ?? "数据不完整"
        }
    }

    public var asciiText: String {
        bytes.map { byte in
            guard let byte else { return " " }
            return (0x20...0x7E).contains(byte)
                ? String(decoding: [byte], as: UTF8.self)
                : "."
        }.joined()
    }

    private func wordText(at wordIndex: Int) -> String? {
        let start = wordIndex * 4
        guard
            let byte0 = bytes[start],
            let byte1 = bytes[start + 1],
            let byte2 = bytes[start + 2],
            let byte3 = bytes[start + 3]
        else {
            return nil
        }

        let word = UInt32(byte0)
            | (UInt32(byte1) << 8)
            | (UInt32(byte2) << 16)
            | (UInt32(byte3) << 24)
        let hex = String(word, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: 8 - hex.count) + hex
    }
}

public enum MemoryTableFormatter {
    public static func rows(from blocks: [MIMemoryBlock]) throws -> [MemoryTableRow] {
        let memory = try MemoryBlockDecoder.bytes(from: blocks)

        var rows: [MemoryTableRow] = []
        var rowAddress: UInt64?
        var rowBytes: [UInt8] = []
        var previousAddress: UInt64?

        for (address, byte) in memory.sorted(by: { $0.key < $1.key }) {
            if let previousAddress {
                let (expectedAddress, overflow) = previousAddress.addingReportingOverflow(1)
                if overflow || address != expectedAddress || rowBytes.count == 16 {
                    if let rowAddress {
                        rows.append(MemoryTableRow(address: rowAddress, bytes: rowBytes))
                    }
                    rowAddress = nil
                    rowBytes.removeAll(keepingCapacity: true)
                }
            }

            if rowAddress == nil {
                rowAddress = address
            }
            rowBytes.append(byte)
            previousAddress = address
        }

        if let rowAddress {
            rows.append(MemoryTableRow(address: rowAddress, bytes: rowBytes))
        }
        return rows
    }
}

public enum MemoryWordTableFormatter {
    public static func rows(
        from blocks: [MIMemoryBlock],
        baseAddress: UInt64,
        rowCount: Int = MemoryWindowLayout.rowCount
    ) throws -> [MemoryWordTableRow] {
        guard rowCount > 0 else { return [] }

        let (byteCount, multiplicationOverflow) = UInt64(rowCount).multipliedReportingOverflow(
            by: UInt64(MemoryWindowLayout.bytesPerRow)
        )
        guard !multiplicationOverflow else {
            throw MemoryTableFormattingError.addressOverflow(String(baseAddress))
        }
        let (_, addressOverflow) = baseAddress.addingReportingOverflow(byteCount - 1)
        guard !addressOverflow else {
            throw MemoryTableFormattingError.addressOverflow(String(baseAddress))
        }

        let memory = try MemoryBlockDecoder.bytes(from: blocks)
        return (0..<rowCount).map { rowIndex in
            let rowAddress = baseAddress
                + UInt64(rowIndex) * UInt64(MemoryWindowLayout.bytesPerRow)
            let bytes: [UInt8?] = (0..<MemoryWindowLayout.bytesPerRow).map { byteIndex in
                memory[rowAddress + UInt64(byteIndex)]
            }
            return MemoryWordTableRow(address: rowAddress, bytes: bytes)
        }
    }
}

private enum MemoryBlockDecoder {
    static func bytes(from blocks: [MIMemoryBlock]) throws -> [UInt64: UInt8] {
        var memory: [UInt64: UInt8] = [:]

        for block in blocks {
            guard let begin = block.begin.numeric else {
                throw MemoryTableFormattingError.invalidAddress(block.begin.raw)
            }

            let contents = Array(block.contents.utf8)
            guard contents.count.isMultiple(of: 2) else {
                throw MemoryTableFormattingError.oddHexDigitCount(address: block.begin.raw)
            }

            for contentIndex in stride(from: 0, to: contents.count, by: 2) {
                guard
                    let high = hexNibble(contents[contentIndex]),
                    let low = hexNibble(contents[contentIndex + 1])
                else {
                    throw MemoryTableFormattingError.invalidHex(address: block.begin.raw)
                }

                let byteOffset = UInt64(contentIndex / 2)
                let (address, overflow) = begin.addingReportingOverflow(byteOffset)
                guard !overflow else {
                    throw MemoryTableFormattingError.addressOverflow(block.begin.raw)
                }

                let byte = (high << 4) | low
                if let existing = memory[address], existing != byte {
                    throw MemoryTableFormattingError.conflictingByte(address: address)
                }
                memory[address] = byte
            }
        }

        return memory
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
