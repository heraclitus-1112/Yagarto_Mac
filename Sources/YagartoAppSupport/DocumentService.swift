// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public enum DocumentServiceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSource(String)
    case sourceMissing(String)
    case fileTooLarge(actual: Int, limit: Int)
    case invalidUTF8(String)
    case unsafeSymbolicLink(String)
    case unsafeHardLink(String)
    case fileIO(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource(let path):
            return "只能打开 .s、.S 文件或包含 yagarto.json 的工程目录：\(path)"
        case .sourceMissing(let path):
            return "找不到工程源码：\(path)"
        case .fileTooLarge(let actual, let limit):
            return "源码文件过大（\(actual) 字节，上限 \(limit) 字节）。"
        case .invalidUTF8(let path):
            return "源码不是有效的 UTF-8 文本：\(path)"
        case .unsafeSymbolicLink(let path):
            return "为避免跟随危险链接，拒绝打开或保存符号链接：\(path)"
        case .unsafeHardLink(let path):
            return "为避免修改其他文件，拒绝打开或保存硬链接：\(path)"
        case .fileIO(let message):
            return "文件操作失败：\(message)"
        }
    }
}

public struct WorkspaceSourceBuffer: Equatable, Identifiable, Sendable {
    public let relativePath: String
    public let sourceURL: URL
    public private(set) var loadedText: String?
    public private(set) var selection: NSRange?
    private var savedText: String?

    public var id: String { relativePath }
    public var text: String? { loadedText }
    public var isLoaded: Bool { loadedText != nil }
    public var isDirty: Bool {
        guard let loadedText, let savedText else { return false }
        return loadedText != savedText
    }

    fileprivate init(
        relativePath: String,
        sourceURL: URL,
        loadedText: String? = nil,
        savedText: String? = nil,
        selection: NSRange? = nil
    ) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL.standardizedFileURL
        self.loadedText = loadedText
        self.savedText = savedText
        self.selection = selection
    }

    fileprivate func loading(_ text: String) -> WorkspaceSourceBuffer {
        WorkspaceSourceBuffer(
            relativePath: relativePath,
            sourceURL: sourceURL,
            loadedText: text,
            savedText: text,
            selection: selection
        )
    }

    fileprivate func editing(_ text: String) -> WorkspaceSourceBuffer {
        WorkspaceSourceBuffer(
            relativePath: relativePath,
            sourceURL: sourceURL,
            loadedText: text,
            savedText: savedText,
            selection: selection
        )
    }

    fileprivate func updatingSelection(_ range: NSRange?) -> WorkspaceSourceBuffer {
        WorkspaceSourceBuffer(
            relativePath: relativePath,
            sourceURL: sourceURL,
            loadedText: loadedText,
            savedText: savedText,
            selection: range
        )
    }

    fileprivate func acknowledgingSavedText(_ text: String) -> WorkspaceSourceBuffer {
        WorkspaceSourceBuffer(
            relativePath: relativePath,
            sourceURL: sourceURL,
            loadedText: loadedText,
            savedText: text,
            selection: selection
        )
    }
}

public struct WorkspaceDocument: Equatable, Sendable {
    public let projectDirectory: URL
    public private(set) var configuration: ProjectConfiguration
    public private(set) var sourceBuffers: [WorkspaceSourceBuffer]
    public private(set) var activeSourceRelativePath: String
    private var savedConfiguration: ProjectConfiguration

    public var sourceURL: URL { activeSource.sourceURL }
    public var text: String { activeSource.loadedText ?? "" }
    public var isDirty: Bool {
        configuration != savedConfiguration || sourceBuffers.contains(where: \.isDirty)
    }
    public var activeSelection: NSRange? { activeSource.selection }

    private var activeSourceIndex: Int {
        sourceBuffers.firstIndex { $0.relativePath == activeSourceRelativePath } ?? 0
    }

    private var activeSource: WorkspaceSourceBuffer {
        sourceBuffers[activeSourceIndex]
    }

