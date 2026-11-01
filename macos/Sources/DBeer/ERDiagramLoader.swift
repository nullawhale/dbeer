import Foundation

/// Injectable connected-only metadata provider; builds never request user rows.
@MainActor
enum ERDiagramLoader {
    typealias Provider = @MainActor (CatalogRequest) async throws -> BackendMessage
    static func load(_ model: ERDiagramModel, context: ERDiagramLoadContext,
                     isCurrent: @MainActor () -> Bool, provider: Provider, retryFailuresOnly: Bool = false) async {
        model.beginLoad(retryingFailures: retryFailuresOnly)
        model.context = context
        let generation = model.generation
        let tables = model.stored.tables
        func current() -> Bool { !Task.isCancelled && model.generation == generation && model.context == context && isCurrent() && model.stored.tables == tables }
        defer {
            if model.generation == generation {
                model.isLoading = false
                if current() { model.autoLayout() }
            }
        }
        var columnsUsed = model.metadata.values.reduce(0) { $0 + $1.columns.count }
        var keysUsed = model.metadata.values.reduce(0) { $0 + $1.foreignKeys.count }
        var bytesUsed = model.metadata.values.reduce(0) { $0 + $1.retainedBytes }
        for table in tables {
            guard current() else { return }
            if retryFailuresOnly, let previous = model.metadata[table], previous.columnState.isAvailable, previous.relationshipState.isAvailable {
                model.progress += 1; await Task.yield(); continue
            }
            var facts = ERTableMetadata(table: table)
            do {
                let response = try await provider(CatalogRequest(kind: "columns", schema: table.schema, object: table.name, objectKind: "table"))
                guard current() else { return }
                facts.columns = try ERDiagramMetadata.columns(response)
                if facts.columns.isEmpty {
                    // An empty column list does not establish visibility or existence.
                    let lookup = try await provider(CatalogRequest(kind: "search", schema: table.schema, search: table.name))
                    guard current() else { return }
                    guard lookup.truncated != true, lookup.catalogRecords.contains(where: {
                        Data(($0["schema"] ?? "").utf8) == Data(table.schema.utf8) &&
                        Data(($0["name"] ?? "").utf8) == Data(table.name.utf8) && $0["kind"] == "table"
                    }) else { throw ERDiagramFailure("An empty column response cannot confirm this table's availability. Narrow the search or check metadata permissions.") }
                }
                facts.columnState = ERDiagramMetadata.notice(response).map(ERMetadataState.partial) ?? .available
            } catch {
                guard current() else { return }
                facts.columnState = .unavailable(safeError(error, collection: "Column"))
            }
            do {
                let response = try await provider(CatalogRequest(kind: "foreignKeys", schema: table.schema, object: table.name, objectKind: "table"))
                guard current() else { return }
                facts.foreignKeys = try TableForeignKey.parse(response)
                facts.relationshipState = ERDiagramMetadata.notice(response).map(ERMetadataState.partial) ?? .available
            } catch {
                guard current() else { return }
                facts.relationshipState = .unavailable(safeError(error, collection: "Foreign-key"))
            }
            guard columnsUsed + facts.columns.count <= ERDiagramLimits.columns,
                  keysUsed + facts.foreignKeys.count <= ERDiagramLimits.relationships,
                  bytesUsed + facts.retainedBytes <= ERDiagramLimits.metadataBytes else {
                model.notice = "Diagram metadata limit reached. Remaining selected tables are not loaded; narrow the area and Build again."
                return
            }
            columnsUsed += facts.columns.count; keysUsed += facts.foreignKeys.count; bytesUsed += facts.retainedBytes
            model.setMetadata(facts); model.progress += 1
            await Task.yield()
        }
        guard current() else { return }
        model.notice = "Metadata is a best-effort read. Arrows point from FK to referenced table; no cardinality is inferred. Incoming keys from unselected tables are outside this diagram's scope."
    }
    private static func safeError(_ error: Error, collection: String) -> String {
        if let failure = error as? ERDiagramFailure { return failure.message }
        if let failure = error as? TableNavigationFailure { return failure.message }
        return collection + " metadata is unavailable. Retry or check table visibility and permissions."
    }
}
