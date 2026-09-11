// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

@MainActor
final class AppViewModelTests: XCTestCase {
    func testLatestOpenWinsWhenEarlierOpenCompletesLast() async throws {
        let fixture = try ViewModelFixture()
        let other = fixture.document(named: "other", text: "MOV r7, #7\n")
        let documents = ControlledDocumentService(documents: [fixture.document, other])
        let model = AppViewModel(
            documentService: documents,
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )

        let openingFirst = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        let openingSecond = Task { await model.open(other.sourceURL) }
        await documents.waitUntilOpenStarted(other.sourceURL)
        await documents.finishOpen(other.sourceURL)
        await openingSecond.value
        model.selectedRange = NSRange(location: 2, length: 0)
        await documents.finishOpen(fixture.document.sourceURL)
        await openingFirst.value

        XCTAssertEqual(model.document?.sourceURL, other.sourceURL)
        XCTAssertEqual(model.document?.text, other.text)
        XCTAssertEqual(model.selectedRange, NSRange(location: 2, length: 0))
    }

    func testSuccessfulNewOpenClearsPreviousSourceSelection() async throws {
        let fixture = try ViewModelFixture()
        let other = fixture.document(named: "other", text: "MOV r7, #7\n")
        let documents = ControlledDocumentService(documents: [fixture.document, other])
        let model = AppViewModel(
            documentService: documents,
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )
        let openingFirst = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        await documents.finishOpen(fixture.document.sourceURL)
        await openingFirst.value
        model.selectedRange = NSRange(location: 3, length: 0)

        let openingSecond = Task { await model.open(other.sourceURL) }
        await documents.waitUntilOpenStarted(other.sourceURL)
        await documents.finishOpen(other.sourceURL)
        await openingSecond.value

        XCTAssertEqual(model.document?.sourceURL, other.sourceURL)
        XCTAssertNil(model.selectedRange)
    }

    func testSaveCompletionAdvancesSnapshotBaselineWithoutOverwritingNewerEdit() async throws {
        let fixture = try ViewModelFixture()
        let documents = ControlledDocumentService(documents: [fixture.document])
        let model = AppViewModel(
            documentService: documents,
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )
        let opening = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        await documents.finishOpen(fixture.document.sourceURL)
        await opening.value
        model.edit("MOV r0, #1\n")

        let saving = Task { await model.save() }
        await documents.waitUntilSaveStarted(text: "MOV r0, #1\n")
        model.edit("MOV r0, #2\n")
        await documents.finishSave(text: "MOV r0, #1\n")
        await saving.value

        XCTAssertEqual(model.document?.text, "MOV r0, #2\n")
        XCTAssertTrue(model.document?.isDirty == true)
    }

    func testCloseInvalidatesOldSaveWhileLaterSaveCanCommit() async throws {
        let fixture = try ViewModelFixture()
        let documents = ControlledDocumentService(documents: [fixture.document])
        let model = AppViewModel(
            documentService: documents,
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )
        let opening = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        await documents.finishOpen(fixture.document.sourceURL)
        await opening.value
        model.edit("MOV r0, #1\n")
        let oldSave = Task { await model.save() }
        await documents.waitUntilSaveStarted(text: "MOV r0, #1\n")

        await model.close()
        model.edit("MOV r0, #2\n")
        let newSave = Task { await model.save() }
        await documents.waitUntilSaveStarted(text: "MOV r0, #2\n")
        await documents.finishSave(text: "MOV r0, #1\n")
        await oldSave.value

        XCTAssertEqual(model.document?.text, "MOV r0, #2\n")
        XCTAssertTrue(model.document?.isDirty == true)

        await documents.finishSave(text: "MOV r0, #2\n")
        await newSave.value
        XCTAssertEqual(model.document?.text, "MOV r0, #2\n")
        XCTAssertFalse(model.document?.isDirty ?? true)
    }

