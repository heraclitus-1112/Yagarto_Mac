// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin
import XCTest
@testable import YagartoCore

final class ProcessRunnerTests: XCTestCase {
    func testInteractiveRunnerPreservesExecutableAndArgumentsWithoutShellWrapping() throws {
        let recorder = InteractiveExecutionRecorder(termination: ProcessTermination(
            reason: .exit,
            status: 0
        ))
        let runner = ProcessRunner(interactiveExecution: recorder.execute)
        let command = CommandSpec(
            executable: "/tools/GDB 中文",
            args: ["-ex", "file /tmp/空 格/demo.elf", "$(touch /tmp/nope)"],
            workingDirectory: URL(fileURLWithPath: "/tmp/项目", isDirectory: true)
        )

        XCTAssertEqual(try runner.runInteractive(command), 0)
        XCTAssertEqual(recorder.commands, [command])
    }

    func testInteractiveRunnerMapsSIGINTToExit130() throws {
        let runner = ProcessRunner(interactiveExecution: { _ in
            ProcessTermination(reason: .uncaughtSignal, status: SIGINT)
        })

        XCTAssertEqual(
            try runner.runInteractive(CommandSpec(
                executable: "/tools/gdb",
                args: [],
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )),
            YagartoExitCode.interrupted.rawValue
        )
    }

    func testInteractiveRunnerPreservesNormalExit130TerminationReason() throws {
        let expected = ProcessTermination(reason: .exit, status: 130)
        let runner = ProcessRunner(interactiveExecution: { _ in expected })

        XCTAssertEqual(
            try runner.runInteractiveTermination(CommandSpec(
                executable: "/tools/gdb",
                args: [],
                workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
            )),
            expected
        )
    }

