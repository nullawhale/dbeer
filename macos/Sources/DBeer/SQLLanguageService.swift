import Foundation

struct SQLCompletionRelation: Equatable, Sendable {
    var schema: String
    var name: String
    /// Adapter-provided catalog kinds: table, view or function.
    var kind: String
    var columns: [String] = []
}

struct SQLCompletionContext: Equatable, Sendable {
    var profileID: UUID?
    var catalog: [SQLCompletionRelation]
    static let empty = SQLCompletionContext(profileID: nil, catalog: [])
}

struct SQLCompletionItem: Equatable, Sendable {
    var label: String
    var detail: String? = nil
    var kind: Int? = nil
    var replacement: String
    var replacementRange: NSRange
    var insertText: String { replacement }
}

struct SQLLanguageDiagnostic: Equatable, Sendable {
    let range: NSRange
    let message: String
    let severity: Int
}

/// LSP positions and native editor ranges both count UTF-16 units. Line endings
/// are kept intact; CRLF is a single line break, and neither half is a column.
enum SQLLSPPosition {
    static func position(offset: Int, in text: String) -> SQLLSPJSON? {
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count else { return nil }
        if offset > 0, offset < units.count,
           (0xD800...0xDBFF).contains(units[offset - 1]), (0xDC00...0xDFFF).contains(units[offset]) { return nil }
        var line = 0, start = 0, index = 0
        while index < offset {
            if units[index] == 13 {
                if index + 1 < units.count, units[index + 1] == 10 {
                    guard index + 1 < offset else { return nil }
                    index += 1
                }
                line += 1
                start = index + 1
            } else if units[index] == 10 { line += 1; start = index + 1 }
            index += 1
        }
        return .object(["line": .int(line), "character": .int(offset - start)])
    }

    static func offset(position: SQLLSPJSON, in text: String) -> Int? {
        guard let targetLine = position["line"]?.integer, let column = position["character"]?.integer,
              targetLine >= 0, column >= 0 else { return nil }
        let units = Array(text.utf16)
        var line = 0, index = 0
        while line < targetLine, index < units.count {
            if units[index] == 13 {
                if index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                line += 1
            } else if units[index] == 10 { line += 1 }
            index += 1
        }
        guard line == targetLine else { return nil }
        let start = index
        while index < units.count, units[index] != 13, units[index] != 10 { index += 1 }
        guard column <= index - start else { return nil }
        let offset = start + column
        // Reject positions that would split a surrogate pair in NSTextStorage.
        if offset > 0, offset < units.count,
           (0xD800...0xDBFF).contains(units[offset - 1]), (0xDC00...0xDFFF).contains(units[offset]) { return nil }
        return offset
    }

    static func range(_ value: SQLLSPJSON, in text: String) -> NSRange? {
        guard let start = value["start"], let end = value["end"],
              let lower = offset(position: start, in: text), let upper = offset(position: end, in: text),
              upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}

/// One facade belongs to one SQLEditorState. Failure leaves the native editor
/// fully usable; a missing or slow helper simply produces no remote completion.
@MainActor
final class SQLLanguageService {
    static let maxDocumentBytes = 2 * 1_024 * 1_024
    private struct Document {
        let uri: String
        var text: String
        var engine: DatabaseEngine
        var context: SQLCompletionContext
        var version: Int
    }

    private let transport: SQLLSPTransport
    private var documents: [UUID: Document] = [:]
    private var sentVersions: [String: Int] = [:]
    private var sentContexts: [String: SQLCompletionContext] = [:]
    private var dirty: Set<UUID> = []
    private var closingURIs: Set<String> = []
    private var diagnosticValues: [UUID: [SQLLanguageDiagnostic]] = [:]
    private var observers: [UUID: @MainActor (UUID, [SQLLanguageDiagnostic]) -> Void] = [:]
    private var startup: Task<Bool, Never>?
    private var flushing: Task<Void, Never>?
    private var stopped = false
    private(set) var isAvailable = false

    init(helperURL: URL = BackendClient.bundledExecutableURL(), helperArguments: [String] = ["--language-server"],
         requestTimeout: Duration = .seconds(2)) {
        transport = SQLLSPTransport(executableURL: helperURL, arguments: helperArguments, requestTimeout: requestTimeout)
    }

    deinit {
        let transport = transport
        Task { await transport.shutdown() }
    }

