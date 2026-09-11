// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

@MainActor
final class AppViewModelTests: XCTestCase {
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

private actor FakeDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let continuation: AsyncStream<DebuggerEvent>.Continuation
    private var recordedCalls: [String] = []
    private var requests: [DebugMemoryRequest] = []
    private var shouldFailBreakpoint = false
    private var shouldFailBreakpointRemoval = false
    private var stepSnapshot: DebugSnapshot?

    init() {
        let pair = AsyncStream<DebuggerEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws { recordedCalls.append("prepare") }
    func launch(mode: DebugMode) async throws { recordedCalls.append("launch:\(mode.rawValue)") }
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
        if shouldFailBreakpoint { throw FakeFailure.breakpoint }
        return DebugBreakpoint(id: "\(line)", location: "\(file.path):\(line)")
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
    func setStepSnapshot(_ snapshot: DebugSnapshot) { stepSnapshot = snapshot }
}

private enum FakeFailure: Error, Sendable {
    case breakpoint
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
    func launch(mode: DebugMode) async throws {}
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
