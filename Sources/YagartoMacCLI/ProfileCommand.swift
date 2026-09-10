// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import YagartoCore

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "管理项目 profile。",
        subcommands: [SetProfileCommand.self]
    )
}

struct SetProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "设置项目 profile。"
    )

    @Argument(help: "arm7tdmi、cortex-m4 或 stm32f4-discovery。")
    var profile: ProfileID

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let store = ConfigStore(projectDirectory: currentDirectory())
        var configuration = try store.load()
        configuration.profile = profile
        try store.save(configuration)

        switch format {
        case .json:
            try CLIOutput.printJSON(ConfigurationOutput(
                action: "profile-set",
                path: store.configurationURL.path,
                configuration: configuration
            ))
        case .text:
            print("已将 profile 设置为 \(profile.rawValue)。")
        }
    }
}
