// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoCore

final class GDBMISessionTests: XCTestCase {
    func testTransportUsesPOSIXSpawnWithPreExecProcessGroup() {
        XCTAssertEqual(GDBMISession.launchStrategy, .posixSpawnProcessGroup)
    }

    func testArgumentsContainExactlyOneMI3InterpreterAndPreserveEverythingElse() throws {
        let original = [
            "-q", "--interpreter", "mi2",
            "-ex", "target remote | exec '/路径/qemu system-arm' '-gdb' 'stdio'",
            "-i=mi3", "-ex", "monitor reset halt"
        ]

        let normalized = try GDBMISession.normalizedArguments(original)

        XCTAssertEqual(normalized.filter { $0 == "--interpreter=mi3" }.count, 1)
        XCTAssertEqual(normalized, [
            "-q", "--interpreter=mi3",
            "-ex", "target remote | exec '/路径/qemu system-arm' '-gdb' 'stdio'",
            "-ex", "monitor reset halt"
        ])

        XCTAssertEqual(
            try GDBMISession.normalizedArguments(["-q", "-ex", "file demo.elf"]),
            ["--interpreter=mi3", "-q", "-ex", "file demo.elf"]
        )
    }

    func testArgumentNormalizerTreatsOptionValuesAsOpaqueArguments() throws {
        let arguments = [
            "-ex", "--interpreter=sentinel",
            "--eval-command", "target remote | exec '/路径/qemu system-arm' '-gdb' 'stdio'",
            "-x", "--interpreter=commands.gdb",
            "--command", "-leading-command-file",
            "--interpreter=mi2"
        ]

        XCTAssertEqual(try GDBMISession.normalizedArguments(arguments), [
            "-ex", "--interpreter=sentinel",
            "--eval-command", "target remote | exec '/路径/qemu system-arm' '-gdb' 'stdio'",
            "-x", "--interpreter=commands.gdb",
            "--command", "-leading-command-file",
            "--interpreter=mi3"
        ])
    }

    func testArgumentNormalizerPreservesEverySupportedValueTakingOptionPair() throws {
        let options = [
            "-b", "--baud", "-c", "--core", "-cd", "--cd", "-d", "--directory",
            "-D", "--data-directory", "-e", "--exec", "-ex", "--eval-command",
            "-iex", "--init-eval-command", "-ix", "--init-command", "-l", "-p", "--pid",
            "-s", "--symbols", "-se", "--se", "-tty", "--tty", "-x", "--command"
        ]

        for option in options {
            let value = "--interpreter=value-for-\(option)"
            XCTAssertEqual(
                try GDBMISession.normalizedArguments([option, value]),
                ["--interpreter=mi3", option, value],
                option
            )
            XCTAssertThrowsError(try GDBMISession.normalizedArguments([option]), option) { error in
                XCTAssertEqual(
                    error as? GDBMISessionError,
                    .missingOptionValue(option: option)
                )
            }
            if option.hasPrefix("--") {
                XCTAssertEqual(
                    try GDBMISession.normalizedArguments(["\(option)=\(value)"]),
                    ["--interpreter=mi3", "\(option)=\(value)"],
                    option
                )
                XCTAssertThrowsError(
                    try GDBMISession.normalizedArguments(["\(option)="]),
                    option
                ) { error in
                    XCTAssertEqual(
                        error as? GDBMISessionError,
                        .missingOptionValue(option: option)
                    )
                }
            }
        }
    }

    func testArgumentNormalizerOnlyRewritesExactTopLevelInterpreterForms() throws {
        let arguments = [
            "-q", "--interpreter", "mi2", "-i=mi",
            "--interpreter=mi3", "-i", "mi2",
            "--interpreter-mode=sentinel", "-i-extra", "--args",
            "/tmp/program", "--interpreter=inferior-argument"
        ]

        XCTAssertEqual(try GDBMISession.normalizedArguments(arguments), [
            "-q", "--interpreter=mi3",
            "--interpreter-mode=sentinel", "-i-extra", "--args",
            "/tmp/program", "--interpreter=inferior-argument"
        ])
    }

    func testArgumentNormalizerHonorsTheOptionTerminator() throws {
        XCTAssertEqual(
            try GDBMISession.normalizedArguments([
                "-q", "--", "/tmp/program", "--interpreter=program-argument"
            ]),
            [
                "--interpreter=mi3", "-q", "--", "/tmp/program",
                "--interpreter=program-argument"
            ]
        )
    }

