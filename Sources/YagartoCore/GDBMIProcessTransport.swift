// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum GDBMIProcessLaunchStrategy: Equatable, Sendable {
    case posixSpawnProcessGroup
}

final class GDBMIChildProcess: Sendable {
    let processIdentifier: pid_t
    let processGroupIdentifier: pid_t

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        processGroupIdentifier = processIdentifier
    }

    static func spawn(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        standardInput: Pipe,
        standardOutput: Pipe,
        standardError: Pipe
    ) throws -> GDBMIChildProcess {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let fileActionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsStatus == 0 else {
            throw launchError(executable, status: fileActionsStatus)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let inputRead = standardInput.fileHandleForReading.fileDescriptor
        let inputWrite = standardInput.fileHandleForWriting.fileDescriptor
        let outputRead = standardOutput.fileHandleForReading.fileDescriptor
        let outputWrite = standardOutput.fileHandleForWriting.fileDescriptor
        let errorRead = standardError.fileHandleForReading.fileDescriptor
        let errorWrite = standardError.fileHandleForWriting.fileDescriptor
        for status in [
            posix_spawn_file_actions_adddup2(&fileActions, inputRead, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, inputWrite),
            posix_spawn_file_actions_addclose(&fileActions, outputRead),
            posix_spawn_file_actions_addclose(&fileActions, errorRead),
            posix_spawn_file_actions_addclose(&fileActions, inputRead),
            posix_spawn_file_actions_addclose(&fileActions, outputWrite),
            posix_spawn_file_actions_addclose(&fileActions, errorWrite)
        ] where status != 0 {
            throw launchError(executable, status: status)
        }

        let chdirStatus = workingDirectory.path.withCString {
            addSpawnWorkingDirectory(&fileActions, path: $0)
        }
        guard chdirStatus == 0 else {
            throw launchError(executable, status: chdirStatus)
        }

        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else {
            throw launchError(executable, status: attributesStatus)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
            sigaddset(&defaultSignals, signalNumber)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        for status in [
            posix_spawnattr_setflags(&attributes, flags),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        ] where status != 0 {
            throw launchError(executable, status: status)
        }

        var childPID = pid_t(0)
        var argv = ([executable] + arguments).map { strdup($0) }
        guard argv.allSatisfy({ $0 != nil }) else {
            for pointer in argv where pointer != nil { free(pointer) }
            throw GDBMISessionError.launchFailed(
                executable: executable,
                detail: "unable to allocate argv"
            )
        }
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
        }
        argv.append(nil)
        let spawnStatus = argv.withUnsafeMutableBufferPointer { buffer in
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
            throw launchError(executable, status: spawnStatus)
        }
        return GDBMIChildProcess(processIdentifier: childPID)
    }

    func waitForTermination() -> Result<ProcessTermination, GDBMISessionError> {
        var status = Int32(0)
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result == -1 && errno == EINTR
        guard result == processIdentifier else {
            return .failure(.waitFailed(String(cString: strerror(errno))))
        }
        let statusKind = status & 0x7F
        if statusKind != 0 && statusKind != 0x7F {
            return .success(.init(reason: .uncaughtSignal, status: statusKind))
        }
        return .success(.init(reason: .exit, status: (status >> 8) & 0xFF))
    }

    func signalGroup(_ signal: Int32) {
        _ = Darwin.kill(-processGroupIdentifier, signal)
    }

    func groupExists() -> Bool {
        errno = 0
        if Darwin.kill(-processGroupIdentifier, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func launchError(_ executable: String, status: Int32) -> GDBMISessionError {
        .launchFailed(executable: executable, detail: String(cString: strerror(status)))
    }
}

private typealias GDBMISpawnAddChdir = @convention(c) (
    UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
    UnsafePointer<CChar>?
) -> Int32

private func addSpawnWorkingDirectory(
    _ fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    path: UnsafePointer<CChar>
) -> Int32 {
    guard let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "posix_spawn_file_actions_addchdir_np"
    ) else {
        return ENOSYS
    }
    let function = unsafeBitCast(symbol, to: GDBMISpawnAddChdir.self)
    return function(fileActions, path)
}