    func update(documentID: UUID, text: String, engine: DatabaseEngine, context: SQLCompletionContext) {
        guard !stopped else { return }
        let otherDocumentBytes = documents.reduce(0) { $0 + ($1.key == documentID ? 0 : $1.value.text.utf8.count) }
        guard text.utf8.count <= Self.maxDocumentBytes, otherDocumentBytes + text.utf8.count <= 8 * 1_024 * 1_024,
              documents[documentID] != nil || documents.count < 32 else {
            close(documentID: documentID)
            return
        }
        if var document = documents[documentID] {
            guard document.text != text || document.engine != engine || document.context != context else { return }
            if document.engine != engine || document.context.profileID != context.profileID {
                closingURIs.insert(document.uri)
                document = Document(uri: Self.uri(documentID), text: text, engine: engine, context: context,
                                    version: document.version + 1)
            } else {
                document.text = text
                document.context = context
                document.version += 1
            }
            documents[documentID] = document
        } else {
            documents[documentID] = Document(uri: Self.uri(documentID), text: text, engine: engine, context: context, version: 1)
        }
        publish([], documentID: documentID)
        dirty.insert(documentID)
        scheduleFlush()
    }

    func close(documentID: UUID) {
        if let document = documents.removeValue(forKey: documentID) { closingURIs.insert(document.uri) }
        dirty.remove(documentID)
        publish([], documentID: documentID)
        diagnosticValues.removeValue(forKey: documentID)
        if !sentVersions.isEmpty { scheduleFlush() }
    }

    func diagnostics(documentID: UUID) -> [SQLLanguageDiagnostic] { diagnosticValues[documentID] ?? [] }