    public init(
        projectDirectory: URL,
        sourceURL: URL,
        configuration: ProjectConfiguration,
        text: String,
        isDirty: Bool = false,
        savedText: String? = nil,
        savedConfiguration: ProjectConfiguration? = nil
    ) {
        let standardizedProject = projectDirectory.standardizedFileURL
        let standardizedSource = sourceURL.standardizedFileURL
        var buffers = configuration.sources.map { relativePath in
            WorkspaceSourceBuffer(
                relativePath: relativePath,
                sourceURL: standardizedProject.appendingPathComponent(relativePath)
            )
        }
        let activeIndex = buffers.firstIndex {
            $0.sourceURL.standardizedFileURL == standardizedSource
        }
        let activeRelativePath: String
        if let activeIndex {
            activeRelativePath = buffers[activeIndex].relativePath
        } else {
            activeRelativePath = standardizedSource.lastPathComponent
            buffers.append(WorkspaceSourceBuffer(
                relativePath: activeRelativePath,
                sourceURL: standardizedSource
            ))
        }
        let loadedIndex = buffers.firstIndex { $0.relativePath == activeRelativePath } ?? 0
        let baseline = savedText ?? (isDirty ? "" : text)
        buffers[loadedIndex] = WorkspaceSourceBuffer(
            relativePath: activeRelativePath,
            sourceURL: standardizedSource,
            loadedText: text,
            savedText: baseline
        )

        self.projectDirectory = standardizedProject
        self.configuration = configuration
        self.sourceBuffers = buffers
        self.activeSourceRelativePath = activeRelativePath
        self.savedConfiguration = savedConfiguration ?? configuration
    }

    fileprivate init(
        projectDirectory: URL,
        configuration: ProjectConfiguration,
        sourceBuffers: [WorkspaceSourceBuffer],
        activeSourceRelativePath: String,
        savedConfiguration: ProjectConfiguration
    ) {
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.configuration = configuration
        self.sourceBuffers = sourceBuffers
        self.activeSourceRelativePath = activeSourceRelativePath
        self.savedConfiguration = savedConfiguration
    }

    public func editing(_ newText: String) -> WorkspaceDocument {
        var copy = self
        copy.sourceBuffers[activeSourceIndex] = activeSource.editing(newText)
        return copy
    }

    public func changingProfile(to profile: ProfileID) -> WorkspaceDocument {
        var copy = self
        copy.configuration.profile = profile
        return copy
    }

    public func updatingActiveSelection(_ range: NSRange?) -> WorkspaceDocument {
        var copy = self
        copy.sourceBuffers[activeSourceIndex] = activeSource.updatingSelection(range)
        return copy
    }

    public func selectingSource(
        _ relativePath: String,
        loadedText: String? = nil
    ) throws -> WorkspaceDocument {
        guard let index = sourceBuffers.firstIndex(where: { $0.relativePath == relativePath }) else {
            throw DocumentServiceError.sourceMissing(relativePath)
        }
        var copy = self
        if let loadedText, !copy.sourceBuffers[index].isLoaded {
            copy.sourceBuffers[index] = copy.sourceBuffers[index].loading(loadedText)
        }
        guard copy.sourceBuffers[index].isLoaded else {
            throw DocumentServiceError.sourceMissing(copy.sourceBuffers[index].sourceURL.path)
        }
        copy.activeSourceRelativePath = relativePath
        return copy
    }

    fileprivate func acknowledgingSourceSave(
        relativePath: String,
        text: String
    ) -> WorkspaceDocument {
        guard let index = sourceBuffers.firstIndex(where: { $0.relativePath == relativePath }) else {
            return self
        }
        var copy = self
        copy.sourceBuffers[index] = copy.sourceBuffers[index].acknowledgingSavedText(text)
        return copy
    }

    fileprivate func acknowledgingConfigurationSave() -> WorkspaceDocument {
        var copy = self
        copy.savedConfiguration = configuration
        return copy
    }

    func markingSaved() -> WorkspaceDocument {
        var copy = self
        for buffer in sourceBuffers where buffer.isLoaded {
            if let text = buffer.loadedText {
                copy = copy.acknowledgingSourceSave(relativePath: buffer.relativePath, text: text)
            }
        }
        return copy.acknowledgingConfigurationSave()
    }

