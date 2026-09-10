// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import YagartoCore

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "创建默认 yagarto.json。"
    )

    @Option(name: .long, help: "目标 profile。")
    var profile: ProfileID = .arm7tdmi

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let directory = currentDirectory()
        let store = ConfigStore(projectDirectory: directory)
        let configuration = ProjectConfiguration(profile: profile)
        try store.save(configuration)

        switch format {
        case .json:
            try CLIOutput.printJSON(ConfigurationOutput(
                action: "initialized",
                path: store.configurationURL.path,
                configuration: configuration
            ))
        case .text:
            print("已创建 \(store.configurationURL.path)，profile：\(profile.rawValue)")
        }
    }
}
