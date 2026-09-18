// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

@MainActor
final class AppViewModelMultiSourceTests: XCTestCase {
    func testSourceSwitchPreservesIndependentTextBreakpointsAndSaveAll() async throws {
        let fixture = try MultiSourceFixture()
        let debug = MultiSourceDebugService()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: debug
        )
        await model.open(fixture.directory)

        model.edit("MOV r0, #10\n")
        await model.toggleBreakpoint(line: 1)
        await model.selectSource("second.s")
        model.edit("MOV r1, #20\n")
        await model.toggleBreakpoint(line: 2)

        XCTAssertEqual(model.document?.activeSourceRelativePath, "second.s")
        XCTAssertEqual(model.breakpoints.lines, [2])
        XCTAssertEqual(model.document?.sourceBuffers.map(\.isDirty), [true, true])

        await model.selectSource("first.s")
        XCTAssertEqual(model.document?.text, "MOV r0, #10\n")
        XCTAssertEqual(model.breakpoints.lines, [1])

        await model.save()
        XCTAssertFalse(model.document?.isDirty ?? true)
        XCTAssertEqual(try String(contentsOf: fixture.first, encoding: .utf8), "MOV r0, #10\n")
        XCTAssertEqual(try String(contentsOf: fixture.second, encoding: .utf8), "MOV r1, #20\n")
    }

    func testCrossFileDiagnosticLoadsAndSelectsTargetSource() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService()
        )
        await model.open(fixture.directory)
        let diagnostic = BuildDiagnostic(
            severity: .error,
            file: fixture.second,
            line: 1,
            column: 5,
            message: "second source"
        )

        await model.activateDiagnostic(diagnostic)

        XCTAssertEqual(model.document?.activeSourceRelativePath, "second.s")
        XCTAssertEqual(model.selectedRange?.location, 4)
    }

    func testSourceSwitchRestoresPerFileSelection() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService()
        )
        await model.open(fixture.directory)
        model.updateSelection(NSRange(location: 2, length: 0))
        await model.selectSource("second.s")
        model.updateSelection(NSRange(location: 5, length: 0))

        await model.selectSource("first.s")
        XCTAssertEqual(model.selectedRange, NSRange(location: 2, length: 0))
    }

    func testSourceSwitchDoesNotClearExistingOperationError() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService()
        )
        await model.open(fixture.directory)
        model.reportOperationError(MultiSourceFailure.expected)

        await model.selectSource("second.s")

        XCTAssertEqual(model.errorMessage, "保留这个错误")
    }

    func testDebugLaunchReceivesBreakpointsFromEveryConfiguredSource() async throws {
        let fixture = try MultiSourceFixture()
        let debug = MultiSourceDebugService()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: debug
        )
        await model.open(fixture.directory)
        await model.toggleBreakpoint(line: 1)
        await model.selectSource("second.s")
        await model.toggleBreakpoint(line: 2)
        await model.build()

        await model.start(.debug)

        let captured = await debug.capturedBreakpoints()
        XCTAssertEqual(
            Set(captured.map { "\($0.file.lastPathComponent):\($0.line)" }),
            ["first.s:1", "second.s:2"]
        )
    }

    func testSuccessfulOpenRecordsRecentProjectAndClearRemovesIt() async throws {
        let fixture = try MultiSourceFixture()
        let recent = MemoryRecentProjectStore()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            recentProjectStore: recent
        )

        await model.open(fixture.directory)

        XCTAssertEqual(model.recentProjects.map(\.projectURL), [fixture.directory.standardizedFileURL])

        await model.clearRecentProjects()
        XCTAssertTrue(model.recentProjects.isEmpty)
    }
}

private struct MultiSourceFixture {
    let directory: URL
    let first: URL
    let second: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        first = directory.appendingPathComponent("first.s")
        second = directory.appendingPathComponent("second.s")
        try Data("MOV r0, #1\n".utf8).write(to: first)
        try Data("MOV r1, #2\n".utf8).write(to: second)
        try ConfigStore(projectDirectory: directory).save(ProjectConfiguration(
            sources: ["first.s", "second.s"],
            outputName: "multi"
        ))
    }
}

private struct MultiSourceBuildService: BuildServicing {
    let project: URL

    func build(projectDirectory: URL) async throws -> AppBuildResult {
        let configuration = try ConfigStore(projectDirectory: projectDirectory).load()
        return AppBuildResult(
            configuration: configuration,
            projectDirectory: project,
            elf: project.appendingPathComponent("multi.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
    }
}

private actor MultiSourceDebugService: DebugServicing {
    private var breakpoints: [DebugSourceBreakpoint] = []

    func events() -> AsyncStream<DebuggerEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func prepare(_ build: AppBuildResult) async throws {}

    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        self.breakpoints = breakpoints
        return DebugLaunchResult()
    }

    func capturedBreakpoints() -> [DebugSourceBreakpoint] { breakpoints }
    func pause() async throws {}
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws {}
    func stop() async throws {}
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "\(file.lastPathComponent):\(line)", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}
}

private actor MemoryRecentProjectStore: RecentProjectStoring {
    private var values: [RecentProject] = []

    func projects() -> [RecentProject] { values }

    func record(_ projectURL: URL) -> [RecentProject] {
        let project = RecentProject(projectURL: projectURL)
        values.removeAll { $0.canonicalPath == project.canonicalPath }
        values.insert(project, at: 0)
        return values
    }

    func remove(_ projectURL: URL) -> [RecentProject] {
        let path = RecentProject(projectURL: projectURL).canonicalPath
        values.removeAll { $0.canonicalPath == path }
        return values
    }

    func clear() { values = [] }
}

private enum MultiSourceFailure: Error, LocalizedError {
    case expected
    var errorDescription: String? { "保留这个错误" }
}
