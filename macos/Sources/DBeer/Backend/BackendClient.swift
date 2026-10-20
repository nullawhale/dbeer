import Darwin
import Foundation

/// Local command rejection before a request is registered or written to stdin.
/// Keep this distinct from a malformed or oversized reply from the helper.
enum BackendRequestError: LocalizedError, Sendable, Equatable {
    case invalidCommand, duplicateRequest, frameTooLarge, encodingFailed

    var errorDescription: String? {
        let explanation: String
        switch self {
        case .invalidCommand: explanation = "The command is invalid."
        case .duplicateRequest: explanation = "A command identifier was reused."
        case .frameTooLarge: explanation = "The command exceeds the 16 MiB transport limit."
        case .encodingFailed: explanation = "The command could not be encoded."
        }
        return explanation + " The command was not sent."
    }
}

/// Serial pipe writes run independently of the client actor, so a helper that
/// stops reading cannot prevent the actor's shutdown deadline from firing.
private final class PipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dbeer.helper.stdin")

    init(_ handle: FileHandle) {
        self.handle = handle
        // EPIPE must be a transport error rather than a signal killing the UI.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                try self.handle.write(contentsOf: data)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    func close() {
        queue.async { try? self.handle.close() }
    }
}

actor BackendClient {
    struct Exit: Sendable { let status: Int32 }
    struct Shutdown: Sendable {
        let acknowledged: Bool
        let forced: Bool
    }

    private struct Pending {
        let command: BackendCommand
        let continuation: CheckedContinuation<BackendMessage, Error>
        let onEvent: (@Sendable (BackendMessage) -> Void)?
        var started = false
        var streamSequence = 0
        var streamSets: [QueryResultSet] = []
        var streamRows = 0
        var streamBytes = 0
    }

    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var writer: PipeWriter?
    private var outputReader: Task<Void, Never>?
    private var errorReader: Task<Int, Never>?
    private var pending: [String: Pending] = [:]
    private var usedRequestIDs: Set<String> = []
    private var failure: BackendTransportError?
    private var failureWaiters: [CheckedContinuation<BackendTransportError, Never>] = []
    private var exit: Exit?
    private var exitWaiters: [CheckedContinuation<Exit, Never>] = []
    private var ready = false
    private var capturedExportSupported = false
    private var shuttingDown = false
    private var wasForced = false
    private var shutdownTask: Task<Shutdown, Never>?

    init(executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    nonisolated static func bundledExecutableURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/dbeer-core", isDirectory: false)
    }

    func start() async throws {
        guard process == nil else { throw BackendTransportError(.alreadyStarted) }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BackendTransportError(.missingExecutable)
        }

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { await self?.didExit(status: status) }
        }
        try child.run()
        process = child
        writer = PipeWriter(stdin.fileHandleForWriting)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let errorHandle = stderr.fileHandleForReading
        errorReader = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "dbeer.helper.stderr", qos: .utility).async {
                    defer { try? errorHandle.close() }
                    var count = 0
                    // Never retain or display diagnostics that could contain SQL
                    // or credentials. Blocking reads use dedicated GCD threads.
                    while let data = try? Self.readChunk(errorHandle), !data.isEmpty {
                        count += data.count
                    }
                    continuation.resume(returning: count)
                }
            }
        }
        let outputHandle = stdout.fileHandleForReading
        outputReader = Task.detached { [weak self] in
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "dbeer.helper.stdout", qos: .utility).async { [weak self] in
                    defer {
                        try? outputHandle.close()
                        continuation.resume()
                    }
                    var framer = NDJSONFramer()
                    do {
                        while let bytes = try Self.readChunk(outputHandle), !bytes.isEmpty {
                            for frame in try framer.append(bytes) {
                                let reply = try NDJSONFramer.decode(frame)
                                // Only the dedicated reader thread waits. The
                                // actor remains free to cancel or kill the child
                                // while pipe backpressure bounds unread replies.
                                Self.deliver { [weak self] in await self?.receive(reply) }
                            }
                        }
                        try framer.finish()
                        Self.deliver { [weak self] in await self?.outputEnded() }
                    } catch {
                        let failure = (error as? BackendTransportError) ?? BackendTransportError(.invalidMessage)
                        Self.deliver { [weak self] in await self?.fail(failure) }
                    }
                }
            }
        }

        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.handshakeExpired()
        }
        defer { deadline.cancel() }
        _ = try await send(.hello(), lifecycle: true)
        guard !shuttingDown else { throw BackendTransportError(.notReady) }
        ready = true
    }

    /// Returns the terminal reply. `query.started` is delivered separately;
    /// cancelling a SQL query uses an explicit cancel command, not Task.cancel.
    func supportsCapturedExport() -> Bool { capturedExportSupported }

    func request(_ command: BackendCommand,
                 onEvent: (@Sendable (BackendMessage) -> Void)? = nil) async throws -> BackendMessage {
        if command.export?.destination != nil, !capturedExportSupported { throw BackendTransportError(.unsupportedCapturedExport) }
        return try await send(command, onEvent: onEvent)
    }

    func waitForFailure() async -> BackendTransportError {
        if let failure { return failure }
        if shuttingDown { return BackendTransportError(.notReady) }
        return await withCheckedContinuation { failureWaiters.append($0) }
    }

    func waitForExit() async -> Exit {
        if let exit { return exit }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    func stderrBytesRead() async -> Int {
        await errorReader?.value ?? 0
    }

    func shutdown() async -> Shutdown {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        return await task.value
    }

    private func performShutdown() async -> Shutdown {
        guard process != nil else { return Shutdown(acknowledged: false, forced: false) }
        shuttingDown = true
        ready = false
        // Release observers on intentional shutdown too, so replacing a failed
        // helper does not retain its process client and suspended observer.
        for waiter in failureWaiters { waiter.resume(returning: BackendTransportError(.notReady)) }
        failureWaiters.removeAll()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.forceExitIfNeeded()
        }
        var acknowledged = false
        if exit == nil, failure == nil {
            acknowledged = (try? await send(.shutdown(), lifecycle: true))?.type == "shutdown.ack"
        }
        writer?.close()
        _ = await waitForExit()
        deadline.cancel()
        await outputReader?.value
        _ = await errorReader?.value
        return Shutdown(acknowledged: acknowledged, forced: wasForced)
    }

    private func send(_ command: BackendCommand, lifecycle: Bool = false,
                      onEvent: (@Sendable (BackendMessage) -> Void)? = nil) async throws -> BackendMessage {
        if let failure { throw failure }
        guard lifecycle || (ready && !shuttingDown), let writer else {
            throw BackendTransportError(.notReady)
        }
        guard BackendMessage.validID(command.requestId), command.terminalType != nil else {
            throw BackendRequestError.invalidCommand
        }
        guard !usedRequestIDs.contains(command.requestId) else {
            throw BackendRequestError.duplicateRequest
        }
        var data: Data
        do { data = try JSONEncoder().encode(command) }
        catch { throw BackendRequestError.encodingFailed }
        guard data.count <= BackendProtocol.maxFrameBytes else { throw BackendRequestError.frameTooLarge }
        data.append(0x0A)
        usedRequestIDs.insert(command.requestId)
        let frame = data
        return try await withCheckedThrowingContinuation { continuation in
            pending[command.requestId] = Pending(command: command, continuation: continuation, onEvent: onEvent)
            writer.write(frame) { [weak self] success in
                if !success {
                    Task { await self?.fail(BackendTransportError(.writeFailed)) }
                }
            }
        }
    }

    private func receive(_ reply: BackendMessage) {
        guard failure == nil else { return }
        guard var request = pending[reply.requestId] else {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        let command = request.command
        guard (command.sessionId == nil || command.sessionId == reply.sessionId),
              (command.queryId == nil || command.queryId == reply.queryId) else {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        if command.type == "connect", reply.type == "connect.result", reply.engine != command.connection?.engine {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        if reply.type == "query.started", ["execute", "catalog", "changes.preview", "changes.apply"].contains(command.type), !request.started {
            request.started = true
            pending[reply.requestId] = request
            request.onEvent?(reply)
            return
        }
        if reply.type == "query.progress" {
            guard command.export != nil, request.started, let sequence = reply.sequence, sequence == request.streamSequence + 1 else { fail(BackendTransportError(.invalidMessage)); return }
            request.streamSequence = sequence
            pending[reply.requestId] = request
            do { try acknowledgeChunk(reply) } catch { fail(BackendTransportError(.invalidMessage)); return }
            request.onEvent?(reply)
            return
        }
        if reply.type == "query.chunk" {
            do {
                guard command.stream == true, request.started else { throw BackendTransportError(.invalidMessage) }
                try appendChunk(reply, request: &request)
                pending[reply.requestId] = request
                try acknowledgeChunk(reply)
            } catch { fail(BackendTransportError(.invalidMessage)) }
            return
        }
        guard reply.type == command.terminalType || reply.type == "error" else {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        // The original frame has already validated optional product metadata.
        // Native SwiftUI helpers remain compatible without GPUI product pairing.
        if reply.type == "hello.ack" { capturedExportSupported = reply.capabilities?.contains("capturedExportV1") == true }
        if reply.type == "hello.ack", reply.protocolVersion != BackendProtocol.version {
            fail(BackendTransportError(.incompatibleVersion(reply.protocolVersion ?? -1)))
            return
        }
        let terminal: BackendMessage
        do { terminal = try hydrate(reply, request: request) }
        catch { fail(BackendTransportError(.invalidMessage)); return }
        pending.removeValue(forKey: reply.requestId)
        if terminal.type == "error" {
            request.continuation.resume(throwing: BackendRemoteError(reply: terminal))
        } else {
            request.continuation.resume(returning: terminal)
        }
    }

    private func appendChunk(_ reply: BackendMessage, request: inout Pending) throws {
        guard let sequence = reply.sequence, sequence == request.streamSequence + 1,
              let index = reply.resultIndex, let rows = reply.rows else { throw BackendTransportError(.invalidMessage) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let columns = reply.columns {
            guard index == request.streamSets.count else { throw BackendTransportError(.invalidMessage) }
            request.streamBytes += try encoder.encode(columns).count + 1_024
            request.streamSets.append(QueryResultSet(columns: columns))
        }
        guard index == request.streamSets.count - 1,
              rows.allSatisfy({ $0.count == request.streamSets[index].columns.count }) else {
            throw BackendTransportError(.invalidMessage)
        }
        request.streamRows += rows.count
        for row in rows { request.streamBytes += try encoder.encode(row).count + 1 }
        guard request.streamRows <= 1_000, request.streamBytes <= 8 * 1_024 * 1_024 else {
            throw BackendTransportError(.invalidMessage)
        }
        request.streamSets[index].rows.append(contentsOf: rows)
        request.streamSequence = sequence
    }

    private func acknowledgeChunk(_ reply: BackendMessage) throws {
        guard let writer else { throw BackendTransportError(.notReady) }
        let command = BackendCommand(type: "stream.ack", requestId: UUID().uuidString,
            sessionId: reply.sessionId, queryId: reply.queryId, sequence: reply.sequence)
        var frame = try JSONEncoder().encode(command)
        frame.append(0x0A)
        writer.write(frame) { [weak self] success in
            if !success { Task { await self?.fail(BackendTransportError(.writeFailed)) } }
        }
    }

    private func hydrate(_ reply: BackendMessage, request: Pending) throws -> BackendMessage {
        guard reply.streamed == true else {
            guard request.streamSequence == 0 else { throw BackendTransportError(.invalidMessage) }
            try validateAggregate(reply)
            return reply
        }
        guard var sets = reply.resultSets, sets.count <= request.streamSets.count,
              reply.type == "error" || sets.count == request.streamSets.count else {
            throw BackendTransportError(.invalidMessage)
        }
        for index in sets.indices {
            guard sets[index].columns == request.streamSets[index].columns,
                  sets[index].displayedRowCount == request.streamSets[index].rows.count else {
                throw BackendTransportError(.invalidMessage)
            }
            sets[index].rows = request.streamSets[index].rows
        }
        var result = reply
        result.streamed = nil
        result.resultSets = sets
        if result.type == "query.result" {
            if let first = sets.first(where: { !$0.columns.isEmpty }) ?? sets.first {
                result.columns = first.columns; result.rows = first.rows
                result.commandTag = first.commandTag; result.rowCount = first.rowCount
                result.displayedRowCount = first.displayedRowCount
                result.truncated = first.truncated; result.displayNotice = first.displayNotice
                result.affectedRowCountKnown = first.affectedRowCountKnown; result.nextCursor = first.nextCursor
            } else {
                result.columns = []; result.rows = []; result.displayedRowCount = 0
            }
        }
        try result.validate()
        try validateAggregate(result)
        return result
    }

    private func validateAggregate(_ reply: BackendMessage) throws {
        let sets: [QueryResultSet]
        if let results = reply.resultSets { sets = results }
        else if reply.type == "query.result" {
            sets = [QueryResultSet(columns: reply.columns ?? [], rows: reply.rows ?? [],
                commandTag: reply.commandTag ?? "", rowCount: reply.rowCount ?? 0,
                displayedRowCount: reply.displayedRowCount ?? 0, truncated: reply.truncated ?? false,
                displayNotice: reply.displayNotice)]
        } else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard sets.count <= 1_024, sets.reduce(0, { $0 + $1.rows.count }) <= 1_000,
              try encoder.encode(sets).count <= 8 * 1_024 * 1_024 else {
            throw BackendTransportError(.invalidMessage)
        }
    }

    private func handshakeExpired() {
        if !ready && !shuttingDown { fail(BackendTransportError(.handshakeTimeout)) }
    }

    private func outputEnded() {
        if shuttingDown {
            failPending(BackendTransportError(.unexpectedEOF))
        } else if let process, !process.isRunning {
            fail(BackendTransportError(.processExited(process.terminationStatus)))
        } else {
            fail(BackendTransportError(.unexpectedEOF))
        }
    }

    private func failPending(_ error: BackendTransportError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            var contextualError = error
            contextualError.outcomeUnknown = ["execute", "catalog", "changes.apply"].contains(request.command.type)
            request.continuation.resume(throwing: contextualError)
        }
    }

    private func fail(_ error: BackendTransportError) {
        guard failure == nil else { return }
        failure = error
        ready = false
        failPending(error)
        for waiter in failureWaiters { waiter.resume(returning: error) }
        failureWaiters.removeAll()
        writer?.close()
        // A helper that has lost its protocol output is unusable. Reap it even
        // if it remains alive, so the application never keeps an orphan session.
        forceExitIfNeeded()
    }

    private func forceExitIfNeeded() {
        guard exit == nil, let process, process.isRunning else { return }
        wasForced = true
        kill(process.processIdentifier, SIGKILL)
    }

    private func didExit(status: Int32) async {
        guard exit == nil else { return }
        let result = Exit(status: status)
        exit = result
        for waiter in exitWaiters { waiter.resume(returning: result) }
        exitWaiters.removeAll()
        // The final reply can be in the pipe when Process reports termination.
        await outputReader?.value
        if !shuttingDown { fail(BackendTransportError(.processExited(status))) }
    }

    private nonisolated static func readChunk(_ handle: FileHandle) throws -> Data? {
        while true {
            var buffer = Data(count: 65_536)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw BackendTransportError(.unexpectedEOF)
            }
            buffer.count = count
            return buffer
        }
    }

    /// A single decoded frame may be in flight from the blocking reader. Never
    /// call this on the client actor or Swift's cooperative executor.
    private nonisolated static func deliver(_ consume: @escaping @Sendable () async -> Void) {
        let consumed = DispatchSemaphore(value: 0)
        Task {
            await consume()
            consumed.signal()
        }
        consumed.wait()
    }
}
