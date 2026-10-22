import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
    enum HelperState {
        case starting, ready, stopping, stopped, failed(String)

        var label: String {
            switch self {
            case .starting: "Starting helper"
            case .ready: "Helper ready"
            case .stopping: "Stopping helper"
            case .stopped: "Helper stopped"
            case .failed: "Helper unavailable"
            }
        }
    }

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, disconnecting

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .disconnecting: "Disconnecting…"
            }
        }
    }

    enum QueryPhase: Equatable {
        case idle, starting, running, cancelling

        var label: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Starting query…"
            case .running: "Running query…"
            case .cancelling: "Stopping query…"
            }
        }
    }

    struct QueryFailure: Equatable, Sendable {
        let category: String
        let message: String
        let sqlState: String?
        let outcomeUnknown: Bool
        var sqlNotExecuted: Bool = false

        var title: String {
            if sqlNotExecuted { return "Not executed" }
            return switch category {
            case "cancelled": "Query cancelled"
            case "timeout": "Query timed out"
            case "connection", "transport": "Connection lost"
            case "export": "Export failed"
            default: "Query failed"
            }
        }
    }

    struct QueryCompletion: Sendable {
        let startedAt: Date
        let finishedAt: Date
        let durationMs: Double
        let reply: BackendMessage?
        let failure: QueryFailure?
    }

    nonisolated static let sslModes = ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]

    @Published var host = "localhost"
    @Published var engine: DatabaseEngine = .postgresql
    @Published var port = "5432"
    @Published var database = "postgres"
    @Published var user = "postgres"
    // Runtime credentials stay in memory; saved passwords use the credential store.
    @Published var password = ""
    @Published var passwordCommand: PasswordCommand?
    @Published var sslMode = "verify-full"
    @Published var sslRootCert = ""
    @Published var policy = ExecutionPolicy()
    @Published var contactPoints: [String]?
    @Published var localDatacenter: String?
    @Published var consistency: String?
    @Published var ssh: SSHSettings?
    @Published private(set) var connectionProgress: String?
    @Published private var connectionPreparationId: UUID?
    private var connectionAttempt = UUID()
    var isConnecting: Bool { connectionState == .connecting || connectionPreparationId != nil }
    @Published private(set) var currentKeyspace: String?
    @Published private(set) var capabilities: Set<String> = []
    @Published var sql = "SELECT 1 AS id, 'hello'::text AS name;"

    @Published private(set) var state: HelperState = .starting
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var sessionId: String?
    @Published private(set) var transactionStatus: TransactionStatus?
    @Published private(set) var errorMessage: String?
    @Published private(set) var queryPhase: QueryPhase = .idle
    @Published private(set) var activeQueryId: String?
    @Published private(set) var queryStartedAt: Date?
    @Published private(set) var result: BackendMessage?
    @Published private(set) var queryFailure: QueryFailure?
    @Published private(set) var queryDurationMs: Double?
    @Published private(set) var queryErrorPosition: Int?
    @Published private(set) var cancellationMessage: String?
    @Published private(set) var savedConnections: [SavedConnection] = []
    @Published private(set) var selectedConnectionId: UUID?
    @Published private(set) var activeConnectionId: UUID?
    private(set) var connectionsErrorProfileID: UUID?
    @Published private(set) var connectionsError: String?
    @Published private(set) var isSavingConnection = false
    @Published var isConnectionEditorPresented = false

    private let helperFactory: () -> BackendClient
    private let connectionStore: any ConnectionLibraryStore
    private let credentialStore: any ConnectionCredentialStore
    private var hasLoadedConnections = false
    private var connectionMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var helper: BackendClient?
    private var ownsHelper = true
    private var helperGeneration = UUID()
    private var latestQueryId: String?
    private var transportFailureMessage: String?
    private var started = false
    private var stopping = false

    init(helperFactory: @escaping () -> BackendClient = { BackendClient() },
         connectionStore: any ConnectionLibraryStore = MemoryConnectionLibraryStore(),
         credentialStore: any ConnectionCredentialStore = MemoryConnectionCredentialStore()) {
        self.helperFactory = helperFactory
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
    }

    var canConnect: Bool {
        guard !stopping, connectionPreparationId == nil, activeQueryId == nil, connectionState == .disconnected else { return false }
        switch state {
        case .ready, .failed: return true
        default: return false
        }
    }

    var canDisconnect: Bool { !stopping && activeQueryId == nil && connectionState == .connected }
    var canEditConnection: Bool { !stopping && activeQueryId == nil && connectionState == .disconnected }
    var isExecuting: Bool { activeQueryId != nil }
    var canRun: Bool {
        guard !stopping, !isExecuting, sessionId != nil, connectionState == .connected,
              case .ready = state else { return false }
        return !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canStop: Bool { !stopping && activeQueryId != nil && (queryPhase == .starting || queryPhase == .running) }

    var transactionLabel: String {
        switch transactionStatus {
        case .idle: "Idle"
        case .unsupported: "Not supported"
        case .transaction: "In transaction"
        case .failedTransaction: "Failed transaction"
        case nil: "No session"
        }
    }

    func elapsedMilliseconds(at date: Date = .now) -> Double {
        guard let queryStartedAt else { return queryDurationMs ?? 0 }
        return max(0, date.timeIntervalSince(queryStartedAt) * 1_000)
    }

    var connectionSummary: String {
        guard sessionId != nil else { return connectionProgress ?? connectionState.label }
        if engine == .cassandra {
            return "\(host):\(port)/\(currentKeyspace ?? database) · \(consistency ?? "LOCAL_QUORUM")"
        }
        return "\(user)@\(host):\(port)/\(database)"
    }

    var supportsGridEditing: Bool { capabilities.contains("gridEditing") }
    var usesCursorPagination: Bool { capabilities.contains("cursorPagination") }
    var readOnlyScope: String { capabilities.contains("localReadOnly") ? "Local readonly" : "Readonly" }

    func start(startupConnection: Result<ConnectionSettings, StartupConnection.InputError>? = nil,
               sharedHelper: BackendClient? = nil) async {
        guard (!started || sharedHelper != nil), !stopping else { return }
        started = true
        await loadConnections()
        guard !stopping else { return }
        if let sharedHelper {
            ownsHelper = false
            helper = sharedHelper
            helperGeneration = UUID()
            state = .ready
            observeFailure(of: sharedHelper, generation: helperGeneration)
        }
        if case .success(let settings) = startupConnection {
            applyConnection(settings)
            selectedConnectionId = savedConnections.first { $0.matches(settings) }?.id
        }
        do { if sharedHelper == nil { _ = try await startHelper() } }
        catch { if !stopping { showTransportFailure(error) } }
        guard !stopping else { return }
        switch startupConnection {
        case .success:
            if case .ready = state { await connect() }
        case .failure(let error): errorMessage = error.localizedDescription
        case nil: break
        }
    }

    func connect() async {
        await openConnection(savedProfileId: nil)
    }

    private func openConnection(savedProfileId: UUID?) async {
        let attempt = connectionAttempt
        guard canConnect else { return }
        guard let portNumber = Int(port), (1...65535).contains(portNumber),
              !host.isEmpty, (engine == .cassandra || (!database.isEmpty && !user.isEmpty)) else {
            errorMessage = "Enter a host, database, user, and a port from 1 to 65535."
            return
        }
        guard engine.sslModes.contains(sslMode) else {
            errorMessage = "Choose a supported TLS mode."
            return
        }
        let settings = ConnectionSettings(host: host, port: portNumber, database: database,
            user: user, password: password, sslMode: sslMode,
            sslRootCert: sslRootCert.isEmpty ? nil : sslRootCert, engine: engine, policy: policy,
            contactPoints: contactPoints, localDatacenter: localDatacenter, consistency: consistency, ssh: ssh, passwordCommand: passwordCommand)
        guard settings.hasValidNativeFields else {
            errorMessage = "Enter valid connection settings for the selected database engine."
            return
        }
        let connectingProfileId = savedConnections.first { $0.id == selectedConnectionId && $0.matches(settings) }?.id
        clearQueryFeedback()
        connectionState = .connecting
        connectionProgress = settings.ssh == nil ? "Connecting to database…" : "Verifying SSH server…"
        defer { connectionProgress = nil }
        do {
            let client: BackendClient
            if case .ready = state, let helper { client = helper }
            else { client = try await startHelper() }
            guard !stopping else { return }
            try await SSHConnectionReview.prepare(settings, client: client)
            try Task.checkCancellation()
            guard !stopping, connectionAttempt == attempt else { throw CancellationError() }
            if let savedProfileId, let profile = savedConnections.first(where: { $0.id == savedProfileId }), !profile.matches(settings) {
                throw CancellationError()
            }
            connectionProgress = settings.ssh == nil ? "Connecting to database…" : "Opening SSH tunnel and database connection…"
            let reply = try await client.request(.connect(settings))
            if stopping || connectionAttempt != attempt || Task.isCancelled {
                if let openedSession = reply.sessionId {
                    _ = try? await client.request(.disconnect(sessionId: openedSession))
                }
                if !stopping { connectionState = .disconnected }
                return
            }
            guard !stopping, case .ready = state else { return }
            sessionId = reply.sessionId
            transactionStatus = reply.transactionStatus
            capabilities = Set(reply.capabilities ?? [])
            currentKeyspace = reply.currentKeyspace ?? (engine == .cassandra ? database : nil)
            connectionState = .connected
            let connectedSession = reply.sessionId
            // A saved profile already owns these credentials. Reconnecting must
            // not read and rewrite its Keychain item through saveConnection.
            let rememberedId: UUID?
            if let savedProfileId, savedProfileId == connectingProfileId {
                rememberedId = savedProfileId
            } else {
                rememberedId = await rememberConnectedSettings(settings, preferredId: connectingProfileId)
            }
            if !stopping, sessionId == connectedSession, connectionState == .connected {
                activeConnectionId = rememberedId
            }
        } catch is CancellationError {
            connectionState = .disconnected
            errorMessage = nil
        } catch let error as BackendRequestError {
            guard !stopping, case .ready = state else { return }
            errorMessage = error.localizedDescription
            connectionState = .disconnected
        } catch let error as BackendRemoteError {
            guard !stopping else { return }
            showRemoteFailure(error)
        } catch {
            guard !stopping else { return }
            showTransportFailure(error)
        }
    }

    func cancelConnection() {
        connectionAttempt = UUID()
        if let connectionPreparationId { SSHConnectionReview.cancel(profileId: connectionPreparationId.uuidString) }
        if let ssh { SSHConnectionReview.cancel(profileId: ssh.profileId) }
        connectionPreparationId = nil
    }

    func disconnect() async {
        guard canDisconnect, let sessionId, let helper else { return }
        connectionState = .disconnecting
        errorMessage = nil
        do {
            _ = try await helper.request(.disconnect(sessionId: sessionId))
            guard !stopping else { return }
            clearSession()
        } catch let error as BackendRequestError {
            guard !stopping, case .ready = state else { return }
            errorMessage = error.localizedDescription
            connectionState = .connected
        } catch let error as BackendRemoteError {
            guard !stopping else { return }
            showRemoteFailure(error)
        } catch {
            guard !stopping else { return }
            showTransportFailure(error)
        }
    }

    private func reportConnectionsError(_ message: String, profileID: UUID? = nil) {
        connectionsErrorProfileID = profileID
        connectionsError = message
    }

    func dismissConnectionsError() { connectionsErrorProfileID = nil; connectionsError = nil }

    /// nil is a read failure; an empty string is a successfully read empty/missing password.
    func passwordForConnection(_ id: UUID) async -> String? {
        guard let profile = savedConnections.first(where: { $0.id == id }) else { return nil }
        if profile.passwordCommand != nil { return "" }
        do { return try await credentialStore.password(for: id) ?? "" }
        catch {
            reportConnectionsError(ConnectionLibraryError.credentialRead.localizedDescription, profileID: id)
            return nil
        }
    }

    func selectConnection(_ id: UUID) async {
        guard !isSavingConnection, let profile = savedConnections.first(where: { $0.id == id }) else { return }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        selectedConnectionId = id
        if hasLoadedConnections {
            do { try await connectionStore.save(librarySnapshot()) }
            catch { reportConnectionsError(ConnectionLibraryError.save.localizedDescription, profileID: id) }
        }
        // Selection is independent of the live session, including connection transitions.
        if connectionState == .disconnected {
            applyConnection(profile.settings(password: ""))
        }
    }

    func connectSavedConnection(_ id: UUID, sshSnapshot: SSHSettings? = nil) async {
        guard canConnect else { return }
        await waitForConnectionMutation()
        guard canConnect,
              let profile = savedConnections.first(where: { $0.id == id }) else { return }
        await selectConnection(id)
        guard canConnect, selectedConnectionId == id else { return }
        let attempt = UUID()
        connectionAttempt = attempt
        connectionPreparationId = id
        defer { if connectionAttempt == attempt { connectionPreparationId = nil } }
        do {
            let secret = profile.passwordCommand == nil ? try await credentialStore.password(for: id) ?? "" : ""
            guard !stopping, connectionAttempt == attempt, connectionState == .disconnected, selectedConnectionId == id else { return }
            var settings = profile.settings(password: secret)
            if let sshSnapshot {
                guard sshSnapshot.profileId == id.uuidString, sshSnapshot.configuration == profile.ssh else {
                    reportConnectionsError("The SSH profile changed. Disconnect and reconnect before opening another session.", profileID: id)
                    return
                }
                settings.ssh = sshSnapshot
            } else if var ssh = settings.ssh {
                if ssh.authMethod == .password {
                    ssh.password = try await credentialStore.secret(for: id, purpose: .sshPassword)
                    if ssh.password == nil { ssh.password = try await SSHConnectionReview.requestSecret(passphrase: false, profileId: id.uuidString, configuration: ssh.configuration) }
                } else if ssh.authMethod == .privateKey {
                    ssh.passphrase = try await credentialStore.secret(for: id, purpose: .sshPassphrase)
                    if ssh.passphrase == nil { ssh.passphrase = try await SSHConnectionReview.requestSecret(passphrase: true, profileId: id.uuidString, configuration: ssh.configuration) }
                }
                settings.ssh = ssh
            }
            guard !stopping, connectionAttempt == attempt, connectionState == .disconnected, selectedConnectionId == id else { return }
            applyConnection(settings)
            connectionPreparationId = nil
            await openConnection(savedProfileId: id)
        } catch is CancellationError { return }
        catch { reportConnectionsError(ConnectionLibraryError.credentialRead.localizedDescription, profileID: id) }
    }

    @discardableResult
    func saveConnection(name: String, settings: ConnectionSettings, id: UUID? = nil, rememberSSHSecret: Bool = true) async -> Bool {
        guard !isSavingConnection else { return false }
        if !hasLoadedConnections { await loadConnections() }
        guard hasLoadedConnections else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 128 else {
            reportConnectionsError("Enter a connection name with 1 to 128 characters.", profileID: id)
            return false
        }
        guard settings.hasValidNativeFields else {
            reportConnectionsError("Enter a host, database, user, valid port, and supported TLS mode.", profileID: id)
            return false
        }
        if let id, !savedConnections.contains(where: { $0.id == id }) {
            reportConnectionsError("This saved connection is no longer available.", profileID: id)
            return false
        }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        dismissConnectionsError()
        let profile = SavedConnection(id: id ?? UUID(), name: cleanName, settings: settings)
        var previousSecrets: [ConnectionCredentialPurpose: String] = [:]
        do {
            for purpose in ConnectionCredentialPurpose.allCases {
                previousSecrets[purpose] = try await credentialStore.secret(for: profile.id, purpose: purpose)
            }
        } catch {
            reportConnectionsError(ConnectionLibraryError.credentialRead.localizedDescription, profileID: id)
            return false
        }
        do {
            if settings.passwordCommand == nil { try await credentialStore.savePassword(settings.password, for: profile.id) }
            else { try await credentialStore.deletePassword(for: profile.id) }
            for purpose in [ConnectionCredentialPurpose.sshPassword, .sshPassphrase] {
                let value = purpose == .sshPassword ? settings.ssh?.password : settings.ssh?.passphrase
                if rememberSSHSecret, let value { try await credentialStore.saveSecret(value, for: profile.id, purpose: purpose) }
                else { try await credentialStore.deleteSecret(for: profile.id, purpose: purpose) }
            }
        } catch {
            let restored = await restoreSecrets(previousSecrets, for: profile.id)
            reportConnectionsError(ConnectionLibraryError.credentialWrite.localizedDescription +
                (restored ? "" : " The credential change could not be undone in macOS Keychain."), profileID: id)
            return false
        }
        var updated = savedConnections
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        do {
            try await connectionStore.save(SavedConnectionLibrary(connections: updated,
                selectedConnectionId: profile.id))
            savedConnections = updated
            selectedConnectionId = profile.id
            return true
        } catch {
            reportConnectionsError(ConnectionLibraryError.save.localizedDescription, profileID: id)
            if !(await restoreSecrets(previousSecrets, for: profile.id)) {
                reportConnectionsError(ConnectionLibraryError.save.localizedDescription +
                    " The credential change could not be undone in macOS Keychain.", profileID: id)
            }
            return false
        }
    }

    @discardableResult
    func deleteConnection(_ id: UUID) async -> Bool {
        guard !isSavingConnection, hasLoadedConnections,
              savedConnections.contains(where: { $0.id == id }) else { return false }
        guard activeConnectionId != id else {
            reportConnectionsError("Disconnect this connection before deleting it.", profileID: id)
            return false
        }
        guard connectionState != .connecting, connectionState != .disconnecting else {
            reportConnectionsError("Wait for the connection operation to finish before deleting a connection.", profileID: id)
            return false
        }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        dismissConnectionsError()
        var secrets: [ConnectionCredentialPurpose: String] = [:]
        do {
            for purpose in ConnectionCredentialPurpose.allCases {
                secrets[purpose] = try await credentialStore.secret(for: id, purpose: purpose)
            }
        } catch {
            reportConnectionsError(ConnectionLibraryError.credentialRead.localizedDescription, profileID: id)
            return false
        }
        do {
            for purpose in ConnectionCredentialPurpose.allCases { try await credentialStore.deleteSecret(for: id, purpose: purpose) }
        } catch {
            _ = await restoreSecrets(secrets, for: id)
            reportConnectionsError(ConnectionLibraryError.credentialDelete.localizedDescription, profileID: id)
            return false
        }
        let updated = savedConnections.filter { $0.id != id }
        let selected = selectedConnectionId == id ? updated.first?.id : selectedConnectionId
        do {
            try await connectionStore.save(SavedConnectionLibrary(connections: updated, selectedConnectionId: selected))
            savedConnections = updated
            selectedConnectionId = selected
        } catch {
            reportConnectionsError(ConnectionLibraryError.save.localizedDescription, profileID: id)
            if !(await restoreSecrets(secrets, for: id)) {
                reportConnectionsError(ConnectionLibraryError.save.localizedDescription +
                    " The credentials could not be restored in macOS Keychain.", profileID: id)
            }
            return false
        }
        return true
    }

    /// Read profile metadata without starting a helper or restoring credentials.
    func loadConnections() async {
        guard !hasLoadedConnections, !isSavingConnection else { return }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        do {
            let library = try await connectionStore.load()
            savedConnections = library.connections
            selectedConnectionId = library.connections.contains { $0.id == library.selectedConnectionId }
                ? library.selectedConnectionId : library.connections.first?.id
            hasLoadedConnections = true
            if connectionState == .disconnected,
               let profile = savedConnections.first(where: { $0.id == selectedConnectionId }) {
                applyConnection(profile.settings(password: ""))
            }
        } catch { reportConnectionsError(ConnectionLibraryError.load.localizedDescription) }
    }

    private func librarySnapshot() -> SavedConnectionLibrary {
        SavedConnectionLibrary(connections: savedConnections, selectedConnectionId: selectedConnectionId)
    }

    private func restoreSecrets(_ secrets: [ConnectionCredentialPurpose: String], for id: UUID) async -> Bool {
        var success = true
        for purpose in ConnectionCredentialPurpose.allCases {
            do {
                if let value = secrets[purpose] { try await credentialStore.saveSecret(value, for: id, purpose: purpose) }
                else { try await credentialStore.deleteSecret(for: id, purpose: purpose) }
            } catch { success = false }
        }
        return success
    }

    func sshSecretForConnection(_ id: UUID, purpose: ConnectionCredentialPurpose) async -> String? {
        do { return try await credentialStore.secret(for: id, purpose: purpose) }
        catch { reportConnectionsError(ConnectionLibraryError.credentialRead.localizedDescription, profileID: id); return nil }
    }

    private func applyConnection(_ settings: ConnectionSettings) {
        ssh = settings.ssh
        engine = settings.engine
        host = settings.host
        port = String(settings.port)
        database = settings.database
        user = settings.user
        password = settings.password
        passwordCommand = settings.passwordCommand
        sslMode = settings.sslMode
        sslRootCert = settings.sslRootCert ?? ""
        policy = settings.policy
        contactPoints = settings.contactPoints
        localDatacenter = settings.localDatacenter
        consistency = settings.consistency
    }

    private func finishConnectionMutation() {
        isSavingConnection = false
        let waiters = connectionMutationWaiters
        connectionMutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForConnectionMutation() async {
        while isSavingConnection {
            await withCheckedContinuation { connectionMutationWaiters.append($0) }
        }
    }

    private func rememberConnectedSettings(_ settings: ConnectionSettings, preferredId: UUID?) async -> UUID? {
        await waitForConnectionMutation()
        guard !stopping else { return nil }
        // An edit made while connecting describes the next connection. Keep it intact.
        if let profile = savedConnections.first(where: { $0.id == preferredId }), !profile.matches(settings) {
            return profile.id
        }
        let existing = savedConnections.first { $0.id == preferredId }
            ?? savedConnections.first { $0.id == selectedConnectionId && $0.matches(settings) }
            ?? savedConnections.first { $0.matches(settings) }
        let saved = await saveConnection(name: existing?.name ?? (settings.database.isEmpty ? settings.host : settings.database),
            settings: settings, id: existing?.id)
        return saved ? selectedConnectionId : existing?.id
    }

    @discardableResult
    func run(sql commandSQL: String? = nil, catalog: CatalogRequest? = nil, export: ExportRequest? = nil,
             authorization: String? = nil) async -> QueryCompletion? {
        guard canRun, let sessionId, let helper else { return nil }
        let queryId = UUID().uuidString
        let generation = helperGeneration
        var command: BackendCommand
        if let catalog { command = .catalog(sessionId: sessionId, queryId: queryId, request: catalog) }
        else if let export { command = .runToFile(sessionId: sessionId, queryId: queryId, sql: commandSQL ?? sql, export: export) }
        else { command = .execute(sessionId: sessionId, queryId: queryId, sql: commandSQL ?? sql) }
        command.authorization = authorization
        clearQueryFeedback()
        latestQueryId = queryId
        activeQueryId = queryId
        let startedAt = Date.now
        let clock = ContinuousClock.now
        func completion(reply: BackendMessage? = nil, failure: QueryFailure? = nil) -> QueryCompletion {
            let elapsed = clock.duration(to: .now).components
            let elapsedMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            let duration = reply?.durationMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? elapsedMs
            return QueryCompletion(startedAt: startedAt, finishedAt: .now, durationMs: max(0, duration),
                reply: reply, failure: failure)
        }
        queryStartedAt = startedAt
        queryPhase = .starting
        do {
            let reply = try await helper.request(command) { [weak self] event in
                Task { @MainActor in
                    guard let self, !self.stopping, self.helperGeneration == generation,
                          self.activeQueryId == queryId, event.type == "query.started",
                          self.queryPhase == .starting else { return }
                    self.queryPhase = .running
                }
            }
            let terminal = completion(reply: reply)
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return terminal }
            result = reply
            if let keyspace = reply.currentKeyspace { currentKeyspace = keyspace }
            queryFailure = nil
            if case .ready = state { transactionStatus = reply.transactionStatus }
            else { preserveConfirmedOutcome() }
            queryDurationMs = reply.durationMs
            finishQuery()
            return terminal
        } catch let error as BackendRequestError {
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return nil }
            queryFailure = QueryFailure(category: "validation", message: error.localizedDescription,
                sqlState: nil, outcomeUnknown: false, sqlNotExecuted: true)
            queryDurationMs = nil
            errorMessage = error.localizedDescription
            preserveConfirmedOutcome()
            finishQuery()
            return nil
        } catch let error as BackendRemoteError {
            let failure = QueryFailure(category: error.reply.category ?? "sql",
                message: error.reply.message ?? "The query failed.", sqlState: error.reply.sqlState,
                outcomeUnknown: error.reply.outcomeUnknown == true, sqlNotExecuted: error.reply.sqlNotExecuted == true)
            let terminal = completion(reply: error.reply, failure: failure)
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return terminal }
            if let keyspace = error.reply.currentKeyspace { currentKeyspace = keyspace }
            queryErrorPosition = error.reply.errorPosition
            if error.reply.resultSets?.isEmpty == false { result = error.reply }
            queryDurationMs = error.reply.durationMs ?? elapsedMilliseconds()
            queryFailure = failure
            showRemoteFailure(error)
            if case .failed = state, error.reply.outcomeUnknown != true { preserveConfirmedOutcome() }
            finishQuery()
            return terminal
        } catch {
            let transport = error as? BackendTransportError
            let terminal = completion(failure: QueryFailure(category: "transport",
                message: transport.map { BackendTransportError($0.code).localizedDescription } ?? "The helper connection failed.",
                sqlState: nil, outcomeUnknown: transport?.outcomeUnknown ?? true,
                sqlNotExecuted: transport?.outcomeUnknown == false))
            guard !stopping, helperGeneration == generation, activeQueryId == queryId else { return terminal }
            showTransportFailure(error)
            return terminal
        }
    }

    func stop() async {
        guard canStop, let queryId = activeQueryId, let sessionId, let helper else { return }
        let generation = helperGeneration
        queryPhase = .cancelling
        do {
            _ = try await helper.request(.cancel(sessionId: sessionId, queryId: queryId))
            // The execute reply owns the final state. A successful query can
            // win the Stop race, and a cancel acknowledgement is not completion.
        } catch let error as BackendRequestError {
            guard !stopping, helperGeneration == generation, activeQueryId == queryId else { return }
            cancellationMessage = error.localizedDescription
            queryPhase = .running
        } catch let error as BackendRemoteError {
            guard !stopping, helperGeneration == generation, activeQueryId == queryId else { return }
            cancellationMessage = error.localizedDescription
        } catch {
            guard !stopping, helperGeneration == generation, activeQueryId == queryId else { return }
            showTransportFailure(error)
        }
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        if let ssh { SSHConnectionReview.cancel(profileId: ssh.profileId) }
        if let connectionPreparationId { SSHConnectionReview.cancel(profileId: connectionPreparationId.uuidString) }
        state = .stopping
        if let helper {
            if ownsHelper { _ = await helper.shutdown() }
            else if let sessionId {
                _ = try? await helper.request(.disconnect(sessionId: sessionId))
            }
        }
        finishQuery()
        clearSession()
        password = ""
        ssh?.password = nil
        ssh?.passphrase = nil
        state = .stopped
    }

    private func startHelper() async throws -> BackendClient {
        if !ownsHelper, let helper { return helper }
        // BackendClient has one launch. Recovery creates a new helper and waits
        // for the old process to exit before opening a new database session.
        let generation = UUID()
        helperGeneration = generation
        transportFailureMessage = nil
        latestQueryId = nil
        if let helper { _ = await helper.shutdown() }
        guard !stopping else { throw BackendTransportError(.notReady) }
        let client = helperFactory()
        helper = client
        state = .starting
        try await client.start()
        guard !stopping else { throw BackendTransportError(.notReady) }
        state = .ready
        observeFailure(of: client, generation: generation)
        return client
    }

    private func observeFailure(of client: BackendClient, generation: UUID) {
        Task { [weak self] in
            let failure = await client.waitForFailure()
            guard let self, !self.stopping, self.helperGeneration == generation else { return }
            self.showTransportFailure(failure)
        }
    }

    private func clearSession() {
        sessionId = nil
        activeConnectionId = nil
        transactionStatus = nil
        currentKeyspace = nil
        capabilities = []
        connectionState = .disconnected
    }

    private func clearQueryFeedback() {
        queryErrorPosition = nil
        latestQueryId = nil
        result = nil
        queryFailure = nil
        queryDurationMs = nil
        cancellationMessage = nil
        errorMessage = nil
    }

    private func finishQuery() {
        activeQueryId = nil
        queryStartedAt = nil
        queryPhase = .idle
        cancellationMessage = nil
    }

    private func preserveConfirmedOutcome() {
        // A terminal reply already read from the pipe is authoritative even
        // when the helper's failure observer reaches MainActor first.
        if let transportFailureMessage {
            errorMessage = transportFailureMessage
            state = .failed(transportFailureMessage)
        }
    }

    private func showRemoteFailure(_ error: BackendRemoteError) {
        guard case .ready = state else { return }
        errorMessage = error.localizedDescription
        if let sqlState = error.reply.sqlState { errorMessage! += " (SQLSTATE \(sqlState))" }
        if error.reply.outcomeUnknown == true {
            errorMessage! += " The SQL outcome is unknown; the command was not repeated."
        }
        if error.reply.connected == true, sessionId != nil {
            connectionState = .connected
            transactionStatus = error.reply.transactionStatus
        } else { clearSession() }
    }

    private func showTransportFailure(_ error: Error) {
        // The failure observer receives a general transport error while the
        // execute waiter receives a contextual one. Preserve uncertainty in
        // either delivery order, and do not let the second callback erase it.
        if let transport = error as? BackendTransportError {
            transportFailureMessage = BackendTransportError(transport.code).localizedDescription
        } else { transportFailureMessage = error.localizedDescription }
        let outcomeUnknown = isExecuting || (error as? BackendTransportError)?.outcomeUnknown == true ||
            queryFailure?.outcomeUnknown == true
        if isExecuting || (error as? BackendTransportError)?.outcomeUnknown == true {
            queryDurationMs = elapsedMilliseconds()
            let message: String
            if let transport = error as? BackendTransportError {
                message = BackendTransportError(transport.code).localizedDescription
            } else { message = error.localizedDescription }
            queryFailure = QueryFailure(category: "transport", message: message,
                sqlState: nil, outcomeUnknown: outcomeUnknown)
        }
        clearSession()
        finishQuery()
        var description = error.localizedDescription
        if outcomeUnknown, !description.contains("SQL outcome is unknown") {
            description += " The SQL outcome is unknown; the command was not repeated."
        }
        errorMessage = description
        state = .failed(description)
    }
}
