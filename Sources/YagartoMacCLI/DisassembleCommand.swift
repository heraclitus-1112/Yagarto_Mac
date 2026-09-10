// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation
import YagartoCore

struct DisassembleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disassemble",
        abstract: "使用 objdump -d -S 反汇编 ELF。"
    )

    @Argument(help: "可选 ELF 路径；省略时从 yagarto.json 推导。")
    var elf: String?

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let directory = currentDirectory()
        let elfURL: URL
        if let elf {
            let candidate = URL(fileURLWithPath: elf)
            elfURL = candidate.path.hasPrefix("/")
                ? candidate
                : directory.appendingPathComponent(elf)
        } else {
            let configuration = try ConfigStore(projectDirectory: directory).load()
            elfURL = directory
                .appendingPathComponent(".yagarto/build", isDirectory: true)
                .appendingPathComponent(configuration.profile.rawValue, isDirectory: true)
                .appendingPathComponent("\(configuration.outputName).elf")
        }

        let command = CommandSpec(
            executable: try ToolResolver().resolve(.objdump),
            args: ["-d", "-S", elfURL.path],
            workingDirectory: directory
        )
        let result = try ProcessRunner().run(command)
        guard result.exitStatus == 0 else {
            throw YagartoError.buildStepFailed(
                command.executable,
                result.exitStatus,
                result.stderr
            )
        }

        switch format {
        case .json:
            try CLIOutput.printJSON(DisassemblyOutput(
                elf: elfURL.path,
                disassembly: result.stdout
            ))
        case .text:
            print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n")
        }
    }
}
