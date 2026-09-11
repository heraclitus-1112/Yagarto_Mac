// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import YagartoCore

final class DebuggerStateMachineTests: XCTestCase {
    func testCompleteTransitionGraphAcceptsOnlyDocumentedEdges() throws {
        let graph: [DebuggerState: [DebuggerLifecycleEvent: DebuggerState]] = [
            .idle: [.buildStarted: .building],
            .building: [.buildSucceeded: .ready, .buildFailed: .idle],
            .ready: [.buildStarted: .building, .launchStarted: .launching],
            .launching: [
                .inferiorStopped: .stopped,
                .inferiorRunning: .running,
                .launchFailed: .ready,
                .terminationStarted: .terminating
            ],
            .stopped: [.inferiorRunning: .running, .terminationStarted: .terminating],
            .running: [.inferiorStopped: .stopped, .terminationStarted: .terminating],
            .terminating: [.terminationCompleted: .ready]
        ]

        for state in DebuggerState.allCases {
            for event in DebuggerLifecycleEvent.allCases {
                var machine = DebuggerStateMachine(initialState: state)
                if let expected = graph[state]?[event] {
                    XCTAssertNoThrow(try machine.apply(event), "\(state) + \(event)")
                    XCTAssertEqual(machine.state, expected, "\(state) + \(event)")
                } else {
                    XCTAssertThrowsError(try machine.apply(event), "\(state) + \(event)") {
                        XCTAssertEqual(
                            $0 as? DebuggerTransitionError,
                            DebuggerTransitionError(from: state, event: event)
                        )
                    }
                    XCTAssertEqual(machine.state, state, "rejection must not mutate state")
                }
            }
        }
    }

    func testStableFailurePathsAreExplicit() throws {
        var build = DebuggerStateMachine()
        try build.apply(.buildStarted)
        try build.apply(.buildFailed)
        XCTAssertEqual(build.state, .idle)

        var launch = DebuggerStateMachine(initialState: .ready)
        try launch.apply(.launchStarted)
        try launch.apply(.launchFailed)
        XCTAssertEqual(launch.state, .ready)

        var termination = DebuggerStateMachine(initialState: .running)
        try termination.apply(.terminationStarted)
        try termination.apply(.terminationCompleted)
        XCTAssertEqual(termination.state, .ready)
    }
}
