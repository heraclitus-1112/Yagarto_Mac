// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoAppSupport
import YagartoCore

@MainActor
struct AppRuntime {
    let model: AppViewModel
    let isUITesting: Bool
    private let exampleInstaller: ExampleWorkspaceInstaller?
#if DEBUG
    private let uiFixture: UITestFixture?
#endif

    var canOpenExample: Bool {
#if DEBUG
        exampleInstaller != nil || uiFixture != nil
#else
        exampleInstaller != nil
#endif
    }

    var projectCreationDefaultParent: URL? {
#if DEBUG
        uiFixture?.projectParent
#else
        nil
#endif
    }

    var projectCreationDefaultProfile: ProfileID? {
#if DEBUG
        uiFixture == nil ? nil : .arm7tdmi
#else
        nil
#endif
    }

    var projectImportInputsOverride: [URL]? {
#if DEBUG
        uiFixture.map { [$0.importSource] }
#else
        nil
#endif
    }

    static func make() -> AppRuntime {
#if DEBUG
        let process = ProcessInfo.processInfo
        let uiTesting = process.arguments.contains { $0 == "--ui-testing" }
            && process.environment["YAGARTO_UI_TEST_SESSION"] == "YagartoMacAppUITests"
        if uiTesting {
            let recoveryScenario = process.arguments.contains {
                $0 == "--ui-testing-recovery"
            }
            do {
                let fixture = try UITestFixture(
                    singleSource: process.arguments.contains("--ui-testing-single-source")
                )
                let onboardingMode: UITestEnvironmentChecker.Mode?
                if process.arguments.contains("--ui-testing-onboarding-ready") {
                    onboardingMode = .ready
                } else if process.arguments.contains("--ui-testing-onboarding-missing") {
                    onboardingMode = .missing
                } else {
                    onboardingMode = nil
                }
                let model = AppViewModel(
                    documentService: LocalDocumentService(),
                    buildService: UITestBuildService(),
                    debugService: UITestDebugService(recoveryScenario: recoveryScenario),
                    recentProjectStore: process.arguments.contains("--ui-testing-recent")
                        ? UITestRecentProjectStore(project: fixture.directory) : nil,
                    environmentChecker: onboardingMode.map(UITestEnvironmentChecker.init(mode:)),
                    onboardingPreferenceStore: onboardingMode == nil
                        ? nil : UITestOnboardingPreferenceStore()
                )
                return AppRuntime(
                    model: model,
                    isUITesting: true,
                    exampleInstaller: nil,
                    uiFixture: fixture
                )
            } catch {
                let model = AppViewModel(
                    documentService: LocalDocumentService(),
                    buildService: UITestBuildService(),
                    debugService: UITestDebugService(recoveryScenario: recoveryScenario)
                )
                model.reportOperationError(error)
                return AppRuntime(
                    model: model,
                    isUITesting: true,
                    exampleInstaller: nil,
                    uiFixture: nil
                )
            }
        }
#endif
        let bundledProject = Bundle.main.resourceURL?
            .appendingPathComponent("examples/arm7tdmi/array-addressing", isDirectory: true)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("YAGARTO Mac", isDirectory: true)
            .appendingPathComponent("Examples", isDirectory: true)
        let installer: ExampleWorkspaceInstaller?
        if let bundledProject,
           let applicationSupport,
           FileManager.default.fileExists(
               atPath: bundledProject.appendingPathComponent("yagarto.json").path
           ) {
            installer = ExampleWorkspaceInstaller(
                bundledProject: bundledProject,
                applicationSupportDirectory: applicationSupport,
                destinationName: "ARM7 多文件数组寻址示例"
            )
        } else {
            installer = nil
        }
        let model = AppViewModel(
            documentService: LocalDocumentService(),
            buildService: CoreBuildService(),
            debugService: CoreDebugAdapter(),
            recentProjectStore: UserDefaultsRecentProjectStore(),
            environmentChecker: LocalEnvironmentChecker(),
            onboardingPreferenceStore: UserDefaultsOnboardingPreferenceStore()
        )
#if DEBUG
        return AppRuntime(
            model: model,
            isUITesting: false,
            exampleInstaller: installer,
            uiFixture: nil
        )
#else
        return AppRuntime(
            model: model,
            isUITesting: false,
            exampleInstaller: installer
        )
#endif
    }

    func openExample() async {
        do {
#if DEBUG
            if let uiFixture {
                await model.open(uiFixture.directory)
                await model.recordFirstSuccess(.exampleOpened)
            } else if let exampleInstaller {
                await model.open(try await exampleInstaller.install())
                await model.recordFirstSuccess(.exampleOpened)
            }
#else
            if let exampleInstaller {
                await model.open(try await exampleInstaller.install())
                await model.recordFirstSuccess(.exampleOpened)
            }
#endif
        } catch {
            model.reportOperationError(error)
        }
    }

    func cleanup() {
#if DEBUG
        uiFixture?.cleanup()
#endif
    }
}

#if DEBUG
@MainActor
private final class UITestFixture {
    private let owner: OwnedTemporaryWorkspace
    let directory: URL
    var projectParent: URL { owner.directory }
    let importSource: URL

