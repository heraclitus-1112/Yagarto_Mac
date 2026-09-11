// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct FlashPlan: Codable, Equatable, Sendable {
    public let profile: ProfileID
    public let elf: String
    public let boardConfig: String
    public let command: CommandSpec

    public init(
        profile: ProfileID,
        elf: String,
        boardConfig: String,
        command: CommandSpec
    ) {
        self.profile = profile
        self.elf = elf
        self.boardConfig = boardConfig
        self.command = command
    }
}

public struct FlashPlanner {
    private let openOCDExecutable: String
    private let boardConfig: URL

    public init(openOCDExecutable: String, boardConfig: URL) {
        self.openOCDExecutable = openOCDExecutable
        self.boardConfig = boardConfig.standardizedFileURL
    }

    public func plan(
        configuration: ProjectConfiguration,
        elf: URL,
        projectDirectory: URL
    ) throws -> FlashPlan {
        guard configuration.profile == .stm32f4Discovery else {
            throw YagartoError.flashUnsupportedProfile(configuration.profile)
        }
        let project = projectDirectory.standardizedFileURL
        let elf = elf.standardizedFileURL
        let programCommand = "program \(try tclQuote(elf.path, error: .unsafeTclValue(elf.path))) verify reset exit"
        return FlashPlan(
            profile: configuration.profile,
            elf: elf.path,
            boardConfig: boardConfig.path,
            command: CommandSpec(
                executable: openOCDExecutable,
                args: ["-f", boardConfig.path, "-c", programCommand],
                workingDirectory: project
            )
        )
    }
}

public protocol HardwareProbing {
    func isBoardConnected(
        openOCDExecutable: String,
        boardConfig: URL,
        projectDirectory: URL
    ) throws -> Bool
}

public enum STLinkUSBPresence: String, Codable, Equatable, Sendable {
    case absent
    case present
}

public protocol STLinkUSBEnumerating {
    func presence() throws -> STLinkUSBPresence
}

public struct SystemProfilerSTLinkUSBEnumerator: STLinkUSBEnumerating {
    private let runner: any ProcessRunning
    private let executable: String

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        executable: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.executable = executable
            ?? environment["YAGARTO_MAC_SYSTEM_PROFILER"]
            ?? "/usr/sbin/system_profiler"
    }

    public func presence() throws -> STLinkUSBPresence {
        let result = try runner.run(CommandSpec(
            executable: executable,
            args: ["SPUSBDataType", "-json"],
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ))
        guard result.exitStatus == 0 else {
            throw YagartoError.buildStepFailed(
                executable,
                result.exitStatus,
                result.toolOutput ?? ""
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        } catch {
            throw YagartoError.buildStepFailed(
                executable,
                1,
                Self.enumerationFailureOutput(
                    result: result,
                    reason: "无法解析 USB 枚举 JSON。"
                )
            )
        }
        guard let root = object as? [String: Any],
              let devices = root["SPUSBDataType"] as? [Any] else {
            throw YagartoError.buildStepFailed(
                executable,
                1,
                Self.enumerationFailureOutput(
                    result: result,
                    reason: "USB 枚举 JSON 缺少 SPUSBDataType 数组。"
                )
            )
        }
        return Self.containsSTLink(in: devices) ? .present : .absent
    }

    private static let stLinkProductIDs: Set<Int> = [
        0x3744, 0x3748, 0x374B, 0x374D, 0x374E,
        0x374F, 0x3752, 0x3753, 0x3754, 0x3755, 0x3757
    ]

    private static func enumerationFailureOutput(
        result: ProcessResult,
        reason: String
    ) -> String {
        let standardError = ProcessResult(
            exitStatus: result.exitStatus,
            stdout: "",
            stderr: result.stderr
        ).toolOutput
        return [standardError, reason].compactMap { $0 }.joined(separator: "\n")
    }

    private static func containsSTLink(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if identifier(dictionary["vendor_id"]) == 0x0483,
               let productID = identifier(dictionary["product_id"]),
               stLinkProductIDs.contains(productID) {
                return true
            }
            return dictionary.values.contains(where: containsSTLink)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsSTLink)
        }
        return false
    }

    private static func identifier(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        guard let string = value as? String else { return nil }
        if let range = string.range(
            of: #"0x[0-9a-fA-F]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            return Int(string[range].dropFirst(2), radix: 16)
        }
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct OpenOCDHardwareProbe: HardwareProbing {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func isBoardConnected(
        openOCDExecutable: String,
        boardConfig: URL,
        projectDirectory: URL
    ) throws -> Bool {
        let result = try runner.run(CommandSpec(
            executable: openOCDExecutable,
            args: ["-f", boardConfig.path, "-c", "init", "-c", "shutdown"],
            workingDirectory: projectDirectory
        ))
        guard result.exitStatus != 0 else {
            return true
        }
        throw YagartoError.buildStepFailed(
            openOCDExecutable,
            result.exitStatus,
            result.toolOutput ?? ""
        )
    }
}

public struct FlashExecutor {
    private let stLinkUSBEnumerator: any STLinkUSBEnumerating
    private let hardwareProbe: any HardwareProbing
    private let runner: any ProcessRunning

    public init(
        stLinkUSBEnumerator: any STLinkUSBEnumerating = SystemProfilerSTLinkUSBEnumerator(),
        hardwareProbe: any HardwareProbing = OpenOCDHardwareProbe(),
        runner: any ProcessRunning = ProcessRunner()
    ) {
        self.stLinkUSBEnumerator = stLinkUSBEnumerator
        self.hardwareProbe = hardwareProbe
        self.runner = runner
    }

    @discardableResult
    public func execute(_ plan: FlashPlan) throws -> ProcessResult {
        let project = plan.command.workingDirectory
        let boardConfig = URL(fileURLWithPath: plan.boardConfig, isDirectory: false)
        guard try stLinkUSBEnumerator.presence() == .present else {
            throw YagartoError.flashBoardNotFound
        }
        guard try hardwareProbe.isBoardConnected(
            openOCDExecutable: plan.command.executable,
            boardConfig: boardConfig,
            projectDirectory: project
        ) else {
            throw YagartoError.buildStepFailed(
                plan.command.executable,
                1,
                "OpenOCD 探测未确认 ST-Link 连接。"
            )
        }

        let result = try runner.run(plan.command)
        guard result.exitStatus == 0 else {
            throw YagartoError.buildStepFailed(
                plan.command.executable,
                result.exitStatus,
                result.toolOutput ?? ""
            )
        }
        return result
    }
}
