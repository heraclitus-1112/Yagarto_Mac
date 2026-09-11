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

    static func validateSourceOutsideOutput(
        _ source: URL,
        outputDirectory: URL,
        configuredPath: String
    ) throws {
        let candidate = source.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        guard candidate != output, !contains(candidate, within: output) else {
            throw YagartoError.sourceInsideBuildOutput(configuredPath)
        }
    }

    static func validateConfiguredSourceOutsideManagedBuildRoot(
        relativePath: String,
        projectDirectory: URL
    ) throws {
        let canonicalProject = projectDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let lexicalSource = canonicalProject
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let managedBuildRoot = canonicalProject
            .appendingPathComponent(".yagarto", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .standardizedFileURL
        guard lexicalSource != managedBuildRoot,
              !contains(lexicalSource, within: managedBuildRoot) else {
            throw YagartoError.sourceInsideBuildOutput(relativePath)
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

    static func requireAtomicDirectorySwapSupport(
        projectDirectory: URL,
        outputDirectory: URL
    ) throws {
        try requireAtomicDirectorySwapSupport(
            projectDirectory: projectDirectory,
            outputDirectory: outputDirectory,
            identifier: UUID(),
            inspectProbeRoot: { _ in }
        )
    }

    static func requireAtomicDirectorySwapSupport(
        projectDirectory: URL,
        outputDirectory: URL,
        identifier: UUID,
        beforeSecondProbeDirectory: (URL) throws -> Void = { _ in },
        inspectProbeRoot: (URL) throws -> Void
    ) throws {
        let output = outputDirectory.standardizedFileURL
        let parent = output.deletingLastPathComponent()
        try createOutputDirectory(
            projectDirectory: projectDirectory,
            outputDirectory: parent
        )
        try validateOutputHierarchy(
            projectDirectory: projectDirectory,
            outputDirectory: output
        )

        let probeRoot = parent.appendingPathComponent(
            ".\(output.lastPathComponent)-swap-probe-\(identifier.uuidString.lowercased())",
            isDirectory: true
        )
        let first = probeRoot.appendingPathComponent("a", isDirectory: true)
        let second = probeRoot.appendingPathComponent("b", isDirectory: true)
        var ownedRoot: DirectoryIdentity?
        var ownedChildren = Set<DirectoryIdentity>()
        var firstIdentity: DirectoryIdentity?
        var secondIdentity: DirectoryIdentity?
        defer {
            for child in [first, second] {
                guard let current = try? metadata(at: child),
                      ownedChildren.contains(DirectoryIdentity(current)),
                      (current.st_mode & S_IFMT) == S_IFDIR else {
                    continue
                }
                child.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.rmdir(path) }
                }
            }
            if let ownedRoot,
               let current = try? metadata(at: probeRoot),
               DirectoryIdentity(current) == ownedRoot,
               (current.st_mode & S_IFMT) == S_IFDIR {
                probeRoot.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.rmdir(path) }
                }
            }
        }

        try createPrivateDirectory(probeRoot, errorPath: output.path) { metadata in
            ownedRoot = DirectoryIdentity(metadata)
        }
        try createPrivateDirectory(first, errorPath: output.path) { metadata in
            let identity = DirectoryIdentity(metadata)
            firstIdentity = identity
            ownedChildren.insert(identity)
        }
        try beforeSecondProbeDirectory(probeRoot)
        try createPrivateDirectory(second, errorPath: output.path) { metadata in
            let identity = DirectoryIdentity(metadata)
            secondIdentity = identity
            ownedChildren.insert(identity)
        }
        try inspectProbeRoot(probeRoot)
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else { return Int32(-1) }
                return Darwin.renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw YagartoError.atomicDirectorySwapUnsupported(
                output.path,
                String(cString: strerror(errno))
            )
        }
        guard let firstIdentity,
              let secondIdentity,
              let firstAfter = try metadata(at: first),
              let secondAfter = try metadata(at: second),
              DirectoryIdentity(firstAfter) == secondIdentity,
              DirectoryIdentity(secondAfter) == firstIdentity else {
            throw YagartoError.atomicDirectorySwapUnsupported(
                output.path,
                "同卷目录交换未保持预期原子语义。"
            )
        }
    }

    static func cleanupStaleBuildDirectories(
        profile: ProfileID,
        projectDirectory: URL,
        outputDirectory: URL
    ) throws {
        let project = projectDirectory.standardizedFileURL
        let output = outputDirectory.standardizedFileURL
        let parent = output.deletingLastPathComponent()
        let expectedParent = project
            .appendingPathComponent(".yagarto", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .standardizedFileURL
        guard parent == expectedParent,
              output.lastPathComponent == profile.rawValue else {
            throw YagartoError.pathTraversal(output.path)
        }
        try createOutputDirectory(
            projectDirectory: project,
            outputDirectory: parent
        )
        try validateOutputHierarchy(
            projectDirectory: project,
            outputDirectory: parent
        )

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw YagartoError.cannotWriteOutput(parent.path, error.localizedDescription)
        }
        for candidate in entries where isStrictStaleBuildDirectoryName(
            candidate.lastPathComponent,
            profile: profile
        ) {
            guard let value = try metadata(at: candidate) else { continue }
            if isSymbolicLink(value) {
                throw YagartoError.outputSymlink(candidate.path)
            }
            guard (value.st_mode & S_IFMT) == S_IFDIR else {
                throw YagartoError.unsafeBuildArtifact(candidate.path)
            }
            do {
                try FileManager.default.removeItem(at: candidate)
            } catch {
                throw YagartoError.cannotWriteOutput(
                    candidate.path,
                    error.localizedDescription
                )
            }
        }
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

    private static func createPrivateDirectory(
        _ directory: URL,
        errorPath: String,
        recordOwnership: (stat) -> Void
    ) throws {
        let result = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.mkdir(path, S_IRWXU)
        }
        guard result == 0 else {
            throw YagartoError.atomicDirectorySwapUnsupported(
                errorPath,
                String(cString: strerror(errno))
            )
        }
        guard let created = try metadata(at: directory) else {
            throw YagartoError.atomicDirectorySwapUnsupported(
                errorPath,
                "无法读取刚创建的探测目录。"
            )
        }
        recordOwnership(created)
        guard (created.st_mode & S_IFMT) == S_IFDIR,
              (created.st_mode & 0o777) == S_IRWXU else {
            throw YagartoError.atomicDirectorySwapUnsupported(
                errorPath,
                "探测目录不是权限为 0700 的普通目录。"
            )
        }
    }

    private static func isStrictStaleBuildDirectoryName(
        _ name: String,
        profile: ProfileID
    ) -> Bool {
        for kind in ["staging", "old", "swap-probe"] {
            let prefix = ".\(profile.rawValue)-\(kind)-"
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard suffix == suffix.lowercased(),
                  let identifier = UUID(uuidString: suffix),
                  identifier.uuidString.lowercased() == suffix else {
                return false
            }
            return true
        }
        return false
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

    private struct DirectoryIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
        }
    }
}
