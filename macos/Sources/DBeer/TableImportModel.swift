import Combine
import Foundation

enum TableImportOutcome: Equatable {
    case applied(Int)
    case failed
    case outcomeUnknown
}

/// An import owns one dedicated session. File bytes, converted values and the
/// reviewed request live only in this model and never enter document storage.
@MainActor
final class TableImportModel: ObservableObject, Identifiable {
    let id = UUID()
    let profile: SavedConnection
    let schema: String
    let table: String
    let mappingPresets: TransferMappingPresetStore
    @Published private(set) var columns: [TableImportColumn] = []
    @Published private(set) var fingerprint: String?
    @Published private(set) var fileName: String?
    @Published private(set) var parsed: DelimitedImportDocument?
    @Published var options = DelimitedImportOptions() {
        didSet {
            guard options != oldValue else { return }
            invalidatePreview()
            startParsing(preserveMapping: true)
        }
    }
    @Published var mapping: [String?] = [] {
        didSet {
            guard !sameMapping(mapping, oldValue) else { return }
            invalidatePreview()
            refreshMappedRequest()
        }
    }
    @Published private(set) var preview: TableImportReply?
    @Published private(set) var outcome: TableImportOutcome?
    @Published private(set) var error: String?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isParsing = false
    @Published private(set) var isReading = false
    @Published private(set) var isRequesting = false
    @Published private(set) var isApplying = false
    @Published private(set) var closing = false
    @Published private(set) var invalidated = false
    private var fileData: Data?
    private var sessionID: String?
    private var queryID: String?
    private var cancelRequested = false
    private var inputRevision: UInt64 = 0
    private var parsingID = UUID()
    private var readingID = UUID()
    private var parsingTask: Task<Void, Never>?
    private var preparedRequest: TableImportRequest?
    private var preparedBytes: Data?
    private var reviewedRequest: TableImportRequest?
    private var reviewedBytes: Data?
    private var reviewedRevision: UInt64?
    private let connect: () async throws -> String
    private let send: (BackendCommand) async throws -> BackendMessage
    private let authorize: (TableImportRequest, TableImportReply, String) async throws -> String?
    private let bindingIsCurrent: () -> Bool
    private let operationsAllowed: () -> Bool
    private let sessionIsKnownClosed: () async -> Bool
    private let changed: () -> Void

    init(profile: SavedConnection, schema: String, table: String,
         connect: @escaping () async throws -> String,
         send: @escaping (BackendCommand) async throws -> BackendMessage,
         authorize: @escaping (TableImportRequest, TableImportReply, String) async throws -> String?,
         bindingIsCurrent: @escaping () -> Bool,
         operationsAllowed: @escaping () -> Bool = { true },
         sessionIsKnownClosed: @escaping () async -> Bool = { false },
         mappingPresets: TransferMappingPresetStore? = nil,
         changed: @escaping () -> Void) {
        self.profile = profile; self.schema = schema; self.table = table
        self.mappingPresets = mappingPresets ?? TransferMappingPresetStore()
        self.connect = connect; self.send = send; self.authorize = authorize
        self.bindingIsCurrent = bindingIsCurrent; self.operationsAllowed = operationsAllowed
        self.sessionIsKnownClosed = sessionIsKnownClosed; self.changed = changed
    }