    func testArgumentNormalizerRejectsOrphanValueTakingOptions() throws {
        for option in ["-ex", "--eval-command", "-x", "--command", "--interpreter", "-i"] {
            XCTAssertThrowsError(try GDBMISession.normalizedArguments([option]), option) { error in
                XCTAssertEqual(
                    error as? GDBMISessionError,
                    .missingOptionValue(option: option)
                )
            }
        }
        for option in ["--interpreter=", "-i="] {
            XCTAssertThrowsError(try GDBMISession.normalizedArguments([option]), option) { error in
                XCTAssertEqual(
                    error as? GDBMISessionError,
                    .missingOptionValue(option: String(option.dropLast()))
                )
            }
        }
        XCTAssertThrowsError(
            try GDBMISession.normalizedArguments(["--interpreter", "-ex", "file demo.elf"])
        ) { error in
            XCTAssertEqual(
                error as? GDBMISessionError,
                .missingOptionValue(option: "--interpreter")
            )
        }
    }

    func testInvalidLaunchArgumentsFailBeforeSpawning() async throws {
        let fixture = try FakeGDBFixture()
        let session = GDBMISession(
            executable: fixture.script.path,
            arguments: ["--command"],
            workingDirectory: fixture.directory
        )

        do {
            try await session.start()
            XCTFail("expected typed configuration error")
        } catch let error as GDBMISessionError {
            XCTAssertEqual(error, .missingOptionValue(option: "--command"))
            XCTAssertEqual(error.exitCode, .configuration)
        }
        let processIdentifier = await session.processIdentifier
        XCTAssertNil(processIdentifier)
    }

    func testRealProcessPreservesUnicodeWorkingDirectoryAndArgumentBoundaries() async throws {
        let fixture = try FakeGDBFixture(directoryName: "MI 调试 空格")
        let capture = fixture.directory.appendingPathComponent("参数 捕获.json")
        let arguments = [
            "--capture", capture.path,
            "-ex", "file \"/tmp/课程 示例.elf\"",
            "-ex", "target remote | exec '/opt/qemu system-arm' '-gdb' 'stdio'"
        ]
        let session = GDBMISession(
            executable: fixture.script.path,
            arguments: arguments,
            workingDirectory: fixture.directory
        )

        try await session.start()
        _ = try await session.send("-list-features")
        await session.shutdown(timeout: .seconds(1))

        let captureData = try Data(contentsOf: capture)
        let captured = try JSONDecoder().decode(FakeGDBCapture.self, from: captureData)
        var expectedDirectory = stat()
        var actualDirectory = stat()
        let expectedStatus = fixture.directory.path.withCString {
            Darwin.lstat($0, &expectedDirectory)
        }
        let actualStatus = captured.cwd.withCString {
            Darwin.lstat($0, &actualDirectory)
        }
        XCTAssertEqual(expectedStatus, 0)
        XCTAssertEqual(actualStatus, 0)
        XCTAssertEqual(expectedDirectory.st_dev, actualDirectory.st_dev)
        XCTAssertEqual(expectedDirectory.st_ino, actualDirectory.st_ino)
        XCTAssertEqual(captured.arguments, try GDBMISession.normalizedArguments(arguments))
    }

    func testOutOfOrderResponsesCorrelateToConcurrentTokens() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        try await session.start()

        async let first = session.send("-reverse-one")
        try await Task.sleep(for: .milliseconds(20))
        async let second = session.send("-reverse-two")
        let records = try await [first, second]

