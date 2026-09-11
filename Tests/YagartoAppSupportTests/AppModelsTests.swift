// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class AppModelsTests: XCTestCase {
    func testGNUDiagnosticsMapFileLineColumnAndBoundOutput() {
        let project = URL(fileURLWithPath: "/tmp/中文 工程", isDirectory: true)
        let oversizedTail = String(repeating: "x", count: 2_000)
        let output = """
        /tmp/中文 工程/main.s:12:7: Error: bad register
        /tmp/中文 工程/startup.s:9: Warning: deprecated form
        ld: undefined reference to `missing_symbol'
        \(oversizedTail)
        """

        let report = BuildDiagnosticParser.parse(output, projectDirectory: project, outputLimit: 512)

        XCTAssertEqual(report.diagnostics[0], BuildDiagnostic(
            severity: .error,
            file: project.appendingPathComponent("main.s"),
            line: 12,
            column: 7,
            message: "bad register"
        ))
        XCTAssertEqual(report.diagnostics[1].severity, .warning)
        XCTAssertEqual(report.diagnostics[1].line, 9)
        XCTAssertTrue(report.diagnostics.contains { $0.message.contains("undefined reference") })
        XCTAssertLessThanOrEqual(report.output.utf8.count, 512)
        XCTAssertTrue(report.wasTruncated)
    }

    func testBoundedToolOutputNeverExceedsByteLimitAcrossUTF8Boundary() {
        let report = BuildDiagnosticParser.parse(
            String(repeating: "中", count: 20),
            projectDirectory: URL(fileURLWithPath: "/tmp"),
            outputLimit: 5
        )

        XCTAssertLessThanOrEqual(report.output.utf8.count, 5)
        XCTAssertTrue(report.wasTruncated)
    }

    func testDiagnosticClickReturnsOneBasedSourceSelection() {
        let diagnostic = BuildDiagnostic(
            severity: .error,
            file: URL(fileURLWithPath: "/tmp/main.s"),
            line: 3,
            column: 2,
            message: "bad"
        )

        XCTAssertEqual(diagnostic.sourceSelection(in: "one\ntwo\nthree\n"), NSRange(location: 9, length: 0))
    }

    func testCommandAvailabilityFollowsEveryDebuggerState() {
        XCTAssertTrue(AppCommandAvailability.isEnabled(.open, state: .idle, hasDocument: false, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.build, state: .idle, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.save, state: .ready, hasDocument: true, isDirty: true))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.run, state: .ready, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.debug, state: .ready, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.pause, state: .running, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.stepInstruction, state: .stopped, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.stepOver, state: .stopped, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.continue, state: .stopped, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.stop, state: .launching, hasDocument: true, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.stop, state: .terminating, hasDocument: true, isDirty: false))

        for state in [DebuggerState.building, .launching, .running, .terminating] {
            XCTAssertFalse(AppCommandAvailability.isEnabled(.build, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.changeProfile, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.edit, state: state, hasDocument: true, isDirty: false))
        }
        XCTAssertFalse(AppCommandAvailability.isEnabled(.build, state: .idle, hasDocument: false, isDirty: false))
    }

    func testMemoryValidationAcceptsHexAndStackButRejectsUnsafeInput() throws {
        XCTAssertEqual(try MemoryRequestValidator.request(address: "$sp", length: "64"), .stackWindow)
        XCTAssertEqual(
            try MemoryRequestValidator.request(address: "0x2000_1000", length: "16"),
            DebugMemoryRequest(address: "0x20001000", byteCount: 16)
        )
        for address in ["2000", "$pc", "0x20; quit", ""] {
            XCTAssertThrowsError(try MemoryRequestValidator.request(address: address, length: "16"))
        }
        for length in ["0", "4097", "-1", "lots"] {
            XCTAssertThrowsError(try MemoryRequestValidator.request(address: "0x20", length: length))
        }
    }

    func testRegisterProfilesAndChangeMarkersAreExplicit() {
        XCTAssertEqual(RegisterPresentation.names(for: .arm7tdmi), (0...15).map { "r\($0)" } + ["CPSR"])
        XCTAssertEqual(RegisterPresentation.names(for: .cortexM4).suffix(5), ["xPSR", "MSP", "PSP", "CONTROL", "PRIMASK"])
        XCTAssertEqual(RegisterPresentation.names(for: .stm32f4Discovery), RegisterPresentation.names(for: .cortexM4))

        let previous = [DebugRegister(name: "r0", value: MIRawNumeric(raw: "0x1", numeric: 1))]
        let current = [
            DebugRegister(name: "r0", value: MIRawNumeric(raw: "0x2", numeric: 2)),
            DebugRegister(name: "r1", value: MIRawNumeric(raw: "0x0", numeric: 0))
        ]
        let rows = RegisterPresentation.rows(current: current, previous: previous)

        XCTAssertTrue(rows[0].hasChanged)
        XCTAssertEqual(rows[0].changeMarker, "已变化")
        XCTAssertTrue(rows[0].accessibilityValue.contains("已变化"))
        XCTAssertFalse(rows[1].hasChanged)
    }

    func testBoundedConsoleKeepsNewestEntriesAndSignalsTruncation() {
        var console = BoundedConsole(limit: 2)
        console.append(DebugConsoleEntry(channel: .console, text: "one"))
        console.append(DebugConsoleEntry(channel: .target, text: "two"))
        console.append(DebugConsoleEntry(channel: .stderr, text: "three"))

        XCTAssertEqual(console.entries.map(\.text), ["two", "three"])
        XCTAssertEqual(console.droppedCount, 1)
    }

    func testClosePolicyRequiresConfirmationOrBoundedDebuggerStop() {
        XCTAssertEqual(ClosePolicy.action(isDirty: true, state: .idle), .confirmUnsaved)
        XCTAssertEqual(ClosePolicy.action(isDirty: false, state: .running), .stopThenClose)
        XCTAssertEqual(ClosePolicy.action(isDirty: false, state: .stopped), .stopThenClose)
        XCTAssertEqual(ClosePolicy.action(isDirty: false, state: .ready), .allow)
    }
}