    var isBusy: Bool { isReading || isParsing || isRequesting }
    var outcomeUnknown: Bool { outcome == .outcomeUnknown }
    var appliedRowCount: Int? { if case .applied(let count) = outcome { count } else { nil } }
    private var completedOrUnknown: Bool { appliedRowCount != nil || outcomeUnknown }
    var hasDraft: Bool { fileData != nil && !completedOrUnknown }
    var canEdit: Bool { !isBusy && !closing && !invalidated && !completedOrUnknown }
    var canEditOptions: Bool { !isRequesting && !closing && !invalidated && !completedOrUnknown }
    var canPreview: Bool {
        canEdit && operationsAllowed() && bindingIsCurrent() && preparedRequest != nil
    }
    var canApply: Bool {
        canPreview && !profile.policy.readOnly && preview != nil &&
            reviewedRevision == inputRevision && reviewedBytes != nil
    }
    var canLoad: Bool { !isBusy && !closing && !invalidated && !completedOrUnknown && operationsAllowed() }
    var mappedColumnNames: [String] { mapping.compactMap { $0 } }
    var unmappedColumns: [TableImportColumn] {
        let selected = Set(mappedColumnNames.map { Data($0.utf8) })
        return columns.filter { !selected.contains(Data($0.name.utf8)) }
    }
    var requiredUnmappedColumns: [TableImportColumn] {
        unmappedColumns.filter { !$0.generated && !$0.nullable && !$0.hasDefault }
    }

    @discardableResult
    func validateBinding() -> Bool {
        guard bindingIsCurrent() else {
            invalidate()
            return false
        }
        return !invalidated
    }

    func invalidate() {
        invalidated = true
        invalidatePreview()
        error = "The connection or catalog changed. Close this import and reopen it with the current connection."
    }

    private func requireContext() throws {
        guard validateBinding(), !cancelRequested, !closing, operationsAllowed(), !completedOrUnknown else {
            throw TableImportError.contextChanged
        }
    }

    private func invalidatePreview() {
        inputRevision &+= 1
        preview = nil
        reviewedRequest = nil
        reviewedBytes = nil
        reviewedRevision = nil
    }

    private func request(_ operation: String, _ payload: TableImportRequest,
                         authorization: String? = nil) async throws -> TableImportReply {
        try requireContext()
        guard let sessionID else { throw TableImportError.noSession }
        let query = UUID().uuidString
        queryID = query
        defer { queryID = nil }
        var command = BackendCommand.tableImport(operation, sessionId: sessionID, queryId: query, request: payload)
        command.authorization = authorization
        let response = try await send(command)
        guard response.type == "import." + operation + ".result", response.sessionId == sessionID,
              response.queryId == query, let reply = response.tableImport,
              reply.valid(for: response.type) else {
            throw BackendTransportError(.invalidMessage, outcomeUnknown: operation == "apply")
        }
        return reply
    }

    func load() async {
        guard canLoad, validateBinding() else { return }
        isRequesting = true; cancelRequested = false; error = nil
        invalidatePreview()
        defer { isRequesting = false }
        do {
            if sessionID == nil { sessionID = try await connect() }
            try requireContext()
            let reply = try await request("describe", .init(schema: schema, table: table))
            try requireContext()
            guard let columns = reply.columns, let fingerprint = reply.fingerprint else {
                throw BackendTransportError(.invalidMessage)
            }
            self.columns = columns
            self.fingerprint = fingerprint
            if let parsed { mapping = automaticMapping(parsed.headers) }
            refreshMappedRequest()
        } catch { noteClosedSession(error); self.error = describe(error) }
    }

    func loadFile(url: URL) async {
        guard !isRequesting, !closing, !invalidated, !completedOrUnknown else { return }
        invalidatePreview()
        let generation = UUID()
        readingID = generation
        isReading = true; error = nil
        do {
            let data = try await Task.detached { try Self.readBounded(url) }.value
            guard readingID == generation else { return }
            isReading = false
            guard !closing, !completedOrUnknown else { return }
            await loadFile(data: data, name: url.lastPathComponent)
        } catch {
            guard readingID == generation else { return }
            isReading = false
            self.error = describe(error)
        }
    }

    func loadFile(data: Data, name: String) async {
        guard !isRequesting, !closing, !invalidated, !completedOrUnknown else { return }
        invalidatePreview()
        guard data.count <= DelimitedTextImport.maximumInputBytes else {
            parsingID = UUID(); parsingTask?.cancel(); parsingTask = nil; isParsing = false
            fileData = nil; fileName = name; parsed = nil; mapping = []
            preparedRequest = nil; preparedBytes = nil
            error = TableImportError.fileTooLarge.localizedDescription
            return
        }
        fileData = data
        fileName = name
        parsed = nil
        mapping = []
        preparedRequest = nil; preparedBytes = nil; error = nil
        startParsing(preserveMapping: false)
        await parsingTask?.value
    }

