// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

struct ConfigurationOutput: Encodable {
    let action: String
    let path: String
    let configuration: ProjectConfiguration
}

struct CreatedProjectOutput: Encodable {
    let schemaVersion: Int
    let action: String
    let profile: ProfileID
    let projectPath: String
    let sourcePath: String
    let configuration: ProjectConfiguration

    init(action: String, created: CreatedProject) {
        schemaVersion = 1
        self.action = action
        profile = created.configuration.profile
        projectPath = created.projectDirectory.path
        sourcePath = created.sourceURL.path
        configuration = created.configuration
    }
}

struct ProjectImportOutput: Encodable {
    struct Created: Encodable {
        let projectPath: String
        let sourcePath: String
        let entry: String
        let outputName: String
    }

    struct Issue: Encodable {
        let sourcePath: String
        let code: String
        let message: String
    }

    let schemaVersion: Int
    let status: ProjectImportStatus
    let profile: ProfileID
    let created: [Created]
    let skipped: [Issue]
    let warnings: [Issue]

    init(report: ProjectImportReport) {
        schemaVersion = report.schemaVersion
        status = report.status
        profile = report.profile
        created = report.created.map {
            Created(
                projectPath: $0.projectDirectory.path,
                sourcePath: $0.sourceURL.path,
                entry: $0.configuration.entry,
                outputName: $0.configuration.outputName
            )
        }
        skipped = report.skipped.map {
            Issue(sourcePath: $0.sourceURL.path, code: $0.code, message: $0.message)
        }
        warnings = report.warnings.map {
            Issue(sourcePath: $0.sourceURL.path, code: $0.code, message: $0.message)
        }
    }
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

struct FlashOutput: Encodable {
    let status: String
    let profile: ProfileID
    let elf: String
}

func currentDirectory() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}
