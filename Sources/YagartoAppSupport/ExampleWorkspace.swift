// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public enum ExampleWorkspaceError: Error, Equatable, LocalizedError, Sendable {
    case bundledExampleMissing(String)
    case invalidDestinationName(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledExampleMissing(let path):
            return "应用内示例不完整，请重新构建应用：\(path)"
        case .invalidDestinationName(let name):
            return "示例工作区名称无效：\(name)"
        case .installFailed(let message):
            return "无法准备可写示例工作区：\(message)"
        }
    }
}

public actor ExampleWorkspaceInstaller {
    private let bundledProject: URL
    private let applicationSupportDirectory: URL
    private let destinationName: String

    public init(
        bundledProject: URL,
        applicationSupportDirectory: URL,
        destinationName: String
    ) {
        self.bundledProject = bundledProject.standardizedFileURL
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.destinationName = destinationName
    }

    public func install() throws -> URL {
        try validateDestinationName()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: bundledProject.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              manager.fileExists(atPath: bundledProject.appendingPathComponent("yagarto.json").path) else {
            throw ExampleWorkspaceError.bundledExampleMissing(bundledProject.path)
        }
        let configuration: ProjectConfiguration
        do {
            configuration = try ConfigStore(projectDirectory: bundledProject).load()
        } catch {
            throw ExampleWorkspaceError.bundledExampleMissing(bundledProject.path)
        }
        guard !configuration.sources.isEmpty else {
            throw ExampleWorkspaceError.bundledExampleMissing(bundledProject.path)
        }
        for source in configuration.sources where !manager.fileExists(
            atPath: bundledProject.appendingPathComponent(source).path
        ) {
            throw ExampleWorkspaceError.bundledExampleMissing(bundledProject.path)
        }

        let destination = applicationSupportDirectory
            .appendingPathComponent(destinationName, isDirectory: true)
            .standardizedFileURL
        if manager.fileExists(atPath: destination.path) {
            return destination
        }

        do {
            try manager.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            let staging = applicationSupportDirectory.appendingPathComponent(
                ".\(destinationName)-install-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: bundledProject, to: staging)
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch where manager.fileExists(atPath: destination.path) {
                // Another launch won the race. Its writable copy is authoritative.
            }
            return destination
        } catch {
            throw ExampleWorkspaceError.installFailed(error.localizedDescription)
        }
    }

    private func validateDestinationName() throws {
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/"),
              !destinationName.contains("\0") else {
            throw ExampleWorkspaceError.invalidDestinationName(destinationName)
        }
    }
}

@MainActor
public final class OwnedTemporaryWorkspace {
    private static let markerName = ".yagarto-owned-workspace"

    public let directory: URL
    private let expectedParent: URL
    private let ownershipToken: String
    private var didClean = false

    private init(directory: URL, expectedParent: URL, ownershipToken: String) {
        self.directory = directory.standardizedFileURL
        self.expectedParent = expectedParent.standardizedFileURL
        self.ownershipToken = ownershipToken
    }

    public static func create(
        in parent: URL = FileManager.default.temporaryDirectory,
        prefix: String
    ) throws -> OwnedTemporaryWorkspace {
        guard !prefix.isEmpty,
              !prefix.contains("/"),
              !prefix.contains("\0") else {
            throw ExampleWorkspaceError.invalidDestinationName(prefix)
        }
        let manager = FileManager.default
        let parent = parent.standardizedFileURL
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let directory = parent.appendingPathComponent("\(prefix)-\(token)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try Data(token.utf8).write(
                to: directory.appendingPathComponent(markerName),
                options: [.atomic]
            )
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        return OwnedTemporaryWorkspace(
            directory: directory,
            expectedParent: parent,
            ownershipToken: token
        )
    }

    @discardableResult
    public func cleanup() throws -> Bool {
        guard !didClean else { return false }
        let removed = try Self.cleanup(
            directory: directory,
            expectedParent: expectedParent,
            ownershipToken: ownershipToken
        )
        if removed { didClean = true }
        return removed
    }

    static func cleanup(
        directory: URL,
        expectedParent: URL,
        ownershipToken: String
    ) throws -> Bool {
        let directory = directory.standardizedFileURL
        let parent = expectedParent.standardizedFileURL
        guard directory.deletingLastPathComponent() == parent else { return false }

        var directoryStatus = Darwin.stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return false
        }
        let marker = directory.appendingPathComponent(markerName)
        var markerStatus = Darwin.stat()
        guard lstat(marker.path, &markerStatus) == 0,
              markerStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              markerStatus.st_nlink == 1,
              let markerData = try? Data(contentsOf: marker),
              String(data: markerData, encoding: .utf8) == ownershipToken else {
            return false
        }
        try FileManager.default.removeItem(at: directory)
        return true
    }
}
