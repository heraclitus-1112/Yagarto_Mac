// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import YagartoAppSupport
import YagartoCore

@MainActor
struct AppRuntime {
    let model: AppViewModel
    let exampleURL: URL?
    let isUITesting: Bool

    static func make() -> AppRuntime {
        let uiTesting = ProcessInfo.processInfo.arguments.contains { $0 == "--ui-testing" }
        if uiTesting {
            let fixture = try! UITestFixture()
            return AppRuntime(
                model: AppViewModel(
                    documentService: LocalDocumentService(),
                    buildService: UITestBuildService(),
                    debugService: UITestDebugService()
                ),
                exampleURL: fixture.directory,
                isUITesting: true
            )
        }
        return AppRuntime(
            model: AppViewModel(
                documentService: LocalDocumentService(),
                buildService: CoreBuildService(),
                debugService: CoreDebugAdapter()
            ),
            exampleURL: nil,
            isUITesting: false
        )
    }
}

private struct UITestFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YagartoMacApp-UI-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["main.s"],
            outputName: "ui-fixture"
        )
        try ConfigStore(projectDirectory: directory).save(configuration)
        try Data("MOV r0, #1\nMOV r1, #2\n".utf8)
            .write(to: directory.appendingPathComponent("main.s"), options: .atomic)
    }
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

    init() {
        let pair = AsyncStream<DebuggerEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<DebuggerEvent> { stream }
    func prepare(_ build: AppBuildResult) async throws { self.build = build }

    func launch(mode: DebugMode) async throws {
        guard build != nil else { throw DebuggerControllerError.missingLaunchPlan }
        continuation.yield(.stateChanged(.stopped))
        continuation.yield(.snapshot(snapshot(line: 1, r0: 1)))
    }

    func pause() async throws { continuation.yield(.stateChanged(.stopped)) }
    func stepInstruction() async throws { continuation.yield(.snapshot(snapshot(line: 2, r0: 2))) }
    func stepOver() async throws { continuation.yield(.snapshot(snapshot(line: 2, r0: 2))) }
    func resume() async throws { continuation.yield(.stateChanged(.running)) }
    func stop() async throws {
        continuation.yield(.stateChanged(.terminating))
        continuation.yield(.stateChanged(.ready))
    }
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
