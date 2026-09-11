// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public struct MICommandFailure: Error, Equatable, Sendable {
    public let token: UInt64?
    public let command: String
    public let message: String?
    public let record: MIResultRecord

    public init(token: UInt64?, command: String, message: String?, record: MIResultRecord) {
        self.token = token
        self.command = command
        self.message = message
        self.record = record
    }
}

public enum GDBMISessionError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case invalidCommand
    case missingOptionValue(option: String)
    case launchFailed(executable: String, detail: String)
    case writeFailed(String)
    case waitFailed(String)
    case endOfFile
    case processExited(ProcessTermination)
    case commandFailed(MICommandFailure)

    public var exitCode: YagartoExitCode {
        switch self {
        case .launchFailed: .missingTool
        case .processExited, .writeFailed, .waitFailed, .endOfFile: .buildFailure
        case .notStarted, .alreadyStarted, .invalidCommand, .missingOptionValue, .commandFailed:
            .configuration
        }
    }

    public var isProcessExit: Bool {
        if case .processExited = self { return true }
        return false
    }
}

public enum GDBMIEvent: Equatable, Sendable {
    case asynchronous(MIAsyncRecord)
    case result(MIResultRecord)
    case orphanResult(MIResultRecord)
    case console(String)
    case target(String)
    case log(String)
    case stderr(String)
    case prompt
    case parseError(MIParseError)
    case endOfFile
    case processExited(ProcessTermination)
    case transportError(GDBMISessionError)
    case eventsDropped(total: Int)
}