    func acknowledgingSave(of snapshot: WorkspaceDocument) -> WorkspaceDocument {
        guard projectDirectory == snapshot.projectDirectory else { return self }
        var copy = self
        for snapshotBuffer in snapshot.sourceBuffers {
            guard let snapshotText = snapshotBuffer.loadedText else { continue }
            copy = copy.acknowledgingSourceSave(
                relativePath: snapshotBuffer.relativePath,
                text: snapshotText
            )
        }
        copy.savedConfiguration = snapshot.savedConfiguration
        return copy
    }
}

public struct WorkspacePartialSaveError: Error, LocalizedError, Sendable {
    public let document: WorkspaceDocument
    public let failure: DocumentServiceError

    public var errorDescription: String? { failure.errorDescription }
}

public protocol DocumentServicing: Sendable {
    func open(_ url: URL) async throws -> WorkspaceDocument
    func selectSource(_ relativePath: String, in document: WorkspaceDocument) async throws
        -> WorkspaceDocument
    func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument
}

public extension DocumentServicing {
    func selectSource(_ relativePath: String, in document: WorkspaceDocument) async throws
        -> WorkspaceDocument {
        try document.selectingSource(relativePath)
    }
}

public struct LocalDocumentService: DocumentServicing, Sendable {
    public static let defaultMaximumFileBytes = 4 * 1_024 * 1_024

    private let maximumFileBytes: Int

    public init(maximumFileBytes: Int = LocalDocumentService.defaultMaximumFileBytes) {
        self.maximumFileBytes = max(1, maximumFileBytes)
    }

    public func open(_ url: URL) async throws -> WorkspaceDocument {
        let requestedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory) else {
            throw DocumentServiceError.sourceMissing(requestedURL.path)
        }

        let projectDirectory: URL
        let requestedSourceURL: URL?
        let configuration: ProjectConfiguration
        if isDirectory.boolValue {
            projectDirectory = requestedURL
            configuration = try ConfigStore(projectDirectory: projectDirectory).load()
            requestedSourceURL = nil
        } else {
            try Self.requireAssemblyExtension(requestedURL)
            projectDirectory = try findProjectDirectory(containing: requestedURL)
            configuration = try ConfigStore(projectDirectory: projectDirectory).load()
            requestedSourceURL = requestedURL
        }

        var buffers: [WorkspaceSourceBuffer] = []
        for relativePath in configuration.sources {
            let sourceURL = projectDirectory.appendingPathComponent(relativePath).standardizedFileURL
            try Self.requireAssemblyExtension(sourceURL)
            try Self.requireContained(sourceURL, in: projectDirectory)
            try validateSafeRegularFile(sourceURL)
            let size = try fileSize(sourceURL)
            guard size <= maximumFileBytes else {
                throw DocumentServiceError.fileTooLarge(actual: size, limit: maximumFileBytes)
            }
            buffers.append(WorkspaceSourceBuffer(relativePath: relativePath, sourceURL: sourceURL))
        }

