// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class AccessibilityIdentifierContractTests: XCTestCase {
    func testMemoryWindowUsesAutomaticAddressControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )

        let requiredContracts = [
            "@State private var memoryWindowControl = MemoryWindowControlState()",
            "Text(\"Address\")",
            ".accessibilityIdentifier(\"memory-address\")",
            ".accessibilityIdentifier(\"memory-address-stepper\")",
            "Text(\"Target is LITTLE endian\")",
            ".accessibilityIdentifier(\"memory-endianness\")",
            ".onSubmit { submitMemoryAddress(memoryWindowControl.editableAddressText) }",
            "await model.setMemoryWindowAddress(candidate)",
            "memoryWindowControl.step(byRows: rowCount)",
            "memoryWindowControl.rollbackDisplayedToConfirmed()",
            "model.invalidateMemoryWindowAddressOperation()",
            "model.reportMemoryWindowError(error)",
            "MemoryHexTable(blocks: model.memory, baseAddress: memoryWindowControl.displayedBaseAddress)"
        ]
        for contract in requiredContracts {
            XCTAssertTrue(workbench.contains(contract), "内存窗口缺少契约：\(contract)")
        }

        let removedContracts = [
            "@State private var memoryLength",
            "@State private var memoryAddress =",
            "@State private var committedMemoryAddress",
            "@State private var committedMemoryAddressText",
            "@State private var memoryAddressRequestGeneration",
            ".accessibilityIdentifier(\"memory-length\")",
            ".accessibilityIdentifier(\"memory-read\")",
            "Button(\"读取\")",
            "candidate = rowCount < 0 ? \"-0x10\" : \"0x10000000000000000\""
        ]
        for contract in removedContracts {
            XCTAssertFalse(workbench.contains(contract), "内存窗口仍包含旧契约：\(contract)")
        }

        XCTAssertTrue(workbench.contains(".accessibilityLabel(\"内存起始地址\")"))
        XCTAssertTrue(workbench.contains(".accessibilityHint(\"输入十六进制地址后按回车提交\")"))
        XCTAssertTrue(workbench.contains(".accessibilityLabel(\"内存地址步进，每次 16 字节\")"))
        XCTAssertTrue(workbench.contains(".onChange(of: model.documentInstanceID)"))
        XCTAssertFalse(workbench.contains(".onChange(of: model.document?.sourceURL)"))
    }

    func testStatusIdentifiersAreProducedAndQueriedIndependently() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiTests = try String(
            contentsOf: repository.appendingPathComponent("YagartoMacAppUITests/YagartoMacAppUITests.swift"),
            encoding: .utf8
        )
        let identifiers = [
            AppAccessibilityIdentifier.debuggerState,
            AppAccessibilityIdentifier.sourceLocationStatus,
            AppAccessibilityIdentifier.currentLineStatus,
            AppAccessibilityIdentifier.operationError
        ]

        for identifier in identifiers {
            let directQuery = "app.descendants(matching: .any)[\"\(identifier)\"]"
            XCTAssertTrue(
                uiTests.contains(directQuery),
                "XCUITest must query \(identifier) directly"
            )
        }

        let semanticQueries = [
            "waitForLabel(\"已定位到第 2 行\", element: sourceLocation)",
            "waitForLabelContaining(\"当前执行第 1 行\", element: currentLine)",
            "waitForLabelContaining(\"当前执行第 2 行\", element: currentLine)",
            "waitForLabelContaining(\"测试后端启动失败\", element: operationError)",
            "waitForLabelContaining(\"测试调试器意外退出\", element: operationError)"
        ]
        for query in semanticQueries {
            XCTAssertTrue(uiTests.contains(query), "Missing semantic UI query: \(query)")
        }
        let stateQueryLines = uiTests.split(separator: "\n").filter { $0.contains("element: state") }
        for fragment in ["已定位到第", "当前执行第", "测试后端启动失败", "测试调试器意外退出"] {
            XCTAssertFalse(
                stateQueryLines.contains { $0.contains(fragment) },
                "Status fragments must not be queried through debugger-state: \(fragment)"
            )
        }
    }

    func testProjectCreationControlsHaveStableAccessibilityContracts() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )
        let uiTests = try String(
            contentsOf: repository.appendingPathComponent("YagartoMacAppUITests/YagartoMacAppUITests.swift"),
            encoding: .utf8
        )
        let identifiers = [
            "empty-new-project", "empty-import-projects", "new-project-name",
            "new-project-create", "import-profile-picker", "import-confirm",
            "import-summary"
        ]
        for identifier in identifiers {
            XCTAssertTrue(workbench.contains("\"\(identifier)\""), "App 缺少 \(identifier)")
            XCTAssertTrue(uiTests.contains("\"\(identifier)\""), "XCUITest 缺少 \(identifier)")
        }
    }

    func testNewProjectAndStepOverDoNotShareCommandN() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )
        let plainCommandN = ".keyboardShortcut(\"n\", modifiers: .command)"

        XCTAssertEqual(workbench.components(separatedBy: plainCommandN).count - 1, 2)
        XCTAssertTrue(workbench.contains(
            "Button(\"单步越过\") { Task { await model.stepOver() } }\n" +
            "                .keyboardShortcut(\"n\", modifiers: [.command, .shift])"
        ))
    }

    func testMultiSourceSidebarHasTextualStateAndStableIdentifiers() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(workbench.contains(#".accessibilityIdentifier("project-sources")"#))
        XCTAssertTrue(workbench.contains(#".accessibilityIdentifier("source-row-\(source.relativePath)")"#))
        XCTAssertTrue(workbench.contains(#"Text("已修改")"#))
        XCTAssertTrue(workbench.contains("await model.selectSource(source.relativePath)"))
        XCTAssertTrue(workbench.contains("await model.activateDiagnostic(diagnostic)"))
    }

    func testRecentProjectsAreAvailableFromEmptyStateAndFileMenu() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(workbench.contains(#".accessibilityIdentifier("recent-projects")"#))
        XCTAssertTrue(workbench.contains(#".accessibilityIdentifier("recent-project-\(project.displayName)")"#))
        XCTAssertTrue(workbench.contains(#".accessibilityIdentifier("clear-recent-projects")"#))
        XCTAssertTrue(workbench.contains(#"Menu("打开最近工程")"#))
        XCTAssertTrue(workbench.contains("RecentProjectAction.open(project, for: model)"))
    }

    func testEnvironmentOnboardingIsAccessibleAndNeverExecutesInstallCommands() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workbench = try String(
            contentsOf: repository.appendingPathComponent("Sources/YagartoMacApp/WorkbenchView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "environment-onboarding", "environment-recheck", "copy-install-command",
            "environment-install-guide", "onboarding-open-example", "onboarding-skip"
        ] {
            XCTAssertTrue(workbench.contains(#""\#(identifier)""#), "缺少 \(identifier)")
        }
        XCTAssertTrue(workbench.contains("ARM926 是兼容超集，不是精确 ARM7TDMI 模型"))
        XCTAssertTrue(workbench.contains("NSPasteboard.general"))
        XCTAssertTrue(workbench.contains(#"Button("检查开发环境…")"#))
        XCTAssertFalse(workbench.contains("ProcessRunner"))
        XCTAssertFalse(workbench.contains("Process("))
    }
}
