// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoCore

enum CLIOutput {
    static func rejectDuplicateFormatIfPresent(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        let optionArguments = arguments.dropFirst().prefix { $0 != "--" }
        let count = optionArguments.reduce(into: 0) { result, argument in
            if argument == "--format" || argument.hasPrefix("--format=") {
                result += 1
            }
        }
        guard count > 1 else { return false }
        writeDiagnostic(
            Diagnostic(
                code: "usage.duplicate_option",
                message: "命令行选项 --format 只能提供一次。请删除重复选项后重试。",
                details: "重复选项：--format"
            ),
            exitCode: .usage,
            arguments: arguments
        )
        return true
    }

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
            details: nil,
            toolOutput: error.toolOutput
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

        write("错误 [\(diagnostic.code)]：\(diagnostic.message)\n", to: .standardError)
        if let details = diagnostic.details {
            write("详情：\(details)\n", to: .standardError)
        }
        if let toolOutput = diagnostic.toolOutput {
            write("工具输出：\n\(toolOutput)\n", to: .standardError)
        }
    }

    private static func requestedJSON(_ arguments: [String]) -> Bool {
        let optionArguments = Array(arguments.dropFirst().prefix { $0 != "--" })
        return optionArguments.enumerated().contains { index, argument in
            argument == "--format=json"
                || (argument == "json" && index > 0 && optionArguments[index - 1] == "--format")
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
    let toolOutput: String?

    init(
        code: String,
        message: String,
        details: String? = nil,
        toolOutput: String? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.toolOutput = toolOutput
    }
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

        if supplied.count >= 3,
           supplied[0] == "profile",
           supplied[1] == "set",
           ProfileID(rawValue: supplied[2]) == nil {
            diagnostic = Self.invalidProfile(supplied[2])
            return
        }

        if supplied.first == "flash",
           !supplied.contains("--yes"),
           !supplied.contains("--dry-run") {
            diagnostic = Diagnostic(
                code: "usage.confirmation_required",
                message: "flash 会写入真实硬件；请确认目标后显式提供 --yes。",
                details: "缺少参数：--yes"
            )
            return
        }

        if supplied.first == "flash",
           let profile = Self.optionValue("--profile", in: supplied),
           profile != ProfileID.stm32f4Discovery.rawValue {
            diagnostic = Diagnostic(
                code: "usage.unsupported_profile",
                message: "flash 仅支持 stm32f4-discovery profile。",
                details: "输入 profile：\(profile)"
            )
            return
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
        case "new":
            return common.union(["--profile", "--parent"])
        case "import":
            return common.union(["--profile"])
        case "doctor", "build", "disassemble":
            return common
        case "run", "debug":
            return common.union(["--profile", "--dry-run"])
        case "flash":
            return common.union(["--profile", "--yes", "--dry-run"])
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

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        if let attached = arguments.first(where: { $0.hasPrefix("\(option)=") }) {
            return String(attached.dropFirst(option.count + 1))
        }
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
