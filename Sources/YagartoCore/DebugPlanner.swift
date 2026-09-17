// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct DebugPlanner {
    private let toolPaths: [ToolIdentifier: String]
    private let gdbSimulatorPath: String?
    private let openOCDBoardConfig: URL?

    public init(
        toolPaths: [ToolIdentifier: String],
        gdbSimulatorPath: String? = nil,
        openOCDBoardConfig: URL? = nil
    ) {
        self.toolPaths = toolPaths
        self.gdbSimulatorPath = gdbSimulatorPath
        self.openOCDBoardConfig = openOCDBoardConfig
    }

    public func plan(
        mode: DebugMode,
        configuration: ProjectConfiguration,
        elf: URL,
        projectDirectory: URL
    ) throws -> DebugLaunchPlan {
        let project = projectDirectory.standardizedFileURL
        let elf = elf.standardizedFileURL
        let entry = try validatedEntry(configuration.entry)
        let fileCommand = "file \(try gdbQuote(elf.path))"

        switch configuration.profile {
        case .arm7tdmi:
            if let gdbSimulatorPath {
                return try makePlan(
                    profile: configuration.profile,
                    backend: .gdbSimulator,
                    gdb: gdbSimulatorPath,
                    commands: [fileCommand, "target sim", "load"]
                        + runCommands(mode: mode, entry: entry, simulator: true),
                    warnings: [],
                    elf: elf,
                    project: project
                )
            }
            guard let qemu = toolPaths[.qemuSystemARM] else {
                throw YagartoError.debugBackendUnavailable(.arm7tdmi)
            }
            let pipe = try pipeCommand(
                executable: qemu,
                arguments: [
                    "-M", "integratorcp",
                    "-cpu", "arm926",
                    "-kernel", elf.path,
                    "-S",
                    "-gdb", "stdio",
                    "-nographic",
                    "-monitor", "none",
                    "-serial", "none"
                ]
            )
            var commands = [fileCommand, "target remote | exec \(pipe)"]
            if mode == .run {
                commands.append("continue")
            }
            return try makePlan(
                profile: configuration.profile,
                backend: .qemuARM926Compatible,
                gdb: requiredTool(.gdb),
                commands: commands,
                warnings: ["ARM926 是 ARM7TDMI 兼容超集，非精确模型"],
                elf: elf,
                project: project
            )

        case .cortexM4:
            guard let qemu = toolPaths[.qemuSystemARM] else {
                throw YagartoError.toolNotFound(ToolIdentifier.qemuSystemARM.rawValue)
            }
            let pipe = try pipeCommand(
                executable: qemu,
                arguments: [
                    "-M", "mps2-an386",
                    "-kernel", elf.path,
                    "-S",
                    "-gdb", "stdio",
                    "-nographic",
                    "-monitor", "none",
                    "-serial", "none"
                ]
            )
            return try makePlan(
                profile: configuration.profile,
                backend: .qemuMPS2AN386,
                gdb: requiredTool(.gdb),
                commands: [fileCommand, "target remote | exec \(pipe)"]
                    + runCommands(mode: mode, entry: entry, simulator: false),
                warnings: [],
                elf: elf,
                project: project
            )

        case .stm32f4Discovery:
            guard let openOCD = toolPaths[.openOCD] else {
                throw YagartoError.toolNotFound(ToolIdentifier.openOCD.rawValue)
            }
            guard let boardConfig = openOCDBoardConfig else {
                throw YagartoError.toolNotFound("scripts/board/stm32f4discovery.cfg")
            }
            let openOCDCommand = "gdb_port pipe; tcl_port disabled; telnet_port disabled; log_output /dev/stderr"
            let pipe = try pipeCommand(
                executable: openOCD,
                arguments: ["-f", boardConfig.path, "-c", openOCDCommand]
            )
            var commands = [
                fileCommand,
                "target extended-remote | exec \(pipe)",
                "monitor reset halt"
            ]
            if mode == .debug {
                commands.append("tbreak \(entry)")
            }
            commands.append("continue")
            return try makePlan(
                profile: configuration.profile,
                backend: .openOCDSTM32F4Discovery,
                gdb: requiredTool(.gdb),
                commands: commands,
                warnings: [],
                elf: elf,
                project: project
            )
        }
    }

    private func makePlan(
        profile: ProfileID,
        backend: DebugBackend,
        gdb: String,
        commands: [String],
        warnings: [String],
        elf: URL,
        project: URL
    ) throws -> DebugLaunchPlan {
        try rejectControlCharacters(gdb, error: .unsafePipeValue(gdb))
        return DebugLaunchPlan(
            profile: profile,
            backend: backend,
            gdbExecutable: gdb,
            gdbArguments: ["-q", "-nx"] + commands.flatMap { ["-ex", $0] },
            initCommands: commands,
            warnings: warnings,
            elf: elf.path,
            projectDirectory: project.path
        )
    }

    private func runCommands(mode: DebugMode, entry: String, simulator: Bool) -> [String] {
        if simulator {
            return mode == .debug ? ["tbreak \(entry)", "run"] : ["run"]
        }
        return mode == .debug ? ["tbreak \(entry)", "continue"] : ["continue"]
    }

    private func requiredTool(_ tool: ToolIdentifier) throws -> String {
        guard let value = toolPaths[tool] else {
            throw YagartoError.toolNotFound(tool.rawValue)
        }
        return value
    }

    private func validatedEntry(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = trimmed.isEmpty ? "start" : trimmed
        let pattern = #"^[\p{L}_.$][\p{L}\p{M}\p{N}_.$]*$"#
        guard entry.range(of: pattern, options: .regularExpression) != nil else {
            throw YagartoError.invalidEntry(raw)
        }
        return entry
    }

    private func gdbQuote(_ value: String) throws -> String {
        try rejectControlCharacters(value, error: .unsafePipeValue(value))
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func pipeCommand(executable: String, arguments: [String]) throws -> String {
        try ([executable] + arguments).map(posixQuote).joined(separator: " ")
    }

    private func posixQuote(_ value: String) throws -> String {
        try rejectControlCharacters(value, error: .unsafePipeValue(value))
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

func tclQuote(_ value: String, error: YagartoError) throws -> String {
    try rejectControlCharacters(value, error: error)
    if !value.contains("{") && !value.contains("}") && !value.hasSuffix("\\") {
        return "{\(value)}"
    }
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
    return "\"\(escaped)\""
}

func rejectControlCharacters(_ value: String, error: YagartoError) throws {
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
        throw error
    }
}
