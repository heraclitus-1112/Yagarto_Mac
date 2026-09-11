// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum ToolIdentifier: String, Codable, CaseIterable, Hashable, Sendable {
    case assembler = "arm-none-eabi-as"
    case compiler = "arm-none-eabi-gcc"
    case linker = "arm-none-eabi-ld"
    case objcopy = "arm-none-eabi-objcopy"
    case objdump = "arm-none-eabi-objdump"
    case gdb = "arm-none-eabi-gdb"
    case openOCD = "openocd"
    case qemuSystemARM = "qemu-system-arm"

    public var isRequired: Bool {
        switch self {
        case .assembler, .compiler, .linker, .objcopy, .objdump:
            return true
        case .gdb, .openOCD, .qemuSystemARM:
            return false
        }
    }
}

public struct DoctorEntry: Codable, Equatable, Sendable {
    public let tool: ToolIdentifier
    public let required: Bool
    public let path: String?
    public let available: Bool
    public let executablePresent: Bool
    public let targetSimCapable: Bool

    public init(
        tool: ToolIdentifier,
        required: Bool,
        path: String?,
        targetSimCapable: Bool = false
    ) {
        self.tool = tool
        self.required = required
        self.path = path
        self.available = path != nil
        self.executablePresent = path != nil
        self.targetSimCapable = targetSimCapable
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let entries: [DoctorEntry]
    public let stm32f4BoardConfig: String?
    public let stm32f4BoardConfigAvailable: Bool

    public init(entries: [DoctorEntry], stm32f4BoardConfig: String? = nil) {
        self.entries = entries
        self.stm32f4BoardConfig = stm32f4BoardConfig
        self.stm32f4BoardConfigAvailable = stm32f4BoardConfig != nil
    }

    public var requiredToolsAvailable: Bool {
        entries.filter(\.required).allSatisfy(\.available)
    }

    public func entry(for tool: ToolIdentifier) -> DoctorEntry? {
        entries.first { $0.tool == tool }
    }
}

public struct ToolResolver {
    private let environment: [String: String]
    private let fileExists: (String) -> Bool
    private let resourceExists: (String) -> Bool
    private let capabilityProbe: (CommandSpec) -> Bool
    private let resolvingSymlinks: (String) -> String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        resourceExists: @escaping (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        capabilityProbe: @escaping (CommandSpec) -> Bool = { command in
            (try? ProcessRunner().run(command).exitStatus) == 0
        },
        resolvingSymlinks: @escaping (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    ) {
        self.environment = environment
        self.fileExists = fileExists
        self.resourceExists = resourceExists
        self.capabilityProbe = capabilityProbe
        self.resolvingSymlinks = resolvingSymlinks
    }

    public func resolve(
        _ tool: ToolIdentifier,
        overrides: [ToolIdentifier: String] = [:]
    ) throws -> String {
        if let path = resolvedPath(for: tool, overrides: overrides) {
            return path
        }
        throw YagartoError.toolNotFound(tool.rawValue)
    }

    public func doctor(
        overrides: [ToolIdentifier: String] = [:]
    ) -> DoctorReport {
        var paths = Dictionary(uniqueKeysWithValues: ToolIdentifier.allCases.map { tool in
            (tool, resolvedPath(for: tool, overrides: overrides))
        })
        let simulator = resolvedGDBSimulator(overrides: overrides)
        if let simulator {
            paths[.gdb] = simulator
        }
        let entries = ToolIdentifier.allCases.map { tool in
            let path = paths[tool] ?? nil
            return DoctorEntry(
                tool: tool,
                required: tool.isRequired,
                path: path,
                targetSimCapable: tool == .gdb
                    && simulator != nil
                    && path == simulator
            )
        }
        let boardConfig = (paths[.openOCD] ?? nil).flatMap { openOCD in
            try? resolveSTM32F4BoardConfig(openOCDPath: openOCD)
        }
        return DoctorReport(entries: entries, stm32f4BoardConfig: boardConfig)
    }

    public func resolveGDBSimulator(
        overrides: [ToolIdentifier: String] = [:]
    ) throws -> String {
        if let simulator = resolvedGDBSimulator(overrides: overrides) {
            return simulator
        }
        throw YagartoError.debugBackendUnavailable(.arm7tdmi)
    }

    private func resolvedGDBSimulator(
        overrides: [ToolIdentifier: String]
    ) -> String? {
        var candidates: [String] = []
        if let environmentOverride = environment["YAGARTO_MAC_GDB_SIM"],
           !environmentOverride.isEmpty {
            candidates.append(environmentOverride)
        }
        if let explicitOverride = overrides[.gdb] {
            candidates.append(explicitOverride)
        }
        if let ordinaryGDB = resolvedPath(for: .gdb, overrides: [:]) {
            candidates.append(ordinaryGDB)
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileExists(candidate), isTargetSimCapable(candidate) {
                return candidate
            }
        }
        return nil
    }

    public func resolveSTM32F4BoardConfig(openOCDPath: String) throws -> String {
        let filename = "stm32f4discovery.cfg"
        let resolvedExecutable = resolvingSymlinks(openOCDPath)
        var roots: [String] = []
        if let scripts = environment["OPENOCD_SCRIPTS"], !scripts.isEmpty {
            roots.append(scripts)
        }
        for executable in [resolvedExecutable, openOCDPath] {
            let prefix = URL(fileURLWithPath: executable)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            roots.append(prefix.appendingPathComponent("share/openocd/scripts").path)
        }
        roots += [
            "/opt/homebrew/share/openocd/scripts",
            "/usr/local/share/openocd/scripts",
            "/opt/local/share/openocd/scripts",
            "/usr/share/openocd/scripts"
        ]

        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("board", isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
                .path
            if resourceExists(candidate) {
                return candidate
            }
        }
        throw YagartoError.toolNotFound("scripts/board/\(filename)")
    }

    private func resolvedPath(
        for tool: ToolIdentifier,
        overrides: [ToolIdentifier: String]
    ) -> String? {
        var candidates: [String] = []
        if let override = overrides[tool] {
            candidates.append(override)
        }

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        candidates.append(contentsOf: pathDirectories.map { directory in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(tool.rawValue, isDirectory: false)
                .path
        })
        candidates.append("/opt/homebrew/bin/\(tool.rawValue)")

        return candidates.first(where: fileExists)
    }

    private func isTargetSimCapable(_ executable: String) -> Bool {
        capabilityProbe(CommandSpec(
            executable: executable,
            args: ["-q", "-nx", "-batch", "-ex", "target sim"],
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ))
    }
}