    private func startParsing(preserveMapping: Bool) {
        guard let fileData, !closing, !invalidated, !completedOrUnknown else { return }
        let previousHeaders = parsed?.headers
        let previousMapping = mapping
        let capturedOptions = options
        let generation = UUID()
        parsingID = generation
        parsingTask?.cancel()
        parsed = nil; preparedRequest = nil; preparedBytes = nil
        isParsing = true; validationMessage = nil; error = nil
        parsingTask = Task { [weak self] in
            do {
                let document = try await Task.detached {
                    try DelimitedTextImport.parse(data: fileData, options: capturedOptions)
                }.value
                guard let self, self.parsingID == generation else { return }
                self.isParsing = false
                guard !self.closing, !self.completedOrUnknown else { return }
                self.parsed = document
                let sameHeaders = previousHeaders.map { old in
                    old.count == document.headers.count &&
                        zip(old, document.headers).allSatisfy { Data($0.utf8) == Data($1.utf8) }
                } ?? false
                self.mapping = preserveMapping && sameHeaders ? previousMapping : self.automaticMapping(document.headers)
                self.refreshMappedRequest()
            } catch {
                guard let self, self.parsingID == generation else { return }
                self.isParsing = false
                self.error = self.describe(error)
            }
        }
    }

    func setMapping(source: Int, target: String?) {
        guard mapping.indices.contains(source), !closing, !completedOrUnknown else { return }
        mapping[source] = target
    }

    func saveMapping(name: String) async {
        guard canEdit, let parsed else { return }
        let preset = TransferMappingPreset(name: name, engine: profile.engine, purpose: "append", headers: parsed.headers,
            columns: mapping.enumerated().map { .init(sourceIndex: $0.offset, targetName: $0.element) },
            fileOptions: .init(options))
        do { try await mappingPresets.save(preset) }
        catch { self.error = error.localizedDescription }
    }

    func applyMapping(_ preset: TransferMappingPreset) async {
        guard canEdit, let fileOptions = preset.fileOptions.options,
              preset.engine == profile.engine, preset.purpose == "append", preset.valid, fileData != nil else { return }
        options = fileOptions
        let parsing = parsingID
        await parsingTask?.value
        guard canEdit, parsing == parsingID, options == fileOptions, let parsed,
              preset.matches(headers: parsed.headers, engine: profile.engine, purpose: "append") else {
            error = "The saved mapping does not match this file's exact column names and parser options."
            return
        }
        let targets = Set(columns.filter { !$0.generated }.map { Data($0.name.utf8) })
        guard preset.columns.allSatisfy({ $0.targetName.map { targets.contains(Data($0.utf8)) } ?? true }) else {
            error = "The saved mapping refers to target columns that no longer exist. Reload columns and review a new mapping."
            return
        }
        mapping = preset.columns.sorted { $0.sourceIndex < $1.sourceIndex }.map(\.targetName)
        error = nil
    }

    private func automaticMapping(_ headers: [String]) -> [String?] {
        let sourceCounts = Dictionary(grouping: headers, by: { Data($0.utf8) }).mapValues(\.count)
        let available = Dictionary(grouping: columns.filter { !$0.generated }, by: { Data($0.name.utf8) })
        return headers.map { header in
            let key = Data(header.utf8)
            guard sourceCounts[key] == 1, let matches = available[key], matches.count == 1 else { return nil }
            return matches[0].name
        }
    }