    init(singleSource: Bool = false) throws {
        owner = try OwnedTemporaryWorkspace.create(prefix: "YagartoMacApp-UI")
        directory = owner.directory.appendingPathComponent("example", isDirectory: true)
        importSource = owner.directory.appendingPathComponent("待导入.s")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let configuration = ProjectConfiguration(
                profile: .arm7tdmi,
                entry: "start",
                sources: singleSource ? ["main.s"] : ["main.s", "helper.s"],
                outputName: "ui-fixture"
            )
            try ConfigStore(projectDirectory: directory).save(configuration)
            try Data("MOV r0, #1\nMOV r1, #2\n".utf8)
                .write(to: directory.appendingPathComponent("main.s"), options: .atomic)
            if !singleSource {
                try Data("MOV r2, #3\n".utf8)
                    .write(to: directory.appendingPathComponent("helper.s"), options: .atomic)
            }
            try Data(".global start\nstart:\n    b start\n".utf8)
                .write(to: importSource, options: .atomic)
        } catch {
            _ = try? owner.cleanup()
            throw error
        }
    }

    func cleanup() {
        _ = try? owner.cleanup()
    }
}

private struct UITestEnvironmentChecker: EnvironmentChecking {
    enum Mode { case ready, missing }
    let mode: Mode

    func check() async -> DoctorReport {
        let ready = mode == .ready
        return DoctorReport(
            entries: ToolIdentifier.allCases.map { tool in
                DoctorEntry(
                    tool: tool,
                    required: tool.isRequired,
                    path: ready || !tool.isRequired ? "/ui-tools/\(tool.rawValue)" : nil
                )
            },
            normalGDB: DoctorGDBStatus(path: ready ? "/ui-tools/gdb" : nil, targetSimCapable: false),
            simulatorGDB: DoctorGDBStatus(
                path: ready ? "/ui-tools/gdb-sim" : nil,
                targetSimCapable: ready
            ),
            debugSelections: [
                DoctorDebugSelection(
                    profile: .arm7tdmi,
                    backend: ready ? .gdbSimulator : nil,
                    gdbExecutable: ready ? "/ui-tools/gdb-sim" : nil,
                    warnings: []
                ),
                DoctorDebugSelection(
                    profile: .cortexM4,
                    backend: ready ? .qemuMPS2AN386 : nil,
                    gdbExecutable: ready ? "/ui-tools/gdb" : nil,
                    warnings: []
                ),
                DoctorDebugSelection(
                    profile: .stm32f4Discovery,
                    backend: ready ? .openOCDSTM32F4Discovery : nil,
                    gdbExecutable: ready ? "/ui-tools/gdb" : nil,
                    warnings: []
                )
            ],
            stm32f4BoardConfig: ready ? "/ui-tools/stm32f4discovery.cfg" : nil
        )
    }
}

private actor UITestOnboardingPreferenceStore: OnboardingPreferenceStoring {
    private var preference = OnboardingPreferenceState()
    func state() -> OnboardingPreferenceState { preference }
    func setDismissed(_ value: Bool) {
        preference = OnboardingPreferenceState(
            isDismissed: value,
            isCompleted: preference.isCompleted
        )
    }
    func setCompleted(_ value: Bool) {
        preference = OnboardingPreferenceState(
            isDismissed: preference.isDismissed,
            isCompleted: value
        )
    }
}

private actor UITestRecentProjectStore: RecentProjectStoring {
    private var values: [RecentProject]

    init(project: URL) {
        values = [RecentProject(projectURL: project)]
    }

    func projects() -> [RecentProject] { values }
    func record(_ projectURL: URL) -> [RecentProject] {
        let project = RecentProject(projectURL: projectURL)
        values.removeAll { $0.canonicalPath == project.canonicalPath }
        values.insert(project, at: 0)
        return values
    }
    func remove(_ projectURL: URL) -> [RecentProject] {
        let path = RecentProject(projectURL: projectURL).canonicalPath
        values.removeAll { $0.canonicalPath == path }
        return values
    }
    func clear() { values = [] }
}

