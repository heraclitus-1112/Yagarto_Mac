// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum ProjectPathGuard {
    struct CanonicalSource {
        let url: URL
        let relativePath: String
        let identity: String
    }

    static func canonicalSource(
        relativePath: String,
        projectDirectory: URL
    ) throws -> CanonicalSource {
        let project = projectDirectory.standardizedFileURL
        let lexicalSource = project
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard contains(lexicalSource, within: project) else {
            throw YagartoError.sourceEscapesProject(relativePath)
        }

        guard try metadata(at: lexicalSource) != nil else {
            let canonicalPath = try Self.relativePath(from: lexicalSource, within: project)
            return CanonicalSource(
                url: lexicalSource,
                relativePath: canonicalPath,
                identity: "path:\(canonicalPath)"
            )
        }

        let resolvedProject = project.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = lexicalSource.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedSource, within: resolvedProject) else {
            throw YagartoError.sourceEscapesProject(relativePath)
        }
        let canonicalPath = try Self.relativePath(
            from: resolvedSource,
            within: resolvedProject
        )
        return CanonicalSource(
            url: resolvedSource,
            relativePath: canonicalPath,
            identity: try fileIdentity(at: resolvedSource)
        )
    }

    static func validateOutputHierarchy(
        projectDirectory: URL,
        outputDirectory: URL
    ) throws {
        for candidate in try outputComponents(
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory
        ) {
            if let metadata = try metadata(at: candidate), isSymbolicLink(metadata) {
                throw YagartoError.outputSymlink(candidate.path)
            }
        }
    }

    static func createOutputDirectory(
        projectDirectory: URL,
        outputDirectory: URL
    ) throws {
        for candidate in try outputComponents(
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory
        ) {
            if let existing = try metadata(at: candidate) {
                if isSymbolicLink(existing) {
                    throw YagartoError.outputSymlink(candidate.path)
                }
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: false
                )
            } catch {
                throw YagartoError.cannotWriteOutput(
                    candidate.path,
                    error.localizedDescription
                )
            }
            if let created = try metadata(at: candidate), isSymbolicLink(created) {
                throw YagartoError.outputSymlink(candidate.path)
            }
        }
    }

    static func validateArtifactPaths(
        _ artifacts: [URL],
        outputDirectory: URL
    ) throws {
        let output = outputDirectory.standardizedFileURL
        for artifact in artifacts {
            let candidate = artifact.standardizedFileURL
            guard contains(candidate, within: output) else {
                throw YagartoError.pathTraversal(candidate.path)
            }
            if let metadata = try metadata(at: candidate), isSymbolicLink(metadata) {
                throw YagartoError.outputSymlink(candidate.path)
            }
        }
    }

    static func createPrivateStagingDirectory(
        projectDirectory: URL,
        outputDirectory: URL
    ) throws -> URL {
        let parent = outputDirectory.standardizedFileURL.deletingLastPathComponent()
        try createOutputDirectory(
            projectDirectory: projectDirectory,
            outputDirectory: parent
        )
        try validateOutputHierarchy(
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory
        )

        for _ in 0..<8 {
            let candidate = parent.appendingPathComponent(
                ".\(outputDirectory.lastPathComponent)-staging-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            let result = candidate.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkdir(path, S_IRWXU)
            }
            if result == 0 {
                guard let created = try metadata(at: candidate),
                      (created.st_mode & S_IFMT) == S_IFDIR,
                      (created.st_mode & 0o777) == S_IRWXU else {
                    try? FileManager.default.removeItem(at: candidate)
                    throw YagartoError.unsafeBuildArtifact(candidate.path)
                }
                return candidate
            }
            if errno != EEXIST {
                throw YagartoError.cannotWriteOutput(
                    candidate.path,
                    String(cString: strerror(errno))
                )
            }
        }
        throw YagartoError.cannotWriteOutput(
            parent.path,
            "无法分配唯一的构建 staging 目录。"
        )
    }

    static func validateProducedArtifacts(
        _ artifacts: [URL],
        outputDirectory: URL
    ) throws {
        let output = outputDirectory.standardizedFileURL
        for artifact in artifacts {
            let candidate = artifact.standardizedFileURL
            guard contains(candidate, within: output) else {
                throw YagartoError.pathTraversal(candidate.path)
            }
            guard let value = try metadata(at: candidate) else {
                throw YagartoError.buildArtifactMissing(candidate.path)
            }
            guard (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1 else {
                throw YagartoError.unsafeBuildArtifact(candidate.path)
            }
        }
    }

    static func publishStagingDirectory(
        _ stagingDirectory: URL,
        to outputDirectory: URL,
        projectDirectory: URL
    ) throws {
        let staging = stagingDirectory.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        try validateOutputHierarchy(
            projectDirectory: projectDirectory,
            outputDirectory: output
        )

        let outputExists = try metadata(at: output) != nil
        let result = staging.withUnsafeFileSystemRepresentation { stagingPath in
            output.withUnsafeFileSystemRepresentation { outputPath in
                guard let stagingPath, let outputPath else { return Int32(-1) }
                if outputExists {
                    return Darwin.renamex_np(stagingPath, outputPath, UInt32(RENAME_SWAP))
                }
                return Darwin.rename(stagingPath, outputPath)
            }
        }
        guard result == 0 else {
            throw YagartoError.cannotWriteOutput(
                output.path,
                String(cString: strerror(errno))
            )
        }
    }

    private static func outputComponents(
        projectDirectory: URL,
        outputDirectory: URL
    ) throws -> [URL] {
        let project = projectDirectory.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        let projectComponents = project.pathComponents
        let outputPathComponents = output.pathComponents
        guard outputPathComponents.count > projectComponents.count,
              Array(outputPathComponents.prefix(projectComponents.count)) == projectComponents else {
            throw YagartoError.pathTraversal(output.path)
        }

        var candidate = project
        return outputPathComponents.dropFirst(projectComponents.count).map { component in
            candidate.appendPathComponent(component, isDirectory: true)
            return candidate
        }
    }

    private static func contains(_ child: URL, within parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }

    private static func relativePath(from child: URL, within parent: URL) throws -> String {
        guard contains(child, within: parent) else {
            throw YagartoError.sourceEscapesProject(child.path)
        }
        return child.pathComponents
            .dropFirst(parent.pathComponents.count)
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
    }

    private static func metadata(at url: URL) throws -> stat? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        if result == 0 {
            return value
        }
        if errno == ENOENT {
            return nil
        }
        let detail = String(cString: strerror(errno))
        throw YagartoError.configurationIOFailed(url.path, detail)
    }

    private static func fileIdentity(at url: URL) throws -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let system = attributes[.systemNumber] as? NSNumber,
                  let file = attributes[.systemFileNumber] as? NSNumber else {
                throw YagartoError.configurationIOFailed(
                    url.path,
                    "文件系统未提供稳定文件标识。"
                )
            }
            return "file:\(system.uint64Value):\(file.uint64Value)"
        } catch let error as YagartoError {
            throw error
        } catch {
            throw YagartoError.configurationIOFailed(
                url.path,
                error.localizedDescription
            )
        }
    }

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFLNK
    }
}
