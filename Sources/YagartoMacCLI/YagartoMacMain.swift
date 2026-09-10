// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Darwin
import Foundation
import YagartoCore

@main
enum YagartoMacMain {
    static func main() {
        do {
            var command = try YagartoCLI.parseAsRoot()
            try command.run()
        } catch let error as YagartoError {
            CLIOutput.writeError(error)
            Darwin.exit(error.exitCode.rawValue)
        } catch {
            let parserCode = YagartoCLI.exitCode(for: error).rawValue
            let code = parserCode == 0 ? YagartoExitCode.success.rawValue : YagartoExitCode.usage.rawValue
            let message = YagartoCLI.fullMessage(for: error) + "\n"
            if code == 0 {
                CLIOutput.write(message, to: .standardOutput)
            } else {
                CLIOutput.write(message, to: .standardError)
            }
            Darwin.exit(code)
        }
    }
}