    func testInteractiveRunnerRealPTYCtrlCLeavesShellUsableAndReturns130() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("系统未提供 /usr/bin/perl，跳过真实 PTY helper")
        }
        let fixture = try PTYCLIExecutionFixture(name: "ctrl-c")
        defer { fixture.cleanupProcesses() }
        let terminal = try InteractiveShellPTY()
        defer { terminal.shutdown() }
        XCTAssertTrue(terminal.waitForPrompt(timeout: 2), terminal.transcript)

        let start = terminal.transcript.utf8.count
        try terminal.send(fixture.command(background: false))
        XCTAssertTrue(terminal.waitFor("GDB_READY", after: start, timeout: 3), terminal.transcript)
        XCTAssertNotEqual(terminal.foregroundProcessGroup, terminal.shellPID)

        let interruptStart = terminal.transcript.utf8.count
        try terminal.sendControl(0x03)
        XCTAssertTrue(terminal.waitForPrompt(after: interruptStart, timeout: 3), terminal.transcript)
        let statusStart = terminal.transcript.utf8.count
        try terminal.send("echo AFTER_INT:$?\n")
        XCTAssertTrue(terminal.waitFor("AFTER_INT:130", after: statusStart, timeout: 2), terminal.transcript)
        XCTAssertEqual(terminal.foregroundProcessGroup, terminal.shellPID)
    }

    func testInteractiveRunnerRealPTYCtrlZReclaimsTTYAndFGResumesChildGroup() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("系统未提供 /usr/bin/perl，跳过真实 PTY helper")
        }
        let fixture = try PTYCLIExecutionFixture(name: "ctrl-z")
        defer { fixture.cleanupProcesses() }
        let terminal = try InteractiveShellPTY()
        defer { terminal.shutdown() }
        XCTAssertTrue(terminal.waitForPrompt(timeout: 2), terminal.transcript)

        let start = terminal.transcript.utf8.count
        try terminal.send(fixture.command(background: false))
        XCTAssertTrue(terminal.waitFor("GDB_READY", after: start, timeout: 3), terminal.transcript)

        let stopStart = terminal.transcript.utf8.count
        try terminal.sendControl(0x1A)
        XCTAssertTrue(terminal.waitForPrompt(after: stopStart, timeout: 3), terminal.transcript)
        XCTAssertEqual(terminal.foregroundProcessGroup, terminal.shellPID)
        let shellCheckStart = terminal.transcript.utf8.count
        try terminal.send("echo SHELL_AFTER_STOP\n")
        XCTAssertTrue(
            terminal.waitFor("SHELL_AFTER_STOP", after: shellCheckStart, timeout: 2),
            terminal.transcript
        )

        try? FileManager.default.removeItem(at: fixture.continueMarker)
        let resumeStart = terminal.transcript.utf8.count
        try terminal.send("fg\n")
        XCTAssertTrue(
            waitForPTYCondition(timeout: 3) {
                terminal.drain()
                return FileManager.default.fileExists(atPath: fixture.continueMarker.path)
                    && terminal.contains("GDB_CONT", after: resumeStart)
            },
            terminal.transcript
        )
        XCTAssertNotEqual(terminal.foregroundProcessGroup, terminal.shellPID)

        let finishStart = terminal.transcript.utf8.count
        try terminal.sendControl(0x03)
        XCTAssertTrue(terminal.waitForPrompt(after: finishStart, timeout: 3), terminal.transcript)
    }

    func testInteractiveRunnerBackgroundPTYDoesNotStealForegroundTTY() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("系统未提供 /usr/bin/perl，跳过真实 PTY helper")
        }
        let fixture = try PTYCLIExecutionFixture(name: "background")
        defer { fixture.cleanupProcesses() }
        let terminal = try InteractiveShellPTY()
        defer { terminal.shutdown() }
        XCTAssertTrue(terminal.waitForPrompt(timeout: 2), terminal.transcript)

        let start = terminal.transcript.utf8.count
        try terminal.send(fixture.command(background: true))
        XCTAssertTrue(terminal.waitFor("GDB_READY", after: start, timeout: 3), terminal.transcript)
        XCTAssertEqual(terminal.foregroundProcessGroup, terminal.shellPID)
        let shellCheckStart = terminal.transcript.utf8.count
        try terminal.send("echo BACKGROUND_TTY_OK\n")
        XCTAssertTrue(
            terminal.waitFor("BACKGROUND_TTY_OK", after: shellCheckStart, timeout: 2),
            terminal.transcript
        )

        try terminal.send("kill %1\nwait %1\n")
        XCTAssertTrue(terminal.waitForPrompt(after: terminal.transcript.utf8.count, timeout: 3))
    }

    func testInteractiveRunnerCtrlZThenBGContinuesChildWithoutStealingTTY() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("系统未提供 /usr/bin/perl，跳过真实 PTY helper")
        }
        let fixture = try PTYCLIExecutionFixture(name: "ctrl-z-bg")
        defer { fixture.cleanupProcesses() }
        let terminal = try InteractiveShellPTY()
        defer { terminal.shutdown() }
        XCTAssertTrue(terminal.waitForPrompt(timeout: 2), terminal.transcript)

        let start = terminal.transcript.utf8.count
        try terminal.send(fixture.command(background: false))
        XCTAssertTrue(terminal.waitFor("GDB_READY", after: start, timeout: 3), terminal.transcript)
        let stopStart = terminal.transcript.utf8.count
        try terminal.sendControl(0x1A)
        XCTAssertTrue(terminal.waitForPrompt(after: stopStart, timeout: 3), terminal.transcript)

        try? FileManager.default.removeItem(at: fixture.continueMarker)
        let backgroundStart = terminal.transcript.utf8.count
        try terminal.send("bg\n")
        XCTAssertTrue(
            waitForPTYCondition(timeout: 3) {
                terminal.drain()
                return FileManager.default.fileExists(atPath: fixture.continueMarker.path)
                    && terminal.contains("GDB_CONT", after: backgroundStart)
            },
            terminal.transcript
        )
        XCTAssertEqual(terminal.foregroundProcessGroup, terminal.shellPID)
        let shellCheckStart = terminal.transcript.utf8.count
        try terminal.send("echo BG_RESUME_TTY_OK\n")
        XCTAssertTrue(
            terminal.waitFor("BG_RESUME_TTY_OK", after: shellCheckStart, timeout: 2),
            terminal.transcript
        )

        try terminal.send("kill %1\nwait %1\n")
    }

    func testSuccessfulProcessCapturesOutputAndUsesWorkingDirectory() throws {
        let directory = try TemporaryTestDirectory(component: "进程 空格")
        let command = CommandSpec(
            executable: "/bin/pwd",
            args: [],
            workingDirectory: directory.url
        )

        let result = try ProcessRunner().run(command)

        XCTAssertEqual(result.exitStatus, 0)
        let reportedDirectory = URL(
            fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).resolvingSymlinksInPath()
        XCTAssertEqual(reportedDirectory, directory.url.resolvingSymlinksInPath())
        XCTAssertEqual(result.stderr, "")
    }

    func testFailedProcessCapturesStderrAndStatus() throws {
        let command = CommandSpec(
            executable: "/bin/ls",
            args: ["/definitely/not/a/yagarto/file"],
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        let result = try ProcessRunner().run(command)

        XCTAssertNotEqual(result.exitStatus, 0)
        XCTAssertTrue(result.stderr.contains("/definitely/not/a/yagarto/file"))
    }

    func testTemporaryCaptureIOFailureIsWrappedAsBuildError() throws {
        let directory = try TemporaryTestDirectory(component: "捕获失败")
        let regularFile = directory.url.appendingPathComponent("不是目录")
        try Data("occupied".utf8).write(to: regularFile)
        let runner = ProcessRunner(temporaryDirectory: regularFile)
        let command = CommandSpec(
            executable: "/usr/bin/true",
            args: [],
            workingDirectory: directory.url
        )

        XCTAssertThrowsError(try runner.run(command)) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("进程捕获 IO 错误必须包装为 YagartoError")
            }
            XCTAssertEqual(error.exitCode, .buildFailure)
            XCTAssertEqual(error.diagnosticCode, "process.io")
        }
    }

    func testProcessLaunchFailureIsWrappedAsBuildError() throws {
        let directory = try TemporaryTestDirectory(component: "启动失败")
        let command = CommandSpec(
            executable: directory.url.appendingPathComponent("不存在的工具").path,
            args: [],
            workingDirectory: directory.url
        )

        XCTAssertThrowsError(try ProcessRunner().run(command)) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("进程启动错误必须包装为 YagartoError")
            }
            XCTAssertEqual(error.exitCode, .buildFailure)
            XCTAssertEqual(error.diagnosticCode, "process.launch_failed")
            XCTAssertNotNil(error.details)
        }
    }
}

