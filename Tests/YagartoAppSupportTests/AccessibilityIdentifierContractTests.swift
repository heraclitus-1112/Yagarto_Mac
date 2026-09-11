// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class AccessibilityIdentifierContractTests: XCTestCase {
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
}
