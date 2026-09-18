// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    public let canonicalPath: String
    public let lastOpenedAt: Date

    public var id: String { canonicalPath }
    public var projectURL: URL {
        URL(fileURLWithPath: canonicalPath, isDirectory: true).standardizedFileURL
    }
    public var displayName: String { projectURL.lastPathComponent }

    public init(projectURL: URL, lastOpenedAt: Date = Date()) {
        canonicalPath = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        self.lastOpenedAt = lastOpenedAt
    }
}

public protocol RecentProjectStoring: Sendable {
    func projects() async -> [RecentProject]
    @discardableResult
    func record(_ projectURL: URL) async -> [RecentProject]
    @discardableResult
    func remove(_ projectURL: URL) async -> [RecentProject]
    func clear() async
}

public actor UserDefaultsRecentProjectStore: RecentProjectStoring {
    public static let defaultKey = "recentYagartoProjects"
    public static let maximumCount = 10

    private let defaults: UserDefaults
    private let key: String
    private let now: @Sendable () -> Date

    public init(
        suiteName: String? = nil,
        key: String = UserDefaultsRecentProjectStore.defaultKey,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            self.defaults = defaults
        } else {
            defaults = .standard
        }
        self.key = key
        self.now = now
    }

    public func projects() -> [RecentProject] {
        let loaded = load()
        let valid = loaded.filter { project in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: project.canonicalPath,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        if valid != loaded { persist(valid) }
        return valid
    }

    @discardableResult
    public func record(_ projectURL: URL) -> [RecentProject] {
        let newProject = RecentProject(projectURL: projectURL, lastOpenedAt: now())
        var updated = load().filter { $0.canonicalPath != newProject.canonicalPath }
        updated.insert(newProject, at: 0)
        if updated.count > Self.maximumCount {
            updated.removeLast(updated.count - Self.maximumCount)
        }
        persist(updated)
        return updated
    }

    @discardableResult
    public func remove(_ projectURL: URL) -> [RecentProject] {
        let path = RecentProject(projectURL: projectURL).canonicalPath
        let updated = load().filter { $0.canonicalPath != path }
        persist(updated)
        return updated
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private func load() -> [RecentProject] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist(_ projects: [RecentProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: key)
    }
}
