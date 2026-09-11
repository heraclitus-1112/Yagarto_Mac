// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@MainActor
final class YagartoMacAppUITests: XCTestCase {
    private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            app = nil
        }
    }

    private func launchApplication(arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
    }

    func testEmptyEditBuildErrorDebugStepStopAndRecovery() throws {
        launchApplication()
        XCTAssertTrue(app.otherElements["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()

        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nBAD\n")
        app.buttons["toolbar-build"].click()
        let state = app.descendants(matching: .any)["debugger-state"]

        let buildError = app.buttons["build-diagnostic-2"]
        XCTAssertTrue(buildError.waitForExistence(timeout: 5))
        buildError.click()
        waitForLabelContaining("已定位到第 2 行", element: state)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nMOV r1, #2\n")
        app.buttons["toolbar-build"].click()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-debug"].click()
        waitForLabelContaining("当前执行第 1 行", element: state)

        app.buttons["toolbar-step-instruction"].click()
        waitForLabelContaining("当前执行第 2 行", element: state)
        let register = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "register-row-r0"))
            .firstMatch
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        XCTAssertTrue(register.label.contains("已变化"))

        app.buttons["toolbar-stop"].click()
        waitForLabel("就绪", element: state)
    }

    func testLaunchErrorAndUnexpectedExitRecoverForAnotherSession() throws {
        launchApplication(arguments: ["--ui-testing-recovery"])
        XCTAssertTrue(app.otherElements["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))
        app.buttons["toolbar-build"].click()
        let state = app.descendants(matching: .any)["debugger-state"]
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-debug"].click()
        waitForLabelContaining("测试后端启动失败", element: state)
        waitForLabelContaining("就绪", element: state)

        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: state)
        app.buttons["toolbar-debug"].click()
        waitForLabelContaining("已暂停", element: state)
        waitForLabelContaining("测试调试器意外退出", element: state)
        waitForLabelContaining("就绪", element: state)

        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: state)
        app.buttons["toolbar-debug"].click()
        waitForLabelContaining("已暂停", element: state)
        app.buttons["toolbar-stop"].click()
        waitForLabel("就绪", element: state)
    }

    private func waitForLabel(_ label: String, element: XCUIElement) {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", label, label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func waitForLabelContaining(_ fragment: String, element: XCUIElement) {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            fragment,
            fragment
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