private final class InteractiveExecutionRecorder {
    let termination: ProcessTermination
    private(set) var commands: [CommandSpec] = []

    init(termination: ProcessTermination) {
        self.termination = termination
    }

    func execute(_ command: CommandSpec) throws -> ProcessTermination {
        commands.append(command)
        return termination
    }
}

private final class InteractiveShellPTY {
    let shellPID: pid_t
    private let master: Int32
    private var transcriptData = Data()

    var transcript: String {
        String(decoding: transcriptData, as: UTF8.self)
    }

    var foregroundProcessGroup: pid_t {
        tcgetpgrp(master)
    }

    init() throws {
        var masterDescriptor = Int32(-1)
        let argumentStrings = [
            "/usr/bin/env",
            "PS1=YAGARTO_PTY_PROMPT> ",
            "ENV=/dev/null",
            "HISTFILE=/dev/null",
            "TERM=dumb",
            "/bin/sh",
            "-i"
        ]
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map {
            strdup($0)
        }
        arguments.append(nil)
        defer {
            for pointer in arguments {
                if let pointer { free(pointer) }
            }
        }

        let child = arguments.withUnsafeMutableBufferPointer { buffer -> pid_t in
            let pid = forkpty(&masterDescriptor, nil, nil, nil)
            if pid == 0 {
                execv(buffer[0], buffer.baseAddress)
                _exit(127)
            }
            return pid
        }
        guard child > 0 else {
            throw YagartoError.internalFailure("无法创建隔离 PTY shell。")
        }
        shellPID = child
        master = masterDescriptor
        let currentFlags = fcntl(master, F_GETFL)
        guard currentFlags >= 0,
              fcntl(master, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            _ = Darwin.kill(child, SIGKILL)
            var status = Int32(0)
            _ = waitpid(child, &status, 0)
            throw YagartoError.internalFailure("无法配置 PTY master。")
        }
    }