    @discardableResult
    func addDiagnosticsObserver(_ observer: @escaping @MainActor (UUID, [SQLLanguageDiagnostic]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeDiagnosticsObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func completion(documentID: UUID, offset: Int) async -> [SQLCompletionItem] {
        guard !stopped else { return [] }
        scheduleFlush()
        while let flushing { await flushing.value }
        guard isAvailable, let document = documents[documentID],
              sentVersions[document.uri] == document.version,
              let position = SQLLSPPosition.position(offset: offset, in: document.text) else { return [] }
        let response: SQLLSPJSON
        do {
            response = try await transport.request(method: "textDocument/completion", params: .object([
                "textDocument": .object(["uri": .string(document.uri)]), "position": position,
                "context": .object(["triggerKind": .int(1)])
            ]))
        } catch {
            if let failure = error as? SQLLSPError {
                switch failure {
                case .remoteError, .requestLimit: break
                default:
                    isAvailable = false
                    for id in Array(diagnosticValues.keys) { publish([], documentID: id) }
                    await transport.shutdown()
                }
            }
            return []
        }
        guard !Task.isCancelled, !stopped, let current = documents[documentID],
              current.uri == document.uri, current.version == document.version else { return [] }
        let items = response.array ?? response["items"]?.array ?? []
        return items.prefix(256).compactMap { item in
            guard let label = item["label"]?.string, !label.isEmpty else { return nil }
            let replacement: String
            let range: NSRange
            if let edit = item["textEdit"] {
                guard let newText = edit["newText"]?.string,
                      let value = edit["range"], let editRange = SQLLSPPosition.range(value, in: document.text) else { return nil }
                replacement = newText
                range = editRange
            } else {
                replacement = item["insertText"]?.string ?? label
                range = NSRange(location: offset, length: 0)
            }
            // The client does not advertise snippets or additional edits.
            guard item["insertTextFormat"]?.integer != 2, item["additionalTextEdits"] == nil else { return nil }
            return SQLCompletionItem(label: label, detail: item["detail"]?.string, kind: item["kind"]?.integer,
                                     replacement: replacement, replacementRange: range)
        }
    }

    func shutdown() async {
        stopped = true
        flushing?.cancel()
        startup?.cancel()
        documents.removeAll()
        dirty.removeAll()
        closingURIs.removeAll()
        sentVersions.removeAll()
        sentContexts.removeAll()
        for id in Array(diagnosticValues.keys) { publish([], documentID: id) }
        isAvailable = false
        await transport.shutdown()
    }

    private static func uri(_ id: UUID) -> String { "dbeer-sql:///\(id.uuidString)/\(UUID().uuidString).sql" }

    private func ensureStarted() async -> Bool {
        guard !stopped else { return false }
        if let startup { return await startup.value }
        let task = Task { [weak self, transport] in
            do {
                try await transport.start { [weak self] message in await self?.receive(message) }
                guard let self, !self.stopped else { return false }
                self.isAvailable = true
                return true
            } catch {
                await transport.shutdown()
                return false
            }
        }
        startup = task
        return await task.value
    }

    private func scheduleFlush() {
        guard !stopped, flushing == nil, !dirty.isEmpty || !closingURIs.isEmpty else { return }
        flushing = Task { [weak self] in
            guard let self else { return }
            defer { self.flushing = nil }
            guard await self.ensureStarted(), !Task.isCancelled, !self.stopped else { return }
            do {
                while !self.dirty.isEmpty || !self.closingURIs.isEmpty {
                    if let uri = self.closingURIs.first {
                        self.closingURIs.remove(uri)
                        self.sentContexts.removeValue(forKey: uri)
                        if self.sentVersions.removeValue(forKey: uri) != nil {
                            try await self.transport.notify(method: "textDocument/didClose", params: .object([
                                "textDocument": .object(["uri": .string(uri)])
                            ]))
                        }
                        continue
                    }
                    guard !Task.isCancelled, !self.stopped, let id = self.dirty.first else { return }
                    self.dirty.remove(id)
                    guard let document = self.documents[id] else { continue }
                    if self.sentContexts[document.uri] != document.context {
                        try await self.transport.notify(method: "workspace/didChangeConfiguration", params: .object([
                            "settings": .object(["dbeer": .object([
                                "uri": .string(document.uri), "engine": .string(document.engine.rawValue),
                                "catalog": .array(Self.boundedCatalog(document.context.catalog))
                            ])])
                        ]))
                        self.sentContexts[document.uri] = document.context
                    }
                    if self.sentVersions[document.uri] == nil {
                        try await self.transport.notify(method: "textDocument/didOpen", params: .object([
                            "textDocument": .object(["uri": .string(document.uri), "languageId": .string("sql"),
                                                     "version": .int(document.version), "text": .string(document.text)])
                        ]))
                    } else {
                        try await self.transport.notify(method: "textDocument/didChange", params: .object([
                            "textDocument": .object(["uri": .string(document.uri), "version": .int(document.version)]),
                            "contentChanges": .array([.object(["text": .string(document.text)])])
                        ]))
                    }
                    self.sentVersions[document.uri] = document.version
                }
            } catch {
                self.isAvailable = false
                for id in Array(self.diagnosticValues.keys) { self.publish([], documentID: id) }
                await self.transport.shutdown()
            }
        }
    }

    private func receive(_ message: SQLLSPJSON) {
        if message["method"]?.string == "$/dbeerTransportClosed" {
            isAvailable = false
            for id in Array(diagnosticValues.keys) { publish([], documentID: id) }
            return
        }
        guard !stopped, message["method"]?.string == "textDocument/publishDiagnostics",
              let params = message["params"], let uri = params["uri"]?.string,
              let (id, document) = documents.first(where: { $0.value.uri == uri }),
              params["version"]?.integer == document.version else { return }
        let diagnostics = (params["diagnostics"]?.array ?? []).prefix(256).compactMap { value -> SQLLanguageDiagnostic? in
            guard let message = value["message"]?.string, let range = value["range"],
                  let nativeRange = SQLLSPPosition.range(range, in: document.text) else { return nil }
            return SQLLanguageDiagnostic(range: nativeRange, message: message, severity: value["severity"]?.integer ?? 1)
        }
        publish(diagnostics, documentID: id)
    }

    private func publish(_ diagnostics: [SQLLanguageDiagnostic], documentID: UUID) {
        diagnosticValues[documentID] = diagnostics
        for observer in Array(observers.values) { observer(documentID, diagnostics) }
    }

    /// Leave room for JSON escaping (up to six bytes per input byte), field
    /// names and framing. Truncation is deterministic and retains useful names
    /// when an unusually large already-loaded catalog exceeds server limits.
    static func boundedCatalog(_ catalog: [SQLCompletionRelation]) -> [SQLLSPJSON] {
        var remainingBytes = 3 * 1_024 * 1_024
        var remainingColumns = 32_768
        var result: [SQLLSPJSON] = []
        for relation in catalog {
            guard result.count < 2_048 else { break }
            guard ["table", "view", "function"].contains(relation.kind), !relation.name.isEmpty,
                  relation.name.utf8.count <= 1_024, relation.schema.utf8.count <= 1_024 else { continue }
            let entryBytes = 128 + 6 * (relation.schema.utf8.count + relation.name.utf8.count + relation.kind.utf8.count)
            guard entryBytes <= remainingBytes else { break }
            remainingBytes -= entryBytes
            var columns: [SQLLSPJSON] = []
            for column in relation.columns where column.utf8.count <= 1_024 {
                let columnBytes = 8 + 6 * column.utf8.count
                guard remainingColumns > 0, columnBytes <= remainingBytes else { break }
                remainingColumns -= 1
                remainingBytes -= columnBytes
                columns.append(.string(column))
            }
            result.append(.object(["schema": .string(relation.schema), "name": .string(relation.name),
                                   "kind": .string(relation.kind), "columns": .array(columns)]))
        }
        return result
    }
}
