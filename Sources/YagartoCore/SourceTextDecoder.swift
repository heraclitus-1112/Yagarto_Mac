// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

public enum SourceTextEncoding: String, Equatable, Sendable {
    case utf8
    case gb18030
    case windowsCP1252
    case isoLatin1

    public var displayName: String {
        switch self {
        case .utf8:
            "UTF-8"
        case .gb18030:
            "GBK/GB18030"
        case .windowsCP1252:
            "Windows-1252/ISO-8859-1"
        case .isoLatin1:
            "ISO-8859-1"
        }
    }
}

public struct DecodedSourceText: Equatable, Sendable {
    public let text: String
    public let utf8Data: Data
    public let encoding: SourceTextEncoding

    public init(text: String, utf8Data: Data, encoding: SourceTextEncoding) {
        self.text = text
        self.utf8Data = utf8Data
        self.encoding = encoding
    }
}

public enum SourceTextDecodingError: Error, Equatable, LocalizedError, Sendable {
    case invalidText

    public var errorDescription: String? {
        "源码不是受支持的文本编码，或包含二进制控制字符。"
    }
}

public struct SourceTextDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> DecodedSourceText {
        if let text = String(data: data, encoding: .utf8) {
            try validateText(text)
            return DecodedSourceText(text: text, utf8Data: data, encoding: .utf8)
        }

        guard !data.contains(0) else {
            throw SourceTextDecodingError.invalidText
        }

        var converted: NSString?
        var usedLossyConversion = ObjCBool(false)
        let rawEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )
        guard !usedLossyConversion.boolValue,
              let converted,
              let encoding = sourceEncoding(for: rawEncoding) else {
            throw SourceTextDecodingError.invalidText
        }

        let text = converted as String
        try validateText(text)
        return DecodedSourceText(
            text: text,
            utf8Data: Data(text.utf8),
            encoding: encoding
        )
    }

    private func sourceEncoding(for rawValue: UInt) -> SourceTextEncoding? {
        switch rawValue {
        case Self.gb18030.rawValue:
            .gb18030
        case String.Encoding.windowsCP1252.rawValue:
            .windowsCP1252
        case String.Encoding.isoLatin1.rawValue:
            .isoLatin1
        default:
            nil
        }
    }

    private func validateText(_ text: String) throws {
        for scalar in text.unicodeScalars {
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                continue
            }
            if scalar.value == 0xFFFD || CharacterSet.controlCharacters.contains(scalar) {
                throw SourceTextDecodingError.invalidText
            }
        }
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}