    func send(_ string: String) throws {
        try sendBytes(Array(string.utf8))
    }

    func sendControl(_ byte: UInt8) throws {
        try sendBytes([byte])
    }

    func contains(_ marker: String, after offset: Int = 0) -> Bool {
        let bytes = Array(transcriptData)
        guard offset <= bytes.count else { return false }
        return String(decoding: bytes[offset...], as: UTF8.self).contains(marker)
    }

    func waitFor(_ marker: String, after offset: Int = 0, timeout: TimeInterval) -> Bool {
        waitForPTYCondition(timeout: timeout) {
            self.drain()
            return self.contains(marker, after: offset)
        }
    }

    func waitForPrompt(after offset: Int = 0, timeout: TimeInterval) -> Bool {
        waitFor("YAGARTO_PTY_PROMPT> ", after: offset, timeout: timeout)
    }

    func drain() {
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&descriptor, 1, 0) > 0 {
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(master, &bytes, bytes.count)
            guard count > 0 else { return }
            transcriptData.append(contentsOf: bytes.prefix(Int(count)))
            descriptor.revents = 0
        }
    }

    func shutdown() {
        try? send("exit\n")
        let deadline = Date().addingTimeInterval(0.5)
        var status = Int32(0)
        while Date() < deadline {
            if waitpid(shellPID, &status, WNOHANG) == shellPID {
                _ = Darwin.close(master)
                return
            }
            usleep(10_000)
        }
        _ = Darwin.kill(shellPID, SIGKILL)
        _ = waitpid(shellPID, &status, WNOHANG)
        _ = Darwin.close(master)
    }

    private func sendBytes(_ bytes: [UInt8]) throws {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { rawBuffer in
                Darwin.write(
                    master,
                    rawBuffer.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
            }
            guard count > 0 else {
                throw YagartoError.internalFailure("写入 PTY 失败。")
            }
            written += count
        }
    }
}

