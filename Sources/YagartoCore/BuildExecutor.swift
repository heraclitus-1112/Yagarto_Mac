// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct BuildExecutor {
    private let runner: any ProcessRunning
    private let atomicSwapPreflight: (URL, URL) throws -> Void

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
        self.atomicSwapPreflight = ProjectPathGuard.requireAtomicDirectorySwapSupport
    }

    init(
        runner: any ProcessRunning,
        atomicSwapPreflight: @escaping (URL, URL) throws -> Void
    ) {
        self.runner = runner
        self.atomicSwapPreflight = atomicSwapPreflight
    }

    @discardableResult
    public func execute(_ plan: BuildPlan) throws -> [ProcessResult] {
        try atomicSwapPreflight(plan.projectDirectory, plan.outputDirectory)
        try ProjectPathGuard.cleanupStaleBuildDirectories(
            profile: plan.profile,
            projectDirectory: plan.projectDirectory,
            outputDirectory: plan.outputDirectory
        )
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
        try normalizePublishedTextPaths(
            stagedPlan: stagedPlan,
            finalPlan: plan
        )
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

    private func normalizePublishedTextPaths(
        stagedPlan: BuildPlan,
        finalPlan: BuildPlan
    ) throws {
        let stagedRoot = Data(stagedPlan.outputDirectory.path.utf8)
        let finalRoot = Data(finalPlan.outputDirectory.path.utf8)
        for artifact in [stagedPlan.mapFile, stagedPlan.listingFile] {
            guard FileManager.default.fileExists(atPath: artifact.path) else {
                continue
            }
            do {
                var contents = try Data(contentsOf: artifact)
                var searchStart = contents.startIndex
                while searchStart < contents.endIndex,
                      let range = contents.range(
                        of: stagedRoot,
                        in: searchStart..<contents.endIndex
                      ) {
                    contents.replaceSubrange(range, with: finalRoot)
                    searchStart = range.lowerBound + finalRoot.count
                }
                try contents.write(to: artifact, options: .atomic)
            } catch {
                throw YagartoError.cannotWriteOutput(
                    artifact.path,
                    error.localizedDescription
                )
            }
        }
    }
}
