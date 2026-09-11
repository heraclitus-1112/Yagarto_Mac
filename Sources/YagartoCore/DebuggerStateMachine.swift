// SPDX-License-Identifier: GPL-3.0-or-later

public enum DebuggerState: String, CaseIterable, Codable, Sendable {
    case idle
    case building
    case ready
    case launching
    case stopped
    case running
    case terminating
}

public enum DebuggerLifecycleEvent: String, CaseIterable, Codable, Sendable {
    case buildStarted
    case buildSucceeded
    case buildFailed
    case launchStarted
    case launchFailed
    case inferiorStopped
    case inferiorRunning
    case terminationStarted
    case terminationCompleted
}

public struct DebuggerTransitionError: Error, Equatable, Sendable {
    public let from: DebuggerState
    public let event: DebuggerLifecycleEvent

    public init(from: DebuggerState, event: DebuggerLifecycleEvent) {
        self.from = from
        self.event = event
    }
}

public struct DebuggerStateMachine: Sendable {
    public private(set) var state: DebuggerState

    public init(initialState: DebuggerState = .idle) {
        state = initialState
    }

    public mutating func apply(_ event: DebuggerLifecycleEvent) throws {
        let next: DebuggerState?
        switch (state, event) {
        case (.idle, .buildStarted), (.ready, .buildStarted): next = .building
        case (.building, .buildSucceeded): next = .ready
        case (.building, .buildFailed): next = .idle
        case (.ready, .launchStarted): next = .launching
        case (.launching, .launchFailed): next = .ready
        case (.launching, .inferiorStopped), (.running, .inferiorStopped): next = .stopped
        case (.launching, .inferiorRunning), (.stopped, .inferiorRunning): next = .running
        case (.launching, .terminationStarted),
             (.stopped, .terminationStarted),
             (.running, .terminationStarted): next = .terminating
        case (.terminating, .terminationCompleted): next = .ready
        default: next = nil
        }
        guard let next else {
            throw DebuggerTransitionError(from: state, event: event)
        }
        state = next
    }
}
