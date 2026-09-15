// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XCTest
import YagartoCore
@testable import YagartoAppSupport

@MainActor
final class MemoryHexTableTests: XCTestCase {
    func testPopulatedTableExposesHeadersAndFirstRow() {
        let snapshot = hostedAccessibilitySnapshot(
            for: MemoryHexTable(blocks: [
                block(begin: "0x8000", contents: "fcfdeeff")
            ])
        )

        let expectedIdentifiers = Set([
            "memory-table",
            "memory-table-header-address",
            "memory-table-header-ascii",
            "memory-table-row-0"
        ] + (0..<16).map { "memory-table-header-byte-\($0)" })

        XCTAssertTrue(
            expectedIdentifiers.isSubset(of: snapshot.identifiers),
            "Missing identifiers: \(expectedIdentifiers.subtracting(snapshot.identifiers).sorted()); "
                + "found: \(snapshot.identifiers.sorted())"
        )

        let expectedRowChildren = Set([
            "memory-table-row-0-address",
            "memory-table-row-0-ascii"
        ] + (0..<16).map { "memory-table-row-0-byte-\($0)" })
        XCTAssertEqual(
            snapshot.childIdentifiers["memory-table-row-0"],
            expectedRowChildren,
            "The row must expose address, 16 byte columns, and ASCII as child elements"
        )
    }

    func testEmptyTableExposesEmptyState() {
        let identifiers = hostedAccessibilitySnapshot(for: MemoryHexTable(blocks: [])).identifiers

        XCTAssertTrue(identifiers.contains("memory-table"))
        XCTAssertTrue(identifiers.contains("memory-table-empty"))
    }

    func testMalformedContentsExposeErrorState() {
        let identifiers = hostedAccessibilitySnapshot(
            for: MemoryHexTable(blocks: [
                block(begin: "0x8000", contents: "GG")
            ])
        ).identifiers

        XCTAssertTrue(identifiers.contains("memory-table"))
        XCTAssertTrue(identifiers.contains("memory-table-error"))
    }

    func testRowGroupDoesNotRepeatAddressFromAddressChild() {
        let snapshot = hostedAccessibilitySnapshot(
            for: MemoryHexTable(blocks: [
                block(begin: "0x8000", contents: "fcfdeeff")
            ])
        )

        XCTAssertEqual(snapshot.labels["memory-table-row-0"], "内存行")
        XCTAssertNil(snapshot.values["memory-table-row-0"])
        XCTAssertEqual(
            snapshot.labels["memory-table-row-0-address"],
            "地址 0x00008000"
        )
    }

    private func block(begin: String, contents: String) -> MIMemoryBlock {
        MIMemoryBlock(
            begin: MIRawNumeric(raw: begin),
            offset: MIRawNumeric(raw: "0"),
            end: MIRawNumeric(raw: begin),
            contents: contents
        )
    }

    private func hostedAccessibilitySnapshot<Content: View>(
        for rootView: Content
    ) -> AccessibilitySnapshot {
        let hosting = NSHostingView(rootView: rootView.frame(width: 1_200, height: 420))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        var snapshot = AccessibilitySnapshot()
        var visited: Set<ObjectIdentifier> = []
        collectAccessibilitySnapshot(
            from: hosting,
            snapshot: &snapshot,
            visited: &visited
        )
        return snapshot
    }

    private struct AccessibilitySnapshot {
        var identifiers: Set<String> = []
        var childIdentifiers: [String: Set<String>] = [:]
        var labels: [String: String] = [:]
        var values: [String: String] = [:]
    }

    private func collectAccessibilitySnapshot(
        from object: NSObject,
        snapshot: inout AccessibilitySnapshot,
        visited: inout Set<ObjectIdentifier>
    ) {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return }

        let children = accessibilityChildren(of: object)
        if let identifier = accessibilityIdentifier(of: object) {
            snapshot.identifiers.insert(identifier)
            snapshot.childIdentifiers[identifier] = Set(children.compactMap(accessibilityIdentifier))
            if let label = accessibilityLabel(of: object) {
                snapshot.labels[identifier] = label
            }
            if let value = accessibilityValue(of: object) {
                snapshot.values[identifier] = value
            }
        }

        if let view = object as? NSView {
            for subview in view.subviews {
                collectAccessibilitySnapshot(
                    from: subview,
                    snapshot: &snapshot,
                    visited: &visited
                )
            }
            for child in children {
                collectAccessibilitySnapshot(
                    from: child,
                    snapshot: &snapshot,
                    visited: &visited
                )
            }
            return
        }

        if object is NSAccessibilityElement {
            for child in children {
                collectAccessibilitySnapshot(
                    from: child,
                    snapshot: &snapshot,
                    visited: &visited
                )
            }
        }
    }

    private func accessibilityIdentifier(of object: NSObject) -> String? {
        if let view = object as? NSView {
            let identifier = view.accessibilityIdentifier()
            return identifier.isEmpty ? nil : identifier
        }
        return (object as? NSAccessibilityElement)?.accessibilityIdentifier()
    }

    private func accessibilityLabel(of object: NSObject) -> String? {
        if let view = object as? NSView {
            return view.accessibilityLabel()
        }
        return (object as? NSAccessibilityElement)?.accessibilityLabel()
    }

    private func accessibilityValue(of object: NSObject) -> String? {
        if let view = object as? NSView {
            return view.accessibilityValue() as? String
        }
        return (object as? NSAccessibilityElement)?.accessibilityValue() as? String
    }

    private func accessibilityChildren(of object: NSObject) -> [NSObject] {
        let children: [Any]
        if let view = object as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let element = object as? NSAccessibilityElement {
            children = element.accessibilityChildren() ?? []
        } else {
            return []
        }
        return children.compactMap { $0 as? NSObject }
    }
}
