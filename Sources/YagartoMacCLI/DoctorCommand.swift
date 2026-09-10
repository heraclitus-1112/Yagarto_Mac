// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import YagartoCore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "检查 ARM 工具链及可选后端。"
    )

    @Option(name: .long, help: "输出格式：text 或 json。")
    var format: OutputFormat = .text

    mutating func run() throws {
        let report = ToolResolver().doctor()
        switch format {
        case .json:
            try CLIOutput.printJSON(report)
        case .text:
            print("YAGARTO Mac 工具检查")
            for entry in report.entries {
                let requirement = entry.required ? "必需" : "可选"
                let status = entry.path.map { "已找到：\($0)" } ?? "未找到"
                print("[\(requirement)] \(entry.tool.rawValue)：\(status)")
            }
        }
    }
}
