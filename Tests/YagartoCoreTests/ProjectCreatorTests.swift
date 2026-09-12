// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoCore

final class ProjectCreatorTests: XCTestCase {
    func testCreateWritesProfileSpecificRunnableProjectWithoutBuildOutput() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let cases: [(ProfileID, String, String)] = [
            (.arm7tdmi, "start", ".cpu arm7tdmi"),
            (.cortexM4, "main", ".cpu cortex-m4"),
            (.stm32f4Discovery, "main", ".cpu cortex-m4")
        ]

        for (index, item) in cases.enumerated() {
            let name = "课程 工程 \(index + 1)"
            let created = try ProjectCreator().create(ProjectCreationRequest(
                parentDirectory: root.url,
                name: name,
                profile: item.0
            ))

            XCTAssertEqual(created.projectDirectory.lastPathComponent, name)
            XCTAssertEqual(created.sourceURL.lastPathComponent, "\(name).s")
            XCTAssertEqual(created.configuration.profile, item.0)
            XCTAssertEqual(created.configuration.entry, item.1)
            XCTAssertEqual(created.configuration.sources, ["\(name).s"])
            XCTAssertEqual(created.configuration.outputName, name)
            XCTAssertEqual(
                try ConfigStore(projectDirectory: created.projectDirectory).load(),
                created.configuration
            )
            let source = try String(contentsOf: created.sourceURL, encoding: .utf8)
            XCTAssertTrue(source.contains(item.2))
            XCTAssertTrue(source.contains(".global \(item.1)"))
            XCTAssertTrue(source.contains("b       .Lhalt"))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: created.projectDirectory.appendingPathComponent(".yagarto").path
            ))
        }
    }

    func testCreateRejectsUnsafeNamesAndAllocatesNumberedCollisionWithoutOverwrite() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let existing = root.url.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        let created = try ProjectCreator().create(ProjectCreationRequest(
            parentDirectory: root.url,
            name: "demo",
            profile: .arm7tdmi
        ))

        XCTAssertEqual(created.projectDirectory.lastPathComponent, "demo-2")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        for name in ["", " ", ".", "..", ".hidden", "a/b", "a:b", "bad\nname"] {
            XCTAssertThrowsError(try ProjectCreator().create(ProjectCreationRequest(
                parentDirectory: root.url,
                name: name,
                profile: .arm7tdmi
            ))) { error in
                XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "project.invalid_name")
            }
        }
    }

    func testImportMovesByteIdenticalSourcesIntoIndependentProjectsAndDetectsEntries() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let firstData = Data("""
        .global start
        start:
            b start
        """.utf8)
        let secondData = Data("""
        .globl lesson_entry
        lesson_entry:
            b lesson_entry
        """.utf8)
        let first = root.url.appendingPathComponent("first.s")
        let second = root.url.appendingPathComponent("第二课.S")
        try firstData.write(to: first)
        try secondData.write(to: second)

        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [first, second],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .complete)
        XCTAssertEqual(report.created.count, 2)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        let bySource = Dictionary(uniqueKeysWithValues: report.created.map {
            ($0.sourceURL.lastPathComponent, $0)
        })
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(bySource["first.s"]?.sourceURL)), firstData)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(bySource["第二课.S"]?.sourceURL)), secondData)
        XCTAssertEqual(bySource["first.s"]?.configuration.entry, "start")
        XCTAssertEqual(bySource["第二课.S"]?.configuration.entry, "lesson_entry")
    }

    func testDirectoryImportIsNonRecursiveAndSkipsAmbiguousOrExistingProjects() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        try Data(".global start\nstart: b start\n".utf8)
            .write(to: root.url.appendingPathComponent("valid.s"))
        try Data(".global one, two\none: b one\ntwo: b two\n".utf8)
            .write(to: root.url.appendingPathComponent("ambiguous.s"))
        try Data("not assembly".utf8)
            .write(to: root.url.appendingPathComponent("notes.txt"))
        let nested = root.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(".global start\nstart: b start\n".utf8)
            .write(to: nested.appendingPathComponent("nested.s"))
        let existingProject = root.url.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingProject, withIntermediateDirectories: false)
        try Data(".global start\nstart: b start\n".utf8)
            .write(to: existingProject.appendingPathComponent("existing.s"))
        try ConfigStore(projectDirectory: existingProject).save(ProjectConfiguration(
            sources: ["existing.s"], outputName: "existing"
        ))

        let directoryReport = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [root.url],
            profile: .arm7tdmi
        ))
        let existingReport = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [existingProject.appendingPathComponent("existing.s")],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(directoryReport.created.map(\.sourceURL.lastPathComponent), ["valid.s"])
        XCTAssertEqual(directoryReport.skipped.map(\.sourceURL.lastPathComponent), ["ambiguous.s"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("nested.s").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(existingReport.status, .partial)
        XCTAssertEqual(existingReport.skipped.first?.code, "project.already_configured")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: existingProject.appendingPathComponent("existing.s").path
        ))
    }

    func testEmptyDirectoryImportReportsNoSourcesInsteadOfEmptySuccess() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let empty = root.url.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)

        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [empty],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.created.isEmpty)
        XCTAssertEqual(report.skipped.map(\.code), ["project.no_sources"])
    }

    func testImportRejectsUnsafeFilesAndLeavesOriginalsUntouched() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let invalidUTF8 = root.url.appendingPathComponent("invalid.s")
        try Data([0xff, 0xfe]).write(to: invalidUTF8)
        let target = root.url.appendingPathComponent("target.s")
        try Data(".global start\nstart: b start\n".utf8).write(to: target)
        let symbolic = root.url.appendingPathComponent("symbolic.s")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        let hard = root.url.appendingPathComponent("hard.s")
        try FileManager.default.linkItem(at: target, to: hard)

        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [invalidUTF8, symbolic, hard],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.created.isEmpty)
        XCTAssertEqual(Set(report.skipped.map(\.code)), [
            "project.invalid_utf8", "project.unsafe_link"
        ])
        for url in [invalidUTF8, symbolic, hard, target] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFailureBeforePublishLeavesOriginalAndCleansStaging() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("lesson.s")
        let original = Data(".global start\nstart: b start\n".utf8)
        try original.write(to: source)
        let creator = ProjectCreator(testingBeforePublish: { _ in
            throw CocoaError(.fileWriteUnknown)
        })

        let report = creator.importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.created.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.hasPrefix(".yagarto-project-staging-") })
    }

    func testEveryPrepublishCheckpointFailureLeavesOriginalAndCleansStaging() throws {
        for checkpoint in ProjectCreationCheckpoint.allCases {
            let root = try ProjectCreatorTemporaryDirectory()
            let source = root.url.appendingPathComponent("lesson.s")
            let original = Data(".global start\nstart: b start\n".utf8)
            try original.write(to: source)
            let creator = ProjectCreator(testingCheckpoint: { current in
                if current == checkpoint { throw CocoaError(.fileWriteUnknown) }
            })

            let report = creator.importProjects(ProjectImportRequest(
                inputs: [source],
                profile: .arm7tdmi
            ))

            XCTAssertEqual(report.status, .partial, "checkpoint: \(checkpoint)")
            XCTAssertTrue(report.created.isEmpty, "checkpoint: \(checkpoint)")
            XCTAssertEqual(try Data(contentsOf: source), original, "checkpoint: \(checkpoint)")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".yagarto-project-staging-") })
        }
    }

    func testOriginalDeletionFailureKeepsBothCopiesAndReturnsWarning() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("lesson.s")
        let original = Data(".global start\nstart: b start\n".utf8)
        try original.write(to: source)
        let creator = ProjectCreator(testingRemoveOriginal: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        let report = creator.importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.created.count, 1)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(report.warnings.map(\.code), ["project.original_retained"])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(report.created.first?.sourceURL)), original)
    }

    func testSourceReplacedAfterPublishIsNotDeletedAndPublishedSnapshotStaysOriginal() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("lesson.s")
        let original = Data(".global start\nstart: b start\n".utf8)
        let replacement = Data("后来写入，绝不能删除".utf8)
        try original.write(to: source)
        let creator = ProjectCreator(testingBeforeOriginalRemoval: { _ in
            try replacement.write(to: source, options: .atomic)
        })

        let report = creator.importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.created.count, 1)
        XCTAssertEqual(report.warnings.map(\.code), ["project.original_changed"])
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(report.created.first?.sourceURL)), original)
    }

    func testLongLegalSourceNameDoesNotOverflowPrivateQuarantineName() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("\(String(repeating: "a", count: 220)).s")
        try Data(".global start\nstart: b start\n".utf8).write(to: source)

        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .complete)
        XCTAssertEqual(report.created.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testDynamicOrConditionalEntryDefinitionsAreSkippedInsteadOfGuessed() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let preprocessed = root.url.appendingPathComponent("macro.S")
        try Data("""
        #define ENTRY main
        .global ENTRY
        ENTRY:
            b ENTRY
        """.utf8).write(to: preprocessed)
        let conditional = root.url.appendingPathComponent("conditional.s")
        try Data("""
        .ifb token
        .global start
        start:
            b start
        .endif
        .global actual
        actual:
            b actual
        """.utf8).write(to: conditional)
        let semicolonConditional = root.url.appendingPathComponent("semicolon.s")
        try Data("""
        dummy: nop ; .if 0
        .global start
        start:
            b start ; .endif
        .global actual
        actual:
            b actual
        """.utf8).write(to: semicolonConditional)

        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [preprocessed, conditional, semicolonConditional],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.created.isEmpty)
        XCTAssertEqual(Set(report.skipped.map(\.code)), ["project.dynamic_entry_unsupported"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: preprocessed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: conditional.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: semicolonConditional.path))
    }

    func testSourceThatBecomesConfiguredDuringImportIsNotRemoved() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("lesson.s")
        let rootURL = root.url
        let original = Data(".global start\nstart: b start\n".utf8)
        try original.write(to: source)
        let creator = ProjectCreator(testingBeforeOriginalRemoval: { _ in
            let configuration = ProjectConfiguration(
                sources: ["lesson.s"],
                outputName: "late-project"
            )
            try JSONEncoder().encode(configuration).write(
                to: rootURL.appendingPathComponent("yagarto.json"),
                options: .atomic
            )
        })

        let report = creator.importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))

        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.created.count, 1)
        XCTAssertEqual(report.warnings.map(\.code), ["project.original_became_configured"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testConfigSaveCannotInterleaveWithSourceImportMutation() throws {
        let root = try ProjectCreatorTemporaryDirectory()
        let rootURL = root.url
        let source = root.url.appendingPathComponent("lesson.s")
        try Data(".global start\nstart: b start\n".utf8).write(to: source)
        let importReachedRemoval = DispatchSemaphore(value: 0)
        let releaseImport = DispatchSemaphore(value: 0)
        let importFinished = DispatchSemaphore(value: 0)
        let saveFinished = DispatchSemaphore(value: 0)
        let creator = ProjectCreator(testingBeforeOriginalRemoval: { _ in
            importReachedRemoval.signal()
            releaseImport.wait()
        })

        DispatchQueue.global().async {
            _ = creator.importProjects(ProjectImportRequest(inputs: [source], profile: .arm7tdmi))
            importFinished.signal()
        }
        XCTAssertEqual(importReachedRemoval.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            try? ConfigStore(projectDirectory: rootURL).save(ProjectConfiguration(
                sources: ["lesson.s"],
                outputName: "concurrent-init"
            ))
            saveFinished.signal()
        }

        XCTAssertEqual(saveFinished.wait(timeout: .now() + 0.1), .timedOut)
        releaseImport.signal()
        XCTAssertEqual(importFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(saveFinished.wait(timeout: .now() + 2), .success)
    }

    func testCreatedTemplatesProduceRealELFForEveryProfileWhenToolsAreAvailable() throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [.assembler, .linker, .objcopy, .objdump]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实 ARM 工具 \(tool.rawValue)，跳过新工程模板 E2E")
            }
            tools[tool] = path
        }
        let root = try ProjectCreatorTemporaryDirectory()

        for profile in ProfileID.allCases {
            let created = try ProjectCreator().create(ProjectCreationRequest(
                parentDirectory: root.url,
                name: "template-\(profile.rawValue)",
                profile: profile
            ))
            let plan = try BuildPlanner(toolPaths: tools).plan(
                configuration: created.configuration,
                projectDirectory: created.projectDirectory
            )

            _ = try BuildExecutor().execute(plan)

            XCTAssertTrue(FileManager.default.fileExists(atPath: plan.elfFile.path))
            XCTAssertGreaterThan(try Data(contentsOf: plan.elfFile).count, 0)
            let listing = try String(contentsOf: plan.listingFile, encoding: .utf8)
            XCTAssertTrue(listing.contains(".global \(created.configuration.entry)"))
            let dwarf = try ProcessRunner().run(CommandSpec(
                executable: try XCTUnwrap(tools[.objdump]),
                args: ["--dwarf=decodedline", plan.elfFile.path],
                workingDirectory: created.projectDirectory
            ))
            XCTAssertEqual(dwarf.exitStatus, 0, dwarf.toolOutput ?? "")
            XCTAssertTrue(dwarf.stdout.contains(created.sourceURL.lastPathComponent))
        }
    }

    func testImportedSimpleUppercaseSourceBuildsWhenCompilerIsAvailable() throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [.assembler, .compiler, .linker, .objcopy, .objdump]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实 ARM 工具 \(tool.rawValue)，跳过 .S 导入 E2E")
            }
            tools[tool] = path
        }
        let root = try ProjectCreatorTemporaryDirectory()
        let source = root.url.appendingPathComponent("preprocessed.S")
        try Data("""
        .syntax unified
        .cpu arm7tdmi
        .arm
        .global start
        start:
            b start
        """.utf8).write(to: source)
        let report = ProjectCreator().importProjects(ProjectImportRequest(
            inputs: [source],
            profile: .arm7tdmi
        ))
        let created = try XCTUnwrap(report.created.first)
        let plan = try BuildPlanner(toolPaths: tools).plan(
            configuration: created.configuration,
            projectDirectory: created.projectDirectory
        )

        _ = try BuildExecutor().execute(plan)

        XCTAssertEqual(report.status, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.elfFile.path))
    }
}

private final class ProjectCreatorTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yagarto-project-creator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
