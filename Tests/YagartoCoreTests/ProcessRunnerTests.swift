// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class ProcessRunnerTests: XCTestCase {
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

final class BuildExecutorTests: XCTestCase {
    func testExecutorRunsStepsInOrderAndWritesListing() throws {
        let directory = try TemporaryTestDirectory(component: "构建 空格")
        let plan = makePlan(directory: directory.url)
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "assembled", stderr: ""),
            ProcessResult(exitStatus: 0, stdout: "listing\n", stderr: "")
        ])

        let results = try BuildExecutor(runner: runner).execute(plan)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(runner.commands, plan.commands)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.outputDirectory.path))
        XCTAssertEqual(
            try String(contentsOf: plan.listingFile, encoding: .utf8),
            "listing\n"
        )
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

    func testExecutorRejectsPreexistingMapSymlinkBeforeRunningCommands() throws {
        let directory = try TemporaryTestDirectory(component: "map 符号链接")
        let outside = try TemporaryTestDirectory(component: "map 外部")
        let plan = makePlan(directory: directory.url, stepCount: 1)
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
        let runner = RecordingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "不应执行", stderr: "")
        ])

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "configuration.output_symlink")
        }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "保持不变")
    }

    func testExecutorRechecksAllArtifactsBeforeEveryStep() throws {
        let directory = try TemporaryTestDirectory(component: "逐步复查")
        let outside = try TemporaryTestDirectory(component: "逐步外部")
        let plan = makePlan(directory: directory.url, stepCount: 2)
        let victim = outside.url.appendingPathComponent("victim.txt")
        try Data("保持不变".utf8).write(to: victim)
        let runner = MutatingProcessRunner {
            try FileManager.default.createSymbolicLink(
                atPath: plan.binaryFile.path,
                withDestinationPath: victim.path
            )
        }

        XCTAssertThrowsError(try BuildExecutor(runner: runner).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "configuration.output_symlink")
        }
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "保持不变")
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

private final class MutatingProcessRunner: ProcessRunning {
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
        return ProcessResult(exitStatus: 0, stdout: "", stderr: "")
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
