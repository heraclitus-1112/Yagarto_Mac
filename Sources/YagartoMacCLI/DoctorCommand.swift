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
            for entry in report.entries where entry.required {
                let status = entry.path.map { "已找到：\($0)" } ?? "未找到"
                print("[必需] \(entry.tool.rawValue)：\(status)")
            }
            let gdb = report.entry(for: .gdb)
            print("[可选] GDB 可执行文件：\(gdb?.path.map { "已找到：\($0)" } ?? "未找到")")
            print("[能力] GDB target sim：\(gdb?.targetSimCapable == true ? "支持" : "不支持")")
            let qemu = report.entry(for: .qemuSystemARM)
            print("[可选] QEMU：\(qemu?.path.map { "已找到：\($0)" } ?? "未找到")")
            let openOCD = report.entry(for: .openOCD)
            print("[可选] OpenOCD：\(openOCD?.path.map { "已找到：\($0)" } ?? "未找到")")
            print(
                "[资源] STM32F4 Discovery board config："
                    + (report.stm32f4BoardConfig.map { "已找到：\($0)" } ?? "未找到")
            )
        }
    }
}