        guard !buffers.isEmpty else {
            throw DocumentServiceError.sourceMissing(projectDirectory.path)
        }
        let activeIndex: Int
        if let requestedSourceURL {
            guard let requestedIndex = buffers.firstIndex(where: {
                $0.sourceURL.standardizedFileURL == requestedSourceURL.standardizedFileURL
            }) else {
                throw DocumentServiceError.unsupportedSource(requestedSourceURL.path)
            }
            activeIndex = requestedIndex
        } else {
            activeIndex = 0
        }
        let activeBuffer = buffers[activeIndex]
        buffers[activeIndex] = activeBuffer.loading(try loadText(from: activeBuffer.sourceURL))
        return WorkspaceDocument(
            projectDirectory: projectDirectory,
            configuration: configuration,
            sourceBuffers: buffers,
            activeSourceRelativePath: buffers[activeIndex].relativePath,
            savedConfiguration: configuration
        )
    }

    public func selectSource(
        _ relativePath: String,
        in document: WorkspaceDocument
    ) async throws -> WorkspaceDocument {
        guard let buffer = document.sourceBuffers.first(where: { $0.relativePath == relativePath }) else {
            throw DocumentServiceError.sourceMissing(relativePath)
        }
        if buffer.isLoaded {
            return try document.selectingSource(relativePath)
        }
        try validateSafeRegularFile(buffer.sourceURL)
        let size = try fileSize(buffer.sourceURL)
        guard size <= maximumFileBytes else {
            throw DocumentServiceError.fileTooLarge(actual: size, limit: maximumFileBytes)
        }
        return try document.selectingSource(
            relativePath,
            loadedText: loadText(from: buffer.sourceURL)
        )
    }

    public func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument {
        let configurationURL = ConfigStore(projectDirectory: document.projectDirectory).configurationURL
        try validateSafeRegularFile(configurationURL)
        var saved = document
        var savedAnySource = false
        for buffer in document.sourceBuffers where buffer.isDirty {
            guard let text = buffer.loadedText else { continue }
            do {
                try validateSafeRegularFile(buffer.sourceURL)
                let data = Data(text.utf8)
                guard data.count <= maximumFileBytes else {
                    throw DocumentServiceError.fileTooLarge(actual: data.count, limit: maximumFileBytes)
                }
                try data.write(to: buffer.sourceURL, options: [.atomic])
                saved = saved.acknowledgingSourceSave(
                    relativePath: buffer.relativePath,
                    text: text
                )
                savedAnySource = true
            } catch let error as DocumentServiceError {
                if !savedAnySource { throw error }
                throw WorkspacePartialSaveError(document: saved, failure: error)
            } catch {
                let failure = DocumentServiceError.fileIO(error.localizedDescription)
                if !savedAnySource { throw failure }
                throw WorkspacePartialSaveError(
                    document: saved,
                    failure: failure
                )
            }
        }
        do {
            try ConfigStore(projectDirectory: document.projectDirectory).save(document.configuration)
            return saved.acknowledgingConfigurationSave()
        } catch let error as DocumentServiceError {
            if !savedAnySource { throw error }
            throw WorkspacePartialSaveError(document: saved, failure: error)
        } catch {
            let failure = DocumentServiceError.fileIO(error.localizedDescription)
            if !savedAnySource { throw failure }
            throw WorkspacePartialSaveError(
                document: saved,
                failure: failure
            )
        }
    }

    private static func requireAssemblyExtension(_ url: URL) throws {
        let suffix = url.pathExtension
        guard suffix == "s" || suffix == "S" else {
            throw DocumentServiceError.unsupportedSource(url.path)
        }
    }

    private static func requireContained(_ source: URL, in projectDirectory: URL) throws {
        let project = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let projectPrefix = project.path.hasSuffix("/") ? project.path : project.path + "/"
        guard resolvedSource.path.hasPrefix(projectPrefix) else {
            throw DocumentServiceError.unsafeSymbolicLink(source.path)
        }
    }

    private func validateSafeRegularFile(_ url: URL) throws {
        var status = Darwin.stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw DocumentServiceError.sourceMissing(url.path) }
            throw DocumentServiceError.fileIO(String(cString: strerror(errno)))
        }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard kind != mode_t(S_IFLNK) else {
            throw DocumentServiceError.unsafeSymbolicLink(url.path)
        }
        guard kind == mode_t(S_IFREG) else {
            throw DocumentServiceError.unsupportedSource(url.path)
        }
        guard status.st_nlink == 1 else {
            throw DocumentServiceError.unsafeHardLink(url.path)
        }
    }

    private func findProjectDirectory(containing sourceURL: URL) throws -> URL {
        var candidate = sourceURL.deletingLastPathComponent().standardizedFileURL
        while true {
            let configuration = candidate.appendingPathComponent("yagarto.json")
            if FileManager.default.fileExists(atPath: configuration.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { break }
            candidate = parent
        }
        throw DocumentServiceError.sourceMissing(sourceURL.path)
    }

    private func loadText(from sourceURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw DocumentServiceError.fileIO(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentServiceError.invalidUTF8(sourceURL.path)
        }
        return text
    }

    private func fileSize(_ url: URL) throws -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw DocumentServiceError.fileIO(error.localizedDescription)
        }
    }
}