public actor GDBMISession {
    private struct PendingRequest {
        let command: String
        let continuation: CheckedContinuation<MIResultRecord, any Error>
    }

    private let executable: String
    private let arguments: [String]
    private let argumentValidationError: GDBMISessionError?
    private let workingDirectory: URL
    private let parser: MIParser
    private let eventBufferLimit: Int

    private var processBox: GDBMIChildProcess?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var nextToken: UInt64 = 1
    private var pending: [UInt64: PendingRequest] = [:]
    private var subscribers: [UUID: AsyncStream<GDBMIEvent>.Continuation] = [:]
    private var stdoutLine = Data()
    private var stderrLine = Data()
    private var discardingStdoutLine = false
    private var discardingStderrLine = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var termination: ProcessTermination?
    private var terminalFailure: GDBMISessionError?
    private var totalDroppedEvents = 0

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        eventBufferLimit: Int = 256,
        maxLineBytes: Int = MIParser.defaultMaxLineBytes,
        maxDepth: Int = MIParser.defaultMaxDepth
    ) {
        self.executable = executable
        do {
            self.arguments = try Self.normalizedArguments(arguments)
            argumentValidationError = nil
        } catch let error as GDBMISessionError {
            self.arguments = []
            argumentValidationError = error
        } catch {
            self.arguments = []
            argumentValidationError = .launchFailed(
                executable: executable,
                detail: String(describing: error)
            )
        }
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.eventBufferLimit = max(1, eventBufferLimit)
        parser = MIParser(maxDepth: maxDepth, maxLineBytes: maxLineBytes)
    }

    public init(
        plan: DebugLaunchPlan,
        eventBufferLimit: Int = 256,
        maxLineBytes: Int = MIParser.defaultMaxLineBytes,
        maxDepth: Int = MIParser.defaultMaxDepth
    ) {
        self.init(
            executable: plan.gdbExecutable,
            arguments: plan.gdbArguments,
            workingDirectory: URL(fileURLWithPath: plan.projectDirectory, isDirectory: true),
            eventBufferLimit: eventBufferLimit,
            maxLineBytes: maxLineBytes,
            maxDepth: maxDepth
        )
    }

    static let launchStrategy = GDBMIProcessLaunchStrategy.posixSpawnProcessGroup

    public var processIdentifier: pid_t? { processBox?.processIdentifier }
    public var droppedEventCount: Int { totalDroppedEvents }

    public static func normalizedArguments(_ arguments: [String]) throws -> [String] {
        let optionsWithSeparateValues: Set<String> = [
            "-b", "--baud",
            "-c", "--core",
            "-cd", "--cd",
            "-d", "--directory",
            "-D", "--data-directory",
            "-e", "--exec",
            "-ex", "--eval-command",
            "-iex", "--init-eval-command",
            "-ix", "--init-command",
            "-l",
            "-p", "--pid",
            "-s", "--symbols",
            "-se", "--se",
            "-tty", "--tty",
            "-x", "--command"
        ]
        var normalized: [String] = []
        var interpreterInsertionIndex: Int?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            // Everything after --args or the conventional option terminator belongs
            // to the inferior/positional tail, so option-shaped strings stay intact.
            if argument == "--args" || argument == "--" {
                normalized.append(contentsOf: arguments[index...])
                break
            }

            // A GDB command or filename may itself begin with "--interpreter" (or
            // any other option spelling). Consume value-taking options atomically.
            if optionsWithSeparateValues.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    throw GDBMISessionError.missingOptionValue(option: argument)
                }
                normalized.append(argument)
                normalized.append(arguments[index + 1])
                index += 2
                continue
            }

            if let equalsIndex = argument.firstIndex(of: "=") {
                let option = String(argument[..<equalsIndex])
                if optionsWithSeparateValues.contains(option) {
                    let valueStart = argument.index(after: equalsIndex)
                    guard valueStart < argument.endIndex else {
                        throw GDBMISessionError.missingOptionValue(option: option)
                    }
                    normalized.append(argument)
                    index += 1
                    continue
                }
            }

            if argument == "--interpreter" || argument == "-i" {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("-") else {
                    throw GDBMISessionError.missingOptionValue(option: argument)
                }
                if interpreterInsertionIndex == nil {
                    interpreterInsertionIndex = normalized.count
                }
                index += 2
                continue
            }

            let attachedInterpreter: String?
            if argument.hasPrefix("--interpreter=") {
                attachedInterpreter = "--interpreter"
            } else if argument.hasPrefix("-i=") {
                attachedInterpreter = "-i"
            } else {
                attachedInterpreter = nil
            }
            if let attachedInterpreter {
                guard argument.count > attachedInterpreter.count + 1 else {
                    throw GDBMISessionError.missingOptionValue(option: attachedInterpreter)
                }
                if interpreterInsertionIndex == nil {
                    interpreterInsertionIndex = normalized.count
                }
                index += 1
                continue
            }

            normalized.append(argument)
            index += 1
        }
        normalized.insert("--interpreter=mi3", at: interpreterInsertionIndex ?? 0)
        return normalized
    }

    public func events() -> AsyncStream<GDBMIEvent> {
        let identifier = UUID()
        let pair = AsyncStream<GDBMIEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(eventBufferLimit)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        subscribers[identifier] = pair.continuation
        return pair.stream
    }

    public func start() throws {
        if let argumentValidationError {
            throw argumentValidationError
        }
        guard processBox == nil, termination == nil, terminalFailure == nil else {
            throw GDBMISessionError.alreadyStarted
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReader = stdoutPipe.fileHandleForReading
        let stderrReader = stderrPipe.fileHandleForReading
        stdoutReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStdout(data) }
        }
        stderrReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStderr(data) }
        }

        let child: GDBMIChildProcess
        do {
            child = try GDBMIChildProcess.spawn(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                standardInput: stdinPipe,
                standardOutput: stdoutPipe,
                standardError: stderrPipe
            )
        } catch {
            stdoutReader.readabilityHandler = nil
            stderrReader.readabilityHandler = nil
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutReader.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrReader.close()
            try? stderrPipe.fileHandleForWriting.close()
            if let sessionError = error as? GDBMISessionError {
                throw sessionError
            }
            throw GDBMISessionError.launchFailed(
                executable: executable,
                detail: String(describing: error)
            )
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        processBox = child
        inputHandle = stdinPipe.fileHandleForWriting
        outputHandle = stdoutReader
        errorHandle = stderrReader
        Task.detached { [weak self] in
            let result = child.waitForTermination()
            await self?.processDidTerminate(result)
        }
    }

    public func send(_ command: String) async throws -> MIResultRecord {
        try Task.checkCancellation()
        guard processBox != nil, termination == nil, terminalFailure == nil, !stdoutEOF else {
            if let terminalFailure { throw terminalFailure }
            throw termination.map(GDBMISessionError.processExited) ?? .notStarted
        }
        guard command.hasPrefix("-"),
              !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw GDBMISessionError.invalidCommand
        }
        let token = nextToken
        guard token < UInt64.max else {
            throw GDBMISessionError.writeFailed("MI token exhausted")
        }
        nextToken += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[token] = PendingRequest(command: command, continuation: continuation)
                do {
                    try inputHandle?.write(contentsOf: Data("\(token)\(command)\n".utf8))
                } catch {
                    if let request = pending.removeValue(forKey: token) {
                        request.continuation.resume(
                            throwing: GDBMISessionError.writeFailed(error.localizedDescription)
                        )
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(token) }
        }
    }

    public func shutdown(timeout: Duration = .seconds(2)) async {
        guard processBox != nil else {
            finishSubscribers()
            return
        }
        var exitCommand: Task<MIResultRecord, any Error>?
        if termination == nil, terminalFailure == nil {
            let commandTask = Task { try await self.send("-gdb-exit") }
            exitCommand = commandTask
            if !(await waitForExit(timeout: timeout)) {
                commandTask.cancel()
                signalProcess(SIGTERM)
                if !(await waitForExit(timeout: .milliseconds(250))) {
                    signalProcess(SIGKILL)
                    _ = await waitForExit(timeout: .seconds(1))
                }
            }
            commandTask.cancel()
        }
        if processBox?.groupExists() == true {
            signalProcess(SIGTERM)
            if !(await waitForGroupExit(timeout: .milliseconds(250))) {
                signalProcess(SIGKILL)
                _ = await waitForGroupExit(timeout: .seconds(1))
            }
        }
        if let exitCommand { _ = try? await exitCommand.value }
        closeHandles()
        failAllPending(
            with: terminalFailure ?? termination.map(GDBMISessionError.processExited) ?? .endOfFile
        )
        finishSubscribers()
        processBox = nil
    }

    private func cancelRequest(_ token: UInt64) {
        guard let request = pending.removeValue(forKey: token) else { return }
        request.continuation.resume(throwing: CancellationError())
    }

    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else {
            outputHandle?.readabilityHandler = nil
            flushStdoutAtEOF()
            stdoutEOF = true
            emit(.endOfFile)
            failAllPending(
                with: terminalFailure ?? termination.map(GDBMISessionError.processExited) ?? .endOfFile
            )
            finishSubscribersIfTerminalAndDrained()
            return
        }
        consume(data, line: &stdoutLine, discarding: &discardingStdoutLine) { [self] complete in
            parseStdoutLine(complete)
        }
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else {
            errorHandle?.readabilityHandler = nil
            if !stderrLine.isEmpty {
                emitStderrLine(stderrLine)
                stderrLine.removeAll(keepingCapacity: false)
            }
            stderrEOF = true
            finishSubscribersIfTerminalAndDrained()
            return
        }
        consume(data, line: &stderrLine, discarding: &discardingStderrLine) { [self] complete in
            emitStderrLine(complete)
        }
    }

    private func consume(
        _ data: Data,
        line: inout Data,
        discarding: inout Bool,
        processLine: (Data) -> Void
    ) {
        for byte in data {
            if discarding {
                if byte == 0x0A { discarding = false }
                continue
            }
            if byte == 0x0A {
                processLine(line)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > parser.maxLineBytes {
                    line.removeAll(keepingCapacity: false)
                    discarding = true
                    emit(.parseError(.lineTooLong(limit: parser.maxLineBytes)))
                }
            }
        }
    }

    private func flushStdoutAtEOF() {
        guard !stdoutLine.isEmpty, !discardingStdoutLine else { return }
        parseStdoutLine(stdoutLine)
        stdoutLine.removeAll(keepingCapacity: false)
    }

    private func parseStdoutLine(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            switch try parser.parse(data) {
            case .result(let record):
                receiveResult(record)
            case .asynchronous(let record):
                emit(.asynchronous(record))
            case .stream(let record):
                switch record.kind {
                case .console: emit(.console(record.text))
                case .target: emit(.target(record.text))
                case .log: emit(.log(record.text))
                }
            case .prompt:
                emit(.prompt)
            }
        } catch let error as MIParseError {
            emit(.parseError(error))
        } catch {
            emit(.parseError(.malformed(position: 0)))
        }
    }

    private func emitStderrLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else {
            emit(.parseError(.invalidUTF8))
            return
        }
        emit(.stderr(line.last == "\r" ? String(line.dropLast()) : line))
    }

    private func receiveResult(_ record: MIResultRecord) {
        guard let token = record.token else {
            emit(.result(record))
            return
        }
        guard let request = pending.removeValue(forKey: token) else {
            emit(.orphanResult(record))
            return
        }
        if record.resultClass == .error {
            request.continuation.resume(throwing: GDBMISessionError.commandFailed(MICommandFailure(
                token: token,
                command: request.command,
                message: record.errorMessage,
                record: record
            )))
        } else {
            request.continuation.resume(returning: record)
        }
    }

    private func processDidTerminate(
        _ result: Result<ProcessTermination, GDBMISessionError>
    ) {
        guard termination == nil, terminalFailure == nil else { return }
        switch result {
        case .success(let processTermination):
            termination = processTermination
            emit(.processExited(processTermination))
            failAllPending(with: .processExited(processTermination))
        case .failure(let error):
            terminalFailure = error
            emit(.transportError(error))
            failAllPending(with: error)
        }
        finishSubscribersIfTerminalAndDrained()
    }

    private func failAllPending(with error: GDBMISessionError) {
        let requests = pending.values
        pending.removeAll(keepingCapacity: false)
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    private func emit(_ event: GDBMIEvent) {
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

    private func finishSubscribers() {
        let continuations = subscribers.values
        subscribers.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.finish() }
    }

    private func finishSubscribersIfTerminalAndDrained() {
        guard (termination != nil || terminalFailure != nil), stdoutEOF, stderrEOF else { return }
        finishSubscribers()
    }

    private func waitForExit(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while termination == nil, terminalFailure == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return termination != nil || terminalFailure != nil
    }

    private func waitForGroupExit(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processBox?.groupExists() == true, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return processBox?.groupExists() != true
    }

    private func signalProcess(_ signal: Int32) {
        processBox?.signalGroup(signal)
    }

    private func closeHandles() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }
}
