// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Dispatch

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
        let termination = try runInteractiveTermination(command)
        if termination.reason == .uncaughtSignal && termination.status == SIGINT {
            return YagartoExitCode.interrupted.rawValue
        }
        if termination.reason == .uncaughtSignal {
            return 128 + termination.status
        }
        return termination.status
    }

    public func runInteractiveTermination(
        _ command: CommandSpec
    ) throws -> ProcessTermination {
        try interactiveExecution(command)
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
        InteractiveProcessCoordinator.lock.lock()
        defer { InteractiveProcessCoordinator.lock.unlock() }

        let handledSignals = [SIGINT, SIGTERM, SIGHUP]
        let signalMonitor = try InteractiveSignalMonitor(
            signals: handledSignals,
            executable: command.executable
        )

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
        for signalNumber in handledSignals + [SIGTTOU, SIGTTIN, SIGTSTP] {
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

        let terminalController: InteractiveTerminalController
        do {
            terminalController = try InteractiveTerminalController(
                childProcessGroup: childPID,
                executable: command.executable
            )
        } catch {
            _ = Darwin.kill(-childPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGCONT)
            var ignoredStatus = Int32(0)
            _ = waitpid(childPID, &ignoredStatus, 0)
            throw error
        }
        defer { terminalController.restoreForExit() }

        _ = Darwin.kill(childPID, SIGCONT)
        do {
            return try superviseInteractiveProcess(
                childPID: childPID,
                signalMonitor: signalMonitor,
                terminalController: terminalController,
                executable: command.executable
            )
        } catch {
            _ = Darwin.kill(-childPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGCONT)
            var ignoredStatus = Int32(0)
            _ = waitpid(childPID, &ignoredStatus, 0)
            throw error
        }
    }
}

private enum InteractiveProcessCoordinator {
    static let lock = NSLock()
}

private final class InteractiveSignalMonitor {
    private let descriptor: Int32
    private let executable: String
    private var previousHandlers: [(signal: Int32, handler: sig_t?)] = []
    private var isClosed = false

    init(signals: [Int32], executable: String) throws {
        self.executable = executable
        descriptor = kqueue()
        guard descriptor >= 0 else {
            throw YagartoError.processLaunchFailed(
                executable,
                String(cString: strerror(errno))
            )
        }

        // EVFILT_SIGNAL records ignored process-directed signals, so no Swift
        // callback executes in async-signal context or shares mutable state.
        for signalNumber in signals {
            previousHandlers.append((
                signalNumber,
                Darwin.signal(signalNumber, SIG_IGN)
            ))
        }

        var registrations = signals.map { signalNumber in
            var event = kevent64_s()
            event.ident = UInt64(signalNumber)
            event.filter = Int16(EVFILT_SIGNAL)
            event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
            return event
        }
        let registrationStatus = registrations.withUnsafeMutableBufferPointer { buffer in
            Darwin.kevent64(
                descriptor,
                buffer.baseAddress,
                Int32(buffer.count),
                nil,
                0,
                0,
                nil
            )
        }
        guard registrationStatus == 0 else {
            let errorCode = errno
            closeAndRestore()
            throw YagartoError.processLaunchFailed(
                executable,
                String(cString: strerror(errorCode))
            )
        }
    }

    deinit {
        closeAndRestore()
    }

    func nextSignal(waitNanoseconds: UInt64) throws -> Int32? {
        var event = kevent64_s()
        var timeout = timespec(
            tv_sec: Int(waitNanoseconds / 1_000_000_000),
            tv_nsec: Int(waitNanoseconds % 1_000_000_000)
        )
        while true {
            let eventCount = Darwin.kevent64(
                descriptor,
                nil,
                0,
                &event,
                1,
                0,
                &timeout
            )
            if eventCount == 1 {
                return Int32(event.ident)
            }
            if eventCount == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            throw YagartoError.processLaunchFailed(
                executable,
                String(cString: strerror(errno))
            )
        }
    }

    private func closeAndRestore() {
        guard !isClosed else { return }
        isClosed = true
        for saved in previousHandlers.reversed() {
            _ = Darwin.signal(saved.signal, saved.handler)
        }
        _ = Darwin.close(descriptor)
    }
}

private final class InteractiveTerminalController {
    private let descriptor = STDIN_FILENO
    private let parentProcessGroup: pid_t
    private let childProcessGroup: pid_t
    private let executable: String
    private let hasControllingTerminal: Bool
    private var handedTerminalToChild = false

    init(childProcessGroup: pid_t, executable: String) throws {
        self.parentProcessGroup = getpgrp()
        self.childProcessGroup = childProcessGroup
        self.executable = executable
        if isatty(descriptor) == 1, tcgetpgrp(descriptor) >= 0 {
            hasControllingTerminal = true
        } else {
            hasControllingTerminal = false
        }

        if hasControllingTerminal, tcgetpgrp(descriptor) == parentProcessGroup {
            try handTerminalToChild()
        }
    }

