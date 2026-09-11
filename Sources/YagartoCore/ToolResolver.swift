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

public struct DoctorGDBStatus: Codable, Equatable, Sendable {
    public let path: String?
    public let executablePresent: Bool
    public let targetSimCapable: Bool

    public init(path: String?, targetSimCapable: Bool) {
        self.path = path
        self.executablePresent = path != nil
        self.targetSimCapable = targetSimCapable
    }
}

public struct DoctorDebugSelection: Codable, Equatable, Sendable {
    public let profile: ProfileID
    public let available: Bool
    public let backend: DebugBackend?
    public let gdbExecutable: String?
    public let warnings: [String]

    public init(
        profile: ProfileID,
        backend: DebugBackend?,
        gdbExecutable: String?,
        warnings: [String]
    ) {
        self.profile = profile
        self.available = backend != nil && gdbExecutable != nil
        self.backend = backend
        self.gdbExecutable = gdbExecutable
        self.warnings = warnings
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let entries: [DoctorEntry]
    public let normalGDB: DoctorGDBStatus
    public let simulatorGDB: DoctorGDBStatus
    public let debugSelections: [DoctorDebugSelection]
    public let stm32f4BoardConfig: String?
    public let stm32f4BoardConfigAvailable: Bool

    public init(
        entries: [DoctorEntry],
        normalGDB: DoctorGDBStatus,
        simulatorGDB: DoctorGDBStatus,
        debugSelections: [DoctorDebugSelection],
        stm32f4BoardConfig: String? = nil
    ) {
        self.schemaVersion = 1
        self.entries = entries
        self.normalGDB = normalGDB
        self.simulatorGDB = simulatorGDB
        self.debugSelections = debugSelections
        self.stm32f4BoardConfig = stm32f4BoardConfig
        self.stm32f4BoardConfigAvailable = stm32f4BoardConfig != nil
    }

    public var requiredToolsAvailable: Bool {
        entries.filter(\.required).allSatisfy(\.available)
    }

    public func entry(for tool: ToolIdentifier) -> DoctorEntry? {
        entries.first { $0.tool == tool }
    }

    public func debugSelection(for profile: ProfileID) -> DoctorDebugSelection? {
        debugSelections.first { $0.profile == profile }
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
        capabilityProbe: ((CommandSpec) -> Bool)? = nil,
        resolvingSymlinks: @escaping (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    ) {
        self.environment = environment
        self.fileExists = fileExists
        self.resourceExists = resourceExists
        self.capabilityProbe = capabilityProbe ?? { command in
            TimedProcessCapabilityProbe.run(command)
        }
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
        let paths = Dictionary(uniqueKeysWithValues: ToolIdentifier.allCases.map { tool in
            (tool, resolvedPath(for: tool, overrides: overrides))
        })
        let normalGDB = paths[.gdb] ?? nil
        let qemu = paths[.qemuSystemARM] ?? nil
        let openOCD = paths[.openOCD] ?? nil
        let normalGDBTargetSimCapable = normalGDB.map(isTargetSimCapable) ?? false
        let simulator = resolvedGDBSimulator(overrides: overrides)
        let simulatorCandidate = simulator
            ?? gdbSimulatorCandidates(overrides: overrides).first(where: fileExists)
        let entries = ToolIdentifier.allCases.map { tool in
            let path = paths[tool] ?? nil
            return DoctorEntry(
                tool: tool,
                required: tool.isRequired,
                path: path,
                targetSimCapable: tool == .gdb && normalGDBTargetSimCapable
            )
        }
        let boardConfig = openOCD.flatMap { openOCD in
            try? resolveSTM32F4BoardConfig(openOCDPath: openOCD)
        }
        var debugSelections: [DoctorDebugSelection] = []
        if let simulator {
            debugSelections.append(DoctorDebugSelection(
                profile: .arm7tdmi,
                backend: .gdbSimulator,
                gdbExecutable: simulator,
                warnings: []
            ))
        } else if let normalGDB, qemu != nil {
            debugSelections.append(DoctorDebugSelection(
                profile: .arm7tdmi,
                backend: .qemuARM926Compatible,
                gdbExecutable: normalGDB,
                warnings: ["ARM926 是 ARM7TDMI 兼容超集，非精确模型"]
            ))
        } else {
            debugSelections.append(DoctorDebugSelection(
                profile: .arm7tdmi,
                backend: nil,
                gdbExecutable: nil,
                warnings: []
            ))
        }
        debugSelections.append(DoctorDebugSelection(
            profile: .cortexM4,
            backend: normalGDB != nil && qemu != nil
                ? .qemuMPS2AN386
                : nil,
            gdbExecutable: qemu != nil ? normalGDB : nil,
            warnings: []
        ))
        debugSelections.append(DoctorDebugSelection(
            profile: .stm32f4Discovery,
            backend: normalGDB != nil && openOCD != nil && boardConfig != nil
                ? .openOCDSTM32F4Discovery
                : nil,
            gdbExecutable: openOCD != nil && boardConfig != nil ? normalGDB : nil,
            warnings: []
        ))
        return DoctorReport(
            entries: entries,
            normalGDB: DoctorGDBStatus(
                path: normalGDB,
                targetSimCapable: normalGDBTargetSimCapable
            ),
            simulatorGDB: DoctorGDBStatus(
                path: simulatorCandidate,
                targetSimCapable: simulator != nil
            ),
            debugSelections: debugSelections,
            stm32f4BoardConfig: boardConfig
        )
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
        for candidate in gdbSimulatorCandidates(overrides: overrides) {
            if fileExists(candidate), isTargetSimCapable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func gdbSimulatorCandidates(
        overrides: [ToolIdentifier: String]
    ) -> [String] {
        var candidates: [String] = []
        if let environmentOverride = environment["YAGARTO_MAC_GDB_SIM"],
           !environmentOverride.isEmpty {
            candidates.append(environmentOverride)
        }
        if let explicitOverride = overrides[.gdb] {
            candidates.append(explicitOverride)
        }

        let simulatorName = "arm-none-eabi-gdb-sim"
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        candidates.append(contentsOf: pathDirectories.map { directory in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(simulatorName, isDirectory: false)
                .path
        })
        if let homeDirectory = environment["HOME"], !homeDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: homeDirectory, isDirectory: true)
                    .appendingPathComponent(".local", isDirectory: true)
                    .appendingPathComponent("share", isDirectory: true)
                    .appendingPathComponent("yagarto-mac", isDirectory: true)
                    .appendingPathComponent("toolchains", isDirectory: true)
                    .appendingPathComponent("gdb-15.2-sim", isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(simulatorName, isDirectory: false)
                    .path
            )
        }
        candidates.append("/opt/homebrew/bin/\(simulatorName)")
        if let ordinaryGDB = resolvedPath(for: .gdb, overrides: [:]) {
            candidates.append(ordinaryGDB)
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate).inserted
        }
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
            args: [
                "-q", "-nx", "-batch",
                "-ex", "set endian little",
                "-ex", "set architecture arm",
                "-ex", "target sim"
            ],
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ))
    }
}
