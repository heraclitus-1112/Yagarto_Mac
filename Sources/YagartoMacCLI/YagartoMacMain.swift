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
            if parserCode == 0 {
                let message = YagartoCLI.fullMessage(for: error) + "\n"
                CLIOutput.write(message, to: .standardOutput)
                Darwin.exit(YagartoExitCode.success.rawValue)
            }
            if parserCode == ExitCode.validationFailure.rawValue {
                CLIOutput.writeUsageError()
                Darwin.exit(YagartoExitCode.usage.rawValue)
            }
            let internalError = YagartoError.internalFailure(error.localizedDescription)
            CLIOutput.writeError(internalError)
            Darwin.exit(internalError.exitCode.rawValue)
        }
    }
}
