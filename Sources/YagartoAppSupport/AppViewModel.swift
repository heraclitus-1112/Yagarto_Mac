// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

@Observable
@MainActor
public final class AppViewModel {
    private struct DocumentVersion: Equatable {
        let identifier: UUID
        let revision: UInt64
    }

    private struct BreakpointKey: Hashable {
        let canonicalPath: String
        let line: Int
    }

    public private(set) var document: WorkspaceDocument?
    public private(set) var latestBuild: AppBuildResult?
    public private(set) var buildDiagnostics: [BuildDiagnostic] = []
    public private(set) var debugDiagnostics: [DebugDiagnostic] = []
    public private(set) var snapshot: DebugSnapshot?
    public private(set) var registerRows: [RegisterRow] = []
    public private(set) var console = BoundedConsole()
    public private(set) var breakpoints = BreakpointLines()
    public private(set) var memory: [MIMemoryBlock] = []
    public private(set) var errorMessage: String?
    public private(set) var isProjectOperationInProgress = false
    public var selectedRange: NSRange?

    private var machine = DebuggerStateMachine()
    private let documentService: any DocumentServicing
    private let buildService: any BuildServicing
    private let debugService: any DebugServicing
    private let projectCreationService: any ProjectCreationServicing
    private let stopTimeout: Duration
    private var breakpointIdentifiers: [BreakpointKey: String] = [:]
    private var breakpointRequestGenerations: [BreakpointKey: UInt64] = [:]
    private var reconcilingBreakpoints: Set<BreakpointKey> = []
    private var debugSessionGeneration: UInt64 = 0
    private var startGeneration: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var documentIdentifier: UUID?
    private var documentRevision: UInt64 = 0
    private var openGeneration: UInt64 = 0
    private var memoryOperationGeneration: UInt64 = 0
    private var desiredMemoryRequest = DebugMemoryRequest.yagartoWindow
    private var memoryErrorGeneration: UInt64?

    public init(
        documentService: any DocumentServicing,
        buildService: any BuildServicing,
        debugService: any DebugServicing,
        stopTimeout: Duration = .seconds(2),
        projectCreationService: any ProjectCreationServicing = CoreProjectCreationService()
    ) {
        self.documentService = documentService
        self.buildService = buildService
        self.debugService = debugService
        self.projectCreationService = projectCreationService
        self.stopTimeout = stopTimeout
        observeDebuggerEvents()
    }

    public var state: DebuggerState { machine.state }
    public var documentInstanceID: UUID? { documentIdentifier }

    public var currentExecutionLine: Int? {
        guard state == .stopped,
              let document,
              let location = snapshot?.location,
              SourceLocationMatcher.matches(
                  debuggerFile: location.fullName ?? location.file,
                  documentURL: document.sourceURL,
                  projectDirectory: document.projectDirectory
              ),
              let numeric = location.line?.numeric,
              numeric <= UInt64(Int.max) else { return nil }
        return Int(numeric)
    }

    public func isEnabled(_ command: AppCommand) -> Bool {
        AppCommandAvailability.isEnabled(
            command,
            state: state,
            hasDocument: document != nil,
            isDirty: document?.isDirty ?? false,
            isProjectOperationInProgress: isProjectOperationInProgress
        )
    }

    public func open(_ url: URL) async {
        guard isEnabled(.open) else { return }
        retireStart()
        invalidateMemoryOperations()
        openGeneration &+= 1
        let generation = openGeneration
        do {
            let openedDocument = try await documentService.open(url)
            guard generation == openGeneration else { return }
            install(openedDocument)
        } catch {
            guard generation == openGeneration else { return }
            present(error)
        }
    }

    public func createProject(_ request: ProjectCreationRequest) async -> CreatedProject? {
        guard isEnabled(.newProject) else { return nil }
        retireStart()
        invalidateMemoryOperations()
        openGeneration &+= 1
        let generation = openGeneration
        isProjectOperationInProgress = true
        defer { isProjectOperationInProgress = false }
        do {
            let created = try await projectCreationService.create(request)
            guard generation == openGeneration else { return nil }
            let openedDocument = try await documentService.open(created.projectDirectory)
            guard generation == openGeneration else { return nil }
            install(openedDocument)
            return created
        } catch {
            guard generation == openGeneration else { return nil }
            present(error)
            return nil
        }
    }