    func testAutosaveCompletionFromOldProjectCannotReplaceNewOpen() async throws {
        let fixture = try ViewModelFixture()
        let other = fixture.document(named: "other", text: "MOV r7, #7\n")
        let documents = ControlledDocumentService(documents: [fixture.document, other])
        let builds = ControlledBuildService()
        let model = AppViewModel(
            documentService: documents,
            buildService: builds,
            debugService: FakeDebugService()
        )
        let openingFirst = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        await documents.finishOpen(fixture.document.sourceURL)
        await openingFirst.value
        model.edit("MOV r0, #9\n")

        let openingSecond = Task { await model.open(other.sourceURL) }
        await documents.waitUntilOpenStarted(other.sourceURL)
        let building = Task { await model.build() }
        await documents.waitUntilSaveStarted(text: "MOV r0, #9\n")
        await documents.finishOpen(other.sourceURL)
        await openingSecond.value
        await documents.finishSave(text: "MOV r0, #9\n")
        try await Task.sleep(for: .milliseconds(10))
        let startedProjects = await builds.startedProjects()
        if !startedProjects.isEmpty {
            await builds.finish(fixture.buildResult)
        }
        await building.value

        XCTAssertEqual(model.document?.sourceURL, other.sourceURL)
        XCTAssertNil(model.latestBuild)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(startedProjects.isEmpty)
    }

