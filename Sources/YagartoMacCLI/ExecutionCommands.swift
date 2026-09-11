// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import YagartoCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "运行 ELF，或输出运行启动计划。"
    )

    @Argument(help: "可选 ELF 路径；省略时从 yagarto.json 推导。")
    var elf: String?

    @Option(name: .long, help: "临时覆盖项目 profile。")
    var profile: ProfileID?

    @Flag(name: .long, help: "只输出启动计划，不执行 GDB。")
    var dryRun = false

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        if !dryRun, case .json = format {
            throw YagartoError.interactiveJSONUnsupported
        }
        let plan = try makeDebugLaunchPlan(
            mode: .run,
            elfArgument: elf,
            profileOverride: profile
        )
        if dryRun {
            try printDebugLaunchPlan(plan, format: format)
            return
        }
        try executeDebugLaunchPlan(plan)
    }
}

struct DebugCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "启动 GDB 调试，或输出调试启动计划。"
    )

    @Argument(help: "可选 ELF 路径；省略时从 yagarto.json 推导。")
    var elf: String?

    @Option(name: .long, help: "临时覆盖项目 profile。")
    var profile: ProfileID?

    @Flag(name: .long, help: "只输出启动计划，不执行 GDB。")
    var dryRun = false

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        if !dryRun, case .json = format {
            throw YagartoError.interactiveJSONUnsupported
        }
        let plan = try makeDebugLaunchPlan(
            mode: .debug,
            elfArgument: elf,
            profileOverride: profile
        )
        if dryRun {
            try printDebugLaunchPlan(plan, format: format)
            return
        }
        try executeDebugLaunchPlan(plan)
    }
}

struct FlashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flash",
        abstract: "使用 OpenOCD 烧录 STM32F4 Discovery。"
    )

    @Argument(help: "可选 ELF 路径；省略时从 yagarto.json 推导。")
    var elf: String?

    @Option(name: .long, help: "临时覆盖项目 profile。")
    var profile: ProfileID?

    @Flag(name: .long, help: "确认执行真实硬件烧录。")
    var yes = false

    @Flag(name: .long, help: "只输出烧录计划，不探测或写入硬件。")
    var dryRun = false

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        guard dryRun || yes else {
            throw ValidationError("flash 会写入真实硬件；请显式提供 --yes。")
        }
        if let profile, profile != .stm32f4Discovery {
            throw YagartoError.flashUnsupportedProfile(profile)
        }

        let directory = currentDirectory()
        let store = ConfigStore(projectDirectory: directory)
        var configuration: ProjectConfiguration
        if FileManager.default.fileExists(atPath: store.configurationURL.path) {
            configuration = try store.load()
        } else if elf != nil {
            configuration = .default
        } else {
            throw YagartoError.configurationNotFound(store.configurationURL.path)
        }
        if let profile {
            configuration.profile = profile
        }
        guard configuration.profile == .stm32f4Discovery else {
            throw YagartoError.flashUnsupportedProfile(configuration.profile)
        }

        let elfURL: URL
        if let elf {
            let candidate = URL(fileURLWithPath: elf)
            elfURL = candidate.path.hasPrefix("/")
                ? candidate
                : directory.appendingPathComponent(elf)
        } else {
            elfURL = directory
                .appendingPathComponent(".yagarto/build", isDirectory: true)
                .appendingPathComponent(configuration.profile.rawValue, isDirectory: true)
                .appendingPathComponent("\(configuration.outputName).elf")
        }

        let resolver = ToolResolver()
        let openOCD = try resolver.resolve(.openOCD)
        let boardConfig = try resolver.resolveSTM32F4BoardConfig(openOCDPath: openOCD)
        let plan = try FlashPlanner(
            openOCDExecutable: openOCD,
            boardConfig: URL(fileURLWithPath: boardConfig)
        ).plan(
            configuration: configuration,
            elf: elfURL,
            projectDirectory: directory
        )
        if dryRun {
            try printFlashPlan(plan, format: format)
            return
        }
        _ = try FlashExecutor().execute(plan)
        let output = FlashOutput(
            status: "ok",
            profile: configuration.profile,
            elf: plan.elf
        )
        switch format {
        case .json:
            try CLIOutput.printJSON(output)
        case .text:
            print("烧录完成（\(configuration.profile.rawValue)）：\(plan.elf)")
        }
    }
}

