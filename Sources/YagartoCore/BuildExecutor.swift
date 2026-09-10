// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct BuildExecutor {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    @discardableResult
    public func execute(_ plan: BuildPlan) throws -> [ProcessResult] {
        let projectDirectory = plan.steps.first?.command.workingDirectory
            ?? plan.outputDirectory.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        try ProjectPathGuard.createOutputDirectory(
            projectDirectory: projectDirectory,
            outputDirectory: plan.outputDirectory
        )

        var results: [ProcessResult] = []
        for step in plan.steps {
            let result = try runner.run(step.command)
            guard result.exitStatus == 0 else {
                throw YagartoError.buildStepFailed(
                    step.command.executable,
                    result.exitStatus,
                    result.stderr
                )
            }
            if let destination = step.standardOutputFile {
                do {
                    try Data(result.stdout.utf8).write(to: destination, options: .atomic)
                } catch {
                    throw YagartoError.cannotWriteOutput(
                        destination.path,
                        error.localizedDescription
                    )
                }
            }
            results.append(result)
        }
        return results
    }
}
