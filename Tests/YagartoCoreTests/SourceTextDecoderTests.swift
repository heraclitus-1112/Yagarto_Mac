// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import XCTest
@testable import YagartoCore

final class SourceTextDecoderTests: XCTestCase {
    func testStrictUTF8RemainsByteIdentical() throws {
        let data = Data("@ 中文与 français\r\n.global start\r\nstart: b start\r\n".utf8)

        let decoded = try SourceTextDecoder().decode(data)

        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertEqual(decoded.utf8Data, data)
        XCTAssertEqual(decoded.text, String(decoding: data, as: UTF8.self))
    }

    func testDecodesWindows1252FrenchTextAsUTF8() throws {
        let expected = "@ résultat récupère libère\r\n.global start\r\nstart: b start\r\n"
        let data = try XCTUnwrap(expected.data(using: .windowsCP1252))

        let decoded = try SourceTextDecoder().decode(data)

        XCTAssertEqual(decoded.encoding, .windowsCP1252)
        XCTAssertEqual(decoded.text, expected)
        XCTAssertEqual(decoded.utf8Data, Data(expected.utf8))
    }

    func testDecodesGB18030ChineseTextAsUTF8() throws {
        let expected = "@ 中文注释：课程源码\r\n.global start\r\nstart: b start\r\n"
        let data = try XCTUnwrap(expected.data(using: Self.gb18030))

        let decoded = try SourceTextDecoder().decode(data)

        XCTAssertEqual(decoded.encoding, .gb18030)
        XCTAssertEqual(decoded.text, expected)
        XCTAssertEqual(decoded.utf8Data, Data(expected.utf8))
    }

    func testRejectsBinaryNullAndDisallowedControlCharacters() {
        for data in [
            Data([0x00, 0x41]),
            Data([0x41, 0x1B, 0x42]),
            Data([0xFF, 0xFE])
        ] {
            XCTAssertThrowsError(try SourceTextDecoder().decode(data)) { error in
                XCTAssertEqual(error as? SourceTextDecodingError, .invalidText)
            }
        }
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}
