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

public protocol DebugServicing: Sendable {
    func events() async -> AsyncStream<DebuggerEvent>
    func prepare(_ build: AppBuildResult) async throws
    func launch(mode: DebugMode) async throws
    func pause() async throws
    func stepInstruction() async throws
    func stepOver() async throws
    func resume() async throws
    func stop() async throws
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock]
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint
    func removeBreakpoint(identifier: String) async throws
}