    func testBuildResultFromOldProjectCannotOverwriteNewOpen() async throws {
        let fixture = try ViewModelFixture()
        let other = fixture.document(named: "other", text: "MOV r7, #7\n")
        let documents = ControlledDocumentService(documents: [fixture.document, other])
        let builds = ControlledBuildService()
        let model = AppViewModel(
            documentService: documents,
            buildService: builds,
            debugService: FakeDebugService()
        )
        let openingFirst = Task { await model.open(fixture.document.sourceURL) }
        await documents.waitUntilOpenStarted(fixture.document.sourceURL)
        await documents.finishOpen(fixture.document.sourceURL)
        await openingFirst.value

        let openingSecond = Task { await model.open(other.sourceURL) }
        await documents.waitUntilOpenStarted(other.sourceURL)
        let building = Task { await model.build() }
        await builds.waitUntilStarted(fixture.document.projectDirectory)
        await documents.finishOpen(other.sourceURL)
        await openingSecond.value
        await builds.finish(fixture.buildResult)
        await building.value

        XCTAssertEqual(model.document?.sourceURL, other.sourceURL)
        XCTAssertNil(model.latestBuild)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.errorMessage)
    }

    func testDirtyDocumentAutosavesBeforeBuildAndBecomesReady() async throws {
        let fixture = try ViewModelFixture()
        let recorder = CallRecorder()
        let documents = FakeDocumentService(document: fixture.document, recorder: recorder)
        let builds = FakeBuildService(result: fixture.buildResult, recorder: recorder)
        let debug = FakeDebugService()
        let model = AppViewModel(documentService: documents, buildService: builds, debugService: debug)
        await model.open(fixture.document.sourceURL)
        model.edit("MOV r0, #42\n")

        await model.build()

        let recordedCalls = await recorder.values()
        XCTAssertEqual(recordedCalls, ["open", "save", "build"])
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.document?.isDirty ?? true)
        XCTAssertEqual(model.latestBuild, fixture.buildResult)
        XCTAssertTrue(model.buildDiagnostics.isEmpty)
    }

    func testBuildFailureReturnsToIdleWithClickableDiagnostic() async throws {
        let fixture = try ViewModelFixture()
        let diagnostic = BuildDiagnostic(
            severity: .error,
            file: fixture.document.sourceURL,
            line: 2,
            column: 1,
            message: "bad instruction"
        )
        let failure = BuildServiceFailure(message: "构建失败", diagnostics: [diagnostic], output: "tool output")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(error: failure),
            debugService: FakeDebugService()
        )
        await model.open(fixture.document.sourceURL)

        await model.build()
        model.selectDiagnostic(diagnostic)

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.buildDiagnostics, [diagnostic])
        XCTAssertEqual(model.selectedRange, NSRange(location: 11, length: 0))
        XCTAssertTrue(model.errorMessage?.contains("构建失败") == true)
    }

    func testDebugEventsStepAndRegisterRefreshUpdatePresentation() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await debug.emit(.snapshot(fixture.snapshot(line: 1, r0: 1)))
        await waitUntil { model.snapshot?.registers.first?.value?.numeric == 1 }
        await debug.setStepSnapshot(fixture.snapshot(line: 2, r0: 2))

        await model.stepInstruction()
        await waitUntil { model.snapshot?.registers.first?.value?.numeric == 2 }

        XCTAssertEqual(model.state, .stopped)
        XCTAssertEqual(model.currentExecutionLine, 2)
        XCTAssertTrue(model.registerRows.first?.hasChanged == true)
        let debugCalls = await debug.calls()
        XCTAssertEqual(debugCalls, ["prepare", "launch:debug", "stepInstruction"])
    }

    func testDebugPreparationEntersLaunchingBeforeAwaitingBackendProbe() async throws {
        let fixture = try ViewModelFixture()
        let debug = SuspendedPrepareDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        let launch = Task { await model.start(.debug) }
        await debug.waitUntilPrepareStarted()

        XCTAssertEqual(model.state, .launching)
        XCTAssertFalse(model.isEnabled(.build))
        await debug.resumePrepare()
        await launch.value
    }

    func testBreakpointFailureRollsBackAndSurfacesDiagnostic() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        await debug.setBreakpointFailure(true)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }

        await model.toggleBreakpoint(line: 2)

        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        XCTAssertTrue(model.debugDiagnostics.contains { $0.message.contains("断点") })
    }

    func testBreakpointRemovalFailureRestoresExistingBreakpoint() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        await model.toggleBreakpoint(line: 2)
        await debug.setBreakpointFailure(false, removeFailure: true)

        await model.toggleBreakpoint(line: 2)

        XCTAssertEqual(model.breakpoints.lines, [2])
        XCTAssertTrue(model.debugDiagnostics.contains { $0.message.contains("断点") })
    }

    func testRapidBreakpointDoubleToggleRemovesSetThatCompletedAfterCancellation() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.suspendNextSet()

        let adding = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilSetStarted()
        let removing = Task { await model.toggleBreakpoint(line: 2) }
        await debug.resumeSet()
        await adding.value
        await removing.value

        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertTrue(remote.isEmpty)
        let calls = await debug.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("set:") || $0.hasPrefix("remove:") }.count, 2)
    }

    func testRapidBreakpointTripleToggleKeepsSingleRemoteBreakpoint() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.suspendNextSet()

        let first = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilSetStarted()
        let second = Task { await model.toggleBreakpoint(line: 2) }
        let third = Task { await model.toggleBreakpoint(line: 2) }
        await debug.resumeSet()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(model.breakpoints.lines, [2])
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remote.count, 1)
    }

    func testRemoveCompletingAfterReAddDoesNotLoseNewRemoteIdentifier() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await model.toggleBreakpoint(line: 2)
        await debug.suspendNextRemove()

        let removing = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilRemoveStarted()
        let readding = Task { await model.toggleBreakpoint(line: 2) }
        await debug.resumeRemove()
        await removing.value
        await readding.value

        XCTAssertEqual(model.breakpoints.lines, [2])
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remote.count, 1)

        await model.toggleBreakpoint(line: 2)
        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        let afterFinalRemove = await debug.remoteBreakpointIDs()
        XCTAssertTrue(afterFinalRemove.isEmpty)
    }

    func testBreakpointSetAndRemoveFailuresRollbackToActualRemoteState() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.failNextSet()

        await model.toggleBreakpoint(line: 2)

        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        let afterSetFailure = await debug.remoteBreakpointIDs()
        XCTAssertTrue(afterSetFailure.isEmpty)

        await model.toggleBreakpoint(line: 2)
        await debug.failNextRemove()
        await model.toggleBreakpoint(line: 2)

        XCTAssertEqual(model.breakpoints.lines, [2])
        let afterRemoveFailure = await debug.remoteBreakpointIDs()
        XCTAssertEqual(afterRemoveFailure.count, 1)
    }

    func testBreakpointReconcilesAcrossStopAndSessionRestartWithoutHiddenRemote() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await model.toggleBreakpoint(line: 2)
        let firstRemote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(firstRemote.count, 1)

        await model.stop()
        let afterStop = await debug.remoteBreakpointIDs()
        XCTAssertTrue(afterStop.isEmpty)
        await model.start(.debug)
        await waitUntil { model.state == .stopped }

        XCTAssertEqual(model.breakpoints.lines, [2])
        let secondRemote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(secondRemote.count, 1)
        XCTAssertNotEqual(firstRemote, secondRemote)

        await model.toggleBreakpoint(line: 2)
        let finalRemote = await debug.remoteBreakpointIDs()
        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        XCTAssertTrue(finalRemote.isEmpty)
    }

    func testFailedSetFromStoppedSessionCannotRollbackRestartedSessionBreakpoint() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.suspendNextSet()
        await debug.failNextSet()
        let oldSet = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilSetStarted()

        await model.stop()
        await model.start(.debug)
        await waitUntil { model.state == .stopped }
        await debug.resumeSet()
        await oldSet.value

        XCTAssertEqual(model.breakpoints.lines, [2])
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remote.count, 1)
    }

    func testSetCompletingAfterResumeKeepsLocalAndRemoteStateConsistent() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.suspendNextSet()
        let adding = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilSetStarted()
        await debug.emitState(.running)
        await waitUntil { model.state == .running }

        await debug.resumeSet()
        await adding.value

        XCTAssertEqual(model.breakpoints.lines, [2])
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remote.count, 1)
        await model.stop()
    }

    func testRemoveCompletingAfterReAddAndResumeRollsBackToActualRemoteState() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await model.toggleBreakpoint(line: 2)
        await debug.suspendNextRemove()
        let removing = Task { await model.toggleBreakpoint(line: 2) }
        await debug.waitUntilRemoveStarted()
        let readding = Task { await model.toggleBreakpoint(line: 2) }
        await debug.emitState(.running)
        await waitUntil { model.state == .running }

        await debug.resumeRemove()
        await removing.value
        await readding.value

        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        let remote = await debug.remoteBreakpointIDs()
        XCTAssertTrue(remote.isEmpty)
        await model.stop()
    }

    func testPrelaunchBreakpointsSynchronizeOnEverySessionAndRemovalUsesCurrentRemoteID() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        await debug.setEmitStoppedOnLaunch(true)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.toggleBreakpoint(line: 1)
        await model.toggleBreakpoint(line: 2)
        await model.build()

        await model.start(.debug)
        await waitUntil { model.state == .stopped }
        await model.stop()
        await model.start(.debug)
        await waitUntil { model.state == .stopped }
        await model.toggleBreakpoint(line: 2)

        let calls = await debug.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("setBreakpoint:") }, [
            "setBreakpoint:1", "setBreakpoint:2",
            "setBreakpoint:1", "setBreakpoint:2"
        ])
        XCTAssertTrue(calls.contains("removeBreakpoint:session-2-line-2"))
        XCTAssertEqual(model.breakpoints.lines, [1])
    }

    func testPrelaunchBreakpointFailureRollsBackOnlyFailedLine() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        await debug.setEmitStoppedOnLaunch(true)
        await debug.setBreakpointFailureLines([2])
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.toggleBreakpoint(line: 1)
        await model.toggleBreakpoint(line: 2)
        await model.build()

        await model.start(.debug)
        await waitUntil { model.state == .stopped }

        XCTAssertEqual(model.breakpoints.lines, [1])
        XCTAssertTrue(model.debugDiagnostics.contains {
            $0.message.contains("第 2 行") && $0.message.contains("已恢复")
        })
    }

    func testStopTimeoutStaysTerminatingUntilBackendActuallyFinishes() async throws {
        let fixture = try ViewModelFixture()
        let debug = SuspendedStopDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug,
            stopTimeout: .milliseconds(20)
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }

        await model.stop()

        XCTAssertEqual(model.state, .terminating)
        XCTAssertFalse(model.isEnabled(.build))
        XCTAssertTrue(model.errorMessage?.contains("后台清理") == true)
        await debug.finishStop()
        await waitUntil { model.state == .ready }
    }

    func testCloseDoesNotFinishBeforeSuspendedDebuggerCleanup() async throws {
        let fixture = try ViewModelFixture()
        let debug = SuspendedStopDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug,
            stopTimeout: .milliseconds(20)
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        let completion = CompletionProbe()

        let closing = Task {
            await model.close()
            await completion.finish()
        }
        await debug.waitUntilStopStarted()
        try await Task.sleep(for: .milliseconds(40))

        let finishedBeforeCleanup = await completion.isFinished()
        XCTAssertFalse(finishedBeforeCleanup)
        XCTAssertEqual(model.state, .terminating)
        await debug.finishStop()
        await closing.value
        let finishedAfterCleanup = await completion.isFinished()
        XCTAssertTrue(finishedAfterCleanup)
        XCTAssertEqual(model.state, .ready)
    }

    func testRuntimeDerivedStateClearsAcrossRunningStopBuildAndProfileChange() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await debug.emit(.snapshot(fixture.snapshot(line: 1, r0: 1)))
        await waitUntil { model.snapshot != nil }

        await debug.emit(.stateChanged(.running))
        await waitUntil { model.state == .running }
        XCTAssertNil(model.currentExecutionLine)

        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        await model.stop()
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.registerRows.isEmpty)
        XCTAssertTrue(model.memory.isEmpty)

        await model.build()
        model.changeProfile(to: .cortexM4)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.registerRows.contains { $0.name == "CPSR" })
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testLaunchFailureDoesNotAllowLateSnapshotToRepopulateDerivedState() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        await debug.setLaunchFailure(snapshotBeforeFailure: fixture.snapshot(line: 1, r0: 1))
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        await model.start(.debug)
        await Task.yield()

        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.registerRows.isEmpty)
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testCriticalUnexpectedExitDiagnosticStaysVisibleAfterRecoveryToReady() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }

        await debug.emit(.diagnostic(DebugDiagnostic(
            pane: .session,
            isCritical: true,
            message: "测试调试器意外退出"
        )))
        await debug.emit(.stateChanged(.terminating))
        await debug.emit(.stateChanged(.ready))
        await waitUntil { model.state == .ready }

        XCTAssertEqual(model.errorMessage, "测试调试器意外退出")
        XCTAssertTrue(model.isEnabled(.build))
        XCTAssertNil(model.snapshot)
    }

    func testBuildLifecycleIgnoresDebuggerSnapshotAndLeavesDerivedStateClear() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let build = SuspendedBuildService(result: fixture.buildResult)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: build,
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        let building = Task { await model.build() }
        await build.waitUntilStarted()

        await debug.emit(.snapshot(fixture.snapshot(line: 1, r0: 1)))
        await Task.yield()
        XCTAssertEqual(model.state, .building)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.registerRows.isEmpty)

        await build.finish()
        await building.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testMemoryValidationRecoveryAndCloseStopAreBounded() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug,
            stopTimeout: .milliseconds(200)
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.run)
        await debug.emit(.stateChanged(.running))
        await waitUntil { model.state == .running }

        await model.readMemory(address: "unsafe", length: "10")
        XCTAssertTrue(model.errorMessage?.contains("内存地址") == true)
        let memoryRequests = await debug.memoryRequests()
        XCTAssertEqual(memoryRequests, [])

        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        await model.readMemory(address: "0x2000_1000", length: "16")
        let validRequests = await debug.memoryRequests()
        XCTAssertEqual(validRequests, [DebugMemoryRequest(address: "0x20001000", byteCount: 16)])

        await model.close()

        XCTAssertEqual(model.state, .ready)
        let closeCalls = await debug.calls()
        XCTAssertTrue(closeCalls.contains("stop"))
    }

    func testProfileSwitchUpdatesDocumentOnlyWhenSessionInactive() async throws {
        let fixture = try ViewModelFixture()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )
        await model.open(fixture.document.sourceURL)

        model.changeProfile(to: .cortexM4)

        XCTAssertEqual(model.document?.configuration.profile, .cortexM4)
        XCTAssertTrue(model.document?.isDirty == true)
        XCTAssertEqual(model.state, .idle)
    }

    private func stoppedModel(
        fixture: ViewModelFixture,
        debug: ControlledBreakpointDebugService
    ) async throws -> AppViewModel {
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        await waitUntil { model.state == .stopped }
        return model
    }
}

