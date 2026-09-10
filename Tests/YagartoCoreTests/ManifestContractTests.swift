// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class ManifestContractTests: XCTestCase {
    func testSwiftToolsVersionIsExactlySixPointThree() throws {
        let packageFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageFile, encoding: .utf8)

        XCTAssertEqual(manifest.components(separatedBy: .newlines).first, "// swift-tools-version: 6.3")
    }
}
