// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class RecentProjectsTests: XCTestCase {
    func testRecordCanonicalizesDeduplicatesAndKeepsTenNewestProjects() async throws {
        let suite = "RecentProjectsTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRecentProjectStore(suiteName: suite, key: "projects")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var directories: [URL] = []
        for index in 0..<12 {
            let directory = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            directories.append(directory)
            _ = await store.record(directory)
        }
        _ = await store.record(directories[5].appendingPathComponent(".", isDirectory: true))

        let projects = await store.projects()
        XCTAssertEqual(projects.count, 10)
        XCTAssertEqual(projects.first?.projectURL, directories[5].standardizedFileURL)
        XCTAssertEqual(Set(projects.map(\.canonicalPath)).count, projects.count)
        XCTAssertFalse(projects.contains { $0.projectURL == directories[0].standardizedFileURL })
    }

    func testProjectsPrunesMissingDirectoriesAndClearRemovesEverything() async throws {
        let suite = "RecentProjectsTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRecentProjectStore(suiteName: suite, key: "projects")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = await store.record(directory)
        try FileManager.default.removeItem(at: directory)

        let pruned = await store.projects()
        XCTAssertTrue(pruned.isEmpty)

        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        _ = await store.record(existing)
        await store.clear()
        let cleared = await store.projects()
        XCTAssertTrue(cleared.isEmpty)
    }
}
