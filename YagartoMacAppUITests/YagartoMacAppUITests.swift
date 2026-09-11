// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

final class YagartoMacAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    func testEmptyEditBuildErrorDebugStepStopAndRecovery() throws {
        XCTAssertTrue(app.otherElements["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()

        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nBAD\n")
        app.buttons["toolbar-build"].click()

        let buildError = app.buttons["build-diagnostic-2"]
        XCTAssertTrue(buildError.waitForExistence(timeout: 5))
        buildError.click()
        let location = app.descendants(matching: .any)["source-location-status"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertEqual(location.label, "已定位到第 2 行")

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nMOV r1, #2\n")
        app.buttons["toolbar-build"].click()
        let state = app.descendants(matching: .any)["debugger-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-debug"].click()
        let currentLine = app.descendants(matching: .any)["current-line-status"]
        XCTAssertTrue(currentLine.waitForExistence(timeout: 5))
        waitForLabel("当前执行第 1 行", element: currentLine)

        app.buttons["toolbar-step-instruction"].click()
        waitForLabel("当前执行第 2 行", element: currentLine)
        let register = app.descendants(matching: .any)["register-row-r0"]
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        XCTAssertTrue(register.label.contains("已变化"))

        app.buttons["toolbar-stop"].click()
        waitForLabel("就绪", element: state)
    }

    private func waitForLabel(_ label: String, element: XCUIElement) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
