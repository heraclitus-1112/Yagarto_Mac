// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import XCTest
@testable import YagartoAppSupport

final class ProjectSourceManagerTests: XCTestCase {
    func testCreateSourceAppendsPersistsAndActivatesEmptyFile() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let document = try await LocalDocumentService().open(fixture.directory)

        let result = try await LocalProjectSourceManager().createSource(
            CreateProjectSourceRequest(directoryRelativePath: nil, filename: "helper"),
            in: document
        )

        XCTAssertEqual(result.addedRelativePaths, ["helper.s"])
        XCTAssertEqual(result.document.configuration.sources, ["main.s", "helper.s"])
        XCTAssertEqual(result.document.activeSourceRelativePath, "helper.s")
        XCTAssertEqual(result.document.text, "")
        XCTAssertFalse(result.document.isDirty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("helper.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s", "helper.s"]
        )
    }

    func testCopySourcesPreservesOriginalsUsesUniqueNamesAndActivatesFirstCopy() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s", "vendor.s"])
        let external = try SourceManagerFixture(sources: [])
        let first = external.directory.appendingPathComponent("vendor.s")
        let second = external.directory.appendingPathComponent("math.S")
        try Data("MOV r1, #1\n".utf8).write(to: first)
        try Data("MOV r2, #2\n".utf8).write(to: second)
        let document = try await LocalDocumentService().open(fixture.directory)

        let result = try await LocalProjectSourceManager().copySources(
            CopyProjectSourcesRequest(
                sourceURLs: [first, second],
                destinationDirectoryRelativePath: nil
            ),
            in: document
        )

        XCTAssertEqual(result.addedRelativePaths, ["vendor-2.s", "math.S"])
        XCTAssertEqual(result.document.activeSourceRelativePath, "vendor-2.s")
        XCTAssertEqual(result.document.text, "MOV r1, #1\n")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "MOV r1, #1\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "MOV r2, #2\n")
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s", "vendor.s", "vendor-2.s", "math.S"]
        )
    }

    func testCopySourcesConvertsWindows1252AndGB18030ToUTF8WithoutChangingOriginals() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let external = try SourceManagerFixture(sources: [])
        let frenchText = "@ résultat récupère\r\nMOV r1, #1\r\n"
        let chineseText = "@ 中文注释：课程源码\r\nMOV r2, #2\r\n"
        let frenchData = try XCTUnwrap(frenchText.data(using: .windowsCP1252))
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let chineseData = try XCTUnwrap(chineseText.data(using: gb18030))
        let french = external.directory.appendingPathComponent("french.s")
        let chinese = external.directory.appendingPathComponent("chinese.s")
        try frenchData.write(to: french)
        try chineseData.write(to: chinese)
        let document = try await LocalDocumentService().open(fixture.directory)

        let result = try await LocalProjectSourceManager().copySources(
            CopyProjectSourcesRequest(
                sourceURLs: [french, chinese],
                destinationDirectoryRelativePath: nil
            ),
            in: document
        )

        XCTAssertEqual(result.addedRelativePaths, ["french.s", "chinese.s"])
        XCTAssertEqual(result.convertedRelativePaths, ["french.s", "chinese.s"])
        XCTAssertEqual(result.document.activeSourceRelativePath, "french.s")
        XCTAssertEqual(result.document.text, frenchText)
        XCTAssertEqual(try Data(contentsOf: french), frenchData)
        XCTAssertEqual(try Data(contentsOf: chinese), chineseData)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.directory.appendingPathComponent("french.s"),
                encoding: .utf8
            ),
            frenchText
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.directory.appendingPathComponent("chinese.s"),
                encoding: .utf8
            ),
            chineseText
        )
    }

    func testRenameDirtySourcePreservesBufferSelectionAndReportsPathMapping() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s", "helper.s"])
        let service = LocalDocumentService()
        var document = try await service.open(fixture.directory)
        document = try await service.selectSource("helper.s", in: document)
        document = document
            .editing("MOV r7, #7\n")
            .updatingActiveSelection(NSRange(location: 4, length: 0))

        let result = try await LocalProjectSourceManager().renameSource(
            RenameProjectSourceRequest(relativePath: "helper.s", newFilename: "renamed.S"),
            in: document
        )

        XCTAssertEqual(result.renamedRelativePaths, ["helper.s": "renamed.S"])
        XCTAssertEqual(result.document.activeSourceRelativePath, "renamed.S")
        XCTAssertEqual(result.document.text, "MOV r7, #7\n")
        XCTAssertEqual(result.document.activeSelection, NSRange(location: 4, length: 0))
        XCTAssertTrue(result.document.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("helper.s").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("renamed.S").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s", "renamed.S"]
        )
    }

    func testTrashDirtySourceCanSaveLatestAndSelectNextSource() async throws {
        let fixture = try SourceManagerFixture(sources: ["first.s", "second.s", "third.s"])
        let service = LocalDocumentService()
        var document = try await service.open(fixture.directory)
        document = try await service.selectSource("second.s", in: document)
        document = document.editing("MOV r9, #9\n")
        let trash = fixture.directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let manager = LocalProjectSourceManager(testingTrashHandler: { source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })

        let result = try await manager.trashSource(
            TrashProjectSourceRequest(relativePath: "second.s", dirtyPolicy: .saveLatest),
            in: document
        )

        XCTAssertEqual(result.removedRelativePath, "second.s")
        XCTAssertEqual(result.document.configuration.sources, ["first.s", "third.s"])
        XCTAssertEqual(result.document.activeSourceRelativePath, "third.s")
        XCTAssertEqual(result.document.text, "MOV r2, #2\n")
        XCTAssertEqual(
            try String(contentsOf: trash.appendingPathComponent("second.s"), encoding: .utf8),
            "MOV r9, #9\n"
        )
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["first.s", "third.s"]
        )
    }

    func testTrashRejectsLastSourceWithoutChangingDiskOrConfiguration() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let document = try await LocalDocumentService().open(fixture.directory)

        await XCTAssertThrowsSourceMutation(
            try await LocalProjectSourceManager().trashSource(
                TrashProjectSourceRequest(relativePath: "main.s", dirtyPolicy: .discardChanges),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .cannotTrashLastSource)
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("main.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s"]
        )
    }

    func testCopySourcesRejectsUnsafeInputBeforePublishingAnyFiles() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let external = try SourceManagerFixture(sources: [])
        let target = external.directory.appendingPathComponent("target.s")
        try Data("MOV r1, #1\n".utf8).write(to: target)
        let symlink = external.directory.appendingPathComponent("linked.s")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let document = try await LocalDocumentService().open(fixture.directory)

        await XCTAssertThrowsSourceMutation(
            try await LocalProjectSourceManager().copySources(
                CopyProjectSourcesRequest(
                    sourceURLs: [target, symlink],
                    destinationDirectoryRelativePath: nil
                ),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .unsafeSymbolicLink(symlink.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("target.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s"]
        )
    }

    func testCopySourcesRejectsHardLinkedInput() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let external = try SourceManagerFixture(sources: [])
        let target = external.directory.appendingPathComponent("target.s")
        let hardlink = external.directory.appendingPathComponent("hardlink.s")
        try Data("MOV r1, #1\n".utf8).write(to: target)
        try FileManager.default.linkItem(at: target, to: hardlink)
        let document = try await LocalDocumentService().open(fixture.directory)

        await XCTAssertThrowsSourceMutation(
            try await LocalProjectSourceManager().copySources(
                CopyProjectSourcesRequest(
                    sourceURLs: [hardlink],
                    destinationDirectoryRelativePath: nil
                ),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .unsafeHardLink(hardlink.path))
        }
    }

    func testCopySourcesRejectsInvalidUTF8AndOversizedFile() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let external = try SourceManagerFixture(sources: [])
        let invalid = external.directory.appendingPathComponent("invalid.s")
        let large = external.directory.appendingPathComponent("large.s")
        try Data([0xFF]).write(to: invalid)
        try Data(repeating: 0x41, count: 9).write(to: large)
        let document = try await LocalDocumentService().open(fixture.directory)
        let manager = LocalProjectSourceManager(maximumFileBytes: 8)

        await XCTAssertThrowsSourceMutation(
            try await manager.copySources(
                CopyProjectSourcesRequest(
                    sourceURLs: [invalid],
                    destinationDirectoryRelativePath: nil
                ),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .invalidUTF8(invalid.path))
        }
        await XCTAssertThrowsSourceMutation(
            try await manager.copySources(
                CopyProjectSourcesRequest(
                    sourceURLs: [large],
                    destinationDirectoryRelativePath: nil
                ),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .fileTooLarge(actual: 9, limit: 8))
        }
    }

    func testCreateRejectsDirectoryTraversal() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let document = try await LocalDocumentService().open(fixture.directory)

        await XCTAssertThrowsSourceMutation(
            try await LocalProjectSourceManager().createSource(
                CreateProjectSourceRequest(directoryRelativePath: "../outside", filename: "bad.s"),
                in: document
            )
        ) { error in
            XCTAssertEqual(error, .invalidDirectory("../outside"))
        }
    }

    func testCopyRollsBackPublishedFilesWhenConfigurationWriteFails() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s"])
        let external = try SourceManagerFixture(sources: [])
        let source = external.directory.appendingPathComponent("copy.s")
        try Data("MOV r4, #4\n".utf8).write(to: source)
        let document = try await LocalDocumentService().open(fixture.directory)
        let manager = LocalProjectSourceManager(
            testingTrashHandler: { _ in nil },
            testingBeforeConfigurationSave: { throw SourceManagerTestFailure.expected }
        )

        await XCTAssertThrowsSourceMutation(
            try await manager.copySources(
                CopyProjectSourcesRequest(
                    sourceURLs: [source],
                    destinationDirectoryRelativePath: nil
                ),
                in: document
            )
        ) { error in
            guard case .fileIO = error else {
                return XCTFail("Expected fileIO, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("copy.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s"]
        )
    }

    func testRenameRestoresOriginalFileWhenConfigurationWriteFails() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s", "helper.s"])
        let document = try await LocalDocumentService().open(fixture.directory)
        let manager = LocalProjectSourceManager(
            testingTrashHandler: { _ in nil },
            testingBeforeConfigurationSave: { throw SourceManagerTestFailure.expected }
        )

        await XCTAssertThrowsSourceMutation(
            try await manager.renameSource(
                RenameProjectSourceRequest(relativePath: "helper.s", newFilename: "renamed.s"),
                in: document
            )
        ) { error in
            guard case .fileIO = error else {
                return XCTFail("Expected fileIO, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("helper.s").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("renamed.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s", "helper.s"]
        )
    }

    func testTrashFailureRestoresOriginalConfiguration() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s", "helper.s"])
        let document = try await LocalDocumentService().open(fixture.directory)
        let manager = LocalProjectSourceManager(testingTrashHandler: { _ in
            throw SourceManagerTestFailure.expected
        })

        await XCTAssertThrowsSourceMutation(
            try await manager.trashSource(
                TrashProjectSourceRequest(
                    relativePath: "helper.s",
                    dirtyPolicy: .discardChanges
                ),
                in: document
            )
        ) { error in
            guard case .trashFailed(
                let sourcePath,
                let configurationRestored,
                let latestTextSaved,
                _
            ) = error else {
                return XCTFail("Expected trashFailed, got \(error)")
            }
            XCTAssertEqual(sourcePath, fixture.directory.appendingPathComponent("helper.s").path)
            XCTAssertTrue(configurationRestored)
            XCTAssertFalse(latestTextSaved)
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("helper.s").path
        ))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: fixture.directory).load().sources,
            ["main.s", "helper.s"]
        )
    }

    func testTrashFailureReportsWhenLatestDirtyTextWasSaved() async throws {
        let fixture = try SourceManagerFixture(sources: ["main.s", "helper.s"])
        let service = LocalDocumentService()
        var document = try await service.open(fixture.directory)
        document = try await service.selectSource("helper.s", in: document)
        document = document.editing("MOV r10, #10\n")
        let manager = LocalProjectSourceManager(testingTrashHandler: { _ in
            throw SourceManagerTestFailure.expected
        })

        await XCTAssertThrowsSourceMutation(
            try await manager.trashSource(
                TrashProjectSourceRequest(relativePath: "helper.s", dirtyPolicy: .saveLatest),
                in: document
            )
        ) { error in
            guard case .trashFailed(_, true, true, _) = error else {
                return XCTFail("Expected restored configuration and saved text, got \(error)")
            }
        }

        XCTAssertEqual(
            try String(
                contentsOf: fixture.directory.appendingPathComponent("helper.s"),
                encoding: .utf8
            ),
            "MOV r10, #10\n"
        )
    }
}

private enum SourceManagerTestFailure: Error {
    case expected
}

private struct SourceManagerFixture {
    let directory: URL

    init(sources: [String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, source) in sources.enumerated() {
            let url = directory.appendingPathComponent(source)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("MOV r\(index), #\(index)\n".utf8).write(to: url)
        }
        if !sources.isEmpty {
            try ConfigStore(projectDirectory: directory).save(ProjectConfiguration(
                sources: sources,
                outputName: "fixture"
            ))
        }
    }
}

private func XCTAssertThrowsSourceMutation<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (ProjectSourceMutationError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected project source mutation error", file: file, line: line)
    } catch let error as ProjectSourceMutationError {
        verify(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
