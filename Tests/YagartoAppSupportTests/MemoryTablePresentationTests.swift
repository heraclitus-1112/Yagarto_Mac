// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import YagartoCore
@testable import YagartoAppSupport

final class MemoryTablePresentationTests: XCTestCase {
    func testMemoryWindowLayoutUsesCourseDefaults() {
        XCTAssertEqual(MemoryWindowLayout.defaultAddress, 0x8000)
        XCTAssertEqual(MemoryWindowLayout.defaultAddressText, "0x00008000")
        XCTAssertEqual(MemoryWindowLayout.bytesPerRow, 16)
        XCTAssertEqual(MemoryWindowLayout.wordsPerRow, 4)
        XCTAssertEqual(MemoryWindowLayout.rowCount, 7)
        XCTAssertEqual(MemoryWindowLayout.byteCount, 112)
    }

    func testMemoryWindowAddressNormalizesStrictHexAndFallsBackToDefault() throws {
        XCTAssertEqual(try MemoryWindowAddress.normalized("0x8000"), "0x00008000")
        XCTAssertEqual(try MemoryWindowAddress.normalized("0x2000_1000"), "0x20001000")
        XCTAssertEqual(try MemoryWindowAddress.value("0x8000"), 0x8000)
        XCTAssertEqual(MemoryWindowAddress.valueOrDefault("$sp"), 0x8000)

        for address in ["$sp", "8000", "0X8000", "0x20; quit", ""] {
            XCTAssertThrowsError(try MemoryWindowAddress.normalized(address))
        }
    }

    func testMemoryWindowAddressStepsBySixteenBytesAndRejectsOverflow() throws {
        XCTAssertEqual(try MemoryWindowAddress.stepped("0x8000", byRows: 1), "0x00008010")
        XCTAssertEqual(try MemoryWindowAddress.stepped("0x8000", byRows: -1), "0x00007FF0")
        XCTAssertEqual(
            try MemoryWindowAddress.normalized("0xFFFFFFFFFFFFFF90"),
            "0xFFFFFFFFFFFFFF90"
        )

        XCTAssertThrowsError(try MemoryWindowAddress.normalized("0xFFFFFFFFFFFFFF91"))
        XCTAssertThrowsError(try MemoryWindowAddress.stepped("0xFFFFFFFFFFFFFF90", byRows: 1))
        XCTAssertThrowsError(try MemoryWindowAddress.stepped("0x0", byRows: -1))
    }

    func testFormatsDefaultWindowAsSevenRowsOfLittleEndianWords() throws {
        let rows = try MemoryWordTableFormatter.rows(
            from: [block(begin: "0x8000", contents: "fcfdeeff010000000200000003000000")],
            baseAddress: 0x8000
        )

        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[0].address, 0x8000)
        XCTAssertEqual(rows[0].addressText, "0x00008000")
        XCTAssertEqual(rows[0].bytes, [
            0xFC, 0xFD, 0xEE, 0xFF,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(rows[0].wordTexts, [
            "0xFFEEFDFC", "0x00000001", "0x00000002", "0x00000003"
        ])
        XCTAssertEqual(rows[0].wordAccessibilityValues, rows[0].wordTexts)
        XCTAssertEqual(rows[0].asciiText, "................")

        XCTAssertEqual(rows[1].address, 0x8010)
        XCTAssertEqual(rows[1].bytes, Array<UInt8?>(repeating: nil, count: 16))
        XCTAssertEqual(rows[1].wordTexts, Array(repeating: "", count: 4))
        XCTAssertEqual(rows[1].wordAccessibilityValues, Array(repeating: "空", count: 4))
        XCTAssertEqual(rows[1].asciiText, String(repeating: " ", count: 16))
        XCTAssertEqual(rows[6].address, 0x8060)
    }

    func testMarksPartialAndEmptyWordsForAccessibility() throws {
        let partialRows = try MemoryWordTableFormatter.rows(
            from: [block(begin: "0x8000", contents: "010203")],
            baseAddress: 0x8000,
            rowCount: 1
        )

        XCTAssertEqual(partialRows[0].wordTexts, Array(repeating: "", count: 4))
        XCTAssertEqual(
            partialRows[0].wordAccessibilityValues,
            ["数据不完整", "空", "空", "空"]
        )
        XCTAssertEqual(partialRows[0].asciiText, "...             ")

        let emptyRows = try MemoryWordTableFormatter.rows(
            from: [],
            baseAddress: 0x8000,
            rowCount: 1
        )
        XCTAssertEqual(emptyRows[0].wordTexts, Array(repeating: "", count: 4))
        XCTAssertEqual(emptyRows[0].wordAccessibilityValues, Array(repeating: "空", count: 4))
    }

    func testWordWindowPreservesExactUnalignedBaseAddress() throws {
        let rows = try MemoryWordTableFormatter.rows(
            from: [block(begin: "0x8003", contents: "01000000")],
            baseAddress: 0x8003,
            rowCount: 2
        )

        XCTAssertEqual(rows.map(\.addressText), ["0x00008003", "0x00008013"])
        XCTAssertEqual(rows[0].wordTexts, ["0x00000001", "", "", ""])
        XCTAssertEqual(rows[1].bytes, Array<UInt8?>(repeating: nil, count: 16))
    }

    func testWordWindowBoundsRowCountBeforeAllocation() throws {
        XCTAssertEqual(
            try MemoryWordTableFormatter.rows(from: [], baseAddress: 0, rowCount: 1).count,
            1
        )
        XCTAssertEqual(
            try MemoryWordTableFormatter.rows(from: [], baseAddress: 0, rowCount: 256).count,
            256
        )

        for rowCount in [-1, 0, 257, 1 << 59] {
            XCTAssertThrowsError(
                try MemoryWordTableFormatter.rows(
                    from: [],
                    baseAddress: 0,
                    rowCount: rowCount
                )
            ) { error in
                XCTAssertEqual(
                    error as? MemoryTableFormattingError,
                    .invalidRowCount(rowCount)
                )
                XCTAssertEqual(
                    error.localizedDescription,
                    "内存窗口行数必须在 1 到 256 之间，当前为 \(rowCount)。"
                )
            }
        }
    }

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
