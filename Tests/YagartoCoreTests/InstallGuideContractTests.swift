// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class InstallGuideContractTests: XCTestCase {
    func testSimulatorAndDoctorAreMandatoryBeforeFirstAppLaunch() throws {
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let simulator = try index(of: "构建 ARM7 指令级 GDB simulator", in: guide)
        let doctor = try index(of: "用 doctor 做安装门槛验收", in: guide)
        let install = try index(of: "将 App 安装到“应用程序”并首次打开", in: guide)
        let firstLaunch = try index(of: "open /Applications/YagartoMacApp.app", in: guide)

        XCTAssertLessThan(simulator, doctor)
        XCTAssertLessThan(doctor, install)
        XCTAssertLessThan(doctor, firstLaunch)
        XCTAssertTrue(guide.contains("Simulator GDB") && guide.contains("失败时停止"))
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
