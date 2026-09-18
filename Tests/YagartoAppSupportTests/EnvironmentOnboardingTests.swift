// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoAppSupport

final class EnvironmentOnboardingTests: XCTestCase {
    func testEnvironmentSummarySeparatesExactCompatibleAndUnavailableProfiles() {
        let exact = EnvironmentSummary(report: report(arm7: .gdbSimulator, cortex: true, stm32: true))
        XCTAssertTrue(exact.buildToolsAvailable)
        XCTAssertEqual(exact.arm7, .exact)
        XCTAssertEqual(exact.cortexM4, .ready)
        XCTAssertEqual(exact.stm32f4Discovery, .ready)

        let compatible = EnvironmentSummary(
            report: report(arm7: .qemuARM926Compatible, cortex: false, stm32: false)
        )
        XCTAssertEqual(compatible.arm7, .compatible)
        XCTAssertEqual(compatible.cortexM4, .unavailable)
        XCTAssertEqual(compatible.stm32f4Discovery, .unavailable)

        let unavailable = EnvironmentSummary(report: report(arm7: nil, cortex: false, stm32: false))
        XCTAssertEqual(unavailable.arm7, .unavailable)
    }

    func testFirstSuccessProgressRequiresEveryMilestoneInOrderIndependentSet() {
        var progress = FirstSuccessProgress()
        for milestone in FirstSuccessMilestone.allCases.dropLast() {
            progress.record(milestone)
        }
        XCTAssertFalse(progress.isComplete)

        progress.record(.returnedToReady)
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(progress.completed.count, FirstSuccessMilestone.allCases.count)
    }

    func testPreferenceStorePersistsDismissalAndCompletionSeparately() async {
        let suite = "EnvironmentOnboardingTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingPreferenceStore(
            suiteName: suite,
            keyPrefix: "onboarding-v1"
        )

        let initial = await store.state()
        XCTAssertEqual(initial, OnboardingPreferenceState())
        await store.setDismissed(true)
        let dismissed = await store.state()
        XCTAssertEqual(
            dismissed,
            OnboardingPreferenceState(isDismissed: true, isCompleted: false)
        )
        await store.setCompleted(true)
        let completed = await store.state()
        XCTAssertEqual(
            completed,
            OnboardingPreferenceState(isDismissed: true, isCompleted: true)
        )
    }

    private func report(
        arm7: DebugBackend?,
        cortex: Bool,
        stm32: Bool
    ) -> DoctorReport {
        let entries = ToolIdentifier.allCases.map {
            DoctorEntry(tool: $0, required: $0.isRequired, path: $0.isRequired ? "/tool/\($0.rawValue)" : nil)
        }
        return DoctorReport(
            entries: entries,
            normalGDB: DoctorGDBStatus(path: "/tool/gdb", targetSimCapable: false),
            simulatorGDB: DoctorGDBStatus(
                path: arm7 == .gdbSimulator ? "/tool/gdb-sim" : nil,
                targetSimCapable: arm7 == .gdbSimulator
            ),
            debugSelections: [
                DoctorDebugSelection(
                    profile: .arm7tdmi,
                    backend: arm7,
                    gdbExecutable: arm7 == nil ? nil : "/tool/gdb",
                    warnings: arm7 == .qemuARM926Compatible ? ["非精确模型"] : []
                ),
                DoctorDebugSelection(
                    profile: .cortexM4,
                    backend: cortex ? .qemuMPS2AN386 : nil,
                    gdbExecutable: cortex ? "/tool/gdb" : nil,
                    warnings: []
                ),
                DoctorDebugSelection(
                    profile: .stm32f4Discovery,
                    backend: stm32 ? .openOCDSTM32F4Discovery : nil,
                    gdbExecutable: stm32 ? "/tool/gdb" : nil,
                    warnings: []
                )
            ],
            stm32f4BoardConfig: stm32 ? "/tool/stm32f4discovery.cfg" : nil
        )
    }
}

@MainActor
final class AppViewModelOnboardingTests: XCTestCase {
    func testPrepareDismissReopenAndCompleteOnboarding() async throws {
        let fixture = try OnboardingFixture()
        let preferences = MemoryOnboardingPreferenceStore()
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: OnboardingBuildService(project: fixture.directory),
            debugService: OnboardingDebugService(),
            environmentChecker: FixedEnvironmentChecker(
                report: onboardingReport(arm7: .qemuARM926Compatible)
            ),
            onboardingPreferenceStore: preferences
        )

