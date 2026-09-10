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

    static func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }
}

private struct ErrorOutput: Encodable {
    let error: String
    let exitCode: Int32
}
