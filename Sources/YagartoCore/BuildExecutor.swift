// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct BuildExecutor {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    @discardableResult
    public func execute(_ plan: BuildPlan) throws -> [ProcessResult] {
        let stagingDirectory = try ProjectPathGuard.createPrivateStagingDirectory(
            projectDirectory: plan.projectDirectory,
            outputDirectory: plan.outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedPlan = plan.rebased(to: stagingDirectory)

        var results: [ProcessResult] = []
        for step in stagedPlan.steps {
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
                    outputDirectory: stagedPlan.outputDirectory
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
        try ProjectPathGuard.validateProducedArtifacts(
            stagedPlan.artifactFiles,
            outputDirectory: stagedPlan.outputDirectory
        )
        try ProjectPathGuard.publishStagingDirectory(
            stagingDirectory,
            to: plan.outputDirectory,
            projectDirectory: plan.projectDirectory
        )
        return results
    }
}