private actor CallRecorder {
    private var calls: [String] = []
    func append(_ call: String) { calls.append(call) }
    func values() -> [String] { calls }
}

private actor FakeDocumentService: DocumentServicing {
    private let loadedDocument: WorkspaceDocument
    private let recorder: CallRecorder?

    init(document: WorkspaceDocument, recorder: CallRecorder? = nil) {
        loadedDocument = document
        self.recorder = recorder
    }

    func open(_ url: URL) async throws -> WorkspaceDocument {
        await recorder?.append("open")
        return loadedDocument
    }

    func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument {
        await recorder?.append("save")
        return WorkspaceDocument(
            projectDirectory: document.projectDirectory,
            sourceURL: document.sourceURL,
            configuration: document.configuration,
            text: document.text
        )
    }
}

private actor ControlledDocumentService: DocumentServicing {
    private let documents: [String: WorkspaceDocument]
    private var openContinuations: [String: CheckedContinuation<WorkspaceDocument, Error>] = [:]
    private var openWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var saveContinuations: [String: CheckedContinuation<WorkspaceDocument, Error>] = [:]
    private var saveWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var saveSnapshots: [String: WorkspaceDocument] = [:]

    init(documents: [WorkspaceDocument]) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.sourceURL.path, $0) })
    }

    func open(_ url: URL) async throws -> WorkspaceDocument {
        let key = url.standardizedFileURL.path
        openWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { openContinuations[key] = $0 }
    }

    func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument {
        let key = document.text
        saveSnapshots[key] = document
        saveWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { saveContinuations[key] = $0 }
    }

    func waitUntilOpenStarted(_ url: URL) async {
        let key = url.standardizedFileURL.path
        if openContinuations[key] != nil { return }
        await withCheckedContinuation { openWaiters[key, default: []].append($0) }
    }

    func finishOpen(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard let continuation = openContinuations.removeValue(forKey: key),
              let document = documents[key] else { return }
        continuation.resume(returning: document)
    }

    func waitUntilSaveStarted(text: String) async {
        if saveContinuations[text] != nil { return }
        await withCheckedContinuation { saveWaiters[text, default: []].append($0) }
    }

    func finishSave(text: String) {
        guard let continuation = saveContinuations.removeValue(forKey: text),
              let snapshot = saveSnapshots[text] else { return }
        continuation.resume(returning: snapshot.markingSaved())
    }
}

