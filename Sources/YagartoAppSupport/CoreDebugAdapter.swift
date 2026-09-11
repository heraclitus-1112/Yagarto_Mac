// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public actor CoreDebugAdapter: DebugServicing {
    private let overrides: [ToolIdentifier: String]
    private let environment: [String: String]
    private let explicitGDBSimulatorPath: String?
    private var debugPlan: DebugLaunchPlan?
    private var runPlan: DebugLaunchPlan?
    private var controller: DebuggerController?
    private var forwardingTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<DebuggerEvent>.Continuation] = [:]

    public private(set) var preparedBackend: DebugBackend?
    public var preparedModes: [DebugMode] {
        var modes: [DebugMode] = []
        if debugPlan != nil { modes.append(.debug) }
        if runPlan != nil { modes.append(.run) }
        return modes
    }

    public init(
        overrides: [ToolIdentifier: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gdbSimulatorPath: String? = nil
    ) {
        self.overrides = overrides
        self.environment = environment
        explicitGDBSimulatorPath = gdbSimulatorPath
    }

    public func events() -> AsyncStream<DebuggerEvent> {
        let identifier = UUID()
        let pair = AsyncStream<DebuggerEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        subscribers[identifier] = pair.continuation
        return pair.stream
    }

    public func prepare(_ build: AppBuildResult) async throws {
        let resolver = ToolResolver(environment: environment)
        var toolPaths: [ToolIdentifier: String] = [:]
        for tool in ToolIdentifier.allCases {
            if let path = try? resolver.resolve(tool, overrides: overrides) {
                toolPaths[tool] = path
            }
        }
        let simulator: String?
        if let explicitGDBSimulatorPath {
            simulator = explicitGDBSimulatorPath
        } else {
            simulator = try? resolver.resolveGDBSimulator(overrides: overrides)
        }
        let boardConfig: URL?
        if let openOCD = toolPaths[.openOCD],
           let path = try? resolver.resolveSTM32F4BoardConfig(openOCDPath: openOCD) {
            boardConfig = URL(fileURLWithPath: path)
        } else {
            boardConfig = nil
        }
        let planner = DebugPlanner(
            toolPaths: toolPaths,
            gdbSimulatorPath: simulator,
            openOCDBoardConfig: boardConfig
        )
        let debug = try planner.plan(
            mode: .debug,
            configuration: build.configuration,
            elf: build.elf,
            projectDirectory: build.projectDirectory
        )
        let run = try planner.plan(
            mode: .run,
            configuration: build.configuration,
            elf: build.elf,
            projectDirectory: build.projectDirectory
        )
        debugPlan = debug
        runPlan = run
        preparedBackend = debug.backend
    }

    public func launch(mode: DebugMode) async throws {
        let plan: DebugLaunchPlan?
        switch mode {
        case .debug: plan = debugPlan
        case .run: plan = runPlan
        }
        guard let plan else { throw DebuggerControllerError.missingLaunchPlan }
        forwardingTask?.cancel()
        let newController = DebuggerController(plan: plan)
        controller = newController
        let stream = await newController.events()
        forwardingTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.publish(event)
            }
        }
        try await newController.launch()
    }

    public func pause() async throws { try await requiredController().pause() }
    public func stepInstruction() async throws { try await requiredController().stepInstruction() }
    public func stepOver() async throws { try await requiredController().stepOver() }
    public func resume() async throws { try await requiredController().continue() }

    public func stop() async throws {
        guard let controller else { return }
        let state = await controller.currentState
        if state == .launching || state == .stopped || state == .running {
            try await controller.stop()
        }
    }

    public func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        try await requiredController().readMemory(request)
    }

    public func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        guard line > 0 else { throw DebuggerControllerError.invalidBreakpointLocation }
        return try await requiredController().setBreakpoint("\(file.standardizedFileURL.path):\(line)")
    }

    public func removeBreakpoint(identifier: String) async throws {
        try await requiredController().removeBreakpoint(identifier)
    }

    private func requiredController() throws -> DebuggerController {
        guard let controller else { throw DebuggerControllerError.missingLaunchPlan }
        return controller
    }

    private func publish(_ event: DebuggerEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers[identifier] = nil
    }
}
