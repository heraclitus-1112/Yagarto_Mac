// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import YagartoCore

struct YagartoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yagarto-mac",
        abstract: "macOS 上的非官方 YAGARTO 兼容命令行层。",
        version: "0.1.0",
        subcommands: [
            DoctorCommand.self,
            InitCommand.self,
            ProfileCommand.self,
            BuildCommand.self,
            DisassembleCommand.self
        ]
    )
}

extension ProfileID: ExpressibleByArgument {}
extension OutputFormat: ExpressibleByArgument {}
