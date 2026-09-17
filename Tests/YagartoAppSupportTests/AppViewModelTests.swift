// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

@MainActor
final class AppViewModelTests: XCTestCase {
    func testDocumentInstanceIDChangesOnlyWhenSamePathDocumentIsReinstalled() async throws {
        let fixture = try ViewModelFixture()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService()
        )

        XCTAssertNil(model.documentInstanceID)
        await model.open(fixture.document.sourceURL)
        let firstInstanceID = try XCTUnwrap(model.documentInstanceID)

        model.edit("MOV r0, #1\n")
        XCTAssertEqual(model.documentInstanceID, firstInstanceID)
        await model.save()
        XCTAssertEqual(model.documentInstanceID, firstInstanceID)
        model.changeProfile(to: .cortexM4)
        XCTAssertEqual(model.documentInstanceID, firstInstanceID)

        await model.open(fixture.document.sourceURL)

        XCTAssertEqual(model.document?.sourceURL, fixture.document.sourceURL)
        XCTAssertNotEqual(model.documentInstanceID, firstInstanceID)
    }

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

    func testBreakpointAddedWhileRunningSynchronizesOnNextStop() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emitState(.running)
        await waitUntil { model.state == .running }

        await model.toggleBreakpoint(line: 2)
        XCTAssertEqual(model.breakpoints.lines, [2])
        let remoteBeforeStop = await debug.remoteBreakpointIDs()
        XCTAssertTrue(remoteBeforeStop.isEmpty)

        await debug.emitState(.stopped)
        await waitUntilRemoteBreakpoints(debug, count: 1)

        XCTAssertEqual(model.state, .stopped)
        XCTAssertEqual(model.breakpoints.lines, [2])
    }

    func testBreakpointRemovedWhileRunningSynchronizesOnNextStop() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await model.toggleBreakpoint(line: 2)
        let initialRemote = await debug.remoteBreakpointIDs()
        XCTAssertEqual(initialRemote.count, 1)
        await debug.emitState(.running)
        await waitUntil { model.state == .running }

        await model.toggleBreakpoint(line: 2)
        XCTAssertTrue(model.breakpoints.lines.isEmpty)
        let remoteBeforeStop = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remoteBeforeStop.count, 1)

        await debug.emitState(.stopped)
        await waitUntilRemoteBreakpoints(debug, count: 0)

        XCTAssertEqual(model.state, .stopped)
        XCTAssertTrue(model.breakpoints.lines.isEmpty)
    }

    func testDeferredBreakpointSetFailureRollsBackVisibleStateAndUserRetryAdds() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emitState(.running)
        await waitUntil { model.state == .running }
        await model.toggleBreakpoint(line: 2)
        await debug.failNextSet()

        await debug.emitState(.stopped)
        await waitUntil { !model.debugDiagnostics.isEmpty }

        XCTAssertTrue(model.breakpoints.lines.isEmpty, "设置失败后不能显示远端并不存在的断点")
        let remoteAfterFailure = await debug.remoteBreakpointIDs()
        XCTAssertTrue(remoteAfterFailure.isEmpty)
        XCTAssertTrue(model.debugDiagnostics.contains { $0.message.contains("断点") })

        await model.toggleBreakpoint(line: 2)
        await waitUntilRemoteBreakpoints(debug, count: 1)

        XCTAssertEqual(model.breakpoints.lines, [2])
    }

    func testDeferredBreakpointRemovalFailureRestoresVisibleRemoteStateAndUserRetryRemoves() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledBreakpointDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await model.toggleBreakpoint(line: 2)
        await debug.emitState(.running)
        await waitUntil { model.state == .running }
        await model.toggleBreakpoint(line: 2)
        await debug.failNextRemove()

        await debug.emitState(.stopped)
        await waitUntil { !model.debugDiagnostics.isEmpty }

        XCTAssertEqual(model.breakpoints.lines, [2], "删除失败后必须继续显示实际仍存在的远端断点")
        let remoteAfterFailure = await debug.remoteBreakpointIDs()
        XCTAssertEqual(remoteAfterFailure.count, 1)
        XCTAssertTrue(model.debugDiagnostics.contains { $0.message.contains("断点") })

        await model.toggleBreakpoint(line: 2)
        await waitUntilRemoteBreakpoints(debug, count: 0)

        XCTAssertTrue(model.breakpoints.lines.isEmpty)
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

    func testRetiredPrepareFailureCannotMutateNewLaunchGeneration() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledStartDebugService(suspendsLaunch: true)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        let firstStart = Task { await model.start(.debug) }
        await debug.waitUntilPrepareStarted(1)
        await model.stop()

        let secondStart = Task { await model.start(.debug) }
        await debug.waitUntilPrepareStarted(2)
        await debug.finishPrepare(2)
        await debug.waitUntilLaunchStarted(1)

        await debug.failPrepare(1)
        await firstStart.value

        XCTAssertEqual(model.state, .launching)
        XCTAssertNil(model.errorMessage)
        let launchesWhileSecondIsSuspended = await debug.launchCallCount()
        XCTAssertEqual(launchesWhileSecondIsSuspended, 1, "已退役的 A 不得进入 launch")

        await debug.finishLaunch(1)
        await secondStart.value

        XCTAssertEqual(model.state, .stopped)
        XCTAssertNil(model.errorMessage)
    }

    func testRetiredSuccessfulPrepareDoesNotCallLaunch() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledStartDebugService(suspendsLaunch: false)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        let start = Task { await model.start(.debug) }
        await debug.waitUntilPrepareStarted(1)
        await model.stop()
        await debug.finishPrepare(1)
        await start.value

        let launchCount = await debug.launchCallCount()
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.errorMessage)
    }

    func testCurrentStartFailureStillReturnsToReadyWithError() async throws {
        let fixture = try ViewModelFixture()
        let debug = ControlledStartDebugService(suspendsLaunch: false)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        let start = Task { await model.start(.debug) }
        await debug.waitUntilPrepareStarted(1)
        await debug.failPrepare(1)
        await start.value

        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.errorMessage)
        let launchCount = await debug.launchCallCount()
        XCTAssertEqual(launchCount, 0)
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
        let block = fixture.memoryBlock(begin: "0x8000", contents: "01020304")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: build,
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        let building = Task { await model.build() }
        await build.waitUntilStarted()

        await debug.emitSnapshot(
            fixture.snapshot(line: 1, r0: 1, memory: [block]),
            followedBy: "building-snapshot-barrier"
        )
        await waitUntil { model.debugDiagnostics.contains { $0.message == "building-snapshot-barrier" } }
        XCTAssertEqual(model.state, .building)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.registerRows.isEmpty)
        XCTAssertTrue(model.memory.isEmpty)

        await build.finish()
        await building.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testStoppedSnapshotAdoptsMemoryWhileReadyAndRunningSnapshotsAreIgnored() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        let stoppedBlock = fixture.memoryBlock(begin: "0x8000", contents: "01020304")
        let ignoredBlock = fixture.memoryBlock(begin: "0x9000", contents: "AABBCCDD")
        await model.open(fixture.document.sourceURL)
        await model.build()

        await debug.emitSnapshot(
            fixture.snapshot(line: 1, r0: 1, memory: [ignoredBlock]),
            followedBy: "ready-snapshot-barrier"
        )
        await waitUntil { model.debugDiagnostics.contains { $0.message == "ready-snapshot-barrier" } }
        XCTAssertTrue(model.memory.isEmpty)

        await model.start(.debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [stoppedBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.memory == [stoppedBlock] }
        XCTAssertEqual(model.snapshot?.memory, [stoppedBlock])

        await debug.emit(.stateChanged(.running))
        await waitUntil { model.state == .running }
        XCTAssertTrue(model.memory.isEmpty)
        await debug.emitSnapshot(
            fixture.snapshot(line: 2, r0: 2, memory: [ignoredBlock]),
            followedBy: "running-snapshot-barrier"
        )
        await waitUntil { model.debugDiagnostics.contains { $0.message == "running-snapshot-barrier" } }
        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertEqual(model.snapshot?.memory, [stoppedBlock])
    }

    func testSetMemoryWindowAddressConfiguresFixedWindowAndReadsWhenStopped() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let block = fixture.memoryBlock(begin: "0x9000", contents: "DEADBEEF")
        await debug.setMemoryResult([block], for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let normalized = await model.setMemoryWindowAddress("0x9000")

        let configuredRequests = await debug.configuredRequests()
        let readRequests = await debug.readRequests()
        let configuredRequest = try XCTUnwrap(configuredRequests.first)
        let readRequest = try XCTUnwrap(readRequests.first)
        XCTAssertEqual(normalized, "0x00009000")
        XCTAssertEqual(configuredRequests.count, 1)
        XCTAssertEqual(readRequests.count, 1)
        XCTAssertEqual(configuredRequest.address, "0x00009000")
        XCTAssertEqual(configuredRequest.byteCount, 112)
        XCTAssertNotNil(configuredRequest.observationID)
        XCTAssertEqual(readRequest, configuredRequest)
        XCTAssertEqual(model.memory, [block])
        XCTAssertNil(model.errorMessage)
    }

    func testRunningMemoryWindowAddressOnlyConfiguresThenNextStoppedSnapshotRefreshes() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let oldBlock = fixture.memoryBlock(begin: "0x8000", contents: "01")
        let newBlock = fixture.memoryBlock(begin: "0xA000", contents: "02")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [oldBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.memory == [oldBlock] }
        await debug.emit(.stateChanged(.running))
        await waitUntil { model.state == .running }

        let normalized = await model.setMemoryWindowAddress("0xa000")

        let configuredRequests = await debug.configuredRequests()
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(configuredRequests.first)
        XCTAssertEqual(normalized, "0x0000A000")
        XCTAssertEqual(configuredRequests.count, 1)
        XCTAssertEqual(request.address, "0x0000A000")
        XCTAssertEqual(request.byteCount, 112)
        XCTAssertNotNil(request.observationID)
        XCTAssertTrue(readRequests.isEmpty)
        XCTAssertTrue(model.memory.isEmpty)

        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        await debug.emit(.snapshot(fixture.snapshot(
            line: 2,
            r0: 2,
            memory: [newBlock],
            memoryRequest: request
        )))
        await waitUntil { model.memory == [newBlock] }
        XCTAssertEqual(model.memory, [newBlock])
    }

    func testRunningSnapshotDoesNotInvalidatePendingMemoryWindowConfiguration() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let ignoredBlock = fixture.memoryBlock(begin: "0xA000", contents: "AA")
        await debug.suspendMemoryConfiguration(for: "0x0000A000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emit(.stateChanged(.running))
        await waitUntil { model.state == .running }

        let configuring = Task { await model.setMemoryWindowAddress("0xA000") }
        await debug.waitUntilMemoryConfigurationStarted("0x0000A000")
        await debug.emitSnapshot(
            fixture.snapshot(line: 2, r0: 2, memory: [ignoredBlock]),
            followedBy: "pending-configuration-snapshot-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "pending-configuration-snapshot-barrier" }
        }
        await debug.finishMemoryConfiguration("0x0000A000")
        let normalized = await configuring.value

        XCTAssertEqual(normalized, "0x0000A000")
        let readRequests = await debug.readRequests()
        XCTAssertTrue(readRequests.isEmpty)
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testMemoryWindowAddressRejectsInvalidRegisterAndOverflowWithoutServiceCalls() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        for rawAddress in ["8000", "$sp", "0xFFFFFFFFFFFFFF91"] {
            let normalized = await model.setMemoryWindowAddress(rawAddress)
            XCTAssertNil(normalized)
            XCTAssertTrue(model.errorMessage?.contains("内存") == true)
        }

        let configuredRequests = await debug.configuredRequests()
        let readRequests = await debug.readRequests()
        XCTAssertTrue(configuredRequests.isEmpty)
        XCTAssertTrue(readRequests.isEmpty)
    }

    func testCurrentMemoryWindowReadFailureKeepsConfiguredAddressForSnapshotRecovery() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let oldBlock = fixture.memoryBlock(begin: "0x8000", contents: "88")
        let recoveredBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        await debug.failMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [oldBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.memory == [oldBlock] }

        let normalized = await model.setMemoryWindowAddress("0x9000")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)

        XCTAssertEqual(normalized, "0x00009000")
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
        XCTAssertTrue(model.memory.isEmpty)

        await debug.emit(.snapshot(fixture.snapshot(
            line: 2,
            r0: 2,
            memory: [recoveredBlock],
            memoryRequest: request
        )))
        await waitUntil { model.memory == [recoveredBlock] }

        XCTAssertEqual(model.memory, [recoveredBlock])
        XCTAssertNil(model.errorMessage)
    }

    func testFailedNewerMemoryConfigurationRestoresConfirmedRequestAfterOlderCompletion() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        await debug.suspendMemoryConfiguration(for: "0x0000A000")
        await debug.failMemoryConfiguration(for: "0x0000B000")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()

        let configuringA = Task { await model.setMemoryWindowAddress("0xA000") }
        await debug.waitUntilMemoryConfigurationStarted("0x0000A000")
        let resultB = await model.setMemoryWindowAddress("0xB000")
        await debug.finishMemoryConfiguration("0x0000A000")
        let resultA = await configuringA.value

        XCTAssertNil(resultB)
        XCTAssertNil(resultA)
        var configuredRequests = await debug.configuredRequests()
        XCTAssertEqual(configuredRequests.last, .yagartoWindow)

        await model.start(.debug)
        configuredRequests = await debug.configuredRequests()
        XCTAssertEqual(configuredRequests.last, .yagartoWindow)
    }

    func testSuccessfulMemoryWindowSubmissionClearsLocalMemoryWindowError() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        model.reportMemoryWindowError(MemoryTableFormattingError.invalidAddress("invalid"))
        XCTAssertNotNil(model.errorMessage)

        let normalized = await model.setMemoryWindowAddress("0x9000")

        XCTAssertEqual(normalized, "0x00009000")
        XCTAssertNil(model.errorMessage)
    }

    func testLaunchFailureResetsDesiredMemoryRequestBeforeNextStart() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        _ = await model.setMemoryWindowAddress("0x9000")
        await debug.setLaunchFailure(snapshotBeforeFailure: fixture.snapshot(line: 1, r0: 1))

        await model.start(.debug)
        XCTAssertEqual(model.state, .ready)
        await debug.clearLaunchFailure()
        await model.start(.debug)

        let configuredRequests = await debug.configuredRequests()
        XCTAssertEqual(configuredRequests.last, .yagartoWindow)
    }

    func testReadyEventBeforeLaunchThrowResetsDesiredMemoryRequestBeforeNextStart() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        _ = await model.setMemoryWindowAddress("0x9000")
        await debug.failNextLaunchAfterReadyEvent()

        let failedStart = Task { await model.start(.debug) }
        await debug.waitUntilReadyLaunchFailureStarted()
        await waitUntil { model.state == .ready }
        await debug.finishReadyLaunchFailure()
        await failedStart.value

        await model.start(.debug)

        let configuredRequests = await debug.configuredRequests()
        XCTAssertEqual(configuredRequests.last, .yagartoWindow)
    }

    func testMatchingSnapshotClearsPreviousMemoryError() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let recoveredBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        await debug.failMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        _ = await model.setMemoryWindowAddress("0x9000")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")

        await debug.emit(.snapshot(fixture.snapshot(
            line: 2,
            r0: 2,
            memory: [recoveredBlock],
            memoryRequest: request
        )))
        await waitUntil { model.memory == [recoveredBlock] }

        XCTAssertNil(model.errorMessage)
    }

    func testMatchingSnapshotDoesNotClearNewerGlobalError() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let recoveredBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        await debug.failMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        _ = await model.setMemoryWindowAddress("0x9000")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
        model.reportOperationError(FakeFailure.global)

        await debug.emit(.snapshot(fixture.snapshot(
            line: 2,
            r0: 2,
            memory: [recoveredBlock],
            memoryRequest: request
        )))
        await waitUntil { model.memory == [recoveredBlock] }

        XCTAssertEqual(model.errorMessage, "测试全局错误。")
    }

    func testFailedMatchingSnapshotDoesNotClearMemoryError() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let diagnostic = DebugDiagnostic(
            pane: .memory,
            isCritical: false,
            message: "测试 snapshot 内存读取失败"
        )
        await debug.failMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        _ = await model.setMemoryWindowAddress("0x9000")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")

        await debug.emitSnapshot(
            fixture.snapshot(
                line: 2,
                r0: 2,
                memoryRequest: request,
                diagnostics: [diagnostic]
            ),
            followedBy: "failed-matching-snapshot-error-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "failed-matching-snapshot-error-barrier" }
        }

        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
        XCTAssertTrue(model.memory.isEmpty)
    }

    func testFailedMatchingSnapshotDoesNotReplaceSuccessfulDirectMemory() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let directBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        let diagnostic = DebugDiagnostic(
            pane: .memory,
            isCritical: false,
            message: "测试 snapshot 内存读取失败"
        )
        await debug.setMemoryResult([directBlock], for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        _ = await model.setMemoryWindowAddress("0x9000")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)
        XCTAssertEqual(model.memory, [directBlock])

        await debug.emitSnapshot(
            fixture.snapshot(
                line: 2,
                r0: 2,
                memoryRequest: request,
                diagnostics: [diagnostic]
            ),
            followedBy: "failed-matching-snapshot-data-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "failed-matching-snapshot-data-barrier" }
        }

        XCTAssertEqual(model.memory, [directBlock])
        XCTAssertNil(model.errorMessage)
    }

    func testNewerMemoryReadWinsWhenOlderReadSucceedsLast() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let blockA = fixture.memoryBlock(begin: "0xA000", contents: "AA")
        let blockB = fixture.memoryBlock(begin: "0xB000", contents: "BB")
        await debug.suspendMemoryRead(for: "0x0000A000")
        await debug.suspendMemoryRead(for: "0x0000B000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let readingA = Task { await model.setMemoryWindowAddress("0xA000") }
        await debug.waitUntilMemoryReadStarted("0x0000A000")
        let readingB = Task { await model.setMemoryWindowAddress("0xB000") }
        await debug.waitUntilMemoryReadStarted("0x0000B000")
        await debug.finishMemoryRead("0x0000B000", with: [blockB])
        let resultB = await readingB.value
        XCTAssertEqual(resultB, "0x0000B000")
        XCTAssertEqual(model.memory, [blockB])

        await debug.finishMemoryRead("0x0000A000", with: [blockA])
        let resultA = await readingA.value
        XCTAssertNil(resultA)
        XCTAssertEqual(model.memory, [blockB])
        XCTAssertNil(model.errorMessage)
    }

    func testNewerMemoryReadWinsWhenOlderReadFailsLast() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let blockB = fixture.memoryBlock(begin: "0xB000", contents: "BB")
        await debug.suspendMemoryRead(for: "0x0000A000")
        await debug.suspendMemoryRead(for: "0x0000B000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let readingA = Task { await model.setMemoryWindowAddress("0xA000") }
        await debug.waitUntilMemoryReadStarted("0x0000A000")
        let readingB = Task { await model.setMemoryWindowAddress("0xB000") }
        await debug.waitUntilMemoryReadStarted("0x0000B000")
        await debug.finishMemoryRead("0x0000B000", with: [blockB])
        let resultB = await readingB.value
        XCTAssertEqual(resultB, "0x0000B000")

        await debug.failPendingMemoryRead("0x0000A000")
        let resultA = await readingA.value
        XCTAssertNil(resultA)
        XCTAssertEqual(model.memory, [blockB])
        XCTAssertNil(model.errorMessage)
    }

    func testOlderSameAddressSnapshotCannotReplaceNewerDirectMemory() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let blockA = fixture.memoryBlock(begin: "0x9000", contents: "AA")
        let blockB = fixture.memoryBlock(begin: "0x9000", contents: "BB")
        await debug.suspendMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let readingA = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryReadStarted("0x00009000")
        let requestsAfterA = await debug.readRequests()
        let requestA = try XCTUnwrap(requestsAfterA.first)
        await debug.suspendMemoryRead(for: "0x00009000")
        let readingB = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryReadStarted("0x00009000", count: 2)
        let requestsAfterB = await debug.readRequests()
        let requestB = try XCTUnwrap(requestsAfterB.last)
        await debug.finishMemoryRead("0x00009000", occurrence: 2, with: [blockB])
        let resultB = await readingB.value

        await debug.emitSnapshot(
            fixture.snapshot(
                line: 2,
                r0: 2,
                memory: [blockA],
                memoryRequest: requestA
            ),
            followedBy: "same-address-old-success-snapshot-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "same-address-old-success-snapshot-barrier" }
        }
        await debug.finishMemoryRead("0x00009000", with: [blockA])
        let resultA = await readingA.value

        XCTAssertNotNil(requestA.observationID)
        XCTAssertNotNil(requestB.observationID)
        XCTAssertNotEqual(requestA.observationID, requestB.observationID)
        XCTAssertEqual(resultB, "0x00009000")
        XCTAssertNil(resultA)
        XCTAssertEqual(model.memory, [blockB])
        XCTAssertNil(model.errorMessage)
    }

    func testOlderSameAddressSnapshotCannotClearNewerReadError() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let blockA = fixture.memoryBlock(begin: "0x9000", contents: "AA")
        await debug.suspendMemoryRead(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let readingA = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryReadStarted("0x00009000")
        let requestsAfterA = await debug.readRequests()
        let requestA = try XCTUnwrap(requestsAfterA.first)
        await debug.suspendMemoryRead(for: "0x00009000")
        let readingB = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryReadStarted("0x00009000", count: 2)
        let requestsAfterB = await debug.readRequests()
        let requestB = try XCTUnwrap(requestsAfterB.last)
        await debug.failPendingMemoryRead("0x00009000", occurrence: 2)
        let resultB = await readingB.value

        await debug.emitSnapshot(
            fixture.snapshot(
                line: 2,
                r0: 2,
                memory: [blockA],
                memoryRequest: requestA
            ),
            followedBy: "same-address-old-failure-snapshot-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "same-address-old-failure-snapshot-barrier" }
        }
        await debug.finishMemoryRead("0x00009000", with: [blockA])
        let resultA = await readingA.value

        XCTAssertNotNil(requestA.observationID)
        XCTAssertNotNil(requestB.observationID)
        XCTAssertNotEqual(requestA.observationID, requestB.observationID)
        XCTAssertEqual(resultB, "0x00009000")
        XCTAssertNil(resultA)
        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
    }

    func testOldStoppedSnapshotDoesNotInterruptNewMemoryWindowConfiguration() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let initialBlock = fixture.memoryBlock(begin: "0x8000", contents: "11")
        let staleBlock = fixture.memoryBlock(begin: "0x8000", contents: "22")
        let finalBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        await debug.setMemoryResult([finalBlock], for: "0x00009000")
        await debug.suspendMemoryConfiguration(for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [initialBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.memory == [initialBlock] }

        let configuring = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryConfigurationStarted("0x00009000")
        await debug.emitSnapshot(
            fixture.snapshot(
                line: 8,
                r0: 8,
                memory: [staleBlock],
                memoryRequest: .yagartoWindow
            ),
            followedBy: "old-stopped-snapshot-barrier"
        )
        await waitUntil { model.debugDiagnostics.contains { $0.message == "old-stopped-snapshot-barrier" } }
        let memoryAfterOldSnapshot = model.memory
        let registerAfterOldSnapshot = model.snapshot?.registers.first?.value?.numeric

        await debug.finishMemoryConfiguration("0x00009000")
        let normalized = await configuring.value

        XCTAssertEqual(memoryAfterOldSnapshot, [initialBlock])
        XCTAssertEqual(registerAfterOldSnapshot, 8)
        XCTAssertEqual(normalized, "0x00009000")
        XCTAssertEqual(model.memory, [finalBlock])
        XCTAssertNil(model.errorMessage)
    }

    func testStopInvalidatesOlderMemoryWindowRead() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let staleBlock = fixture.memoryBlock(begin: "0xA000", contents: "AA")
        await debug.suspendMemoryRead(for: "0x0000A000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        let reading = Task { await model.setMemoryWindowAddress("0xA000") }
        await debug.waitUntilMemoryReadStarted("0x0000A000")

        await model.stop()
        await debug.finishMemoryRead("0x0000A000", with: [staleBlock])

        let result = await reading.value
        XCTAssertNil(result)
        XCTAssertEqual(model.state, .ready)
        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testStopResetsDesiredMemoryRequestBeforeNextSessionSnapshot() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let customBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        let defaultBlock = fixture.memoryBlock(begin: "0x8000", contents: "88")
        await debug.setMemoryResult([customBlock], for: "0x00009000")
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        _ = await model.setMemoryWindowAddress("0x9000")
        XCTAssertEqual(model.memory, [customBlock])

        await model.stop()
        await model.start(.debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [defaultBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.snapshot?.registers.first?.value?.numeric == 1 }

        XCTAssertEqual(model.memory, [defaultBlock])
    }

    func testProfileChangeInvalidatesOlderLegacyMemoryRead() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let staleBlock = fixture.memoryBlock(begin: "0x3000", contents: "AA")
        await debug.suspendMemoryRead(for: "0x3000")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        let reading = Task { await model.readMemory(address: "0x3000", length: "16") }
        await debug.waitUntilMemoryReadStarted("0x3000")

        model.changeProfile(to: .cortexM4)
        await debug.finishMemoryRead("0x3000", with: [staleBlock])
        await reading.value

        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testOpenInvalidatesOlderLegacyMemoryRead() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let staleBlock = fixture.memoryBlock(begin: "0x3000", contents: "AA")
        await debug.suspendMemoryRead(for: "0x3000")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        let reading = Task { await model.readMemory(address: "0x3000", length: "16") }
        await debug.waitUntilMemoryReadStarted("0x3000")

        await model.open(fixture.document.sourceURL)
        await debug.finishMemoryRead("0x3000", with: [staleBlock])
        await reading.value

        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testLegacyMemoryReadTracksDesiredRequestAndOwnsItsFailure() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let address = "0x3000"
        let oldBlock = fixture.memoryBlock(begin: "0x8000", contents: "88")
        let staleBlock = fixture.memoryBlock(begin: "0x8000", contents: "77")
        let recoveredBlock = fixture.memoryBlock(begin: "0x3000", contents: "33")
        await debug.failMemoryRead(for: address)
        let model = try await stoppedModel(fixture: fixture, debug: debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [oldBlock],
            memoryRequest: .yagartoWindow
        )))
        await waitUntil { model.memory == [oldBlock] }

        await model.readMemory(address: address, length: "16")
        let readRequests = await debug.readRequests()
        let request = try XCTUnwrap(readRequests.last)
        XCTAssertNotNil(request.observationID)
        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
        await debug.emitSnapshot(
            fixture.snapshot(
                line: 2,
                r0: 2,
                memory: [staleBlock],
                memoryRequest: .yagartoWindow
            ),
            followedBy: "legacy-stale-snapshot-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "legacy-stale-snapshot-barrier" }
        }
        XCTAssertTrue(model.memory.isEmpty)
        XCTAssertEqual(model.errorMessage, "测试内存读取失败。")
        await debug.emitSnapshot(
            fixture.snapshot(
                line: 3,
                r0: 3,
                memory: [recoveredBlock],
                memoryRequest: request
            ),
            followedBy: "legacy-matching-snapshot-barrier"
        )
        await waitUntil {
            model.debugDiagnostics.contains { $0.message == "legacy-matching-snapshot-barrier" }
        }

        XCTAssertEqual(model.memory, [recoveredBlock])
        XCTAssertNil(model.errorMessage)
    }

    func testCloseFromReadyInvalidatesPendingMemoryWindowConfiguration() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let initialBlock = fixture.memoryBlock(begin: "0x3000", contents: "33")
        await debug.setMemoryResult([initialBlock], for: "0x3000")
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.readMemory(address: "0x3000", length: "16")
        model.reportOperationError(FakeFailure.global)
        await debug.suspendMemoryConfiguration(for: "0x00009000")

        let configuring = Task { await model.setMemoryWindowAddress("0x9000") }
        await debug.waitUntilMemoryConfigurationStarted("0x00009000")
        await model.close()
        await debug.finishMemoryConfiguration("0x00009000")
        let normalized = await configuring.value

        XCTAssertNil(normalized)
        XCTAssertEqual(model.memory, [initialBlock])
        XCTAssertEqual(model.errorMessage, "测试全局错误。")
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
        let memoryRequests = await debug.readRequests()
        XCTAssertEqual(memoryRequests, [])

        await debug.emit(.stateChanged(.stopped))
        await waitUntil { model.state == .stopped }
        await model.readMemory(address: "0x2000_1000", length: "16")
        let validRequests = await debug.readRequests()
        let validRequest = try XCTUnwrap(validRequests.first)
        XCTAssertEqual(validRequests.count, 1)
        XCTAssertEqual(validRequest.address, "0x20001000")
        XCTAssertEqual(validRequest.byteCount, 16)
        XCTAssertNotNil(validRequest.observationID)

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

    func testProfileResetSynchronizesDefaultMemoryRequestBeforeNextLaunch() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        _ = await model.setMemoryWindowAddress("0x9000")

        model.changeProfile(to: .cortexM4)
        await model.build()
        await model.start(.debug)

        let configuredRequests = await debug.configuredRequests()
        XCTAssertEqual(configuredRequests.last, .yagartoWindow)
    }

    func testMemoryRequestSubmittedDuringStopSurvivesOldStopCompletion() async throws {
        let fixture = try ViewModelFixture()
        let debug = FakeDebugService()
        let customBlock = fixture.memoryBlock(begin: "0x9000", contents: "99")
        await debug.suspendNextStop()
        let model = try await stoppedModel(fixture: fixture, debug: debug)

        let stopping = Task { await model.stop() }
        await debug.waitUntilStopStarted()
        let normalized = await model.setMemoryWindowAddress("0x9000")
        let configuredRequests = await debug.configuredRequests()
        let customRequest = try XCTUnwrap(configuredRequests.last)
        await debug.finishStop()
        await stopping.value
        await model.start(.debug)
        await debug.emit(.snapshot(fixture.snapshot(
            line: 1,
            r0: 1,
            memory: [customBlock],
            memoryRequest: customRequest
        )))
        await waitUntil { model.snapshot?.registers.first?.value?.numeric == 1 }

        XCTAssertEqual(normalized, customRequest.address)
        XCTAssertEqual(model.memory, [customBlock])
    }

    func testCreateProjectOpensCreatedDocumentWithoutBuilding() async throws {
        let fixture = try ViewModelFixture()
        let created = CreatedProject(
            projectDirectory: fixture.document.projectDirectory,
            sourceURL: fixture.document.sourceURL,
            configuration: fixture.document.configuration
        )
        let projectService = FakeProjectCreationService(created: created)
        let recorder = CallRecorder()
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document, recorder: recorder),
            buildService: FakeBuildService(result: fixture.buildResult, recorder: recorder),
            debugService: FakeDebugService(),
            projectCreationService: projectService
        )

        let result = await model.createProject(ProjectCreationRequest(
            parentDirectory: fixture.directory.deletingLastPathComponent(),
            name: "new-project",
            profile: .arm7tdmi
        ))

        XCTAssertEqual(result, created)
        XCTAssertEqual(model.document, fixture.document)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.latestBuild)
        XCTAssertFalse(model.isProjectOperationInProgress)
        let recorded = await recorder.values()
        let projectCalls = await projectService.calls()
        XCTAssertEqual(recorded, ["open"])
        XCTAssertEqual(projectCalls, ["create"])
    }

    func testImportProjectsReturnsSummaryWithoutReplacingCurrentDocument() async throws {
        let fixture = try ViewModelFixture()
        let report = ProjectImportReport(
            profile: .arm7tdmi,
            created: [],
            skipped: [ProjectImportIssue(
                sourceURL: fixture.directory.appendingPathComponent("bad.s"),
                code: "project.entry_not_found",
                message: "没有找到入口"
            )],
            warnings: []
        )
        let projectService = FakeProjectCreationService(report: report)
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: FakeDebugService(),
            projectCreationService: projectService
        )
        await model.open(fixture.document.sourceURL)

        let result = await model.importProjects(ProjectImportRequest(
            inputs: [fixture.directory],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(result, report)
        XCTAssertEqual(model.document, fixture.document)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isProjectOperationInProgress)
        let projectCalls = await projectService.calls()
        XCTAssertEqual(projectCalls, ["import"])
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

    private func stoppedModel(
        fixture: ViewModelFixture,
        debug: FakeDebugService
    ) async throws -> AppViewModel {
        let model = AppViewModel(
            documentService: FakeDocumentService(document: fixture.document),
            buildService: FakeBuildService(result: fixture.buildResult),
            debugService: debug
        )
        await model.open(fixture.document.sourceURL)
        await model.build()
        await model.start(.debug)
        XCTAssertEqual(model.state, .stopped)
        await debug.clearMemoryRequestRecords()
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

private actor FakeProjectCreationService: ProjectCreationServicing {
    private let created: CreatedProject?
    private let report: ProjectImportReport?
    private var recordedCalls: [String] = []

    init(created: CreatedProject? = nil, report: ProjectImportReport? = nil) {
        self.created = created
        self.report = report
    }

    func create(_ request: ProjectCreationRequest) async throws -> CreatedProject {
        recordedCalls.append("create")
        return try XCTUnwrap(created)
    }

    func importProjects(_ request: ProjectImportRequest) async -> ProjectImportReport {
        recordedCalls.append("import")
        return report ?? ProjectImportReport(
            profile: request.profile,
            created: [],
            skipped: [],
            warnings: []
        )
    }

    func calls() -> [String] { recordedCalls }
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
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
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
    private var configuredMemoryRequests: [DebugMemoryRequest] = []
    private var readMemoryRequests: [DebugMemoryRequest] = []
    private var suspendedMemoryConfigurations: Set<String> = []
    private var failingMemoryConfigurations: Set<String> = []
    private var pendingMemoryConfigurations: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var memoryConfigurationStartCounts: [String: Int] = [:]
    private var memoryConfigurationStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var memoryResults: [String: [MIMemoryBlock]] = [:]
    private var failingMemoryReads: Set<String> = []
    private var suspendedMemoryReads: Set<String> = []
    private var pendingMemoryReads: [String: [CheckedContinuation<[MIMemoryBlock], any Error>]] = [:]
    private var memoryReadStartCounts: [String: Int] = [:]
    private var memoryReadStartWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var shouldSuspendStop = false
    private var stopStarted = false
    private var stopStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingStop: CheckedContinuation<Void, Never>?
    private var shouldFailBreakpoint = false
    private var shouldFailBreakpointRemoval = false
    private var breakpointFailureLines: Set<Int> = []
    private var emitStoppedOnLaunch = false
    private var launchCount = 0
    private var stepSnapshot: DebugSnapshot?
    private var launchFailureSnapshot: DebugSnapshot?
    private var shouldFailLaunchAfterReadyEvent = false
    private var readyLaunchFailureStarted = false
    private var readyLaunchFailureWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReadyLaunchFailure: CheckedContinuation<Void, Never>?

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
        if shouldFailLaunchAfterReadyEvent {
            shouldFailLaunchAfterReadyEvent = false
            continuation.yield(.stateChanged(.ready))
            await withCheckedContinuation { continuation in
                pendingReadyLaunchFailure = continuation
                readyLaunchFailureStarted = true
                readyLaunchFailureWaiters.forEach { $0.resume() }
                readyLaunchFailureWaiters.removeAll()
            }
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
    func stop() async throws {
        recordedCalls.append("stop")
        if shouldSuspendStop {
            shouldSuspendStop = false
            await withCheckedContinuation { continuation in
                pendingStop = continuation
                stopStarted = true
                stopStartWaiters.forEach { $0.resume() }
                stopStartWaiters.removeAll()
            }
        }
    }
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {
        configuredMemoryRequests.append(request)
        if suspendedMemoryConfigurations.remove(request.address) != nil {
            try await withCheckedThrowingContinuation { continuation in
                pendingMemoryConfigurations[request.address, default: []].append(continuation)
                markMemoryConfigurationStarted(request.address)
            }
        } else {
            markMemoryConfigurationStarted(request.address)
        }
        if failingMemoryConfigurations.remove(request.address) != nil { throw FakeFailure.memory }
    }
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        readMemoryRequests.append(request)
        if suspendedMemoryReads.remove(request.address) != nil {
            return try await withCheckedThrowingContinuation { continuation in
                pendingMemoryReads[request.address, default: []].append(continuation)
                markMemoryReadStarted(request.address)
            }
        }
        markMemoryReadStarted(request.address)
        if failingMemoryReads.remove(request.address) != nil { throw FakeFailure.memory }
        return memoryResults[request.address] ?? []
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
    func emitSnapshot(_ snapshot: DebugSnapshot, followedBy marker: String) {
        continuation.yield(.snapshot(snapshot))
        continuation.yield(.diagnostic(DebugDiagnostic(
            pane: .memory,
            isCritical: false,
            message: marker
        )))
    }
    func calls() -> [String] { recordedCalls }
    func configuredRequests() -> [DebugMemoryRequest] { configuredMemoryRequests }
    func readRequests() -> [DebugMemoryRequest] { readMemoryRequests }
    func clearMemoryRequestRecords() {
        configuredMemoryRequests = []
        readMemoryRequests = []
    }
    func suspendNextStop() { shouldSuspendStop = true }
    func waitUntilStopStarted() async {
        if stopStarted { return }
        await withCheckedContinuation { stopStartWaiters.append($0) }
    }
    func finishStop() {
        pendingStop?.resume()
        pendingStop = nil
    }
    func suspendMemoryConfiguration(for address: String) {
        suspendedMemoryConfigurations.insert(address)
    }
    func failMemoryConfiguration(for address: String) {
        failingMemoryConfigurations.insert(address)
    }
    func waitUntilMemoryConfigurationStarted(_ address: String) async {
        if memoryConfigurationStartCounts[address, default: 0] > 0 { return }
        await withCheckedContinuation {
            memoryConfigurationStartWaiters[address, default: []].append($0)
        }
    }
    func finishMemoryConfiguration(_ address: String) {
        popPendingMemoryConfiguration(address)?.resume()
    }
    func setMemoryResult(_ blocks: [MIMemoryBlock], for address: String) {
        memoryResults[address] = blocks
    }
    func failMemoryRead(for address: String) { failingMemoryReads.insert(address) }
    func suspendMemoryRead(for address: String) { suspendedMemoryReads.insert(address) }
    func waitUntilMemoryReadStarted(_ address: String, count: Int = 1) async {
        if memoryReadStartCounts[address, default: 0] >= count { return }
        await withCheckedContinuation { memoryReadStartWaiters[address, default: []].append($0) }
    }
    func finishMemoryRead(_ address: String, with blocks: [MIMemoryBlock]) {
        popPendingMemoryRead(address)?.resume(returning: blocks)
    }
    func finishMemoryRead(
        _ address: String,
        occurrence: Int,
        with blocks: [MIMemoryBlock]
    ) {
        popPendingMemoryRead(address, at: occurrence - 1)?.resume(returning: blocks)
    }
    func failPendingMemoryRead(_ address: String) {
        popPendingMemoryRead(address)?.resume(throwing: FakeFailure.memory)
    }
    func failPendingMemoryRead(_ address: String, occurrence: Int) {
        popPendingMemoryRead(address, at: occurrence - 1)?.resume(throwing: FakeFailure.memory)
    }
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
    func clearLaunchFailure() { launchFailureSnapshot = nil }
    func failNextLaunchAfterReadyEvent() { shouldFailLaunchAfterReadyEvent = true }
    func waitUntilReadyLaunchFailureStarted() async {
        if readyLaunchFailureStarted { return }
        await withCheckedContinuation { readyLaunchFailureWaiters.append($0) }
    }
    func finishReadyLaunchFailure() {
        pendingReadyLaunchFailure?.resume()
        pendingReadyLaunchFailure = nil
        readyLaunchFailureStarted = false
    }

    private func markMemoryReadStarted(_ address: String) {
        memoryReadStartCounts[address, default: 0] += 1
        memoryReadStartWaiters.removeValue(forKey: address)?.forEach { $0.resume() }
    }

    private func markMemoryConfigurationStarted(_ address: String) {
        memoryConfigurationStartCounts[address, default: 0] += 1
        memoryConfigurationStartWaiters.removeValue(forKey: address)?.forEach { $0.resume() }
    }

    private func popPendingMemoryConfiguration(
        _ address: String
    ) -> CheckedContinuation<Void, any Error>? {
        guard var continuations = pendingMemoryConfigurations[address], !continuations.isEmpty else {
            return nil
        }
        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            pendingMemoryConfigurations[address] = nil
        } else {
            pendingMemoryConfigurations[address] = continuations
        }
        return continuation
    }

    private func popPendingMemoryRead(
        _ address: String,
        at index: Int = 0
    ) -> CheckedContinuation<[MIMemoryBlock], any Error>? {
        guard var continuations = pendingMemoryReads[address], continuations.indices.contains(index) else {
            return nil
        }
        let continuation = continuations.remove(at: index)
        if continuations.isEmpty {
            pendingMemoryReads[address] = nil
        } else {
            pendingMemoryReads[address] = continuations
        }
        return continuation
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
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
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
    case memory
    case global
}

extension FakeFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .breakpoint: return "测试断点失败。"
        case .launch: return "测试启动失败。"
        case .memory: return "测试内存读取失败。"
        case .global: return "测试全局错误。"
        }
    }
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
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "1", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}
}