    private func refreshMappedRequest() {
        preparedRequest = nil; preparedBytes = nil; validationMessage = nil
        guard let parsed else { return }
        guard !columns.isEmpty, let fingerprint else {
            validationMessage = "Load the target columns before reviewing the import."
            return
        }
        do {
            guard mapping.count == parsed.headers.count else { throw TableImportError.mapping }
            let selected = mapping.compactMap { $0 }
            guard !selected.isEmpty, Set(selected.map { Data($0.utf8) }).count == selected.count else {
                throw TableImportError.mapping
            }
            let targets = Dictionary(uniqueKeysWithValues: columns.map { (Data($0.name.utf8), $0) })
            guard selected.allSatisfy({ name in
                targets[Data(name.utf8)].map { !$0.generated } == true
            }) else { throw TableImportError.mapping }
            guard requiredUnmappedColumns.isEmpty else { throw TableImportError.requiredColumns }
            guard !parsed.rows.isEmpty else { throw TableImportError.noRows }
            let binary = columns.filter(\.binary).map(\.name)
            let rows = try parsed.mappedRows(mapping: mapping, binaryColumns: binary, options: options)
            let request = TableImportRequest(schema: schema, table: table, fingerprint: fingerprint,
                columns: selected, rows: rows)
            guard request.valid(for: "import.preview") else { throw TableImportError.limits }
            preparedBytes = try Self.bytes(request)
            preparedRequest = request
        } catch { validationMessage = describe(error) }
    }

    func preparePreview() async {
        guard canPreview, let frozen = preparedRequest, let bytes = preparedBytes else { return }
        let revision = inputRevision
        isRequesting = true; cancelRequested = false; error = nil
        preview = nil; reviewedRequest = nil; reviewedBytes = nil; reviewedRevision = nil
        defer { isRequesting = false }
        do {
            let reply = try await request("preview", frozen)
            try requireContext()
            guard revision == inputRevision, preparedBytes == bytes,
                  reply.fingerprint == frozen.fingerprint, reply.rowCount == frozen.rows?.count else {
                throw TableImportError.draftChanged
            }
            preview = reply; reviewedRequest = frozen; reviewedBytes = bytes; reviewedRevision = revision
        } catch { noteClosedSession(error); self.error = describe(error) }
    }

    func apply() async {
        guard canApply, let frozen = reviewedRequest, let bytes = reviewedBytes,
              let reviewed = preview, let sessionID else { return }
        let revision = inputRevision
        isRequesting = true; cancelRequested = false; error = nil
        defer { isRequesting = false; isApplying = false }
        do {
            guard let authorization = try await authorize(frozen, reviewed, sessionID) else { return }
            try requireContext()
            guard revision == inputRevision, reviewedRevision == revision, preparedBytes == bytes,
                  try Self.bytes(frozen) == bytes, preview != nil else { throw TableImportError.draftChanged }
            isApplying = true
            let reply = try await request("apply", frozen, authorization: authorization)
            guard reply.rowCount == frozen.rows?.count, let rowCount = reply.rowCount else {
                throw BackendTransportError(.invalidMessage, outcomeUnknown: true)
            }
            // Preserve terminal evidence even when the connection changed in flight.
            outcome = .applied(rowCount)
            invalidatePreview()
            preparedRequest = nil; preparedBytes = nil
            changed()
            _ = validateBinding()
        } catch {
            noteClosedSession(error)
            self.error = describe(error)
            if isApplying {
                let remote = (error as? BackendRemoteError)?.reply
                let transport = error as? BackendTransportError
                let unknown = remote?.outcomeUnknown == true || transport?.outcomeUnknown == true ||
                    (remote == nil && transport == nil && !(error is BackendRequestError))
                outcome = unknown ? .outcomeUnknown : .failed
                invalidatePreview()
                if unknown {
                    preparedRequest = nil; preparedBytes = nil
                    changed()
                }
            } else if cancelRequested {
                invalidatePreview()
            }
        }
    }

