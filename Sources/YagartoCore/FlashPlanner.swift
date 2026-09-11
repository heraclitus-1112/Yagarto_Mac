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

        let output = result.toolOutput ?? ""
        let normalized = output.lowercased()
        let noDeviceMarkers = [
            "no device found",
            "libusb_error_no_device",
            "no cmsis-dap device found",
            "unable to find a matching cmsis-dap device",
            "unable to find any matching cmsis-dap device",
            "could not find or open device"
        ]
        let explicitlyMissing = noDeviceMarkers.contains { normalized.contains($0) }
        let genericOpenFailure = normalized.contains("open failed")
            && !normalized.contains("permission")
            && !normalized.contains("access")
            && !normalized.contains("busy")
        if explicitlyMissing || genericOpenFailure {
            return false
        }
        throw YagartoError.buildStepFailed(
            openOCDExecutable,
            result.exitStatus,
            output
        )
    }
}

public struct FlashExecutor {
    private let hardwareProbe: any HardwareProbing
    private let runner: any ProcessRunning

    public init(
        hardwareProbe: any HardwareProbing = OpenOCDHardwareProbe(),
        runner: any ProcessRunning = ProcessRunner()
    ) {
        self.hardwareProbe = hardwareProbe
        self.runner = runner
    }

    @discardableResult
    public func execute(_ plan: FlashPlan) throws -> ProcessResult {
        let project = plan.command.workingDirectory
        let boardConfig = URL(fileURLWithPath: plan.boardConfig, isDirectory: false)
        guard try hardwareProbe.isBoardConnected(
            openOCDExecutable: plan.command.executable,
            boardConfig: boardConfig,
            projectDirectory: project
        ) else {
            throw YagartoError.flashBoardNotFound
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
