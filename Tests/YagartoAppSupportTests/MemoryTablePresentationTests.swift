// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import YagartoCore
@testable import YagartoAppSupport

final class MemoryTablePresentationTests: XCTestCase {
    func testFormatsTwentyBytesAsSixteenByteRowAndPaddedRemainder() throws {
        let rows = try MemoryTableFormatter.rows(from: [
            block(
                begin: "0x8000",
                contents: "fcfdeeff01000000020000000300000004000000"
            )
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].address, 0x8000)
        XCTAssertEqual(rows[0].addressText, "0x00008000")
        XCTAssertEqual(rows[0].bytes, [
            0xFC, 0xFD, 0xEE, 0xFF,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(rows[0].byteTexts, [
            "FC", "FD", "EE", "FF",
            "01", "00", "00", "00",
            "02", "00", "00", "00",
            "03", "00", "00", "00"
        ])
        XCTAssertEqual(rows[0].asciiText, "................")

        XCTAssertEqual(rows[1].address, 0x8010)
        XCTAssertEqual(rows[1].addressText, "0x00008010")
        XCTAssertEqual(rows[1].bytes, [0x04, 0x00, 0x00, 0x00])
        XCTAssertEqual(
            rows[1].byteTexts,
            ["04", "00", "00", "00"] + Array(repeating: "", count: 12)
        )
        XCTAssertEqual(rows[1].asciiText, "....            ")
    }

    func testPreservesUnalignedAddressAndMapsOnlyPrintableASCII() throws {
        let rows = try MemoryTableFormatter.rows(from: [
            block(
                begin: "0x8003",
                contents: "4142207e001f7f3031323334353637383930"
            )
        ])

        XCTAssertEqual(rows.map(\.addressText), ["0x00008003", "0x00008013"])
        XCTAssertEqual(rows[0].asciiText, "AB ~...012345678")
        XCTAssertEqual(String(rows[0].asciiText.prefix(7)), "AB ~...")
        XCTAssertEqual(rows[1].bytes, [0x39, 0x30])
        XCTAssertEqual(rows[1].byteTexts, ["39", "30"] + Array(repeating: "", count: 14))
        XCTAssertEqual(rows[1].asciiText, "90              ")
    }

    func testMergesContiguousBlocksDeduplicatesEqualBytesAndStartsNewRowAtGap() throws {
        let rows = try MemoryTableFormatter.rows(from: [
            block(begin: "0x2000", contents: "0506"),
            block(begin: "0x1002", contents: "0304"),
            block(begin: "0x1000", contents: "0102"),
            block(begin: "0x1001", contents: "02")
        ])

        XCTAssertEqual(rows, [
            MemoryTableRow(address: 0x1000, bytes: [0x01, 0x02, 0x03, 0x04]),
            MemoryTableRow(address: 0x2000, bytes: [0x05, 0x06])
        ])
    }

    func testReturnsNoRowsForEmptyInput() throws {
        XCTAssertEqual(try MemoryTableFormatter.rows(from: []), [])
    }

    func testRejectsMalformedBlocksOverflowAndConflictingBytes() {
        assertFormattingError(
            .invalidAddress("not-an-address"),
            blocks: [block(begin: "not-an-address", contents: "00")]
        )
        assertFormattingError(
            .oddHexDigitCount(address: "0x1000"),
            blocks: [block(begin: "0x1000", contents: "0")]
        )
        assertFormattingError(
            .invalidHex(address: "0x1000"),
            blocks: [block(begin: "0x1000", contents: "0G")]
        )
        assertFormattingError(
            .addressOverflow("0xFFFFFFFFFFFFFFFF"),
            blocks: [block(begin: "0xFFFFFFFFFFFFFFFF", contents: "0102")]
        )
        assertFormattingError(
            .conflictingByte(address: 0x3000),
            blocks: [
                block(begin: "0x3000", contents: "01"),
                block(begin: "0x3000", contents: "02")
            ]
        )
    }

    private func block(begin: String, contents: String) -> MIMemoryBlock {
        MIMemoryBlock(
            begin: MIRawNumeric(raw: begin),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: begin),
            contents: contents
        )
    }

    private func assertFormattingError(
        _ expected: MemoryTableFormattingError,
        blocks: [MIMemoryBlock],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MemoryTableFormatter.rows(from: blocks), file: file, line: line) { error in
            XCTAssertEqual(error as? MemoryTableFormattingError, expected, file: file, line: line)
        }
    }
}