    func childDidStop(signal stopSignal: Int32) throws {
        guard hasControllingTerminal else { return }
        reclaimTerminalIfOwnedByChild()

        let previousHandler: sig_t?
        if stopSignal == SIGSTOP {
            previousHandler = nil
        } else {
            previousHandler = Darwin.signal(stopSignal, SIG_DFL)
        }
        _ = Darwin.kill(0, stopSignal)
        if stopSignal != SIGSTOP {
            _ = Darwin.signal(stopSignal, previousHandler)
        }

        // `fg` makes our group foreground before SIGCONT, while `bg` does not.
        // Only the former receives the TTY; both resume the stopped child group.
        if tcgetpgrp(descriptor) == parentProcessGroup {
            try handTerminalToChild()
        }
        _ = Darwin.kill(-childProcessGroup, SIGCONT)
    }

    func restoreForExit() {
        guard hasControllingTerminal else { return }
        reclaimTerminalIfOwnedByChild()
    }

    private func handTerminalToChild() throws {
        guard tcgetpgrp(descriptor) == parentProcessGroup else { return }
        try setForegroundProcessGroup(childProcessGroup)
        handedTerminalToChild = true
    }

    private func reclaimTerminalIfOwnedByChild() {
        guard handedTerminalToChild,
              tcgetpgrp(descriptor) == childProcessGroup else {
            return
        }
        try? setForegroundProcessGroup(parentProcessGroup)
        handedTerminalToChild = false
    }

    private func setForegroundProcessGroup(_ processGroup: pid_t) throws {
        let previousHandler = Darwin.signal(SIGTTOU, SIG_IGN)
        defer { _ = Darwin.signal(SIGTTOU, previousHandler) }
        guard tcsetpgrp(descriptor, processGroup) == 0 else {
            throw YagartoError.processLaunchFailed(
                executable,
                String(cString: strerror(errno))
            )
        }
    }
}

private func superviseInteractiveProcess(
    childPID: pid_t,
    signalMonitor: InteractiveSignalMonitor,
    terminalController: InteractiveTerminalController,
    executable: String
) throws -> ProcessTermination {
    enum EscalationStage {
        case waiting
        case originalSignal
        case terminate
        case kill
    }

    let graceNanoseconds: UInt64 = 200_000_000
    let killReapNanoseconds: UInt64 = 1_000_000_000
    let pollNanoseconds: UInt64 = 20_000_000
    var stage = EscalationStage.waiting
    var deadline: UInt64?
    var receivedSignal: Int32?
    var waitStatus = Int32(0)
    var childReaped = false

    while true {
        if !childReaped {
            let waitResult = waitpid(
                childPID,
                &waitStatus,
                WNOHANG | WUNTRACED | WCONTINUED
            )
            if waitResult == childPID {
                let statusKind = waitStatus & 0x7F
                let stopSignal = (waitStatus >> 8) & 0xFF
                if statusKind == 0x7F, stopSignal == SIGCONT {
                    continue
                }
                if statusKind == 0x7F {
                    try terminalController.childDidStop(signal: stopSignal)
                    continue
                }
                childReaped = true
            } else if waitResult == -1, errno != EINTR {
                let errorCode = errno
                _ = Darwin.kill(-childPID, SIGKILL)
                throw YagartoError.processLaunchFailed(
                    executable,
                    String(cString: strerror(errorCode))
                )
            }
        }

        let groupAlive = processGroupExists(childPID)
        if childReaped && !groupAlive {
            break
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if let currentDeadline = deadline, now >= currentDeadline {
            switch stage {
            case .originalSignal:
                _ = Darwin.kill(-childPID, SIGTERM)
                stage = .terminate
                deadline = now + graceNanoseconds
            case .terminate:
                _ = Darwin.kill(-childPID, SIGKILL)
                stage = .kill
                deadline = now + killReapNanoseconds
            case .kill:
                _ = Darwin.kill(-childPID, SIGKILL)
                throw YagartoError.processLaunchFailed(
                    executable,
                    "受控进程组在 SIGKILL 后仍未于时限内退出。"
                )
            case .waiting:
                break
            }
            continue
        }

        if childReaped && groupAlive && stage == .waiting {
            _ = Darwin.kill(-childPID, SIGTERM)
            stage = .terminate
            deadline = now + graceNanoseconds
            continue
        }

        let remaining = deadline.map { $0 > now ? $0 - now : 0 } ?? pollNanoseconds
        let signalWait = min(pollNanoseconds, remaining)
        if let signalNumber = try signalMonitor.nextSignal(
            waitNanoseconds: signalWait
        ) {
            _ = Darwin.kill(-childPID, signalNumber)
            if receivedSignal == nil {
                receivedSignal = signalNumber
                stage = .originalSignal
                deadline = DispatchTime.now().uptimeNanoseconds + graceNanoseconds
            }
        }
    }

    if let receivedSignal {
        return ProcessTermination(reason: .uncaughtSignal, status: receivedSignal)
    }
    let terminatingSignal = waitStatus & 0x7F
    if terminatingSignal != 0 && terminatingSignal != 0x7F {
        return ProcessTermination(reason: .uncaughtSignal, status: terminatingSignal)
    }
    return ProcessTermination(reason: .exit, status: (waitStatus >> 8) & 0xFF)
}

private func processGroupExists(_ processGroup: pid_t) -> Bool {
    guard processGroup > 0 else { return false }
    errno = 0
    if Darwin.kill(-processGroup, 0) == 0 {
        return true
    }
    return errno != ESRCH
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
