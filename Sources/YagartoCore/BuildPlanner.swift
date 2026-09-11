// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public struct BuildPlanner {
    private let toolPaths: [ToolIdentifier: String]
    private let linkerScriptURL: (ProfileID) throws -> URL
    private let startupSourceURL: (ProfileID) throws -> URL

    public init(
        toolPaths: [ToolIdentifier: String],
        linkerScriptURL: @escaping (ProfileID) throws -> URL = LinkerScriptStore.url(for:),
        startupSourceURL: @escaping (ProfileID) throws -> URL = StartupStore.url(for:)
    ) {
        self.toolPaths = toolPaths
        self.linkerScriptURL = linkerScriptURL
        self.startupSourceURL = startupSourceURL
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
        var sourceIdentities = Set<String>()
        var objectFiles: [URL] = []
        var steps: [BuildStep] = []
        let cpuArguments = cpuArguments(for: configuration.profile)

        for source in configuration.sources {
            let canonicalSource = try ProjectPathGuard.canonicalSource(
                relativePath: source,
                projectDirectory: projectDirectory
            )
            try ProjectPathGuard.validateSourceOutsideOutput(
                canonicalSource.url,
                outputDirectory: outputDirectory.deletingLastPathComponent(),
                configuredPath: source
            )
            guard sourceIdentities.insert(canonicalSource.identity).inserted else {
                throw YagartoError.duplicateSource(source)
            }
            let objectName = objectName(for: canonicalSource.relativePath)
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
                args: assemblyArguments + ["-o", objectURL.path, canonicalSource.url.path],
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

        let startupObjectFile: URL?
        if let startupName = configuration.profile.startupSourceName {
            let sourceURL = try startupSourceURL(configuration.profile)
            let objectURL = outputDirectory.appendingPathComponent(
                "\(URL(fileURLWithPath: startupName).deletingPathExtension().lastPathComponent).o"
            )
            startupObjectFile = objectURL
            steps.append(BuildStep(command: CommandSpec(
                executable: try toolPath(for: .assembler),
                args: cpuArguments + ["-o", objectURL.path, sourceURL.path],
                workingDirectory: projectDirectory
            )))
        } else {
            startupObjectFile = nil
        }

        let linkEntry: String
        var linkerArguments: [String]
        if let startupObjectFile {
            let userEntry = try validatedLinkerSymbol(entry)
            linkEntry = "Reset_Handler"
            linkerArguments = [
                "-T", scriptURL.path,
                "-e", linkEntry,
                "--defsym=__yagarto_entry=\(userEntry)",
                "-Map", mapFile.path,
                "-o", elfFile.path,
                startupObjectFile.path
            ] + objectFiles.map(\.path)
        } else {
            linkEntry = entry
            linkerArguments = [
                "-T", scriptURL.path,
                "-e", linkEntry,
                "-Map", mapFile.path,
                "-o", elfFile.path
            ] + objectFiles.map(\.path)
        }

        steps.append(BuildStep(command: CommandSpec(
            executable: try toolPath(for: .linker),
            args: linkerArguments,
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
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory,
            objectFiles: objectFiles,
            startupObjectFile: startupObjectFile,
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

    private func validatedLinkerSymbol(_ value: String) throws -> String {
        let pattern = #"^[\p{L}_.$][\p{L}\p{M}\p{N}_.$]*$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw YagartoError.invalidEntry(value)
        }
        return value
    }

    private func toolPath(for tool: ToolIdentifier) throws -> String {
        guard let path = toolPaths[tool] else {
            throw YagartoError.toolNotFound(tool.rawValue)
        }
        return path
    }
}
