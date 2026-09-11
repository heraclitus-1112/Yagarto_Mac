// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

@Observable
@MainActor
public final class AppViewModel {
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
    public var selectedRange: NSRange?

    private var machine = DebuggerStateMachine()
    private let documentService: any DocumentServicing
    private let buildService: any BuildServicing
    private let debugService: any DebugServicing
    private let stopTimeout: Duration
    private var breakpointIdentifiers: [Int: String] = [:]
    private var eventTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    public init(
        documentService: any DocumentServicing,
        buildService: any BuildServicing,
        debugService: any DebugServicing,
        stopTimeout: Duration = .seconds(2)
    ) {
        self.documentService = documentService
        self.buildService = buildService
        self.debugService = debugService
        self.stopTimeout = stopTimeout
        observeDebuggerEvents()
    }

    public var state: DebuggerState { machine.state }

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
            isDirty: document?.isDirty ?? false
        )
    }

    public func open(_ url: URL) async {
        guard isEnabled(.open) else { return }
        do {
            document = try await documentService.open(url)
            latestBuild = nil
            buildDiagnostics = []
            debugDiagnostics = []
            snapshot = nil
            registerRows = []
            breakpoints = BreakpointLines()
            breakpointIdentifiers = [:]
            errorMessage = nil
            machine = DebuggerStateMachine()
        } catch {
            present(error)
        }
    }

    public func edit(_ text: String) {
        guard isEnabled(.edit), let document else { return }
        let transform = LineEditTransform.between(oldText: document.text, newText: text)
        breakpoints = breakpoints.applying(transform)
        self.document = document.editing(text)
        latestBuild = nil
    }

    public func changeProfile(to profile: ProfileID) {
        guard isEnabled(.changeProfile), let document else { return }
        self.document = document.changingProfile(to: profile)
        latestBuild = nil
        machine = DebuggerStateMachine()
        breakpointIdentifiers = [:]
        clearRuntimePresentation()
    }

    public func save() async {
        guard let document, document.isDirty else { return }
        do {
            self.document = try await documentService.save(document)
            errorMessage = nil
        } catch {
            present(error)
        }
    }

    public func build() async {
        guard isEnabled(.build), let currentDocument = document else { return }
        do {
            try machine.apply(.buildStarted)
            breakpointIdentifiers = [:]
            clearRuntimePresentation()
            errorMessage = nil
            buildDiagnostics = []
            var buildDocument = currentDocument
            if buildDocument.isDirty {
                buildDocument = try await documentService.save(buildDocument)
                document = buildDocument
            }
            let result = try await buildService.build(projectDirectory: buildDocument.projectDirectory)
            latestBuild = result
            buildDiagnostics = result.diagnostics
            try machine.apply(.buildSucceeded)
            clearRuntimePresentation()
        } catch {
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
        do {
            try machine.apply(.launchStarted)
            breakpointIdentifiers = [:]
            clearRuntimePresentation()
            try await debugService.prepare(latestBuild)
            let requests = breakpoints.lines.sorted().map {
                DebugSourceBreakpoint(file: document.sourceURL, line: $0)
            }
            let result = try await debugService.launch(mode: mode, breakpoints: requests)
            breakpointIdentifiers = result.breakpointIdentifiers
            for failure in result.failures {
                breakpoints = breakpoints.toggling(failure.breakpoint.line)
                debugDiagnostics.append(DebugDiagnostic(
                    pane: .session,
                    isCritical: false,
                    message: "第 \(failure.breakpoint.line) 行断点同步失败，已恢复本地状态：\(failure.message)"
                ))
            }
            if state == .launching {
                try machine.apply(mode == .run ? .inferiorRunning : .inferiorStopped)
            } else if mode == .run, state == .stopped {
                try machine.apply(.inferiorRunning)
            }
            errorMessage = nil
        } catch {
            if state == .launching { try? machine.apply(.launchFailed) }
            breakpointIdentifiers = [:]
            clearRuntimePresentation()
            present(error)
        }
    }

    public func pause() async { await performDebugCommand { try await debugService.pause() } }
    public func stepInstruction() async { await performDebugCommand { try await debugService.stepInstruction() } }
    public func stepOver() async { await performDebugCommand { try await debugService.stepOver() } }
    public func resume() async { await performDebugCommand { try await debugService.resume() } }

    public func stop() async {
        guard isEnabled(.stop) || state == .terminating else { return }
        beginStopIfNeeded()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: stopTimeout)
        while clock.now < deadline, state == .terminating {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if state == .terminating {
            errorMessage = "停止调试器超时；后台清理仍在继续。"
        }
    }

    public func readMemory(address: String, length: String) async {
        do {
            let request = try MemoryRequestValidator.request(address: address, length: length)
            memory = try await debugService.readMemory(request)
            errorMessage = nil
        } catch {
            present(error)
        }
    }

    public func toggleBreakpoint(line: Int) async {
        guard line > 0, let document else { return }
        let previous = breakpoints
        let adding = !previous.lines.contains(line)
        breakpoints = previous.toggling(line)
        guard state == .stopped else { return }
        do {
            if adding {
                let breakpoint = try await debugService.setBreakpoint(file: document.sourceURL, line: line)
                breakpointIdentifiers[line] = breakpoint.id
            } else if let identifier = breakpointIdentifiers[line] {
                try await debugService.removeBreakpoint(identifier: identifier)
                breakpointIdentifiers[line] = nil
            }
        } catch {
            breakpoints = previous
            debugDiagnostics.append(DebugDiagnostic(
                pane: .session,
                isCritical: false,
                message: "断点更新失败，已恢复原状态：\(error.localizedDescription)"
            ))
        }
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
            console.replace(with: newSnapshot.console)
            debugDiagnostics.append(contentsOf: newSnapshot.diagnostics)
        case .consoleAppended(let entry):
            console.append(entry)
        case .diagnostic(let diagnostic):
            debugDiagnostics.append(diagnostic)
            if diagnostic.isCritical { errorMessage = diagnostic.message }
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
            if newState == .ready {
                breakpointIdentifiers = [:]
                clearRuntimePresentation()
            }
        }
    }

    private func performDebugCommand(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func beginStopIfNeeded() {
        guard stopTask == nil else { return }
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
        clearRuntimePresentation()
        stopTask = nil
        if let error { errorMessage = "停止调试器失败：\(error)" }
    }

    private func clearRuntimePresentation() {
        snapshot = nil
        registerRows = []
        memory = []
    }
}
