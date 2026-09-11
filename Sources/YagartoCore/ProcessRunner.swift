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

    public var toolOutput: String? {
        let standardOutput = Self.controlledOutput(stdout)
        let standardError = Self.controlledOutput(stderr)
        switch (standardOutput, standardError) {
        case (nil, nil):
            return nil
        case (let output?, nil):
            return output
        case (nil, let error?):
            return error
        case (let output?, let error?):
            return "stdout:\n\(output)\nstderr:\n\(error)"
        }
    }

    private static func controlledOutput(_ value: String) -> String? {
        let filteredScalars = value.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || scalar.value >= 0x20
        }
        let trimmed = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let limit = 16_384
        guard trimmed.count > limit else {
            return trimmed
        }
        return String(trimmed.prefix(limit)) + "\n…（工具输出已截断）"
    }
}

public protocol ProcessRunning {
    func run(_ command: CommandSpec) throws -> ProcessResult
}

public struct ProcessTermination: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case exit
        case uncaughtSignal
    }

    public let reason: Reason
    public let status: Int32

    public init(reason: Reason, status: Int32) {
        self.reason = reason
        self.status = status
    }
}

public struct ProcessRunner: ProcessRunning {
    private let temporaryDirectory: URL
    private let interactiveExecution: (CommandSpec) throws -> ProcessTermination

    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        interactiveExecution: ((CommandSpec) throws -> ProcessTermination)? = nil
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.interactiveExecution = interactiveExecution ?? Self.executeInteractively
    }

    public func runInteractive(_ command: CommandSpec) throws -> Int32 {
        let termination = try interactiveExecution(command)
        if termination.reason == .uncaughtSignal && termination.status == SIGINT {
            return YagartoExitCode.interrupted.rawValue
        }
        if termination.reason == .uncaughtSignal {
            return 128 + termination.status
        }
        return termination.status
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

    private static func executeInteractively(_ command: CommandSpec) throws -> ProcessTermination {
        InteractiveProcessSignalState.lock.lock()
        defer { InteractiveProcessSignalState.lock.unlock() }
        InteractiveProcessSignalState.processGroup = 0
        InteractiveProcessSignalState.receivedSignal = 0

        let handledSignals = [SIGINT, SIGTERM, SIGHUP]
        let previousHandlers = handledSignals.map {
            Darwin.signal($0, forwardInteractiveProcessSignal)
        }
        defer {
            InteractiveProcessSignalState.processGroup = 0
            for (signalNumber, previousHandler) in zip(handledSignals, previousHandlers) {
                _ = Darwin.signal(signalNumber, previousHandler)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let fileActionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsStatus == 0 else {
            throw YagartoError.processLaunchFailed(
                command.executable,
                String(cString: strerror(fileActionsStatus))
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let chdirStatus = command.workingDirectory.path.withCString {
            addSpawnWorkingDirectory(&fileActions, $0)
        }
        guard chdirStatus == 0 else {
            throw YagartoError.processLaunchFailed(
                command.executable,
                String(cString: strerror(chdirStatus))
            )
        }

        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else {
            throw YagartoError.processLaunchFailed(
                command.executable,
                String(cString: strerror(attributesStatus))
            )
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in handledSignals + [SIGTTOU, SIGTTIN] {
            sigaddset(&defaultSignals, signalNumber)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_START_SUSPENDED
        )
        for status in [
            posix_spawnattr_setflags(&attributes, spawnFlags),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        ] where status != 0 {
            throw YagartoError.processLaunchFailed(
                command.executable,
                String(cString: strerror(status))
            )
        }

        var childPID = pid_t(0)
        var arguments = ([command.executable] + command.args).map { strdup($0) }
        guard arguments.allSatisfy({ $0 != nil }) else {
            for pointer in arguments {
                if let pointer { free(pointer) }
            }
            throw YagartoError.internalFailure("无法分配交互进程参数。")
        }
        defer {
            for pointer in arguments {
                if let pointer { free(pointer) }
            }
        }
        arguments.append(nil)
        let spawnStatus = arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &childPID,
                buffer[0],
                &fileActions,
                &attributes,
                buffer.baseAddress,
                environ
            )
        }
        guard spawnStatus == 0 else {
            throw YagartoError.processLaunchFailed(
                command.executable,
                String(cString: strerror(spawnStatus))
            )
        }

        InteractiveProcessSignalState.processGroup = childPID
        let terminalFileDescriptor = STDIN_FILENO
        let originalForegroundGroup = isatty(terminalFileDescriptor) == 1
            ? tcgetpgrp(terminalFileDescriptor)
            : pid_t(-1)
        var previousTTOUHandler: sig_t?
        if originalForegroundGroup >= 0 {
            previousTTOUHandler = Darwin.signal(SIGTTOU, SIG_IGN)
            if tcsetpgrp(terminalFileDescriptor, childPID) != 0 {
                let errorCode = errno
                _ = Darwin.kill(-childPID, SIGKILL)
                _ = Darwin.kill(childPID, SIGCONT)
                var ignoredStatus = Int32(0)
                _ = waitpid(childPID, &ignoredStatus, 0)
                throw YagartoError.processLaunchFailed(
                    command.executable,
                    String(cString: strerror(errorCode))
                )
            }
        }
        defer {
            if originalForegroundGroup >= 0 {
                _ = tcsetpgrp(terminalFileDescriptor, originalForegroundGroup)
                _ = Darwin.signal(SIGTTOU, previousTTOUHandler)
            }
        }

        if InteractiveProcessSignalState.receivedSignal != 0 {
            _ = Darwin.kill(
                -childPID,
                InteractiveProcessSignalState.receivedSignal
            )
        }
        _ = Darwin.kill(childPID, SIGCONT)

        var waitStatus = Int32(0)
        while true {
            let result = waitpid(childPID, &waitStatus, 0)
            if result == childPID {
                break
            }
            if result == -1 && errno == EINTR {
                continue
            }
            if result == -1 {
                throw YagartoError.processLaunchFailed(
                    command.executable,
                    String(cString: strerror(errno))
                )
            }
        }
        terminateRemainingProcessGroup(childPID)

        if InteractiveProcessSignalState.receivedSignal != 0 {
            return ProcessTermination(
                reason: .uncaughtSignal,
                status: InteractiveProcessSignalState.receivedSignal
            )
        }

        let terminatingSignal = waitStatus & 0x7F
        if terminatingSignal != 0 && terminatingSignal != 0x7F {
            return ProcessTermination(reason: .uncaughtSignal, status: terminatingSignal)
        }
        return ProcessTermination(reason: .exit, status: (waitStatus >> 8) & 0xFF)
    }
}

private enum InteractiveProcessSignalState {
    static let lock = NSLock()
    nonisolated(unsafe) static var processGroup = pid_t(0)
    nonisolated(unsafe) static var receivedSignal = Int32(0)
}

private func forwardInteractiveProcessSignal(_ signalNumber: Int32) {
    InteractiveProcessSignalState.receivedSignal = signalNumber
    let processGroup = InteractiveProcessSignalState.processGroup
    if processGroup > 0 {
        _ = Darwin.kill(-processGroup, signalNumber)
    }
}

private func terminateRemainingProcessGroup(_ processGroup: pid_t) {
    guard processGroup > 0 else { return }
    errno = 0
    guard Darwin.kill(-processGroup, 0) == 0 || errno != ESRCH else { return }

    _ = Darwin.kill(-processGroup, SIGTERM)
    for _ in 0..<100 {
        errno = 0
        if Darwin.kill(-processGroup, 0) == -1, errno == ESRCH {
            return
        }
        usleep(10_000)
    }
    _ = Darwin.kill(-processGroup, SIGKILL)
    for _ in 0..<100 {
        errno = 0
        if Darwin.kill(-processGroup, 0) == -1, errno == ESRCH {
            return
        }
        usleep(10_000)
    }
}

private typealias SpawnAddChdir = @convention(c) (
    UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
    UnsafePointer<CChar>?
) -> Int32

private func addSpawnWorkingDirectory(
    _ fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>
) -> Int32 {
    guard let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "posix_spawn_file_actions_addchdir_np"
    ) else {
        return ENOSYS
    }
    let function = unsafeBitCast(symbol, to: SpawnAddChdir.self)
    return function(fileActions, path)
}
