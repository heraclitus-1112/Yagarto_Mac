// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import YagartoCore

public struct CreateProjectSourceRequest: Equatable, Sendable {
    public let directoryRelativePath: String?
    public let filename: String

    public init(directoryRelativePath: String?, filename: String) {
        self.directoryRelativePath = directoryRelativePath
        self.filename = filename
    }
}

public struct CopyProjectSourcesRequest: Equatable, Sendable {
    public let sourceURLs: [URL]
    public let destinationDirectoryRelativePath: String?

    public init(sourceURLs: [URL], destinationDirectoryRelativePath: String?) {
        self.sourceURLs = sourceURLs
        self.destinationDirectoryRelativePath = destinationDirectoryRelativePath
    }
}

public struct RenameProjectSourceRequest: Equatable, Sendable {
    public let relativePath: String
    public let newFilename: String

    public init(relativePath: String, newFilename: String) {
        self.relativePath = relativePath
        self.newFilename = newFilename
    }
}

public enum DirtySourceTrashPolicy: Equatable, Sendable {
    case saveLatest
    case discardChanges
}

public struct TrashProjectSourceRequest: Equatable, Sendable {
    public let relativePath: String
    public let dirtyPolicy: DirtySourceTrashPolicy

    public init(relativePath: String, dirtyPolicy: DirtySourceTrashPolicy) {
        self.relativePath = relativePath
        self.dirtyPolicy = dirtyPolicy
    }
}

public struct ProjectSourceMutationResult: Equatable, Sendable {
    public let document: WorkspaceDocument
    public let addedRelativePaths: [String]
    public let renamedRelativePaths: [String: String]
    public let removedRelativePath: String?

    public init(
        document: WorkspaceDocument,
        addedRelativePaths: [String] = [],
        renamedRelativePaths: [String: String] = [:],
        removedRelativePath: String? = nil
    ) {
        self.document = document
        self.addedRelativePaths = addedRelativePaths
        self.renamedRelativePaths = renamedRelativePaths
        self.removedRelativePath = removedRelativePath
    }
}

public enum ProjectSourceMutationError: Error, Equatable, LocalizedError, Sendable {
    case invalidFilename(String)
    case invalidDirectory(String)
    case sourceMissing(String)
    case unsafeSymbolicLink(String)
    case unsafeHardLink(String)
    case invalidUTF8(String)
    case fileTooLarge(actual: Int, limit: Int)
    case cannotTrashLastSource
    case trashFailed(
        sourcePath: String,
        configurationRestored: Bool,
        latestTextSaved: Bool,
        detail: String
    )
    case fileIO(String)
    case rollbackFailed(operation: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFilename(let name):
            return "源码名称无效：\(name)。请输入不含路径分隔符的 .s 或 .S 文件名。"
        case .invalidDirectory(let path):
            return "目标目录不在当前工程内或不是安全目录：\(path)"
        case .sourceMissing(let path):
            return "找不到工程源码：\(path)"
        case .unsafeSymbolicLink(let path):
            return "为避免跟随危险链接，拒绝操作符号链接：\(path)"
        case .unsafeHardLink(let path):
            return "为避免修改其他文件，拒绝操作硬链接：\(path)"
        case .invalidUTF8(let path):
            return "源码不是有效的 UTF-8 文本：\(path)"
        case .fileTooLarge(let actual, let limit):
            return "源码文件过大（\(actual) 字节，上限 \(limit) 字节）。"
        case .cannotTrashLastSource:
            return "工程必须至少保留一个源码，不能将最后一个源码移到废纸篓。"
        case .trashFailed(
            let sourcePath,
            let configurationRestored,
            let latestTextSaved,
            let detail
        ):
            let configurationState = configurationRestored
                ? "工程配置已恢复。" : "工程配置未能恢复。"
            let savedState = latestTextSaved
                ? "最新编辑内容已写入该文件。" : "磁盘文件保持上次保存版本。"
            return "无法将源码移到废纸篓：\(detail) \(configurationState) 文件仍位于 \(sourcePath)。\(savedState)"
        case .fileIO(let detail):
            return "工程文件操作失败：\(detail)"
        case .rollbackFailed(let operation, let recovery):
            return "\(operation)失败，且无法完整恢复：\(recovery)"
        }
    }
}

