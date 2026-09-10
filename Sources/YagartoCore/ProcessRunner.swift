// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ProcessResult: Codable, Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning {
    func run(_ command: CommandSpec) throws -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ command: CommandSpec) throws -> ProcessResult {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let identifier = UUID().uuidString
        let stdoutURL = temporaryDirectory.appendingPathComponent("yagarto-\(identifier)-stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("yagarto-\(identifier)-stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.args
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw YagartoError.processLaunchFailed(
                command.executable,
                error.localizedDescription
            )
        }

        try stdoutHandle.close()
        try stderrHandle.close()
        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        return ProcessResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