private struct PTYCLIExecutionFixture {
    let directory: URL
    let tools: URL
    let cliPIDFile: URL
    let gdbPIDFile: URL
    let continueMarker: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pty-\(name)-\(UUID().uuidString)", isDirectory: true)
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        cliPIDFile = directory.appendingPathComponent("cli.pid")
        gdbPIDFile = directory.appendingPathComponent("gdb.pid")
        continueMarker = directory.appendingPathComponent("gdb-continued")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try writePTYExecutable(
            """
            #!/usr/bin/perl
            use strict;
            use warnings;
            $| = 1;
            open(my $pid, '>', $ENV{'YAGARTO_GDB_PID_FILE'}) or die $!;
            print $pid "$$\\n";
            close($pid);
            $SIG{'CONT'} = sub {
                open(my $continued, '>', $ENV{'YAGARTO_GDB_CONT_FILE'}) or die $!;
                print $continued "continued\\n";
                close($continued);
                print STDERR "GDB_CONT\\n";
            };
            print STDERR "GDB_READY\\n";
            while (1) { sleep 30; }
            """,
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writePTYExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )
    }

    func command(background: Bool) -> String {
        let executable = Bundle(for: ProcessRunnerTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("yagarto-mac").path
        let wrapper = "echo $$ > \(shellQuote(cliPIDFile.path)); exec \(shellQuote(executable)) run firmware.elf --profile cortex-m4 --format text"
        let environment = [
            "PATH=\(shellQuote("\(tools.path):/usr/bin:/bin"))",
            "YAGARTO_GDB_PID_FILE=\(shellQuote(gdbPIDFile.path))",
            "YAGARTO_GDB_CONT_FILE=\(shellQuote(continueMarker.path))"
        ].joined(separator: " ")
        return "/usr/bin/env \(environment) /bin/sh -c \(shellQuote(wrapper))\(background ? " &" : "")\n"
    }

    func cleanupProcesses() {
        for file in [gdbPIDFile, cliPIDFile] {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            _ = Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func writePTYExecutable(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func waitForPTYCondition(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

final class BuildExecutorTests: XCTestCase {
    func testExecutorStagesAndAtomicallyReplacesEveryArtifactLinkWithoutTouchingVictim() throws {
        enum LinkKind: String {
            case hard
            case symbolic
        }

        for linkKind in [LinkKind.hard, .symbolic] {
            for artifactIndex in 0..<5 {
                let directory = try TemporaryTestDirectory(
                    component: "staging-\(linkKind.rawValue)-\(artifactIndex)"
                )
                let outside = try TemporaryTestDirectory(
                    component: "victim-\(linkKind.rawValue)-\(artifactIndex)"
                )
                let plan = makeRealWritingPlan(directory: directory.url)
                let target = plan.artifactFiles[artifactIndex]
                let victim = outside.url.appendingPathComponent("victim.txt")
                try Data("保持不变".utf8).write(to: victim)
                try FileManager.default.createDirectory(
                    at: plan.outputDirectory,
                    withIntermediateDirectories: true
                )
                switch linkKind {
                case .hard:
                    try FileManager.default.linkItem(at: victim, to: target)
                case .symbolic:
                    try FileManager.default.createSymbolicLink(
                        atPath: target.path,
                        withDestinationPath: victim.path
                    )
                }

                XCTAssertNoThrow(
                    try BuildExecutor().execute(plan),
                    "未安全替换 \(linkKind.rawValue) link：\(target.lastPathComponent)"
                )
                XCTAssertEqual(
                    try String(contentsOf: victim, encoding: .utf8),
                    "保持不变",
                    "外部 victim 被改写：\(target.lastPathComponent)"
                )
                for artifact in plan.artifactFiles {
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: artifact.path
                    )
                    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
                    XCTAssertEqual(
                        (attributes[.referenceCount] as? NSNumber)?.intValue,
                        1,
                        artifact.lastPathComponent
                    )
                }
            }
        }
    }

    func testExecutorRejectsSuccessfulToolsThatProduceNoArtifacts() throws {
        let directory = try TemporaryTestDirectory(component: "空成功产物")
        let plan = makePlan(directory: directory.url, stepCount: 1)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "", stderr: "")
        ])

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.artifact_missing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.elfFile.path))
    }

    func testExecutorRunsStepsInOrderAndWritesListing() throws {
        let directory = try TemporaryTestDirectory(component: "构建 空格")
        let plan = makeRealWritingPlan(directory: directory.url)
        let runner = DelegatingRecordingProcessRunner()

        let results = try BuildExecutor(runner: runner).execute(plan)

        XCTAssertEqual(results.count, plan.steps.count)
        XCTAssertEqual(
            runner.commands.map(\.executable),
            plan.commands.map(\.executable)
        )
        XCTAssertTrue(runner.commands.flatMap(\.args).contains {
            $0.contains("-staging-")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.outputDirectory.path))
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(
                atPath: plan.outputDirectory.path
            )[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            try String(contentsOf: plan.listingFile, encoding: .utf8),
            "listing\n"
        )
    }

    func testExecutorFailureCleansStagingAndPreservesLastPublishedDirectory() throws {
        let directory = try TemporaryTestDirectory(component: "失败不发布")
        let plan = makePlan(directory: directory.url, stepCount: 1)
        try FileManager.default.createDirectory(
            at: plan.outputDirectory,
            withIntermediateDirectories: true
        )
        let marker = plan.outputDirectory.appendingPathComponent("last-good.txt")
        try Data("last good".utf8).write(to: marker)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 7, stdout: "", stderr: "tool failed")
        ])

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "last good")
        let parent = plan.outputDirectory.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("-staging-") }
        XCTAssertTrue(leftovers.isEmpty, "残留 staging：\(leftovers)")
    }

    func testExecutorStopsAfterFirstFailedStepAndMapsExitCodeFour() throws {
        let directory = try TemporaryTestDirectory(component: "短路")
        let plan = makePlan(directory: directory.url, stepCount: 3)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "", stderr: ""),
            ProcessResult(exitStatus: 9, stdout: "", stderr: "汇编失败"),
            ProcessResult(exitStatus: 0, stdout: "不应执行", stderr: "")
        ])

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("错误类型应为 YagartoError")
            }
            XCTAssertEqual(error.exitCode, .buildFailure)
            XCTAssertTrue(error.localizedDescription.contains("汇编失败"))
        }
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testExecutorCombinesUsefulStdoutAndStderrForFailedStep() throws {
        let directory = try TemporaryTestDirectory(component: "双流诊断")
        let plan = makePlan(directory: directory.url, stepCount: 1)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(
                exitStatus: 7,
                stdout: "stdout linker reason",
                stderr: "stderr linker reason"
            )
        ])

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            guard let output = (error as? YagartoError)?.toolOutput else {
                return XCTFail("失败步骤必须包含受控工具输出")
            }
            XCTAssertTrue(output.contains("stdout linker reason"))
            XCTAssertTrue(output.contains("stderr linker reason"))
            XCTAssertTrue(output.contains("stdout:"))
            XCTAssertTrue(output.contains("stderr:"))
        }
    }

    func testExecutorRejectsOutputSymlinkAddedAfterPlanning() throws {
        let directory = try TemporaryTestDirectory(component: "执行前替换")
        let outside = try TemporaryTestDirectory(component: "外部目录")
        let plan = makePlan(directory: directory.url, stepCount: 1)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "不应执行", stderr: "")
        ])
        try FileManager.default.createSymbolicLink(
            atPath: directory.url.appendingPathComponent(".yagarto").path,
            withDestinationPath: outside.url.path
        )

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("执行期输出 symlink 必须产生 YagartoError")
            }
            XCTAssertEqual(error.diagnosticCode, "configuration.output_symlink")
        }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.url.appendingPathComponent("build").path
        ))
    }

    func testExecutorAtomicallyReplacesPreexistingMapSymlinkWithoutChangingVictim() throws {
        let directory = try TemporaryTestDirectory(component: "map 符号链接")
        let outside = try TemporaryTestDirectory(component: "map 外部")
        let plan = makeRealWritingPlan(directory: directory.url)
        let victim = outside.url.appendingPathComponent("victim.txt")
        try Data("保持不变".utf8).write(to: victim)
        try FileManager.default.createDirectory(
            at: plan.outputDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: plan.mapFile.path,
            withDestinationPath: victim.path
        )
        XCTAssertNoThrow(try BuildExecutor().execute(plan))
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "保持不变")
        let attributes = try FileManager.default.attributesOfItem(atPath: plan.mapFile.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
    }

    func testExecutorReplacesFinalArtifactLinkInsertedDuringStagedBuild() throws {
        let directory = try TemporaryTestDirectory(component: "逐步复查")
        let outside = try TemporaryTestDirectory(component: "逐步外部")
        let plan = makeRealWritingPlan(directory: directory.url)
        let victim = outside.url.appendingPathComponent("victim.txt")
        try Data("保持不变".utf8).write(to: victim)
        try FileManager.default.createDirectory(
            at: plan.outputDirectory,
            withIntermediateDirectories: true
        )
        let runner = MutatingDelegatingProcessRunner {
            try FileManager.default.createSymbolicLink(
                atPath: plan.binaryFile.path,
                withDestinationPath: victim.path
            )
        }

        XCTAssertNoThrow(try BuildExecutor(runner: runner).execute(plan))
        XCTAssertEqual(runner.commands.count, plan.steps.count)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "保持不变")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: plan.binaryFile.path)[.type]
                as? FileAttributeType,
            .typeRegular
        )
    }

    private func makePlan(directory: URL, stepCount: Int = 2) -> BuildPlan {
        let outputDirectory = directory.appendingPathComponent(".yagarto/build/arm7tdmi", isDirectory: true)
        let commands = (0..<stepCount).map { index in
            CommandSpec(
                executable: "/tool/\(index)",
                args: ["参数 \(index)"],
                workingDirectory: directory
            )
        }
        let listingFile = outputDirectory.appendingPathComponent("demo.lst")
        let steps = commands.enumerated().map { index, command in
            BuildStep(
                command: command,
                standardOutputFile: index == 1 ? listingFile : nil
            )
        }
        return BuildPlan(
            profile: .arm7tdmi,
            projectDirectory: directory,
            outputDirectory: outputDirectory,
            objectFiles: [outputDirectory.appendingPathComponent("demo.o")],
            elfFile: outputDirectory.appendingPathComponent("demo.elf"),
            mapFile: outputDirectory.appendingPathComponent("demo.map"),
            binaryFile: outputDirectory.appendingPathComponent("demo.bin"),
            listingFile: listingFile,
            steps: steps
        )
    }

    private func makeRealWritingPlan(directory: URL) -> BuildPlan {
        let output = directory.appendingPathComponent(
            ".yagarto/build/arm7tdmi",
            isDirectory: true
        )
        let object = output.appendingPathComponent("demo.o")
        let elf = output.appendingPathComponent("demo.elf")
        let map = output.appendingPathComponent("demo.map")
        let binary = output.appendingPathComponent("demo.bin")
        let listing = output.appendingPathComponent("demo.lst")
        let steps = [
            BuildStep(command: CommandSpec(
                executable: "/usr/bin/truncate",
                args: ["-s", "0", object.path],
                workingDirectory: directory
            )),
            BuildStep(command: CommandSpec(
                executable: "/usr/bin/truncate",
                args: ["-s", "0", elf.path, map.path],
                workingDirectory: directory
            )),
            BuildStep(command: CommandSpec(
                executable: "/usr/bin/truncate",
                args: ["-s", "0", binary.path],
                workingDirectory: directory
            )),
            BuildStep(
                command: CommandSpec(
                    executable: "/usr/bin/printf",
                    args: ["listing\n"],
                    workingDirectory: directory
                ),
                standardOutputFile: listing
            )
        ]
        return BuildPlan(
            profile: .arm7tdmi,
            projectDirectory: directory,
            outputDirectory: output,
            objectFiles: [object],
            elfFile: elf,
            mapFile: map,
            binaryFile: binary,
            listingFile: listing,
            steps: steps
        )
    }
}

private final class RecordingProcessRunner: ProcessRunning {
    private var results: [ProcessResult]
    private(set) var commands: [CommandSpec] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ command: CommandSpec) throws -> ProcessResult {
        commands.append(command)
        return results.removeFirst()
    }
}

private final class DelegatingRecordingProcessRunner: ProcessRunning {
    private(set) var commands: [CommandSpec] = []

    func run(_ command: CommandSpec) throws -> ProcessResult {
        commands.append(command)
        return try ProcessRunner().run(command)
    }
}

private final class MutatingDelegatingProcessRunner: ProcessRunning {
    private let mutation: () throws -> Void
    private(set) var commands: [CommandSpec] = []

    init(mutation: @escaping () throws -> Void) {
        self.mutation = mutation
    }

    func run(_ command: CommandSpec) throws -> ProcessResult {
        commands.append(command)
        if commands.count == 1 {
            try mutation()
        }
        return try ProcessRunner().run(command)
    }
}

private struct TemporaryTestDirectory {
    let url: URL

    init(component: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