public protocol ProjectSourceManaging: Sendable {
    func createSource(
        _ request: CreateProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult

    func copySources(
        _ request: CopyProjectSourcesRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult

    func renameSource(
        _ request: RenameProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult

    func trashSource(
        _ request: TrashProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult
}

public struct LocalProjectSourceManager: ProjectSourceManaging, Sendable {
    public static let defaultMaximumFileBytes = 4 * 1_024 * 1_024

    typealias TrashHandler = @Sendable (URL) throws -> URL?
    typealias ConfigurationSaveHook = @Sendable () throws -> Void

    private let maximumFileBytes: Int
    private let trashHandler: TrashHandler
    private let beforeConfigurationSave: ConfigurationSaveHook

    public init(maximumFileBytes: Int = Self.defaultMaximumFileBytes) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        trashHandler = { source in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        }
        beforeConfigurationSave = {}
    }

    init(
        maximumFileBytes: Int = Self.defaultMaximumFileBytes,
        testingTrashHandler: @escaping TrashHandler,
        testingBeforeConfigurationSave: @escaping ConfigurationSaveHook = {}
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        trashHandler = testingTrashHandler
        beforeConfigurationSave = testingBeforeConfigurationSave
    }

    public func createSource(
        _ request: CreateProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        let directory = try destinationDirectory(
            request.directoryRelativePath,
            in: document.projectDirectory
        )
        let filename = try normalizedFilename(request.filename)
        let destination = directory.url.appendingPathComponent(filename).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectSourceMutationError.invalidFilename(filename)
        }
        let relativePath = joined(directory.relativePath, filename)
        guard !document.configuration.sources.contains(relativePath) else {
            throw ProjectSourceMutationError.invalidFilename(filename)
        }

        return try withProjectLock(document.projectDirectory) { lock in
            let staging = try makeStagingDirectory(in: document.projectDirectory)
            defer { try? FileManager.default.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(filename)
            try Data().write(to: staged, options: .atomic)
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
                var configuration = document.configuration
                configuration.sources.append(relativePath)
                try beforeConfigurationSave()
                try ConfigStore(projectDirectory: document.projectDirectory)
                    .save(configuration, holding: lock)

                var buffers = document.sourceBuffers
                buffers.append(WorkspaceSourceBuffer(
                    relativePath: relativePath,
                    sourceURL: destination,
                    loadedText: "",
                    savedText: ""
                ))
                return ProjectSourceMutationResult(
                    document: document.replacingPersistedStructure(
                        configuration: configuration,
                        sourceBuffers: buffers,
                        activeSourceRelativePath: relativePath
                    ),
                    addedRelativePaths: [relativePath]
                )
            } catch {
                let originalError = error
                let rollbackFailures = rollbackCreatedFiles([destination])
                if !rollbackFailures.isEmpty {
                    throw ProjectSourceMutationError.rollbackFailed(
                        operation: "新建源码",
                        recovery: "\(rollbackFailures.joined(separator: "；"))。原始错误：\(originalError.localizedDescription)"
                    )
                }
                throw map(originalError)
            }
        }
    }

    public func copySources(
        _ request: CopyProjectSourcesRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        guard !request.sourceURLs.isEmpty else {
            return ProjectSourceMutationResult(document: document)
        }
        let directory = try destinationDirectory(
            request.destinationDirectoryRelativePath,
            in: document.projectDirectory
        )
        var reserved = Set(document.configuration.sources.map { $0.lowercased() })
        var prepared: [(data: Data, text: String, relativePath: String, destination: URL)] = []
        for source in request.sourceURLs {
            let source = source.standardizedFileURL
            try validateSafeRegularFile(source)
            let data = try readSourceData(source)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProjectSourceMutationError.invalidUTF8(source.path)
            }
            let originalName = try normalizedFilename(source.lastPathComponent)
            let name = uniqueFilename(
                originalName,
                in: directory,
                reservedRelativePaths: &reserved
            )
            let relativePath = joined(directory.relativePath, name)
            prepared.append((
                data: data,
                text: text,
                relativePath: relativePath,
                destination: directory.url.appendingPathComponent(name).standardizedFileURL
            ))
        }

        return try withProjectLock(document.projectDirectory) { lock in
            let staging = try makeStagingDirectory(in: document.projectDirectory)
            defer { try? FileManager.default.removeItem(at: staging) }
            var published: [URL] = []
            do {
                for (index, item) in prepared.enumerated() {
                    let staged = staging.appendingPathComponent("source-\(index)")
                    try item.data.write(to: staged, options: .atomic)
                    try FileManager.default.moveItem(at: staged, to: item.destination)
                    published.append(item.destination)
                }
                var configuration = document.configuration
                configuration.sources.append(contentsOf: prepared.map(\.relativePath))
                try beforeConfigurationSave()
                try ConfigStore(projectDirectory: document.projectDirectory)
                    .save(configuration, holding: lock)

                var buffers = document.sourceBuffers
                for (index, item) in prepared.enumerated() {
                    var buffer = WorkspaceSourceBuffer(
                        relativePath: item.relativePath,
                        sourceURL: item.destination
                    )
                    if index == 0 { buffer = buffer.loading(item.text) }
                    buffers.append(buffer)
                }
                let active = prepared[0].relativePath
                return ProjectSourceMutationResult(
                    document: document.replacingPersistedStructure(
                        configuration: configuration,
                        sourceBuffers: buffers,
                        activeSourceRelativePath: active
                    ),
                    addedRelativePaths: prepared.map(\.relativePath)
                )
            } catch {
                let originalError = error
                let rollbackFailures = rollbackCreatedFiles(published.reversed())
                if !rollbackFailures.isEmpty {
                    throw ProjectSourceMutationError.rollbackFailed(
                        operation: "复制源码",
                        recovery: "\(rollbackFailures.joined(separator: "；"))。原始错误：\(originalError.localizedDescription)"
                    )
                }
                throw map(originalError)
            }
        }
    }

    public func renameSource(
        _ request: RenameProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        guard let index = document.sourceBuffers.firstIndex(where: {
            $0.relativePath == request.relativePath
        }) else {
            throw ProjectSourceMutationError.sourceMissing(request.relativePath)
        }
        let oldBuffer = document.sourceBuffers[index]
        try validateSafeRegularFile(oldBuffer.sourceURL)
        let filename = try normalizedFilename(request.newFilename)
        let parentRelativePath = parentPath(of: request.relativePath)
        let directory = try destinationDirectory(parentRelativePath, in: document.projectDirectory)
        let newRelativePath = joined(parentRelativePath ?? "", filename)
        let destination = directory.url.appendingPathComponent(filename).standardizedFileURL
        if newRelativePath == request.relativePath {
            return ProjectSourceMutationResult(document: document)
        }
        guard !FileManager.default.fileExists(atPath: destination.path),
              !document.configuration.sources.contains(where: {
                  $0.caseInsensitiveCompare(newRelativePath) == .orderedSame
              }) else {
            throw ProjectSourceMutationError.invalidFilename(filename)
        }

        return try withProjectLock(document.projectDirectory) { lock in
            do {
                try FileManager.default.moveItem(at: oldBuffer.sourceURL, to: destination)
                var configuration = document.configuration
                configuration.sources[index] = newRelativePath
                do {
                    try beforeConfigurationSave()
                    try ConfigStore(projectDirectory: document.projectDirectory)
                        .save(configuration, holding: lock)
                } catch {
                    do {
                        try FileManager.default.moveItem(at: destination, to: oldBuffer.sourceURL)
                    } catch let rollbackError {
                        throw ProjectSourceMutationError.rollbackFailed(
                            operation: "重命名源码",
                            recovery: rollbackError.localizedDescription
                        )
                    }
                    throw error
                }

                var buffers = document.sourceBuffers
                buffers[index] = oldBuffer.relocating(
                    relativePath: newRelativePath,
                    sourceURL: destination
                )
                let active = document.activeSourceRelativePath == request.relativePath
                    ? newRelativePath : document.activeSourceRelativePath
                return ProjectSourceMutationResult(
                    document: document.replacingPersistedStructure(
                        configuration: configuration,
                        sourceBuffers: buffers,
                        activeSourceRelativePath: active
                    ),
                    renamedRelativePaths: [request.relativePath: newRelativePath]
                )
            } catch let error as ProjectSourceMutationError {
                throw error
            } catch {
                throw map(error)
            }
        }
    }

    public func trashSource(
        _ request: TrashProjectSourceRequest,
        in document: WorkspaceDocument
    ) async throws -> ProjectSourceMutationResult {
        guard document.sourceBuffers.count > 1 else {
            throw ProjectSourceMutationError.cannotTrashLastSource
        }
        guard let index = document.sourceBuffers.firstIndex(where: {
            $0.relativePath == request.relativePath
        }) else {
            throw ProjectSourceMutationError.sourceMissing(request.relativePath)
        }
        let buffer = document.sourceBuffers[index]
        try validateSafeRegularFile(buffer.sourceURL)
        let savedLatestText = request.dirtyPolicy == .saveLatest && buffer.isDirty
        var replacementText: String?
        if document.activeSourceRelativePath == request.relativePath {
            let replacementIndex = index + 1 < document.sourceBuffers.count ? index + 1 : index - 1
            let replacement = document.sourceBuffers[replacementIndex]
            if !replacement.isLoaded {
                try validateSafeRegularFile(replacement.sourceURL)
                let data = try readSourceData(replacement.sourceURL)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ProjectSourceMutationError.invalidUTF8(replacement.sourceURL.path)
                }
                replacementText = text
            }
        }

        return try withProjectLock(document.projectDirectory) { lock in
            if request.dirtyPolicy == .saveLatest, buffer.isDirty, let text = buffer.loadedText {
                let data = Data(text.utf8)
                guard data.count <= maximumFileBytes else {
                    throw ProjectSourceMutationError.fileTooLarge(
                        actual: data.count,
                        limit: maximumFileBytes
                    )
                }
                do {
                    try data.write(to: buffer.sourceURL, options: .atomic)
                } catch {
                    throw map(error)
                }
            }

            var configuration = document.configuration
            configuration.sources.remove(at: index)
            let store = ConfigStore(projectDirectory: document.projectDirectory)
            do {
                try beforeConfigurationSave()
                try store.save(configuration, holding: lock)
                do {
                    _ = try trashHandler(buffer.sourceURL)
                } catch {
                    let trashError = error
                    do {
                        try store.save(document.configuration, holding: lock)
                    } catch let rollbackError {
                        throw ProjectSourceMutationError.rollbackFailed(
                            operation: "移到废纸篓",
                            recovery: "配置未能恢复；文件仍位于 \(buffer.sourceURL.path)：\(rollbackError.localizedDescription)"
                        )
                    }
                    throw ProjectSourceMutationError.trashFailed(
                        sourcePath: buffer.sourceURL.path,
                        configurationRestored: true,
                        latestTextSaved: savedLatestText,
                        detail: trashError.localizedDescription
                    )
                }
            } catch let error as ProjectSourceMutationError {
                throw error
            } catch {
                throw map(error)
            }

            var buffers = document.sourceBuffers
            buffers.remove(at: index)
            let active: String
            if document.activeSourceRelativePath == request.relativePath {
                let replacementIndex = min(index, buffers.count - 1)
                if let replacementText, !buffers[replacementIndex].isLoaded {
                    buffers[replacementIndex] = buffers[replacementIndex].loading(replacementText)
                }
                active = buffers[replacementIndex].relativePath
            } else {
                active = document.activeSourceRelativePath
            }
            return ProjectSourceMutationResult(
                document: document.replacingPersistedStructure(
                    configuration: configuration,
                    sourceBuffers: buffers,
                    activeSourceRelativePath: active
                ),
                removedRelativePath: request.relativePath
            )
        }
    }

