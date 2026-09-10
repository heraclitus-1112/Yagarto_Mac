// SPDX-License-Identifier: GPL-3.0-or-later

public struct ProjectConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profile: ProfileID
    public var entry: String
    public var sources: [String]
    public var outputName: String

    public init(
        schemaVersion: Int = 1,
        profile: ProfileID = .arm7tdmi,
        entry: String = "start",
        sources: [String] = ["demo.s"],
        outputName: String = "demo"
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.entry = entry
        self.sources = sources
        self.outputName = outputName
    }

    public static let `default` = ProjectConfiguration()
}
