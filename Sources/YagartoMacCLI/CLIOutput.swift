// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

enum CLIOutput {
    static func printJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func writeError(_ error: YagartoError) {
        let wantsJSON = CommandLine.arguments.enumerated().contains { index, argument in
            argument == "--format=json"
                || (argument == "json" && index > 0 && CommandLine.arguments[index - 1] == "--format")
        }
        if wantsJSON {
            let payload = ErrorOutput(
                error: error.localizedDescription,
                exitCode: error.exitCode.rawValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if var data = try? encoder.encode(payload) {
                data.append(0x0A)
                FileHandle.standardError.write(data)
                return
            }
        }
        write("错误：\(error.localizedDescription)\n", to: .standardError)
    }

    static func writeUsageError(arguments: [String] = CommandLine.arguments) {
        let diagnostic = CLIUsageDiagnostic(arguments: arguments)
        let wantsJSON = arguments.enumerated().contains { index, argument in
            argument == "--format=json"
                || (argument == "json" && index > 0 && arguments[index - 1] == "--format")
        }
        if wantsJSON {
            let payload = UsageErrorOutput(
                success: false,
                exitCode: YagartoExitCode.usage.rawValue,
                message: diagnostic.message,
                details: diagnostic.details
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if var data = try? encoder.encode(payload) {
                data.append(0x0A)
                FileHandle.standardError.write(data)
                return
            }
        }
        write("错误：\(diagnostic.message)\n", to: .standardError)
    }

    static func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }
}

private struct ErrorOutput: Encodable {
    let error: String
    let exitCode: Int32
}

private struct UsageErrorOutput: Encodable {
    let success: Bool
    let exitCode: Int32
    let message: String
    let details: String?
}

private struct CLIUsageDiagnostic {
    let message: String
    let details: String?

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--profile"),
           arguments.indices.contains(index + 1),
           ProfileID(rawValue: arguments[index + 1]) == nil {
            let value = arguments[index + 1]
            let choices = ProfileID.allCases.map(\.rawValue).joined(separator: "、")
            message = "参数 --profile 的值“\(value)”无效；可选值：\(choices)。请修改后重试。"
            details = "参数：--profile；输入：\(value)"
            return
        }

        let supplied = arguments.dropFirst().joined(separator: " ")
        message = "命令行参数无效：“\(supplied)”。请运行 yagarto-mac --help 查看用法。"
        details = supplied.isEmpty ? nil : "收到的参数：\(supplied)"
    }
}