        XCTAssertNotEqual(records[0].token, records[1].token)
        XCTAssertEqual(records[0].results["reply"]?.constant, "first")
        XCTAssertEqual(records[1].results["reply"]?.constant, "second")
        await session.shutdown(timeout: .seconds(1))
    }

    func testMIStreamsStderrAsyncAndPromptAreSeparateEvents() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        let stream = await session.events()
        try await session.start()

        let events = try await collectFirstEvents(5, from: stream)

        XCTAssertTrue(events.contains(.console("控制台\n")))
        XCTAssertTrue(events.contains(.target("目标")))
        XCTAssertTrue(events.contains(.log("日志")))
        XCTAssertTrue(events.contains(.stderr("诊断 stderr")))
        XCTAssertTrue(events.contains(.prompt))
        await session.shutdown(timeout: .seconds(1))
    }

    func testMultipleEventSubscribersReceiveTheSameLaunchEvents() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        let first = await session.events()
        let second = await session.events()
        try await session.start()

        async let firstSubscriber = collectFirstEvents(5, from: first)
        async let secondSubscriber = collectFirstEvents(5, from: second)
        let received = try await [firstSubscriber, secondSubscriber]

        XCTAssertEqual(received[0], received[1])
        XCTAssertEqual(received[0].count, 5)
        await session.shutdown(timeout: .seconds(1))
    }

    func testCommandErrorIsStructuredAndIncludesGDBMessage() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        try await session.start()

        do {
            _ = try await session.send("-fail")
            XCTFail("expected structured command failure")
        } catch let GDBMISessionError.commandFailed(failure) {
            XCTAssertEqual(failure.command, "-fail")
            XCTAssertEqual(failure.message, "命令失败")
            XCTAssertNotNil(failure.token)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await session.shutdown(timeout: .seconds(1))
    }

    func testExitedResultCompletesItsRequestWithoutEndingTheSession() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        try await session.start()

        let exited = try await session.send("-inferior-exited-result")
        XCTAssertEqual(exited.resultClass, .exited)
        let subsequent = try await session.send("-list-features")
        XCTAssertEqual(subsequent.resultClass, .done)

        await session.shutdown(timeout: .seconds(1))
    }

    func testEOFResumesEveryPendingRequestExactlyOnce() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        try await session.start()

        async let hanging = session.send("-hang")
        try await Task.sleep(for: .milliseconds(20))
        _ = try? await session.send("-eof")

        do {
            _ = try await hanging
            XCTFail("expected EOF")
        } catch let error as GDBMISessionError {
            XCTAssertTrue(error == .endOfFile || error.isProcessExit)
        }
        await session.shutdown(timeout: .milliseconds(100))
    }

    func testTerminalProcessClosesEventStreamsWithoutExplicitShutdown() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        let stream = await session.events()
        try await session.start()

        _ = try? await session.send("-eof")
        let count = try await collectUntilFinished(stream, timeout: .seconds(1))

        XCTAssertGreaterThan(count, 0)
        await session.shutdown(timeout: .milliseconds(100))
    }

    func testCancellingOneRequestDoesNotPoisonLaterRequests() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session()
        try await session.start()
        let hanging = Task { try await session.send("-hang") }
        try await Task.sleep(for: .milliseconds(20))

        hanging.cancel()

        do {
            _ = try await hanging.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let later = try await session.send("-list-features")
        XCTAssertEqual(later.resultClass, .done)
        await session.shutdown(timeout: .seconds(1))
    }

    func testEventBufferIsBoundedAndReportsDrops() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session(eventBufferLimit: 3)
        let heldStream = await session.events()
        try await session.start()

        _ = try await session.send("-burst")

        let dropped = await session.droppedEventCount
        XCTAssertGreaterThan(dropped, 0)
        _ = heldStream
        await session.shutdown(timeout: .seconds(1))
    }

    func testOversizedStdoutLineIsDroppedAndFollowingResponseStillCompletes() async throws {
        let fixture = try FakeGDBFixture()
        let session = fixture.session(maxLineBytes: 64)
        let stream = await session.events()
        try await session.start()

        let response = try await session.send("-oversized")
        let events = try await collectFirstEvents(6, from: stream)

        XCTAssertEqual(response.resultClass, .done)
        XCTAssertTrue(events.contains(.parseError(.lineTooLong(limit: 64))))
        await session.shutdown(timeout: .seconds(1))
    }

    func testLaunchFailureMapsToMissingToolExitFive() async {
        let session = GDBMISession(
            executable: "/definitely/missing/gdb",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        do {
            try await session.start()
            XCTFail("expected launch failure")
        } catch let error as GDBMISessionError {
            XCTAssertEqual(error.exitCode, .missingTool)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTwentyRealStartExitCyclesLeaveNoChildProcess() async throws {
        let fixture = try FakeGDBFixture()
        for _ in 0..<20 {
            let session = fixture.session()
            try await session.start()
            guard let pid = await session.processIdentifier else {
                return XCTFail("missing child pid")
            }
            await session.shutdown(timeout: .seconds(1))
            XCTAssertEqual(Darwin.kill(pid, 0), -1, "pid \(pid) still exists")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testInstalledArmGDBMI3HandshakeWhenAvailable() async throws {
        let executable = "/opt/homebrew/bin/arm-none-eabi-gdb"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("未安装 arm-none-eabi-gdb，跳过真实 MI3 handshake")
        }
        let session = GDBMISession(
            executable: executable,
            arguments: ["-q", "-nx"],
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        try await session.start()
        let response = try await session.send("-list-features")
        XCTAssertEqual(response.resultClass, .done)
        await session.shutdown(timeout: .seconds(2))
    }

    func testInstalledArmGDBDecodesRealEscapeConsoleStreamWhenAvailable() async throws {
        let executable = "/opt/homebrew/bin/arm-none-eabi-gdb"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("未安装 arm-none-eabi-gdb，跳过真实 \\e stream 回归")
        }
        let session = GDBMISession(
            executable: executable,
            arguments: ["-q", "-nx"],
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        let stream = await session.events()
        try await session.start()
        let consoleTask = Task { try await firstConsole(from: stream, timeout: .seconds(1)) }

        do {
            _ = try await session.send(
                #"-interpreter-exec console "printf \"\\e[31mRED\\e[0m\"""#
            )
            let console = try await consoleTask.value
            await session.shutdown(timeout: .seconds(2))
            XCTAssertEqual(console, "\u{1B}[31mRED\u{1B}[0m")
        } catch {
            consoleTask.cancel()
            await session.shutdown(timeout: .seconds(2))
            throw error
        }
    }

    func testUnresponsiveGDBEscalatesToProcessGroupKillAndReapsParent() async throws {
        let fixture = try StubbornGDBFixture()
        let session = GDBMISession(
            executable: fixture.script.path,
            arguments: fixture.arguments,
            workingDirectory: fixture.directory
        )
        try await session.start()
        let capturedParentPID = await session.processIdentifier
        let parentPID = try XCTUnwrap(capturedParentPID)
        let childPID = try await fixture.waitForChildPID()
        XCTAssertEqual(Darwin.getpgid(parentPID), parentPID)
        XCTAssertEqual(Darwin.getpgid(childPID), parentPID)

        await session.shutdown(timeout: .milliseconds(50))

        try await assertProcessDisappears(parentPID)
        try await assertProcessDisappears(childPID)
    }

    func testGracefulGDBExitStillReapsRemainingProcessGroupChildren() async throws {
        let fixture = try StubbornGDBFixture(exitOnGDBExit: true)
        let session = GDBMISession(
            executable: fixture.script.path,
            arguments: fixture.arguments,
            workingDirectory: fixture.directory
        )
        try await session.start()
        let capturedParentPID = await session.processIdentifier
        let parentPID = try XCTUnwrap(capturedParentPID)
        let childPID = try await fixture.waitForChildPID()

        let clock = ContinuousClock()
        let started = clock.now
        await session.shutdown(timeout: .seconds(1))
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(2))
        try await assertProcessDisappears(parentPID)
        try await assertProcessDisappears(childPID)
    }

    func testParentExitRecoversPendingBeforeDescendantClosesStdout() async throws {
        let fixture = try StubbornGDBFixture()
        let session = GDBMISession(
            executable: fixture.script.path,
            arguments: fixture.arguments,
            workingDirectory: fixture.directory
        )
        try await session.start()
        _ = try await fixture.waitForChildPID()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await session.send("-parent-exit")
            XCTFail("expected process exit")
        } catch let error as GDBMISessionError {
            XCTAssertTrue(error.isProcessExit)
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        await session.shutdown(timeout: .milliseconds(50))
    }

    private func assertProcessDisappears(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("pid \(pid) remained after shutdown")
    }
}

private func collectFirstEvents(
    _ count: Int,
    from stream: AsyncStream<GDBMIEvent>
) async throws -> [GDBMIEvent] {
    try await withThrowingTaskGroup(of: [GDBMIEvent].self) { group in
        group.addTask {
            var events: [GDBMIEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count { return events }
            }
            return events
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw FakeGDBTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next() ?? []
    }
}

private func collectUntilFinished(
    _ stream: AsyncStream<GDBMIEvent>,
    timeout: Duration
) async throws -> Int {
    try await withThrowingTaskGroup(of: Int.self) { group in
        group.addTask {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FakeGDBTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next() ?? 0
    }
}

private func firstConsole(
    from stream: AsyncStream<GDBMIEvent>,
    timeout: Duration
) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            for await event in stream {
                if case .console(let text) = event { return text }
            }
            throw FakeGDBTestError.timeout
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FakeGDBTestError.timeout
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw FakeGDBTestError.timeout }
        return value
    }
}

private struct FakeGDBCapture: Codable {
    let cwd: String
    let arguments: [String]
}

private enum FakeGDBTestError: Error {
    case timeout
}

private final class FakeGDBFixture {
    let directory: URL
    let script: URL

    init(directoryName: String = UUID().uuidString) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fake gdb.py")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func session(eventBufferLimit: Int = 64, maxLineBytes: Int = 4_096) -> GDBMISession {
        GDBMISession(
            executable: script.path,
            arguments: [],
            workingDirectory: directory,
            eventBufferLimit: eventBufferLimit,
            maxLineBytes: maxLineBytes
        )
    }

    private static let source = #"""
#!/usr/bin/python3
import json, os, sys

if "--capture" in sys.argv:
    index = sys.argv.index("--capture")
    with open(sys.argv[index + 1], "w", encoding="utf-8") as handle:
        json.dump({"cwd": os.getcwd(), "arguments": sys.argv[1:]}, handle, ensure_ascii=False)

def out(value):
    sys.stdout.write(value + "\n")
    sys.stdout.flush()

out('~"\\346\\216\\247\\345\\210\\266\\345\\217\\260\\n"')
out('@"\\347\\233\\256\\346\\240\\207"')
out('&"\\346\\227\\245\\345\\277\\227"')
sys.stderr.write("诊断 stderr\n")
sys.stderr.flush()
out("(gdb)")

held = None
for raw in sys.stdin:
    raw = raw.rstrip("\r\n")
    pos = 0
    while pos < len(raw) and raw[pos].isdigit():
        pos += 1
    token, command = raw[:pos], raw[pos:]
    if command == "-reverse-one":
        held = token
    elif command == "-reverse-two":
        out(token + '^done,reply="second"')
        out(held + '^done,reply="first"')
        held = None
    elif command == "-fail":
        out(token + '^error,msg="\\345\\221\\275\\344\\273\\244\\345\\244\\261\\350\\264\\245"')
    elif command == "-inferior-exited-result":
        out(token + "^exited")
    elif command == "-hang":
        pass
    elif command == "-eof":
        sys.exit(23)
    elif command == "-burst":
        for value in range(30):
            out('~"event-%d"' % value)
        out(token + "^done")
    elif command == "-oversized":
        out('~"' + ('x' * 200) + '"')
        out(token + "^done")
    elif command == "-gdb-exit":
        out(token + "^exit")
        sys.exit(0)
    else:
        out(token + "^done")
"""#
}

private final class StubbornGDBFixture {
    let directory: URL
    let script: URL
    let childPIDFile: URL
    let exitOnGDBExit: Bool

    var arguments: [String] {
        [
            "--pid-file", childPIDFile.path,
            "--exit-mode", exitOnGDBExit ? "exit" : "hang"
        ]
    }

    init(exitOnGDBExit: Bool = false) throws {
        self.exitOnGDBExit = exitOnGDBExit
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("stubborn gdb.py")
        childPIDFile = directory.appendingPathComponent("child.pid")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    deinit {
        if let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForChildPID() async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FakeGDBTestError.timeout
    }

    private static let source = #"""
#!/usr/bin/python3
import signal, subprocess, sys, time

pid_file = sys.argv[sys.argv.index("--pid-file") + 1]
exit_on_gdb_exit = sys.argv[sys.argv.index("--exit-mode") + 1] == "exit"
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, lambda *_: exit(0)); time.sleep(5)"
])
with open(pid_file, "w", encoding="ascii") as handle:
    handle.write(str(child.pid))

for raw in sys.stdin:
    raw = raw.rstrip("\r\n")
    pos = 0
    while pos < len(raw) and raw[pos].isdigit():
        pos += 1
    token, command = raw[:pos], raw[pos:]
    if command == "-parent-exit":
        sys.exit(17)
    elif command == "-gdb-exit":
        if exit_on_gdb_exit:
            sys.exit(0)
    else:
        sys.stdout.write(token + "^done\n")
        sys.stdout.flush()
"""#
}
