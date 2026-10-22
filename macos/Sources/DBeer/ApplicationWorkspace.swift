import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A document owns its text and its working session. Profile service sessions
/// belong to the workspace and never execute document SQL.
@MainActor
final class SQLDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var text: String {
        didSet {
            if !SQLFileDocument.sameBytes(text, oldValue) {
                clearExecutionSuccess()
                if !isSynchronizingFile, let fileDocument, !SQLFileDocument.sameBytes(fileDocument.text, text) {
                    fileDocument.text = text
                }
            }
        }
    }
    @Published var profileID: UUID? {
        didSet {
            if profileID != oldValue {
                clearExecutionSuccess()
                tableForeignKeys = []
                foreignKeysError = nil
                tableResult = nil
                tableSnapshotSource = nil
                tableFailure = nil
                tableNavigationError = nil
                foreignKeysRequestID = UUID()
                isLoadingForeignKeys = false
                tableBackHistory = []
                tableForwardHistory = []
                if profileID != nil { historyConnectionNotice = nil }
            }
        }
    }
    @Published var historyConnectionNotice: String?
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
    @Published var fileContentSHA256: String?
    @Published var restoredFileBinding = false
    @Published var fileRecoveryURL: URL?
    @Published private(set) var fileDocument: SQLFileDocument?
    @Published var sqlLibraryEntryID: UUID?
    private var restoredFileDocumentID: UUID?
    private var fileObservations: [AnyCancellable] = []
    private var isSynchronizingFile = false
    var fileDidMove: ((URL, URL) -> Void)?
    var stopRequested = false
    @Published var table: TableReference?
    @Published var tableNeedsExplicitLoad = false
    @Published var page = 0
    @Published var tableCursor: String?
    @Published var tableNextCursor: String?
    @Published var tableSort: [CatalogSort] = [] { didSet { if tableSort != oldValue { resetTablePaging() } } }
    @Published var tableFilters: [CatalogFilter] = [] {
        didSet {
            guard tableFilters != oldValue else { return }
            resetTablePaging()
            if tableColumns.contains(where: { (Int($0["partitionKeyPosition"] ?? "0") ?? 0) > 0 }),
               !CassandraBrowseRules.hasValidSort(self) { tableSort = [] }
        }
    }
    @Published var tableColumns: [[String: String]] = []
    @Published var tableResult: BackendMessage?
    @Published var tableSnapshotSource: ResultSnapshotSource?
    @Published var tableFailure: WorkspaceModel.QueryFailure?
    @Published var tableForeignKeys: [TableForeignKey] = []
    @Published var foreignKeysError: String?
    @Published var tableNavigationError: String?
    @Published var isLoadingForeignKeys = false
    @Published var isNavigatingTable = false
    @Published var tableBackHistory: [TableViewLocation] = []
    @Published var tableForwardHistory: [TableViewLocation] = []
    var foreignKeysRequestID = UUID()
    var tableNavigationSourceState: StoredSQLDocument?
    var isProvisionalTableView = false
    var provisionalPreviousSelection: UUID?
    @Published private(set) var grid: GridDraft?
    @Published private(set) var snapshotID: UUID?
    @Published private(set) var snapshotModel: ResultSnapshotDocumentModel?
    @Published private(set) var isSnapshot = false
    @Published private(set) var investigationID: UUID?
    @Published private(set) var investigationModel: InvestigationDocumentModel?
    @Published private(set) var isInvestigation = false
    private var runtimeObservation: AnyCancellable?
    private var gridObservation: AnyCancellable?
    private var snapshotObservation: AnyCancellable?
    private var investigationObservations: [AnyCancellable] = []
    private var isSynchronizingInvestigationTitle = false

    init(id: UUID = UUID(), title: String = "SQL", text: String = "SELECT 1;", profileID: UUID? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.profileID = profileID
    }

    /// The persisted document identity distinguishes independent views of the
    /// same database relation, including views restored by R09.
    var tableViewID: UUID? { table == nil ? nil : id }
    var isSQLDocument: Bool { table == nil && !isSnapshot && !isInvestigation }
    var canNavigateTable: Bool {
        table != nil && !isRunning && !isNavigatingTable && grid?.isApplying != true &&
            grid?.isReloading != true && grid?.isPreviewing != true && grid?.isClosing != true
    }
    var canNavigateTableBack: Bool { canNavigateTable && !tableBackHistory.isEmpty }
    var canNavigateTableForward: Bool { canNavigateTable && !tableForwardHistory.isEmpty }

    /// Reopening a saved document creates presentation state only. Runtime,
    /// cursors, result rows, executions and pending grid writes stay absent.
    convenience init(restoring stored: StoredSQLDocument) {
        self.init(id: stored.id, title: stored.title,
            text: stored.kind == .snapshot || stored.kind == .investigation ? "" : stored.text,
            profileID: stored.kind == .snapshot || stored.kind == .investigation ? nil : stored.profileID)
        if stored.kind == .investigation {
            isInvestigation = true
            investigationID = stored.investigationID
            return
        }
        if stored.kind == .snapshot {
            isSnapshot = true
            snapshotID = stored.snapshotID
            return
        }
        if let savedTable = stored.table, stored.kind == .table {
            table = savedTable.reference
            tableFilters = savedTable.filters
            tableSort = savedTable.sort
            page = savedTable.page
            tableNeedsExplicitLoad = true
        } else {
            fileURL = stored.fileURL
            fileContentSHA256 = stored.fileContentSHA256
            restoredFileDocumentID = stored.fileDocumentID
            fileRecoveryURL = stored.fileRecoveryURL
            sqlLibraryEntryID = stored.sqlLibraryEntryID
            restoredFileBinding = stored.fileURL != nil
        }
    }

    /// This state can also be used by future closed-tab and pane restoration.
    /// A table's loaded rows and local edit draft are deliberately excluded.
    var storedState: StoredSQLDocument {
        if isInvestigation {
            return StoredSQLDocument(id: id, title: title, text: "", kind: .investigation, investigationID: investigationID)
        }
        if isSnapshot {
            return StoredSQLDocument(id: id, title: title, text: "", kind: .snapshot, snapshotID: snapshotID)
        }
        return StoredSQLDocument(id: id, title: title, text: text, profileID: profileID,
            kind: table == nil ? .sql : .table,
            table: table.map { StoredTableDocument(reference: $0, page: page, filters: tableFilters, sort: tableSort) },
            fileURL: table == nil ? fileURL : nil,
            fileContentSHA256: table == nil && fileURL != nil ? fileContentSHA256 : nil,
            fileDocumentID: table == nil ? (fileDocument?.id ?? restoredFileDocumentID) : nil,
            fileRecoveryURL: table == nil ? fileRecoveryURL : nil,
            sqlLibraryEntryID: table == nil ? sqlLibraryEntryID : nil)
    }

    func attachFileDocument(_ file: SQLFileDocument) {
        guard isSQLDocument else { return }
        fileObservations = []
        fileDocument = file
        restoredFileDocumentID = file.id
        synchronizeFileText(file.text)
        fileURL = file.url
        fileContentSHA256 = file.acceptedSHA256
        restoredFileBinding = file.restoredBinding
        fileRecoveryURL = file.recoveryURL
        fileObservations = [
            file.$text.dropFirst().sink { [weak self] in self?.synchronizeFileText($0) },
            file.$url.dropFirst().sink { [weak self] url in
                guard let self else { return }
                let oldURL = self.fileURL
                let oldName = self.fileURL?.lastPathComponent
                self.fileURL = url
                if self.title == oldName { self.title = url.lastPathComponent }
                if let oldURL, oldURL != url { self.fileDidMove?(oldURL, url) }
            },
            file.$acceptedSHA256.dropFirst().sink { [weak self] in self?.fileContentSHA256 = $0 },
            file.$restoredBinding.dropFirst().sink { [weak self] in self?.restoredFileBinding = $0 },
            file.$recoveryURL.dropFirst().sink { [weak self] in self?.fileRecoveryURL = $0 },
            file.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    private func synchronizeFileText(_ value: String) {
        guard !SQLFileDocument.sameBytes(text, value) else { return }
        isSynchronizingFile = true
        text = value
        isSynchronizingFile = false
    }

    func detachFileDocument() {
        fileObservations = []
        fileDocument = nil
    }

    func resetTablePaging() {
        page = 0
        tableCursor = nil
        tableNextCursor = nil
    }

    func attach(_ model: WorkspaceModel, preserveTablePage: Bool = false) {
        guard !isSnapshot && !isInvestigation else { return }
        if preserveTablePage {
            tableCursor = nil
            tableNextCursor = nil
        } else { resetTablePaging() }
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
              SQLFileDocument.sameBytes(source.substring(with: range), statement.sql) else { return }
        successfulExecutionRanges.append(range)
    }

    func attachGrid(_ draft: GridDraft?) {
        grid = draft
        gridObservation = draft?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func attachSnapshot(_ model: ResultSnapshotDocumentModel) {
        isSnapshot = true
        snapshotID = model.snapshotID
        snapshotModel = model
        snapshotObservation = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func attachInvestigation(_ model: InvestigationDocumentModel) {
        isInvestigation = true
        investigationID = model.id
        investigationModel = model
        title = model.title
        investigationObservations = [
            model.$title.dropFirst().sink { [weak self] title in
                guard let self, self.title != title else { return }
                self.isSynchronizingInvestigationTitle = true
                self.title = title
                self.isSynchronizingInvestigationTitle = false
            },
            model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    func updateInvestigationTitle(_ title: String) {
        guard !isSynchronizingInvestigationTitle, let model = investigationModel, model.title != title else { return }
        model.title = title
    }
}

/// Operation ownership stays valid when selection changes. Command routing adds
/// the requirement that the owning tab and block are currently visible.
@MainActor
struct OwnedSQLContext {
    let tab: SQLDocument
    let sql: SQLDocument
    let investigationID: UUID?
    let blockID: UUID?
    let paneID: WorkspacePaneID
}

struct SQLExecution: Identifiable {
    let id = UUID()
    let sql: String
    let range: NSRange
    var status = "Pending"
    var result: BackendMessage?
    var failure: WorkspaceModel.QueryFailure?
    var snapshotSource: ResultSnapshotSource?
}

@MainActor
final class ApplicationWorkspace: ObservableObject {
    let library: WorkspaceModel
    @Published private(set) var documents: [SQLDocument] = []
    @Published private(set) var closedTabs: [ClosedWorkspaceTab] = []
    @Published private(set) var paneLayout = WorkspacePaneLayout() { didSet { scheduleSave() } }
    @Published private(set) var services: [UUID: WorkspaceModel] = [:]
    @Published private(set) var error: String?
    let notifications = WorkspaceNotifications()
    @Published private(set) var isStarting = false
    @Published private(set) var catalogRoots: [UUID: [CatalogNode]] = [:]
    @Published private(set) var catalogErrors: [UUID: String] = [:]
    @Published private var completionCatalog = SQLCompletionCatalog()
    @Published var inspection: CatalogInspection?
    @Published var clusterInspection: CassandraClusterInspection?
    @Published var typeInspection: PostgresTypeInspectionModel? {
        didSet {
            if oldValue?.id != typeInspection?.id, let oldValue {
                invalidatePostgresTypeModel(oldValue, reason: "This type inspector was closed.")
            }
        }
    }
    @Published var catalogSearch = ""
    @Published private(set) var catalogSearchResults: [UUID: [CatalogNode]] = [:]
    @Published private(set) var history: [SQLHistoryEntry] = []
    @Published private(set) var historySettings = SQLHistoryRetentionSettings.default
    @Published private(set) var historyError: String?
    @Published var historyEnabled = true { didSet { scheduleSave() } }
    @Published var isHistoryPresented = false
    @Published var schemaComparison: SchemaComparisonModel?
    @Published var isSnapshotsPresented = false
    @Published var isInvestigationsPresented = false
    @Published private(set) var isClosing = false
    @Published var importPreview: [ImportedProfile]?
    @Published var importError: String?
    @Published var insertCopySelection: InsertCopySelection?
    @Published private(set) var isImportingProfiles = false
    let editorState = SQLEditorState()
    let editorThemes: EditorThemeStore
    let appearance: AppAppearance
    let commandShortcuts: AppShortcutStore
    let copySettings: ResultCopySettings
    let sqlFolders: SQLFolderLibrary
    let sqlLibrary: SQLLibrary
    let resultSnapshots: ResultSnapshotsModel
    let investigations: InvestigationLibraryModel
    lazy var commands = AppCommandRegistry(workspace: self, shortcuts: commandShortcuts)

    private let connectionStore: any ConnectionLibraryStore
    private let credentialStore: any ConnectionCredentialStore
    private let helperFactory: () -> BackendClient
    private let documentStore: any SQLDocumentStore
    private let closeDecision: @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision
    let executionDecision: @MainActor (OperationConfirmation) async -> Bool
    private var autosave: Task<Void, Never>?
    private var documentSaveTask: Task<Bool, Never>?
    private var documentSaveID = UUID()
    private var documentSaveError: String?
    private var documentRestoreTask: Task<Void, Never>?
    private var draftsLoaded = false
    private var documentObservations: [UUID: [AnyCancellable]] = [:]
    private var helper: BackendClient?
    private var helperFailed = false
    private var helperGeneration = UUID()
    private var helperStart: Task<BackendClient, Error>?
    private var profileConnections: [UUID: Task<Void, Never>] = [:]
    private var disconnectingProfiles: Set<UUID> = []
    private var closingDocuments: Set<UUID> = []
    private var paneSelectionRevisions: [WorkspacePaneID: UInt64] = [:]
    private var paneActivationRevision: UInt64 = 0
    private var paneSplitRevision: UInt64 = 0
    @Published private var isClearingDocuments = false
    private var catalogRequests: [UUID: (id: UUID, task: Task<BackendMessage, Error>)] = [:]
    private var completionLoads: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var started = false
    private var observations: [UUID: AnyCancellable] = [:]
    var typeProfileRevisions: [UUID: UUID] = [:]
    var typeProfileFingerprints: [UUID: Data] = [:]
    var typeServiceGenerations: [UUID: UUID] = [:]
    var typeSessionObservations: [UUID: [AnyCancellable]] = [:]
    private var typeProfilesObservation: AnyCancellable?
    private var libraryObservation: AnyCancellable?
    private var libraryErrorObservation: AnyCancellable?
    private var folderObservation: AnyCancellable?
    private var folderSaveObservation: AnyCancellable?
    private var sqlLibraryObservation: AnyCancellable?
    private var sqlLibrarySaveObservation: AnyCancellable?
    private var resultSnapshotsObservation: AnyCancellable?
    private var investigationsObservation: AnyCancellable?
    private var investigationSnapshotDocuments: [UUID: [UUID: SQLDocument]] = [:]
    private var fileDocuments: [UUID: SQLFileDocument] = [:]
    private let automaticallyWatchFiles: Bool
    weak var presentationWindow: NSWindow?
    private var profileExportPanel: NSSavePanel?

    init(connectionStore: any ConnectionLibraryStore = FileConnectionLibraryStore(),
         credentialStore: any ConnectionCredentialStore = KeychainConnectionCredentialStore(),
         documentStore: any SQLDocumentStore = MemorySQLDocumentStore(),
         commandShortcuts: AppShortcutStore? = nil,
         copySettings: ResultCopySettings? = nil,
         editorThemes: EditorThemeStore? = nil,
         appearance: AppAppearance? = nil,
         sqlFolders: SQLFolderLibrary? = nil,
         sqlLibrary: SQLLibrary? = nil,
         resultSnapshots: ResultSnapshotsModel? = nil,
         investigations: InvestigationLibraryModel? = nil,
         automaticallyWatchFiles: Bool = true,
         closeDecision: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = WorkspaceCloseConfirmation.present,
         executionDecision: @escaping @MainActor (OperationConfirmation) async -> Bool = ExecutionConfirmation.present,
         helperFactory: @escaping () -> BackendClient = { BackendClient() }) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.helperFactory = helperFactory
        self.documentStore = documentStore
        self.commandShortcuts = commandShortcuts ?? AppShortcutStore()
        self.copySettings = copySettings ?? .shared
        self.sqlFolders = sqlFolders ?? SQLFolderLibrary()
        self.sqlLibrary = sqlLibrary ?? SQLLibrary()
        let snapshots = resultSnapshots ?? ResultSnapshotsModel()
        self.resultSnapshots = snapshots
        self.investigations = investigations ?? InvestigationLibraryModel(snapshotStore: snapshots.store)
        self.automaticallyWatchFiles = automaticallyWatchFiles
        let themes = editorThemes ?? appearance?.editorThemes ?? EditorThemeStore()
        self.editorThemes = themes
        self.appearance = appearance ?? AppAppearance(editorThemes: themes)
        self.closeDecision = closeDecision
        self.executionDecision = executionDecision
        library = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
        libraryObservation = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        typeProfilesObservation = library.$savedConnections.sink { [weak self] profiles in
            self?.updatePostgresTypeProfileRevisions(profiles)
        }
        libraryErrorObservation = library.$connectionsError.sink { [weak self] error in
            guard let self, let error else { return }
            let profile = self.library.savedConnections.first { $0.id == self.library.connectionsErrorProfileID }
            self.notifications.post(error, source: "Connections", connection: profile.map(WorkspaceNotification.Connection.init))
        }
        folderObservation = self.sqlFolders.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        folderSaveObservation = self.sqlFolders.$attachments.dropFirst().sink { [weak self] _ in self?.scheduleSave() }
        sqlLibraryObservation = self.sqlLibrary.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        resultSnapshotsObservation = self.resultSnapshots.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        investigationsObservation = self.investigations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.resultSnapshots.investigationReferences = { [weak self] id in
            guard let self else { throw InvestigationReferenceError() }
            return try self.investigations.referencingInvestigations(snapshotID: id)
        }
        sqlLibrarySaveObservation = self.sqlLibrary.$snapshot.dropFirst().sink { [weak self] snapshot in
            self?.bindIndexedSQLViews(snapshot)
            self?.scheduleSave()
        }
    }

    var activePaneID: WorkspacePaneID { paneLayout.activePaneID }

    func paneTitle(_ pane: WorkspacePaneID) -> String {
        "Working pane \((paneLayout.paneIDs.firstIndex(of: pane) ?? 0) + 1)"
    }

    var selectedDocumentID: UUID? {
        get { paneLayout.selectedDocumentID }
        set {
            guard let newValue, let pane = pane(containing: newValue) else { return }
            selectDocument(newValue, in: pane)
        }
    }

    var selectedDocument: SQLDocument? { selectedDocument(in: activePaneID) }

    func documents(in pane: WorkspacePaneID) -> [SQLDocument] {
        let indexed = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return paneLayout[pane].documentIDs.compactMap { indexed[$0] }
    }

    func selectedDocument(in pane: WorkspacePaneID) -> SQLDocument? {
        guard let id = paneLayout[pane].selectedDocumentID else { return nil }
        return documents.first { $0.id == id }
    }

    func pane(containing id: UUID) -> WorkspacePaneID? {
        if let pane = paneLayout.pane(containing: id) { return pane }
        guard let parent = documents.first(where: { parent in
            parent.investigationModel?.allSQLDocuments.contains(where: { $0.id == id }) == true ||
                investigationSnapshotDocuments[parent.investigationID ?? parent.id]?.values.contains(where: { $0.id == id }) == true
        }) else { return nil }
        return paneLayout.pane(containing: parent.id)
    }

    func isSelectedVisibleDocument(_ id: UUID) -> Bool {
        commandDocument(for: id) != nil
    }

    /// Include top-level table sessions as well as SQL tabs and embedded SQL.
    /// Presentation-only investigation and snapshot envelopes have no runtime.
    var allOwnedRuntimeDocuments: [SQLDocument] {
        documents.flatMap { document in
            if let investigation = document.investigationModel { return investigation.allSQLDocuments }
            return document.isInvestigation || document.isSnapshot ? [] : [document]
        }
    }

    var allOwnedSQLDocuments: [SQLDocument] { allOwnedRuntimeDocuments }

    func ownedSQLContext(for document: SQLDocument) -> OwnedSQLContext? {
        for tab in documents {
            guard let pane = paneLayout.pane(containing: tab.id) else { continue }
            if tab === document {
                return OwnedSQLContext(tab: tab, sql: document, investigationID: tab.investigationID,
                    blockID: nil, paneID: pane)
            }
            guard let investigation = tab.investigationModel else { continue }
            if let blockID = investigation.blockID(for: document) {
                return OwnedSQLContext(tab: tab, sql: document, investigationID: investigation.id,
                    blockID: blockID, paneID: pane)
            }
            if let blockID = investigationSnapshotDocuments[investigation.id]?.first(where: { $0.value === document })?.key,
               investigation.blocks.contains(where: { $0.id == blockID && $0.kind == .snapshot && $0.snapshotID == document.snapshotID }) {
                return OwnedSQLContext(tab: tab, sql: document, investigationID: investigation.id,
                    blockID: blockID, paneID: pane)
            }
        }
        return nil
    }

    func ownedDocument(forRuntimeID id: UUID) -> SQLDocument? {
        if let document = documents.first(where: { $0.id == id }) { return document }
        if let document = allOwnedRuntimeDocuments.first(where: { $0.id == id }) { return document }
        return investigationSnapshotDocuments.values.lazy.flatMap { $0.values }.first { document in
            document.id == id && ownedSQLContext(for: document) != nil
        }
    }

    /// An explicit stale child responder never falls back to another block or
    /// the active pane. Background operation ownership uses the resolver above.
    func commandDocument(for id: UUID) -> SQLDocument? {
        guard let source = ownedDocument(forRuntimeID: id), let owner = ownedSQLContext(for: source),
              paneLayout[owner.paneID].selectedDocumentID == owner.tab.id else { return nil }
        guard let investigation = owner.tab.investigationModel else { return source }
        if let blockID = owner.blockID {
            return investigation.selectedBlockID == blockID ? source : nil
        }
        if let sql = investigation.selectedSQLDocument { return sql }
        if let block = investigation.selectedBlock, block.kind == .snapshot {
            return investigationSnapshotDocument(owner.tab, blockID: block.id)
        }
        return owner.tab
    }

    func isInvestigationSQLDocument(_ document: SQLDocument) -> Bool {
        guard let owner = ownedSQLContext(for: document) else { return false }
        return owner.blockID != nil && owner.investigationID != nil && document.isSQLDocument
    }

    func investigationSnapshotDocument(_ parent: SQLDocument, blockID: UUID) -> SQLDocument? {
        guard documents.contains(where: { $0 === parent }), let model = parent.investigationModel,
              let block = model.blocks.first(where: { $0.id == blockID && $0.kind == .snapshot }),
              let snapshotID = block.snapshotID else { return nil }
        if let cached = investigationSnapshotDocuments[model.id]?[blockID], cached.snapshotID == snapshotID { return cached }
        guard let snapshot = model.snapshotModel(for: blockID) else { return nil }
        let document = SQLDocument(title: "Investigation Snapshot", text: "")
        document.attachSnapshot(snapshot)
        investigationSnapshotDocuments[model.id, default: [:]][blockID] = document
        return document
    }

    func investigationSnapshotModel(parent: SQLDocument, blockID: UUID) -> ResultSnapshotDocumentModel? {
        investigationSnapshotDocument(parent, blockID: blockID)?.snapshotModel
    }

    func activatePane(_ pane: WorkspacePaneID) {
        paneActivationRevision &+= 1
        guard paneLayout.activePaneID != pane else { return }
        var layout = paneLayout
        if pane == .left || pane == .right { layout.ensurePane(pane) }
        guard layout.paneIDs.contains(pane) else { return }
        layout.activePaneID = pane
        paneLayout = layout
    }

    func selectDocument(_ id: UUID, in pane: WorkspacePaneID) {
        guard self.pane(containing: id) == pane, documents.contains(where: { $0.id == id }) else { return }
        // An explicit re-selection still represents newer user intent than an
        // asynchronous open or restoration that began before this call.
        paneSelectionRevisions[pane, default: 0] &+= 1
        paneActivationRevision &+= 1
        var layout = paneLayout
        if layout[pane].selectedDocumentID != id {
            layout[pane].selectedDocumentID = id
        }
        layout.activePaneID = pane
        if paneLayout != layout { paneLayout = layout }
    }

    /// Moving a tab preserves its document, runtime and native editor objects.
    func moveDocument(_ id: UUID, to pane: WorkspacePaneID, at index: Int? = nil) {
        guard shutdownTask == nil, let source = self.pane(containing: id),
              documents.contains(where: { $0.id == id }) else { return }
        var layout = paneLayout
        layout.insertDocument(id, in: pane, at: index)
        layout.activePaneID = pane
        guard layout != paneLayout else { return }
        if source != pane { prepareEditorsForPaneMove(id) }
        paneSelectionRevisions[source, default: 0] &+= 1
        if source != pane { paneSelectionRevisions[pane, default: 0] &+= 1 }
        if paneLayout.activePaneID != pane { paneActivationRevision &+= 1 }
        paneLayout = layout
    }

    @discardableResult
    func splitDocument(_ id: UUID, direction: WorkspaceSplitDirection) -> WorkspacePaneID? {
        guard canManageWorkspace, let source = paneLayout.pane(containing: id),
              let origin = documents.first(where: { $0.id == id }) else { return nil }
        var layout = paneLayout
        guard let destination = layout.split(source, direction: direction) else { return nil }
        let document = makeSQLDocument(profileID: origin.profileID)
        documents.append(document)
        observeDocument(document)
        layout.insertDocument(document.id, in: destination)
        layout.activePaneID = destination
        paneSelectionRevisions[source, default: 0] &+= 1
        paneSelectionRevisions[destination, default: 0] &+= 1
        paneActivationRevision &+= 1
        paneSplitRevision &+= 1
        let activationRevision = paneActivationRevision
        let documentID = document.id
        editorState.requestFocus(documentID) { [weak self] in
            guard let self else { return false }
            return self.paneActivationRevision == activationRevision && self.activePaneID == destination &&
                self.selectedDocumentID == documentID
        }
        paneLayout = layout
        return destination
    }

    private func prepareEditorsForPaneMove(_ id: UUID) {
        editorState.prepareForPaneMove(id)
        if let investigation = documents.first(where: { $0.id == id })?.investigationModel {
            for child in investigation.allSQLDocuments { editorState.prepareForPaneMove(child.id) }
        }
    }

    func unsplitPane(_ pane: WorkspacePaneID) {
        guard canManageWorkspace, paneLayout.isSplit else { return }
        var layout = paneLayout
        guard let destination = layout.unsplit(pane) else { return }
        for id in paneLayout[pane].documentIDs { prepareEditorsForPaneMove(id) }
        paneSelectionRevisions[pane, default: 0] &+= 1
        paneSelectionRevisions[destination, default: 0] &+= 1
        paneActivationRevision &+= 1
        paneSplitRevision &+= 1
        paneLayout = layout
    }

    func mergePanes() {
        guard canManageWorkspace, paneLayout.isSplit else { return }
        for pane in paneLayout.paneIDs {
            for id in paneLayout[pane].documentIDs where pane != .left { prepareEditorsForPaneMove(id) }
            paneSelectionRevisions[pane, default: 0] &+= 1
        }
        paneActivationRevision &+= 1
        paneSplitRevision &+= 1
        paneLayout.unsplitAll()
    }

    func setSplitFraction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let clamped = min(max(fraction, WorkspacePaneLayout.splitRange.lowerBound), WorkspacePaneLayout.splitRange.upperBound)
        guard paneLayout.splitFraction != clamped else { return }
        paneSplitRevision &+= 1
        var layout = paneLayout
        layout.splitFraction = clamped
        if let rootID = layout.root.splitIDs.first { layout.setFraction(clamped, for: rootID) }
        paneLayout = layout
    }

    func setSplitFraction(_ fraction: Double, for splitID: UUID) {
        guard fraction.isFinite, paneLayout.root.splitIDs.contains(splitID) else { return }
        let clamped = min(max(fraction, WorkspacePaneLayout.splitRange.lowerBound), WorkspacePaneLayout.splitRange.upperBound)
        var layout = paneLayout
        layout.setFraction(clamped, for: splitID)
        guard layout != paneLayout else { return }
        paneSplitRevision &+= 1
        paneLayout = layout
    }

    struct PaneSelectionContext {
        let pane: WorkspacePaneID
        let selectionRevisions: [WorkspacePaneID: UInt64]
        let activationRevision: UInt64
        let selectedDocumentID: UUID?
    }

    func capturePaneSelection(in pane: WorkspacePaneID? = nil) -> PaneSelectionContext {
        let pane = pane ?? activePaneID
        return PaneSelectionContext(pane: pane, selectionRevisions: paneSelectionRevisions,
            activationRevision: paneActivationRevision, selectedDocumentID: paneLayout[pane].selectedDocumentID)
    }

    private func canSelectAfterOpening(in pane: WorkspacePaneID, context: PaneSelectionContext) -> Bool {
        guard paneLayout.paneIDs.contains(pane) else { return false }
        guard paneSelectionRevisions[pane, default: 0] == context.selectionRevisions[pane, default: 0] else { return false }
        // A newer focus event in the same pane can keep the same tab selected.
        // Preserve that editor rather than replacing it when delayed work ends.
        // An inactive origin pane may still reveal its result without taking
        // focus from the pane the user has since activated.
        return paneActivationRevision == context.activationRevision || (pane == context.pane && activePaneID != pane)
    }

    private func selectAfterOpening(_ document: SQLDocument, context: PaneSelectionContext) {
        guard let pane = pane(containing: document.id), canSelectAfterOpening(in: pane, context: context) else { return }
        var layout = paneLayout
        if layout[pane].selectedDocumentID != document.id {
            paneSelectionRevisions[pane, default: 0] &+= 1
            layout[pane].selectedDocumentID = document.id
        }
        if paneActivationRevision == context.activationRevision {
            if layout.activePaneID != pane { paneActivationRevision &+= 1 }
            layout.activePaneID = pane
        }
        if paneLayout != layout { paneLayout = layout }
    }

    var canManageWorkspace: Bool {
        shutdownTask == nil && !isStarting && documentRestoreTask == nil &&
            !isClosing && !isClearingDocuments && closingDocuments.isEmpty && disconnectingProfiles.isEmpty
    }

    var canReopenClosedTab: Bool { canManageWorkspace && !closedTabs.isEmpty }

    @discardableResult
    func reopenClosedTab() -> SQLDocument? {
        guard canReopenClosedTab, let closed = closedTabs.popLast() else { return nil }
        var state = closed.state
        if state.kind == .investigation, let id = state.investigationID,
           let existing = documents.first(where: { $0.investigationID == id }) {
            selectedDocumentID = existing.id
            return existing
        }
        // Callbacks belonging to the old document must not acquire a new tab
        // with the same identity while this application is still running.
        state.id = UUID()
        let document = restoredDocument(state, knownProfiles: library.savedConnections.map(\.id))
        documents.insert(document, at: min(max(0, closed.originalIndex), documents.count))
        observeDocument(document)
        let pane = paneLayout.paneIDs.contains(closed.paneID) ? closed.paneID : activePaneID
        paneLayout.insertDocument(document.id, in: pane, at: closed.originalPaneIndex)
        paneSelectionRevisions[pane, default: 0] &+= 1
        activatePane(pane)
        scheduleSave()
        return document
    }

    private func reportError(_ message: String?, connection: SavedConnection? = nil) {
        error = message
        if let message { notifications.post(message, connection: connection.map(WorkspaceNotification.Connection.init)) }
    }

    func reportCopyError(_ message: String) { reportError(message) }

    func prepareConnectionEditor(_ id: UUID) async -> SavedConnection? {
        guard library.savedConnections.contains(where: { $0.id == id }),
              await disconnectProfile(id) else { return nil }
        return library.savedConnections.first { $0.id == id }
    }

    func showSchemaComparison() {
        guard schemaComparison == nil else { return }
        let store = credentialStore
        schemaComparison = SchemaComparisonModel(profiles: library.savedConnections, resolve: { profile in
            try await SchemaComparisonCredentials.settings(profile, store: store)
        })
    }

    func dismissSchemaComparison() {
        let model = schemaComparison; schemaComparison = nil
        Task { await model?.close() }
    }

    func start(startupConnection: Result<ConnectionSettings, StartupConnection.InputError>? = nil) async {
        guard !started else { return }
        started = true
        await restoreSavedWorkspace()
        isStarting = true
        defer { isStarting = false }
        if startupConnection == nil, !documents.isEmpty, documents.allSatisfy({ $0.isSnapshot || $0.isInvestigation }) {
            await library.loadConnections()
            return
        }
        do {
            _ = try await ensureHelper()
            if case .success(let settings) = startupConnection {
                let existing = library.savedConnections.first { $0.matches(settings) }
                if await library.saveConnection(name: existing?.name ?? (settings.database.isEmpty ? settings.host : settings.database), settings: settings, id: existing?.id),
                   let id = library.selectedConnectionId { await connectProfile(id) }
            } else if case .failure(let failure) = startupConnection { reportError(failure.localizedDescription) }
            if documents.isEmpty { newDocument(profileID: library.selectedConnectionId) }
        } catch { reportError(error.localizedDescription) }
    }

    @discardableResult
    func newDocument(profileID: UUID? = nil, text: String? = nil, in pane: WorkspacePaneID? = nil) -> SQLDocument {
        addDocument(makeSQLDocument(profileID: profileID ?? library.selectedConnectionId, text: text), in: pane)
    }

    private func makeSQLDocument(profileID: UUID?, text: String? = nil) -> SQLDocument {
        let engine = library.savedConnections.first { $0.id == profileID }?.engine
        let initialText = text ?? (engine == .cassandra ? "SELECT cluster_name, release_version, data_center FROM system.local;" : "SELECT 1;")
        return SQLDocument(title: "SQL \(documents.count + 1)", text: initialText, profileID: profileID)
    }

    @discardableResult
    func newInvestigation(title: String = "Investigation") async -> SQLDocument? {
        guard canManageWorkspace else { return nil }
        let context = capturePaneSelection()
        await investigations.restore()
        guard canManageWorkspace, let model = investigations.create(title: title) else {
            if let message = investigations.error { reportError(message) }
            return nil
        }
        let parent = SQLDocument(title: model.title, text: "")
        parent.attachInvestigation(model)
        addDocument(parent, context: context)
        if !(await investigations.saveInvestigation(model.id)), let message = investigations.error { reportError(message) }
        return parent
    }

    @discardableResult
    func openInvestigation(id: UUID) -> SQLDocument? {
        guard canManageWorkspace else { return nil }
        if let existing = documents.first(where: { $0.investigationID == id }) {
            selectedDocumentID = existing.id
            return existing
        }
        let stored = StoredSQLDocument(id: UUID(), title: "Investigation", text: "", kind: .investigation, investigationID: id)
        return addDocument(restoredDocument(stored, knownProfiles: library.savedConnections.map(\.id)))
    }

    func canEditInvestigation(_ parent: SQLDocument) -> Bool {
        guard parent.isInvestigation, parent.investigationModel?.isAvailable == true,
              canStartOperation(parent) else { return false }
        return parent.investigationModel?.allSQLDocuments.allSatisfy { child in
            !closingDocuments.contains(child.id) && child.profileID.map { !disconnectingProfiles.contains($0) } != false
        } == true
    }

    @discardableResult
    func addInvestigationMarkdown(_ parent: SQLDocument, text: String = "") -> UUID? {
        guard canEditInvestigation(parent) else { return nil }
        return parent.investigationModel?.addMarkdown(text: text)
    }

    @discardableResult
    func addInvestigationSQL(_ parent: SQLDocument, text: String = "SELECT 1;", profileID: UUID? = nil) -> UUID? {
        guard canEditInvestigation(parent) else { return nil }
        return parent.investigationModel?.addSQL(text: text, profileID: profileID)
    }

    @discardableResult
    func addInvestigationSnapshot(_ parent: SQLDocument, snapshotID: UUID, explanation: String = "") -> UUID? {
        guard canEditInvestigation(parent) else { return nil }
        return parent.investigationModel?.addSnapshot(id: snapshotID, explanation: explanation)
    }

    func canBindInvestigationProfile(_ child: SQLDocument) -> Bool {
        guard isInvestigationSQLDocument(child), let owner = ownedSQLContext(for: child), canEditInvestigation(owner.tab),
              !child.isRunning, !child.isNavigatingTable, child.runtime?.sessionId == nil,
              child.runtime?.isConnecting != true, child.runtime?.queryFailure?.outcomeUnknown != true,
              child.grid?.isApplying != true, child.grid?.isPreviewing != true,
              child.grid?.isReloading != true, child.grid?.outcomeUnknown != true else { return false }
        return true
    }

    @discardableResult
    func bindInvestigationProfile(_ child: SQLDocument, profileID: UUID?) -> Bool {
        guard canBindInvestigationProfile(child), let owner = ownedSQLContext(for: child), let blockID = owner.blockID,
              profileID == nil || library.savedConnections.contains(where: { $0.id == profileID }) else { return false }
        owner.tab.investigationModel?.setProfileID(profileID, for: blockID)
        return child.profileID == profileID
    }

    @discardableResult
    func saveInvestigation(_ document: SQLDocument) async -> Bool {
        guard let owner = ownedSQLContext(for: document), owner.tab.isInvestigation,
              canStartOperation(owner.tab), commitNativeEditors(in: [owner.tab] + runtimeDocuments(in: owner.tab)) else { return false }
        return await saveInvestigationContent(owner.tab)
    }

    private func saveInvestigationContent(_ parent: SQLDocument) async -> Bool {
        guard let model = parent.investigationModel, model.isAvailable else {
            reportError(parent.investigationModel?.unavailableReason ?? "This investigation is unavailable. Its saved content has been preserved.")
            return false
        }
        let saved = await investigations.saveInvestigation(model.id)
        if !saved { reportError(investigations.error ?? model.error ?? "The investigation could not be saved. Its draft remains open.") }
        return saved
    }

    private func runtimeDocuments(in tab: SQLDocument) -> [SQLDocument] {
        if let model = tab.investigationModel { return model.allSQLDocuments }
        return tab.isInvestigation || tab.isSnapshot ? [] : [tab]
    }

    private func commitNativeEditors(in affected: [SQLDocument]) -> Bool {
        if let window = presentationWindow, !window.makeFirstResponder(nil) { return false }
        for document in affected { document.grid?.commitEditing?() }
        return true
    }

    @discardableResult
    func openHistoryEntry(_ entry: SQLHistoryEntry) -> SQLDocument {
        let profileID = entry.profileID.flatMap { id in library.savedConnections.contains { $0.id == id } ? id : nil }
        let document = SQLDocument(title: "SQL \(documents.count + 1)", text: entry.sql, profileID: profileID)
        if profileID == nil {
            document.historyConnectionNotice = entry.profileID == nil
                ? "This history entry has no saved connection. Choose a connection above before running this SQL."
                : "The original connection is no longer available. Choose a connection above before running this SQL."
        }
        return addDocument(document)
    }

    @discardableResult
    func openResultSnapshot(id: UUID, title: String = "Result Snapshot") -> SQLDocument? {
        guard canManageWorkspace else { return nil }
        if let existing = documents.first(where: { $0.snapshotID == id }) {
            selectedDocumentID = existing.id
            return existing
        }
        let document = SQLDocument(title: title, text: "")
        document.attachSnapshot(ResultSnapshotDocumentModel(id: id, store: resultSnapshots.store))
        return addDocument(document)
    }

    /// The captured profile is historical information, not authorization to run.
    /// A new SQL draft always requires an explicit connection choice.
    @discardableResult
    func openSnapshotSQLInNewTab(_ source: SQLDocument) -> SQLDocument? {
        guard canStartOperation(source), source.isSnapshot,
              let model = source.snapshotModel, model.isAvailable,
              let manifest = model.manifest else { return nil }
        let document = SQLDocument(title: "SQL from " + source.title, text: manifest.sql)
        document.historyConnectionNotice = manifest.engine == .cassandra
            ? "Choose a connection before running this captured SQL. It starts a new read; the original paging cursor is not encoded."
            : "Choose a connection before running this captured SQL."
        return addDocument(document, in: pane(containing: source.id))
    }

    func snapshotCapture(for document: SQLDocument, resultSetIndex: Int = 0) -> ResultSnapshotCapture? {
        guard canStartOperation(document), !document.isSnapshot, !document.isRunning,
              !document.isNavigatingTable, document.grid?.isApplying != true,
              document.grid?.isReloading != true, document.grid?.isClosing != true else { return nil }
        let source: ResultSnapshotSource?
        if document.table != nil {
            guard document.grid != nil else { return nil }
            source = document.tableSnapshotSource
        } else {
            guard document.executions.indices.contains(document.selectedExecution) else { return nil }
            source = document.executions[document.selectedExecution].snapshotSource
        }
        return source?.capture(title: document.title, resultSetIndex: resultSetIndex)
    }

    @discardableResult
    func pinResult(_ document: SQLDocument, resultSetIndex: Int = 0) async -> ResultSnapshotSummary? {
        guard let capture = snapshotCapture(for: document, resultSetIndex: resultSetIndex) else { return nil }
        let saved = await resultSnapshots.save(capture)
        if let saved {
            notifications.post("Result snapshot saved. Open it from Result Snapshots.", source: "Result Snapshots")
            return saved
        }
        if let error = resultSnapshots.error { reportError(error) }
        return nil
    }

    @discardableResult
    func addDocument(_ document: SQLDocument, in requestedPane: WorkspacePaneID? = nil,
                             context: PaneSelectionContext? = nil) -> SQLDocument {
        let requested = context?.pane ?? requestedPane ?? activePaneID
        let pane = context != nil && !paneLayout.paneIDs.contains(requested) ? activePaneID : requested
        documents.append(document)
        observeDocument(document)
        let shouldSelect = context.map { canSelectAfterOpening(in: pane, context: $0) } ?? true
        var layout = paneLayout
        layout.insertDocument(document.id, in: pane, select: shouldSelect)
        if shouldSelect && (context.map { paneActivationRevision == $0.activationRevision } ?? true) {
            if layout.activePaneID != pane { paneActivationRevision &+= 1 }
            layout.activePaneID = pane
        }
        if layout[pane].selectedDocumentID != paneLayout[pane].selectedDocumentID {
            paneSelectionRevisions[pane, default: 0] &+= 1
        }
        paneLayout = layout
        scheduleSave()
        return document
    }

    func connectProfile(_ id: UUID, sshSnapshot: SSHSettings? = nil) async {
        guard shutdownTask == nil, !isClosing, !disconnectingProfiles.contains(id) else { return }
        if let connection = profileConnections[id] { await connection.value; return }
        let task = Task { @MainActor in await self.openProfile(id, sshSnapshot: sshSnapshot) }
        profileConnections[id] = task
        await task.value
        profileConnections[id] = nil
    }

    private func openProfile(_ id: UUID, sshSnapshot: SSHSettings?) async {
        let profile = library.savedConnections.first { $0.id == id }
        do {
            let client = try await ensureHelper()
            if let service = services[id], service.connectionState == .connected { return }
            let service = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
            services[id] = service
            observePostgresTypeSession(service, profileID: id)
            observations[id] = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            await service.start(sharedHelper: client)
            await service.connectSavedConnection(id, sshSnapshot: sshSnapshot)
            if service.connectionState != .connected {
                reportError(service.errorMessage ?? service.connectionsError, connection: profile)
            } else {
                error = nil
                Task { @MainActor [weak self] in await self?.loadCompletionCatalog(id) }
            }
        } catch { reportError(error.localizedDescription, connection: profile) }
    }

    @discardableResult func disconnectProfile(_ id: UUID) async -> Bool {
        // A profile's working and service sessions close together. Other
        // profiles keep their connections and in-flight queries.
        guard !isClosing, !allOwnedRuntimeDocuments.contains(where: {
            $0.profileID == id && (closingDocuments.contains($0.id) ||
                ownedSQLContext(for: $0).map { closingDocuments.contains($0.tab.id) } == true || $0.isNavigatingTable)
        }),
              disconnectingProfiles.insert(id).inserted else { return false }
        let affected = allOwnedRuntimeDocuments.filter { $0.profileID == id }
        invalidatePostgresTypeInspection(profileID: id, reason: "The connection is disconnecting. Reopen this type after connecting again.")
        guard commitNativeEditors(in: affected) else { disconnectingProfiles.remove(id); return false }
        let grids = affected.compactMap(\.grid)
        for grid in grids { grid.isClosing = true }
        defer {
            disconnectingProfiles.remove(id)
            for grid in grids { grid.isClosing = false }
        }
        guard await prepareToClose(.profile(id)) else { return false }
        if let connecting = profileConnections[id] {
            services[id]?.cancelConnection()
            connecting.cancel()
            await connecting.value
        }
        guard await disconnectRuntimeDocuments(affected) else { return false }
        if let service = services[id], service.sessionId != nil {
            await service.disconnect()
            guard service.sessionId == nil else {
                reportError(service.errorMessage ?? "The profile's service session could not be closed. Try disconnecting again.")
                return false
            }
        }
        for document in affected { await document.runtime?.shutdown() }
        if let service = services.removeValue(forKey: id) { await service.shutdown() }
        if clusterInspection?.profileID == id { clusterInspection = nil }
        completionLoads.removeValue(forKey: id)?.task.cancel()
        observations[id] = nil
        typeSessionObservations[id] = nil
        typeServiceGenerations[id] = nil
        catalogRoots[id] = nil
        completionCatalog.remove(profileID: id)
        catalogErrors[id] = nil
        for document in affected {
            document.runtime = nil
            document.attachGrid(nil)
        }
        return true
    }

    func closeDocument(_ document: SQLDocument) async {
        guard let owner = ownedSQLContext(for: document), canStartOperation(owner.tab) else { return }
        let parent = owner.tab
        let affected = runtimeDocuments(in: parent)
        let ids = Set(([parent] + affected).map(\.id))
        guard closingDocuments.isDisjoint(with: ids) else { return }
        closingDocuments.formUnion(ids)
        let grids = affected.compactMap(\.grid)
        guard commitNativeEditors(in: [parent] + affected) else { closingDocuments.subtract(ids); return }
        for grid in grids { grid.isClosing = true }
        defer {
            closingDocuments.subtract(ids)
            for grid in grids { grid.isClosing = false }
        }
        guard await prepareToClose(.document(parent.id)) else { return }
        if parent.investigationModel?.isAvailable == true {
            guard await saveInvestigationContent(parent) else { return }
        }
        guard await disconnectRuntimeDocuments(affected) else { return }
        await closeDocumentImmediately(parent, remember: true)
    }

    func canStartOperation(_ document: SQLDocument, forClosing: Bool = false, forNavigating: Bool = false) -> Bool {
        guard shutdownTask == nil, let owner = ownedSQLContext(for: document) else { return false }
        if forClosing { return true }
        if document === owner.tab, let model = owner.tab.investigationModel,
           model.allSQLDocuments.contains(where: {
               closingDocuments.contains($0.id) || $0.profileID.map { disconnectingProfiles.contains($0) } == true
           }) { return false }
        return !isClosing && (!document.isNavigatingTable || forNavigating) &&
            !closingDocuments.contains(owner.tab.id) && !closingDocuments.contains(document.id) &&
            document.profileID.map { !disconnectingProfiles.contains($0) } != false
    }

    private func disconnectRuntimeDocuments(_ affected: [SQLDocument]) async -> Bool {
        for document in affected {
            guard ownedSQLContext(for: document) != nil else { return false }
            if let runtime = document.runtime, runtime.sessionId != nil {
                await runtime.disconnect()
                guard runtime.sessionId == nil else {
                    document.localError = runtime.errorMessage ?? "The session could not be closed. Try closing it again."
                    return false
                }
            }
        }
        return true
    }

    @discardableResult
    func deleteInvestigationBlock(_ parent: SQLDocument, blockID: UUID) async -> Bool {
        guard canEditInvestigation(parent), let model = parent.investigationModel,
              model.blocks.contains(where: { $0.id == blockID }) else { return false }
        let child = model.sqlDocument(for: blockID)
        let affected = child.map { [$0] } ?? []
        let ids = Set(([parent] + affected).map(\.id))
        guard closingDocuments.isDisjoint(with: ids) else { return false }
        closingDocuments.formUnion(ids)
        let grid = child?.grid
        guard commitNativeEditors(in: [parent] + affected) else { closingDocuments.subtract(ids); return false }
        grid?.isClosing = true
        defer { closingDocuments.subtract(ids); grid?.isClosing = false }
        guard await prepareToClose(affected), await disconnectRuntimeDocuments(affected) else { return false }
        grid?.isClosing = false
        guard await investigations.saveRemovingBlock(in: model.id, blockID: blockID) else {
            reportError(investigations.error ?? model.error ?? "The block could not be removed. Its saved content and draft remain available.")
            return false
        }
        if let child {
            await child.runtime?.shutdown()
            editorState.removeDocument(child.id)
        }
        if let snapshot = investigationSnapshotDocuments[model.id]?.removeValue(forKey: blockID) {
            editorState.removeDocument(snapshot.id)
        }
        return true
    }

    @discardableResult
    func disconnectInvestigationBlock(_ child: SQLDocument) async -> Bool {
        guard isInvestigationSQLDocument(child), canStartOperation(child),
              let owner = ownedSQLContext(for: child) else { return false }
        let ids: Set<UUID> = [owner.tab.id, child.id]
        guard closingDocuments.isDisjoint(with: ids) else { return false }
        closingDocuments.formUnion(ids)
        let grid = child.grid
        guard commitNativeEditors(in: [owner.tab, child]) else { closingDocuments.subtract(ids); return false }
        grid?.isClosing = true
        defer { closingDocuments.subtract(ids); grid?.isClosing = false }
        guard await prepareToClose([child]), await disconnectRuntimeDocuments([child]) else { return false }
        await child.runtime?.shutdown()
        child.runtime = nil
        child.attachGrid(nil)
        return true
    }

    @discardableResult
    private func closeDocumentImmediately(_ document: SQLDocument, remember: Bool = false) async -> Bool {
        let runtimeDocuments = runtimeDocuments(in: document)
        for child in runtimeDocuments {
            await child.runtime?.shutdown()
            child.runtime = nil
            child.attachGrid(nil)
        }
        if let model = document.investigationModel, model.isAvailable {
            if model.isDirty { guard await saveInvestigationContent(document) else { return false } }
            guard investigations.releaseDocument(model.id) else {
                reportError("The investigation changed while closing. Save it and try closing again.")
                return false
            }
        }
        guard shutdownTask == nil, let index = documents.firstIndex(where: { $0 === document }) else { return false }
        let pane = self.pane(containing: document.id) ?? .left
        let paneIndex = paneLayout[pane].documentIDs.firstIndex(of: document.id) ?? 0
        let closed = remember ? ClosedWorkspaceTab(state: document.storedState, originalIndex: index,
            paneID: pane, originalPaneIndex: paneIndex) : nil
        documents.remove(at: index)
        var layout = paneLayout
        let removesPane = layout.isSplit && layout[pane].documentIDs.count == 1
        // Freeze inferred legacy splits before removing their last right tab.
        if removesPane { layout.tree = layout.root }
        layout.removeDocument(document.id)
        if removesPane, let destination = layout.unsplit(pane) {
            paneSelectionRevisions[destination, default: 0] &+= 1
            paneSplitRevision &+= 1
        }
        if layout.activePaneID != activePaneID { paneActivationRevision &+= 1 }
        paneSelectionRevisions[pane, default: 0] &+= 1
        paneLayout = layout
        document.detachFileDocument()
        pruneFileDocuments()
        documentObservations[document.id] = nil
        editorState.removeDocument(document.id)
        for child in runtimeDocuments { editorState.removeDocument(child.id) }
        if let id = document.investigationID {
            if let snapshots = investigationSnapshotDocuments.removeValue(forKey: id) {
                for child in snapshots.values { editorState.removeDocument(child.id) }
            }
        }
        if let closed {
            closedTabs.append(closed)
            if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        }
        scheduleSave()
        return true
    }

    func run(_ document: SQLDocument, sql: String? = nil) async {
        guard canStartOperation(document), !document.isSnapshot, !document.isInvestigation else { return }
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
        guard document.isSQLDocument else { return nil }
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
                         isScript: Bool = false, sourceSQL: String? = nil, forNavigating: Bool = false) async {
        guard canStartOperation(document, forNavigating: forNavigating), !document.isRunning else { return }
        guard !document.isSnapshot, !document.isInvestigation else { return }
        if let notice = sqlLibraryExecutionNotice(for: document) { document.localError = notice; return }
        guard let profileID = document.profileID else { return }
        guard document.table != nil || !statements.isEmpty else { return }
        guard let profile = library.savedConnections.first(where: { $0.id == profileID }) else { return }
        let libraryBinding = sqlLibraryExecutionBinding(document)
        let boundText = document.text
        if !forNavigating { document.tableNavigationError = nil }
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
            if export?.destination != nil, !(await client.supportsCapturedExport()) {
                throw ExecutionPolicyError(message: "The helper does not support captured full export. SQL was not executed.")
            }
            guard canStartOperation(document, forNavigating: forNavigating), !document.stopRequested, SQLFileDocument.sameBytes(document.text, boundText),
                  document.profileID == profileID,
                  hasSQLLibraryExecutionBinding(document, libraryBinding),
                  library.savedConnections.first(where: { $0.id == profileID }) == profile else {
                throw ExecutionPolicyError(message: "The SQL or connection context changed before execution. Review it and run again.")
            }
            if services[profileID]?.connectionState != .connected { await connectProfile(profileID) }
            guard canStartOperation(document, forNavigating: forNavigating), !document.stopRequested,
                  document.profileID == profileID, SQLFileDocument.sameBytes(document.text, boundText),
                  library.savedConnections.first(where: { $0.id == profileID }) == profile,
                  services[profileID]?.connectionState == .connected else { return }
            guard hasSQLLibraryExecutionBinding(document, libraryBinding) else {
                throw ExecutionPolicyError(message: "The SQL library scope changed while connecting. Review the file and connection before running again.")
            }
            if document.runtime?.connectionState != .connected {
                let runtime = WorkspaceModel(connectionStore: connectionStore, credentialStore: credentialStore)
                document.attach(runtime, preserveTablePage: document.table != nil)
                await runtime.start(sharedHelper: client)
                await runtime.connectSavedConnection(profileID, sshSnapshot: services[profileID]?.ssh)
            }
            guard let runtime = document.runtime else { return }
            guard canStartOperation(document, forNavigating: forNavigating), !document.stopRequested,
                  SQLFileDocument.sameBytes(document.text, boundText), document.profileID == profileID,
                  hasSQLLibraryExecutionBinding(document, libraryBinding),
                  library.savedConnections.first(where: { $0.id == profileID }) == profile else {
                throw ExecutionPolicyError(message: "The SQL or connection context changed while connecting. Review it and run again.")
            }
            guard runtime.connectionState == .connected else {
                document.localError = runtime.errorMessage ?? runtime.connectionsError ?? "The working session could not be opened."
                for index in document.executions.indices { document.executions[index].status = "Not executed" }
                return
            }
            guard runtime.activeConnectionId == profileID, runtime.policy == profile.policy,
                  runtime.engine == profile.engine, runtime.host == profile.host,
                  Int(runtime.port) == profile.port, runtime.database == profile.database,
                  runtime.contactPoints == profile.contactPoints, runtime.localDatacenter == profile.localDatacenter,
                  runtime.consistency == profile.consistency, runtime.ssh?.configuration == profile.ssh,
                  runtime.user == profile.user, runtime.sslMode == profile.sslMode,
                  (runtime.sslRootCert.isEmpty ? nil : runtime.sslRootCert) == profile.sslRootCert else {
                throw ExecutionPolicyError(message: "The profile changed. Disconnect and reconnect before loading data or executing SQL.")
            }
            runtime.sql = document.text
            if let table = document.table {
                if runtime.usesCursorPagination, document.tableCursor == nil {
                    // Server cursors belong to a physical session. Offset-based
                    // engines retain their saved page; cursor engines start over.
                    document.page = 0
                    document.tableNextCursor = nil
                }
                let metadata: [[String: String]]
                do {
                    let structure = try await catalog(CatalogRequest(kind: "columns", schema: table.schema,
                        object: table.name, objectKind: table.kind), profileID: profileID)
                    metadata = structure.catalogRecords
                } catch {
                    document.localError = error.localizedDescription
                    return
                }
                guard canStartOperation(document, forNavigating: forNavigating), !document.stopRequested else { return }
                let historyProfile = SQLHistoryProfile(profile, currentKeyspace: runtime.currentKeyspace)
                let completion = await runtime.run(catalog: CatalogRequest(kind: "browse", schema: table.schema,
                    object: table.name, objectKind: table.kind, page: runtime.usesCursorPagination ? 0 : document.page,
                    cursor: runtime.usesCursorPagination ? document.tableCursor : nil, sort: document.tableSort, filters: document.tableFilters))
                if runtime.queryFailure == nil, let result = runtime.result {
                    document.tableFailure = nil
                    document.tableResult = result
                    document.tableSnapshotSource = completion.flatMap { completion in
                        completion.reply?.sql.flatMap { sql in
                            ResultSnapshotSource(sql: sql, profileID: profileID, profile: historyProfile,
                                completion: completion, isTablePage: true)
                        }
                    }
                    document.tableColumns = metadata
                    document.tableNextCursor = result.nextCursor
                    let grid = GridDraft(reference: table, result: result, metadata: metadata)
                    grid.policyReadOnly = runtime.policy.readOnly
                    grid.supportsEditing = runtime.supportsGridEditing
                    document.attachGrid(grid)
                    document.tableNeedsExplicitLoad = false
                    await loadForeignKeys(document, forNavigating: forNavigating)
                } else {
                    document.tableFailure = runtime.queryFailure
                    if runtime.queryFailure?.category == "cursor" { document.resetTablePaging() }
                }
            } else {
                guard let sessionID = runtime.sessionId else { return }
                let operations = statements.map { OperationRequest(type: "execute", sql: $0.sql, export: export) }
                guard let authorization = try await authorizeOperations(operations, sessionID: sessionID,
                    profile: profile, client: client, isScript: isScript || statements.count > 1,
                    sourceSQL: isScript || statements.count > 1 ? (sourceSQL ?? statements.map(\.sql).joined(separator: ";\n")) : nil),
                    canStartOperation(document), !document.stopRequested,
                    document.profileID == profileID, document.runtime === runtime,
                    hasSQLLibraryExecutionBinding(document, libraryBinding),
                    runtime.sessionId == sessionID, runtime.policy == profile.policy,
                    library.savedConnections.first(where: { $0.id == profileID }) == profile,
                    SQLFileDocument.sameBytes(document.text, boundText) else {
                    if !hasSQLLibraryExecutionBinding(document, libraryBinding) {
                        document.localError = "The SQL library scope or connection group changed. Review it before running again."
                    }
                    _ = try? await client.request(.cancel(sessionId: sessionID, queryId: UUID().uuidString))
                    for index in document.executions.indices { document.executions[index].status = "Not executed" }
                    return
                }
                for (index, statement) in statements.enumerated() {
                    guard canStartOperation(document), !document.stopRequested, SQLFileDocument.sameBytes(document.text, boundText),
                          document.profileID == profileID, runtime.sessionId == sessionID,
                          hasSQLLibraryExecutionBinding(document, libraryBinding),
                          library.savedConnections.first(where: { $0.id == profileID }) == profile else { break }
                    document.selectedExecution = index
                    document.executions[index].status = "Running"
                    let historyProfile = SQLHistoryProfile(profile, currentKeyspace: runtime.currentKeyspace)
                    let completion = await runtime.run(sql: statement.sql, export: export, authorization: authorization)
                    document.executions[index].result = runtime.result
                    document.executions[index].failure = runtime.queryFailure
                    document.executions[index].snapshotSource = completion.flatMap {
                        ResultSnapshotSource(sql: statement.sql, profileID: profileID, profile: historyProfile, completion: $0)
                    }
                    document.executions[index].status = runtime.queryFailure?.title ?? (runtime.result == nil ? "Failed" : "Completed")
                    if runtime.queryFailure?.outcomeUnknown == true { document.executions[index].status = "Unknown outcome" }
                    if runtime.queryFailure == nil, let result = runtime.result, result.outcomeUnknown != true {
                        document.recordExecutionSuccess(statement, revision: executionRevision)
                    }
                    if let completion, let entry = SQLHistoryEntry(documentID: document.id, profileID: profileID,
                        profile: historyProfile, sql: statement.sql, completion: completion) {
                        recordHistory(entry)
                    }
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
                if !hasSQLLibraryExecutionBinding(document, libraryBinding) {
                    document.localError = "The SQL library scope or connection group changed. Remaining statements were not executed."
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
        guard ownedSQLContext(for: document) != nil else { return }
        if document.grid?.isApplying == true { await stopGridApply(document); return }
        document.stopRequested = true
        if document.runtime?.isConnecting == true { document.runtime?.cancelConnection() }
        await document.runtime?.stop()
    }

    func flushDocuments() async {
        _ = await persistDocuments()
    }

    private func persistDocuments() async -> Bool {
        autosave?.cancel()
        autosave = nil
        guard draftsLoaded else { return false }
        let captured = snapshot()
        let previous = documentSaveTask
        let saveID = UUID()
        documentSaveID = saveID
        let task = Task { @MainActor [self] in
            if let previous { _ = await previous.value }
            do {
                try await documentStore.save(captured)
                if documentSaveID == saveID {
                    historyError = nil
                    if let documentSaveError, self.error == documentSaveError { self.error = nil }
                    documentSaveError = nil
                }
                return true
            } catch {
                if documentSaveID == saveID {
                    let message = error.localizedDescription
                    self.reportError(message)
                    documentSaveError = message
                    historyError = "Workspace and history changes remain in memory but could not be saved. Try saving again before closing the application."
                }
                return false
            }
        }
        documentSaveTask = task
        let saved = await task.value
        if documentSaveID == saveID { documentSaveTask = nil }
        return saved
    }

    @discardableResult
    func updateHistorySettings(_ settings: SQLHistoryRetentionSettings) async -> Bool {
        guard canManageHistory() else { return false }
        guard settings.isValid else {
            historyError = "Enter a history limit from 1 to 100,000 and a retention period from 1 to 3,650 days."
            return false
        }
        historySettings = settings
        trimHistory()
        return await persistDocuments()
    }

    func setHistoryFavorite(_ id: UUID, isFavorite: Bool) async {
        guard canManageHistory(), let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].isFavorite = isFavorite
        trimHistory()
        await flushDocuments()
    }

    func deleteHistoryEntry(_ id: UUID, includeFavorite: Bool = false) async {
        guard canManageHistory() else { return }
        history.removeAll { $0.id == id && (includeFavorite || !$0.isFavorite) }
        await flushDocuments()
    }

    func clearHistory(entryIDs: Set<UUID>, includeFavorites: Bool) async {
        guard canManageHistory() else { return }
        history.removeAll { entryIDs.contains($0.id) && (includeFavorites || !$0.isFavorite) }
        await flushDocuments()
    }

    func clearHistory() async {
        await clearHistory(entryIDs: Set(history.map(\.id)), includeFavorites: false)
    }

    private func trimHistory() {
        var saved = snapshot()
        saved.trimHistory()
        history = saved.history
    }

    private func canManageHistory() -> Bool {
        guard draftsLoaded else {
            historyError = "SQL drafts and history must be loaded successfully before changing history."
            return false
        }
        return true
    }

    func clearRestoredDocuments() async {
        guard !isClosing, !isClearingDocuments, closingDocuments.isEmpty, disconnectingProfiles.isEmpty,
              !allOwnedRuntimeDocuments.contains(where: \.isNavigatingTable) else { return }
        isClearingDocuments = true
        defer { isClearingDocuments = false }
        let previousClosedIDs = Set(closedTabs.map(\.id))
        let affected = documents
        let runtimeDocuments = allOwnedRuntimeDocuments
        let ids = Set((affected + runtimeDocuments).map(\.id))
        guard closingDocuments.isDisjoint(with: ids) else { return }
        closingDocuments.formUnion(ids)
        let grids = runtimeDocuments.compactMap(\.grid)
        guard commitNativeEditors(in: affected + runtimeDocuments) else { closingDocuments.subtract(ids); return }
        for grid in grids { grid.isClosing = true }
        defer {
            closingDocuments.subtract(ids)
            for grid in grids { grid.isClosing = false }
        }
        guard await prepareToClose(.application) else { return }
        guard await disconnectRuntimeDocuments(runtimeDocuments) else { return }
        for document in affected { guard await closeDocumentImmediately(document) else { return } }
        if draftsLoaded { guard await persistDocuments() else { return } }
        closedTabs.removeAll { previousClosedIDs.contains($0.id) }
    }

    func prepareToClose(_ scope: WorkspaceCloseScope) async -> Bool {
        let affected: [SQLDocument]
        switch scope {
        case .document(let id):
            if let tab = documents.first(where: { $0.id == id }) { affected = runtimeDocuments(in: tab) }
            else if let child = ownedDocument(forRuntimeID: id) { affected = [child] }
            else { return false }
        case .profile(let id): affected = allOwnedRuntimeDocuments.filter { $0.profileID == id }
        case .application:
            guard closingDocuments.isEmpty || isClearingDocuments else { return false }
            affected = allOwnedRuntimeDocuments
        }
        guard await prepareToClose(affected) else { return false }
        if case .application = scope {
            isClosing = true
            defer { isClosing = false }
            guard commitNativeEditors(in: documents + affected) else { return false }
            if investigations.isLoaded, !(await investigations.flush()) {
                reportError(investigations.error ?? "The investigations could not be saved. Their drafts remain open.")
                return false
            }
            if draftsLoaded { guard await persistDocuments() else { return false } }
        }
        return true
    }

    private func prepareToClose(_ affected: [SQLDocument]) async -> Bool {
        guard !isClosing else { return false }
        guard !affected.contains(where: \.isNavigatingTable) else { return false }
        guard commitNativeEditors(in: affected) else { return false }
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
            guard ownedSQLContext(for: document) != nil else { return false }
            if document.runtime?.queryFailure?.outcomeUnknown == true {
                document.localError = "The SQL outcome is unknown. Review the database outcome before closing this session. The document remains open."
                return false
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
        let confirmed = documents.filter { !$0.isProvisionalTableView }
        let states = confirmed.map { $0.tableNavigationSourceState ?? $0.storedState }
        let knownIDs = Set(states.map(\.id))
        var layout = paneLayout
        for pane in layout.storedPaneIDs {
            var state = layout[pane]
            state.documentIDs = state.documentIDs.filter { knownIDs.contains($0) }
            if let selected = selectedDocument(in: pane), selected.isProvisionalTableView,
               let previous = selected.provisionalPreviousSelection, state.documentIDs.contains(previous) {
                state.selectedDocumentID = previous
            }
            if state.selectedDocumentID.map(state.documentIDs.contains) != true {
                state.selectedDocumentID = state.documentIDs.first
            }
            layout[pane] = state
        }
        return SQLWorkspaceSnapshot(documents: states,
            selectedDocumentID: layout.selectedDocumentID,
            history: history, historyEnabled: historyEnabled, historySettings: historySettings,
            sqlFolders: sqlFolders.attachments, sqlLibrary: sqlLibrary.snapshot, paneLayout: layout)
    }

    /// Loads local workspace state without launching a helper, requesting
    /// credentials, connecting, browsing a table or executing user SQL.
    func restoreSavedWorkspace() async {
        guard !draftsLoaded, shutdownTask == nil else { return }
        if let documentRestoreTask { await documentRestoreTask.value; return }
        let task = Task { @MainActor [self] in await loadSavedWorkspace() }
        documentRestoreTask = task
        await task.value
        documentRestoreTask = nil
    }

    private func loadSavedWorkspace() async {
        await investigations.restore()
        do {
            let saved = try await documentStore.load()
            let knownProfiles = try? await connectionStore.load().connections.map(\.id)
            guard shutdownTask == nil else { return }
            let localDocuments = documents
            let localLayout = paneLayout
            history = saved.history
            historySettings = saved.historySettings
            historyEnabled = saved.historyEnabled
            let localLibrary = sqlLibrary.snapshot
            let mergedLibrary = SQLLibrarySnapshot(
                entries: saved.sqlLibrary.entries + localLibrary.entries.filter { !saved.sqlLibrary.entries.contains($0) },
                groups: saved.sqlLibrary.groups + localLibrary.groups.filter { !saved.sqlLibrary.groups.contains($0) })
            guard mergedLibrary.isValid else { throw SQLDocumentStoreError.read }
            // Folder restoration creates local tree roots only. Enumeration
            // and file reconciliation run separately from database startup.
            let attached = sqlFolders.attachments
            guard sqlFolders.restore(saved.sqlFolders + attached.filter { local in
                !saved.sqlFolders.contains { $0.id == local.id || $0.url == local.url }
            }) else { throw SQLDocumentStoreError.read }
            guard sqlLibrary.restore(mergedLibrary) else { throw SQLDocumentStoreError.read }
            let localIDs = Set(localDocuments.map(\.id))
            var investigationIDs = Set(localDocuments.compactMap(\.investigationID))
            let restored = saved.documents.filter { stored in
                guard !localIDs.contains(stored.id) else { return false }
                if let id = stored.investigationID { return investigationIDs.insert(id).inserted }
                return true
            }.map { stored in
                restoredDocument(stored, knownProfiles: knownProfiles)
            }
            documents = restored + localDocuments
            for document in documents { observeDocument(document) }
            var layout = paneSplitRevision > 0 ? localLayout : saved.paneLayout
            for pane in saved.paneLayout.paneIDs + localLayout.paneIDs where !layout.paneIDs.contains(pane) {
                layout.ensurePane(pane)
            }
            for pane in layout.storedPaneIDs {
                var state = saved.paneLayout[pane]
                let restoredIDs = Set(restored.map(\.id))
                state.documentIDs.removeAll { localIDs.contains($0) || !restoredIDs.contains($0) }
                state.documentIDs += localLayout[pane].documentIDs
                let localSelection = localLayout[pane].selectedDocumentID
                if let localSelection, state.documentIDs.contains(localSelection) {
                    state.selectedDocumentID = localSelection
                } else if state.selectedDocumentID.map(state.documentIDs.contains) != true {
                    state.selectedDocumentID = state.documentIDs.first
                }
                layout[pane] = state
            }
            if paneActivationRevision > 0 || !localDocuments.isEmpty { layout.activePaneID = localLayout.activePaneID }
            if paneSplitRevision > 0 { layout.splitFraction = localLayout.splitFraction }
            paneLayout = layout
            draftsLoaded = true
            if !localDocuments.isEmpty || !attached.isEmpty || localLibrary != SQLLibrarySnapshot() ||
                documents.map(\.storedState) != saved.documents || layout != saved.paneLayout {
                scheduleSave()
            }
        } catch { reportError(error.localizedDescription) }
    }

    private func restoredDocument(_ stored: StoredSQLDocument, knownProfiles: [UUID]?) -> SQLDocument {
        let document = SQLDocument(restoring: stored)
        if document.isInvestigation {
            if let id = document.investigationID {
                do { document.attachInvestigation(try investigations.openDocument(id: id)) }
                catch {
                    document.attachInvestigation(InvestigationDocumentModel(unavailableID: id, title: stored.title,
                        reason: error.localizedDescription))
                }
                for child in document.investigationModel?.allSQLDocuments ?? [] {
                    if child.profileID == nil {
                        child.historyConnectionNotice = "This SQL block is unbound. Choose a connection before running it."
                    } else if let knownProfiles, !knownProfiles.contains(child.profileID!) {
                        child.historyConnectionNotice = "This SQL block's original connection is no longer available. Choose a connection before running it."
                    }
                }
            }
            return document
        }
        if document.isSnapshot {
            if let snapshotID = document.snapshotID {
                document.attachSnapshot(ResultSnapshotDocumentModel(id: snapshotID, store: resultSnapshots.store))
            }
            return document
        }
        restoreFileDocument(document)
        bindIndexedSQLView(document)
        if document.profileID == nil {
            document.historyConnectionNotice = "This restored tab has no saved connection. Choose a connection before loading data or running SQL."
        } else if let knownProfiles, !knownProfiles.contains(document.profileID!) {
            document.historyConnectionNotice = "The original connection is no longer available. Choose a connection before loading data or running SQL."
        }
        return document
    }

    private func observeDocument(_ document: SQLDocument) {
        document.fileDidMove = { [weak self, weak document] oldURL, newURL in
            guard let self, let document, self.documents.contains(where: { $0 === document }),
                  let id = document.sqlLibraryEntryID, let entry = self.sqlLibrary.entry(id: id),
                  entry.fileURL == oldURL else { return }
            do {
                _ = try self.sqlLibrary.upsertEntry(id: id, fileURL: newURL, folder: entry.folder,
                    tags: entry.tags, scope: entry.scope)
            } catch { self.reportError(error.localizedDescription) }
        }
        documentObservations[document.id] = [
            document.$text.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$title.dropFirst().sink { [weak self, weak document] title in
                document?.updateInvestigationTitle(title)
                self?.scheduleSave()
            },
            document.$profileID.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$table.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$page.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$tableFilters.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$tableSort.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$fileURL.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$sqlLibraryEntryID.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$fileContentSHA256.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.$fileRecoveryURL.dropFirst().sink { [weak self] _ in self?.scheduleSave() },
            document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    func openSQLFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await openSQLFile(at: url) }
        }
    }

    func selectedSQLLibraryEntry(for document: SQLDocument) -> SQLLibraryEntry? {
        if let id = document.sqlLibraryEntryID { return sqlLibrary.entry(id: id) }
        return document.fileURL.flatMap { sqlLibrary.entry(at: $0) }
    }

    func availableSQLLibraryProfiles(for document: SQLDocument) -> [SavedConnection] {
        guard isSQLLibraryView(document) else { return library.savedConnections }
        guard let entry = selectedSQLLibraryEntry(for: document), entry.fileURL == document.fileURL else { return [] }
        return library.savedConnections.filter { sqlLibrary.allows(entry: entry, profileID: $0.id) }
    }

    func sqlLibraryExecutionNotice(for document: SQLDocument) -> String? {
        guard isSQLLibraryView(document) else { return nil }
        guard let entry = selectedSQLLibraryEntry(for: document), entry.fileURL == document.fileURL else {
            return "This SQL library entry is no longer available at this path. Restore its library reference or open a separate SQL file view."
        }
        guard let profileID = document.profileID,
              library.savedConnections.contains(where: { $0.id == profileID }) else {
            return "Choose a specific connection and review its environment before running shared SQL."
        }
        guard sqlLibrary.allows(entry: entry, profileID: profileID) else {
            return "This connection is outside the SQL file's current library scope. Choose an available connection; a missing group or profile remains unavailable."
        }
        return nil
    }

    private func isSQLLibraryView(_ document: SQLDocument) -> Bool {
        document.table == nil && (document.sqlLibraryEntryID != nil ||
            document.fileURL.flatMap { sqlLibrary.entry(at: $0) } != nil)
    }

    private struct SQLLibraryExecutionBinding: Equatable {
        let entryID: UUID
        let fileURL: URL
        let scope: SQLLibraryScope
        let group: SQLProfileGroup?
    }

    private func sqlLibraryExecutionBinding(_ document: SQLDocument) -> SQLLibraryExecutionBinding? {
        guard let entry = selectedSQLLibraryEntry(for: document) else { return nil }
        let group: SQLProfileGroup?
        if case .group(let id) = entry.scope { group = sqlLibrary.snapshot.groups.first { $0.id == id } }
        else { group = nil }
        return SQLLibraryExecutionBinding(entryID: entry.id, fileURL: entry.fileURL, scope: entry.scope, group: group)
    }

    private func hasSQLLibraryExecutionBinding(_ document: SQLDocument, _ expected: SQLLibraryExecutionBinding?) -> Bool {
        sqlLibraryExecutionNotice(for: document) == nil && sqlLibraryExecutionBinding(document) == expected
    }

    private func bindIndexedSQLView(_ document: SQLDocument, snapshot: SQLLibrarySnapshot? = nil) {
        guard document.table == nil, document.sqlLibraryEntryID == nil, let url = document.fileURL,
              let entry = (snapshot ?? sqlLibrary.snapshot).entries.first(where: { $0.fileURL == url }) else { return }
        document.sqlLibraryEntryID = entry.id
        // Indexing a file must not turn the globally selected default profile
        // into an implicit authorization to run shared SQL.
        if document.runtime?.sessionId == nil { document.profileID = nil }
    }

    private func bindIndexedSQLViews(_ snapshot: SQLLibrarySnapshot) {
        for document in documents { bindIndexedSQLView(document, snapshot: snapshot) }
    }

    @discardableResult
    func openSQLLibraryEntry(_ entry: SQLLibraryEntry) async -> SQLDocument? {
        guard let current = sqlLibrary.entry(id: entry.id), current.fileURL == entry.fileURL else {
            reportError(SQLLibraryError.missingEntry.localizedDescription)
            return nil
        }
        guard let document = await openSQLFile(at: current.fileURL, inNewTab: true) else { return nil }
        document.sqlLibraryEntryID = current.id
        document.profileID = nil
        scheduleSave()
        return document
    }

    @discardableResult
    func openSQLFile(at url: URL, inNewTab: Bool = false) async -> SQLDocument? {
        guard shutdownTask == nil, !isClosing else { return nil }
        let context = capturePaneSelection()
        let profileID = library.selectedConnectionId
        let location = url.standardizedFileURL
        do {
            let file: SQLFileDocument
            if let existing = fileDocument(at: location) { file = existing }
            else {
                let loaded = try await Task.detached { try SQLFileBinding.read(location) }.value
                guard shutdownTask == nil, !isClosing else { return nil }
                // Separate hard-link paths can diverge during an atomic save or
                // checkout. Share views by their bound path, not a stale inode.
                if let existing = fileDocument(at: location) { file = existing }
                else {
                    file = SQLFileDocument(url: location, text: loaded.text, acceptedSHA256: loaded.sha256, loaded: loaded)
                    fileDocuments[file.id] = file
                }
            }
            if !inNewTab, let existing = documents.first(where: { $0.fileDocument === file }) {
                bindIndexedSQLView(existing)
                selectAfterOpening(existing, context: context)
                return existing
            }
            let document = SQLDocument(title: file.url.lastPathComponent, text: file.text, profileID: profileID)
            addDocument(document, context: context)
            document.attachFileDocument(file)
            bindIndexedSQLView(document)
            if automaticallyWatchFiles { file.startWatching() }
            scheduleSave()
            return document
        } catch { reportError(error.localizedDescription); return nil }
    }

    @discardableResult
    func openSQLFileInNewTab(_ source: SQLDocument) -> SQLDocument? {
        guard canStartOperation(source), source.isSQLDocument, let file = boundFileDocument(source) else { return nil }
        let document = newDocument(profileID: source.profileID, text: file.text, in: pane(containing: source.id))
        document.title = source.title
        document.attachFileDocument(file)
        bindIndexedSQLView(document)
        scheduleSave()
        return document
    }

    func attachSQLFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Attach Folder"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                do { _ = try await sqlFolders.attach(url) }
                catch { self.reportError(error.localizedDescription) }
            }
        }
    }

    func reconcileSQLFiles() async {
        for file in Array(fileDocuments.values) {
            guard shutdownTask == nil else { return }
            await file.reconcile()
        }
    }

    func openPreservedSQLFileVersion(_ source: SQLDocument) async {
        guard canStartOperation(source), let url = source.fileRecoveryURL else { return }
        let context = capturePaneSelection(in: pane(containing: source.id))
        let profileID = source.profileID
        do {
            let preserved = try await Task.detached { try SQLFileBinding.read(url) }.value
            guard canStartOperation(source), source.fileRecoveryURL == url else { return }
            let document = SQLDocument(title: "Preserved " + (source.fileURL?.lastPathComponent ?? "SQL"),
                text: preserved.text, profileID: profileID)
            addDocument(document, context: context)
            error = nil
        } catch { reportError(error.localizedDescription) }
    }

    func resolveSQLFileConflict(_ document: SQLDocument, conflictID: UUID, decision: SQLFileConflictDecision,
                                expectedText: String? = nil) async {
        guard canStartOperation(document), let file = document.fileDocument else { return }
        do {
            try await file.resolve(conflictID: conflictID, decision: decision, expectedText: expectedText)
            error = nil
        }
        catch { reportError(error.localizedDescription) }
    }

    func saveSQLFile(_ document: SQLDocument, chooseLocation: Bool = false) {
        guard canStartOperation(document), document.isSQLDocument, !isInvestigationSQLDocument(document) else { return }
        let file = boundFileDocument(document)
        guard file?.isSaving != true else { return }
        if !chooseLocation, let file, file.requiresSaveAs {
            reportError(file.statusMessage)
            return
        }
        let capturedText = document.text
        let capturedFileID = file?.id
        do {
            if !chooseLocation, let file, file.acceptedSHA256 != nil, !file.requiresSaveAs {
                _ = try file.save()
                document.title = file.url.lastPathComponent
                error = nil
                scheduleSave()
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
            panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? document.title + ".sql"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            var reviewed: SQLFileVersion?
            if FileManager.default.fileExists(atPath: destination.path) {
                let external = try SQLFileBinding.read(destination)
                guard SQLFileReplacementConfirmation.present(localText: capturedText, external: external, url: destination) else { return }
                reviewed = external.version
            }
            guard canStartOperation(document), document.fileDocument?.id == capturedFileID,
                  SQLFileDocument.sameBytes(document.text, capturedText) else {
                throw SQLFileDocumentFailure(message: "The local draft changed while choosing a destination. Review it and save again.")
            }
            try saveSQLFile(document, to: destination, reviewedVersion: reviewed)
        } catch { reportError(error.localizedDescription) }
    }

    /// Headless entry point shared by Save As and the conflict copy action.
    /// Existing targets require the exact version shown in the comparison.
    func saveSQLFile(_ document: SQLDocument, to destination: URL, reviewedVersion: SQLFileVersion?) throws {
        guard canStartOperation(document), document.isSQLDocument, !isInvestigationSQLDocument(document) else {
            throw SQLFileDocumentFailure(message: "This SQL document is no longer available for saving.")
        }
        let location = destination.standardizedFileURL
        let text = document.text
        let original = document.fileDocument
        let originalURL = document.fileURL
        let target = fileDocument(at: location)
        guard original?.isSaving != true, target?.isSaving != true else {
            throw SQLFileDocumentFailure(message: "A file involved in this save is already being saved.")
        }
        if let target, target !== original, !SQLFileDocument.sameBytes(target.text, text) {
            throw SQLFileDocumentFailure(message: "The destination has a different open draft. Keep that draft and choose another file for this copy.")
        }
        if let target, let sourceRecovery = document.fileRecoveryURL, let targetRecovery = target.recoveryURL,
           sourceRecovery != targetRecovery {
            throw SQLFileDocumentFailure(message: "These views have different preserved external versions. Choose another destination to keep both recovery references.")
        }
        let saved: LoadedSQLFile
        do { saved = try SQLFileBinding.write(text, to: location, expectedVersion: reviewedVersion) }
        catch {
            if let url = (error as? SQLFileBindingError)?.recoveryURL {
                document.fileRecoveryURL = url
                original?.recordFailure(error)
                scheduleSave()
            }
            throw error
        }
        let file: SQLFileDocument
        if let target {
            file = target
            file.retainRecovery(document.fileRecoveryURL)
            file.acceptSaved(saved)
        }
        else {
            file = SQLFileDocument(id: original == nil ? document.id : UUID(), url: location,
                text: text, acceptedSHA256: saved.sha256, loaded: saved, recoveryURL: document.fileRecoveryURL)
            fileDocuments[file.id] = file
        }
        document.attachFileDocument(file)
        if originalURL != location { document.sqlLibraryEntryID = nil }
        bindIndexedSQLView(document)
        document.title = location.lastPathComponent
        if automaticallyWatchFiles { file.startWatching() }
        pruneFileDocuments()
        scheduleSave()
        error = nil
    }

    private func fileDocument(at url: URL) -> SQLFileDocument? {
        fileDocuments.values.first { !$0.requiresSaveAs && $0.url == url.standardizedFileURL }
    }

    private func boundFileDocument(_ document: SQLDocument) -> SQLFileDocument? {
        if let file = document.fileDocument { return file }
        restoreFileDocument(document)
        return document.fileDocument
    }

    private func restoreFileDocument(_ document: SQLDocument) {
        guard document.isSQLDocument, !isInvestigationSQLDocument(document), let url = document.fileURL else { return }
        let state = document.storedState
        if let id = state.fileDocumentID, let existing = fileDocuments[id] {
            document.attachFileDocument(existing)
            return
        }
        let existing = fileDocument(at: url)
        if let existing, SQLFileDocument.sameBytes(existing.text, document.text),
           existing.acceptedSHA256 == document.fileContentSHA256 {
            document.attachFileDocument(existing)
            return
        }
        // Earlier workspace versions could contain independent drafts bound to
        // the same path. Keep every differing draft as a Save As recovery copy.
        let file = SQLFileDocument(id: state.fileDocumentID ?? document.id, url: url, text: document.text,
            acceptedSHA256: document.fileContentSHA256, restored: document.restoredFileBinding,
            requiresSaveAs: existing != nil, recoveryURL: document.fileRecoveryURL)
        fileDocuments[file.id] = file
        document.attachFileDocument(file)
        if automaticallyWatchFiles { file.startWatching() }
    }

    private func pruneFileDocuments() {
        let used = Set(documents.compactMap { $0.fileDocument?.id })
        for (id, file) in fileDocuments where !used.contains(id) {
            file.stopWatching()
            fileDocuments[id] = nil
        }
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
        } catch { reportError(error.localizedDescription) }
    }

    func runToFile(_ document: SQLDocument, format: String, fragment: SQLExecutionFragment? = nil) async {
        guard canStartOperation(document), document.isSQLDocument, !document.isRunning else { return }
        if let notice = sqlLibraryExecutionNotice(for: document) { document.localError = notice; return }
        let libraryBinding = sqlLibraryExecutionBinding(document)
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
        guard canStartOperation(document), SQLFileDocument.sameBytes(document.text, boundText), document.profileID == boundProfileID,
              hasSQLLibraryExecutionBinding(document, libraryBinding),
              library.savedConnections.first(where: { $0.id == boundProfileID }) == boundProfile else {
            document.localError = "The SQL or connection changed while choosing the export file. Review it and run again."
            return
        }
        do {
            let captured = try await Task.detached { try Self.captureExportDestination(destination) }.value
            guard canStartOperation(document), SQLFileDocument.sameBytes(document.text, boundText), document.profileID == boundProfileID,
                  hasSQLLibraryExecutionBinding(document, libraryBinding),
                  library.savedConnections.first(where: { $0.id == boundProfileID }) == boundProfile else {
                document.localError = "The SQL or connection changed while capturing the export file. Review it and run again."
                return
            }
            await execute(document, statements: fragment.statements,
                export: ExportRequest(path: destination.path, format: format, nullMarker: marker, destination: captured))
        } catch { document.localError = "The export destination changed or could not be captured. SQL was not executed." }
    }

    nonisolated private static func captureExportDestination(_ url: URL) throws -> ExportDestination {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().standardizedFileURL == parent.standardizedFileURL else { throw CocoaError(.fileReadUnknown) }
        let parentAttributes = try manager.attributesOfItem(atPath: parent.path)
        func identity(_ attributes: [FileAttributeKey: Any]) throws -> String {
            guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
            return "\(device.uint64Value):\(inode.uint64Value)"
        }
        let parentIdentity = try identity(parentAttributes)
        guard manager.fileExists(atPath: url.path) else { return ExportDestination(exists: false, parentIdentity: parentIdentity, size: 0, sha256: "") }
        let before = try manager.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
        let after = try manager.attributesOfItem(atPath: url.path)
        guard before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        return ExportDestination(exists: true, identity: try identity(before), parentIdentity: parentIdentity, size: (before[.size] as? NSNumber)?.int64Value ?? 0,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
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
        guard !field.stringValue.isEmpty else { reportError(ResultExportError.nullMarker.localizedDescription); return nil }
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
                catch { self.reportError(error.localizedDescription) }
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
        } catch { reportError(error.localizedDescription) }
    }

    func chooseImportedCA(_ id: UUID) {
        guard !isImportingProfiles, let original = importPreview?.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose this Mac's trusted CA file. The profile's TLS verification mode stays the same."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard !isImportingProfiles, let index = importPreview?.firstIndex(where: { $0.id == id && $0 == original }) else { return }
        importPreview?[index].profile.sslRootCert = selected.path
    }

    func chooseImportedSSHKey(_ id: UUID) {
        guard !isImportingProfiles, let original = importPreview?.first(where: { $0.id == id }),
              original.profile.ssh?.authMethod == .privateKey else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose this Mac's SSH private key. Private keys and trust decisions are never imported."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        guard !isImportingProfiles, let index = importPreview?.firstIndex(where: { $0.id == id && $0 == original }) else { return }
        importPreview?[index].profile.ssh?.identityFile = selected.path
    }

    func importProfiles() async {
        guard !isImportingProfiles else { return }
        let profiles = selectedImportProfiles
        guard !profiles.isEmpty else { return }
        guard !profiles.contains(where: { $0.requiresCASelection || $0.requiresSSHKeySelection }) else {
            importError = "Choose the missing CA files and local SSH private keys before importing."
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
            !selectedImportProfiles.contains(where: { $0.requiresCASelection || $0.requiresSSHKeySelection })
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

    func completionContext(profileID: UUID?, keyspace: String? = nil) -> SQLCompletionContext {
        var context = completionCatalog.context(profileID: profileID)
        let profile = library.savedConnections.first { $0.id == profileID }
        context.keyspace = keyspace ?? (profile?.engine == .cassandra ? profile?.database : nil)
        return context
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
        guard draftsLoaded, shutdownTask == nil else { return }
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.flushDocuments()
        }
    }

    private func recordHistory(_ entry: SQLHistoryEntry) {
        var saved = snapshot()
        saved.record(entry)
        history = saved.history
        scheduleSave()
    }

    func loadSchemas(_ profileID: UUID, refresh: Bool = false) async {
        guard refresh || catalogRoots[profileID] == nil else { return }
        if refresh { invalidatePostgresTypeInspection(profileID: profileID, reason: "The catalog was refreshed. Refresh this inspector before generating SQL.") }
        do {
            let result = try await catalog(CatalogRequest(kind: "schemas"), profileID: profileID)
            catalogRoots[profileID] = result.catalogRecords.compactMap { record in
                guard let name = record["name"] else { return nil }
                return CatalogNode(profileID: profileID, name: name, kind: .schema, schema: name,
                    engine: library.savedConnections.first { $0.id == profileID }?.engine)
            }
            catalogErrors[profileID] = nil
            if refresh { await loadCompletionCatalog(profileID, refresh: true) }
        } catch { catalogErrors[profileID] = error.localizedDescription }
    }

    func showClusterNodes(_ profileID: UUID) async {
        guard library.savedConnections.first(where: { $0.id == profileID })?.engine == .cassandra,
              let service = services[profileID], service.connectionState == .connected,
              let sessionID = service.sessionId else { return }
        let name = library.savedConnections.first(where: { $0.id == profileID })?.name ?? "Cassandra"
        clusterInspection = CassandraClusterInspection(profileID: profileID, sessionID: sessionID, title: name)
        await refreshClusterNodes()
    }

    func refreshClusterNodes() async {
        guard let inspection = clusterInspection, !inspection.isLoading else { return }
        clusterInspection?.isLoading = true
        clusterInspection?.error = nil
        do {
            let reply = try await catalog(CatalogRequest(kind: "clusterNodes"), profileID: inspection.profileID,
                                          connectedSessionID: inspection.sessionID)
            guard clusterInspection?.id == inspection.id else { return }
            clusterInspection?.nodes = reply.catalogRecords.map(CassandraClusterNode.init)
            clusterInspection?.totalNodeCount = reply.rowCount ?? 0
            clusterInspection?.refreshedAt = Date()
            clusterInspection?.notice = reply.displayNotice
        } catch {
            guard clusterInspection?.id == inspection.id else { return }
            clusterInspection?.nodes = []
            clusterInspection?.totalNodeCount = 0
            clusterInspection?.refreshedAt = nil
            clusterInspection?.notice = nil
            clusterInspection?.error = error.localizedDescription
        }
        clusterInspection?.isLoading = false
    }

    func expand(_ node: CatalogNode, refresh: Bool = false) async {
        guard !node.isLoading, refresh || node.children == nil else { return }
        if refresh { invalidatePostgresTypeInspection(profileID: node.profileID, reason: "The catalog was refreshed. Refresh this inspector before generating SQL.") }
        node.isLoading = true
        node.error = nil
        defer { node.isLoading = false }
        if node.kind == .schema {
            let engine = library.savedConnections.first { $0.id == node.profileID }?.engine
            var groups = engine == .cassandra ? [("Tables", "table"), ("Materialized Views", "view"), ("User-defined Types", "type")] :
                [("Tables", "table"), ("Views", "view"), ("Functions", "function"), ("Procedures", "procedure"), ("Triggers", "trigger")]
            if engine == .postgresql { groups += [("Enums", "enum"), ("User-defined Types", "type")] }
            node.children = groups.map { title, kind in
                CatalogNode(profileID: node.profileID, name: title, kind: .group, schema: node.schema, objectKind: kind, engine: engine)
            }
            return
        }
        if node.kind == .object {
            let engine = library.savedConnections.first { $0.id == node.profileID }?.engine
            if engine == .postgresql && ["enum", "type"].contains(node.objectKind) {
                await inspectPostgresType(node)
                return
            }
            let groups = node.objectKind == "type" ? [("Columns", "columns")] : engine == .cassandra ? [("Columns", "columns"), ("Keys", "keys"), ("Indexes", "indexes")] :
                [("Columns", "columns"), ("Keys", "keys"), ("Indexes", "indexes"), ("Constraints", "constraints"), ("Triggers", "triggers")]
            node.children = groups.map { title, kind in
                CatalogNode(profileID: node.profileID, name: title, kind: .detailGroup, schema: node.schema,
                    object: node.name, objectKind: kind, engine: engine, parentObjectKind: node.objectKind)
            }
            return
        }
        let isPostgresGroup = node.kind == .group && library.savedConnections.first(where: { $0.id == node.profileID })?.engine == .postgresql
        let typeOrigin = isPostgresGroup ? currentPostgresTypeCatalogOrigin(profileID: node.profileID) : nil
        do {
            let request: CatalogRequest
            if node.kind == .group {
                request = CatalogRequest(kind: "objects", schema: node.schema, objectKind: node.objectKind)
            } else {
                request = CatalogRequest(kind: node.objectKind, schema: node.schema, object: node.object,
                    objectKind: node.parentObjectKind ?? "table")
            }
            if isPostgresGroup && typeOrigin == nil {
                throw CatalogFailure(message: "Connect to this profile before browsing objects.")
            }
            let result = try await catalog(request, profileID: node.profileID, connectedSessionID: typeOrigin?.serviceSessionID)
            if isPostgresGroup {
                guard typeOrigin == currentPostgresTypeCatalogOrigin(profileID: node.profileID) else { return }
                node.children = try PostgresTypeCatalog.decodeObjects(result).map { item in
                    CatalogNode(profileID: node.profileID, name: item.name, kind: .object, schema: item.schema,
                        object: item.name, objectKind: item.kind, identity: item.identity, engine: .postgresql,
                        localOID: ["enum", "type"].contains(item.kind) ? item.identity : nil, typeKind: item.typeKind,
                        typeOrigin: typeOrigin)
                }
                if result.truncated == true { node.error = "Only part of this catalog group was returned. Refresh to check for more objects." }
                return
            }
            node.children = result.catalogRecords.enumerated().compactMap { index, record in
                guard let name = record["name"] else { return nil }
                let isObject = node.kind == .group
                let type = record["nativeType"].map { nativeType in
                    var details = [nativeType]
                    if (Int(record["partitionKeyPosition"] ?? "0") ?? 0) > 0 { details.append("partition key") }
                    if (Int(record["clusteringPosition"] ?? "0") ?? 0) > 0 { details.append("clustering " + (record["clusteringOrder"] ?? "asc")) }
                    if record["static"] == "true" { details.append("static") }
                    return details.joined(separator: " · ")
                }
                return CatalogNode(profileID: node.profileID, name: name,
                    kind: isObject ? .object : .detail, schema: node.schema,
                    object: isObject ? name : node.object, objectKind: record["kind"] ?? node.objectKind,
                    identity: record["identity"] ?? String(index), detail: type ?? record["definition"],
                    engine: library.savedConnections.first { $0.id == node.profileID }?.engine,
                    localOID: ["enum", "type"].contains(record["kind"] ?? node.objectKind) ? record["identity"] : nil,
                    typeKind: record["typeKind"])
            }
        } catch {
            if isPostgresGroup {
                guard typeOrigin == currentPostgresTypeCatalogOrigin(profileID: node.profileID) else { return }
                node.error = "PostgreSQL catalog metadata could not be loaded. Refresh the catalog and check access permissions."
            } else { node.error = error.localizedDescription }
        }
    }

    func inspect(_ node: CatalogNode) async {
        if library.savedConnections.first(where: { $0.id == node.profileID })?.engine == .postgresql,
           ["enum", "type"].contains(node.objectKind) {
            await inspectPostgresType(node)
            return
        }
        dismissPostgresTypeInspection()
        let title = "\(node.schema).\(node.name)"
        inspection = CatalogInspection(title: title)
        let inspectionID = inspection?.id
        do {
            if ["table", "view", "type"].contains(node.objectKind) {
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
        let profile = library.savedConnections.first { $0.id == node.profileID }
        do {
            let result = try await catalog(CatalogRequest(kind: "select", schema: node.schema,
                object: node.name, objectKind: node.objectKind), profileID: node.profileID)
            return result.catalogRecords.first?["sql"]
        } catch { reportError(error.localizedDescription, connection: profile); return nil }
    }

    @discardableResult
    func openGeneratedSelect(_ node: CatalogNode) async -> SQLDocument? {
        guard shutdownTask == nil, !isClosing else { return nil }
        let context = capturePaneSelection()
        guard let sql = await generatedSelect(node), shutdownTask == nil, !isClosing else { return nil }
        let document = SQLDocument(title: "SQL \(documents.count + 1)", text: sql, profileID: node.profileID)
        return addDocument(document, context: context)
    }

    func generatedName(_ node: CatalogNode) async -> String? {
        let profile = library.savedConnections.first { $0.id == node.profileID }
        do {
            if profile?.engine == .postgresql, ["enum", "type"].contains(node.objectKind) {
                return await generatedPostgresTypeName(node)
            }
            let identity = ["function", "procedure", "trigger"].contains(node.objectKind) ? node.identity : nil
            let result = try await catalog(CatalogRequest(kind: "name", schema: node.schema,
                object: node.name, objectKind: node.objectKind, identity: identity), profileID: node.profileID)
            return result.catalogRecords.first?["name"]
        } catch { reportError(error.localizedDescription, connection: profile); return nil }
    }

    @discardableResult
    func copyName(_ node: CatalogNode, to pasteboard: NSPasteboard = .general) async -> Bool {
        guard let name = await generatedName(node) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(name, forType: .string)
    }

    @discardableResult
    func openData(_ node: CatalogNode, inNewTab: Bool = false, in pane: WorkspacePaneID? = nil) async -> SQLDocument? {
        guard shutdownTask == nil, !isClosing, !disconnectingProfiles.contains(node.profileID),
              ["table", "view"].contains(node.objectKind) else { return nil }
        let reference = TableReference(schema: node.schema, name: node.name, kind: node.objectKind)
        if !inNewTab, let existing = documents.first(where: { $0.profileID == node.profileID && $0.table == reference }) {
            selectedDocumentID = existing.id
            return existing
        }
        let document = newDocument(profileID: node.profileID, text: "Table data", in: pane)
        document.title = node.name
        document.table = reference
        document.tableNeedsExplicitLoad = true
        await run(document)
        return documents.contains(where: { $0 === document }) ? document : nil
    }

    @discardableResult
    func openTableInNewTab(_ source: SQLDocument) async -> SQLDocument? {
        guard canStartOperation(source), let table = source.table, let profileID = source.profileID else { return nil }
        return await openData(CatalogNode(profileID: profileID, name: table.name, kind: .object,
            schema: table.schema, object: table.name, objectKind: table.kind), inNewTab: true,
            in: pane(containing: source.id))
    }

    func loadForeignKeys(_ document: SQLDocument, forNavigating: Bool = false) async {
        guard canStartOperation(document, forNavigating: forNavigating), !document.isLoadingForeignKeys,
              let table = document.table, let profileID = document.profileID else { return }
        document.tableForeignKeys = []
        document.foreignKeysError = nil
        if library.savedConnections.first(where: { $0.id == profileID })?.engine == .cassandra {
            document.foreignKeysError = "Foreign-key navigation is not supported for Cassandra."
            return
        }
        let requestID = UUID()
        document.foreignKeysRequestID = requestID
        document.isLoadingForeignKeys = true
        defer { if document.foreignKeysRequestID == requestID { document.isLoadingForeignKeys = false } }
        do {
            let response = try await catalog(CatalogRequest(kind: "foreignKeys", schema: table.schema,
                object: table.name, objectKind: table.kind), profileID: profileID)
            guard canStartOperation(document, forNavigating: forNavigating), document.profileID == profileID,
                  document.table == table, document.foreignKeysRequestID == requestID else { return }
            document.tableForeignKeys = try TableForeignKey.parse(response)
        } catch {
            guard canStartOperation(document, forNavigating: forNavigating), document.profileID == profileID,
                  document.table == table, document.foreignKeysRequestID == requestID else { return }
            document.foreignKeysError = error.localizedDescription
        }
    }

    func followForeignKey(_ key: TableForeignKey, rowID: UUID, in document: SQLDocument, inNewTab: Bool = false) async {
        guard canStartOperation(document), document.canNavigateTable else { return }
        let context = capturePaneSelection(in: pane(containing: document.id))
        document.grid?.commitEditing?()
        guard let source = TableViewLocation(document), let grid = document.grid,
              document.tableForeignKeys.contains(key), let row = grid.rows.first(where: { $0.id == rowID }) else {
            document.tableNavigationError = "The source row or foreign-key metadata changed. Select the row again after reloading."
            return
        }
        document.isNavigatingTable = true
        let wasClosing = grid.isClosing
        grid.isClosing = true
        defer { grid.isClosing = wasClosing; document.isNavigatingTable = false }
        document.tableNavigationError = nil
        do {
            let columns = try await navigationColumns(key.target, profileID: source.profileID,
                required: Set(key.columns.map(\.target)))
            guard navigationIsCurrent(document, source: source) else { return }
            let filters: [CatalogFilter]
            if inNewTab {
                guard let original = row.original else {
                    throw TableNavigationFailure("Apply the new row and reload it before opening related rows in another tab.")
                }
                let originalFilters = try key.filters(sourceColumns: grid.columns, values: original)
                let editedFilters = try key.filters(sourceColumns: grid.columns, values: row.values)
                guard originalFilters == editedFilters else {
                    throw TableNavigationFailure("Apply or discard the changed foreign-key values before opening related rows in another tab.")
                }
                filters = originalFilters
            } else {
                guard let resolved = try await navigationFiltersAfterReview(document, grid: grid, key: key, row: row) else { return }
                filters = resolved
            }
            guard navigationIsCurrent(document, source: source) else { return }
            let target = TableViewLocation(reference: key.target, profileID: source.profileID, filters: filters)
            if inNewTab {
                await openRelatedTable(target, columns: columns, source: document, context: context)
            } else if await moveTable(document, from: source, to: target, columns: columns) {
                document.tableBackHistory.append(source)
                if document.tableBackHistory.count > 100 { document.tableBackHistory.removeFirst() }
                document.tableForwardHistory = []
            }
        } catch { if navigationIsCurrent(document, source: source) { document.tableNavigationError = error.localizedDescription } }
    }

    func navigateTableBack(_ document: SQLDocument) async { await navigateTableHistory(document, backwards: true) }
    func navigateTableForward(_ document: SQLDocument) async { await navigateTableHistory(document, backwards: false) }

    private func navigateTableHistory(_ document: SQLDocument, backwards: Bool) async {
        guard canStartOperation(document), document.canNavigateTable,
              let target = backwards ? document.tableBackHistory.last : document.tableForwardHistory.last,
              let source = TableViewLocation(document) else { return }
        guard source.profileID == target.profileID else {
            document.tableNavigationError = "The connection changed. Reopen the target table with its original connection."
            return
        }
        document.grid?.commitEditing?()
        let grid = document.grid
        document.isNavigatingTable = true
        let wasClosing = grid?.isClosing ?? false
        grid?.isClosing = true
        defer { grid?.isClosing = wasClosing; document.isNavigatingTable = false }
        document.tableNavigationError = nil
        do {
            let columns = try await navigationColumns(target.reference, profileID: target.profileID,
                required: Set(target.filters.map(\.column) + target.sort.map(\.column)))
            guard navigationIsCurrent(document, source: source),
                  try await prepareNavigationDraft(document, grid: grid) else { return }
            if await moveTable(document, from: source, to: target, columns: columns) {
                if backwards {
                    document.tableBackHistory.removeLast()
                    document.tableForwardHistory.append(source)
                } else {
                    document.tableForwardHistory.removeLast()
                    document.tableBackHistory.append(source)
                }
            }
        } catch { if navigationIsCurrent(document, source: source) { document.tableNavigationError = error.localizedDescription } }
    }

    private func navigationColumns(_ reference: TableReference, profileID: UUID, required: Set<String>) async throws -> [[String: String]] {
        let response = try await catalog(CatalogRequest(kind: "columns", schema: reference.schema,
            object: reference.name, objectKind: reference.kind), profileID: profileID)
        let columns = response.catalogRecords
        guard response.truncated != true, !columns.isEmpty,
              required.isSubset(of: Set(columns.compactMap { $0["name"] })) else {
            throw TableNavigationFailure("The target table or its key columns are unavailable. Check the table name and SELECT permissions.")
        }
        return columns
    }

    private func navigationIsCurrent(_ document: SQLDocument, source: TableViewLocation) -> Bool {
        canStartOperation(document, forNavigating: true) && TableViewLocation(document) == source
    }

    private func prepareNavigationDraft(_ document: SQLDocument, grid: GridDraft?, key: TableForeignKey? = nil,
                                        row: GridRow? = nil) async throws -> Bool {
        guard let grid else { return true }
        guard !grid.hasInlineDraft else { throw TableNavigationFailure("Finish editing the cell before following related rows.") }
        let request = grid.request()
        let decision: WorkspaceCloseDecision
        if grid.outcomeUnknown { decision = await closeDecision(.unknownApply(document.title)) }
        else if grid.pendingCount > 0 { decision = await closeDecision(.changes(document.title, count: grid.pendingCount)) }
        else { return true }
        guard canStartOperation(document, forNavigating: true), document.grid === grid, grid.request() == request else { return false }
        switch decision {
        case .apply:
            guard !grid.outcomeUnknown else { return false }
            if let key, let row { _ = try key.filters(sourceColumns: grid.columns, values: row.values) }
            // Navigation already owns the view lock. Applying without the
            // ordinary automatic reload uses the same preview/confirmation path.
            guard await applyGrid(document, forClosing: true) else { return false }
            await execute(document, statements: [], forNavigating: true)
            return document.grid != nil && document.runtime?.queryFailure == nil && document.localError == nil
        case .discard:
            let unknown = grid.outcomeUnknown
            grid.isClosing = false
            grid.discard()
            grid.isClosing = true
            grid.outcomeUnknown = unknown
            return true
        default: return false
        }
    }

    private func navigationFiltersAfterReview(_ document: SQLDocument, grid: GridDraft,
                                        key: TableForeignKey, row: GridRow) async throws -> [CatalogFilter]? {
        let pending = grid.pendingCount > 0 || grid.outcomeUnknown
        let before = grid.rows.map { ($0.id, $0.values) }
        guard try await prepareNavigationDraft(document, grid: grid, key: key, row: row) else { return nil }
        let values: [ChangeValue]
        if !pending { values = row.values }
        else if document.grid === grid, grid.pendingCount == 0 {
            guard let original = row.original else { throw TableNavigationFailure("The inserted source row was discarded and has no related stored row.") }
            values = original
        } else {
            // Apply may reload/reorder rows. Use the captured edited values,
            // never the row at the old ordinal in the refreshed result.
            values = before.first { $0.0 == row.id }?.1 ?? row.values
        }
        return try key.filters(sourceColumns: grid.columns, values: values)
    }

    private func installTableLocation(_ location: TableViewLocation, in document: SQLDocument) {
        document.table = location.reference
        document.profileID = location.profileID
        document.title = location.title
        document.tableFilters = location.filters
        document.tableSort = location.sort
        document.page = location.page
        document.tableCursor = nil
        document.tableNextCursor = nil
        document.tableForeignKeys = []
        document.foreignKeysError = nil
        document.foreignKeysRequestID = UUID()
        document.isLoadingForeignKeys = false
    }

    private func moveTable(_ document: SQLDocument, from source: TableViewLocation, to target: TableViewLocation,
                           columns: [[String: String]]) async -> Bool {
        guard navigationIsCurrent(document, source: source) else { return false }
        let oldGrid = document.grid
        let oldResult = document.tableResult
        let oldSnapshotSource = document.tableSnapshotSource
        let oldFailure = document.tableFailure
        let oldColumns = document.tableColumns
        let oldCursor = document.tableCursor
        let oldNextCursor = document.tableNextCursor
        let oldNeedsLoad = document.tableNeedsExplicitLoad
        let oldError = document.localError
        let oldKeys = document.tableForeignKeys
        let oldKeysError = document.foreignKeysError
        document.tableNavigationSourceState = document.storedState
        defer {
            document.tableNavigationSourceState = nil
            scheduleSave()
        }
        installTableLocation(target, in: document)
        document.attachGrid(nil)
        document.tableResult = nil
        document.tableSnapshotSource = nil
        document.tableFailure = nil
        document.tableColumns = columns
        document.tableNeedsExplicitLoad = true
        document.localError = nil
        await execute(document, statements: [], forNavigating: true)
        guard canStartOperation(document, forNavigating: true), TableViewLocation(document) == target else { return false }
        guard document.grid != nil, document.localError == nil, document.runtime?.queryFailure == nil else {
            let message = document.localError ?? document.runtime?.queryFailure?.message ?? document.runtime?.errorMessage ?? "The target table could not be loaded."
            installTableLocation(source, in: document)
            document.attachGrid(oldGrid)
            document.tableResult = oldResult
            document.tableSnapshotSource = oldSnapshotSource
            document.tableFailure = oldFailure
            document.tableColumns = oldColumns
            document.tableCursor = oldCursor
            document.tableNextCursor = oldNextCursor
            document.tableNeedsExplicitLoad = oldNeedsLoad
            document.localError = oldError
            document.tableForeignKeys = oldKeys
            document.foreignKeysError = oldKeysError
            document.tableNavigationError = "Could not load \(target.reference.schema).\(target.reference.name): \(message)"
            scheduleSave()
            return false
        }
        document.tableNavigationError = nil
        scheduleSave()
        return true
    }

    private func openRelatedTable(_ location: TableViewLocation, columns: [[String: String]], source: SQLDocument,
                                  context: PaneSelectionContext) async {
        guard canStartOperation(source, forNavigating: true) else { return }
        let document = SQLDocument(title: "SQL \(documents.count + 1)", text: "Table data", profileID: location.profileID)
        document.isProvisionalTableView = true
        document.provisionalPreviousSelection = context.selectedDocumentID ?? source.id
        addDocument(document, context: context)
        defer {
            document.isProvisionalTableView = false
            document.provisionalPreviousSelection = nil
            scheduleSave()
        }
        installTableLocation(location, in: document)
        document.tableColumns = columns
        document.tableNeedsExplicitLoad = true
        await run(document)
        guard documents.contains(where: { $0 === document }) else { return }
        if document.grid == nil || document.localError != nil || document.runtime?.queryFailure != nil {
            let message = document.localError ?? document.runtime?.queryFailure?.message ?? document.runtime?.errorMessage ?? "The related rows could not be loaded."
            guard closingDocuments.insert(document.id).inserted else { return }
            defer { closingDocuments.remove(document.id) }
            if let pane = pane(containing: document.id), paneLayout[pane].selectedDocumentID == document.id,
               let selected = document.provisionalPreviousSelection, paneLayout[pane].documentIDs.contains(selected) {
                paneLayout[pane].selectedDocumentID = selected
                paneSelectionRevisions[pane, default: 0] &+= 1
            }
            await closeDocumentImmediately(document)
            if canStartOperation(source, forNavigating: true) { source.tableNavigationError = message }
        }
    }

    func searchCatalog() async {
        let term = catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogSearchResults = [:]
        guard !term.isEmpty else { return }
        for profileID in services.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !Task.isCancelled, catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            let isPostgres = library.savedConnections.first(where: { $0.id == profileID })?.engine == .postgresql
            let typeOrigin = isPostgres ? currentPostgresTypeCatalogOrigin(profileID: profileID) : nil
            do {
                if isPostgres && typeOrigin == nil { continue }
                let result = try await catalog(CatalogRequest(kind: "search", search: term), profileID: profileID,
                    connectedSessionID: typeOrigin?.serviceSessionID)
                guard !Task.isCancelled, catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                if isPostgres {
                    guard typeOrigin == currentPostgresTypeCatalogOrigin(profileID: profileID) else { continue }
                    catalogSearchResults[profileID] = try PostgresTypeCatalog.decodeObjects(result).map { item in
                        CatalogNode(profileID: profileID, name: item.name, kind: .object, schema: item.schema,
                            object: item.name, objectKind: item.kind, identity: item.identity, engine: .postgresql,
                            localOID: ["enum", "type"].contains(item.kind) ? item.identity : nil, typeKind: item.typeKind,
                            typeOrigin: typeOrigin)
                    }
                    catalogErrors[profileID] = result.truncated == true
                        ? "Search results are incomplete. Refine the search to find more objects." : nil
                    continue
                }
                catalogSearchResults[profileID] = result.catalogRecords.compactMap { record in
                    guard let name = record["name"], let schema = record["schema"] else { return nil }
                    return CatalogNode(profileID: profileID, name: name, kind: .object, schema: schema,
                        object: name, objectKind: record["kind"] ?? "table", identity: record["identity"],
                        engine: library.savedConnections.first { $0.id == profileID }?.engine,
                        localOID: ["enum", "type"].contains(record["kind"] ?? "") ? record["identity"] : nil,
                        typeKind: record["typeKind"])
                }
            } catch {
                guard !Task.isCancelled, catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                if isPostgres {
                    guard typeOrigin == currentPostgresTypeCatalogOrigin(profileID: profileID) else { continue }
                    catalogErrors[profileID] = "PostgreSQL catalog search is unavailable. Refresh the catalog and check access permissions."
                } else { catalogErrors[profileID] = error.localizedDescription }
            }
        }
    }

    func catalog(_ request: CatalogRequest, profileID: UUID, connectedSessionID: String? = nil,
                 typeRequest: PostgresTypeCatalogRequest? = nil) async throws -> BackendMessage {
        let client: BackendClient
        if let connectedSessionID {
            guard shutdownTask == nil, !helperFailed, !disconnectingProfiles.contains(profileID),
                  services[profileID]?.sessionId == connectedSessionID,
                  services[profileID]?.connectionState == .connected, let helper else {
                throw CatalogFailure(message: "The profile was disconnected while loading metadata.")
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
            guard self.services[profileID]?.sessionId == sessionID,
                  self.services[profileID]?.connectionState == .connected,
                  typeRequest?.cancelled != true else {
                throw CatalogFailure(message: "The profile was disconnected while loading metadata.")
            }
            typeRequest?.submitted = true
            return try await client.request(.catalog(sessionId: sessionID,
                queryId: typeRequest?.queryID ?? UUID().uuidString, request: request))
        }
        typeRequest?.task = task
        catalogRequests[profileID] = (requestID, task)
        defer {
            typeRequest?.finished = true
            typeRequest?.task = nil
            if catalogRequests[profileID]?.id == requestID { catalogRequests[profileID] = nil }
        }
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

    var canInspectPostgresTypes: Bool { shutdownTask == nil && !isClosing && !helperFailed }

    func cancelPostgresTypeCatalogQuery(sessionID: String, queryID: String) async throws -> BackendMessage {
        guard let helper, !helperFailed, shutdownTask == nil else { throw BackendTransportError(.notReady) }
        return try await helper.request(.cancel(sessionId: sessionID, queryId: queryID))
    }

    private struct CatalogFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func shutdown() async {
        await schemaComparison?.close(); schemaComparison = nil
        if let shutdownTask { await shutdownTask.value; return }
        dismissPostgresTypeInspection()
        for file in fileDocuments.values { file.stopWatching() }
        sqlFolders.shutdown()
        closedTabs.removeAll()
        let task = Task { @MainActor in
            await self.flushDocuments()
            if self.investigations.isLoaded { _ = await self.investigations.flush() }
            for load in self.completionLoads.values { load.task.cancel() }
            for service in self.services.values { service.cancelConnection() }
            for document in self.allOwnedRuntimeDocuments { document.runtime?.cancelConnection() }
            for task in self.profileConnections.values { task.cancel() }
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
                self.clusterInspection = nil
                self.invalidatePostgresTypeInspection(reason: "The helper connection ended. Reopen this type after connecting again.")
                self.reportError(failure.localizedDescription)
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

private struct InvestigationReferenceError: LocalizedError {
    var errorDescription: String? { "The investigation library is unavailable. Snapshot references could not be checked." }
}
