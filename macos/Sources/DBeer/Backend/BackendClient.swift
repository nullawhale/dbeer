import Darwin
import Foundation

/// Local command rejection before a request is registered or written to stdin.
/// Keep this distinct from a malformed or oversized reply from the helper.
enum BackendRequestError: LocalizedError, Sendable, Equatable {
    case cancelledBeforeDispatch, invalidCommand, duplicateRequest, frameTooLarge, encodingFailed, unsupportedSSHConfiguration, unsupportedPasswordCommand, unsupportedQueryParameters, unsupportedTableImport, unsupportedSessionMonitor

    var errorDescription: String? {
        let explanation: String
        switch self {
        case .cancelledBeforeDispatch: explanation = "The capture was stopped before dispatch."
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
        write(data, captureAdmission: nil) { success, _ in completion(success) }
    }

    func write(_ data: Data, captureAdmission: ExplainCollectorAdmission?, completion: @escaping @Sendable (Bool, Bool) -> Void) {
        queue.async {
            do {
                // Admission is rechecked on the actual writer queue; this hop
                // is not a Swift task and cannot inherit Task cancellation.
                if let captureAdmission, !captureAdmission.beginDispatch() {
                    completion(false, true); return
                }
                try self.handle.write(contentsOf: data)
                completion(true, false)
            } catch {
                completion(false, false)
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
    private var schemaBundleSupported = false
    private var schemaBundleSourceSupported = false
    private var dataComparisonSupported = false
    private var synchronizationPlanSupported = false
    private var explainDMLSupported = false
    private var sessionExplainDMLSupport: [String: ExplainSupport] = [:]
    private struct ExplainDMLGrant {
        let session: String
        let request: Data
        let target: ExplainDMLTarget
    }
    private var explainDMLGrants: [String: ExplainDMLGrant] = [:]
    private var explainDMLExecutionTargets: [String: ExplainDMLTarget] = [:]
    private var tuningSupported = false
    private var sessionTuningSupport: [String: ExplainSupport] = [:]
    private var sessionTuningTransaction: [String: TransactionStatus] = [:]
    private var tuningGrants = TuningGrantLedger()
    private var tuningAssessmentGenerations: [String: UUID] = [:]
    private var currentAssessmentRequests: [String: String] = [:]
    private var explainMetricsSupported = false
    private var sessionExplainMetricsSupport: [String: ExplainSupport] = [:]
    private var explainOptionsSupported = false
    private var sessionExplainOptionSupport: [String: ExplainSupport] = [:]
    private var explainParametersSupported = false
    private var engineDiagnosticsSupported = false
    private var sessionDiagnosticSupport: [String: ExplainSupport] = [:]
    private var queryParametersSupported = false
    private var tableImportSupported = false
    private var sessionMonitorSupported = false
    private var schemaObservationSupported = false
    private var databaseToolsSupported = false
    private var dataTransferSupported = false
    private var nativeCommandsSupported = false
    private var nativeResultValuesSupported = false
    private var destructiveStructureSupported = false
    private var indexAuthoringSupported = false
    private var reconstructionSupported = false
    private var migrationsSupported = false
    private var physicalStructureSupported = false
    // One admission bit per logical owner, independent of preview count or plan IDs.
    private var reconstructionSessions: [String: Bool] = [:]
    private var sessionCapabilities: [String: Set<String>] = [:]
    // Physical loss retires active admission; retained status stays on its logical helper owner.
    private var retainedStructureCapabilities: [String: Set<String>] = [:]
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
    func supportsNativeCommands(sessionId: String) -> Bool {
        nativeCommandsSupported && nativeResultValuesSupported &&
            sessionCapabilities[sessionId]?.contains(NativeCommand.capability) == true &&
            sessionCapabilities[sessionId]?.contains(NativeValue.capability) == true
    }
    private func supportsPhysicalStructure(sessionId: String?, retainedStatus: Bool = false) -> Bool {
        physicalStructureSupported && sessionId.flatMap { retainedStatus ? retainedStructureCapabilities[$0] : sessionCapabilities[$0] }?.contains(structurePhysicalCapability) == true
    }
    private func supportsMigrations(sessionId: String?, retainedStatus: Bool = false) -> Bool {
        migrationsSupported && sessionId.flatMap { retainedStatus ? retainedStructureCapabilities[$0] : sessionCapabilities[$0] }?.contains(structureMigrationsCapability) == true
    }
    private func supportsIndexAuthoring(sessionId: String?, retainedStatus: Bool = false) -> Bool {
        indexAuthoringSupported && sessionId.flatMap { retainedStatus ? retainedStructureCapabilities[$0] : sessionCapabilities[$0] }?.contains("tableStructureIndexAuthoringV1") == true
    }
    private func supportsDestructiveStructure(sessionId: String?, retainedStatus: Bool = false) -> Bool {
        destructiveStructureSupported && sessionId.flatMap { retainedStatus ? retainedStructureCapabilities[$0] : sessionCapabilities[$0] }?.contains("tableStructureDestructiveV1") == true
    }
    private func supportsReconstruction(sessionId: String?, retainedStatus: Bool = false) -> Bool {
        reconstructionSupported && sessionId.flatMap { retainedStatus ? retainedStructureCapabilities[$0] : sessionCapabilities[$0] }?.contains("tableStructureReconstructionV1") == true
    }
    private func reconstructionOwnerIsKnown(_ sessionId: String?) -> Bool {
        sessionId.flatMap { reconstructionSessions[$0] } != nil
    }
    private func requiresReconstruction(_ command: BackendCommand) -> Bool {
        command.structure?.draft?.requiresReconstructionAuthoring == true ||
            command.sessionId.flatMap { reconstructionSessions[$0] } == true &&
                ["structure.apply", "structure.validate", "structure.status"].contains(command.type)
    }
    func supportsCapturedExport() -> Bool { capturedExportSupported }
    func supportsInsertFormatting() -> Bool { insertFormattingSupported }
    func supportsResultComparison() -> Bool { resultComparisonSupported }
    func supportsTuning() -> Bool { tuningSupported }
    func supportsExplainDML() -> Bool { explainDMLSupported }
    func supportsExplainMetrics() -> Bool { explainMetricsSupported }
    func supportsExplainOptions() -> Bool { explainOptionsSupported }
    func supportsExplainParameters() -> Bool { explainParametersSupported }
    func supportsEngineDiagnostics() -> Bool { engineDiagnosticsSupported }
    func supportsQueryParameters() -> Bool { queryParametersSupported }
    func supportsTableImport() -> Bool { tableImportSupported }
    func supportsSessionMonitor() -> Bool { sessionMonitorSupported }
    func supportsSchemaObservation() -> Bool { schemaObservationSupported }
    func supportsDatabaseTools() -> Bool { databaseToolsSupported }
    func supportsDataTransfer() -> Bool { dataTransferSupported }

    /// Check on the transport actor immediately before writing a cancel frame.
    /// A retired capture cannot cancel a later query or invalidate its grant.
    func cancelPendingCapture(sessionID: String, queryID: String) async {
        guard pending.values.contains(where: { $0.command.type == "explain.run" &&
            $0.command.sessionId == sessionID && $0.command.queryId == queryID }) else { return }
        _ = try? await request(.cancel(sessionId: sessionID, queryId: queryID))
    }

    /// A late assessment is retired only while it is still this owner's latest
    /// operation. A newer operation has already retired it at the helper.
    func discardAssessmentIfCurrent(_ reply: BackendMessage) async {
        guard reply.type == "operation.assessment", let session = reply.sessionId, let query = reply.queryId,
              currentAssessmentRequests[session] == reply.requestId else { return }
        currentAssessmentRequests.removeValue(forKey: session)
        _ = try? await request(.cancel(sessionId: session, queryId: query))
    }

    func request(_ command: BackendCommand, captureAdmission: ExplainCollectorAdmission? = nil,
                 onEvent: (@Sendable (BackendMessage) -> Void)? = nil) async throws -> BackendMessage {
        if captureAdmission != nil {
            guard command.type == "explain.run" else { throw BackendRequestError.invalidCommand }
            try checkCaptureAdmission(captureAdmission)
        }
        var command = command
        let hasTuningPayload = command.tuningInspect != nil || command.tuningValidation != nil || command.tuningSetting != nil || command.tuningSettingObservation != nil
        if hasTuningPayload || command.type.hasPrefix("tuning.") {
            guard let session = command.sessionId, let owner = sessionTuningSupport[session],
                  TuningTransportAdmission.validOwner(support: owner, engine: owner.engine,
                      capabilities: sessionCapabilities[session] ?? [], helperSupports: tuningSupported) else { throw BackendRequestError.invalidCommand }
            try TuningTransportAdmission.validateCommand(command, owner: owner, transaction: sessionTuningTransaction[session])
        }
        let tuningOperations = (command.operations ?? []).filter { $0.tuningValidation != nil || $0.tuningSetting != nil || $0.type.hasPrefix("tuning.") }
        if !tuningOperations.isEmpty {
            guard command.type == "operation.assess", command.operations?.count == 1,
                  let session = command.sessionId, let owner = sessionTuningSupport[session] else { throw BackendRequestError.invalidCommand }
            try TuningTransportAdmission.validateOperation(tuningOperations[0], session: session, owner: owner, transaction: sessionTuningTransaction[session])
        }
        if nativeResultValuesSupported,
           let session = command.sessionId, sessionCapabilities[session]?.contains(NativeValue.capability) == true,
           command.type == "execute" || command.type == "command.execute" || (command.type == "catalog" && command.catalog?.kind == "browse") {
            command.resultValues = NativeValue.format
        }
        if let format = command.resultValues {
            guard nativeResultValuesSupported, format == NativeValue.format,
                  command.type == "execute" || command.type == "command.execute" || (command.type == "catalog" && command.catalog?.kind == "browse"),
                  command.sessionId.flatMap({ sessionCapabilities[$0] })?.contains(NativeValue.capability) == true else {
                throw BackendRequestError.invalidCommand
            }
        }
        if command.type == "command.execute" {
            guard let session = command.sessionId, supportsNativeCommands(sessionId: session),
                  command.queryId.map(BackendMessage.validID) == true, command.nativeCommand?.valid == true,
                  command.resultValues == NativeValue.format, command.sql == nil, command.parameters == nil,
                  command.connection == nil, command.catalog == nil, command.catalogMetadata == nil,
                  command.stream == nil, command.export == nil, command.sequence == nil, command.changes == nil,
                  command.operations == nil, command.sshTrust == nil, command.insert == nil, command.comparison == nil,
                  command.schemaComparison == nil, command.dataComparison == nil, command.explain == nil,
                  command.structure == nil, command.tableImport == nil, command.databaseTools == nil,
                  command.transfer == nil, command.schemaObservation == nil, command.protocolVersion == nil,
                  command.authorization.map(BackendMessage.validID) == true else { throw BackendRequestError.invalidCommand }
        } else if command.nativeCommand != nil { throw BackendRequestError.invalidCommand }
        for operation in command.operations ?? [] {
            if operation.type == "command.execute" {
                guard command.type == "operation.assess", let session = command.sessionId,
                      supportsNativeCommands(sessionId: session), operation.nativeCommand?.valid == true,
                      operation.queryId.map(BackendMessage.validID) == true, operation.sql == nil,
                      operation.parameters == nil, operation.export == nil, operation.changes == nil,
                      operation.explain == nil, operation.structure == nil, operation.tableImport == nil else { throw BackendRequestError.invalidCommand }
            } else if operation.nativeCommand != nil || operation.queryId != nil { throw BackendRequestError.invalidCommand }
        }
        if command.type == "monitor.schema" {
            guard schemaObservationSupported, command.validSchemaObservationCommand else { throw BackendRequestError.invalidCommand }
        } else if command.schemaObservation != nil { throw BackendRequestError.invalidCommand }
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
            if operation.type == "structure.physical.apply" {
                guard command.type == "operation.assess", supportsPhysicalStructure(sessionId: command.sessionId),
                      operation.structure?.valid == true, operation.sql == nil, operation.export == nil,
                      operation.changes == nil, operation.explain == nil, operation.parameters == nil,
                      operation.tableImport == nil, operation.nativeCommand == nil, operation.queryId == nil else { throw BackendRequestError.invalidCommand }
            } else if operation.type == "structure.migration.apply" {
                guard command.type == "operation.assess", supportsMigrations(sessionId: command.sessionId),
                      operation.structure?.valid == true, operation.sql == nil, operation.export == nil,
                      operation.changes == nil, operation.explain == nil, operation.parameters == nil,
                      operation.tableImport == nil, operation.nativeCommand == nil, operation.queryId == nil else { throw BackendRequestError.invalidCommand }
            } else if operation.structure != nil {
                guard !reconstructionSupported || reconstructionOwnerIsKnown(command.sessionId),
                      command.sessionId.flatMap({ reconstructionSessions[$0] }) != true || supportsReconstruction(sessionId: command.sessionId) else {
                    throw BackendRequestError.invalidCommand
                }
            }
            if operation.type == "structure.validate" {
                guard command.type == "operation.assess", operation.structure?.valid == true,
                      operation.sql == nil, operation.export == nil, operation.changes == nil, operation.explain == nil,
                      operation.parameters == nil, operation.tableImport == nil, operation.nativeCommand == nil, operation.queryId == nil,
                      supportsDestructiveStructure(sessionId: command.sessionId) else { throw BackendRequestError.invalidCommand }
            }
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
        let explainRequests = [command.explain].compactMap { $0 } + (command.operations ?? []).compactMap(\.explain)
        for explain in explainRequests {
            guard let session = command.sessionId, explain.valid,
                  explain.context.map({ $0.sessionId == session }) ?? true else { throw BackendRequestError.invalidCommand }
            if explain.writeIntent != nil || sessionExplainDMLSupport[session] != nil && ExplainDMLAdmission.possibleDML(explain.sql, engine: sessionExplainDMLSupport[session]!.engine) {
                guard let owner = sessionExplainDMLSupport[session], ExplainDMLAdmission.validOwner(support: owner,
                    engine: owner.engine, capabilities: sessionCapabilities[session] ?? [], helperSupports: explainDMLSupported) else {
                    throw BackendRequestError.invalidCommand
                }
            }
            if let options = explain.options {
                guard ExplainOptionsAdmission.validOwner(support: sessionExplainOptionSupport[session],
                    engine: sessionExplainOptionSupport[session]?.engine,
                    capabilities: sessionCapabilities[session] ?? [], helperSupports: explainOptionsSupported),
                    let support = sessionExplainOptionSupport[session],
                    ExplainOptionsAdmission.accepts(options, support: support, mode: explain.mode) else {
                    throw BackendRequestError.invalidCommand
                }
            }
            if let support = sessionDiagnosticSupport[session] {
                guard ExplainDiagnosticAdmission.validOwner(support: support,
                    capabilities: sessionCapabilities[session] ?? [], helperSupports: engineDiagnosticsSupported,
                    transaction: .unsupported, parameters: explain.parameters, planKind: explain.planKind),
                    explain.context?.transactionStatus == "unsupported", support.modes.contains(explain.mode) else {
                    throw BackendRequestError.invalidCommand
                }
            } else if explain.parameters != nil || explain.planKind != nil || explain.context != nil {
                guard explainParametersSupported, sessionCapabilities[session]?.contains("explainParametersV1") == true,
                      explain.context?.transactionStatus != "unsupported" else { throw BackendRequestError.invalidCommand }
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
            if command.type.hasPrefix("structure.physical.") {
                guard supportsPhysicalStructure(sessionId: command.sessionId, retainedStatus: ["structure.physical.status", "structure.physical.close"].contains(command.type)) else { throw BackendRequestError.invalidCommand }
            }
            if command.type.hasPrefix("structure.migration.") {
                guard supportsMigrations(sessionId: command.sessionId, retainedStatus: ["structure.migration.status", "structure.migration.close"].contains(command.type)) else { throw BackendRequestError.invalidCommand }
            }
            guard !reconstructionSupported || reconstructionOwnerIsKnown(command.sessionId) else { throw BackendRequestError.invalidCommand }
            if requiresReconstruction(command), !supportsReconstruction(sessionId: command.sessionId, retainedStatus: command.type == "structure.status") {
                throw BackendRequestError.invalidCommand
            }
            if command.structure?.draft?.requiresIndexAuthoring == true || command.structure?.draft?.authoringVersion == 3,
               !supportsIndexAuthoring(sessionId: command.sessionId) {
                throw BackendRequestError.invalidCommand
            }
            if command.structure?.draft?.requiresDestructiveAuthoring == true || command.structure?.draft?.authoringVersion == 4 || command.type == "structure.validate",
               !supportsDestructiveStructure(sessionId: command.sessionId) { throw BackendRequestError.invalidCommand }
            guard command.structure?.valid(for: command.type) == true,
                  command.sessionId.map(BackendMessage.validID) == true, command.queryId.map(BackendMessage.validID) == true,
                  command.sql == nil, command.catalog == nil, command.connection == nil, command.stream == nil,
                  command.changes == nil, command.export == nil, command.operations == nil,
                  command.comparison == nil, command.schemaComparison == nil, command.dataComparison == nil,
                  command.protocolVersion == nil, command.sequence == nil, command.insert == nil, command.sshTrust == nil, command.explain == nil,
                  ["structure.apply", "structure.validate", "structure.migration.apply", "structure.physical.apply"].contains(command.type) || command.authorization == nil else { throw BackendRequestError.invalidCommand }
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
            let supported = command.type.hasPrefix("schema.import.") ? schemaBundleSourceSupported :
                command.type.hasPrefix("schema.bundle.") ? schemaBundleSupported : schemaComparisonSupported
            guard supported, command.schemaComparison?.valid(for: command.type) == true,
                  command.sessionId == nil, command.queryId == nil, command.connection == nil, command.sql == nil, command.catalog == nil,
                  command.protocolVersion == nil, command.stream == nil, command.export == nil, command.changes == nil,
                  command.operations == nil, command.authorization == nil, command.sequence == nil, command.sshTrust == nil,
                  command.insert == nil, command.comparison == nil else { throw BackendRequestError.invalidCommand }
            if command.schemaComparison?.source?.bundle != nil || command.schemaComparison?.target?.bundle != nil {
                guard schemaBundleSourceSupported else { throw BackendRequestError.invalidCommand }
            }
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
        if command.type == "cancel", let session = command.sessionId {
            explainDMLGrants = explainDMLGrants.filter { $0.value.session != session }
        }
        if command.type == "explain.run", let request = command.explain, request.writeIntent != nil {
            guard let authorization = command.authorization, let grant = explainDMLGrants.removeValue(forKey: authorization),
                  grant.session == command.sessionId, grant.request == request.exactBindingData else { throw BackendRequestError.invalidCommand }
            explainDMLExecutionTargets[command.requestId] = grant.target
        }
        if let session = command.sessionId {
            if command.type == "tuning.validate" || command.type == "tuning.setting" {
                let operation = OperationRequest(type: command.type, tuningValidation: command.tuningValidation, tuningSetting: command.tuningSetting)
                guard tuningGrants.consume(command.authorization, session: session, operation: operation) else { throw BackendRequestError.invalidCommand }
            }
            if command.type == "operation.assess" { currentAssessmentRequests[session] = command.requestId }
            else if captureAdmission == nil { currentAssessmentRequests.removeValue(forKey: session) }
            let generation = tuningGrants.begin(session)
            if !tuningOperations.isEmpty { tuningAssessmentGenerations[command.requestId] = generation }
        }
        defer {
            explainDMLExecutionTargets.removeValue(forKey: command.requestId)
            tuningAssessmentGenerations.removeValue(forKey: command.requestId)
        }
        return try await send(command, captureAdmission: captureAdmission, onEvent: onEvent)
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

    private func send(_ command: BackendCommand, lifecycle: Bool = false, captureAdmission: ExplainCollectorAdmission? = nil,
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
        let frame = data
        if captureAdmission != nil { try checkCaptureAdmission(captureAdmission) }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let enqueue = {
                    self.usedRequestIDs.insert(command.requestId)
                    self.pending[command.requestId] = Pending(command: command, continuation: continuation, onEvent: onEvent)
                    writer.write(frame, captureAdmission: captureAdmission) { [weak self] success, cancelled in
                        if cancelled { Task { await self?.captureWasNotDispatched(command.requestId) } }
                        else if !success { Task { await self?.fail(BackendTransportError(.writeFailed)) } }
                    }
                }
                if let captureAdmission {
                    try captureAdmission.whileWaiting { try Task.checkCancellation(); enqueue() }
                } else { enqueue() }
            } catch { continuation.resume(throwing: BackendRequestError.cancelledBeforeDispatch) }
        }
    }

    private func checkCaptureAdmission(_ admission: ExplainCollectorAdmission?) throws {
        do { try Task.checkCancellation(); try admission?.whileWaiting {} }
        catch { throw BackendRequestError.cancelledBeforeDispatch }
    }

    private func captureWasNotDispatched(_ requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.continuation.resume(throwing: BackendRequestError.cancelledBeforeDispatch)
    }

    private func receive(_ reply: BackendMessage) {
        guard failure == nil else { return }
        guard var request = pending[reply.requestId] else {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        let command = request.command
        let physicalAdmitted = supportsPhysicalStructure(sessionId: command.sessionId, retainedStatus: ["structure.physical.status", "structure.physical.close"].contains(command.type))
        let migrationAdmitted = supportsMigrations(sessionId: command.sessionId, retainedStatus: ["structure.migration.status", "structure.migration.close"].contains(command.type))
        let destructiveStructureAdmitted = supportsDestructiveStructure(sessionId: command.sessionId, retainedStatus: command.type == "structure.status")
        let indexAuthoringAdmitted = supportsIndexAuthoring(sessionId: command.sessionId, retainedStatus: command.type == "structure.status")
        let reconstructionRequired = requiresReconstruction(command)
        let reconstructionAdmitted = supportsReconstruction(sessionId: command.sessionId, retainedStatus: command.type == "structure.status")
        guard (command.sessionId == nil || command.sessionId == reply.sessionId),
              (command.queryId == nil || command.queryId == reply.queryId) else {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        if command.type == "connect", reply.type == "connect.result", reply.engine != command.connection?.engine {
            fail(BackendTransportError(.invalidMessage))
            return
        }
        if reply.type == "query.started", (["execute", "command.execute", "explain.run", "monitor.snapshot", "monitor.schema", "catalog", "catalog.page", "catalog.batch", "catalog.close", "changes.preview", "changes.apply"].contains(command.type) || command.type.hasPrefix("structure.") || command.type.hasPrefix("import.") || command.type.hasPrefix("tuning.")), !request.started {
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
        if command.type.hasPrefix("tuning."), reply.type != "error" {
            guard request.started, let session = command.sessionId, let owner = sessionTuningSupport[session] else { fail(BackendTransportError(.invalidMessage)); return }
            do { try TuningTransportAdmission.validateReply(reply, command: command, owner: owner) }
            catch { fail(BackendTransportError(.invalidMessage)); return }
        }
        if command.type == "operation.assess", reply.type != "error", let operation = command.operations?.first,
           operation.tuningValidation != nil || operation.tuningSetting != nil {
            guard let assessment = reply.assessment, assessment.operations.count == 1, assessment.operations[0].explain == nil,
                  ["confirm", "deny"].contains(assessment.decision), let session = command.sessionId else { fail(BackendTransportError(.invalidMessage)); return }
            if let setting = operation.tuningSetting {
                guard assessment.decision == "deny" || assessment.operations[0].tuningSetting?.sql == TuningTransportAdmission.settingSQL(setting.valueKiB) &&
                    assessment.operations[0].tuningSetting?.restoreSQL == TuningTransportAdmission.settingSQL(setting.expectedValueKiB) else { fail(BackendTransportError(.invalidMessage)); return }
            } else if assessment.operations[0].tuningSetting != nil { fail(BackendTransportError(.invalidMessage)); return }
            if let authorization = assessment.authorization { tuningGrants.record(authorization, session: session, operation: operation, assessedGeneration: tuningAssessmentGenerations[command.requestId]) }
        }
        // Validate against the live physical owner before a terminal frame can
        // retire its capabilities or disconnect the tab.
        if reply.explain?.support.dml != nil {
            guard let session = command.sessionId, let owner = sessionExplainDMLSupport[session], reply.explain?.support == owner,
                  ExplainDMLAdmission.validOwner(support: owner, engine: owner.engine,
                    capabilities: sessionCapabilities[session] ?? [], helperSupports: explainDMLSupported) else {
                fail(BackendTransportError(.invalidMessage)); return
            }
        }
        // A correlated refusal before execution has no collected DML facts.
        // Keep it a normal remote error without failing other physical owners.
        let refusedDML = command.type == "explain.run" && command.explain?.writeIntent != nil &&
            explainDMLExecutionTargets[command.requestId] != nil && reply.type == "error" &&
            reply.sqlNotExecuted == true && reply.sqlCompleted != true && reply.outcomeUnknown != true &&
            reply.explainDML == nil && reply.explain == nil
        if !refusedDML && (reply.explainDML != nil || reply.explain?.dml != nil || command.explain?.writeIntent != nil) {
            guard command.type == "explain.run", let requested = command.explain, let session = command.sessionId,
                  let owner = sessionExplainDMLSupport[session],
                  ExplainDMLAdmission.validOwner(support: owner, engine: owner.engine,
                    capabilities: sessionCapabilities[session] ?? [], helperSupports: explainDMLSupported),
                  let outcome = reply.explain?.dml ?? reply.explainDML,
                  reply.explain == nil || reply.explain?.support == owner,
                  requested.writeIntent == nil || explainDMLExecutionTargets[command.requestId] == outcome.target,
                  ExplainDMLAdmission.accepts(outcome, request: requested, support: owner,
                    transactionStatus: reply.transactionStatus, connected: reply.connected, sqlCompleted: reply.sqlCompleted,
                    outcomeUnknown: reply.outcomeUnknown, sqlNotExecuted: reply.sqlNotExecuted),
                  outcome.execution == "notExecuted" || request.started else { fail(BackendTransportError(.invalidMessage)); return }
        }
        if command.type == "explain.run", reply.type == "explain.result" {
            guard request.started, let result = reply.explain, result.mode == command.explain?.mode else {
                fail(BackendTransportError(.invalidMessage)); return
            }
            if command.explain?.options != nil || result.options != nil || result.format != nil || result.support.notices != nil {
                guard let session = command.sessionId, let owner = sessionExplainOptionSupport[session], result.support == owner,
                      ExplainOptionsAdmission.validOwner(support: owner, engine: result.support.engine,
                        capabilities: sessionCapabilities[session] ?? [], helperSupports: explainOptionsSupported),
                      result.options == command.explain?.options else {
                    fail(BackendTransportError(.invalidMessage)); return
                }
            }
            if result.advancedMetrics != nil || result.nodes.contains(where: { $0.advancedMetrics != nil }) {
                guard let session = command.sessionId, let owner = sessionExplainMetricsSupport[session], result.support == owner,
                      ExplainMetricsAdmission.validOwner(support: owner, engine: result.support.engine,
                        capabilities: sessionCapabilities[session] ?? [], helperSupports: explainMetricsSupported) else {
                    fail(BackendTransportError(.invalidMessage)); return
                }
            }
            let owner = command.sessionId.flatMap { sessionDiagnosticSupport[$0] }
            if owner != nil || result.engineDiagnostic != nil {
                guard engineDiagnosticsSupported, let session = command.sessionId,
                      sessionCapabilities[session]?.contains("engineDiagnosticsV1") == true,
                      let owner, owner.engine == result.support.engine,
                      owner.diagnosticModel == result.engineDiagnostic?.kind,
                      reply.transactionStatus == .unsupported else { fail(BackendTransportError(.invalidMessage)); return }
            }
        }
        if command.type == "operation.assess", let operations = command.operations, let assessment = reply.assessment {
            guard zip(operations, assessment.operations).allSatisfy({ $0.0.tuningSetting != nil || $0.1.tuningSetting == nil }) else { fail(BackendTransportError(.invalidMessage)); return }
            for (operation, assessed) in zip(operations, assessment.operations) {
                guard let requested = operation.explain, let preview = assessed.explain else { continue }
                if requested.writeIntent != nil || preview.dml != nil || preview.support.dml != nil {
                    guard let session = command.sessionId, let owner = sessionExplainDMLSupport[session], preview.support == owner,
                          ExplainDMLAdmission.validOwner(support: owner, engine: owner.engine,
                            capabilities: sessionCapabilities[session] ?? [], helperSupports: explainDMLSupported),
                          requested.writeIntent == nil || preview.dml != nil else { fail(BackendTransportError(.invalidMessage)); return }
                }
                if requested.options != nil || preview.options != nil || preview.format != nil || preview.support.notices != nil {
                    guard let session = command.sessionId, let owner = sessionExplainOptionSupport[session], preview.support == owner,
                          ExplainOptionsAdmission.validOwner(support: owner, engine: preview.support.engine,
                            capabilities: sessionCapabilities[session] ?? [], helperSupports: explainOptionsSupported),
                          preview.options == requested.options else {
                        fail(BackendTransportError(.invalidMessage)); return
                    }
                }
            }
        }
        if command.type == "operation.assess", let session = command.sessionId, let operations = command.operations,
           let assessment = reply.assessment {
            explainDMLGrants = explainDMLGrants.filter { $0.value.session != session }
            if let authorization = assessment.authorization, operations.count == 1,
               let requested = operations[0].explain, let target = assessment.operations.first?.explain?.dml,
               let binding = requested.exactBindingData {
                explainDMLGrants[authorization] = ExplainDMLGrant(session: session, request: binding, target: target)
            }
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
            schemaBundleSupported = reply.capabilities?.contains("schemaBundleV1") == true
            schemaBundleSourceSupported = reply.capabilities?.contains("schemaBundleSourceV1") == true
            dataComparisonSupported = reply.capabilities?.contains("dataComparisonV1") == true
            synchronizationPlanSupported = reply.capabilities?.contains("synchronizationPlanV1") == true
            tuningSupported = reply.capabilities?.contains(TuningInspectRequest.capability) == true
            explainDMLSupported = reply.capabilities?.contains(ExplainDMLSupport.capability) == true
            explainMetricsSupported = reply.capabilities?.contains(ExplainNodeMetrics.capability) == true
            explainOptionsSupported = reply.capabilities?.contains("explainOptionsV1") == true
            explainParametersSupported = reply.capabilities?.contains("explainParametersV1") == true
            engineDiagnosticsSupported = reply.capabilities?.contains("engineDiagnosticsV1") == true
            queryParametersSupported = reply.capabilities?.contains("queryParametersV1") == true
            tableImportSupported = reply.capabilities?.contains("tableImportV1") == true
            sessionMonitorSupported = reply.capabilities?.contains("sessionMonitorV1") == true
            schemaObservationSupported = reply.capabilities?.contains("schemaObservationV1") == true
            databaseToolsSupported = reply.capabilities?.contains("databaseToolsV1") == true
            dataTransferSupported = reply.capabilities?.contains("dataTransferV1") == true
            nativeCommandsSupported = reply.capabilities?.contains(NativeCommand.capability) == true
            nativeResultValuesSupported = reply.capabilities?.contains(NativeValue.capability) == true
            destructiveStructureSupported = reply.capabilities?.contains("tableStructureDestructiveV1") == true
            indexAuthoringSupported = reply.capabilities?.contains("tableStructureIndexAuthoringV1") == true
            reconstructionSupported = reply.capabilities?.contains("tableStructureReconstructionV1") == true
            migrationsSupported = reply.capabilities?.contains(structureMigrationsCapability) == true
            physicalStructureSupported = reply.capabilities?.contains(structurePhysicalCapability) == true
        }
        if reply.type == "connect.result", let session = reply.sessionId {
            sessionCapabilities[session] = Set(reply.capabilities ?? [])
            if command.connection?.sessionPurpose == nil,
               TuningTransportAdmission.validOwner(support: reply.explainSupport, engine: reply.engine,
                   capabilities: Set(reply.capabilities ?? []), helperSupports: tuningSupported) {
                sessionTuningSupport[session] = reply.explainSupport
            } else { sessionTuningSupport.removeValue(forKey: session) }
            reconstructionSessions[session] = false
            if let support = reply.explainSupport,
               ExplainDMLAdmission.validOwner(support: support, engine: reply.engine,
                 capabilities: Set(reply.capabilities ?? []), helperSupports: explainDMLSupported) {
                sessionExplainDMLSupport[session] = support
            } else { sessionExplainDMLSupport.removeValue(forKey: session) }
            if let support = reply.explainSupport,
               ExplainMetricsAdmission.validOwner(support: support, engine: reply.engine,
                 capabilities: Set(reply.capabilities ?? []), helperSupports: explainMetricsSupported) {
                sessionExplainMetricsSupport[session] = support
            } else { sessionExplainMetricsSupport.removeValue(forKey: session) }
            if let support = reply.explainSupport,
               ExplainOptionsAdmission.validOwner(support: support, engine: reply.engine,
                 capabilities: Set(reply.capabilities ?? []), helperSupports: explainOptionsSupported) {
                sessionExplainOptionSupport[session] = support
            } else { sessionExplainOptionSupport.removeValue(forKey: session) }
            let structureCapabilities = Set(reply.capabilities ?? []).intersection(["tableStructureIndexAuthoringV1", "tableStructureDestructiveV1", "tableStructureReconstructionV1", structureMigrationsCapability, structurePhysicalCapability])
            if !structureCapabilities.isEmpty { retainedStructureCapabilities[session] = structureCapabilities }
            else { retainedStructureCapabilities.removeValue(forKey: session) }
            if reply.transactionStatus == .unsupported, let support = reply.explainSupport, support.engine.hasEngineDiagnostics {
                sessionDiagnosticSupport[session] = support
            } else { sessionDiagnosticSupport.removeValue(forKey: session) }
        }
        if reply.type == "disconnect.ack", let session = reply.sessionId {
            retainedStructureCapabilities.removeValue(forKey: session)
            reconstructionSessions.removeValue(forKey: session)
        }
        if let session = reply.sessionId, let transaction = reply.transactionStatus { sessionTuningTransaction[session] = transaction }
        if reply.type == "disconnect.ack" || reply.connected == false, let session = reply.sessionId {
            sessionTuningSupport.removeValue(forKey: session)
            sessionTuningTransaction.removeValue(forKey: session)
            currentAssessmentRequests.removeValue(forKey: session)
            tuningGrants.retire(session)
            sessionCapabilities.removeValue(forKey: session)
            sessionExplainDMLSupport.removeValue(forKey: session)
            explainDMLGrants = explainDMLGrants.filter { $0.value.session != session }
            sessionExplainOptionSupport.removeValue(forKey: session)
            sessionExplainMetricsSupport.removeValue(forKey: session)
            sessionDiagnosticSupport.removeValue(forKey: session)
        }
        if let session = reply.sessionId, let transaction = reply.transactionStatus, transaction != .unsupported {
            sessionDiagnosticSupport.removeValue(forKey: session)
        }
        if reply.type == "hello.ack", reply.protocolVersion != BackendProtocol.version {
            fail(BackendTransportError(.incompatibleVersion(reply.protocolVersion ?? -1)))
            return
        }
        if command.type == "monitor.schema", reply.type == "monitor.schema.result", !request.started {
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
            if reply.type != "error", command.type.hasPrefix("structure.physical.") {
                guard (request.started || command.type == "structure.physical.status"), physicalAdmitted, reply.type == command.terminalType,
                      reply.structure?.valid(for: reply.type) == true else { throw BackendTransportError(.invalidMessage) }
                try PhysicalTransportAdmission.validate(reply.structure?.physical, command: command)
            } else if reply.type != "error", command.type.hasPrefix("structure.migration.") {
                guard request.started, migrationAdmitted,
                      reply.structure?.valid(for: reply.type) == true, reply.type == command.terminalType else { throw BackendTransportError(.invalidMessage) }
                try MigrationTransportAdmission.validate(reply.structure?.migration, command: command)
            } else if reply.type != "error", command.type.hasPrefix("structure.") {
                guard request.started, reply.structure?.valid(for: reply.type) == true,
                      !reconstructionRequired || reconstructionAdmitted else { throw BackendTransportError(.invalidMessage) }
                if reply.structure?.baseline?.requiresIndexAuthoring == true || reply.structure?.outcome?.observed?.requiresIndexAuthoring == true {
                    guard indexAuthoringAdmitted else { throw BackendTransportError(.invalidMessage) }
                }
                if reply.structure?.baseline?.requiresDestructiveAuthoring == true || reply.structure?.plan?.requiresDestructiveAuthoring == true || reply.structure?.outcome?.requiresDestructiveAuthoring == true || reply.structure?.validation != nil {
                    guard destructiveStructureAdmitted else { throw BackendTransportError(.invalidMessage) }
                }
                if let validation = command.structure?.validation {
                    guard let report = reply.structure?.validation, report.planId.utf8.elementsEqual(validation.planId.utf8), report.digest == validation.digest, report.executionId.utf8.elementsEqual(validation.executionId.utf8) else { throw BackendTransportError(.invalidMessage) }
                }
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
        if reply.type == "structure.preview.result", command.structure?.draft?.requiresReconstructionAuthoring == true,
           let session = command.sessionId {
            reconstructionSessions[session] = true
        }
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
                  response.value == nil && command.type != "schema.bundle.export" || chunk.valueRef == requested.valueRef else { throw BackendTransportError(.invalidMessage) }
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
        let wantsNative = request.command.resultValues == NativeValue.format
        guard wantsNative == (reply.nativeValues != nil),
              NativeValue.validMatrix(reply.nativeValues, rows: rows.count, columns: request.streamSets[index].columns.count) else {
            throw BackendTransportError(.invalidMessage)
        }
        if let native = reply.nativeValues {
            request.streamBytes += try encoder.encode(native).count
            if request.streamSets[index].nativeValues == nil { request.streamSets[index].nativeValues = [] }
            request.streamSets[index].nativeValues?.append(contentsOf: native)
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
            if reply.type == "query.result" {
                let wantsNative = request.command.resultValues == NativeValue.format
                guard wantsNative == (reply.nativeValues != nil),
                      reply.resultSets?.allSatisfy({ ($0.nativeValues != nil) == wantsNative }) ?? true else { throw BackendTransportError(.invalidMessage) }
            }
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
            guard sets[index].nativeValues == nil else { throw BackendTransportError(.invalidMessage) }
            sets[index].nativeValues = request.streamSets[index].nativeValues
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
                result.nativeValues = first.nativeValues
                result.storageTokens = first.storageTokens
                result.source = first.source
            } else {
                result.columns = []; result.rows = []; result.displayedRowCount = 0
                result.sqliteValues = nil
                result.nativeValues = nil
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
                displayNotice: reply.displayNotice, sqliteValues: reply.sqliteValues, nativeValues: reply.nativeValues, storageTokens: reply.storageTokens, source: reply.source)]
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
        retainedStructureCapabilities.removeAll()
        reconstructionSessions.removeAll()
        sessionExplainDMLSupport.removeAll()
        explainDMLGrants.removeAll()
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
            contextualError.outcomeUnknown = ["execute", "command.execute", "explain.run", "catalog", "changes.apply", "structure.apply", "structure.migration.apply", "structure.physical.apply", "import.apply", "transfer.apply", "dbtools.start"].contains(request.command.type)
            request.continuation.resume(throwing: contextualError)
        }
    }

    private func fail(_ error: BackendTransportError) {
        guard failure == nil else { return }
        failure = error
        ready = false
        retainedStructureCapabilities.removeAll()
        reconstructionSessions.removeAll()
        sessionExplainDMLSupport.removeAll()
        explainDMLGrants.removeAll()
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
