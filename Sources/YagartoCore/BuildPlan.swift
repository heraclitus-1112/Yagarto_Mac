// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct BuildStep: Equatable, Sendable {
    public let command: CommandSpec
    public let standardOutputFile: URL?

    public init(command: CommandSpec, standardOutputFile: URL? = nil) {
        self.command = command
        self.standardOutputFile = standardOutputFile
    }
}

public struct BuildPlan: Equatable, Sendable {
    public let profile: ProfileID
    public let projectDirectory: URL
    public let outputDirectory: URL
    public let objectFiles: [URL]
    public let startupObjectFile: URL?
    public let elfFile: URL
    public let mapFile: URL
    public let binaryFile: URL
    public let listingFile: URL
    public let steps: [BuildStep]

    public init(
        profile: ProfileID,
        projectDirectory: URL,
        outputDirectory: URL,
        objectFiles: [URL],
        startupObjectFile: URL? = nil,
        elfFile: URL,
        mapFile: URL,
        binaryFile: URL,
        listingFile: URL,
        steps: [BuildStep]
    ) {
        self.profile = profile
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.outputDirectory = outputDirectory
        self.objectFiles = objectFiles
        self.startupObjectFile = startupObjectFile
        self.elfFile = elfFile
        self.mapFile = mapFile
        self.binaryFile = binaryFile
        self.listingFile = listingFile
        self.steps = steps
    }

    public var commands: [CommandSpec] {
        steps.map(\.command)
    }

    public var artifactFiles: [URL] {
        var seen = Set<String>()
        return (objectFiles + [startupObjectFile].compactMap { $0 }
            + [elfFile, mapFile, binaryFile, listingFile]
            + steps.compactMap(\.standardOutputFile)).filter { url in
                seen.insert(url.standardizedFileURL.path).inserted
            }
    }

    func rebased(to stagedOutputDirectory: URL) -> BuildPlan {
        let originalRoot = outputDirectory.standardizedFileURL.path
        let stagedRoot = stagedOutputDirectory.standardizedFileURL.path

        let exactOutputPaths = artifactFiles.reduce(into: [String: String]()) { mapping, artifact in
            let path = artifact.standardizedFileURL.path
            guard path.hasPrefix(originalRoot + "/") else { return }
            mapping[path] = stagedRoot + path.dropFirst(originalRoot.count)
        }

        func rebase(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            guard let rebasedPath = exactOutputPaths[path] else {
                return url
            }
            return URL(fileURLWithPath: rebasedPath, isDirectory: false)
        }

        func rebase(_ value: String) -> String {
            exactOutputPaths[value] ?? value
        }

        let stagedSteps = steps.map { step in
            BuildStep(
                command: CommandSpec(
                    executable: step.command.executable,
                    args: step.command.args.map(rebase),
                    workingDirectory: step.command.workingDirectory
                ),
                standardOutputFile: step.standardOutputFile.map(rebase)
            )
        }
        return BuildPlan(
            profile: profile,
            projectDirectory: projectDirectory,
            outputDirectory: stagedOutputDirectory,
            objectFiles: objectFiles.map(rebase),
            startupObjectFile: startupObjectFile.map(rebase),
            elfFile: rebase(elfFile),
            mapFile: rebase(mapFile),
            binaryFile: rebase(binaryFile),
            listingFile: rebase(listingFile),
            steps: stagedSteps
        )
    }
}