private actor FakeBuildService: BuildServicing {
    private let result: AppBuildResult?
    private let error: (any Error & Sendable)?
    private let recorder: CallRecorder?

    init(
        result: AppBuildResult? = nil,
        error: (any Error & Sendable)? = nil,
        recorder: CallRecorder? = nil
    ) {
        self.result = result
        self.error = error
        self.recorder = recorder
    }

    func build(projectDirectory: URL) async throws -> AppBuildResult {
        await recorder?.append("build")
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}

private actor SuspendedBuildService: BuildServicing {
    private let result: AppBuildResult
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var buildContinuation: CheckedContinuation<Void, Never>?

    init(result: AppBuildResult) {
        self.result = result
    }

    func build(projectDirectory: URL) async throws -> AppBuildResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { buildContinuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        buildContinuation?.resume()
        buildContinuation = nil
    }
}

private actor ControlledBuildService: BuildServicing {
    private var continuation: CheckedContinuation<AppBuildResult, Error>?
    private var started: [URL] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func build(projectDirectory: URL) async throws -> AppBuildResult {
        started.append(projectDirectory.standardizedFileURL)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted(_ projectDirectory: URL) async {
        let expected = projectDirectory.standardizedFileURL
        if started.contains(expected) { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ result: AppBuildResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func startedProjects() -> [URL] { started }
}

private actor ControlledBreakpointDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let continuation: AsyncStream<DebuggerEvent>.Continuation
    private var recordedCalls: [String] = []
    private var remoteIdentifiers: Set<String> = []
    private var session = 0
    private var nextIdentifier = 0
    private var shouldSuspendSet = false
    private var shouldSuspendRemove = false
    private var shouldFailSet = false
    private var shouldFailRemove = false
    private var setStarted = false
    private var removeStarted = false
    private var setStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var removeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var setContinuation: CheckedContinuation<Void, Never>?
    private var removeContinuation: CheckedContinuation<Void, Never>?

    init() {
        let pair = AsyncStream<DebuggerEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws {}

    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        session += 1
        remoteIdentifiers.removeAll()
        var identifiers: [Int: String] = [:]
        for breakpoint in breakpoints {
            let identifier = makeIdentifier(line: breakpoint.line)
            remoteIdentifiers.insert(identifier)
            identifiers[breakpoint.line] = identifier
        }
        continuation.yield(.stateChanged(.stopped))
        if mode == .run { continuation.yield(.stateChanged(.running)) }
        return DebugLaunchResult(breakpointIdentifiers: identifiers)
    }

    func pause() async throws { continuation.yield(.stateChanged(.stopped)) }
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws { continuation.yield(.stateChanged(.running)) }
    func stop() async throws {
        remoteIdentifiers.removeAll()
        continuation.yield(.stateChanged(.terminating))
        continuation.yield(.stateChanged(.ready))
    }
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }

    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        let identifier = makeIdentifier(line: line)
        recordedCalls.append("set:\(identifier)")
        remoteIdentifiers.insert(identifier)
        if shouldSuspendSet {
            shouldSuspendSet = false
            setStarted = true
            setStartWaiters.forEach { $0.resume() }
            setStartWaiters.removeAll()
            await withCheckedContinuation { setContinuation = $0 }
        }
        if shouldFailSet {
            shouldFailSet = false
            remoteIdentifiers.remove(identifier)
            throw FakeFailure.breakpoint
        }
        return DebugBreakpoint(id: identifier, location: "\(file.path):\(line)")
    }

    func removeBreakpoint(identifier: String) async throws {
        recordedCalls.append("remove:\(identifier)")
        if shouldSuspendRemove {
            shouldSuspendRemove = false
            removeStarted = true
            removeStartWaiters.forEach { $0.resume() }
            removeStartWaiters.removeAll()
            await withCheckedContinuation { removeContinuation = $0 }
        }
        if shouldFailRemove {
            shouldFailRemove = false
            throw FakeFailure.breakpoint
        }
        remoteIdentifiers.remove(identifier)
    }

    func suspendNextSet() { shouldSuspendSet = true }
    func suspendNextRemove() { shouldSuspendRemove = true }
    func failNextSet() { shouldFailSet = true }
    func failNextRemove() { shouldFailRemove = true }

    func waitUntilSetStarted() async {
        if setStarted { return }
        await withCheckedContinuation { setStartWaiters.append($0) }
    }

    func waitUntilRemoveStarted() async {
        if removeStarted { return }
        await withCheckedContinuation { removeStartWaiters.append($0) }
    }

    func resumeSet() {
        setContinuation?.resume()
        setContinuation = nil
    }

    func resumeRemove() {
        removeContinuation?.resume()
        removeContinuation = nil
    }

    func remoteBreakpointIDs() -> Set<String> { remoteIdentifiers }
    func calls() -> [String] { recordedCalls }
    func emitState(_ state: DebuggerState) { continuation.yield(.stateChanged(state)) }

    private func makeIdentifier(line: Int) -> String {
        nextIdentifier += 1
        return "session-\(session)-line-\(line)-id-\(nextIdentifier)"
    }
}

private actor FakeDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let continuation: AsyncStream<DebuggerEvent>.Continuation
    private var recordedCalls: [String] = []
    private var requests: [DebugMemoryRequest] = []
    private var shouldFailBreakpoint = false
    private var shouldFailBreakpointRemoval = false
    private var breakpointFailureLines: Set<Int> = []
    private var emitStoppedOnLaunch = false
    private var launchCount = 0
    private var stepSnapshot: DebugSnapshot?
    private var launchFailureSnapshot: DebugSnapshot?

    init() {
        let pair = AsyncStream<DebuggerEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws { recordedCalls.append("prepare") }
    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        launchCount += 1
        recordedCalls.append("launch:\(mode.rawValue)")
        if let launchFailureSnapshot {
            continuation.yield(.snapshot(launchFailureSnapshot))
            await Task.yield()
            throw FakeFailure.launch
        }
        if emitStoppedOnLaunch { continuation.yield(.stateChanged(.stopped)) }
        var identifiers: [Int: String] = [:]
        var failures: [DebugBreakpointSyncFailure] = []
        for breakpoint in breakpoints {
            recordedCalls.append("setBreakpoint:\(breakpoint.line)")
            if shouldFailBreakpoint || breakpointFailureLines.contains(breakpoint.line) {
                failures.append(DebugBreakpointSyncFailure(
                    breakpoint: breakpoint,
                    message: FakeFailure.breakpoint.localizedDescription
                ))
            } else {
                identifiers[breakpoint.line] = "session-\(launchCount)-line-\(breakpoint.line)"
            }
        }
        if mode == .run, emitStoppedOnLaunch { continuation.yield(.stateChanged(.running)) }
        return DebugLaunchResult(
            breakpointIdentifiers: identifiers,
            failures: failures
        )
    }
    func pause() async throws { recordedCalls.append("pause") }
    func stepInstruction() async throws {
        recordedCalls.append("stepInstruction")
        if let stepSnapshot { continuation.yield(.snapshot(stepSnapshot)) }
    }
    func stepOver() async throws { recordedCalls.append("stepOver") }
    func resume() async throws { recordedCalls.append("continue") }
    func stop() async throws { recordedCalls.append("stop") }
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        requests.append(request)
        return []
    }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        recordedCalls.append("setBreakpoint:\(line)")
        if shouldFailBreakpoint || breakpointFailureLines.contains(line) { throw FakeFailure.breakpoint }
        return DebugBreakpoint(
            id: "session-\(launchCount)-line-\(line)",
            location: "\(file.path):\(line)"
        )
    }
    func removeBreakpoint(identifier: String) async throws {
        recordedCalls.append("removeBreakpoint:\(identifier)")
        if shouldFailBreakpointRemoval { throw FakeFailure.breakpoint }
    }

    func emit(_ event: DebuggerEvent) { continuation.yield(event) }
    func calls() -> [String] { recordedCalls }
    func memoryRequests() -> [DebugMemoryRequest] { requests }
    func setBreakpointFailure(_ value: Bool, removeFailure: Bool = false) {
        shouldFailBreakpoint = value
        shouldFailBreakpointRemoval = removeFailure
    }
    func setBreakpointFailureLines(_ lines: Set<Int>) { breakpointFailureLines = lines }
    func setEmitStoppedOnLaunch(_ value: Bool) { emitStoppedOnLaunch = value }
    func setStepSnapshot(_ snapshot: DebugSnapshot) { stepSnapshot = snapshot }
    func setLaunchFailure(snapshotBeforeFailure: DebugSnapshot) {
        launchFailureSnapshot = snapshotBeforeFailure
    }
}

