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

    struct QueryFailure: Equatable {
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

    nonisolated static let sslModes = ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]

    @Published var host = "localhost"
    @Published var engine: DatabaseEngine = .postgresql
    @Published var port = "5432"
    @Published var database = "postgres"
    @Published var user = "postgres"
    // Runtime credentials stay in memory; saved passwords use the credential store.
    @Published var password = ""
    @Published var sslMode = "verify-full"
    @Published var sslRootCert = ""
    @Published var policy = ExecutionPolicy()
    @Published var contactPoints: [String]?
    @Published var localDatacenter: String?
    @Published var consistency: String?
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
        guard !stopping, activeQueryId == nil, connectionState == .disconnected else { return false }
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
        guard sessionId != nil else { return connectionState.label }
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
            contactPoints: contactPoints, localDatacenter: localDatacenter, consistency: consistency)
        guard settings.hasValidNativeFields else {
            errorMessage = "Enter valid connection settings for the selected database engine."
            return
        }
        let connectingProfileId = savedConnections.first { $0.id == selectedConnectionId && $0.matches(settings) }?.id
        clearQueryFeedback()
        connectionState = .connecting
        do {
            let client: BackendClient
            if case .ready = state, let helper { client = helper }
            else { client = try await startHelper() }
            guard !stopping else { return }
            let reply = try await client.request(.connect(settings))
            if stopping, !ownsHelper {
                if let openedSession = reply.sessionId {
                    _ = try? await client.request(.disconnect(sessionId: openedSession))
                }
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

    func dismissConnectionsError() { connectionsError = nil }

    /// nil is a read failure; an empty string is a successfully read empty/missing password.
    func passwordForConnection(_ id: UUID) async -> String? {
        guard savedConnections.contains(where: { $0.id == id }) else { return nil }
        do { return try await credentialStore.password(for: id) ?? "" }
        catch {
            connectionsError = ConnectionLibraryError.credentialRead.localizedDescription
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
            catch { connectionsError = ConnectionLibraryError.save.localizedDescription }
        }
        // Selection is independent of the live session, including connection transitions.
        if connectionState == .disconnected {
            applyConnection(profile.settings(password: ""))
        }
    }

    func connectSavedConnection(_ id: UUID) async {
        guard canConnect else { return }
        await waitForConnectionMutation()
        guard canConnect,
              let profile = savedConnections.first(where: { $0.id == id }) else { return }
        await selectConnection(id)
        guard canConnect, selectedConnectionId == id else { return }
        do {
            let secret = try await credentialStore.password(for: id) ?? ""
            guard canConnect, selectedConnectionId == id else { return }
            applyConnection(profile.settings(password: secret))
            await openConnection(savedProfileId: id)
        } catch { connectionsError = ConnectionLibraryError.credentialRead.localizedDescription }
    }

    @discardableResult
    func saveConnection(name: String, settings: ConnectionSettings, id: UUID? = nil) async -> Bool {
        guard !isSavingConnection else { return false }
        if !hasLoadedConnections { await loadConnections() }
        guard hasLoadedConnections else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 128 else {
            connectionsError = "Enter a connection name with 1 to 128 characters."
            return false
        }
        guard settings.hasValidNativeFields else {
            connectionsError = "Enter a host, database, user, valid port, and supported TLS mode."
            return false
        }
        if let id, !savedConnections.contains(where: { $0.id == id }) {
            connectionsError = "This saved connection is no longer available."
            return false
        }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        connectionsError = nil
        let profile = SavedConnection(id: id ?? UUID(), name: cleanName, settings: settings)
        let previousPassword: String?
        do { previousPassword = try await credentialStore.password(for: profile.id) }
        catch {
            connectionsError = ConnectionLibraryError.credentialRead.localizedDescription
            return false
        }
        do { try await credentialStore.savePassword(settings.password, for: profile.id) }
        catch {
            connectionsError = ConnectionLibraryError.credentialWrite.localizedDescription
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
            connectionsError = ConnectionLibraryError.save.localizedDescription
            do {
                if let previousPassword { try await credentialStore.savePassword(previousPassword, for: profile.id) }
                else { try await credentialStore.deletePassword(for: profile.id) }
            } catch {
                connectionsError = ConnectionLibraryError.save.localizedDescription +
                    " The password change could not be undone in macOS Keychain."
            }
            return false
        }
    }

    @discardableResult
    func deleteConnection(_ id: UUID) async -> Bool {
        guard !isSavingConnection, hasLoadedConnections,
              savedConnections.contains(where: { $0.id == id }) else { return false }
        guard activeConnectionId != id else {
            connectionsError = "Disconnect this connection before deleting it."
            return false
        }
        guard connectionState != .connecting, connectionState != .disconnecting else {
            connectionsError = "Wait for the connection operation to finish before deleting a connection."
            return false
        }
        isSavingConnection = true
        defer { finishConnectionMutation() }
        connectionsError = nil
        let secret: String?
        do { secret = try await credentialStore.password(for: id) }
        catch {
            connectionsError = ConnectionLibraryError.credentialRead.localizedDescription
            return false
        }
        do { try await credentialStore.deletePassword(for: id) }
        catch {
            connectionsError = ConnectionLibraryError.credentialDelete.localizedDescription
            return false
        }
        let updated = savedConnections.filter { $0.id != id }
        let selected = selectedConnectionId == id ? updated.first?.id : selectedConnectionId
        do {
            try await connectionStore.save(SavedConnectionLibrary(connections: updated, selectedConnectionId: selected))
            savedConnections = updated
            selectedConnectionId = selected
        } catch {
            connectionsError = ConnectionLibraryError.save.localizedDescription
            if let secret {
                do { try await credentialStore.savePassword(secret, for: id) }
                catch {
                    connectionsError = ConnectionLibraryError.save.localizedDescription +
                        " The password could not be restored in macOS Keychain."
                }
            }
            return false
        }
        return true
    }

    private func loadConnections() async {
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
        } catch { connectionsError = ConnectionLibraryError.load.localizedDescription }
    }

    private func librarySnapshot() -> SavedConnectionLibrary {
        SavedConnectionLibrary(connections: savedConnections, selectedConnectionId: selectedConnectionId)
    }

    private func applyConnection(_ settings: ConnectionSettings) {
        engine = settings.engine
        host = settings.host
        port = String(settings.port)
        database = settings.database
        user = settings.user
        password = settings.password
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

    func run(sql commandSQL: String? = nil, catalog: CatalogRequest? = nil, export: ExportRequest? = nil,
             authorization: String? = nil) async {
        guard canRun, let sessionId, let helper else { return }
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
        queryStartedAt = .now
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
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return }
            result = reply
            if let keyspace = reply.currentKeyspace { currentKeyspace = keyspace }
            queryFailure = nil
            if case .ready = state { transactionStatus = reply.transactionStatus }
            else { preserveConfirmedOutcome() }
            queryDurationMs = reply.durationMs
            finishQuery()
        } catch let error as BackendRequestError {
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return }
            queryFailure = QueryFailure(category: "validation", message: error.localizedDescription,
                sqlState: nil, outcomeUnknown: false)
            queryDurationMs = nil
            errorMessage = error.localizedDescription
            preserveConfirmedOutcome()
            finishQuery()
        } catch let error as BackendRemoteError {
            guard !stopping, helperGeneration == generation, latestQueryId == queryId else { return }
            if let keyspace = error.reply.currentKeyspace { currentKeyspace = keyspace }
            queryErrorPosition = error.reply.errorPosition
            if error.reply.resultSets?.isEmpty == false { result = error.reply }
            queryDurationMs = error.reply.durationMs ?? elapsedMilliseconds()
            queryFailure = QueryFailure(category: error.reply.category ?? "sql",
                message: error.reply.message ?? error.localizedDescription,
                sqlState: error.reply.sqlState, outcomeUnknown: error.reply.outcomeUnknown == true, sqlNotExecuted: error.reply.sqlNotExecuted == true)
            showRemoteFailure(error)
            if case .failed = state, error.reply.outcomeUnknown != true { preserveConfirmedOutcome() }
            finishQuery()
        } catch {
            guard !stopping, helperGeneration == generation, activeQueryId == queryId else { return }
            showTransportFailure(error)
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
