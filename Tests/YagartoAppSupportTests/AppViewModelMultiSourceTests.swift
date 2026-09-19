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

    func testRenameSourceMigratesDirtyBufferSelectionAndBreakpoints() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: LocalProjectSourceManager()
        )
        await model.open(fixture.directory)
        await model.selectSource("second.s")
        model.edit("MOV r8, #8\n")
        model.updateSelection(NSRange(location: 3, length: 0))
        await model.toggleBreakpoint(line: 1)

        let result = await model.renameSource("second.s", to: "renamed.S")

        XCTAssertEqual(result?.renamedRelativePaths, ["second.s": "renamed.S"])
        XCTAssertEqual(model.document?.activeSourceRelativePath, "renamed.S")
        XCTAssertEqual(model.document?.text, "MOV r8, #8\n")
        XCTAssertEqual(model.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(model.breakpoints.lines, [1])
        XCTAssertTrue(model.document?.isDirty ?? false)
        XCTAssertEqual(model.selectedSourceRelativePath, "renamed.S")
        XCTAssertFalse(model.isSourceMutationInProgress)
    }

    func testCreateCopyAndTrashUpdateTreeAndChooseExpectedActiveSource() async throws {
        let fixture = try MultiSourceFixture()
        let external = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString).s")
        try Data("MOV r4, #4\n".utf8).write(to: external)
        let trashDirectory = fixture.directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: false)
        let manager = LocalProjectSourceManager(testingTrashHandler: { source in
            let destination = trashDirectory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: manager
        )
        await model.open(fixture.directory)

        _ = await model.createSource(filename: "new-file", inDirectory: nil)
        XCTAssertEqual(model.document?.activeSourceRelativePath, "new-file.s")
        XCTAssertEqual(model.projectTree.map(\.name), ["first.s", "second.s", "new-file.s"])

        let copied = await model.copySources([external], toDirectory: nil)
        XCTAssertEqual(copied?.addedRelativePaths, [external.lastPathComponent])
        XCTAssertEqual(model.document?.activeSourceRelativePath, external.lastPathComponent)

        _ = await model.trashSource(external.lastPathComponent, dirtyPolicy: .discardChanges)
        XCTAssertEqual(model.document?.activeSourceRelativePath, "new-file.s")
        XCTAssertFalse(model.document?.configuration.sources.contains(external.lastPathComponent) ?? true)
    }

    func testSourceManagementIsDisabledWhileDebuggerStopped() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: LocalProjectSourceManager()
        )
        await model.open(fixture.directory)
        await model.build()
        await model.start(.debug)
        XCTAssertEqual(model.state, .stopped)

        let result = await model.createSource(filename: "blocked.s", inDirectory: nil)

        XCTAssertNil(result)
        XCTAssertFalse(model.canManageProjectSources)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("blocked.s").path
        ))
    }

    func testSourceMutationInvalidatesReadyBuildAndReturnsToIdle() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: LocalProjectSourceManager()
        )
        await model.open(fixture.directory)
        await model.build()
        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.latestBuild)

        _ = await model.createSource(filename: "invalidates-build.s", inDirectory: nil)

        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.latestBuild)
        XCTAssertFalse(model.isEnabled(.run))
        XCTAssertFalse(model.isEnabled(.debug))
    }

    func testRenamingToSameFilenameKeepsReadyBuild() async throws {
        let fixture = try MultiSourceFixture()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: LocalProjectSourceManager()
        )
        await model.open(fixture.directory)
        await model.build()

        let result = await model.renameSource("first.s", to: "first.s")

        XCTAssertNotNil(result)
        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.latestBuild)
        XCTAssertTrue(model.isEnabled(.run))
    }

    func testFailedSourceMutationPreservesDocumentAndPresentsError() async throws {
        let fixture = try MultiSourceFixture()
        let manager = FailingProjectSourceManager()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: MultiSourceBuildService(project: fixture.directory),
            debugService: MultiSourceDebugService(),
            projectSourceManager: manager
        )
        await model.open(fixture.directory)
        let original = model.document

        let result = await model.renameSource("first.s", to: "renamed.s")

        XCTAssertNil(result)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(model.errorMessage, "模拟工程文件失败")
        XCTAssertFalse(model.isSourceMutationInProgress)
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

private struct FailingProjectSourceManager: ProjectSourceManaging {
    func createSource(
        _ request: CreateProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        throw MultiSourceMutationFailure.expected
    }

    func copySources(
        _ request: CopyProjectSourcesRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        throw MultiSourceMutationFailure.expected
    }

    func renameSource(
        _ request: RenameProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        throw MultiSourceMutationFailure.expected
    }

    func trashSource(
        _ request: TrashProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        throw MultiSourceMutationFailure.expected
    }
}

private enum MultiSourceMutationFailure: Error, LocalizedError {
    case expected
    var errorDescription: String? { "模拟工程文件失败" }
}
