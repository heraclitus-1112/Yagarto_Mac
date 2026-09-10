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
        let diagnostic = Diagnostic(
            code: error.diagnosticCode,
            message: error.message,
            details: nil
        )
        writeDiagnostic(diagnostic, exitCode: error.exitCode)
    }

    static func writeUsageError(arguments: [String] = CommandLine.arguments) {
        writeDiagnostic(
            CLIUsageDiagnostic(arguments: arguments).diagnostic,
            exitCode: .usage,
            arguments: arguments
        )
    }

    static func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }

    private static func writeDiagnostic(
        _ diagnostic: Diagnostic,
        exitCode: YagartoExitCode,
        arguments: [String] = CommandLine.arguments
    ) {
        if requestedJSON(arguments) {
            let payload = ErrorEnvelope(
                schemaVersion: 1,
                success: false,
                exitCode: exitCode.rawValue,
                error: diagnostic
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
        if let details = diagnostic.details {
            write("详情：\(details)\n", to: .standardError)
        }
    }

    private static func requestedJSON(_ arguments: [String]) -> Bool {
        arguments.enumerated().contains { index, argument in
            argument == "--format=json"
                || (argument == "json" && index > 0 && arguments[index - 1] == "--format")
        }
    }
}

private struct ErrorEnvelope: Encodable {
    let schemaVersion: Int
    let success: Bool
    let exitCode: Int32
    let error: Diagnostic
}

private struct Diagnostic: Encodable {
    let code: String
    let message: String
    let details: String?
}

private struct CLIUsageDiagnostic {
    let diagnostic: Diagnostic

    init(arguments: [String]) {
        let supplied = Array(arguments.dropFirst())
        let allowedOptions = Self.allowedLongOptions(for: supplied)
        if let unknown = supplied.first(where: { argument in
            guard argument.hasPrefix("--") else { return false }
            let name = String(argument.split(separator: "=", maxSplits: 1)[0])
            return !allowedOptions.contains(name)
        }) {
            diagnostic = Diagnostic(
                code: "usage.unknown_option",
                message: "不支持命令行选项“\(unknown)”。请运行 yagarto-mac --help 查看可用选项。",
                details: "输入：\(unknown)"
            )
            return
        }

        if let attached = supplied.first(where: { $0.hasPrefix("--profile=") }) {
            let value = String(attached.dropFirst("--profile=".count))
            if ProfileID(rawValue: value) == nil {
                diagnostic = Self.invalidProfile(value)
                return
            }
        }

        if let index = supplied.firstIndex(of: "--profile") {
            guard supplied.indices.contains(index + 1),
                  !supplied[index + 1].hasPrefix("-") else {
                diagnostic = Diagnostic(
                    code: "usage.missing_value",
                    message: "参数 --profile 缺少值。请提供一个有效 profile。",
                    details: "可选值：\(Self.profileChoices)"
                )
                return
            }
            let value = supplied[index + 1]
            if ProfileID(rawValue: value) == nil {
                diagnostic = Self.invalidProfile(value)
                return
            }
        }

        let joined = supplied.joined(separator: " ")
        diagnostic = Diagnostic(
            code: "usage.invalid_invocation",
            message: "命令行参数无效。请运行 yagarto-mac --help 查看用法。",
            details: joined.isEmpty ? nil : "收到的参数：\(joined)"
        )
    }

    private static var profileChoices: String {
        ProfileID.allCases.map(\.rawValue).joined(separator: "、")
    }

    private static func allowedLongOptions(for arguments: [String]) -> Set<String> {
        let common: Set<String> = ["--help", "--format"]
        guard let command = arguments.first else {
            return ["--help", "--version"]
        }
        switch command {
        case "init":
            return common.union(["--profile"])
        case "doctor", "build", "disassemble":
            return common
        case "profile":
            return common
        default:
            return ["--help", "--version"]
        }
    }

    private static func invalidProfile(_ value: String) -> Diagnostic {
        Diagnostic(
            code: "usage.invalid_value",
            message: "参数 --profile 的值“\(value)”无效；可选值：\(profileChoices)。请修改后重试。",
            details: "参数：--profile；输入：\(value)"
        )
    }
}
