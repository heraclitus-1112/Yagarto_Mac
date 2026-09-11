// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class DocumentServiceTests: XCTestCase {
    func testOpensProjectWithChineseSpacePathAndTracksDirtyText() async throws {
        let fixture = try AppTemporaryDirectory(name: "中文 工程")
        let source = fixture.url.appendingPathComponent("源 文件.s")
        try Data("MOV r0, #1\n".utf8).write(to: source)
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["源 文件.s"],
            outputName: "课程 固件"
        ))

        let document = try await LocalDocumentService().open(fixture.url)
        let edited = document.editing("MOV r0, #2\n")

        XCTAssertEqual(document.sourceURL, source.standardizedFileURL)
        XCTAssertEqual(document.configuration.profile, .arm7tdmi)
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(edited.isDirty)
        XCTAssertEqual(edited.text, "MOV r0, #2\n")
    }

    func testOpensAssemblyFileThroughNeighbouringConfiguration() async throws {
        let fixture = try AppTemporaryDirectory()
        let source = fixture.url.appendingPathComponent("main.S")
        try Data(".global start\n".utf8).write(to: source)
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["main.S"]))

        let document = try await LocalDocumentService().open(source)

        XCTAssertEqual(document.projectDirectory, fixture.url.standardizedFileURL)
        XCTAssertEqual(document.text, ".global start\n")
    }

    func testRejectsLargeInvalidUTF8SymlinkAndHardLink() async throws {
        let fixture = try AppTemporaryDirectory()
        let service = LocalDocumentService(maximumFileBytes: 8)

        let large = try fixture.source(named: "large.s", bytes: Data(repeating: 0x41, count: 9))
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["large.s"]))
        await XCTAssertThrowsAsyncError(try await service.open(large)) { error in
            XCTAssertEqual(error as? DocumentServiceError, .fileTooLarge(actual: 9, limit: 8))
        }

        let invalid = try fixture.source(named: "invalid.s", bytes: Data([0xFF]))
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["invalid.s"]))
        await XCTAssertThrowsAsyncError(try await LocalDocumentService().open(invalid)) { error in
            XCTAssertEqual(error as? DocumentServiceError, .invalidUTF8(invalid.path))
        }

        let target = try fixture.source(named: "target.s", bytes: Data("NOP\n".utf8))
        let symlink = fixture.url.appendingPathComponent("link.s")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["link.s"]))
        await XCTAssertThrowsAsyncError(try await LocalDocumentService().open(symlink)) { error in
            XCTAssertEqual(error as? DocumentServiceError, .unsafeSymbolicLink(symlink.path))
        }

        let hardlink = fixture.url.appendingPathComponent("hard.s")
        try FileManager.default.linkItem(at: target, to: hardlink)
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["hard.s"]))
        await XCTAssertThrowsAsyncError(try await LocalDocumentService().open(hardlink)) { error in
            XCTAssertEqual(error as? DocumentServiceError, .unsafeHardLink(hardlink.path))
        }
    }

    func testAtomicSavePersistsUTF8AndClearsDirtyWithoutFollowingLinks() async throws {
        let fixture = try AppTemporaryDirectory()
        let source = try fixture.source(named: "main.s", bytes: Data("MOV r0, #1\n".utf8))
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["main.s"]))
        let service = LocalDocumentService()
        let document = try await service.open(source).editing("MOV r0, #42 // 中文\n")

        let saved = try await service.save(document)

        XCTAssertFalse(saved.isDirty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "MOV r0, #42 // 中文\n")

        let destination = fixture.url.appendingPathComponent("destination.s")
        try Data("SECRET\n".utf8).write(to: destination)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
        await XCTAssertThrowsAsyncError(try await service.save(saved.editing("changed\n"))) { error in
            XCTAssertEqual(error as? DocumentServiceError, .unsafeSymbolicLink(source.path))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "SECRET\n")
    }

    func testOpenRejectsIntermediateSymlinkThatEscapesProject() async throws {
        let fixture = try AppTemporaryDirectory()
        let external = try AppTemporaryDirectory()
        _ = try external.source(named: "outside.s", bytes: Data("SECRET\n".utf8))
        let linkedDirectory = fixture.url.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: external.url)
        let escapedSource = linkedDirectory.appendingPathComponent("outside.s")
        try ConfigStore(projectDirectory: fixture.url).save(ProjectConfiguration(sources: ["linked/outside.s"]))

        await XCTAssertThrowsAsyncError(try await LocalDocumentService().open(fixture.url)) { error in
            XCTAssertEqual(error as? DocumentServiceError, .unsafeSymbolicLink(escapedSource.path))
        }
    }
}

private struct AppTemporaryDirectory {
    let url: URL

    init(name: String = UUID().uuidString) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func source(named name: String, bytes: Data) throws -> URL {
        let url = url.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

private func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
