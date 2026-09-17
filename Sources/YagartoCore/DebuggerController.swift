// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public actor DebuggerController {
    private struct TrackedTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct TrackedRemoteInterrupt {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private struct StoppedContext {
        let record: MIAsyncRecord
        let session: GDBMISession
        let generation: UUID
    }

    private let profile: ProfileID
    private let consoleLimit: Int
    private let eventBufferLimit: Int
    private let snapshotCommandTimeout: Duration
    private let postStartSynchronization: (@Sendable () async -> Void)?
    private var machine: DebuggerStateMachine
    private var plan: DebugLaunchPlan?
    private var session: GDBMISession?
    private var generation = UUID()
    private var sessionEventTask: TrackedTask?
    private var snapshotTasks: [UUID: TrackedTask] = [:]
    private var currentSnapshotTaskID: UUID?
    private var recoveryTask: TrackedTask?
    private var remoteInterruptTask: TrackedRemoteInterrupt?
    private var console: [DebugConsoleEntry] = []
    private var memoryRequest = DebugMemoryRequest.yagartoWindow
    private var memoryRequestRevision: UInt64 = 0
    private var stoppedContext: StoppedContext?
    private var subscribers: [UUID: AsyncStream<DebuggerEvent>.Continuation] = [:]
    private var totalDroppedEvents = 0

    public private(set) var latestSnapshot: DebugSnapshot?

    public init(
        profile: ProfileID,
        consoleLimit: Int = 512,
        eventBufferLimit: Int = 128,
        snapshotCommandTimeout: Duration = .seconds(2)
    ) {
        self.profile = profile
        self.consoleLimit = max(1, consoleLimit)
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.snapshotCommandTimeout = snapshotCommandTimeout
        postStartSynchronization = nil
        machine = DebuggerStateMachine()
    }

    public init(
        plan: DebugLaunchPlan,
        consoleLimit: Int = 512,
        eventBufferLimit: Int = 128,
        snapshotCommandTimeout: Duration = .seconds(2)
    ) {
        profile = plan.profile
        self.plan = plan
        self.consoleLimit = max(1, consoleLimit)
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.snapshotCommandTimeout = snapshotCommandTimeout
        postStartSynchronization = nil
        machine = DebuggerStateMachine(initialState: .ready)
    }

    init(
        plan: DebugLaunchPlan,
        consoleLimit: Int = 512,
        eventBufferLimit: Int = 128,
        snapshotCommandTimeout: Duration = .seconds(2),
        postStartSynchronization: @escaping @Sendable () async -> Void
    ) {
        profile = plan.profile
        self.plan = plan
        self.consoleLimit = max(1, consoleLimit)
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.snapshotCommandTimeout = snapshotCommandTimeout
        self.postStartSynchronization = postStartSynchronization
        machine = DebuggerStateMachine(initialState: .ready)
    }

    public var currentState: DebuggerState { machine.state }

    public func events() -> AsyncStream<DebuggerEvent> {
        let identifier = UUID()
        let pair = AsyncStream<DebuggerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(eventBufferLimit)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        subscribers[identifier] = pair.continuation
        return pair.stream
    }

    public func buildStarted() throws {
        try transition(.buildStarted)
    }

    public func buildSucceeded(plan: DebugLaunchPlan) throws {
        guard plan.profile == profile else {
            throw DebuggerControllerError.profileMismatch(expected: profile, actual: plan.profile)
        }
        try transition(.buildSucceeded)
        self.plan = plan
    }

    public func buildFailed() throws {
        try transition(.buildFailed)
        plan = nil
    }

    public func launch() async throws {
        try Task.checkCancellation()
        guard let plan else { throw DebuggerControllerError.missingLaunchPlan }
        try transition(.launchStarted)
        stoppedContext = nil
        let attemptGeneration = UUID()
        generation = attemptGeneration
        var attemptSession: GDBMISession?
        var attemptEventTask: TrackedTask?
        do {
            await cancelAndAwaitBackgroundTasks()
            try validateLaunchAttempt(attemptGeneration)
            if let staleSession = session {
                session = nil
                await staleSession.shutdown(timeout: .zero)
                try validateLaunchAttempt(attemptGeneration)
            }

            latestSnapshot = nil
            let newSession = GDBMISession(plan: plan)
            attemptSession = newSession
            session = newSession
            let stream = await newSession.events()
            try validateLaunchAttempt(attemptGeneration, session: newSession)
            try await newSession.start()
            try validateLaunchAttempt(attemptGeneration, session: newSession)
            if let postStartSynchronization {
                await postStartSynchronization()
                try validateLaunchAttempt(attemptGeneration, session: newSession)
            }

            let eventTaskID = UUID()
            let eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.receive(
                        event,
                        generation: attemptGeneration,
                        sourceSession: newSession
                    )
                }
                await self?.eventTaskFinished(eventTaskID)
            }
            let trackedEventTask = TrackedTask(id: eventTaskID, task: eventTask)
            attemptEventTask = trackedEventTask
            sessionEventTask = trackedEventTask
            try validateLaunchAttempt(attemptGeneration, session: newSession)
        } catch {
            await rollbackLaunchAttempt(
                generation: attemptGeneration,
                session: attemptSession,
                eventTask: attemptEventTask
            )
            throw error
        }
    }

    public func run() async throws {
        try await `continue`()
    }

    public func `continue`() async throws {
        try requireState(.stopped, operation: "continue")
        _ = try await requiredSession().send("-exec-continue")
    }

    public func pause() async throws {
        try requireState(.running, operation: "pause")
        let activeSession = try requiredSession()
        if plan?.backend == .gdbSimulator {
            try await interruptSimulator(activeSession)
        } else {
            try await interruptRemoteTarget(activeSession)
        }
    }

    public func stepInstruction() async throws {
        try requireState(.stopped, operation: "stepInstruction")
        _ = try await requiredSession().send("-exec-step-instruction")
    }

    public func stepOver() async throws {
        try requireState(.stopped, operation: "stepOver")
        _ = try await requiredSession().send("-exec-next")
    }

    public func stop() async throws {
        let requestRevision = memoryRequestRevision
        defer { resetMemoryRequest(ifUnchanged: requestRevision) }
        stoppedContext = nil
        let stoppedSession = session
        let stoppedBackend = plan?.backend
        var interruptFailure: (any Error)?
        if machine.state == .running, let stoppedSession {
            do {
                switch stoppedBackend {
                case .gdbSimulator:
                try await interruptSimulator(stoppedSession)
                case .qemuARM926Compatible, .qemuMPS2AN386:
                    try await interruptRemoteTarget(stoppedSession)
                case .openOCDSTM32F4Discovery, .none:
                    break
                }
            } catch {
                interruptFailure = error
            }
        }
        stoppedContext = nil
        if machine.state == .ready {
            generation = UUID()
            if let stoppedSession, session === stoppedSession { session = nil }
            await cancelAndAwaitBackgroundTasks()
            if let stoppedSession {
                await terminateQEMUIfNeeded(stoppedSession, backend: stoppedBackend)
                await stoppedSession.shutdown(timeout: .zero)
            }
            return
        }
        try transition(.terminationStarted)
        generation = UUID()
        session = nil
        await cancelAndAwaitBackgroundTasks()
        if let stoppedSession {
            await terminateQEMUIfNeeded(stoppedSession, backend: stoppedBackend)
            await stoppedSession.shutdown(
                timeout: interruptFailure == nil ? .seconds(2) : .zero
            )
        }
        try transition(.terminationCompleted)
        if let interruptFailure { throw interruptFailure }
    }

    public func setMemoryRequest(_ request: DebugMemoryRequest) throws {
        try validate(request)
        commitMemoryRequest(request)
    }

    @discardableResult
    package func setMemoryRequest(
        _ request: DebugMemoryRequest,
        validity: DebugSessionValidity
    ) throws -> Bool {
        try validate(request)
        return validity.performIfActive { commitMemoryRequest(request) }
    }

    public func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        try requireState(.stopped, operation: "readMemory")
        try setMemoryRequest(request)
        return try await readCommittedMemory(request)
    }

    package func readMemory(
        _ request: DebugMemoryRequest,
        validity: DebugSessionValidity
    ) async throws -> [MIMemoryBlock] {
        try validate(request)
        let committed = try validity.performIfActive {
            try requireState(.stopped, operation: "readMemory")
            commitMemoryRequest(request)
        }
        guard committed else { throw CancellationError() }
        return try await readCommittedMemory(request)
    }

    private func commitMemoryRequest(_ request: DebugMemoryRequest) {
        memoryRequest = request
        memoryRequestRevision &+= 1
        guard machine.state == .stopped,
              let stoppedContext,
              isCurrent(stoppedContext.generation, session: stoppedContext.session) else {
            return
        }
        dispatchSnapshot(
            stopped: stoppedContext.record,
            session: stoppedContext.session,
            generation: stoppedContext.generation
        )
    }

    private func readCommittedMemory(
        _ request: DebugMemoryRequest
    ) async throws -> [MIMemoryBlock] {
        let record = try await requiredSession().send(
            "-data-read-memory-bytes \(request.address) \(request.byteCount)"
        )
        return record.memoryBlocks
    }

    public func setBreakpoint(_ location: String) async throws -> DebugBreakpoint {
        try requireState(.stopped, operation: "setBreakpoint")
        guard !location.isEmpty,
              !location.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw DebuggerControllerError.invalidBreakpointLocation
        }
        let record = try await requiredSession().send(
            "-break-insert -- \(Self.quoteMIArgument(location))"
        )
        guard case .tuple(let tuple)? = record.results["bkpt"],
              let identifier = tuple["number"]?.constant else {
            throw DebuggerControllerError.missingBreakpointID
        }
        return DebugBreakpoint(
            id: identifier,
            location: location,
            address: tuple["addr"]?.constant.map { MIRawNumeric(raw: $0) }
        )
    }

    public func removeBreakpoint(_ identifier: String) async throws {
        try requireState(.stopped, operation: "removeBreakpoint")
        guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else {
            throw DebuggerControllerError.invalidBreakpointID
        }
        _ = try await requiredSession().send("-break-delete \(identifier)")
    }

    private func receive(
        _ event: GDBMIEvent,
        generation eventGeneration: UUID,
        sourceSession: GDBMISession
    ) {
        guard isCurrent(eventGeneration, session: sourceSession),
              machine.state != .idle,
              machine.state != .building,
              machine.state != .ready else { return }
        switch event {
        case .asynchronous(let record) where record.kind == .exec && record.asyncClass == "running":
            guard machine.state == .launching || machine.state == .stopped else { return }
            stoppedContext = nil
            try? transition(.inferiorRunning)
            cancelSnapshotTasks()
        case .asynchronous(let record) where record.kind == .exec && record.asyncClass == "stopped":
            guard machine.state == .launching || machine.state == .running else { return }
            try? transition(.inferiorStopped)
            stoppedContext = StoppedContext(
                record: record,
                session: sourceSession,
                generation: eventGeneration
            )
            dispatchSnapshot(
                stopped: record,
                session: sourceSession,
                generation: eventGeneration
            )
        case .console(let text): appendConsole(.init(channel: .console, text: text))
        case .target(let text): appendConsole(.init(channel: .target, text: text))
        case .log(let text): appendConsole(.init(channel: .log, text: text))
        case .stderr(let text): appendConsole(.init(channel: .stderr, text: text))
        case .parseError(let error):
            publishDiagnostic(.init(pane: .session, isCritical: false, message: "MI parse error: \(error)"))
        case .transportError(let error):
            publishDiagnostic(.init(
                pane: .session,
                isCritical: true,
                message: "GDB transport error: \(error)"
            ))
        case .eventsDropped(let total):
            publishDiagnostic(.init(
                pane: .session,
                isCritical: false,
                message: "MI event buffer dropped \(total) event(s)"
            ))
        case .processExited(let termination):
            dispatchRecovery(
                termination,
                session: sourceSession,
                generation: eventGeneration
            )
        case .endOfFile:
            publishDiagnostic(.init(pane: .session, isCritical: true, message: "GDB stdout reached EOF"))
        case .result, .orphanResult, .prompt, .asynchronous:
            break
        }
    }

    private func refreshSnapshot(
        stopped: MIAsyncRecord,
        session: GDBMISession,
        generation snapshotGeneration: UUID,
        taskID: UUID
    ) async {
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }
        var diagnostics: [DebugDiagnostic] = []
        var location = stopped.frame
        var registerNames: [String] = []
        var registerValues: [MIRegisterValue] = []
        var stack: [MIFrame] = []
        var memory: [MIMemoryBlock] = []
        var actualMemoryRequest: DebugMemoryRequest?
        var disassembly: [MIInstruction] = []

        do {
            location = try await sendSnapshotCommand("-stack-info-frame", to: session).frame ?? location
        } catch {
            diagnostics.append(diagnostic(.frame, critical: true, error: error))
        }
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }
        do {
            registerNames = try await sendSnapshotCommand(
                "-data-list-register-names",
                to: session
            ).registerNames
            registerValues = try await sendSnapshotCommand(
                "-data-list-register-values x",
                to: session
            ).registerValues
        } catch {
            diagnostics.append(diagnostic(.registers, critical: true, error: error))
        }
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }
        do {
            stack = try await sendSnapshotCommand("-stack-list-frames", to: session).stackFrames
        } catch {
            diagnostics.append(diagnostic(.stack, critical: false, error: error))
        }
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }
        do {
            let request = memoryRequest
            try validate(request)
            actualMemoryRequest = request
            memory = try await sendSnapshotCommand(
                "-data-read-memory-bytes \(request.address) \(request.byteCount)",
                to: session
            ).memoryBlocks
        } catch {
            diagnostics.append(diagnostic(.memory, critical: false, error: error))
        }
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }
        do {
            disassembly = try await sendSnapshotCommand(
                "-data-disassemble -s \"$pc-32\" -e \"$pc+32\" -- 0",
                to: session
            ).instructions
        } catch {
            diagnostics.append(diagnostic(.disassembly, critical: false, error: error))
        }
        guard mayContinueSnapshot(
            taskID: taskID,
            generation: snapshotGeneration,
            session: session
        ) else { return }

        let snapshot = DebugSnapshot(
            stopReason: stopped.stopReason,
            location: location,
            registers: makeRegisters(names: registerNames, values: registerValues),
            stack: stack,
            memory: memory,
            memoryRequest: actualMemoryRequest,
            disassembly: disassembly,
            console: console,
            diagnostics: diagnostics
        )
        latestSnapshot = snapshot
        emit(.snapshot(snapshot))
        for diagnostic in diagnostics { emit(.diagnostic(diagnostic)) }
    }

    private func makeRegisters(names: [String], values: [MIRegisterValue]) -> [DebugRegister] {
        let valuesByNumber = Dictionary(uniqueKeysWithValues: values.map { ($0.number, $0.value) })
        var numbersByName: [String: Int] = [:]
        for (number, name) in names.enumerated() where !name.isEmpty {
            numbersByName[name.lowercased()] = number
        }
        return Self.registerDisplayNames(for: profile).map { displayName in
            let lookupNames: [String]
            switch displayName.lowercased() {
            case "r13": lookupNames = ["r13", "sp"]
            case "r14": lookupNames = ["r14", "lr"]
            case "r15": lookupNames = ["r15", "pc"]
            default: lookupNames = [displayName.lowercased()]
            }
            let number = lookupNames.lazy.compactMap { numbersByName[$0] }.first
            return DebugRegister(
                name: displayName,
                number: number,
                value: number.flatMap { valuesByNumber[$0] }
            )
        }
    }

    private func sendSnapshotCommand(
        _ command: String,
        to session: GDBMISession
    ) async throws -> MIResultRecord {
        try await sendCommand(
            command,
            to: session,
            timeout: snapshotCommandTimeout
        )
    }

    private func sendCommand(
        _ command: String,
        to session: GDBMISession,
        timeout duration: Duration
    ) async throws -> MIResultRecord {
        let request = Task { try await session.send(command) }
        let timeout = Task {
            try await Task.sleep(for: duration)
            request.cancel()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            do {
                return try await request.value
            } catch is CancellationError where !Task.isCancelled {
                throw DebuggerControllerError.commandTimedOut(command)
            }
        } onCancel: {
            request.cancel()
            timeout.cancel()
        }
    }

    private func interruptSimulator(_ activeSession: GDBMISession) async throws {
        let interruptGeneration = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        do {
            try await activeSession.interruptProcessGroup()
        } catch {
            if !isCurrent(interruptGeneration, session: activeSession)
                || machine.state == .terminating
                || machine.state == .ready {
                return
            }
            throw error
        }
        try await waitForInterruptCompletion(
            activeSession,
            generation: interruptGeneration,
            deadline: deadline,
            operation: "等待 ARM7 仿真器暂停"
        )
    }

    private func interruptRemoteTarget(_ activeSession: GDBMISession) async throws {
        if let existing = remoteInterruptTask {
            try await existing.task.value
            return
        }

        let interruptGeneration = generation
        let identifier = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRemoteInterrupt(
                activeSession,
                generation: interruptGeneration
            )
        }
        remoteInterruptTask = TrackedRemoteInterrupt(id: identifier, task: task)
        do {
            try await task.value
            clearRemoteInterrupt(identifier)
        } catch {
            clearRemoteInterrupt(identifier)
            throw error
        }
    }

    private func performRemoteInterrupt(
        _ activeSession: GDBMISession,
        generation interruptGeneration: UUID
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        do {
            _ = try await sendCommand(
                "-exec-interrupt --all",
                to: activeSession,
                timeout: .seconds(1)
            )
        } catch {
            if !isCurrent(interruptGeneration, session: activeSession)
                || machine.state == .terminating
                || machine.state == .ready {
                return
            }
            throw error
        }
        try await waitForInterruptCompletion(
            activeSession,
            generation: interruptGeneration,
            deadline: deadline,
            operation: "等待 QEMU 暂停"
        )
    }

    private func clearRemoteInterrupt(_ identifier: UUID) {
        guard remoteInterruptTask?.id == identifier else { return }
        remoteInterruptTask = nil
    }

    private func waitForInterruptCompletion(
        _ activeSession: GDBMISession,
        generation interruptGeneration: UUID,
        deadline: ContinuousClock.Instant,
        operation: String
    ) async throws {
        let clock = ContinuousClock()
        while clock.now < deadline {
            guard isCurrent(interruptGeneration, session: activeSession) else { return }
            switch machine.state {
            case .stopped, .terminating, .ready:
                return
            case .running:
                try await Task.sleep(for: .milliseconds(10))
            case .idle, .building, .launching:
                throw DebuggerControllerError.commandTimedOut(operation)
            }
        }
        throw DebuggerControllerError.commandTimedOut(operation)
    }

    private func terminateQEMUIfNeeded(
        _ activeSession: GDBMISession,
        backend: DebugBackend?
    ) async {
        guard backend == .qemuARM926Compatible || backend == .qemuMPS2AN386 else { return }
        _ = try? await sendCommand(
            #"-interpreter-exec console "monitor quit""#,
            to: activeSession,
            timeout: .milliseconds(500)
        )
    }

    private static func registerDisplayNames(for profile: ProfileID) -> [String] {
        let general = (0...15).map { "r\($0)" }
        switch profile {
        case .arm7tdmi:
            return general + ["CPSR"]
        case .cortexM4, .stm32f4Discovery:
            return general + ["xPSR", "MSP", "PSP", "CONTROL", "PRIMASK"]
        }
    }

    private func recoverAfterUnexpectedExit(
        _ processTermination: ProcessTermination,
        session endedSession: GDBMISession,
        generation recoveryGeneration: UUID
    ) async {
        guard isCurrent(recoveryGeneration, session: endedSession),
              machine.state != .ready,
              machine.state != .idle,
              machine.state != .building else { return }
        stoppedContext = nil
        publishDiagnostic(.init(
            pane: .session,
            isCritical: true,
            message: "GDB exited (\(processTermination.status))"
        ))
        switch machine.state {
        case .launching:
            try? transition(.launchFailed)
        case .stopped, .running:
            try? transition(.terminationStarted)
            try? transition(.terminationCompleted)
        case .terminating:
            break
        case .idle, .building, .ready:
            break
        }
        await endedSession.shutdown(timeout: .zero)
        guard isCurrent(recoveryGeneration, session: endedSession) else { return }
        session = nil
    }

    private func dispatchSnapshot(
        stopped: MIAsyncRecord,
        session: GDBMISession,
        generation snapshotGeneration: UUID
    ) {
        cancelSnapshotTasks()
        let taskID = UUID()
        currentSnapshotTaskID = taskID
        let task = Task { [weak self] in
            await self?.refreshSnapshot(
                stopped: stopped,
                session: session,
                generation: snapshotGeneration,
                taskID: taskID
            )
            await self?.snapshotTaskFinished(taskID)
        }
        snapshotTasks[taskID] = TrackedTask(
            id: taskID,
            task: task
        )
    }

    private func dispatchRecovery(
        _ termination: ProcessTermination,
        session: GDBMISession,
        generation recoveryGeneration: UUID
    ) {
        guard recoveryTask == nil else { return }
        stoppedContext = nil
        cancelSnapshotTasks()
        let taskID = UUID()
        let task = Task { [weak self] in
            await self?.recoverAfterUnexpectedExit(
                termination,
                session: session,
                generation: recoveryGeneration
            )
            await self?.recoveryTaskFinished(taskID)
        }
        recoveryTask = TrackedTask(
            id: taskID,
            task: task
        )
    }

    private func mayContinueSnapshot(
        taskID: UUID,
        generation snapshotGeneration: UUID,
        session sourceSession: GDBMISession
    ) -> Bool {
        !Task.isCancelled
            && currentSnapshotTaskID == taskID
            && machine.state == .stopped
            && isCurrent(snapshotGeneration, session: sourceSession)
    }

    private func isCurrent(_ candidate: UUID, session candidateSession: GDBMISession) -> Bool {
        generation == candidate && session === candidateSession
    }

    private func validateLaunchAttempt(
        _ candidate: UUID,
        session candidateSession: GDBMISession? = nil
    ) throws {
        try Task.checkCancellation()
        guard generation == candidate, machine.state == .launching else {
            throw CancellationError()
        }
        if let candidateSession, session !== candidateSession {
            throw CancellationError()
        }
    }

    private func rollbackLaunchAttempt(
        generation attemptGeneration: UUID,
        session attemptSession: GDBMISession?,
        eventTask attemptEventTask: TrackedTask?
    ) async {
        if let attemptEventTask {
            attemptEventTask.task.cancel()
            if sessionEventTask?.id == attemptEventTask.id {
                sessionEventTask = nil
            }
            await attemptEventTask.task.value
        }
        if let attemptSession {
            if session === attemptSession { session = nil }
            await attemptSession.shutdown(timeout: .zero)
        }
        guard generation == attemptGeneration, machine.state == .launching else { return }
        generation = UUID()
        stoppedContext = nil
        try? transition(.launchFailed)
    }

    private func cancelSnapshotTasks() {
        currentSnapshotTaskID = nil
        for tracked in snapshotTasks.values { tracked.task.cancel() }
    }

    private func cancelAndAwaitBackgroundTasks() async {
        let eventTask = sessionEventTask?.task
        let snapshots = snapshotTasks.values.map(\.task)
        let recovery = recoveryTask?.task
        sessionEventTask = nil
        snapshotTasks.removeAll(keepingCapacity: false)
        currentSnapshotTaskID = nil
        recoveryTask = nil
        eventTask?.cancel()
        for task in snapshots { task.cancel() }
        recovery?.cancel()
        if let eventTask { await eventTask.value }
        for task in snapshots { await task.value }
        if let recovery { await recovery.value }
    }

    private func eventTaskFinished(_ taskID: UUID) {
        guard sessionEventTask?.id == taskID else { return }
        sessionEventTask = nil
    }

    private func snapshotTaskFinished(_ taskID: UUID) {
        snapshotTasks.removeValue(forKey: taskID)
        if currentSnapshotTaskID == taskID { currentSnapshotTaskID = nil }
    }

    private func recoveryTaskFinished(_ taskID: UUID) {
        guard recoveryTask?.id == taskID else { return }
        recoveryTask = nil
    }

    private func transition(_ event: DebuggerLifecycleEvent) throws {
        try machine.apply(event)
        emit(.stateChanged(machine.state))
    }

    private func requireState(_ required: DebuggerState, operation: String) throws {
        guard machine.state == required else {
            throw DebuggerControllerError.operationUnavailable(operation, state: machine.state)
        }
    }

    private func requiredSession() throws -> GDBMISession {
        guard let session else { throw DebuggerControllerError.missingLaunchPlan }
        return session
    }

    private func validate(_ request: DebugMemoryRequest) throws {
        let pattern = #"^[A-Za-z0-9_$+*/().-]+$"#
        guard request.byteCount > 0,
              request.byteCount <= 1_048_576,
              request.address.range(of: pattern, options: .regularExpression) != nil else {
            throw DebuggerControllerError.invalidMemoryRequest
        }
    }

    private func resetMemoryRequest(ifUnchanged revision: UInt64) {
        guard memoryRequestRevision == revision else { return }
        memoryRequest = .yagartoWindow
        memoryRequestRevision &+= 1
    }

    private static func quoteMIArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func diagnostic(
        _ pane: DebugDiagnosticPane,
        critical: Bool,
        error: any Error
    ) -> DebugDiagnostic {
        let message: String
        if case let GDBMISessionError.commandFailed(failure) = error {
            message = failure.message ?? String(describing: error)
        } else if case let DebuggerControllerError.commandTimedOut(command) = error {
            message = "\(command) timed out"
        } else {
            message = String(describing: error)
        }
        return DebugDiagnostic(pane: pane, isCritical: critical, message: message)
    }

    private func publishDiagnostic(_ diagnostic: DebugDiagnostic) {
        emit(.diagnostic(diagnostic))
    }

    private func appendConsole(_ entry: DebugConsoleEntry) {
        console.append(entry)
        if console.count > consoleLimit {
            console.removeFirst(console.count - consoleLimit)
        }
        emit(.consoleAppended(entry))
    }

    private func emit(_ event: DebuggerEvent) {
        for continuation in subscribers.values {
            if case .dropped = continuation.yield(event) {
                totalDroppedEvents += 1
                _ = continuation.yield(.eventsDropped(total: totalDroppedEvents))
            }
        }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }
}
