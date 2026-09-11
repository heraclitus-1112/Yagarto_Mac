// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public actor CoreBuildService: BuildServicing {
    private let overrides: [ToolIdentifier: String]
    private let environment: [String: String]

    public init(
        overrides: [ToolIdentifier: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.overrides = overrides
        self.environment = environment
    }

    public func build(projectDirectory: URL) async throws -> AppBuildResult {
        let project = projectDirectory.standardizedFileURL
        let configuration = try ConfigStore(projectDirectory: project).load()
        let resolver = ToolResolver(environment: environment)
        var tools: [ToolIdentifier: String] = [:]
        for tool in ToolIdentifier.allCases where tool.isRequired {
            tools[tool] = try resolver.resolve(tool, overrides: overrides)
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let plan = try BuildPlanner(toolPaths: tools).plan(
                    configuration: configuration,
                    projectDirectory: project
                )
                let results = try BuildExecutor().execute(plan)
                let output = results.flatMap { [$0.stdout, $0.stderr] }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let report = BuildDiagnosticParser.parse(output, projectDirectory: project)
                return AppBuildResult(
                    configuration: configuration,
                    projectDirectory: project,
                    elf: plan.elfFile,
                    artifacts: plan.artifactFiles,
                    diagnostics: report.diagnostics,
                    output: report.output
                )
            }.value
        } catch {
            let rawOutput: String
            if let coreError = error as? YagartoError {
                rawOutput = coreError.toolOutput ?? coreError.localizedDescription
            } else {
                rawOutput = error.localizedDescription
            }
            let report = BuildDiagnosticParser.parse(rawOutput, projectDirectory: project)
            let diagnostics = report.diagnostics.isEmpty
                ? [BuildDiagnostic(severity: .error, message: error.localizedDescription)]
                : report.diagnostics
            throw BuildServiceFailure(
                message: "构建失败：\(error.localizedDescription)",
                diagnostics: diagnostics,
                output: report.output
            )
        }
    }
}