    func stop() async {
        cancelRequested = true
        invalidatePreview()
        if isReading { readingID = UUID(); isReading = false }
        if isParsing {
            parsingID = UUID(); parsingTask?.cancel(); parsingTask = nil; isParsing = false
        }
        guard let sessionID, let queryID else { return }
        // The terminal import reply owns isRequesting. A cancellation
        // acknowledgement alone never unlocks Apply or closes the session.
        _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID))
    }

    func beginClosing() -> Bool {
        guard !closing else { return false }
        closing = true
        return true
    }
    func cancelClosing() { closing = false }
    func close() async -> Bool {
        guard !isBusy else { return false }
        closing = true
        readingID = UUID()
        parsingID = UUID(); parsingTask?.cancel(); parsingTask = nil
        if let sessionID {
            do {
                let response = try await send(.disconnect(sessionId: sessionID))
                guard response.type == "disconnect.ack", response.sessionId == sessionID else {
                    throw BackendTransportError(.invalidMessage)
                }
            } catch {
                if await sessionIsKnownClosed() {
                    self.sessionID = nil
                    clearFileContents()
                    return true
                }
                self.error = "The import session could not be closed. Wait for its terminal outcome and try again."
                closing = false
                return false
            }
        }
        sessionID = nil
        clearFileContents()
        return true
    }

    private func clearFileContents() {
        fileData = nil; fileName = nil; parsed = nil; mapping = []
        preparedRequest = nil; preparedBytes = nil
        invalidatePreview()
    }

    private func noteClosedSession(_ error: Error) {
        if (error as? BackendRemoteError)?.reply.connected == false { sessionID = nil }
    }

    func previewValue(row: Int, source: Int) -> ChangeValue? {
        guard let parsed, parsed.rows.indices.contains(row),
              parsed.rows[row].fields.indices.contains(source) else { return nil }
        let target = mapping.indices.contains(source) ? mapping[source] : nil
        let binary = target.flatMap { name in columns.first { Data($0.name.utf8) == Data(name.utf8) } }?.binary == true
        return try? parsed.rows[row].fields[source].value(options: options, binary: binary)
    }

    private func describe(_ error: Error) -> String {
        if let remote = error as? BackendRemoteError, let row = remote.reply.tableImport?.row {
            let line = parsed.flatMap { $0.rows.indices.contains(row - 1) ? $0.rows[row - 1].number : nil }
            let location = "Data row \(row)" + (line.map { " (file line \($0))" } ?? "")
            return location + ": " + remote.localizedDescription
        }
        return error.localizedDescription
    }

    private func sameMapping(_ lhs: [String?], _ rhs: [String?]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            switch (a, b) {
            case (nil, nil): true
            case (let a?, let b?): Data(a.utf8) == Data(b.utf8)
            default: false
            }
        }
    }

    private nonisolated static func bytes(_ request: TableImportRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    private nonisolated static func readBounded(_ url: URL) throws -> Data {
        let limit = 8 * 1_024 * 1_024
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= limit {
                let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
                if chunk.isEmpty { return data }
                data.append(chunk)
            }
            throw TableImportError.fileTooLarge
        } catch let error as TableImportError { throw error }
        catch { throw TableImportError.fileRead }
    }
}

private enum TableImportError: LocalizedError {
    case contextChanged, noSession, mapping, requiredColumns, noRows, limits, draftChanged, fileTooLarge, fileRead
    var errorDescription: String? {
        switch self {
        case .contextChanged: "The import was stopped or its connection changed. Review the current target before continuing."
        case .noSession: "Load the target columns in a dedicated import session first."
        case .mapping: "Map at least one source column to a unique, available target column. Generated columns cannot be imported."
        case .requiredColumns: "Map every required target column without a default, or choose another file."
        case .noRows: "The file has no data rows to import."
        case .limits: "Import supports up to 10,000 rows, 256 mapped columns, 100,000 cells and 4 MiB of mapped values."
        case .draftChanged: "The file, mapping, options or target changed. Prepare a fresh SQL preview."
        case .fileTooLarge: "Choose a UTF-8 CSV or TSV file no larger than 8 MiB."
        case .fileRead: "The selected file could not be read."
        }
    }
}
