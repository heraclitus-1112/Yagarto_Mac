// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

struct ConfigurationOutput: Encodable {
    let action: String
    let path: String
    let configuration: ProjectConfiguration
}

struct BuildOutput: Encodable {
    let status: String
    let profile: ProfileID
    let artifacts: [String]
}

struct DisassemblyOutput: Encodable {
    let elf: String
    let disassembly: String
}

func currentDirectory() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}