private actor SuspendedStopDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let continuation: AsyncStream<DebuggerEvent>.Continuation
    private var stopStarted = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init() {
        let pair = AsyncStream<DebuggerEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws {}
    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult { DebugLaunchResult() }
    func pause() async throws {}
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws {}
    func stop() async throws {
        stopStarted = true
        stopWaiters.forEach { $0.resume() }
        stopWaiters.removeAll()
        await withCheckedContinuation { stopContinuation = $0 }
    }
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "\(line)", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}
    func emit(_ event: DebuggerEvent) { continuation.yield(event) }
    func waitUntilStopStarted() async {
        if stopStarted { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor CompletionProbe {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}

private enum FakeFailure: Error, Sendable {
    case breakpoint
    case launch
}

private actor SuspendedPrepareDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private var prepareStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareContinuation: CheckedContinuation<Void, Never>?

    init() {
        stream = AsyncStream { _ in }
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws {
        prepareStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { prepareContinuation = $0 }
    }
    func waitUntilPrepareStarted() async {
        if prepareStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumePrepare() { prepareContinuation?.resume(); prepareContinuation = nil }
    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult { DebugLaunchResult() }
    func pause() async throws {}
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws {}
    func stop() async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "1", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}
}

private struct ViewModelFixture {
    let directory: URL
    let document: WorkspaceDocument
    let buildResult: AppBuildResult

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UI 测试 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("main.s")
        try Data("MOV r0, #1\nBAD\n".utf8).write(to: source)
        let configuration = ProjectConfiguration(sources: ["main.s"], outputName: "demo")
        document = WorkspaceDocument(
            projectDirectory: directory,
            sourceURL: source,
            configuration: configuration,
            text: "MOV r0, #1\nBAD\n"
        )
        buildResult = AppBuildResult(
            configuration: configuration,
            projectDirectory: directory,
            elf: directory.appendingPathComponent("demo.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
    }

    func snapshot(line: UInt64, r0: UInt64) -> DebugSnapshot {
        DebugSnapshot(
            stopReason: .endSteppingRange,
            location: MIFrame(
                address: MIRawNumeric(raw: "0x100", numeric: 0x100),
                function: "start",
                file: "main.s",
                fullName: document.sourceURL.path,
                line: MIRawNumeric(raw: "\(line)", numeric: line)
            ),
            registers: [DebugRegister(name: "r0", value: MIRawNumeric(raw: "0x\(String(r0, radix: 16))", numeric: r0))],
            stack: [],
            memory: [],
            disassembly: [],
            console: [],
            diagnostics: []
        )
    }

    func document(named name: String, text: String) -> WorkspaceDocument {
        let project = directory.deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        return WorkspaceDocument(
            projectDirectory: project,
            sourceURL: project.appendingPathComponent("main.s"),
            configuration: ProjectConfiguration(sources: ["main.s"], outputName: name),
            text: text
        )
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
    }
    XCTAssertTrue(condition())
}