    private func withProjectLock<T>(
        _ projectDirectory: URL,
        operation: (ProjectDirectoryMutationLock) throws -> T
    ) throws -> T {
        let lock: ProjectDirectoryMutationLock
        do {
            lock = try ProjectDirectoryMutationLock.acquire(projectDirectory)
        } catch {
            throw map(error)
        }
        defer { lock.release() }
        return try operation(lock)
    }

    private func destinationDirectory(
        _ relativePath: String?,
        in projectDirectory: URL
    ) throws -> (relativePath: String, url: URL) {
        let normalized = (relativePath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
            throw ProjectSourceMutationError.invalidDirectory(relativePath ?? "")
        }
        let project = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = normalized.isEmpty
            ? projectDirectory.standardizedFileURL
            : projectDirectory.appendingPathComponent(normalized, isDirectory: true).standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved == project || resolved.path.hasPrefix(project.path + "/") else {
            throw ProjectSourceMutationError.invalidDirectory(relativePath ?? "")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectSourceMutationError.invalidDirectory(relativePath ?? "")
        }
        try validateDirectoryComponents(normalized, in: projectDirectory)
        return (normalized, directory)
    }

    private func validateDirectoryComponents(_ relativePath: String, in project: URL) throws {
        guard !relativePath.isEmpty else { return }
        var candidate = project.standardizedFileURL
        for component in relativePath.split(separator: "/") {
            candidate.appendPathComponent(String(component), isDirectory: true)
            var status = Darwin.stat()
            guard lstat(candidate.path, &status) == 0 else {
                throw ProjectSourceMutationError.invalidDirectory(relativePath)
            }
            guard status.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw ProjectSourceMutationError.unsafeSymbolicLink(candidate.path)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw ProjectSourceMutationError.invalidDirectory(relativePath)
            }
        }
    }

    private func normalizedFilename(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0") else {
            throw ProjectSourceMutationError.invalidFilename(rawName)
        }
        let name: String
        if URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            name = trimmed + ".s"
        } else {
            name = trimmed
        }
        let suffix = URL(fileURLWithPath: name).pathExtension
        guard suffix == "s" || suffix == "S",
              !URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.isEmpty else {
            throw ProjectSourceMutationError.invalidFilename(rawName)
        }
        return name
    }

    private func uniqueFilename(
        _ original: String,
        in directory: (relativePath: String, url: URL),
        reservedRelativePaths: inout Set<String>
    ) -> String {
        let url = URL(fileURLWithPath: original)
        let base = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension
        var candidate = original
        var counter = 2
        while FileManager.default.fileExists(
            atPath: directory.url.appendingPathComponent(candidate).path
        ) || reservedRelativePaths.contains(joined(directory.relativePath, candidate).lowercased()) {
            candidate = "\(base)-\(counter).\(suffix)"
            counter += 1
        }
        reservedRelativePaths.insert(joined(directory.relativePath, candidate).lowercased())
        return candidate
    }

    private func validateSafeRegularFile(_ url: URL) throws {
        var status = Darwin.stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw ProjectSourceMutationError.sourceMissing(url.path) }
            throw ProjectSourceMutationError.fileIO(String(cString: strerror(errno)))
        }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard kind != mode_t(S_IFLNK) else {
            throw ProjectSourceMutationError.unsafeSymbolicLink(url.path)
        }
        guard kind == mode_t(S_IFREG) else {
            throw ProjectSourceMutationError.invalidFilename(url.lastPathComponent)
        }
        guard status.st_nlink == 1 else {
            throw ProjectSourceMutationError.unsafeHardLink(url.path)
        }
        let suffix = url.pathExtension
        guard suffix == "s" || suffix == "S" else {
            throw ProjectSourceMutationError.invalidFilename(url.lastPathComponent)
        }
    }

    private func readSourceData(_ url: URL) throws -> Data {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumFileBytes else {
                throw ProjectSourceMutationError.fileTooLarge(
                    actual: data.count,
                    limit: maximumFileBytes
                )
            }
            return data
        } catch let error as ProjectSourceMutationError {
            throw error
        } catch {
            throw map(error)
        }
    }

    private func makeStagingDirectory(in project: URL) throws -> URL {
        let staging = project.appendingPathComponent(
            ".yagarto-source-mutation-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        } catch {
            throw map(error)
        }
    }

    private func rollbackCreatedFiles<S: Sequence>(_ urls: S) -> [String] where S.Element == URL {
        var failures: [String] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("残留文件 \(url.path)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    private func joined(_ directory: String, _ filename: String) -> String {
        directory.isEmpty ? filename : "\(directory)/\(filename)"
    }

    private func parentPath(of relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }

    private func map(_ error: Error) -> ProjectSourceMutationError {
        if let error = error as? ProjectSourceMutationError { return error }
        return .fileIO(error.localizedDescription)
    }
}