private actor UITestBuildService: BuildServicing {
    func build(projectDirectory: URL) async throws -> AppBuildResult {
        let configuration = try ConfigStore(projectDirectory: projectDirectory).load()
        let source = projectDirectory.appendingPathComponent(configuration.sources[0])
        let text = try String(contentsOf: source, encoding: .utf8)
        if let badRange = text.range(of: "BAD") {
            let utf16Offset = text.utf16.distance(from: text.utf16.startIndex, to: badRange.lowerBound.samePosition(in: text.utf16)!)
            let line = SourceLineMap(text).lineNumber(atUTF16Offset: utf16Offset)
            let diagnostic = BuildDiagnostic(
                severity: .error,
                file: source,
                line: line,
                column: 1,
                message: "测试后端检测到无效指令 BAD"
            )
            throw BuildServiceFailure(
                message: "构建失败：请修正标记为 BAD 的测试指令。",
                diagnostics: [diagnostic],
                output: "\(source.path):\(line): Error: bad instruction"
            )
        }
        let outputDirectory = projectDirectory.appendingPathComponent(".yagarto/ui-testing", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let elf = outputDirectory.appendingPathComponent("ui-fixture.elf")
        try Data("deterministic ui fixture".utf8).write(to: elf, options: .atomic)
        return AppBuildResult(
            configuration: configuration,
            projectDirectory: projectDirectory,
            elf: elf,
            artifacts: [elf],
            diagnostics: [],
            output: "UI 测试构建完成"
        )
    }
}

private actor UITestDebugService: DebugServicing {
    private let stream: AsyncStream<DebuggerEvent>
    private let continuation: AsyncStream<DebuggerEvent>.Continuation
    private var build: AppBuildResult?
    private let recoveryScenario: Bool
    private var launchAttempt = 0

    init(recoveryScenario: Bool = false) {
        let pair = AsyncStream<DebuggerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        stream = pair.stream
        continuation = pair.continuation
        self.recoveryScenario = recoveryScenario
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws { self.build = build }

    func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        guard build != nil else { throw DebuggerControllerError.missingLaunchPlan }
        launchAttempt += 1
        if recoveryScenario, launchAttempt == 1 {
            throw UITestBackendError.launchFailed
        }
        continuation.yield(.stateChanged(.stopped))
        continuation.yield(.snapshot(snapshot(line: 1, r0: 1)))
        var identifiers: [Int: String] = [:]
        let bindings = breakpoints.map { breakpoint in
            let identifier = "\(breakpoint.file.lastPathComponent):\(breakpoint.line)"
            identifiers[breakpoint.line] = identifier
            return DebugBreakpointBinding(breakpoint: breakpoint, identifier: identifier)
        }
        if recoveryScenario, launchAttempt == 2 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                await self?.emitUnexpectedExit()
            }
        }
        if mode == .run { continuation.yield(.stateChanged(.running)) }
        return DebugLaunchResult(
            breakpointIdentifiers: identifiers,
            breakpointBindings: bindings
        )
    }

    func pause() async throws { continuation.yield(.stateChanged(.stopped)) }
    func stepInstruction() async throws { continuation.yield(.snapshot(snapshot(line: 2, r0: 2))) }
    func stepOver() async throws { continuation.yield(.snapshot(snapshot(line: 2, r0: 2))) }
    func resume() async throws { continuation.yield(.stateChanged(.running)) }
    func stop() async throws {
        continuation.yield(.stateChanged(.terminating))
        continuation.yield(.stateChanged(.ready))
    }
    func setMemoryRequest(_ request: DebugMemoryRequest) async throws {}
    func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        [MIMemoryBlock(
            begin: MIRawNumeric(raw: request.address),
            offset: MIRawNumeric(raw: "0x0", numeric: 0),
            end: MIRawNumeric(raw: "0x\(String(request.byteCount, radix: 16))", numeric: UInt64(request.byteCount)),
            contents: String(repeating: "00", count: request.byteCount)
        )]
    }
    func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        DebugBreakpoint(id: "\(line)", location: "\(file.path):\(line)")
    }
    func removeBreakpoint(identifier: String) async throws {}

    private func emitUnexpectedExit() {
        continuation.yield(.diagnostic(DebugDiagnostic(
            pane: .session,
            isCritical: true,
            message: "测试调试器意外退出"
        )))
        continuation.yield(.stateChanged(.terminating))
        continuation.yield(.stateChanged(.ready))
    }

    private func snapshot(line: UInt64, r0: UInt64) -> DebugSnapshot {
        let source = build?.projectDirectory.appendingPathComponent("main.s")
        let registers = (0...15).map { index in
            let value = index == 0 ? r0 : UInt64(index)
            return DebugRegister(
                name: "r\(index)",
                number: index,
                value: MIRawNumeric(raw: "0x\(String(value, radix: 16))", numeric: value)
            )
        } + [DebugRegister(name: "CPSR", number: 16, value: MIRawNumeric(raw: "0x60000013", numeric: 0x60000013))]
        return DebugSnapshot(
            stopReason: .endSteppingRange,
            location: MIFrame(
                address: MIRawNumeric(raw: "0x\(String(0x100 + line * 4, radix: 16))", numeric: 0x100 + line * 4),
                function: "start",
                file: "main.s",
                fullName: source?.path,
                line: MIRawNumeric(raw: "\(line)", numeric: line)
            ),
            registers: registers,
            stack: [],
            memory: [],
            disassembly: [MIInstruction(
                address: MIRawNumeric(raw: "0x104", numeric: 0x104),
                function: "start",
                offset: MIRawNumeric(raw: "0", numeric: 0),
                instruction: line == 1 ? "mov r0, #1" : "mov r1, #2"
            )],
            console: [DebugConsoleEntry(channel: .console, text: "确定性 UI 调试后端")],
            diagnostics: []
        )
    }
}

private enum UITestBackendError: Error, LocalizedError {
    case launchFailed

    var errorDescription: String? {
        "测试后端启动失败；可以修正后重新构建并启动。"
    }
}
#endif
