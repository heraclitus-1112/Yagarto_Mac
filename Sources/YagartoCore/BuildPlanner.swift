// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public struct BuildPlanner {
    private let toolPaths: [ToolIdentifier: String]
    private let linkerScriptURL: (ProfileID) throws -> URL

    public init(
        toolPaths: [ToolIdentifier: String],
        linkerScriptURL: @escaping (ProfileID) throws -> URL = LinkerScriptStore.url(for:)
    ) {
        self.toolPaths = toolPaths
        self.linkerScriptURL = linkerScriptURL
    }

    public func plan(
        configuration: ProjectConfiguration,
        projectDirectory: URL
    ) throws -> BuildPlan {
        try ConfigStore.validate(configuration)

        let projectDirectory = projectDirectory.standardizedFileURL
        let outputDirectory = projectDirectory
            .appendingPathComponent(".yagarto", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent(configuration.profile.rawValue, isDirectory: true)
        try ProjectPathGuard.validateOutputHierarchy(
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory
        )

        var objectNames = Set<String>()
        var objectFiles: [URL] = []
        var steps: [BuildStep] = []
        let cpuArguments = cpuArguments(for: configuration.profile)

        for source in configuration.sources {
            let sourceURL = projectDirectory.appendingPathComponent(source, isDirectory: false)
            try ProjectPathGuard.validateExistingSource(
                sourceURL,
                relativePath: source,
                projectDirectory: projectDirectory
            )
            let objectName = objectName(for: source)
            guard objectNames.insert(objectName.lowercased()).inserted else {
                throw YagartoError.duplicateObjectName(objectName)
            }
            let objectURL = outputDirectory.appendingPathComponent(objectName, isDirectory: false)
            objectFiles.append(objectURL)

            let assemblyTool: ToolIdentifier
            let assemblyArguments: [String]
            if source.hasSuffix(".S") {
                assemblyTool = .compiler
                assemblyArguments = cpuArguments + ["-c", "-x", "assembler-with-cpp"]
            } else {
                assemblyTool = .assembler
                assemblyArguments = cpuArguments
            }
            steps.append(BuildStep(command: CommandSpec(
                executable: try toolPath(for: assemblyTool),
                args: assemblyArguments + ["-o", objectURL.path, sourceURL.path],
                workingDirectory: projectDirectory
            )))
        }

        let elfFile = outputDirectory.appendingPathComponent("\(configuration.outputName).elf")
        let mapFile = outputDirectory.appendingPathComponent("\(configuration.outputName).map")
        let binaryFile = outputDirectory.appendingPathComponent("\(configuration.outputName).bin")
        let listingFile = outputDirectory.appendingPathComponent("\(configuration.outputName).lst")
        let scriptURL = try linkerScriptURL(configuration.profile)
        let trimmedEntry = configuration.entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = trimmedEntry.isEmpty ? "start" : trimmedEntry

        steps.append(BuildStep(command: CommandSpec(
            executable: try toolPath(for: .linker),
            args: [
                "-T", scriptURL.path,
                "-e", entry,
                "-Map", mapFile.path,
                "-o", elfFile.path
            ] + objectFiles.map(\.path),
            workingDirectory: projectDirectory
        )))
        steps.append(BuildStep(command: CommandSpec(
            executable: try toolPath(for: .objcopy),
            args: ["-O", "binary", elfFile.path, binaryFile.path],
            workingDirectory: projectDirectory
        )))
        steps.append(BuildStep(
            command: CommandSpec(
                executable: try toolPath(for: .objdump),
                args: ["-d", "-S", elfFile.path],
                workingDirectory: projectDirectory
            ),
            standardOutputFile: listingFile
        ))

        return BuildPlan(
            profile: configuration.profile,
            outputDirectory: outputDirectory,
            objectFiles: objectFiles,
            elfFile: elfFile,
            mapFile: mapFile,
            binaryFile: binaryFile,
            listingFile: listingFile,
            steps: steps
        )
    }

    private func cpuArguments(for profile: ProfileID) -> [String] {
        switch profile {
        case .arm7tdmi:
            return ["-mcpu=arm7tdmi", "-g"]
        case .cortexM4, .stm32f4Discovery:
            return ["-mcpu=cortex-m4", "-mthumb", "-g"]
        }
    }

    private func objectName(for source: String) -> String {
        let normalizedSource = source
            .replacingOccurrences(of: "\\", with: "/")
            .precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalizedSource.utf8))
        let shortHash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = URL(fileURLWithPath: normalizedSource)
            .deletingPathExtension()
            .lastPathComponent
        return "\(stem)-\(shortHash).o"
    }

    private func toolPath(for tool: ToolIdentifier) throws -> String {
        guard let path = toolPaths[tool] else {
            throw YagartoError.toolNotFound(tool.rawValue)
        }
        return path
    }
}
