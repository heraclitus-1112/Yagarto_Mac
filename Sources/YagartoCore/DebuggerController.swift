// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public actor DebuggerController {
    private let profile: ProfileID
    private let consoleLimit: Int
    private let eventBufferLimit: Int
    private let snapshotCommandTimeout: Duration
    private var machine: DebuggerStateMachine
    private var plan: DebugLaunchPlan?
    private var session: GDBMISession?
    private var sessionEventTask: Task<Void, Never>?
    private var console: [DebugConsoleEntry] = []
    private var memoryRequest = DebugMemoryRequest.stackWindow
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
        let newSession = GDBMISession(plan: plan)
        session = newSession
        let stream = await newSession.events()
        sessionEventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        do {
            try await newSession.start()
        } catch {
            sessionEventTask?.cancel()
            sessionEventTask = nil
            session = nil
            try transition(.launchFailed)
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
        _ = try await requiredSession().send("-exec-interrupt --all")
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
        try transition(.terminationStarted)
        sessionEventTask?.cancel()
        sessionEventTask = nil
        if let session {
            await session.shutdown()
        }
        session = nil
        try transition(.terminationCompleted)
    }

    public func readMemory(_ request: DebugMemoryRequest) async throws -> [MIMemoryBlock] {
        try requireState(.stopped, operation: "readMemory")
        try validate(request)
        memoryRequest = request
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

    private func receive(_ event: GDBMIEvent) async {
        switch event {
        case .asynchronous(let record) where record.kind == .exec && record.asyncClass == "running":
            guard machine.state == .launching || machine.state == .stopped else { return }
            try? transition(.inferiorRunning)
        case .asynchronous(let record) where record.kind == .exec && record.asyncClass == "stopped":
            guard machine.state == .launching || machine.state == .running else { return }
            try? transition(.inferiorStopped)
            await refreshSnapshot(stopped: record)
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
            await recoverAfterUnexpectedExit(termination)
        case .endOfFile:
            publishDiagnostic(.init(pane: .session, isCritical: true, message: "GDB stdout reached EOF"))
        case .result, .orphanResult, .prompt, .asynchronous:
            break
        }
    }

    private func refreshSnapshot(stopped: MIAsyncRecord) async {
        guard let session else { return }
        var diagnostics: [DebugDiagnostic] = []
        var location = stopped.frame
        var registerNames: [String] = []
        var registerValues: [MIRegisterValue] = []
        var stack: [MIFrame] = []
        var memory: [MIMemoryBlock] = []
        var disassembly: [MIInstruction] = []

        do {
            location = try await sendSnapshotCommand("-stack-info-frame", to: session).frame ?? location
        } catch {
            diagnostics.append(diagnostic(.frame, critical: true, error: error))
        }
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
        do {
            stack = try await sendSnapshotCommand("-stack-list-frames", to: session).stackFrames
        } catch {
            diagnostics.append(diagnostic(.stack, critical: false, error: error))
        }
        do {
            let request = memoryRequest
            try validate(request)
            memory = try await sendSnapshotCommand(
                "-data-read-memory-bytes \(request.address) \(request.byteCount)",
                to: session
            ).memoryBlocks
        } catch {
            diagnostics.append(diagnostic(.memory, critical: false, error: error))
        }
        do {
            disassembly = try await sendSnapshotCommand(
                "-data-disassemble -s \"$pc-32\" -e \"$pc+32\" -- 0",
                to: session
            ).instructions
        } catch {
            diagnostics.append(diagnostic(.disassembly, critical: false, error: error))
        }

        let snapshot = DebugSnapshot(
            stopReason: stopped.stopReason,
            location: location,
            registers: makeRegisters(names: registerNames, values: registerValues),
            stack: stack,
            memory: memory,
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
            let number = numbersByName[displayName.lowercased()]
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
        let request = Task { try await session.send(command) }
        let timeout = Task {
            try await Task.sleep(for: snapshotCommandTimeout)
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

    private static func registerDisplayNames(for profile: ProfileID) -> [String] {
        let general = (0...15).map { "r\($0)" }
        switch profile {
        case .arm7tdmi:
            return general + ["CPSR"]
        case .cortexM4, .stm32f4Discovery:
            return general + ["xPSR", "MSP", "PSP", "CONTROL", "PRIMASK"]
        }
    }

    private func recoverAfterUnexpectedExit(_ processTermination: ProcessTermination) async {
        guard machine.state != .ready, machine.state != .idle, machine.state != .building else { return }
        let endedSession = session
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
        if let endedSession {
            await endedSession.shutdown(timeout: .zero)
        }
        session = nil
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
