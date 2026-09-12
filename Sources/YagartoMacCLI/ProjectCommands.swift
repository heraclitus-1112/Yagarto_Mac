// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import YagartoCore

struct NewProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "自动创建工程目录、最小可运行汇编源码和 yagarto.json。"
    )

    @Argument(help: "工程名称。")
    var name: String

    @Option(name: .long, help: "目标 profile。")
    var profile: ProfileID = .arm7tdmi

    @Option(name: .long, help: "父目录；省略时使用当前目录。")
    var parent: String?

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let parentURL = resolvedURL(parent ?? currentDirectory().path)
        let created = try ProjectCreator().create(ProjectCreationRequest(
            parentDirectory: parentURL,
            name: name,
            profile: profile
        ))
        let output = CreatedProjectOutput(action: "created", created: created)
        switch format {
        case .json:
            try CLIOutput.printJSON(output)
        case .text:
            print("已创建工程：\(created.projectDirectory.path)")
            print("源码：\(created.sourceURL.path)")
            print("profile：\(created.configuration.profile.rawValue)")
        }
    }
}

struct ImportProjectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "把独立 .s/.S 文件自动整理为一文件一工程。"
    )

    @Argument(help: "一个或多个源码或目录；目录只扫描当前层。")
    var inputs: [String]

    @Option(name: .long, help: "所有输入统一使用的目标 profile。")
    var profile: ProfileID = .arm7tdmi

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: inputs.map(resolvedURL),
            profile: profile
        ))
        let output = ProjectImportOutput(report: report)
        switch format {
        case .json:
            try CLIOutput.printJSON(output)
        case .text:
            print("已创建 \(report.created.count) 个工程。")
            for project in report.created {
                print("  ✓ \(project.sourceURL.path)")
            }
            for issue in report.skipped {
                print("  跳过 \(issue.sourceURL.path)：\(issue.message)")
            }
            for warning in report.warnings {
                print("  警告 \(warning.sourceURL.path)：\(warning.message)")
            }
        }
        if report.status == .partial {
            throw CLIControlledExit(code: YagartoExitCode.usage.rawValue)
        }
    }
}

struct CLIControlledExit: Error {
    let code: Int32
}

private func resolvedURL(_ path: String) -> URL {
    if NSString(string: path).isAbsolutePath {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return currentDirectory().appendingPathComponent(path).standardizedFileURL
}
