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

public struct WorkspaceDocument: Equatable, Sendable {
    public let projectDirectory: URL
    public let sourceURL: URL
    public let configuration: ProjectConfiguration
    public private(set) var text: String
    public private(set) var isDirty: Bool
    private let savedText: String
    private let savedConfiguration: ProjectConfiguration

    public init(
        projectDirectory: URL,
        sourceURL: URL,
        configuration: ProjectConfiguration,
        text: String,
        isDirty: Bool = false,
        savedText: String? = nil,
        savedConfiguration: ProjectConfiguration? = nil
    ) {
        self.projectDirectory = projectDirectory.standardizedFileURL
        self.sourceURL = sourceURL.standardizedFileURL
        self.configuration = configuration
        self.text = text
        self.savedText = savedText ?? text
        self.savedConfiguration = savedConfiguration ?? configuration
        self.isDirty = isDirty
    }

    public func editing(_ newText: String) -> WorkspaceDocument {
        WorkspaceDocument(
            projectDirectory: projectDirectory,
            sourceURL: sourceURL,
            configuration: configuration,
            text: newText,
            isDirty: newText != savedText || configuration != savedConfiguration,
            savedText: savedText,
            savedConfiguration: savedConfiguration
        )
    }

    public func changingProfile(to profile: ProfileID) -> WorkspaceDocument {
        var updated = configuration
        updated.profile = profile
        return WorkspaceDocument(
            projectDirectory: projectDirectory,
            sourceURL: sourceURL,
            configuration: updated,
            text: text,
            isDirty: text != savedText || updated != savedConfiguration,
            savedText: savedText,
            savedConfiguration: savedConfiguration
        )
    }

    func markingSaved() -> WorkspaceDocument {
        WorkspaceDocument(
            projectDirectory: projectDirectory,
            sourceURL: sourceURL,
            configuration: configuration,
            text: text,
            isDirty: false,
            savedText: text,
            savedConfiguration: configuration
        )
    }
}

public protocol DocumentServicing: Sendable {
    func open(_ url: URL) async throws -> WorkspaceDocument
    func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument
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
        let sourceURL: URL
        let configuration: ProjectConfiguration
        if isDirectory.boolValue {
            projectDirectory = requestedURL
            configuration = try ConfigStore(projectDirectory: projectDirectory).load()
            guard let firstSource = configuration.sources.first else {
                throw DocumentServiceError.sourceMissing(projectDirectory.path)
            }
            sourceURL = projectDirectory.appendingPathComponent(firstSource).standardizedFileURL
        } else {
            try Self.requireAssemblyExtension(requestedURL)
            projectDirectory = requestedURL.deletingLastPathComponent().standardizedFileURL
            configuration = try ConfigStore(projectDirectory: projectDirectory).load()
            sourceURL = requestedURL
        }

        try Self.requireAssemblyExtension(sourceURL)
        try Self.requireContained(sourceURL, in: projectDirectory)
        try validateSafeRegularFile(sourceURL)
        let size = try fileSize(sourceURL)
        guard size <= maximumFileBytes else {
            throw DocumentServiceError.fileTooLarge(actual: size, limit: maximumFileBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw DocumentServiceError.fileIO(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentServiceError.invalidUTF8(sourceURL.path)
        }
        return WorkspaceDocument(
            projectDirectory: projectDirectory,
            sourceURL: sourceURL,
            configuration: configuration,
            text: text
        )
    }

    public func save(_ document: WorkspaceDocument) async throws -> WorkspaceDocument {
        try validateSafeRegularFile(document.sourceURL)
        let configurationURL = ConfigStore(projectDirectory: document.projectDirectory).configurationURL
        try validateSafeRegularFile(configurationURL)
        let data = Data(document.text.utf8)
        guard data.count <= maximumFileBytes else {
            throw DocumentServiceError.fileTooLarge(actual: data.count, limit: maximumFileBytes)
        }
        do {
            try data.write(to: document.sourceURL, options: [.atomic])
            try ConfigStore(projectDirectory: document.projectDirectory).save(document.configuration)
        } catch {
            throw DocumentServiceError.fileIO(error.localizedDescription)
        }
        return document.markingSaved()
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

    private func fileSize(_ url: URL) throws -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw DocumentServiceError.fileIO(error.localizedDescription)
        }
    }
}
