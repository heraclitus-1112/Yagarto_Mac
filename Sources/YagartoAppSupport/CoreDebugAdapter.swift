// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public actor CoreDebugAdapter: DebugServicing {
    private struct SessionRecord {
        let identifier: UInt64
        let controller: DebuggerController
        let forwardingTask: Task<Void, Never>
        let memoryRequestValidity: DebugSessionValidity
    }

    private let overrides: [ToolIdentifier: String]
    private let environment: [String: String]
    private let explicitGDBSimulatorPath: String?
    private let postStopSessionSynchronization: (@Sendable () async -> Void)?
    private let memoryRequestApplicator: @Sendable (
        DebuggerController,
        DebugMemoryRequest,
        DebugSessionValidity
    ) async throws -> Void
    private let memoryReader: @Sendable (
        DebuggerController,
        DebugMemoryRequest,
        DebugSessionValidity
    ) async throws -> [MIMemoryBlock]
    private var debugPlan: DebugLaunchPlan?
    private var runPlan: DebugLaunchPlan?
    private var nextSessionIdentifier: UInt64 = 0
    private var activeSession: SessionRecord?
    private var cleanupTasks: [UInt64: Task<Void, Error>] = [:]
    private var pendingMemoryRequest = DebugMemoryRequest.yagartoWindow
    private var memoryRequestRevision: UInt64 = 0
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
        postStopSessionSynchronization = nil
        memoryRequestApplicator = { controller, request, validity in
            try await controller.setMemoryRequest(
                request,
                validity: validity
            )
        }
        memoryReader = { controller, request, validity in
            try await controller.readMemory(request, validity: validity)
        }
    }

    init(
        overrides: [ToolIdentifier: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gdbSimulatorPath: String? = nil,
        postStopSessionSynchronization: @escaping @Sendable () async -> Void
    ) {
        self.overrides = overrides
        self.environment = environment
        explicitGDBSimulatorPath = gdbSimulatorPath
        self.postStopSessionSynchronization = postStopSessionSynchronization
        memoryRequestApplicator = { controller, request, validity in
            try await controller.setMemoryRequest(
                request,
                validity: validity
            )
        }
        memoryReader = { controller, request, validity in
            try await controller.readMemory(request, validity: validity)
        }
    }

    init(
        overrides: [ToolIdentifier: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        gdbSimulatorPath: String? = nil,
        memoryRequestApplicator: @escaping @Sendable (
            DebuggerController,
            DebugMemoryRequest,
            DebugSessionValidity
        ) async throws -> Void,
        memoryReader: @escaping @Sendable (
            DebuggerController,
            DebugMemoryRequest,
            DebugSessionValidity
        ) async throws -> [MIMemoryBlock]
    ) {
        self.overrides = overrides
        self.environment = environment
        explicitGDBSimulatorPath = gdbSimulatorPath
        postStopSessionSynchronization = nil
        self.memoryRequestApplicator = memoryRequestApplicator
        self.memoryReader = memoryReader
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

    public func launch(
        mode: DebugMode,
        breakpoints: [DebugSourceBreakpoint]
    ) async throws -> DebugLaunchResult {
        // Always enter through the stopped debug plan so source breakpoints exist
        // before a user-requested run is allowed to continue.
        guard let plan = debugPlan else { throw DebuggerControllerError.missingLaunchPlan }
        if let previousSession = activeSession {
            try await stopSession(previousSession)
        }
        let newController = DebuggerController(plan: plan)
        let stream = await newController.events()
        nextSessionIdentifier &+= 1
        let identifier = nextSessionIdentifier
        let forwardingTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.publish(event, from: identifier)
            }
        }
        let record = SessionRecord(
            identifier: identifier,
            controller: newController,
            forwardingTask: forwardingTask,
            memoryRequestValidity: DebugSessionValidity()
        )
        activeSession = record
        do {
            let request = pendingMemoryRequest
            let requestRevision = memoryRequestRevision
            try await applyMemoryRequest(request, to: record)
            try await reconcileMemoryRequest(
                afterApplying: requestRevision,
                to: record
            )
            try requireActive(record)
            try await newController.launch()
            try requireActive(record)
            try await waitUntilStopped(newController)
            try requireActive(record)
            let synchronization = await synchronize(
                breakpoints,
                controller: newController,
                projectDirectory: URL(fileURLWithPath: plan.projectDirectory, isDirectory: true)
            )
            try requireActive(record)
            if mode == .run { try await newController.continue() }
            return synchronization
        } catch {
            try? await stopSession(record)
            throw error
        }
    }

    public func pause() async throws { try await requiredController().pause() }
    public func stepInstruction() async throws { try await requiredController().stepInstruction() }
    public func stepOver() async throws { try await requiredController().stepOver() }
    public func resume() async throws { try await requiredController().continue() }

    public func stop() async throws {
        let requestRevision = memoryRequestRevision
        guard let activeSession else {
            resetPendingMemoryRequest(ifUnchanged: requestRevision)
            return
        }
        do {
            try await stopSession(activeSession)
            if let postStopSessionSynchronization {
                await postStopSessionSynchronization()
            }
            resetPendingMemoryRequest(
                ifUnchanged: requestRevision,
                stoppedSessionIdentifier: activeSession.identifier
            )
        } catch {
            resetPendingMemoryRequest(
                ifUnchanged: requestRevision,
                stoppedSessionIdentifier: activeSession.identifier
            )
            throw error
        }
    }

    public func setMemoryRequest(_ request: DebugMemoryRequest) async throws {
        let requestRevision = try rememberMemoryRequest(request)
        guard let activeSession else { return }
        try await applyMemoryRequest(request, to: activeSession)
        try await reconcileMemoryRequest(
            afterApplying: requestRevision,
            to: activeSession
        )
    }

    public func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        let requestRevision = try rememberMemoryRequest(request)
        guard let activeSession else { throw DebuggerControllerError.missingLaunchPlan }
        let memory: [MIMemoryBlock]
        do {
            memory = try await memoryReader(
                activeSession.controller,
                request,
                activeSession.memoryRequestValidity
            )
        } catch let readError {
            do {
                try await reconcileMemoryRequest(
                    afterApplying: nil,
                    to: activeSession
                )
            } catch let synchronizationError {
                publish(.diagnostic(DebugDiagnostic(
                    pane: .memory,
                    isCritical: false,
                    message: "内存读取失败后同步请求失败：\(synchronizationError.localizedDescription)"
                )), from: activeSession.identifier)
            }
            throw readError
        }
        try await reconcileMemoryRequest(
            afterApplying: requestRevision,
            to: activeSession
        )
        return memory
    }

    public func setBreakpoint(file: URL, line: Int) async throws -> DebugBreakpoint {
        guard line > 0 else { throw DebuggerControllerError.invalidBreakpointLocation }
        return try await requiredController().setBreakpoint("\(file.standardizedFileURL.path):\(line)")
    }

    public func removeBreakpoint(identifier: String) async throws {
        try await requiredController().removeBreakpoint(identifier)
    }

    private func requiredController() throws -> DebuggerController {
        guard let activeSession else { throw DebuggerControllerError.missingLaunchPlan }
        return activeSession.controller
    }

    private func publish(_ event: DebuggerEvent, from sessionIdentifier: UInt64) {
        guard activeSession?.identifier == sessionIdentifier else { return }
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers[identifier] = nil
    }

    private func resetPendingMemoryRequest(
        ifUnchanged revision: UInt64,
        stoppedSessionIdentifier: UInt64? = nil
    ) {
        guard memoryRequestRevision == revision else { return }
        if let stoppedSessionIdentifier,
           let activeSession,
           activeSession.identifier != stoppedSessionIdentifier {
            return
        }
        pendingMemoryRequest = .yagartoWindow
        memoryRequestRevision &+= 1
    }

    @discardableResult
    private func rememberMemoryRequest(_ request: DebugMemoryRequest) throws -> UInt64 {
        try Self.validate(request)
        pendingMemoryRequest = request
        memoryRequestRevision &+= 1
        return memoryRequestRevision
    }

    private func reconcileMemoryRequest(
        afterApplying appliedRevision: UInt64?,
        to session: SessionRecord
    ) async throws {
        var appliedRevision = appliedRevision
        while activeSession?.identifier == session.identifier,
              appliedRevision != memoryRequestRevision {
            let request = pendingMemoryRequest
            let revision = memoryRequestRevision
            try await applyMemoryRequest(request, to: session)
            guard activeSession?.identifier == session.identifier else { return }
            appliedRevision = revision
        }
    }

    private func applyMemoryRequest(
        _ request: DebugMemoryRequest,
        to session: SessionRecord
    ) async throws {
        try await memoryRequestApplicator(
            session.controller,
            request,
            session.memoryRequestValidity
        )
    }

    private func waitUntilStopped(_ controller: DebuggerController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            switch await controller.currentState {
            case .stopped:
                return
            case .ready, .idle, .building, .terminating:
                throw DebuggerControllerError.commandTimedOut("等待调试入口停止")
            case .launching, .running:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw DebuggerControllerError.commandTimedOut("等待调试入口停止")
    }

    private func synchronize(
        _ breakpoints: [DebugSourceBreakpoint],
        controller: DebuggerController,
        projectDirectory: URL
    ) async -> DebugLaunchResult {
        var identifiers: [Int: String] = [:]
        var bindings: [DebugBreakpointBinding] = []
        var failures: [DebugBreakpointSyncFailure] = []
        for breakpoint in breakpoints.sorted(by: { $0.line < $1.line }) {
            do {
                let location = try Self.safeLocation(
                    for: breakpoint,
                    projectDirectory: projectDirectory
                )
                let remote = try await controller.setBreakpoint(location)
                identifiers[breakpoint.line] = remote.id
                bindings.append(DebugBreakpointBinding(
                    breakpoint: breakpoint,
                    identifier: remote.id
                ))
            } catch {
                failures.append(DebugBreakpointSyncFailure(
                    breakpoint: breakpoint,
                    message: error.localizedDescription
                ))
            }
        }
        return DebugLaunchResult(
            breakpointIdentifiers: identifiers,
            breakpointBindings: bindings,
            failures: failures
        )
    }

    private static func safeLocation(
        for breakpoint: DebugSourceBreakpoint,
        projectDirectory: URL
    ) throws -> String {
        guard breakpoint.line > 0 else {
            throw DebuggerControllerError.invalidBreakpointLocation
        }
        let project = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        let source = breakpoint.file.resolvingSymlinksInPath().standardizedFileURL
        let prefix = project.path.hasSuffix("/") ? project.path : project.path + "/"
        guard source.path.hasPrefix(prefix) else {
            throw DebuggerControllerError.invalidBreakpointLocation
        }
        return "\(source.path):\(breakpoint.line)"
    }

    private static func validate(_ request: DebugMemoryRequest) throws {
        let pattern = #"^[A-Za-z0-9_$+*/().-]+$"#
        guard request.byteCount > 0,
              request.byteCount <= 1_048_576,
              request.address.range(of: pattern, options: .regularExpression) != nil else {
            throw DebuggerControllerError.invalidMemoryRequest
        }
    }

    private func requireActive(_ record: SessionRecord) throws {
        guard activeSession?.identifier == record.identifier else {
            throw CancellationError()
        }
    }

    private func stopSession(_ record: SessionRecord) async throws {
        record.memoryRequestValidity.invalidate()
        let cleanupTask: Task<Void, Error>
        if let existing = cleanupTasks[record.identifier] {
            cleanupTask = existing
        } else {
            let controller = record.controller
            cleanupTask = Task {
                let state = await controller.currentState
                if state == .launching || state == .stopped || state == .running {
                    try await controller.stop()
                }
            }
            cleanupTasks[record.identifier] = cleanupTask
        }
        do {
            try await cleanupTask.value
            await finishCleanup(record)
        } catch {
            await finishCleanup(record)
            throw error
        }
    }

    private func finishCleanup(_ record: SessionRecord) async {
        cleanupTasks[record.identifier] = nil
        if activeSession?.identifier == record.identifier {
            activeSession = nil
        }
        record.forwardingTask.cancel()
        await record.forwardingTask.value
    }
}
