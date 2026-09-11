// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import YagartoCore

final class CoreModelTests: XCTestCase {
    func testOutputFormatsHaveStableRawValues() {
        XCTAssertEqual(OutputFormat.text.rawValue, "text")
        XCTAssertEqual(OutputFormat.json.rawValue, "json")
    }

    func testExitCodesMatchPublicContract() {
        XCTAssertEqual(YagartoExitCode.success.rawValue, 0)
        XCTAssertEqual(YagartoExitCode.usage.rawValue, 2)
        XCTAssertEqual(YagartoExitCode.configuration.rawValue, 3)
        XCTAssertEqual(YagartoExitCode.buildFailure.rawValue, 4)
        XCTAssertEqual(YagartoExitCode.missingTool.rawValue, 5)
        XCTAssertEqual(YagartoExitCode.unsupported.rawValue, 6)
        XCTAssertEqual(YagartoExitCode.hangup.rawValue, 129)
        XCTAssertEqual(YagartoExitCode.interrupted.rawValue, 130)
        XCTAssertEqual(YagartoExitCode.terminated.rawValue, 143)
    }

    func testErrorsProvideActionableChineseMessageAndExitCode() {
        let error = YagartoError.toolNotFound("arm-none-eabi-as")

        XCTAssertTrue(error.localizedDescription.contains("arm-none-eabi-as"))
        XCTAssertTrue(error.localizedDescription.contains("安装"))
        XCTAssertEqual(error.exitCode, .missingTool)
    }
}
