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