private func printFlashPlan(_ plan: FlashPlan, format: OutputFormat) throws {
    switch format {
    case .json:
        try CLIOutput.printJSON(plan)
    case .text:
        print("profile：\(plan.profile.rawValue)")
        print("ELF：\(plan.elf)")
        print("OpenOCD：\(plan.command.executable)")
        print("board config：\(plan.boardConfig)")
        print("参数：\(plan.command.args.joined(separator: " "))")
    }
}

private func makeDebugLaunchPlan(
    mode: DebugMode,
    elfArgument: String?,
    profileOverride: ProfileID?
) throws -> DebugLaunchPlan {
    let directory = currentDirectory()
    let store = ConfigStore(projectDirectory: directory)
    var configuration: ProjectConfiguration
    if FileManager.default.fileExists(atPath: store.configurationURL.path) {
        configuration = try store.load()
    } else if elfArgument != nil {
        configuration = .default
    } else {
        throw YagartoError.configurationNotFound(store.configurationURL.path)
    }
    if let profileOverride {
        configuration.profile = profileOverride
    }

    let elfURL: URL
    if let elfArgument {
        let candidate = URL(fileURLWithPath: elfArgument)
        elfURL = candidate.path.hasPrefix("/")
            ? candidate
            : directory.appendingPathComponent(elfArgument)
    } else {
        elfURL = directory
            .appendingPathComponent(".yagarto/build", isDirectory: true)
            .appendingPathComponent(configuration.profile.rawValue, isDirectory: true)
            .appendingPathComponent("\(configuration.outputName).elf")
    }

    let resolver = ToolResolver()
    let simulator = configuration.profile == .arm7tdmi
        ? try? resolver.resolveGDBSimulator()
        : nil
    var tools: [ToolIdentifier: String] = [:]
    if let simulator {
        tools[.gdb] = simulator
    } else if let gdb = try? resolver.resolve(.gdb) {
        tools[.gdb] = gdb
    }
    if let qemu = try? resolver.resolve(.qemuSystemARM) {
        tools[.qemuSystemARM] = qemu
    }
    var boardConfig: URL?
    if let openOCD = try? resolver.resolve(.openOCD) {
        tools[.openOCD] = openOCD
        if let path = try? resolver.resolveSTM32F4BoardConfig(openOCDPath: openOCD) {
            boardConfig = URL(fileURLWithPath: path)
        }
    }

    return try DebugPlanner(
        toolPaths: tools,
        gdbSimulatorPath: simulator,
        openOCDBoardConfig: boardConfig
    ).plan(
        mode: mode,
        configuration: configuration,
        elf: elfURL,
        projectDirectory: directory
    )
}

private func printDebugLaunchPlan(
    _ plan: DebugLaunchPlan,
    format: OutputFormat
) throws {
    switch format {
    case .json:
        try CLIOutput.printJSON(plan)
    case .text:
        print("profile：\(plan.profile.rawValue)")
        print("backend：\(plan.backend.rawValue)")
        print("GDB：\(plan.gdbExecutable)")
        for warning in plan.warnings {
            print("警告：\(warning)")
        }
        for command in plan.initCommands {
            print("  -ex \(command)")
        }
    }
}

private func executeDebugLaunchPlan(_ plan: DebugLaunchPlan) throws {
    try DebugPlanner.prepareForLaunch(plan)
    for warning in plan.warnings {
        CLIOutput.write("警告：\(warning)\n", to: .standardError)
    }
    let status = try ProcessRunner().runInteractive(plan.command)
    if status == YagartoExitCode.interrupted.rawValue {
        throw YagartoError.interrupted
    }
    guard status == 0 else {
        throw YagartoError.buildStepFailed(plan.gdbExecutable, status, "")
    }
}
