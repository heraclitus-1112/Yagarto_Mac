// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct AppBuildResult: Equatable, Sendable {
    public let configuration: ProjectConfiguration
    public let projectDirectory: URL
    public let elf: URL
    public let artifacts: [URL]
    public let diagnostics: [BuildDiagnostic]
    public let output: String

    public init(
        configuration: ProjectConfiguration,
        projectDirectory: URL,
        elf: URL,
        artifacts: [URL],
        diagnostics: [BuildDiagnostic],
        output: String
    ) {
        self.configuration = configuration
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.elf = elf.standardizedFileURL
        self.artifacts = artifacts.map(\.standardizedFileURL)
        self.diagnostics = diagnostics
        self.output = output
    }
}

public struct BuildServiceFailure: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public let diagnostics: [BuildDiagnostic]
    public let output: String

    public init(message: String, diagnostics: [BuildDiagnostic], output: String) {
        self.message = message
        self.diagnostics = diagnostics
        self.output = output
    }

    public var errorDescription: String? { message }
}

public protocol BuildServicing: Sendable {
    func build(projectDirectory: URL) async throws -> AppBuildResult
}

public protocol ProjectCreationServicing: Sendable {
    func create(_ request: ProjectCreationRequest) async throws -> CreatedProject
    func importProjects(_ request: ProjectImportRequest) async -> ProjectImportReport
}

public struct CoreProjectCreationService: ProjectCreationServicing, Sendable {
    private let creator: ProjectCreator

    public init(creator: ProjectCreator = ProjectCreator()) {
        self.creator = creator
    }

    public func create(_ request: ProjectCreationRequest) async throws -> CreatedProject {
        try await Task.detached { try creator.create(request) }.value
    }

    public func importProjects(_ request: ProjectImportRequest) async -> ProjectImportReport {
        await Task.detached { creator.importProjects(request) }.value
    }
}

public struct DebugSourceBreakpoint: Equatable, Sendable {
    public let file: URL
    public let line: Int

    public init(file: URL, line: Int) {
        self.file = file.standardizedFileURL
        self.line = line
    }
}

public struct DebugBreakpointSyncFailure: Equatable, Sendable {
    public let breakpoint: DebugSourceBreakpoint
    public let message: String

    public init(breakpoint: DebugSourceBreakpoint, message: String) {
        self.breakpoint = breakpoint
        self.message = message
    }
}

public struct DebugBreakpointBinding: Equatable, Sendable {
    public let breakpoint: DebugSourceBreakpoint
    public let identifier: String

    public init(breakpoint: DebugSourceBreakpoint, identifier: String) {
        self.breakpoint = breakpoint
        self.identifier = identifier
    }
}

public struct DebugLaunchResult: Equatable, Sendable {
    public let breakpointIdentifiers: [Int: String]
    public let breakpointBindings: [DebugBreakpointBinding]
    public let failures: [DebugBreakpointSyncFailure]

    public init(
        breakpointIdentifiers: [Int: String] = [:],
        breakpointBindings: [DebugBreakpointBinding] = [],
        failures: [DebugBreakpointSyncFailure] = []
    ) {
        self.breakpointIdentifiers = breakpointIdentifiers
        self.breakpointBindings = breakpointBindings
        self.failures = failures
    }
}

public protocol DebugServicing: Sendable {
    func events() async -> AsyncStream<DebuggerEvent>
    func prepare(_ build: AppBuildResult) async throws
    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult
    func pause() async throws
    func stepInstruction() async throws
    func stepOver() async throws
    func resume() async throws
    func stop() async throws
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock]
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint
    func removeBreakpoint(identifier: String) async throws
}
