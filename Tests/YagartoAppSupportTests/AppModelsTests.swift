// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class AppModelsTests: XCTestCase {
    func testMemoryWindowControlManualEditSubmissionAndSuccess() throws {
        var state = MemoryWindowControlState()

        state.edit("0x9000")
        let submission = try state.beginSubmission(state.editableAddressText)

        XCTAssertEqual(submission.normalizedAddress, "0x00009000")
        XCTAssertEqual(state.editableAddressText, "0x00009000")
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)

        state.completeSuccess(token: submission.token, normalized: submission.normalizedAddress)

        XCTAssertEqual(state.confirmedBaseAddress, 0x9000)
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.editableAddressText, "0x00009000")
    }

    func testMemoryWindowControlConsecutiveStepsUsePendingDisplayedBase() throws {
        var state = MemoryWindowControlState()

        let first = try state.step(byRows: 1)
        let second = try state.step(byRows: 1)

        XCTAssertEqual(first.normalizedAddress, "0x00008010")
        XCTAssertEqual(second.normalizedAddress, "0x00008020")
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(state.displayedBaseAddress, 0x8020)
        XCTAssertEqual(state.confirmedBaseAddress, 0x8000)

        state.completeSuccess(token: first.token, normalized: first.normalizedAddress)
        XCTAssertEqual(state.confirmedBaseAddress, 0x8000)
        XCTAssertEqual(state.displayedBaseAddress, 0x8020)

        state.completeSuccess(token: second.token, normalized: second.normalizedAddress)
        XCTAssertEqual(state.confirmedBaseAddress, 0x8020)
    }

    func testMemoryWindowControlCurrentFailureRollsBackConfirmedAddress() throws {
        var state = MemoryWindowControlState()
        let submission = try state.beginSubmission("0x9000")

        state.completeFailure(token: submission.token)

        XCTAssertEqual(state.editableAddressText, MemoryWindowLayout.defaultAddressText)
        XCTAssertEqual(state.displayedBaseAddress, MemoryWindowLayout.defaultAddress)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)
    }

    func testMemoryWindowControlIgnoresMismatchedSuccessAddress() throws {
        var state = MemoryWindowControlState()
        let submission = try state.beginSubmission("0x9000")

        state.completeSuccess(token: submission.token, normalized: "0xA000")

        XCTAssertEqual(state.editableAddressText, "0x00009000")
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)

        state.completeSuccess(token: submission.token, normalized: submission.normalizedAddress)
        XCTAssertEqual(state.confirmedBaseAddress, 0x9000)
    }

    func testMemoryWindowControlEditPreservesTextWhilePendingCompletionUpdatesBaseline() throws {
        var state = MemoryWindowControlState()
        let pending = try state.beginSubmission("0x9000")

        state.edit("0xA000")
        state.completeSuccess(token: pending.token, normalized: pending.normalizedAddress)

        XCTAssertEqual(state.editableAddressText, "0xA000")
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.confirmedBaseAddress, 0x9000)

        let newer = try state.beginSubmission(state.editableAddressText)
        state.completeFailure(token: newer.token)

        XCTAssertEqual(state.editableAddressText, "0x00009000")
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.confirmedBaseAddress, 0x9000)
    }

    func testMemoryWindowControlInvalidSubmissionInvalidatesPendingCompletion() throws {
        var state = MemoryWindowControlState()
        let pending = try state.beginSubmission("0x9000")

        XCTAssertThrowsError(try state.beginSubmission("invalid"))
        state.completeSuccess(token: pending.token, normalized: pending.normalizedAddress)
        state.completeFailure(token: pending.token)

        XCTAssertEqual(state.editableAddressText, "0x00009000")
        XCTAssertEqual(state.displayedBaseAddress, 0x9000)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)
    }

    func testMemoryWindowControlNewSubmissionFullySupersedesOlderCompletion() throws {
        var state = MemoryWindowControlState()
        let older = try state.beginSubmission("0x9000")
        let newer = try state.beginSubmission("0xA000")

        state.completeSuccess(token: older.token, normalized: older.normalizedAddress)

        XCTAssertEqual(state.editableAddressText, "0x0000A000")
        XCTAssertEqual(state.displayedBaseAddress, 0xA000)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)

        state.completeSuccess(token: newer.token, normalized: newer.normalizedAddress)
        XCTAssertEqual(state.confirmedBaseAddress, 0xA000)
    }

    func testMemoryWindowControlResetInvalidatesOldSubmissionAndRestoresDefault() throws {
        var state = MemoryWindowControlState()
        let submission = try state.beginSubmission("0x9000")

        state.reset()
        state.completeSuccess(token: submission.token, normalized: submission.normalizedAddress)
        state.completeFailure(token: submission.token)

        XCTAssertEqual(state.editableAddressText, MemoryWindowLayout.defaultAddressText)
        XCTAssertEqual(state.displayedBaseAddress, MemoryWindowLayout.defaultAddress)
        XCTAssertEqual(state.confirmedBaseAddress, MemoryWindowLayout.defaultAddress)
    }

    func testMemoryWindowControlRejectsUnderflowAndOverflowWithoutMutation() throws {
        var lower = MemoryWindowControlState()
        let zero = try lower.beginSubmission("0x0")
        lower.completeSuccess(token: zero.token, normalized: zero.normalizedAddress)

        XCTAssertThrowsError(try lower.step(byRows: -1))
        XCTAssertEqual(lower.editableAddressText, "0x00000000")
        XCTAssertEqual(lower.displayedBaseAddress, 0)
        XCTAssertEqual(lower.confirmedBaseAddress, 0)

        var upper = MemoryWindowControlState()
        let maximum = try upper.beginSubmission("0xFFFFFFFFFFFFFF90")
        upper.completeSuccess(token: maximum.token, normalized: maximum.normalizedAddress)

        XCTAssertThrowsError(try upper.step(byRows: 1))
        XCTAssertEqual(upper.editableAddressText, "0xFFFFFFFFFFFFFF90")
        XCTAssertEqual(upper.displayedBaseAddress, 0xFFFFFFFFFFFFFF90)
        XCTAssertEqual(upper.confirmedBaseAddress, 0xFFFFFFFFFFFFFF90)
    }

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
        XCTAssertTrue(AppCommandAvailability.isEnabled(.newProject, state: .idle, hasDocument: false, isDirty: false))
        XCTAssertTrue(AppCommandAvailability.isEnabled(.importProjects, state: .ready, hasDocument: true, isDirty: false))
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
            XCTAssertFalse(AppCommandAvailability.isEnabled(.newProject, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.importProjects, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.build, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.changeProfile, state: state, hasDocument: true, isDirty: false))
            XCTAssertFalse(AppCommandAvailability.isEnabled(.edit, state: state, hasDocument: true, isDirty: false))
        }
        XCTAssertFalse(AppCommandAvailability.isEnabled(
            .newProject,
            state: .idle,
            hasDocument: false,
            isDirty: false,
            isProjectOperationInProgress: true
        ))
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
        XCTAssertEqual(
            ClosePolicy.action(
                isDirty: false,
                state: .idle,
                isProjectOperationInProgress: true
            ),
            .denyProjectOperation
        )
    }

    func testRememberedCreationProfileWinsUntilAProjectOpenUpdatesIt() {
        XCTAssertEqual(
            ProjectProfilePreference.selected(lastRawValue: "cortex-m4", current: .arm7tdmi),
            .cortexM4
        )
        XCTAssertEqual(
            ProjectProfilePreference.selected(lastRawValue: "invalid", current: .stm32f4Discovery),
            .stm32f4Discovery
        )
        XCTAssertEqual(ProjectProfilePreference.selected(lastRawValue: "invalid", current: nil), .arm7tdmi)
    }
}
