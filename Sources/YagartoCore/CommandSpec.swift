// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct CommandSpec: Codable, Equatable, Sendable {
    public let executable: String
    public let args: [String]
    public let workingDirectory: URL

    public init(executable: String, args: [String], workingDirectory: URL) {
        self.executable = executable
        self.args = args
        self.workingDirectory = workingDirectory.standardizedFileURL
    }
}