private actor ControlledStartDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let suspendsLaunch: Bool
    private var prepareCount = 0
    private var launchCount = 0
    private var prepareContinuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var launchContinuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var prepareWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var launchWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(suspendsLaunch: Bool) {
        self.suspendsLaunch = suspendsLaunch
        stream = AsyncStream { _ in }
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }

    func prepare(_ build: AppBuildResult) async throws {
        prepareCount += 1
        let call = prepareCount
        prepareWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { prepareContinuations[call] = $0 }
    }

    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        launchCount += 1
        let call = launchCount
        launchWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
        if suspendsLaunch {
            try await withCheckedThrowingContinuation { launchContinuations[call] = $0 }
        }
        return DebugLaunchResult()
    }

    func pause() async throws {}
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws {}
    func stop() async throws {}
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "\(line)", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}

    func waitUntilPrepareStarted(_ call: Int) async {
        if prepareContinuations[call] != nil { return }
        await withCheckedContinuation { prepareWaiters[call, default: []].append($0) }
    }

    func waitUntilLaunchStarted(_ call: Int) async {
        if launchCount >= call { return }
        await withCheckedContinuation { launchWaiters[call, default: []].append($0) }
    }

    func finishPrepare(_ call: Int) {
        prepareContinuations.removeValue(forKey: call)?.resume()
    }

    func failPrepare(_ call: Int) {
        prepareContinuations.removeValue(forKey: call)?.resume(throwing: FakeFailure.launch)
    }

    func finishLaunch(_ call: Int) {
        launchContinuations.removeValue(forKey: call)?.resume()
    }

    func launchCallCount() -> Int { launchCount }
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

    func snapshot(
        line: UInt64,
        r0: UInt64,
        memory: [MIMemoryBlock] = [],
        memoryRequest: DebugMemoryRequest? = nil,
        diagnostics: [DebugDiagnostic] = []
    ) -> DebugSnapshot {
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
            memory: memory,
            memoryRequest: memoryRequest,
            disassembly: [],
            console: [],
            diagnostics: diagnostics
        )
    }

    func memoryBlock(begin: String, contents: String) -> MIMemoryBlock {
        MIMemoryBlock(
            begin: MIRawNumeric(raw: begin),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: begin),
            contents: contents
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

private func waitUntilRemoteBreakpoints(
    _ debug: ControlledBreakpointDebugService,
    count: Int,
    timeout: Duration = .seconds(1)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await debug.remoteBreakpointIDs().count != count, clock.now < deadline {
        await Task.yield()
    }
    let finalCount = await debug.remoteBreakpointIDs().count
    XCTAssertEqual(finalCount, count)
}
