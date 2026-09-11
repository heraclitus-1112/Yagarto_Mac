// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum DebugBackend: String, Codable, CaseIterable, Sendable {
    case gdbSimulator = "gdb-simulator"
    case qemuARM926Compatible = "qemu-arm926-compatible"
    case qemuMPS2AN386 = "qemu-mps2-an386"
    case openOCDSTM32F4Discovery = "openocd-stm32f4-discovery"
}

public enum DebugMode: String, Codable, CaseIterable, Sendable {
    case debug
    case run
}

public struct DebugLaunchPlan: Codable, Equatable, Sendable {
    public let profile: ProfileID
    public let backend: DebugBackend
    public let gdbExecutable: String
    public let gdbArguments: [String]
    public let initCommands: [String]
    public let warnings: [String]
    public let elf: String
    public let projectDirectory: String

    public init(
        profile: ProfileID,
        backend: DebugBackend,
        gdbExecutable: String,
        gdbArguments: [String],
        initCommands: [String],
        warnings: [String],
        elf: String,
        projectDirectory: String
    ) {
        self.profile = profile
        self.backend = backend
        self.gdbExecutable = gdbExecutable
        self.gdbArguments = gdbArguments
        self.initCommands = initCommands
        self.warnings = warnings
        self.elf = elf
        self.projectDirectory = projectDirectory
    }

    public var command: CommandSpec {
        CommandSpec(
            executable: gdbExecutable,
            args: gdbArguments,
            workingDirectory: URL(fileURLWithPath: projectDirectory, isDirectory: true)
        )
    }
}
