// SPDX-License-Identifier: GPL-3.0-or-later

public enum YagartoExitCode: Int32, Codable, Sendable {
    case success = 0
    case usage = 2
    case configuration = 3
    case buildFailure = 4
    case missingTool = 5
    case unsupported = 6
    case interrupted = 130
}
