import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// A document owns its text and its working session. Profile service sessions
/// belong to the workspace and never execute document SQL.
@MainActor
final class SQLDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var text: String {
        didSet { if text != oldValue { clearExecutionSuccess() } }
    }
    @Published var profileID: UUID? {
        didSet { if profileID != oldValue { clearExecutionSuccess() } }
    }
    @Published private(set) var successfulExecutionRanges: [NSRange] = []
    private(set) var executionRevision: UInt64 = 0
    @Published var runtime: WorkspaceModel?
    @Published var isRunning = false
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var executions: [SQLExecution] = []
    @Published var selectedExecution = 0
    @Published var localError: String?
    @Published var errorPosition: Int?
    @Published var fileURL: URL?
    var stopRequested = false
    var table: TableReference?
    @Published var page = 0
    @Published var tableSort: [CatalogSort] = []
    @Published var tableFilters: [CatalogFilter] = []
    @Published var tableColumns: [[String: String]] = []
    @Published private(set) var grid: GridDraft?
    private var runtimeObservation: AnyCancellable?
    private var gridObservation: AnyCancellable?

    init(id: UUID = UUID(), title: String = "SQL", text: String = "SELECT 1;", profileID: UUID? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.profileID = profileID
    }

    func attach(_ model: WorkspaceModel) {
        runtime = model
        runtimeObservation = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func clearExecutionSuccess() {
        executionRevision &+= 1
        if !successfulExecutionRanges.isEmpty { successfulExecutionRanges = [] }
    }

    func recordExecutionSuccess(_ statement: SQLStatement, revision: UInt64) {
        let source = text as NSString
        let range = statement.range
        guard revision == executionRevision, range.location >= 0, range.location <= source.length,
              range.length > 0, range.length <= source.length - range.location,
              source.substring(with: range) == statement.sql else { return }
        successfulExecutionRanges.append(range)
    }

    func attachGrid(_ draft: GridDraft?) {
        grid = draft
        gridObservation = draft?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

struct SQLExecution: Identifiable {
    let id = UUID()
    let sql: String
    let range: NSRange
    var status = "Pending"
    var result: BackendMessage?
    var failure: WorkspaceModel.QueryFailure?
}

@MainActor
final class ApplicationWorkspace: ObservableObject {
    let library: WorkspaceModel
    @Published private(set) var documents: [SQLDocument] = []
    @Published var selectedDocumentID: UUID? { didSet { scheduleSave() } }
    @Published private(set) var services: [UUID: WorkspaceModel] = [:]
    @Published private(set) var error: String?
    @Published private(set) var isStarting = false
    @Published private(set) var catalogRoots: [UUID: [CatalogNode]] = [:]
    @Published private(set) var catalogErrors: [UUID: String] = [:]
    @Published private var completionCatalog = SQLCompletionCatalog()
    @Published var inspection: CatalogInspection?
    @Published var catalogSearch = ""
    @Published private(set) var catalogSearchResults: [UUID: [CatalogNode]] = [:]
    @Published private(set) var history: [SQLHistoryEntry] = []
    @Published var historyEnabled = true { didSet { scheduleSave() } }
    @Published var isHistoryPresented = false
    @Published private(set) var isClosing = false
    @Published var importPreview: [ImportedProfile]?
    @Published var importError: String?
    @Published private(set) var isImportingProfiles = false
    let editorState = SQLEditorState()
    let editorThemes: EditorThemeStore
    let appearance: AppAppearance
    let commandShortcuts: AppShortcutStore
    lazy var commands = AppCommandRegistry(workspace: self, shortcuts: commandShortcuts)

    private let connectionStore: any ConnectionLibraryStore
    private let credentialStore: any ConnectionCredentialStore
    private let helperFactory: () -> BackendClient
    private let documentStore: any SQLDocumentStore
    private let closeDecision: @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision
    let executionDecision: @MainActor (OperationConfirmation) async -> Bool
    private var autosave: Task<Void, Never>?
    private var draftsLoaded = false
    private var documentObservations: [UUID: [AnyCancellable]] = [:]
    private var helper: BackendClient?
    private var helperFailed = false
    private var helperGeneration = UUID()
    private var helperStart: Task<BackendClient, Error>?
    private var profileConnections: [UUID: Task<Void, Never>] = [:]
    private var disconnectingProfiles: Set<UUID> = []
    private var closingDocuments: Set<UUID> = []
    private var catalogRequests: [UUID: (id: UUID, task: Task<BackendMessage, Error>)] = [:]
    private var completionLoads: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var started = false
    private var observations: [UUID: AnyCancellable] = [:]
    private var libraryObservation: AnyCancellable?
    weak var presentationWindow: NSWindow?
    private var profileExportPanel: NSSavePanel?

    init(connectionStore: any ConnectionLibraryStore = FileConnectionLibraryStore(),
         credentialStore: any ConnectionCredentialStore = KeychainConnectionCredentialStore(),
         documentStore: any SQLDocumentStore = MemorySQLDocumentStore(),
         commandShortcuts: AppShortcutStore? = nil,
         editorThemes: EditorThemeStore? = nil,
         appearance: AppAppearance? = nil,
         closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = WorkspaceCloseConfirmation.present,
         executionDecision: @escaping @MainActor (OperationConfirmation) async -> Bool = ExecutionConfirmation.present,
         helperFactory: @escaping () -> BackendClient = { BackendClient() }) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.helperFactory = helperFactory
        self.documentStore = documentStore
        self.commandShortcuts = commandShortcuts ?? AppShortcutStore()
        let themes = editorThemes ?? appearance?.editorThemes ?? EditorThemeStore()
        self.editorThemes = themes
        self.appearance = appearance ?? AppAppearance(editorThemes: themes)
        self.closeDecision = closeDecision
        self.executionDecision = executionDecision
        library = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
        libraryObservation = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var selectedDocument: SQLDocument? { documents.first { $0.id == selectedDocumentID } }

    func start(startupConnection: Result<ConnectionSettings, StartupConnection.InputError>? = nil) async {
        guard !started else { return }
        started = true
        await restoreDocuments()
        isStarting = true
        defer { isStarting = false }
        do {
            _ = try await ensureHelper()
            if case .success(let settings) = startupConnection {
                let existing = library.savedConnections.first { $0.matches(settings) }
                if await library.saveConnection(name: existing?.name ?? settings.database, settings: settings, id: existing?.id),
                   let id = library.selectedConnectionId { await connectProfile(id) }
            } else if case .failure(let failure) = startupConnection { error = failure.localizedDescription }
            if documents.isEmpty { newDocument(profileID: library.selectedConnectionId) }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func newDocument(profileID: UUID? = nil, text: String = "SELECT 1;") -> SQLDocument {
        let document = SQLDocument(title: "SQL \(documents.count + 1)", text: text,
            profileID: profileID ?? library.selectedConnectionId)
        documents.append(document)
        observeDocument(document)
        selectedDocumentID = document.id
        scheduleSave()
        return document
    }

    func connectProfile(_ id: UUID) async {
        guard shutdownTask == nil, !isClosing, !disconnectingProfiles.contains(id) else { return }
        if let connection = profileConnections[id] { await connection.value; return }
        let task = Task { @MainActor in await self.openProfile(id) }
        profileConnections[id] = task
        await task.value
        profileConnections[id] = nil
    }

    private func openProfile(_ id: UUID) async {
        do {
            let client = try await ensureHelper()
            if let service = services[id], service.connectionState == .connected { return }
            let service = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
            services[id] = service
            observations[id] = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            await service.start(sharedHelper: client)
            await service.connectSavedConnection(id)
            if service.connectionState != .connected { error = service.errorMessage ?? service.connectionsError }
            else {
                error = nil
                Task { @MainActor [weak self] in await self?.loadCompletionCatalog(id) }
            }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func disconnectProfile(_ id: UUID) async -> Bool {
        // A profile's working and service sessions close together. Other
        // profiles keep their connections and in-flight queries.
        guard !isClosing, !documents.contains(where: { $0.profileID == id && closingDocuments.contains($0.id) }),
              disconnectingProfiles.insert(id).inserted else { return false }
        let grids = documents.filter { $0.profileID == id }.compactMap(\.grid)
        for grid in grids { grid.commitEditing?() }
        for grid in grids { grid.isClosing = true }
        defer {
            disconnectingProfiles.remove(id)
            for grid in grids { grid.isClosing = false }
        }
        guard await prepareToClose(.profile(id)) else { return false }
        completionLoads.removeValue(forKey: id)?.task.cancel()
        if let connecting = profileConnections[id] { await connecting.value }
        let sessions = documents.filter { $0.profileID == id }.compactMap(\.runtime)
        for session in sessions { await session.shutdown() }
        if let service = services.removeValue(forKey: id) { await service.shutdown() }
        observations[id] = nil
        catalogRoots[id] = nil
        completionCatalog.remove(profileID: id)
        catalogErrors[id] = nil
        for document in documents where document.profileID == id {
            document.runtime = nil
            document.attachGrid(nil)
        }
        return true
    }

    func closeDocument(_ document: SQLDocument) async {
        guard canStartOperation(document), closingDocuments.insert(document.id).inserted else { return }
        let grid = document.grid
        grid?.commitEditing?()
        grid?.isClosing = true
        defer {
            closingDocuments.remove(document.id)
            grid?.isClosing = false
        }
        guard await prepareToClose(.document(document.id)) else { return }
        await closeDocumentImmediately(document)
    }

    func canStartOperation(_ document: SQLDocument, forClosing: Bool = false) -> Bool {
        guard shutdownTask == nil, documents.contains(where: { $0.id == document.id }) else { return false }
        return forClosing || (!isClosing && !closingDocuments.contains(document.id) &&
            document.profileID.map { !disconnectingProfiles.contains($0) } != false)
    }

    private func closeDocumentImmediately(_ document: SQLDocument) async {
        if let runtime = document.runtime { await runtime.shutdown() }
        documents.removeAll { $0.id == document.id }
        documentObservations[document.id] = nil
        editorState.removeDocument(document.id)
        if selectedDocumentID == document.id { selectedDocumentID = documents.last?.id }
        scheduleSave()
    }

    func run(_ document: SQLDocument, sql: String? = nil) async {
        guard canStartOperation(document) else { return }
        if document.table != nil {
            document.grid?.commitEditing?()
            guard !isClosing, document.grid?.isApplying != true else { return }
            if let grid = document.grid, grid.outcomeUnknown {
                guard await closeDecision(.unknownApply(document.title)) == .discard else { return }
                grid.discard()
                grid.outcomeUnknown = true
            } else if let grid = document.grid, grid.pendingCount > 0 {
                let decision = await closeDecision(.changes(document.title, count: grid.pendingCount))
                if decision == .apply { _ = await applyGrid(document); return }
                guard decision == .discard else { return }
                grid.discard()
            }
            await execute(document, statements: [])
            return
        }
        if let sql {
            let engine = library.savedConnections.first { $0.id == document.profileID }?.engine ?? .postgresql
            let parsed = SQLScriptParser.parse(sql, engine: engine)
            if let diagnostic = parsed.diagnostics.first { document.localError = diagnostic.message; return }
            await execute(document, statements: parsed.statements, sourceSQL: sql)
            return
        }
        guard let fragment = executionFragment(document) else { return }
        await runResolved(document, fragment: fragment)
    }

    func reloadTableAfterDiscard(_ document: SQLDocument) async { await execute(document, statements: []) }

    func runScript(_ document: SQLDocument) async {
        guard let fragment = executionFragment(document, script: true) else { return }
        await runResolved(document, fragment: fragment, script: true)
    }

    func executionFragment(_ document: SQLDocument, script: Bool = false) -> SQLExecutionFragment? {
        let engine = library.savedConnections.first { $0.id == document.profileID }?.engine ?? .postgresql
        let selection = editorState.selection(for: document.id, fallback: document.selection)
        return SQLExecutionFragment.resolve(text: document.text, selection: selection, engine: engine, script: script)
    }

    func runResolved(_ document: SQLDocument, fragment: SQLExecutionFragment, script: Bool = false) async {
        if let diagnostic = fragment.diagnostic {
            document.clearExecutionSuccess()
            document.localError = diagnostic.message
            document.errorPosition = diagnostic.range.location
            return
        }
        await execute(document, statements: fragment.statements, isScript: script, sourceSQL: fragment.sourceSQL)
    }

    private func execute(_ document: SQLDocument, statements: [SQLStatement], export: ExportRequest? = nil,
                         isScript: Bool = false, sourceSQL: String? = nil) async {
        guard canStartOperation(document), !document.isRunning, let profileID = document.profileID else { return }
        guard document.table != nil || !statements.isEmpty else { return }
        guard let profile = library.savedConnections.first(where: { $0.id == profileID }) else { return }
        let boundText = document.text
        document.clearExecutionSuccess()
        let executionRevision = document.executionRevision
        let previousGrid = document.table == nil ? nil : document.grid
        previousGrid?.isReloading = true
        document.isRunning = true
        document.stopRequested = false
        document.localError = nil
        document.errorPosition = nil
        document.executions = statements.map { SQLExecution(sql: $0.sql, range: $0.range) }
        document.selectedExecution = 0
        defer {
            document.isRunning = false
            previousGrid?.isReloading = false
        }
        do {
            let client = try await ensureHelper()
            guard canStartOperation(document), !document.stopRequested, document.text == boundText,
                  document.profileID == profileID,
                  library.savedConnections.first(where: { $0.id == profileID }) == profile else {
                throw ExecutionPolicyError(message: "The SQL or connection context changed before execution. Review it and run again.")
            }
            if services[profileID]?.connectionState != .connected { await connectProfile(profileID) }
            guard documents.contains(where: { $0.id == document.id }),
                  services[profileID]?.connectionState == .connected else { return }
            if document.runtime?.connectionState != .connected {
                let runtime = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
                document.attach(runtime)
                await runtime.start(sharedHelper: client)
                await runtime.connectSavedConnection(profileID)
            }
            guard let runtime = document.runtime else { return }
            guard !document.stopRequested, document.text == boundText, document.profileID == profileID,
                  library.savedConnections.first(where: { $0.id == profileID }) == profile else {
                throw ExecutionPolicyError(message: "The SQL or connection context changed while connecting. Review it and run again.")
            }
            guard runtime.connectionState == .connected else {
                document.localError = runtime.errorMessage ?? runtime.connectionsError ?? "The working session could not be opened."
                for index in document.executions.indices { document.executions[index].status = "Not executed" }
                return
            }
            runtime.sql = document.text
            if let table = document.table {
                let metadata: [[String: String]]
                do {
                    let structure = try await catalog(CatalogRequest(kind: "columns", schema: table.schema,
                        object: table.name, objectKind: table.kind), profileID: profileID)
                    metadata = structure.catalogRecords
                } catch {
                    document.localError = error.localizedDescription
                    return
                }
                guard canStartOperation(document), !document.stopRequested else { return }
                await runtime.run(catalog: CatalogRequest(kind: "browse", schema: table.schema,
                    object: table.name, objectKind: table.kind, page: document.page,
                    sort: document.tableSort, filters: document.tableFilters))
                if runtime.queryFailure == nil, let result = runtime.result {
                    document.tableColumns = metadata
                    let grid = GridDraft(reference: table, result: result, metadata: metadata)
                    grid.policyReadOnly = runtime.policy.readOnly
                    document.attachGrid(grid)
                }
            } else {
                guard let sessionID = runtime.sessionId else { return }
                guard runtime.activeConnectionId == profileID, runtime.policy == profile.policy,
                      runtime.engine == profile.engine, runtime.host == profile.host,
                      Int(runtime.port) == profile.port, runtime.database == profile.database,
                      runtime.user == profile.user, runtime.sslMode == profile.sslMode,
                      (runtime.sslRootCert.isEmpty ? nil : runtime.sslRootCert) == profile.sslRootCert else {
                    throw ExecutionPolicyError(message: "The profile changed. Disconnect and reconnect before executing SQL.")
                }
                let operations = statements.map { OperationRequest(type: "execute", sql: $0.sql, export: export) }
                guard let authorization = try await authorizeOperations(operations, sessionID: sessionID,
                    profile: profile, client: client, isScript: isScript || statements.count > 1,
                    sourceSQL: isScript || statements.count > 1 ? (sourceSQL ?? statements.map(\.sql).joined(separator: ";\n")) : nil),
                    canStartOperation(document), !document.stopRequested,
                    document.profileID == profileID, document.runtime === runtime,
                    runtime.sessionId == sessionID, runtime.policy == profile.policy,
                    library.savedConnections.first(where: { $0.id == profileID }) == profile,
                    document.text == boundText else {
                    _ = try? await client.request(.cancel(sessionId: sessionID, queryId: UUID().uuidString))
                    for index in document.executions.indices { document.executions[index].status = "Not executed" }
                    return
                }
                for (index, statement) in statements.enumerated() {
                    guard !document.stopRequested, document.text == boundText,
                          document.profileID == profileID, runtime.sessionId == sessionID,
                          library.savedConnections.first(where: { $0.id == profileID }) == profile else { break }
                    document.selectedExecution = index
                    document.executions[index].status = "Running"
                    await runtime.run(sql: statement.sql, export: export, authorization: authorization)
                    document.executions[index].result = runtime.result
                    document.executions[index].failure = runtime.queryFailure
                    document.executions[index].status = runtime.queryFailure?.title ?? (runtime.result == nil ? "Failed" : "Completed")
                    if runtime.queryFailure?.outcomeUnknown == true { document.executions[index].status = "Unknown outcome" }
                    if runtime.queryFailure == nil, let result = runtime.result, result.outcomeUnknown != true {
                        document.recordExecutionSuccess(statement, revision: executionRevision)
                    }
                    recordHistory(document: document, sql: statement.sql, outcome: document.executions[index].status)
                    if let position = runtime.queryErrorPosition {
                        let scalars = statement.sql.unicodeScalars
                        let end = scalars.index(scalars.startIndex, offsetBy: min(max(0, position - 1), scalars.count))
                        document.errorPosition = statement.range.location + String(scalars[..<end]).utf16.count
                    }
                    if runtime.queryFailure != nil || runtime.result == nil { break }
                }
                for index in document.executions.indices where document.executions[index].status == "Pending" {
                    document.executions[index].status = "Skipped"
                }
                _ = try? await client.request(.cancel(sessionId: sessionID, queryId: UUID().uuidString))
            }
        } catch {
            document.localError = error.localizedDescription
            for index in document.executions.indices where document.executions[index].status == "Pending" {
                document.executions[index].status = "Not executed"
            }
        }
    }

    func stop(_ document: SQLDocument) async {
        if document.grid?.isApplying == true { await stopGridApply(document); return }
        document.stopRequested = true
        await document.runtime?.stop()
    }

    func flushDocuments() async {
        autosave?.cancel()
        autosave = nil
        guard draftsLoaded else { return }
        do { try await documentStore.save(snapshot()) }
        catch { self.error = error.localizedDescription }
    }

    func clearHistory() async { history = []; await flushDocuments() }

    func clearRestoredDocuments() async {
        guard !isClosing, closingDocuments.isEmpty, disconnectingProfiles.isEmpty else { return }
        let affected = documents
        let ids = Set(affected.map(\.id))
        guard closingDocuments.isDisjoint(with: ids) else { return }
        closingDocuments.formUnion(ids)
        let grids = affected.compactMap(\.grid)
        for grid in grids { grid.commitEditing?() }
        for grid in grids { grid.isClosing = true }
        defer {
            closingDocuments.subtract(ids)
            for grid in grids { grid.isClosing = false }
        }
        guard await prepareToClose(.application) else { return }
        for document in affected { await closeDocumentImmediately(document) }
        await flushDocuments()
    }

    func prepareToClose(_ scope: WorkspaceCloseScope) async -> Bool {
        guard !isClosing else { return false }
        let affected: [SQLDocument]
        switch scope {
        case .document(let id): affected = documents.filter { $0.id == id }
        case .profile(let id): affected = documents.filter { $0.profileID == id }
        case .application: affected = documents
        }
        for document in affected { document.grid?.commitEditing?() }
        isClosing = true
        defer { isClosing = false }
        let gridLocks = affected.compactMap(\.grid).map { ($0, $0.isClosing) }
        for (grid, _) in gridLocks { grid.isClosing = true }
        defer { for (grid, wasClosing) in gridLocks { grid.isClosing = wasClosing } }
        for document in affected {
            if let grid = document.grid, grid.isApplying {
                guard await closeDecision(.runningQuery("Apply in " + document.title)) == .stop else { return false }
                await stopGridApply(document)
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while grid.isApplying, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                if grid.isApplying { return false }
            }
            if document.isRunning {
                guard await closeDecision(.runningQuery(document.title)) == .stop else { return false }
                await stop(document)
                let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                while document.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if document.isRunning {
                    document.localError = "The query has not finished stopping. Wait for its final outcome before closing."
                    return false
                }
            }
            if let runtime = document.runtime, runtime.transactionStatus == .transaction || runtime.transactionStatus == .failedTransaction {
                let decision = await closeDecision(.transaction(document.title, failed: runtime.transactionStatus == .failedTransaction))
                guard decision == .commit || decision == .rollback else { return false }
                guard runtime.transactionStatus != .failedTransaction || decision == .rollback else { return false }
                await runtime.run(sql: decision == .commit ? "COMMIT" : "ROLLBACK")
                guard runtime.queryFailure == nil, runtime.transactionStatus == .idle else { return false }
            }
            if let grid = document.grid, grid.outcomeUnknown {
                guard await closeDecision(.unknownApply(document.title)) == .discard else { return false }
                document.attachGrid(nil)
            } else if let grid = document.grid, grid.pendingCount > 0 {
                switch await closeDecision(.changes(document.title, count: grid.pendingCount)) {
                case .apply:
                    guard await applyGrid(document, forClosing: true) else { return false }
                case .discard: document.attachGrid(nil)
                default: return false
                }
            }
        }
        return true
    }

    private func snapshot() -> SQLWorkspaceSnapshot {
        SQLWorkspaceSnapshot(documents: documents.filter { $0.table == nil }.map {
            StoredSQLDocument(id: $0.id, title: $0.title, text: $0.text, profileID: $0.profileID)
        }, selectedDocumentID: selectedDocumentID, history: history, historyEnabled: historyEnabled)
    }

    private func restoreDocuments() async {
        do {
            let saved = try await documentStore.load()
            history = saved.history
            historyEnabled = saved.historyEnabled
            documents = saved.documents.map { SQLDocument(id: $0.id, title: $0.title, text: $0.text, profileID: $0.profileID) }
            for document in documents { observeDocument(document) }
            selectedDocumentID = documents.contains { $0.id == saved.selectedDocumentID } ? saved.selectedDocumentID : documents.first?.id
            draftsLoaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func observeDocument(_ document: SQLDocument) {
        documentObservations[document.id] = [
            document.$text.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$title.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$profileID.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let document = newDocument(text: text)
                document.title = url.lastPathComponent
                document.fileURL = url
            } catch { self.error = "The SQL file could not be opened as UTF-8." }
        }
    }

    func saveSQLFile(_ document: SQLDocument, chooseLocation: Bool = false) {
        guard document.table == nil else { return }
        var destination = document.fileURL
        if chooseLocation || destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
            panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? document.title + ".sql"
            guard panel.runModal() == .OK else { return }
            destination = panel.url
        }
        guard let destination else { return }
        do {
            try document.text.write(to: destination, atomically: true, encoding: .utf8)
            document.fileURL = destination
            document.title = destination.lastPathComponent
        } catch { self.error = "The SQL file could not be saved." }
    }

    func exportLoaded(_ result: ExportResultSet, title: String, format: String) {
        let marker: String?
        if format == "csv" {
            guard let chosen = chooseNullMarker() else { return }
            marker = chosen
        } else { marker = nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == "csv" ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = title + "-loaded-\(result.rows.count)-rows." + format
        panel.message = result.truncated
            ? "This exports only the \(result.rows.count) loaded rows. The displayed result is truncated."
            : "This exports the loaded result without running SQL again."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = format == "csv" ? try ResultExport.csv(result, nullMarker: marker!) : try ResultExport.json([result])
            try ResultExport.write(data, to: destination)
        } catch { self.error = error.localizedDescription }
    }

    func runToFile(_ document: SQLDocument, format: String, fragment: SQLExecutionFragment? = nil) async {
        guard document.table == nil, !document.isRunning else { return }
        let boundText = document.text
        let boundProfileID = document.profileID
        let boundProfile = library.savedConnections.first { $0.id == boundProfileID }
        guard let fragment = fragment ?? executionFragment(document) else { return }
        guard fragment.diagnostic == nil, fragment.statements.count == 1 else {
            document.localError = "Select one SQL statement for Run to File."
            return
        }
        let marker: String?
        if format == "csv" {
            guard let chosen = chooseNullMarker() else { return }
            marker = chosen
        } else { marker = nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == "csv" ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = document.title + "." + format
        panel.message = "Run this SQL once and save all rows. The final file appears only after successful completion."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard document.text == boundText, document.profileID == boundProfileID,
              library.savedConnections.first(where: { $0.id == boundProfileID }) == boundProfile else {
            document.localError = "The SQL or connection changed while choosing the export file. Review it and run again."
            return
        }
        await execute(document, statements: fragment.statements,
            export: ExportRequest(path: destination.path, format: format, nullMarker: marker))
    }

    private func chooseNullMarker() -> String? {
        let alert = NSAlert()
        alert.messageText = "Choose CSV NULL Marker"
        alert.informativeText = "SQL NULL uses this marker. If a value equals the marker, choose another marker before exporting. Binary values use Base64."
        let field = NSTextField(string: "\\N")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard !field.stringValue.isEmpty else { error = ResultExportError.nullMarker.localizedDescription; return nil }
        return field.stringValue
    }

    func exportProfiles(_ profiles: [SavedConnection]? = nil) {
        let profiles = profiles ?? library.savedConnections
        guard !profiles.isEmpty, profileExportPanel == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = profiles.count == 1 ? "dbeer-connection.json" : "dbeer-connections.json"
        panel.message = "Share connection settings. Passwords and private keys are excluded."
        profileExportPanel = panel
        // Let menu tracking finish before presenting the panel, and keep it
        // attached to the workspace even when another window has focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                self.profileExportPanel = nil
                guard response == .OK, let destination = panel.url else { return }
                do { try ProfileTransfer.write(profiles, to: destination) }
                catch { self.error = error.localizedDescription }
            }
            if let window = self.presentationWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }

    func previewProfileImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            importPreview = try ProfileTransfer.preview(Data(contentsOf: source))
            importError = nil
        } catch { self.error = error.localizedDescription }
    }

    func chooseImportedCA(_ id: UUID) {
        guard let index = importPreview?.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose this Mac's trusted CA file. The profile's TLS verification mode stays the same."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        importPreview?[index].profile.sslRootCert = selected.path
    }

    func importProfiles() async {
        guard !isImportingProfiles else { return }
        let profiles = selectedImportProfiles
        guard !profiles.isEmpty else { return }
        guard !profiles.contains(where: \.requiresCASelection) else {
            importError = "Choose the missing CA files before importing."
            return
        }
        isImportingProfiles = true
        defer { isImportingProfiles = false }
        importError = nil
        for imported in profiles {
            // saveConnection allocates a new UUID and addresses only its new
            // Keychain account; existing profiles and credentials stay intact.
            guard await library.saveConnection(name: imported.profile.name, settings: imported.profile.settings(password: "")) else {
                importError = library.connectionsError ?? "This profile could not be imported."
                return
            }
            importPreview?.removeAll { $0.id == imported.id }
        }
        importPreview = nil
    }

    var selectedImportProfiles: [ImportedProfile] {
        (importPreview ?? []).filter(\.isSelected)
    }

    var canImportProfiles: Bool {
        !isImportingProfiles && !selectedImportProfiles.isEmpty &&
            !selectedImportProfiles.contains(where: \.requiresCASelection)
    }

    func selectImportProfile(_ id: UUID, selected: Bool) {
        guard !isImportingProfiles, let index = importPreview?.firstIndex(where: { $0.id == id }) else { return }
        importPreview?[index].isSelected = selected
    }

    func selectAllImportProfiles(_ selected: Bool) {
        guard !isImportingProfiles, let profiles = importPreview else { return }
        importPreview = profiles.map { imported in
            var imported = imported
            imported.isSelected = selected
            return imported
        }
    }

    func completions(profileID: UUID?) -> [String] {
        guard let profileID else { return [] }
        func collect(_ nodes: [CatalogNode]) -> [String] {
            nodes.flatMap { node in
                (node.kind == .object || node.kind == .detail || node.kind == .schema ? [node.name] : []) + collect(node.children ?? [])
            }
        }
        let metadata = completionCatalog.context(profileID: profileID).catalog.flatMap {
            [$0.schema, $0.name] + $0.columns
        }
        return Array(Set(collect(catalogRoots[profileID] ?? []) + metadata).subtracting([""])).sorted()
    }

    func completionContext(profileID: UUID?) -> SQLCompletionContext {
        completionCatalog.context(profileID: profileID)
    }

    /// Uses only the existing service session. Typing and restoring documents
    /// must never initiate a database connection or use a tab's transaction.
    func loadCompletionCatalog(_ profileID: UUID, refresh: Bool = false) async {
        guard shutdownTask == nil, !isClosing, !disconnectingProfiles.contains(profileID),
              let service = services[profileID], service.connectionState == .connected,
              let sessionID = service.sessionId else { return }
        if let loading = completionLoads[profileID] {
            if refresh { loading.task.cancel() }
            else { await loading.task.value; return }
        }
        let loadID = UUID()
        let task = Task { @MainActor in
            do {
                var records: [[String: String]] = []
                for page in 0..<50 {
                    try Task.checkCancellation()
                    let reply = try await self.catalog(CatalogRequest(kind: "completion", page: page),
                        profileID: profileID, connectedSessionID: sessionID)
                    guard reply.truncated != true else { return }
                    let batch = reply.catalogRecords
                    records += batch
                    if batch.count < 200 { break }
                }
                try Task.checkCancellation()
                guard self.services[profileID]?.sessionId == sessionID else { return }
                self.completionCatalog.record(records, request: CatalogRequest(kind: "completion"), profileID: profileID)
            } catch {
                // Completion metadata is optional; failures leave the editor
                // usable and preserve names already loaded by catalog browsing.
            }
        }
        completionLoads[profileID] = (loadID, task)
        await task.value
        if completionLoads[profileID]?.id == loadID { completionLoads[profileID] = nil }
    }

    private func scheduleSave() {
        guard draftsLoaded else { return }
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.flushDocuments()
        }
    }

    private func recordHistory(document: SQLDocument, sql: String, outcome: String) {
        var saved = snapshot()
        saved.record(SQLHistoryEntry(documentID: document.id, profileID: document.profileID, sql: sql, outcome: outcome))
        history = saved.history
        scheduleSave()
    }

    func loadSchemas(_ profileID: UUID, refresh: Bool = false) async {
        guard refresh || catalogRoots[profileID] == nil else { return }
        do {
            let result = try await catalog(CatalogRequest(kind: "schemas"), profileID: profileID)
            catalogRoots[profileID] = result.catalogRecords.compactMap { record in
                guard let name = record["name"] else { return nil }
                return CatalogNode(profileID: profileID, name: name, kind: .schema, schema: name)
            }
            catalogErrors[profileID] = nil
            if refresh { await loadCompletionCatalog(profileID, refresh: true) }
        } catch { catalogErrors[profileID] = error.localizedDescription }
    }

    func expand(_ node: CatalogNode, refresh: Bool = false) async {
        guard !node.isLoading, refresh || node.children == nil else { return }
        node.isLoading = true
        node.error = nil
        defer { node.isLoading = false }
        if node.kind == .schema {
            node.children = [("Tables", "table"), ("Views", "view"), ("Functions", "function"),
                ("Procedures", "procedure"), ("Triggers", "trigger")].map { title, kind in
                CatalogNode(profileID: node.profileID, name: title, kind: .group, schema: node.schema, objectKind: kind)
            }
            return
        }
        if node.kind == .object {
            node.children = [("Columns", "columns"), ("Keys", "keys"), ("Indexes", "indexes"),
                ("Constraints", "constraints"), ("Triggers", "triggers")].map { title, kind in
                CatalogNode(profileID: node.profileID, name: title, kind: .detailGroup, schema: node.schema,
                    object: node.name, objectKind: kind, identity: node.objectKind)
            }
            return
        }
        do {
            let request: CatalogRequest
            if node.kind == .group {
                request = CatalogRequest(kind: "objects", schema: node.schema, objectKind: node.objectKind)
            } else {
                request = CatalogRequest(kind: node.objectKind, schema: node.schema, object: node.object,
                    objectKind: node.identity ?? "table")
            }
            let result = try await catalog(request, profileID: node.profileID)
            node.children = result.catalogRecords.enumerated().compactMap { index, record in
                guard let name = record["name"] else { return nil }
                let isObject = node.kind == .group
                let type = record["nativeType"]
                return CatalogNode(profileID: node.profileID, name: name,
                    kind: isObject ? .object : .detail, schema: node.schema,
                    object: isObject ? name : node.object, objectKind: record["kind"] ?? node.objectKind,
                    identity: record["identity"] ?? String(index), detail: type ?? record["definition"])
            }
        } catch { node.error = error.localizedDescription }
    }

    func inspect(_ node: CatalogNode) async {
        let title = "\(node.schema).\(node.name)"
        inspection = CatalogInspection(title: title)
        let inspectionID = inspection?.id
        do {
            if ["table", "view"].contains(node.objectKind) {
                let structure = try await catalog(CatalogRequest(kind: "columns", schema: node.schema,
                    object: node.name, objectKind: node.objectKind), profileID: node.profileID)
                guard inspection?.id == inspectionID else { return }
                inspection?.structure = structure
            }
            let definition = try await catalog(CatalogRequest(kind: "definition", schema: node.schema,
                object: node.name, objectKind: node.objectKind, identity: node.identity), profileID: node.profileID)
            guard inspection?.id == inspectionID else { return }
            inspection?.definition = definition.catalogRecords.first?["definition"] ?? "Definition is unavailable."
        } catch {
            guard inspection?.id == inspectionID else { return }
            inspection?.error = error.localizedDescription
        }
        if inspection?.id == inspectionID { inspection?.isLoading = false }
    }

    func generatedSelect(_ node: CatalogNode) async -> String? {
        do {
            let result = try await catalog(CatalogRequest(kind: "select", schema: node.schema,
                object: node.name, objectKind: node.objectKind), profileID: node.profileID)
            return result.catalogRecords.first?["sql"]
        } catch { self.error = error.localizedDescription; return nil }
    }

    func generatedName(_ node: CatalogNode) async -> String? {
        do {
            let identity = ["function", "procedure", "trigger"].contains(node.objectKind) ? node.identity : nil
            let result = try await catalog(CatalogRequest(kind: "name", schema: node.schema,
                object: node.name, objectKind: node.objectKind, identity: identity), profileID: node.profileID)
            return result.catalogRecords.first?["name"]
        } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult
    func copyName(_ node: CatalogNode, to pasteboard: NSPasteboard = .general) async -> Bool {
        guard let name = await generatedName(node) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(name, forType: .string)
    }

    func openData(_ node: CatalogNode) async {
        let document = newDocument(profileID: node.profileID, text: "Table data")
        document.title = node.name
        document.table = TableReference(schema: node.schema, name: node.name, kind: node.objectKind)
        do {
            let structure = try await catalog(CatalogRequest(kind: "columns", schema: node.schema,
                object: node.name, objectKind: node.objectKind), profileID: node.profileID)
            document.tableColumns = structure.catalogRecords
        } catch { document.localError = error.localizedDescription }
        await run(document)
    }

    func searchCatalog() async {
        let term = catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogSearchResults = [:]
        guard !term.isEmpty else { return }
        for profileID in services.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !Task.isCancelled, catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            do {
                let result = try await catalog(CatalogRequest(kind: "search", search: term), profileID: profileID)
                guard !Task.isCancelled, catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                catalogSearchResults[profileID] = result.catalogRecords.compactMap { record in
                    guard let name = record["name"], let schema = record["schema"] else { return nil }
                    return CatalogNode(profileID: profileID, name: name, kind: .object, schema: schema,
                        object: name, objectKind: record["kind"] ?? "table", identity: record["identity"])
                }
            } catch { catalogErrors[profileID] = error.localizedDescription }
        }
    }

    private func catalog(_ request: CatalogRequest, profileID: UUID, connectedSessionID: String? = nil) async throws -> BackendMessage {
        let client: BackendClient
        if let connectedSessionID {
            guard shutdownTask == nil, !helperFailed, !disconnectingProfiles.contains(profileID),
                  services[profileID]?.sessionId == connectedSessionID,
                  services[profileID]?.connectionState == .connected, let helper else {
                throw CatalogFailure(message: "The profile was disconnected while loading completion metadata.")
            }
            client = helper
        } else {
            client = try await ensureHelper()
            await connectProfile(profileID)
        }
        guard let sessionID = services[profileID]?.sessionId else {
            throw CatalogFailure(message: services[profileID]?.errorMessage ?? "Connect to this profile before browsing objects.")
        }
        let previous = catalogRequests[profileID]?.task
        let requestID = UUID()
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await client.request(.catalog(sessionId: sessionID, request: request))
        }
        catalogRequests[profileID] = (requestID, task)
        defer { if catalogRequests[profileID]?.id == requestID { catalogRequests[profileID] = nil } }
        let reply = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard services[profileID]?.sessionId == sessionID else {
            throw CatalogFailure(message: "The profile was disconnected while loading this branch.")
        }
        if request.kind != "completion" {
            completionCatalog.record(reply.catalogRecords, request: request, profileID: profileID)
        }
        return reply
    }

    private struct CatalogFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { @MainActor in
            await self.flushDocuments()
            for load in self.completionLoads.values { load.task.cancel() }
            await self.editorState.languageService.shutdown()
            if let start = self.helperStart { _ = try? await start.value }
            if let helper = self.helper { _ = await helper.shutdown() }
            await self.library.shutdown()
        }
        shutdownTask = task
        await task.value
    }

    func ensureHelper() async throws -> BackendClient {
        guard shutdownTask == nil else { throw BackendTransportError(.notReady) }
        if let helperStart { return try await helperStart.value }
        if let helper, !helperFailed { return helper }
        let task = Task { @MainActor [self] () throws -> BackendClient in
            if let previous = self.helper { _ = await previous.shutdown() }
            let client = self.helperFactory()
            try await client.start()
            self.helper = client
            self.helperFailed = false
            let generation = UUID()
            self.helperGeneration = generation
            Task { @MainActor [weak self] in
                let failure = await client.waitForFailure()
                guard let self, self.shutdownTask == nil, self.helperGeneration == generation else { return }
                self.helperFailed = true
                self.error = failure.localizedDescription
            }
            return client
        }
        helperStart = task
        defer { helperStart = nil }
        let client = try await task.value
        if started { await library.start(sharedHelper: client) }
        return client
    }
}
