// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum TimedProcessCapabilityProbe {
    static let defaultTimeout: TimeInterval = 2

    static func run(
        _ command: CommandSpec,
        timeout: TimeInterval = defaultTimeout
    ) -> Bool {
        guard timeout > 0 else { return false }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let nullPath = "/dev/null"
        for status in [
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                nullPath,
                O_RDONLY,
                0
            ),
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                nullPath,
                O_WRONLY,
                0
            ),
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                nullPath,
                O_WRONLY,
                0
            )
        ] where status != 0 {
            return false
        }
        let chdirStatus = command.workingDirectory.path.withCString {
            addCapabilityProbeWorkingDirectory(&fileActions, path: $0)
        }
        guard chdirStatus == 0 else { return false }

        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
            sigaddset(&defaultSignals, signalNumber)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        for status in [
            posix_spawnattr_setflags(&attributes, flags),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        ] where status != 0 {
            return false
        }

        var arguments = ([command.executable] + command.args).map { strdup($0) }
        guard arguments.allSatisfy({ $0 != nil }) else {
            for pointer in arguments where pointer != nil { free(pointer) }
            return false
        }
        defer {
            for pointer in arguments where pointer != nil { free(pointer) }
        }
        arguments.append(nil)

        var childPID = pid_t(0)
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
        guard spawnStatus == 0 else { return false }

        return waitForCapabilityProcess(childPID, timeout: timeout)
    }

    private static func waitForCapabilityProcess(
        _ childPID: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        var status = Int32(0)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID {
                terminateRemainingProcessGroup(childPID)
                return processExitedSuccessfully(status)
            }
            if result == -1, errno != EINTR {
                terminateAndReapProcessGroup(childPID, leaderAlreadyReaped: false)
                return false
            }
            usleep(10_000)
        }

        terminateAndReapProcessGroup(childPID, leaderAlreadyReaped: false)
        return false
    }

    private static func terminateAndReapProcessGroup(
        _ processGroup: pid_t,
        leaderAlreadyReaped: Bool
    ) {
        var leaderReaped = leaderAlreadyReaped
        _ = Darwin.kill(-processGroup, SIGTERM)
        let termDeadline = Date().addingTimeInterval(0.1)
        while Date() < termDeadline {
            leaderReaped = leaderReaped || reapLeaderIfExited(processGroup)
            if !processGroupExists(processGroup) { return }
            usleep(10_000)
        }

        _ = Darwin.kill(-processGroup, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline {
            leaderReaped = leaderReaped || reapLeaderIfExited(processGroup)
            if leaderReaped, !processGroupExists(processGroup) { return }
            usleep(10_000)
        }
        if !leaderReaped {
            _ = reapLeaderIfExited(processGroup)
        }
    }

    private static func terminateRemainingProcessGroup(_ processGroup: pid_t) {
        guard processGroupExists(processGroup) else { return }
        _ = Darwin.kill(-processGroup, SIGKILL)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, processGroupExists(processGroup) {
            usleep(10_000)
        }
    }

    private static func reapLeaderIfExited(_ childPID: pid_t) -> Bool {
        var ignoredStatus = Int32(0)
        while true {
            let result = waitpid(childPID, &ignoredStatus, WNOHANG)
            if result == childPID { return true }
            if result == 0 { return false }
            if result == -1, errno == EINTR { continue }
            return result == -1 && errno == ECHILD
        }
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func processExitedSuccessfully(_ status: Int32) -> Bool {
        let statusKind = status & 0x7F
        return statusKind == 0 && ((status >> 8) & 0xFF) == 0
    }
}

private typealias CapabilityProbeSpawnAddChdir = @convention(c) (
    UnsafeMutablePointer<posix_spawn_file_actions_t?>?,
    UnsafePointer<CChar>?
) -> Int32

private func addCapabilityProbeWorkingDirectory(
    _ fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    path: UnsafePointer<CChar>
) -> Int32 {
    guard let symbol = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "posix_spawn_file_actions_addchdir_np"
    ) else {
        return ENOSYS
    }
    let function = unsafeBitCast(symbol, to: CapabilityProbeSpawnAddChdir.self)
    return function(fileActions, path)
}
