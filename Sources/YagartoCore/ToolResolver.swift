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

    public init(tool: ToolIdentifier, required: Bool, path: String?) {
        self.tool = tool
        self.required = required
        self.path = path
        self.available = path != nil
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let entries: [DoctorEntry]

    public init(entries: [DoctorEntry]) {
        self.entries = entries
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

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.environment = environment
        self.fileExists = fileExists
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
        DoctorReport(entries: ToolIdentifier.allCases.map { tool in
            DoctorEntry(
                tool: tool,
                required: tool.isRequired,
                path: resolvedPath(for: tool, overrides: overrides)
            )
        })
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
}