    public func importProjects(_ request: ProjectImportRequest) async -> ProjectImportReport? {
        guard isEnabled(.importProjects) else { return nil }
        isProjectOperationInProgress = true
        defer { isProjectOperationInProgress = false }
        let report = await projectCreationService.importProjects(request)
        clearPresentedError()
        return report
    }

    public func edit(_ text: String) {
        guard isEnabled(.edit), let document else { return }
        let transform = LineEditTransform.between(oldText: document.text, newText: text)
        breakpoints = breakpoints.applying(transform)
        self.document = document.editing(text)
        documentRevision &+= 1
        latestBuild = nil
    }

    public func changeProfile(to profile: ProfileID) {
        guard isEnabled(.changeProfile), let document else { return }
        retireStart()
        self.document = document.changingProfile(to: profile)
        documentRevision &+= 1
        latestBuild = nil
        machine = DebuggerStateMachine()
        breakpointIdentifiers = [:]
        debugSessionGeneration &+= 1
        resetDesiredMemoryRequest()
        clearRuntimePresentation()
    }

    public func save() async {
        guard let document, document.isDirty, let version = currentDocumentVersion else { return }
        let snapshot = document
        do {
            _ = try await documentService.save(snapshot)
            guard matchesDocument(version), let current = self.document else { return }
            self.document = current.acknowledgingSave(of: snapshot)
            clearPresentedError()
        } catch {
            guard matchesDocument(version) else { return }
            present(error)
        }
    }

    public func build() async {
        guard isEnabled(.build), let currentDocument = document,
              let version = currentDocumentVersion else { return }
        do {
            try machine.apply(.buildStarted)
            breakpointIdentifiers = [:]
            clearRuntimePresentation()
            clearPresentedError()
            buildDiagnostics = []
            let buildDocument = currentDocument
            if buildDocument.isDirty {
                let snapshot = buildDocument
                _ = try await documentService.save(snapshot)
                guard matchesDocument(version), let current = document else { return }
                document = current.acknowledgingSave(of: snapshot)
            }
            let result = try await buildService.build(projectDirectory: buildDocument.projectDirectory)
            guard matchesDocument(version) else { return }
            latestBuild = result
            buildDiagnostics = result.diagnostics
            try machine.apply(.buildSucceeded)
            clearRuntimePresentation()
        } catch {
            guard matchesDocument(version) else { return }
            if state == .building { try? machine.apply(.buildFailed) }
            latestBuild = nil
            clearRuntimePresentation()
            if let failure = error as? BuildServiceFailure {
                buildDiagnostics = failure.diagnostics
            }
            present(error)
        }
    }

