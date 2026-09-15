// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

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

public enum MemoryTableFormatter {
    public static func rows(from blocks: [MIMemoryBlock]) throws -> [MemoryTableRow] {
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

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
