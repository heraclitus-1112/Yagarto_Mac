// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class ProjectTreeTests: XCTestCase {
    func testBuildsNestedTreeInFirstSourceOccurrenceOrder() {
        let project = URL(fileURLWithPath: "/tmp/tree-project", isDirectory: true)
        let configuration = ProjectConfiguration(sources: [
            "main.s",
            "drivers/uart.s",
            "support/helper.s",
            "drivers/spi.S"
        ])
        let document = WorkspaceDocument(
            projectDirectory: project,
            sourceURL: project.appendingPathComponent("main.s"),
            configuration: configuration,
            text: "MOV r0, #1\n"
        )

        let tree = ProjectTreeNode.build(from: document.sourceBuffers)

        XCTAssertEqual(tree.map(\.name), ["main.s", "drivers", "support"])
        XCTAssertEqual(tree[0].kind, .source)
        XCTAssertEqual(tree[1].kind, .folder)
        XCTAssertEqual(tree[1].children.map(\.name), ["uart.s", "spi.S"])
        XCTAssertEqual(tree[1].children.map(\.relativePath), ["drivers/uart.s", "drivers/spi.S"])
        XCTAssertEqual(tree[2].children.map(\.relativePath), ["support/helper.s"])
    }

    func testSourceNodeCarriesDirtyStateWithoutPersistingTree() {
        let project = URL(fileURLWithPath: "/tmp/tree-dirty", isDirectory: true)
        let document = WorkspaceDocument(
            projectDirectory: project,
            sourceURL: project.appendingPathComponent("main.s"),
            configuration: ProjectConfiguration(sources: ["main.s"]),
            text: "MOV r0, #1\n"
        ).editing("MOV r0, #2\n")

        let tree = ProjectTreeNode.build(from: document.sourceBuffers)

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].relativePath, "main.s")
        XCTAssertTrue(tree[0].isDirty)
        XCTAssertTrue(tree[0].children.isEmpty)
    }
}
