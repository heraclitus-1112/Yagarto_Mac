// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum ProjectPathGuard {
    static func validateExistingSource(
        _ sourceURL: URL,
        relativePath: String,
        projectDirectory: URL
    ) throws {
        guard try metadata(at: sourceURL) != nil else {
            return
        }

        let resolvedProject = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedSource, within: resolvedProject) else {
            throw YagartoError.sourceEscapesProject(relativePath)
        }
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

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFLNK
    }
}