        await model.prepareOnboarding()
        XCTAssertTrue(model.isOnboardingPresented)
        guard case .loaded(let summary) = model.environmentCheckState else {
            return XCTFail("Expected loaded environment")
        }
        XCTAssertEqual(summary.arm7, .compatible)

        await model.dismissOnboarding()
        XCTAssertFalse(model.isOnboardingPresented)
        let dismissed = await preferences.current()
        XCTAssertTrue(dismissed.isDismissed)

        await model.presentOnboarding()
        XCTAssertTrue(model.isOnboardingPresented)

        for milestone in FirstSuccessMilestone.allCases {
            await model.recordFirstSuccess(milestone)
        }
        XCTAssertTrue(model.firstSuccessProgress.isComplete)
        let completed = await preferences.current()
        XCTAssertTrue(completed.isCompleted)

        let relaunched = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: OnboardingBuildService(project: fixture.directory),
            debugService: OnboardingDebugService(),
            environmentChecker: FixedEnvironmentChecker(
                report: onboardingReport(arm7: .qemuARM926Compatible)
            ),
            onboardingPreferenceStore: preferences
        )
        await relaunched.prepareOnboarding()
        XCTAssertFalse(relaunched.isOnboardingPresented)
        XCTAssertTrue(relaunched.firstSuccessProgress.isComplete)
    }
}

private struct OnboardingFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("MOV r0, #1\n".utf8).write(to: directory.appendingPathComponent("main.s"))
        try ConfigStore(projectDirectory: directory).save(ProjectConfiguration(sources: ["main.s"]))
    }
}

private struct FixedEnvironmentChecker: EnvironmentChecking {
    let report: DoctorReport
    func check() async -> DoctorReport { report }
}

private actor MemoryOnboardingPreferenceStore: OnboardingPreferenceStoring {
    private var value = OnboardingPreferenceState()
    func state() -> OnboardingPreferenceState { value }
    func setDismissed(_ dismissed: Bool) {
        value = OnboardingPreferenceState(isDismissed: dismissed, isCompleted: value.isCompleted)
    }
    func setCompleted(_ completed: Bool) {
        value = OnboardingPreferenceState(isDismissed: value.isDismissed, isCompleted: completed)
    }
    func current() -> OnboardingPreferenceState { value }
}

private struct OnboardingBuildService: BuildServicing {
    let project: URL
    func build(projectDirectory: URL) async throws -> AppBuildResult {
        AppBuildResult(
            configuration: try ConfigStore(projectDirectory: project).load(),
            projectDirectory: project,
            elf: project.appendingPathComponent("demo.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
    }
}

private actor OnboardingDebugService: DebugServicing {
    func events() -> AsyncStream<DebuggerEvent> { AsyncStream { $0.finish() } }
    func prepare(_ build: AppBuildResult) async throws {}
    func launch(mode: DebugMode, breakpoints: [DebugSourceBreakpoint]) async throws -> DebugLaunchResult {
        DebugLaunchResult()
    }
    func pause() async throws {}
    func stepInstruction() async throws {}
    func stepOver() async throws {}
    func resume() async throws {}
    func stop() async throws {}
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] { [] }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "\(line)", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}
}

private func onboardingReport(arm7: DebugBackend?) -> DoctorReport {
    DoctorReport(
        entries: ToolIdentifier.allCases.map {
            DoctorEntry(tool: $0, required: $0.isRequired, path: $0.isRequired ? "/tool/\($0.rawValue)" : nil)
        },
        normalGDB: DoctorGDBStatus(path: "/tool/gdb", targetSimCapable: false),
        simulatorGDB: DoctorGDBStatus(path: nil, targetSimCapable: false),
        debugSelections: [
            DoctorDebugSelection(
                profile: .arm7tdmi,
                backend: arm7,
                gdbExecutable: arm7 == nil ? nil : "/tool/gdb",
                warnings: []
            ),
            DoctorDebugSelection(profile: .cortexM4, backend: nil, gdbExecutable: nil, warnings: []),
            DoctorDebugSelection(profile: .stm32f4Discovery, backend: nil, gdbExecutable: nil, warnings: [])
        ]
    )
}
