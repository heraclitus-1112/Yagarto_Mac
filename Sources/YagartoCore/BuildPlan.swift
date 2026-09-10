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
    public let outputDirectory: URL
    public let objectFiles: [URL]
    public let elfFile: URL
    public let mapFile: URL
    public let binaryFile: URL
    public let listingFile: URL
    public let steps: [BuildStep]

    public init(
        profile: ProfileID,
        outputDirectory: URL,
        objectFiles: [URL],
        elfFile: URL,
        mapFile: URL,
        binaryFile: URL,
        listingFile: URL,
        steps: [BuildStep]
    ) {
        self.profile = profile
        self.outputDirectory = outputDirectory
        self.objectFiles = objectFiles
        self.elfFile = elfFile
        self.mapFile = mapFile
        self.binaryFile = binaryFile
        self.listingFile = listingFile
        self.steps = steps
    }

    public var commands: [CommandSpec] {
        steps.map(\.command)
    }
}
