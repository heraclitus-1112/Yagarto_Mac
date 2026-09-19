// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class ExampleWorkspaceTests: XCTestCase {
    func testInstallerCopiesBundledProjectIntoChineseSpaceApplicationSupportOnce() async throws {
        let fixture = try ExampleFixture()
        let destinationRoot = fixture.root.appendingPathComponent("应用 支持 空格", isDirectory: true)
        let installer = ExampleWorkspaceInstaller(
            bundledProject: fixture.bundledProject,
            applicationSupportDirectory: destinationRoot,
            destinationName: "ARM7 数组 示例"
        )

        let installed = try await installer.install()

        XCTAssertEqual(installed, destinationRoot.appendingPathComponent("ARM7 数组 示例"))
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("main.s"), encoding: .utf8),
            "MOV r0, #1\n"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("yagarto.json").path))

        try Data("用户修改\n".utf8).write(to: installed.appendingPathComponent("main.s"), options: .atomic)
        let installedAgain = try await installer.install()

        XCTAssertEqual(installedAgain, installed)
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("main.s"), encoding: .utf8),
            "用户修改\n",
            "再次点击示例不能覆盖用户已修改的工作副本"
        )
    }

    func testInstallerRejectsBundledProjectWhenAnyConfiguredSourceIsMissing() async throws {
        let fixture = try ExampleFixture()
        try ConfigStore(projectDirectory: fixture.bundledProject).save(ProjectConfiguration(
            sources: ["main.s", "missing.s"],
            outputName: "example"
        ))
        let installer = ExampleWorkspaceInstaller(
            bundledProject: fixture.bundledProject,
            applicationSupportDirectory: fixture.root.appendingPathComponent("Applications"),
            destinationName: "Broken Example"
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected the incomplete example to be rejected")
        } catch let error as ExampleWorkspaceError {
            guard case .bundledExampleMissing = error else {
                return XCTFail("Unexpected example error: \(error)")
            }
        }
    }

    @MainActor
    func testOwnedTemporaryWorkspaceDeletesOnlyDirectoryWithMatchingOwnershipMarker() throws {
        let fixture = try ExampleFixture()
        let owned = try OwnedTemporaryWorkspace.create(
            in: fixture.root,
            prefix: "YagartoMacApp-UI"
        )
        let ownedDirectory = owned.directory
        try Data("owned".utf8).write(to: ownedDirectory.appendingPathComponent("main.s"))

        XCTAssertTrue(try owned.cleanup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDirectory.path))

        let foreign = fixture.root.appendingPathComponent("YagartoMacApp-UI-foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("main.s"))

        XCTAssertFalse(try OwnedTemporaryWorkspace.cleanup(
            directory: foreign,
            expectedParent: fixture.root,
            ownershipToken: UUID().uuidString
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("main.s").path))
    }
}

private final class ExampleFixture {
    let root: URL
    let bundledProject: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("示例 工作区 \(UUID().uuidString)", isDirectory: true)
        bundledProject = root
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("array-addressing", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledProject, withIntermediateDirectories: true)
        try Data("MOV r0, #1\n".utf8).write(to: bundledProject.appendingPathComponent("main.s"))
        try Data(#"{"schemaVersion":1,"profile":"arm7tdmi","entry":"start","sources":["main.s"],"outputName":"example"}"#.utf8)
            .write(to: bundledProject.appendingPathComponent("yagarto.json"))
    }

    deinit {
        _ = try? FileManager.default.removeItem(at: root)
    }
}