    public func start(_ mode: DebugMode) async {
        guard isEnabled(mode == .run ? .run : .debug),
              let latestBuild,
              let document else { return }
        startGeneration &+= 1
        let generation = startGeneration
        do {
            try machine.apply(.launchStarted)
        } catch {
            present(error)
            return
        }
        breakpointIdentifiers = [:]
        debugSessionGeneration &+= 1
        let sessionGeneration = debugSessionGeneration
        clearRuntimePresentation()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart(
                mode,
                build: latestBuild,
                document: document,
                generation: generation,
                session: sessionGeneration
            )
        }
        startTask = task
        await task.value
        if generation == startGeneration {
            startTask = nil
        }
    }

    public func pause() async { await performDebugCommand { try await debugService.pause() } }
    public func stepInstruction() async { await performDebugCommand { try await debugService.stepInstruction() } }
    public func stepOver() async { await performDebugCommand { try await debugService.stepOver() } }
    public func resume() async { await performDebugCommand { try await debugService.resume() } }

    public func stop() async {
        guard isEnabled(.stop) || state == .terminating else { return }
        retireStart()
        beginStopIfNeeded()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: stopTimeout)
        while clock.now < deadline, state == .terminating {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if state == .terminating {
            presentGlobalMessage("停止调试器超时；后台清理仍在继续。")
        }
    }

    public func readMemory(address: String, length: String) async {
        let generation = beginMemoryOperation()
        let operationState = state
        do {
            let validatedRequest = try MemoryRequestValidator.request(address: address, length: length)
            let request = DebugMemoryRequest(
                address: validatedRequest.address,
                byteCount: validatedRequest.byteCount,
                observationID: UUID()
            )
            desiredMemoryRequest = request
            let blocks = try await debugService.readMemory(request)
            guard isCurrentMemoryOperation(generation, state: operationState) else { return }
            memory = blocks
            clearMemoryError()
        } catch {
            guard isCurrentMemoryOperation(generation, state: operationState) else { return }
            memory = []
            presentMemoryError(error, generation: generation)
        }
    }

    public func setMemoryWindowAddress(_ rawAddress: String) async -> String? {
        let generation = beginMemoryOperation()
        let operationState = state
        do {
            let normalized = try MemoryWindowAddress.normalized(rawAddress)
            let request = DebugMemoryRequest(
                address: normalized,
                byteCount: MemoryWindowLayout.byteCount,
                observationID: UUID()
            )
            desiredMemoryRequest = request
            try await debugService.setMemoryRequest(request)
            guard isCurrentMemoryOperation(generation, state: operationState) else { return nil }
            guard state == .stopped else {
                memory = []
                clearMemoryError()
                return normalized
            }
            let blocks = try await debugService.readMemory(request)
            guard isCurrentMemoryOperation(generation, state: .stopped) else { return nil }
            memory = blocks
            clearMemoryError()
            return normalized
        } catch {
            guard isCurrentMemoryOperation(generation, state: operationState) else { return nil }
            memory = []
            presentMemoryError(error, generation: generation)
            return nil
        }
    }

    public func toggleBreakpoint(line: Int) async {
        guard line > 0, let document else { return }
        let key = BreakpointKey(canonicalPath: canonicalPath(document.sourceURL), line: line)
        breakpoints = breakpoints.toggling(line)
        breakpointRequestGenerations[key, default: 0] &+= 1
        guard state == .stopped else { return }
        await reconcileBreakpoint(
            key,
            sourceURL: document.sourceURL,
            session: debugSessionGeneration
        )
    }

    public func selectDiagnostic(_ diagnostic: BuildDiagnostic) {
        guard let document,
              diagnostic.file == nil || SourceLocationMatcher.matches(
                  debuggerFile: diagnostic.file?.path,
                  documentURL: document.sourceURL,
                  projectDirectory: document.projectDirectory
              ) else { return }
        selectedRange = diagnostic.sourceSelection(in: document.text)
    }

    public func reportOperationError(_ error: Error) {
        present(error)
    }

    public func close() async {
        invalidateMemoryOperations()
        guard !isProjectOperationInProgress else { return }
        retireStart()
        invalidateDocumentOperations()
        if isEnabled(.stop) || state == .terminating { beginStopIfNeeded() }
        if let stopTask { await stopTask.value }
        eventTask?.cancel()
        eventTask = nil
    }

    private func observeDebuggerEvents() {
        let service = debugService
        eventTask = Task { [weak self] in
            let events = await service.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    private func receive(_ event: DebuggerEvent) {
        switch event {
        case .stateChanged(let newState):
            transitionFromDebugger(to: newState)
        case .snapshot(let newSnapshot):
            guard state == .stopped else { return }
            let previous = snapshot?.registers ?? []
            snapshot = newSnapshot
            registerRows = RegisterPresentation.rows(current: newSnapshot.registers, previous: previous)
            let memoryReadFailed = newSnapshot.diagnostics.contains { $0.pane == .memory }
            if let memoryRequest = newSnapshot.memoryRequest,
               memoryRequest == desiredMemoryRequest,
               !memoryReadFailed {
                memory = newSnapshot.memory
                clearMemoryError()
            }
            console.replace(with: newSnapshot.console)
            debugDiagnostics.append(contentsOf: newSnapshot.diagnostics)
        case .consoleAppended(let entry):
            console.append(entry)
        case .diagnostic(let diagnostic):
            debugDiagnostics.append(diagnostic)
            if diagnostic.isCritical { presentGlobalMessage(diagnostic.message) }
        case .eventsDropped(let total):
            debugDiagnostics.append(DebugDiagnostic(
                pane: .session,
                isCritical: false,
                message: "调试事件过快，已丢弃 \(total) 条旧事件。"
            ))
        }
    }

    private func transitionFromDebugger(to newState: DebuggerState) {
        guard newState != state else { return }
        let lifecycle: DebuggerLifecycleEvent?
        switch (state, newState) {
        case (.ready, .launching): lifecycle = .launchStarted
        case (.launching, .ready): lifecycle = .launchFailed
        case (.launching, .stopped), (.running, .stopped): lifecycle = .inferiorStopped
        case (.launching, .running), (.stopped, .running): lifecycle = .inferiorRunning
        case (.launching, .terminating), (.stopped, .terminating), (.running, .terminating): lifecycle = .terminationStarted
        case (.terminating, .ready): lifecycle = .terminationCompleted
        default: lifecycle = nil
        }
        if let lifecycle {
            try? machine.apply(lifecycle)
            if newState == .stopped {
                scheduleStoppedBreakpointReconciliation()
            }
            if newState == .running {
                clearMemoryPresentation()
            }
            if newState == .ready {
                retireStart()
                breakpointIdentifiers = [:]
                debugSessionGeneration &+= 1
                clearRuntimePresentation()
            }
        }
    }

    private func performDebugCommand(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            clearPresentedError()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        presentGlobalMessage(error.localizedDescription)
    }

    private func presentGlobalMessage(_ message: String) {
        memoryErrorGeneration = nil
        errorMessage = message
    }

    private func presentMemoryError(_ error: Error, generation: UInt64) {
        memoryErrorGeneration = generation
        errorMessage = error.localizedDescription
    }

    private func clearMemoryError() {
        guard memoryErrorGeneration != nil else { return }
        memoryErrorGeneration = nil
        errorMessage = nil
    }

    private func clearPresentedError() {
        memoryErrorGeneration = nil
        errorMessage = nil
    }

    private func install(_ openedDocument: WorkspaceDocument) {
        document = openedDocument
        documentIdentifier = UUID()
        documentRevision = 0
        latestBuild = nil
        buildDiagnostics = []
        debugDiagnostics = []
        clearRuntimePresentation()
        breakpoints = BreakpointLines()
        breakpointIdentifiers = [:]
        breakpointRequestGenerations = [:]
        reconcilingBreakpoints = []
        debugSessionGeneration &+= 1
        resetDesiredMemoryRequest()
        clearPresentedError()
        machine = DebuggerStateMachine()
        selectedRange = nil
    }

    private func beginStopIfNeeded() {
        guard stopTask == nil else { return }
        invalidateMemoryOperations()
        resetDesiredMemoryRequest()
        if state != .terminating { try? machine.apply(.terminationStarted) }
        guard state == .terminating else { return }
        let service = debugService
        stopTask = Task { [weak self] in
            do {
                try await service.stop()
                self?.completeStop(error: nil)
            } catch {
                self?.completeStop(error: error.localizedDescription)
            }
        }
    }

    private func completeStop(error: String?) {
        if state == .terminating { try? machine.apply(.terminationCompleted) }
        breakpointIdentifiers = [:]
        debugSessionGeneration &+= 1
        clearRuntimePresentation()
        stopTask = nil
        if let error { presentGlobalMessage("停止调试器失败：\(error)") }
    }

    private func clearRuntimePresentation() {
        snapshot = nil
        registerRows = []
        clearMemoryPresentation()
    }

    private func clearMemoryPresentation() {
        invalidateMemoryOperations()
        memory = []
    }

    private func beginMemoryOperation() -> UInt64 {
        memoryOperationGeneration &+= 1
        return memoryOperationGeneration
    }

    private func invalidateMemoryOperations() {
        memoryOperationGeneration &+= 1
    }

    private func resetDesiredMemoryRequest() {
        desiredMemoryRequest = .yagartoWindow
    }

    private func isCurrentMemoryOperation(
        _ generation: UInt64,
        state expectedState: DebuggerState
    ) -> Bool {
        generation == memoryOperationGeneration && state == expectedState
    }

    private func performStart(
        _ mode: DebugMode,
        build: AppBuildResult,
        document: WorkspaceDocument,
        generation: UInt64,
        session: UInt64
    ) async {
        do {
            try await debugService.prepare(build)
            guard isCurrentStart(generation, session: session, document: document) else { return }
            try await synchronizeDesiredMemoryRequestForStart(
                generation: generation,
                session: session,
                document: document
            )
            guard isCurrentStart(generation, session: session, document: document) else { return }
            let requests = breakpoints.lines.sorted().map {
                DebugSourceBreakpoint(file: document.sourceURL, line: $0)
            }
            let result = try await debugService.launch(mode: mode, breakpoints: requests)
            guard isCurrentStart(generation, session: session, document: document) else { return }
            let sourcePath = canonicalPath(document.sourceURL)
            for (line, identifier) in result.breakpointIdentifiers {
                guard isCurrentStart(generation, session: session, document: document) else { return }
                let key = BreakpointKey(canonicalPath: sourcePath, line: line)
                if breakpointIsDesired(key) {
                    breakpointIdentifiers[key] = identifier
                } else {
                    do {
                        try await debugService.removeBreakpoint(identifier: identifier)
                        guard isCurrentStart(generation, session: session, document: document) else { return }
                    } catch {
                        guard isCurrentStart(generation, session: session, document: document) else { return }
                        breakpointIdentifiers[key] = identifier
                        setBreakpointDesired(true, for: key)
                        appendBreakpointDiagnostic(
                            line: line,
                            message: "启动期间取消的断点移除失败，已恢复本地状态：\(error.localizedDescription)"
                        )
                    }
                }
            }
            for failure in result.failures {
                guard isCurrentStart(generation, session: session, document: document) else { return }
                let key = BreakpointKey(
                    canonicalPath: canonicalPath(failure.breakpoint.file),
                    line: failure.breakpoint.line
                )
                if breakpointIsDesired(key) {
                    setBreakpointDesired(false, for: key)
                    appendBreakpointDiagnostic(
                        line: failure.breakpoint.line,
                        message: "断点同步失败，已恢复本地状态：\(failure.message)"
                    )
                }
            }
            guard isCurrentStart(generation, session: session, document: document) else { return }
            if state == .launching {
                try machine.apply(mode == .run ? .inferiorRunning : .inferiorStopped)
            } else if mode == .run, state == .stopped {
                try machine.apply(.inferiorRunning)
            }
            if state == .stopped {
                for line in breakpoints.lines.sorted() {
                    let key = BreakpointKey(canonicalPath: sourcePath, line: line)
                    await reconcileBreakpoint(
                        key,
                        sourceURL: document.sourceURL,
                        session: session
                    )
                    guard isCurrentStart(generation, session: session, document: document) else { return }
                }
            }
            guard isCurrentStart(generation, session: session, document: document) else { return }
            clearPresentedError()
        } catch {
            guard isCurrentStart(generation, session: session, document: document) else { return }
            if state == .launching { try? machine.apply(.launchFailed) }
            breakpointIdentifiers = [:]
            debugSessionGeneration &+= 1
            clearRuntimePresentation()
            present(error)
        }
    }

    private func isCurrentStart(
        _ generation: UInt64,
        session: UInt64,
        document: WorkspaceDocument
    ) -> Bool {
        generation == startGeneration
            && session == debugSessionGeneration
            && documentIdentifier != nil
            && canonicalPath(self.document?.sourceURL) == canonicalPath(document.sourceURL)
            && state != .ready
            && state != .terminating
    }

    private func synchronizeDesiredMemoryRequestForStart(
        generation: UInt64,
        session: UInt64,
        document: WorkspaceDocument
    ) async throws {
        while isCurrentStart(generation, session: session, document: document) {
            let request = desiredMemoryRequest
            try await debugService.setMemoryRequest(request)
            guard isCurrentStart(generation, session: session, document: document) else { return }
            if request == desiredMemoryRequest { return }
        }
    }

    private func retireStart() {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
    }

    private var currentDocumentVersion: DocumentVersion? {
        guard let documentIdentifier else { return nil }
        return DocumentVersion(identifier: documentIdentifier, revision: documentRevision)
    }

    private func matchesDocument(_ version: DocumentVersion) -> Bool {
        documentIdentifier == version.identifier && documentRevision >= version.revision
    }

    private func invalidateDocumentOperations() {
        openGeneration &+= 1
        if document != nil { documentIdentifier = UUID() }
    }

    private func reconcileBreakpoint(
        _ key: BreakpointKey,
        sourceURL: URL,
        session: UInt64
    ) async {
        guard !reconcilingBreakpoints.contains(key) else { return }
        reconcilingBreakpoints.insert(key)
        defer { reconcilingBreakpoints.remove(key) }

        while state == .stopped,
              debugSessionGeneration == session,
              canonicalPath(document?.sourceURL) == key.canonicalPath {
            let desired = breakpointIsDesired(key)
            let remoteIdentifier = breakpointIdentifiers[key]
            if desired, remoteIdentifier == nil {
                do {
                    let remote = try await debugService.setBreakpoint(file: sourceURL, line: key.line)
                    guard debugSessionGeneration == session,
                          canonicalPath(document?.sourceURL) == key.canonicalPath else {
                        return
                    }
                    if breakpointIsDesired(key) {
                        breakpointIdentifiers[key] = remote.id
                    } else if state == .stopped {
                        do {
                            try await debugService.removeBreakpoint(identifier: remote.id)
                        } catch {
                            guard debugSessionGeneration == session,
                                  canonicalPath(document?.sourceURL) == key.canonicalPath else { return }
                            breakpointIdentifiers[key] = remote.id
                            setBreakpointDesired(true, for: key)
                            appendBreakpointDiagnostic(
                                line: key.line,
                                message: "取消后的远端断点移除失败，已恢复本地状态：\(error.localizedDescription)"
                            )
                        }
                    } else {
                        breakpointIdentifiers[key] = remote.id
                        setBreakpointDesired(true, for: key)
                        appendBreakpointDiagnostic(
                            line: key.line,
                            message: "会话状态已变化，保留已创建的远端断点。"
                        )
                    }
                } catch {
                    guard debugSessionGeneration == session,
                          canonicalPath(document?.sourceURL) == key.canonicalPath else { return }
                    if breakpointIdentifiers[key] == nil, breakpointIsDesired(key) {
                        setBreakpointDesired(false, for: key)
                        appendBreakpointDiagnostic(
                            line: key.line,
                            message: "断点设置失败，已恢复本地状态：\(error.localizedDescription)"
                        )
                    }
                }
            } else if !desired, let remoteIdentifier {
                do {
                    try await debugService.removeBreakpoint(identifier: remoteIdentifier)
                    guard debugSessionGeneration == session,
                          canonicalPath(document?.sourceURL) == key.canonicalPath else { return }
                    if breakpointIdentifiers[key] == remoteIdentifier {
                        breakpointIdentifiers[key] = nil
                    }
                    if state != .stopped, breakpointIsDesired(key) {
                        setBreakpointDesired(false, for: key)
                        appendBreakpointDiagnostic(
                            line: key.line,
                            message: "会话状态已变化，已恢复为远端移除后的状态。"
                        )
                    }
                } catch {
                    guard debugSessionGeneration == session,
                          canonicalPath(document?.sourceURL) == key.canonicalPath else { return }
                    guard breakpointIdentifiers[key] == remoteIdentifier else { continue }
                    if !breakpointIsDesired(key) {
                        setBreakpointDesired(true, for: key)
                        appendBreakpointDiagnostic(
                            line: key.line,
                            message: "断点移除失败，已恢复本地状态：\(error.localizedDescription)"
                        )
                    }
                }
            } else {
                return
            }
        }
    }

    private func scheduleStoppedBreakpointReconciliation() {
        guard state == .stopped, startTask == nil, let document else { return }
        let sourceURL = document.sourceURL
        let sourcePath = canonicalPath(sourceURL)
        let session = debugSessionGeneration
        let desiredKeys = breakpoints.lines.map { BreakpointKey(canonicalPath: sourcePath, line: $0) }
        let knownRemoteKeys = breakpointIdentifiers.keys.filter { $0.canonicalPath == sourcePath }
        let keys = Set(desiredKeys).union(knownRemoteKeys).sorted { $0.line < $1.line }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for key in keys {
                guard self.state == .stopped,
                      self.debugSessionGeneration == session,
                      self.canonicalPath(self.document?.sourceURL) == sourcePath else { return }
                await self.reconcileBreakpoint(
                    key,
                    sourceURL: sourceURL,
                    session: session
                )
            }
        }
    }

    private func breakpointIsDesired(_ key: BreakpointKey) -> Bool {
        canonicalPath(document?.sourceURL) == key.canonicalPath && breakpoints.lines.contains(key.line)
    }

    private func setBreakpointDesired(_ desired: Bool, for key: BreakpointKey) {
        guard canonicalPath(document?.sourceURL) == key.canonicalPath else { return }
        if breakpoints.lines.contains(key.line) != desired {
            breakpoints = breakpoints.toggling(key.line)
            breakpointRequestGenerations[key, default: 0] &+= 1
        }
    }

    private func appendBreakpointDiagnostic(line: Int, message: String) {
        debugDiagnostics.append(DebugDiagnostic(
            pane: .session,
            isCritical: false,
            message: "第 \(line) 行\(message)"
        ))
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func canonicalPath(_ url: URL?) -> String? {
        url.map(canonicalPath)
    }
}
