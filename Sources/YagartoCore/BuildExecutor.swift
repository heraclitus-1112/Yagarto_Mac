// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct BuildExecutor {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    @discardableResult
    public func execute(_ plan: BuildPlan) throws -> [ProcessResult] {
        try ProjectPathGuard.createOutputDirectory(
            projectDirectory: plan.projectDirectory,
            outputDirectory: plan.outputDirectory
        )
        try validateOutputPaths(for: plan)

        var results: [ProcessResult] = []
        for step in plan.steps {
            try validateOutputPaths(for: plan)
            let result = try runner.run(step.command)
            guard result.exitStatus == 0 else {
                throw YagartoError.buildStepFailed(
                    step.command.executable,
                    result.exitStatus,
                    result.toolOutput ?? ""
                )
            }
            if let destination = step.standardOutputFile {
                try ProjectPathGuard.validateArtifactPaths(
                    [destination],
                    outputDirectory: plan.outputDirectory
                )
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

    private func validateOutputPaths(for plan: BuildPlan) throws {
        try ProjectPathGuard.validateOutputHierarchy(
            projectDirectory: plan.projectDirectory,
            outputDirectory: plan.outputDirectory
        )
        try ProjectPathGuard.validateArtifactPaths(
            plan.artifactFiles,
            outputDirectory: plan.outputDirectory
        )
    }
}
