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
        app.launchEnvironment["YAGARTO_UI_TEST_SESSION"] = "YagartoMacAppUITests"
        app.launch()
    }

    func testEmptyEditBuildErrorDebugStepStopAndRecovery() throws {
        launchApplication()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()

        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nBAD\n")
        app.buttons["toolbar-build"].click()
        let state = app.descendants(matching: .any)["debugger-state"]
        let sourceLocation = app.descendants(matching: .any)["source-location-status"]
        let currentLine = app.descendants(matching: .any)["current-line-status"]

        let buildError = app.buttons["build-diagnostic-2"]
        XCTAssertTrue(buildError.waitForExistence(timeout: 5))
        buildError.click()
        waitForLabel("已定位到第 2 行", element: sourceLocation)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #1\nMOV r1, #2\n")
        app.buttons["toolbar-build"].click()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-debug"].click()
        waitForLabel("已暂停", element: state)
        waitForLabelContaining("当前执行第 1 行", element: currentLine)

        app.buttons["toolbar-step-instruction"].click()
        waitForLabel("已暂停", element: state)
        waitForLabelContaining("当前执行第 2 行", element: currentLine)
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
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))
        app.buttons["toolbar-build"].click()
        let state = app.descendants(matching: .any)["debugger-state"]
        let operationError = app.descendants(matching: .any)["operation-error"]
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-debug"].click()
        waitForLabelContaining("测试后端启动失败", element: operationError)
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: state)
        app.buttons["toolbar-debug"].click()
        waitForLabel("已暂停", element: state)
        waitForLabelContaining("测试调试器意外退出", element: operationError)
        waitForLabel("就绪", element: state)

        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: state)
        app.buttons["toolbar-debug"].click()
        waitForLabel("已暂停", element: state)
        app.buttons["toolbar-stop"].click()
        waitForLabel("就绪", element: state)
    }

    func testCreateProjectOpensRunnableTemplateWithoutAutomaticBuild() throws {
        launchApplication()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["empty-new-project"].click()

        let name = app.textFields["new-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("自动工程")
        app.buttons["new-project-create"].click()

        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let source = editor.value as? String ?? ""
        XCTAssertTrue(source.contains(".global start"))
        waitForLabel("未构建", element: app.descendants(matching: .any)["debugger-state"])
    }

    func testImportSourcesShowsSummaryWithoutOpeningCreatedProject() throws {
        launchApplication()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["empty-import-projects"].click()
        XCTAssertTrue(app.popUpButtons["import-profile-picker"].waitForExistence(timeout: 5))
        app.buttons["import-confirm"].click()

        let summary = app.descendants(matching: .any)["import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.staticTexts["已创建 1 个工程"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].exists)
    }

    func testNewProjectHonoursUnsavedDocumentCancellation() throws {
        launchApplication()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\n@ unsaved")

        app.typeKey("n", modifierFlags: .command)
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()

        XCTAssertTrue(editor.exists)
        XCTAssertFalse(app.textFields["new-project-name"].exists)
    }

    func testMissingEnvironmentCanBeSkippedWithoutBlockingWorkspace() throws {
        launchApplication(arguments: ["--ui-testing-onboarding-missing"])
        let onboarding = app.descendants(matching: .any)["environment-onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ARM7TDMI：不可用"].exists)
        app.buttons["onboarding-skip"].click()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
    }

    func testReadyOnboardingTracksFirstBuildDebugStepAndStop() throws {
        launchApplication(arguments: ["--ui-testing-onboarding-ready"])
        XCTAssertTrue(app.descendants(matching: .any)["environment-onboarding"].waitForExistence(timeout: 5))
        app.buttons["onboarding-open-example"].click()
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))

        let state = app.descendants(matching: .any)["debugger-state"]
        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: state)
        app.buttons["toolbar-debug"].click()
        waitForLabel("已暂停", element: state)
        app.buttons["toolbar-step-instruction"].click()
        waitForLabel("已暂停", element: state)
        app.buttons["toolbar-stop"].click()
        waitForLabel("就绪", element: state)

        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["environment-onboarding"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["停止并返回就绪，已完成"].waitForExistence(timeout: 5))
    }

    func testMultiSourceSidebarPreservesEditsAcrossFilesAndBuildsAfterSaveAll() throws {
        launchApplication()
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()
        let editor = app.textViews["source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["project-sources"].exists)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r0, #10\n")
        app.buttons["source-row-helper.s"].click()
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("MOV r2, #30\n")
        app.buttons["source-row-main.s"].click()
        XCTAssertTrue((editor.value as? String)?.contains("#10") == true)

        app.buttons["toolbar-save"].click()
        app.buttons["toolbar-build"].click()
        waitForLabel("就绪", element: app.descendants(matching: .any)["debugger-state"])
    }

    func testSingleSourceProjectShowsNavigatorAndCanCreateSecondSource() throws {
        launchApplication(arguments: ["--ui-testing-single-source"])
        XCTAssertTrue(app.descendants(matching: .any)["empty-state"].waitForExistence(timeout: 5))
        app.buttons["open-example"].click()

        XCTAssertTrue(app.descendants(matching: .any)["project-sources"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["source-row-main.s"].exists)
        app.descendants(matching: .any)["source-add-menu"].click()
        app.menuItems["new-source"].click()
        let name = app.textFields["new-source-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("helper")
        app.buttons["new-source-create"].click()

        XCTAssertTrue(app.buttons["source-row-helper.s"].waitForExistence(timeout: 10))
    }

    func testNavigatorCopiesRenamesAndTrashesSource() throws {
        launchApplication()
        app.buttons["open-example"].click()
        XCTAssertTrue(app.descendants(matching: .any)["project-sources"].waitForExistence(timeout: 5))

        app.descendants(matching: .any)["source-add-menu"].click()
        app.menuItems["add-existing-sources"].click()
        let copied = app.buttons["source-row-待导入.s"]
        XCTAssertTrue(copied.waitForExistence(timeout: 5))
        let copyNotice = app.alerts.firstMatch
        if copyNotice.waitForExistence(timeout: 2) {
            copyNotice.buttons["好"].click()
        }

        copied.click()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["重命名当前源码…"].click()
        let rename = app.textFields["rename-source-field-待导入.s"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("renamed.s")
        rename.typeKey(.return, modifierFlags: [])

        let renamed = app.buttons["source-row-renamed.s"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        renamed.click()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["将当前源码移到废纸篓"].click()
        XCTAssertTrue(app.alerts.firstMatch.buttons["移到废纸篓"].waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["移到废纸篓"].click()
        XCTAssertFalse(renamed.waitForExistence(timeout: 2))
    }

    func testRecentProjectOpensFromEmptyState() throws {
        launchApplication(arguments: ["--ui-testing-recent"])
        let recent = app.buttons["recent-project-example"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        XCTAssertTrue(app.textViews["source-editor"].waitForExistence(timeout: 5))
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
