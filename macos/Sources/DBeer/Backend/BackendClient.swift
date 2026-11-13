import Darwin
import Foundation

/// Local command rejection before a request is registered or written to stdin.
/// Keep this distinct from a malformed or oversized reply from the helper.
enum BackendRequestError: LocalizedError, Sendable, Equatable {
    case invalidCommand, duplicateRequest, frameTooLarge, encodingFailed, unsupportedSSHConfiguration, unsupportedPasswordCommand, unsupportedQueryParameters, unsupportedTableImport, unsupportedSessionMonitor

    var errorDescription: String? {
        let explanation: String
        switch self {
        case .invalidCommand: explanation = "The command is invalid."
        case .duplicateRequest: explanation = "A command identifier was reused."
        case .frameTooLarge: explanation = "The command exceeds the 16 MiB transport limit."
        case .encodingFailed: explanation = "The command could not be encoded."
        case .unsupportedSSHConfiguration: explanation = "This helper does not support OpenSSH configuration. Rebuild the matching app and helper."
        case .unsupportedPasswordCommand: explanation = "This helper does not support password commands. Rebuild the matching app and helper."
        case .unsupportedQueryParameters: explanation = "This helper does not support query parameters. Rebuild the matching app and helper."
        case .unsupportedTableImport: explanation = "This helper does not support table import. Rebuild the matching app and helper."
        case .unsupportedSessionMonitor: explanation = "This helper does not support the session monitor. Rebuild the matching app and helper."
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
    private let environment: [String: String]
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
    private var sshTunnelsSupported = false
    private var sshConfigurationSupported = false
    private var passwordCommandSupported = false
    private var insertFormattingSupported = false
    private var resultComparisonSupported = false
    private var schemaComparisonSupported = false
    private var dataComparisonSupported = false
    private var synchronizationPlanSupported = false
    private var queryParametersSupported = false
    private var tableImportSupported = false
    private var sessionMonitorSupported = false
    private var databaseToolsSupported = false
    private var dataTransferSupported = false
    private var shuttingDown = false
    private var wasForced = false
    private var shutdownTask: Task<Shutdown, Never>?

    init(executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = [], environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
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
        if !environment.isEmpty {
            child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        }
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
    func supportsInsertFormatting() -> Bool { insertFormattingSupported }
    func supportsResultComparison() -> Bool { resultComparisonSupported }
    func supportsQueryParameters() -> Bool { queryParametersSupported }
    func supportsTableImport() -> Bool { tableImportSupported }
    func supportsSessionMonitor() -> Bool { sessionMonitorSupported }
    func supportsDatabaseTools() -> Bool { databaseToolsSupported }
    func supportsDataTransfer() -> Bool { dataTransferSupported }

    func request(_ command: BackendCommand,
                 onEvent: (@Sendable (BackendMessage) -> Void)? = nil) async throws -> BackendMessage {
        if ["catalog.page", "catalog.batch", "catalog.close"].contains(command.type) {
            guard command.catalogMetadata?.valid(for: command.type) == true,
                  command.sessionId.map(BackendMessage.validID) == true, command.queryId.map(BackendMessage.validID) == true,
                  command.catalog == nil, command.sql == nil, command.connection == nil, command.stream == nil,
                  command.changes == nil, command.explain == nil, command.structure == nil, command.operations == nil,
                  command.authorization == nil, command.parameters == nil, command.tableImport == nil,
                  command.databaseTools == nil, command.transfer == nil, command.comparison == nil,
                  command.schemaComparison == nil, command.dataComparison == nil, command.protocolVersion == nil,
                  command.export == nil, command.sequence == nil, command.sshTrust == nil, command.insert == nil else {
                throw BackendRequestError.invalidCommand
            }
        } else if command.catalogMetadata != nil { throw BackendRequestError.invalidCommand }
        if command.type.hasPrefix("dbtools.") || command.type.hasPrefix("transfer.") {
            guard command.sessionId == nil, command.queryId == nil, command.connection == nil, command.sql == nil,
                  command.catalog == nil, command.stream == nil, command.export == nil, command.sequence == nil,
                  command.changes == nil, command.operations == nil, command.authorization == nil, command.sshTrust == nil,
                  command.insert == nil, command.comparison == nil, command.schemaComparison == nil, command.dataComparison == nil,
                  command.explain == nil, command.structure == nil, command.parameters == nil, command.tableImport == nil,
                  command.protocolVersion == nil else { throw BackendRequestError.invalidCommand }
            let settings: [ConnectionSettings]
            if command.type.hasPrefix("dbtools.") {
                guard databaseToolsSupported, command.databaseTools?.valid(for: command.type) == true, command.transfer == nil else {
                    throw BackendRequestError.invalidCommand
                }
                settings = command.databaseTools?.connection.map { [$0] } ?? []
            } else {
                guard dataTransferSupported, command.transfer?.valid(for: command.type) == true, command.databaseTools == nil else {
                    throw BackendRequestError.invalidCommand
                }
                settings = command.transfer?.transportConnections ?? []
            }
            for connection in settings {
                if connection.passwordCommand != nil, !passwordCommandSupported { throw BackendRequestError.unsupportedPasswordCommand }
                if connection.ssh?.authMethod == .openSSH, !sshConfigurationSupported { throw BackendRequestError.unsupportedSSHConfiguration }
            }
        } else if command.databaseTools != nil || command.transfer != nil {
            throw BackendRequestError.invalidCommand
        }
        if command.type == "monitor.snapshot" {
            guard sessionMonitorSupported else { throw BackendRequestError.unsupportedSessionMonitor }
            guard command.sessionId.map(BackendMessage.validID) == true, command.queryId.map(BackendMessage.validID) == true,
                  command.protocolVersion == nil, command.connection == nil, command.sql == nil, command.catalog == nil,
                  command.stream == nil, command.export == nil, command.sequence == nil, command.changes == nil,
                  command.operations == nil, command.authorization == nil, command.sshTrust == nil, command.insert == nil,
                  command.comparison == nil, command.schemaComparison == nil, command.dataComparison == nil,
                  command.explain == nil, command.structure == nil, command.parameters == nil, command.tableImport == nil else {
                throw BackendRequestError.invalidCommand
            }
        }
        if command.type.hasPrefix("import.") {
            guard tableImportSupported else { throw BackendRequestError.unsupportedTableImport }
            guard command.tableImport?.valid(for: command.type) == true,
                  command.sessionId.map(BackendMessage.validID) == true, command.queryId.map(BackendMessage.validID) == true,
                  command.sql == nil, command.parameters == nil, command.catalog == nil, command.connection == nil,
                  command.stream == nil, command.export == nil, command.changes == nil, command.operations == nil,
                  command.explain == nil, command.structure == nil, command.comparison == nil,
                  command.schemaComparison == nil, command.dataComparison == nil, command.insert == nil,
                  command.protocolVersion == nil, command.sequence == nil, command.sshTrust == nil,
                  command.type == "import.apply" || command.authorization == nil else { throw BackendRequestError.invalidCommand }
        } else if command.tableImport != nil { throw BackendRequestError.invalidCommand }
        for operation in command.operations ?? [] where operation.type == "import.apply" || operation.tableImport != nil {
            guard tableImportSupported else { throw BackendRequestError.unsupportedTableImport }
            guard command.type == "operation.assess", operation.type == "import.apply",
                  operation.tableImport?.valid(for: "import.apply") == true, operation.sql == nil,
                  operation.parameters == nil, operation.export == nil, operation.changes == nil,
                  operation.structure == nil, operation.explain == nil else { throw BackendRequestError.invalidCommand }
        }
        if let parameters = command.parameters {
            guard queryParametersSupported else { throw BackendRequestError.unsupportedQueryParameters }
            guard command.type == "execute", command.catalog == nil, command.changes == nil,
                  command.explain == nil, command.structure == nil else { throw BackendRequestError.invalidCommand }
            do { try QueryParameterBinding.validate(parameters) }
            catch { throw BackendRequestError.invalidCommand }
        }
        for operation in command.operations ?? [] {
            if let parameters = operation.parameters {
                guard queryParametersSupported else { throw BackendRequestError.unsupportedQueryParameters }
                guard command.type == "operation.assess", operation.type == "execute",
                      operation.changes == nil, operation.explain == nil, operation.structure == nil else {
                    throw BackendRequestError.invalidCommand
                }
                do { try QueryParameterBinding.validate(parameters) }
                catch { throw BackendRequestError.invalidCommand }
            }
        }
        if command.type == "explain.run" {
            guard command.explain?.valid == true, command.sessionId.map(BackendMessage.validID) == true,
                  command.queryId.map(BackendMessage.validID) == true, command.sql == nil, command.catalog == nil,
                  command.stream == nil, command.export == nil, command.changes == nil, command.operations == nil,
                  command.connection == nil, command.comparison == nil, command.schemaComparison == nil, command.dataComparison == nil,
                  command.structure == nil, command.protocolVersion == nil, command.sequence == nil,
                  command.insert == nil, command.sshTrust == nil else { throw BackendRequestError.invalidCommand }
        } else if command.explain != nil { throw BackendRequestError.invalidCommand }
        if command.type.hasPrefix("structure.") {
            guard command.structure?.valid(for: command.type) == true,
                  command.sessionId.map(BackendMessage.validID) == true, command.queryId.map(BackendMessage.validID) == true,
                  command.sql == nil, command.catalog == nil, command.connection == nil, command.stream == nil,
                  command.changes == nil, command.export == nil, command.operations == nil,
                  command.comparison == nil, command.schemaComparison == nil, command.dataComparison == nil,
                  command.protocolVersion == nil, command.sequence == nil, command.insert == nil, command.sshTrust == nil, command.explain == nil,
                  command.type == "structure.apply" || command.authorization == nil else { throw BackendRequestError.invalidCommand }
        } else if command.structure != nil { throw BackendRequestError.invalidCommand }
        if command.type == "data.plan" || command.type == "schema.plan" {
            guard synchronizationPlanSupported else { throw BackendRequestError.invalidCommand }
        }
        if command.type.hasPrefix("data.") {
            guard dataComparisonSupported, command.dataComparison?.valid(for: command.type) == true,
                  command.sessionId == nil, command.queryId == nil, command.connection == nil, command.sql == nil, command.catalog == nil,
                  command.protocolVersion == nil, command.stream == nil, command.export == nil, command.changes == nil,
                  command.operations == nil, command.authorization == nil, command.sequence == nil, command.sshTrust == nil,
                  command.insert == nil, command.comparison == nil, command.schemaComparison == nil else { throw BackendRequestError.invalidCommand }
            for settings in [command.dataComparison?.source?.connection, command.dataComparison?.target?.connection].compactMap({ $0 }) {
                if settings.passwordCommand != nil, !passwordCommandSupported { throw BackendRequestError.unsupportedPasswordCommand }
                if settings.ssh?.authMethod == .openSSH, !sshConfigurationSupported { throw BackendRequestError.unsupportedSSHConfiguration }
            }
        } else if command.dataComparison != nil { throw BackendRequestError.invalidCommand }
        if command.type.hasPrefix("schema.") {
            guard schemaComparisonSupported, command.schemaComparison?.valid(for: command.type) == true,
                  command.sessionId == nil, command.queryId == nil, command.connection == nil, command.sql == nil, command.catalog == nil,
                  command.protocolVersion == nil, command.stream == nil, command.export == nil, command.changes == nil,
                  command.operations == nil, command.authorization == nil, command.sequence == nil, command.sshTrust == nil,
                  command.insert == nil, command.comparison == nil else { throw BackendRequestError.invalidCommand }
            for settings in [command.schemaComparison?.source?.connection, command.schemaComparison?.target?.connection].compactMap({ $0 }) {
                if settings.passwordCommand != nil, !passwordCommandSupported { throw BackendRequestError.unsupportedPasswordCommand }
                if settings.ssh?.authMethod == .openSSH, !sshConfigurationSupported { throw BackendRequestError.unsupportedSSHConfiguration }
            }
        } else if command.schemaComparison != nil { throw BackendRequestError.invalidCommand }
        if command.type.hasPrefix("compare.") {
            guard resultComparisonSupported else { throw BackendTransportError(.unsupportedResultComparison) }
            guard command.comparison?.valid(for: command.type) == true,
                  command.sessionId == nil, command.queryId == nil, command.connection == nil,
                  command.sql == nil, command.catalog == nil, command.protocolVersion == nil,
                  command.stream == nil, command.export == nil, command.changes == nil,
                  command.operations == nil, command.authorization == nil, command.sequence == nil,
                  command.sshTrust == nil, command.insert == nil else { throw BackendRequestError.invalidCommand }
        } else if command.comparison != nil { throw BackendRequestError.invalidCommand }
        if let purpose = command.connection?.sessionPurpose {
            guard ["structure", "import", "monitor"].contains(purpose), ["connect", "ssh.probe", "ssh.trust"].contains(command.type),
                  command.connection.map({ (purpose == "monitor" ? [.postgresql, .mysql] : [.postgresql, .mysql, .sqlite]).contains($0.engine) }) == true else {
                throw BackendRequestError.invalidCommand
            }
            if purpose == "import", !tableImportSupported { throw BackendRequestError.unsupportedTableImport }
            if purpose == "monitor", !sessionMonitorSupported { throw BackendRequestError.unsupportedSessionMonitor }
        }
        if command.connection?.passwordCommand != nil, !passwordCommandSupported {
            throw BackendRequestError.unsupportedPasswordCommand
        }
        if command.connection?.ssh?.authMethod == .openSSH, !sshConfigurationSupported {
            throw BackendRequestError.unsupportedSSHConfiguration
        }
        if command.export?.destination != nil, !capturedExportSupported { throw BackendTransportError(.unsupportedCapturedExport) }
        if command.type == "formatInserts" {
            guard insertFormattingSupported else { throw BackendTransportError(.unsupportedInsertFormatting) }
            guard command.insert?.valid == true, command.sessionId == nil, command.queryId == nil,
                  command.connection == nil, command.sql == nil, command.catalog == nil,
                  command.protocolVersion == nil, command.stream == nil, command.export == nil,
                  command.changes == nil, command.operations == nil, command.authorization == nil,
                  command.sequence == nil, command.sshTrust == nil else {
                throw BackendRequestError.invalidCommand
            }
        }
        return try await send(command, onEvent: onEvent)
    }

    func waitForFailure() async -> BackendTransportError {
        if let failure { return failure }
        if shuttingDown { return BackendTransportError(.notReady) }
        return await withCheckedContinuation { failureWaiters.append($0) }
    }

    func hasExited() -> Bool { exit != nil }

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
        let shutdownGrace: Duration = sshTunnelsSupported ? .seconds(6) : databaseToolsSupported ? .seconds(4) : .seconds(2)
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: shutdownGrace) } catch { return }
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
        if reply.type == "query.started", (["execute", "explain.run", "monitor.snapshot", "catalog", "catalog.page", "catalog.batch", "catalog.close", "changes.preview", "changes.apply"].contains(command.type) || command.type.hasPrefix("structure.") || command.type.hasPrefix("import.")), !request.started {
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
        if reply.type == "hello.ack" {
            capturedExportSupported = reply.capabilities?.contains("capturedExportV1") == true
            sshTunnelsSupported = reply.capabilities?.contains("sshTunnelsV1") == true
            sshConfigurationSupported = reply.capabilities?.contains("sshConfigV1") == true
            passwordCommandSupported = reply.capabilities?.contains("passwordCommandV1") == true
            insertFormattingSupported = reply.capabilities?.contains("formatInsertsV1") == true
            resultComparisonSupported = reply.capabilities?.contains("resultComparisonV1") == true
            schemaComparisonSupported = reply.capabilities?.contains("schemaComparisonV1") == true
            dataComparisonSupported = reply.capabilities?.contains("dataComparisonV1") == true
            synchronizationPlanSupported = reply.capabilities?.contains("synchronizationPlanV1") == true
            queryParametersSupported = reply.capabilities?.contains("queryParametersV1") == true
            tableImportSupported = reply.capabilities?.contains("tableImportV1") == true
            sessionMonitorSupported = reply.capabilities?.contains("sessionMonitorV1") == true
            databaseToolsSupported = reply.capabilities?.contains("databaseToolsV1") == true
            dataTransferSupported = reply.capabilities?.contains("dataTransferV1") == true
        }
        if reply.type == "hello.ack", reply.protocolVersion != BackendProtocol.version {
            fail(BackendTransportError(.incompatibleVersion(reply.protocolVersion ?? -1)))
            return
        }
        if command.type == "explain.run", reply.type == "explain.result",
           !request.started || reply.explain?.mode != command.explain?.mode {
            fail(BackendTransportError(.invalidMessage)); return
        }
        if command.type == "monitor.snapshot", reply.type == "monitor.result", !request.started {
            fail(BackendTransportError(.invalidMessage)); return
        }
        let terminal: BackendMessage
        do {
            if reply.type != "error", command.type.hasPrefix("dbtools.") {
                guard let request = command.databaseTools, let response = reply.databaseTools,
                      request.jobId == nil || request.jobId == response.jobId,
                      request.planId == nil || response.planId == nil || request.planId == response.planId else {
                    throw BackendTransportError(.invalidMessage)
                }
            }
            if reply.type != "error", command.type.hasPrefix("transfer.") {
                guard let request = command.transfer, let response = reply.transfer,
                      request.jobId == nil || request.jobId == response.jobId else {
                    throw BackendTransportError(.invalidMessage)
                }
            }
            if let metadata = reply.catalogMetadata {
                guard request.started, let selectors = command.catalogMetadata?.selectors else { throw BackendTransportError(.invalidMessage) }
                if command.type != "catalog.close" {
                    guard metadata.collections.count == selectors.count,
                          zip(metadata.collections, selectors).allSatisfy({ $0.selector.normalizedMetadataSelector == $1.normalizedMetadataSelector }) else {
                        throw BackendTransportError(.invalidMessage)
                    }
                }
            }
            if let imported = reply.tableImport {
                guard command.type.hasPrefix("import."), request.started,
                      reply.sessionId == command.sessionId, reply.queryId == command.queryId else { throw BackendTransportError(.invalidMessage) }
                if reply.type == "import.preview.result" {
                    guard imported.fingerprint == command.tableImport?.fingerprint,
                          imported.rowCount == command.tableImport?.rows?.count else { throw BackendTransportError(.invalidMessage) }
                }
                if reply.type == "import.apply.result", imported.rowCount != command.tableImport?.rows?.count { throw BackendTransportError(.invalidMessage) }
                if let row = imported.row, row > (command.tableImport?.rows?.count ?? 0) { throw BackendTransportError(.invalidMessage) }
            }
            if reply.type != "error", command.type.hasPrefix("structure.") {
                guard request.started, reply.structure?.valid(for: reply.type) == true else { throw BackendTransportError(.invalidMessage) }
                if let target = command.structure?.target {
                    guard let observed = reply.structure?.baseline?.target else { throw BackendTransportError(.invalidMessage) }
                    if target.reconcile == true {
                        guard target.create, StructureTarget.sameIdentifier(observed.schema, target.schema), StructureTarget.sameIdentifier(observed.table, target.table), observed.reconcile != true else { throw BackendTransportError(.invalidMessage) }
                    } else if observed != target { throw BackendTransportError(.invalidMessage) }
                }
                if let baselineID = command.structure?.baselineId, reply.structure?.plan?.baselineId != baselineID { throw BackendTransportError(.invalidMessage) }
                if let apply = command.structure?.apply, reply.structure?.outcome?.executionId != apply.executionId || reply.structure?.outcome?.planId != apply.planId { throw BackendTransportError(.invalidMessage) }
            }
            try validateDataComparison(reply, command: command)
            try validateSchemaComparison(reply, command: command)
            try validateComparison(reply, command: command)
            terminal = try hydrate(reply, request: request)
        }
        catch { fail(BackendTransportError(.invalidMessage)); return }
        pending.removeValue(forKey: reply.requestId)
        if terminal.type == "error" {
            request.continuation.resume(throwing: BackendRemoteError(reply: terminal))
        } else {
            request.continuation.resume(returning: terminal)
        }
    }

    private func validateDataComparison(_ reply: BackendMessage, command: BackendCommand) throws {
        guard command.type.hasPrefix("data."), reply.type != "error" else { return }
        guard let request = command.dataComparison, let response = reply.dataComparison,
              request.jobId == nil || request.jobId == response.jobId else { throw BackendTransportError(.invalidMessage) }
        if let plan = response.plan {
            guard plan.modelDigest == request.modelDigest else { throw BackendTransportError(.invalidMessage) }
        }
        if response.diff != nil {
            guard response.offset == (request.offset ?? 0), response.cellOffset == (request.cellOffset ?? 0) else { throw BackendTransportError(.invalidMessage) }
        }
        if let page = response.page {
            guard page.offset == (request.offset ?? 0), page.rows.count <= (request.limit ?? 100),
                  page.rows.allSatisfy({ $0.cellOffset == (request.cellOffset ?? 0) }),
                  try JSONEncoder().encode(page).count <= (request.maxBytes ?? 262_144) else { throw BackendTransportError(.invalidMessage) }
        }
        if let value = response.value {
            guard value.valueRef == request.valueRef, value.offset == (request.offset ?? 0),
                  (value.data?.count ?? Int.max) <= (request.maxBytes ?? 65_536) else { throw BackendTransportError(.invalidMessage) }
        }
    }

    private func validateSchemaComparison(_ reply: BackendMessage, command: BackendCommand) throws {
        guard command.type.hasPrefix("schema."), reply.type != "error" else { return }
        guard let requested = command.schemaComparison, let response = reply.schemaComparison,
              requested.jobId == nil || requested.jobId == response.jobId else { throw BackendTransportError(.invalidMessage) }
        if let plan = response.plan {
            guard plan.modelDigest == requested.modelDigest else { throw BackendTransportError(.invalidMessage) }
        }
        if response.diff != nil {
            guard response.offset == (requested.offset ?? 0) else { throw BackendTransportError(.invalidMessage) }
        }
        if let page = response.page {
            guard page.collection == requested.collection, page.offset == (requested.offset ?? 0),
                  page.count <= (requested.limit ?? 100), try JSONEncoder().encode(page).count <= (requested.maxBytes ?? 262_144) else { throw BackendTransportError(.invalidMessage) }
        }
        for chunk in [response.value, response.export].compactMap({ $0 }) {
            guard chunk.offset == (requested.offset ?? 0), (chunk.data?.count ?? Int.max) <= (requested.maxBytes ?? 65_536),
                  response.value == nil || chunk.valueRef == requested.valueRef else { throw BackendTransportError(.invalidMessage) }
        }
    }

    private func validateComparison(_ reply: BackendMessage, command: BackendCommand) throws {
        guard command.type.hasPrefix("compare."), reply.type != "error" else { return }
        guard let requested = command.comparison, let response = reply.comparison,
              requested.jobId == nil || response.jobId == requested.jobId else { throw BackendTransportError(.invalidMessage) }
        if let page = response.page {
            guard page.offset == (requested.offset ?? 0), page.rows.count <= (requested.limit ?? 100),
                  page.rows.allSatisfy({ $0.cellOffset == (requested.cellOffset ?? 0) }),
                  try JSONEncoder().encode(page).count <= (requested.maxBytes ?? 262_144) else { throw BackendTransportError(.invalidMessage) }
        }
        if let value = response.value {
            guard value.valueRef == requested.valueRef, value.offset == (requested.offset ?? 0),
                  (value.data?.count ?? Int.max) <= (requested.maxBytes ?? 65_536) else { throw BackendTransportError(.invalidMessage) }
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
            // Terminal notices can be added after the last streaming summary,
            // including an explanation that SQL source exceeded a size limit.
            // Retain them when presenting any selected result set.
            sets[index].displayNotice = Self.mergingNotice(sets[index].displayNotice, reply.displayNotice)
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
                result.sqliteValues = first.sqliteValues
                result.storageTokens = first.storageTokens
                result.source = first.source
            } else {
                result.columns = []; result.rows = []; result.displayedRowCount = 0
                result.sqliteValues = nil
                result.storageTokens = nil
                result.source = nil
            }
        }
        try result.validate()
        try validateAggregate(result)
        return result
    }

    private static func mergingNotice(_ local: String?, _ terminal: String?) -> String? {
        guard let terminal, !terminal.isEmpty else { return local }
        guard let local, !local.isEmpty else { return terminal }
        if local.contains(terminal) { return local }
        if terminal.contains(local) { return terminal }
        return local + "\n" + terminal
    }

    private func validateAggregate(_ reply: BackendMessage) throws {
        let sets: [QueryResultSet]
        if let results = reply.resultSets { sets = results }
        else if reply.type == "query.result" {
            sets = [QueryResultSet(columns: reply.columns ?? [], rows: reply.rows ?? [],
                commandTag: reply.commandTag ?? "", rowCount: reply.rowCount ?? 0,
                displayedRowCount: reply.displayedRowCount ?? 0, truncated: reply.truncated ?? false,
                displayNotice: reply.displayNotice, sqliteValues: reply.sqliteValues, storageTokens: reply.storageTokens, source: reply.source)]
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
            contextualError.outcomeUnknown = ["execute", "explain.run", "catalog", "changes.apply", "structure.apply", "import.apply", "transfer.apply", "dbtools.start"].contains(request.command.type)
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
