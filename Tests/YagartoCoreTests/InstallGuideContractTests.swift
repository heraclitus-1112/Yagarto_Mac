// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class InstallGuideContractTests: XCTestCase {
    func testSimulatorAndDoctorAreMandatoryBeforeFirstPreciseARM7Debug() throws {
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let simulator = try index(of: "构建 ARM7 指令级 GDB simulator", in: guide)
        let doctor = try index(of: "用 doctor 做安装门槛验收", in: guide)
        let firstPreciseDebug = try index(of: "完成第一个精确 ARM7 工程", in: guide)

        XCTAssertLessThan(simulator, doctor)
        XCTAssertLessThan(doctor, firstPreciseDebug)
        XCTAssertTrue(guide.contains("Simulator GDB") && guide.contains("失败时停止"))
    }

    func testPrebuiltReleasePathDocumentsArchiveChecksumAndUnsignedBoundary() throws {
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        XCTAssertTrue(guide.contains("YagartoMacApp-0.6.0-macOS-arm64.zip"))
        XCTAssertTrue(guide.contains("SHA256SUMS.txt"))
        XCTAssertTrue(guide.contains("shasum -a 256 -c"))
        XCTAssertTrue(guide.contains("不包含 CLI 或 ARM 工具链"))
        XCTAssertTrue(guide.contains("未签名、未公证"))
        XCTAssertTrue(guide.contains("不要全局关闭 Gatekeeper"))
    }

    func testReleasePATHConfigurationAppearsOnlyOnce() throws {
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let command = "echo 'export PATH=\"$HOME/Developer/Yagarto_Mac/.build/release:$PATH\"' >> \"$HOME/.zprofile\""
        XCTAssertEqual(guide.components(separatedBy: command).count - 1, 1)
    }

    private var guideURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/install-from-github.zh-CN.md")
    }

    private func index(of marker: String, in guide: String) throws -> String.Index {
        try XCTUnwrap(guide.range(of: marker), "安装文档缺少：\(marker)").lowerBound
    }
}
