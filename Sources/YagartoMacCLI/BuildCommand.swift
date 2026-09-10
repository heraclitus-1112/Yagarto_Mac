// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import YagartoCore

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "汇编并链接项目或单个源文件。"
    )

    @Argument(help: "可选的 .s 或 .S 源文件；提供时覆盖配置中的 sources。")
    var source: String?

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let directory = currentDirectory()
        let store = ConfigStore(projectDirectory: directory)
        var configuration: ProjectConfiguration

        if FileManager.default.fileExists(atPath: store.configurationURL.path) {
            configuration = try store.load()
            if let source {
                configuration.sources = [source]
            }
        } else if let source {
            let outputName = URL(fileURLWithPath: source)
                .deletingPathExtension()
                .lastPathComponent
            configuration = ProjectConfiguration(
                sources: [source],
                outputName: outputName
            )
        } else {
            throw YagartoError.configurationNotFound(store.configurationURL.path)
        }

        try ConfigStore.validate(configuration)
        let resolver = ToolResolver()
        var requiredTools: Set<ToolIdentifier> = [.linker, .objcopy, .objdump]
        for source in configuration.sources {
            requiredTools.insert(source.hasSuffix(".S") ? .compiler : .assembler)
        }
        var toolPaths: [ToolIdentifier: String] = [:]
        for tool in ToolIdentifier.allCases where requiredTools.contains(tool) {
            toolPaths[tool] = try resolver.resolve(tool)
        }

        let plan = try BuildPlanner(toolPaths: toolPaths).plan(
            configuration: configuration,
            projectDirectory: directory
        )
        try BuildExecutor().execute(plan)

        let output = BuildOutput(
            status: "ok",
            profile: configuration.profile,
            artifacts: [
                plan.elfFile.path,
                plan.mapFile.path,
                plan.binaryFile.path,
                plan.listingFile.path
            ] + plan.objectFiles.map(\.path)
        )
        switch format {
        case .json:
            try CLIOutput.printJSON(output)
        case .text:
            print("构建完成（\(configuration.profile.rawValue)）：")
            for artifact in output.artifacts {
                print("  \(artifact)")
            }
        }
    }
}
