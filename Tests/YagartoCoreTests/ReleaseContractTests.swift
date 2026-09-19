// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class ReleaseContractTests: XCTestCase {
    func testProductVersionsAreUnifiedAtZeroSixZero() throws {
        let appPlist = try propertyList(at: "App/Info.plist")
        XCTAssertEqual(appPlist["CFBundleShortVersionString"] as? String, "0.6.0")
        XCTAssertEqual(appPlist["CFBundleVersion"] as? String, "6")

        let project = try contents(of: "YagartoMacApp.xcodeproj/project.pbxproj")
        XCTAssertEqual(project.components(separatedBy: "MARKETING_VERSION = 0.6.0;").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "CURRENT_PROJECT_VERSION = 6;").count - 1, 2)

        let cli = try contents(of: "Sources/YagartoMacCLI/RootCommand.swift")
        XCTAssertTrue(cli.contains(#"version: "0.6.0""#))

        let app = try contents(of: "Sources/YagartoMacApp/YagartoMacApp.swift")
        XCTAssertFalse(app.contains(#"applicationVersion: "0.5.0""#))
        XCTAssertTrue(app.contains("CFBundleShortVersionString"))

        let buildScript = try contents(of: "scripts/build-app.sh")
        XCTAssertFalse(buildScript.contains(#"= "0.5.0""#))
        XCTAssertTrue(buildScript.contains("expected_marketing_version"))
    }

    func testReleaseWorkflowHasVersionAuditArchiveChecksumAndLeastPrivilege() throws {
        let workflow = try contents(of: ".github/workflows/release.yml")
        XCTAssertTrue(workflow.contains("tags:"))
        XCTAssertTrue(workflow.contains("- 'v*'"))
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("actions/checkout@v7"))
        XCTAssertTrue(workflow.contains("fetch-depth: 0"))
        XCTAssertTrue(workflow.contains("scripts/build-app.sh Release"))
        XCTAssertTrue(workflow.contains("scripts/audit-release-no-fakes.sh"))
        XCTAssertTrue(workflow.contains("scripts/package-release.sh"))
        XCTAssertTrue(workflow.contains("gh release create"))
        XCTAssertTrue(workflow.contains("--verify-tag"))
        XCTAssertFalse(workflow.localizedCaseInsensitiveContains("personal_access_token"))
    }

    func testReleasePackagingScriptValidatesTagAndProducesFixedArtifacts() throws {
        let script = try contents(of: "scripts/package-release.sh")
        XCTAssertTrue(script.contains(#"^v[0-9]+\.[0-9]+\.[0-9]+$"#))
        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains("ditto"))
        XCTAssertTrue(script.contains("--keepParent"))
        XCTAssertTrue(script.contains("SHA256SUMS.txt"))
        XCTAssertTrue(script.contains("YagartoMacApp-${version}-macOS-arm64.zip"))
    }

    func testXcodeReleaseTargetIncludesNavigatorActionsAndEveryExampleSource() throws {
        let project = try contents(of: "YagartoMacApp.xcodeproj/project.pbxproj")
        for required in [
            "ProjectNavigatorView.swift in Sources",
            "ProjectSourceActions.swift in Sources",
            "numbers.s in Copy Bundled Example"
        ] {
            XCTAssertTrue(project.contains(required), "Xcode Release target missing \(required)")
        }

        let buildScript = try contents(of: "scripts/build-app.sh")
        XCTAssertTrue(buildScript.contains(#"numbers.s" "$bundled_example/numbers.s"#))
    }

    func testXCUITestSchemeExpandsAgainstAppAndFailureReportingUsesBracedStatus() throws {
        let scheme = try contents(
            of: "YagartoMacApp.xcodeproj/xcshareddata/xcschemes/YagartoMacApp.xcscheme"
        )
        XCTAssertTrue(scheme.contains("<MacroExpansion>"))
        XCTAssertTrue(scheme.contains(#"BuildableName="YagartoMacApp.app""#))

        let script = try contents(of: "scripts/test-app.sh")
        XCTAssertTrue(script.contains(#"FAIL（状态 ${xcode_status}）"#))
        XCTAssertFalse(script.contains(#"FAIL（状态 $xcode_status）"#))
        XCTAssertTrue(script.contains("CODE_SIGNING_ALLOWED=YES"))
        XCTAssertTrue(script.contains("CODE_SIGNING_REQUIRED=YES"))
        XCTAssertTrue(script.contains("CODE_SIGN_IDENTITY=-"))
        XCTAssertFalse(script.contains("CODE_SIGNING_ALLOWED=NO"))
    }

    func testXcodeUITestHostTargetDoesNotCollideWithSwiftPackageProduct() throws {
        let project = try contents(of: "YagartoMacApp.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("name = YagartoMacDesktopApp;"))
        XCTAssertTrue(project.contains("productName = YagartoMacApp;"))
        XCTAssertTrue(project.contains("TEST_TARGET_NAME = YagartoMacDesktopApp;"))

        let scheme = try contents(
            of: "YagartoMacApp.xcodeproj/xcshareddata/xcschemes/YagartoMacApp.xcscheme"
        )
        XCTAssertTrue(scheme.contains(#"BuildableName="YagartoMacApp.app" BlueprintName="YagartoMacDesktopApp""#))
    }

    func testQEMUSmokeRunsOnlyOnMainWithReadOnlyPermissionsAndHardToolChecks() throws {
        let workflow = try contents(of: ".github/workflows/qemu-smoke.yml")
        XCTAssertTrue(workflow.contains("branches: [main]"))
        XCTAssertFalse(workflow.contains("pull_request:"))
        XCTAssertTrue(workflow.contains("contents: read"))
        XCTAssertFalse(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("runs-on: macos-26"))
        XCTAssertTrue(workflow.contains("actions/checkout@v7"))
        XCTAssertTrue(workflow.contains("brew install arm-none-eabi-gcc arm-none-eabi-gdb qemu"))
        XCTAssertTrue(workflow.contains("scripts/test-qemu-smoke.sh"))

        let script = try contents(of: "scripts/test-qemu-smoke.sh")
        for tool in [
            "arm-none-eabi-as", "arm-none-eabi-ld", "arm-none-eabi-objcopy",
            "arm-none-eabi-objdump", "arm-none-eabi-gdb", "qemu-system-arm"
        ] {
            XCTAssertTrue(script.contains("command -v \(tool)"), "缺少硬检查：\(tool)")
        }
        XCTAssertTrue(script.contains("ARM7QEMUFallbackE2ETests"))
        XCTAssertTrue(script.contains("testRequiredQEMUMachinesWhenQEMUIsInstalled"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func propertyList(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }
}
