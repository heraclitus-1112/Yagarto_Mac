// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct DebugRegister: Equatable, Sendable {
    public let name: String
    public let number: Int?
    public let value: MIRawNumeric?

    public init(name: String, number: Int? = nil, value: MIRawNumeric? = nil) {
        self.name = name
        self.number = number
        self.value = value
    }
}

public enum DebugConsoleChannel: String, Codable, Sendable {
    case console
    case target
    case log
    case stderr
}

public struct DebugConsoleEntry: Equatable, Sendable {
    public let channel: DebugConsoleChannel
    public let text: String

    public init(channel: DebugConsoleChannel, text: String) {
        self.channel = channel
        self.text = text
    }
}

public enum DebugDiagnosticPane: String, Codable, Sendable {
    case frame
    case registers
    case stack
    case memory
    case disassembly
    case session
}

public struct DebugDiagnostic: Equatable, Sendable {
    public let pane: DebugDiagnosticPane
    public let isCritical: Bool
    public let message: String

    public init(pane: DebugDiagnosticPane, isCritical: Bool, message: String) {
        self.pane = pane
        self.isCritical = isCritical
        self.message = message
    }
}

public struct DebugMemoryRequest: Equatable, Sendable {
    public let address: String
    public let byteCount: Int
    public let observationID: UUID?

    public init(address: String, byteCount: Int, observationID: UUID? = nil) {
        self.address = address
        self.byteCount = byteCount
        self.observationID = observationID
    }

    public static let yagartoWindow = DebugMemoryRequest(address: "0x8000", byteCount: 112)
    public static let stackWindow = DebugMemoryRequest(address: "$sp", byteCount: 64)
}

public struct DebugBreakpoint: Equatable, Sendable {
    public let id: String
    public let location: String
    public let address: MIRawNumeric?

    public init(id: String, location: String, address: MIRawNumeric? = nil) {
        self.id = id
        self.location = location
        self.address = address
    }
}

public struct DebugSnapshot: Equatable, Sendable {
    public let stopReason: MIStopReason?
    public let location: MIFrame?
    public let registers: [DebugRegister]
    public let stack: [MIFrame]
    public let memory: [MIMemoryBlock]
    public let memoryRequest: DebugMemoryRequest?
    public let disassembly: [MIInstruction]
    public let console: [DebugConsoleEntry]
    public let diagnostics: [DebugDiagnostic]

    public init(
        stopReason: MIStopReason?,
        location: MIFrame?,
        registers: [DebugRegister],
        stack: [MIFrame],
        memory: [MIMemoryBlock],
        memoryRequest: DebugMemoryRequest? = nil,
        disassembly: [MIInstruction],
        console: [DebugConsoleEntry],
        diagnostics: [DebugDiagnostic]
    ) {
        self.stopReason = stopReason
        self.location = location
        self.registers = registers
        self.stack = stack
        self.memory = memory
        self.memoryRequest = memoryRequest
        self.disassembly = disassembly
        self.console = console
        self.diagnostics = diagnostics
    }
}

public enum DebuggerEvent: Equatable, Sendable {
    case stateChanged(DebuggerState)
    case snapshot(DebugSnapshot)
    case consoleAppended(DebugConsoleEntry)
    case diagnostic(DebugDiagnostic)
    case eventsDropped(total: Int)
}

public enum DebuggerControllerError: Error, Equatable, Sendable {
    case missingLaunchPlan
    case profileMismatch(expected: ProfileID, actual: ProfileID)
    case operationUnavailable(String, state: DebuggerState)
    case invalidMemoryRequest
    case invalidBreakpointLocation
    case invalidBreakpointID
    case missingBreakpointID
    case commandTimedOut(String)
}

extension DebuggerControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingLaunchPlan:
            return "尚未准备调试启动计划。"
        case .profileMismatch(let expected, let actual):
            return "调试目标不匹配：需要 \(expected.rawValue)，实际为 \(actual.rawValue)。"
        case .operationUnavailable(let operation, let state):
            return "当前调试状态（\(state.rawValue)）不能执行 \(operation)。"
        case .invalidMemoryRequest:
            return "内存读取参数无效。"
        case .invalidBreakpointLocation:
            return "断点位置无效。"
        case .invalidBreakpointID:
            return "断点编号无效。"
        case .missingBreakpointID:
            return "GDB 未返回断点编号。"
        case .commandTimedOut(let command):
            return "调试操作超时：\(command)。"
        }
    }
}
