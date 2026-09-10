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
    private let temporaryDirectory: URL

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    public func run(_ command: CommandSpec) throws -> ProcessResult {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let stdoutURL = temporaryDirectory.appendingPathComponent("yagarto-\(identifier)-stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("yagarto-\(identifier)-stderr")
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil) else {
            throw YagartoError.processIOFailed(
                stdoutURL.path,
                "无法创建标准输出捕获文件。"
            )
        }
        guard fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw YagartoError.processIOFailed(
                stderrURL.path,
                "无法创建标准错误捕获文件。"
            )
        }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            throw YagartoError.processIOFailed(
                temporaryDirectory.path,
                error.localizedDescription
            )
        }
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

        let stdoutData: Data
        let stderrData: Data
        do {
            try stdoutHandle.close()
            try stderrHandle.close()
            stdoutData = try Data(contentsOf: stdoutURL)
            stderrData = try Data(contentsOf: stderrURL)
        } catch {
            throw YagartoError.processIOFailed(
                temporaryDirectory.path,
                error.localizedDescription
            )
        }
        return ProcessResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
