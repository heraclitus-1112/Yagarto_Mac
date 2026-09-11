// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class MIParserTests: XCTestCase {
    private let parser = MIParser()

    func testParsesResultAsyncStreamsAndPromptRecords() throws {
        let cases: [(String, MIRecord)] = [
            ("17^done,value=\"ok\"", .result(MIResultRecord(
                token: 17,
                resultClass: .done,
                results: MIResults([MIResult(variable: "value", value: .constant("ok"))])
            ))),
            ("^running", .result(MIResultRecord(token: nil, resultClass: .running))),
            ("3^connected", .result(MIResultRecord(token: 3, resultClass: .connected))),
            ("9^exit", .result(MIResultRecord(token: 9, resultClass: .exit))),
            ("11^exited", .result(MIResultRecord(token: 11, resultClass: .exited))),
            ("4^error,msg=\"bad\"", .result(MIResultRecord(
                token: 4,
                resultClass: .error,
                results: MIResults([MIResult(variable: "msg", value: .constant("bad"))])
            ))),
            ("*stopped,reason=\"breakpoint-hit\"", .asynchronous(MIAsyncRecord(
                token: nil,
                kind: .exec,
                asyncClass: "stopped",
                results: MIResults([MIResult(variable: "reason", value: .constant("breakpoint-hit"))])
            ))),
            ("2+download,section=\".text\"", .asynchronous(MIAsyncRecord(
                token: 2,
                kind: .status,
                asyncClass: "download",
                results: MIResults([MIResult(variable: "section", value: .constant(".text"))])
            ))),
            ("=thread-created,id=\"1\"", .asynchronous(MIAsyncRecord(
                token: nil,
                kind: .notify,
                asyncClass: "thread-created",
                results: MIResults([MIResult(variable: "id", value: .constant("1"))])
            ))),
            ("~\"console\\n\"", .stream(MIStreamRecord(kind: .console, text: "console\n"))),
            ("@\"target\"", .stream(MIStreamRecord(kind: .target, text: "target"))),
            ("&\"log\"", .stream(MIStreamRecord(kind: .log, text: "log"))),
            ("(gdb)", .prompt),
            ("(gdb) ", .prompt)
        ]

        for (line, expected) in cases {
            XCTAssertEqual(try parser.parse(line), expected, line)
        }
    }

    func testParsesNestedTuplesResultListsAndValueListsWithoutLoss() throws {
        let record = try resultRecord(
            "42^done,frame={addr=\"0x1000\",func=\"main\",args=[{name=\"argc\",value=\"1\"}]},"
                + "register-values=[{number=\"0\",value=\"0x2a\"},{number=\"16\",value=\"0x60000013\"}],"
                + "changes=[name=\"r0\",name2=\"r1\"]"
        )

        XCTAssertEqual(record.token, 42)
        guard case .tuple(let frame)? = record.results["frame"],
              case .list(.values(let arguments))? = frame["args"],
              case .tuple(let firstArgument) = arguments.first else {
            return XCTFail("nested tuple/value-list not preserved")
        }
        XCTAssertEqual(firstArgument["name"]?.constant, "argc")

        guard case .list(.results(let changes))? = record.results["changes"] else {
            return XCTFail("result-list not preserved")
        }
        XCTAssertEqual(changes["name"]?.constant, "r0")
        XCTAssertEqual(changes["name2"]?.constant, "r1")
    }

    func testDecodesGDBCStringEscapesAsBytesAndPreservesUnicode() throws {
        let record = try resultRecord(
            #"^done,text="路径\\\"\n\r\t\e\101\x42\303\251""#
        )

        XCTAssertEqual(record.results["text"]?.constant, "路径\\\"\n\r\t\u{1B}ABé")
    }

    func testParsesGDB15StartupRecordThatMixesRawAndOctalUTF8Bytes() throws {
        var line = Data(
            "*stopped,\"Starting program\",execfile=\"/tmp/demo.elf\",reason=\"breakpoint-hit\",frame={fullname=\"/tmp/".utf8
        )
        line.append(0xE6)
        line.append(contentsOf: "\\225".utf8)
        line.append(0xB0)
        line.append(contentsOf: "/main.s\",line=\"12\"}".utf8)

        guard case .asynchronous(let stopped) = try parser.parse(line) else {
            return XCTFail("expected stopped record")
        }
        XCTAssertEqual(stopped.results["message"]?.constant, "Starting program")
        XCTAssertEqual(stopped.results["execfile"]?.constant, "/tmp/demo.elf")
        XCTAssertEqual(stopped.frame?.fullName, "/tmp/数/main.s")
        XCTAssertEqual(stopped.frame?.line?.numeric, 12)
    }

    func testRejectsInvalidUTF8FromRawTransport() {
        XCTAssertThrowsError(try parser.parse(Data([0x5e, 0x64, 0x6f, 0x6e, 0x65, 0xff]))) {
            XCTAssertEqual($0 as? MIParseError, .invalidUTF8)
        }
    }

    func testPreservesDuplicateKeysLosslesslyAndFirstLookupIsDeterministic() throws {
        let record = try resultRecord("^done,a=\"1\",a=\"2\",stack=[frame={level=\"0\"},frame={level=\"1\"}]")

        XCTAssertEqual(record.results["a"]?.constant, "1")
        XCTAssertEqual(record.results.values(for: "a").compactMap(\.constant), ["1", "2"])
        guard case .list(.results(let stack))? = record.results["stack"] else {
            return XCTFail("expected result list")
        }
        XCTAssertEqual(stack.values(for: "frame").count, 2)
    }

    func testRejectsUnknownMalformedAndTrailingInputDeterministically() {
        let malformed = [
            "", "garbage", "^mystery", "^done trailing", "^done,a=\"unterminated",
            "^done,a=\"bad\\q\"", "^done,a=\"raw\tcontrol\"", "^done,a={x=\"1\"", "^done,a=[\"1\"",
            "^done,a=[x=\"1\",\"mixed\"]", "999999999999999999999999^done"
        ]
        for line in malformed {
            XCTAssertThrowsError(try parser.parse(line), line)
        }
    }

    func testRejectsInputOverConfiguredByteAndDepthLimits() {
        let shortParser = MIParser(maxDepth: 3, maxLineBytes: 24)

        XCTAssertThrowsError(try shortParser.parse("^done,text=\"abcdefghijklmnopqrstuvwxyz\"")) {
            XCTAssertEqual($0 as? MIParseError, .lineTooLong(limit: 24))
        }
        XCTAssertThrowsError(try shortParser.parse("^done,a={b={c={d=\"x\"}}}")) {
            XCTAssertEqual($0 as? MIParseError, .depthLimitExceeded(limit: 3))
        }
    }

    func testTypedExtractorsExposeErrorStopFrameRegistersMemoryAndDisassembly() throws {
        let error = try resultRecord("7^error,msg=\"No symbol\",code=\"undefined-command\"")
        XCTAssertEqual(error.errorMessage, "No symbol")

        guard case .asynchronous(let stopped) = try parser.parse(
            "*stopped,reason=\"end-stepping-range\",frame={addr=\"0x00001000\",func=\"main\",file=\"main.s\",fullname=\"/tmp/课程/main.s\",line=\"12\"}"
        ) else {
            return XCTFail("expected stopped record")
        }
        XCTAssertEqual(stopped.stopReason, .endSteppingRange)
        XCTAssertEqual(stopped.frame, MIFrame(
            address: MIRawNumeric(raw: "0x00001000", numeric: 0x1000),
            function: "main",
            file: "main.s",
            fullName: "/tmp/课程/main.s",
            line: MIRawNumeric(raw: "12", numeric: 12)
        ))

        let names = try resultRecord("^done,register-names=[\"r0\",\"\",\"cpsr\"]")
        XCTAssertEqual(names.registerNames, ["r0", "", "cpsr"])

        let values = try resultRecord(
            "^done,register-values=[{number=\"2\",value=\"0x60000013\"},{number=\"0\",value=\"42\"}]"
        )
        XCTAssertEqual(values.registerValues, [
            MIRegisterValue(number: 2, value: MIRawNumeric(raw: "0x60000013", numeric: 0x60000013)),
            MIRegisterValue(number: 0, value: MIRawNumeric(raw: "42", numeric: 42))
        ])

        let memory = try resultRecord(
            "^done,memory=[{begin=\"0x1000\",offset=\"0x0\",end=\"0x1004\",contents=\"002affff\"}]"
        )
        XCTAssertEqual(memory.memoryBlocks, [MIMemoryBlock(
            begin: MIRawNumeric(raw: "0x1000", numeric: 0x1000),
            offset: MIRawNumeric(raw: "0x0", numeric: 0),
            end: MIRawNumeric(raw: "0x1004", numeric: 0x1004),
            contents: "002affff"
        )])

        let disassembly = try resultRecord(
            "^done,asm_insns=[{address=\"0x1000\",func-name=\"main\",offset=\"0\",inst=\"mov r0, #42\"}]"
        )
        XCTAssertEqual(disassembly.instructions, [MIInstruction(
            address: MIRawNumeric(raw: "0x1000", numeric: 0x1000),
            function: "main",
            offset: MIRawNumeric(raw: "0", numeric: 0),
            instruction: "mov r0, #42"
        )])
    }

    func testStackExtractorPreservesRepeatedFrameResults() throws {
        let stack = try resultRecord(
            "^done,stack=[frame={level=\"0\",addr=\"0x1000\",func=\"main\",line=\"8\"},"
                + "frame={level=\"1\",addr=\"0x2000\",func=\"reset\"}]"
        )

        XCTAssertEqual(stack.stackFrames, [
            MIFrame(
                address: MIRawNumeric(raw: "0x1000", numeric: 0x1000),
                function: "main",
                line: MIRawNumeric(raw: "8", numeric: 8)
            ),
            MIFrame(address: MIRawNumeric(raw: "0x2000", numeric: 0x2000), function: "reset")
        ])
    }

    func testFuzzishMalformedCorpusNeverAcceptsTruncations() throws {
        let valid = "91^done,frame={addr=\"0x1000\",args=[{name=\"x\",value=\"路径\"}]}"
        for end in valid.utf8.indices.dropFirst() {
            let truncated = String(decoding: valid.utf8[..<end], as: UTF8.self)
            // A result record may legally end immediately after its class.
            if truncated == "91^done" { continue }
            XCTAssertThrowsError(try parser.parse(truncated), "accepted truncation: \(truncated)")
        }
        XCTAssertNoThrow(try parser.parse(valid))
    }

    private func resultRecord(_ line: String) throws -> MIResultRecord {
        guard case .result(let record) = try parser.parse(line) else {
            throw ParserTestError.expectedResult
        }
        return record
    }
}

private enum ParserTestError: Error {
    case expectedResult
}
