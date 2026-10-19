import Foundation
import Testing
@testable import DBeer

struct SQLCompletionCatalogTests {
    @Test func connectedSnapshotIncludesColumnsAndReplacesStaleObjects() {
        var catalog = SQLCompletionCatalog()
        let profile = UUID(), other = UUID()
        let request = CatalogRequest(kind: "completion")
        let records = [["schema": "public", "name": "orders", "kind": "table", "columns": "[\"id\",\"Display Name\",\"a\\\"b\",\"空\"]"],
                       ["schema": "public", "name": "totals", "kind": "view", "columns": "[\"total\"]"],
                       ["schema": "public", "name": "calculate", "kind": "function", "columns": "[]"]]
        catalog.record(records, request: request, profileID: profile)
        catalog.record(records, request: request, profileID: other)
        #expect(catalog.context(profileID: profile).catalog.first { $0.name == "orders" }?.columns == ["id", "Display Name", "a\"b", "空"])
        catalog.record([["schema": "public", "name": "orders", "kind": "table", "columns": "[\"new_column\"]"]],
            request: request, profileID: profile)
        #expect(catalog.context(profileID: profile).catalog == [
            SQLCompletionRelation(schema: "public", name: "orders", kind: "table", columns: ["new_column"])
        ])
        #expect(catalog.context(profileID: other).catalog.count == 3)
        catalog.record([], request: request, profileID: profile)
        #expect(catalog.context(profileID: profile).catalog.isEmpty)
    }

    @Test func onlyRequestedMetadataIsSharedAndProfilesStaySeparate() {
        var catalog = SQLCompletionCatalog()
        let first = UUID(), second = UUID()
        #expect(catalog.context(profileID: first).catalog.isEmpty)
        catalog.record([["name": "users", "kind": "table"]],
            request: CatalogRequest(kind: "objects", schema: "public", objectKind: "table"), profileID: first)
        catalog.record([["name": "id"], ["name": "Display Name"]],
            request: CatalogRequest(kind: "columns", schema: "public", object: "users", objectKind: "table"), profileID: first)
        catalog.record([["schema": "analytics", "name": "daily", "kind": "view"],
                        ["schema": "public", "name": "unsafe_trigger", "kind": "trigger"]],
            request: CatalogRequest(kind: "search", search: "daily"), profileID: first)
        let context = catalog.context(profileID: first)
        #expect(context.profileID == first)
        #expect(context.catalog.map(\.name) == ["daily", "users"])
        #expect(context.catalog.last?.columns == ["id", "Display Name"])
        #expect(catalog.context(profileID: second).catalog.isEmpty)
        #expect(catalog.context(profileID: nil) == .empty)
        catalog.remove(profileID: first)
        #expect(catalog.context(profileID: first).catalog.isEmpty)
    }

    @Test func refreshDropsRemovedObjectsAndReplacesColumnsWithoutMixingSchemas() {
        var catalog = SQLCompletionCatalog()
        let profile = UUID()
        for schema in ["public", "other"] {
            catalog.record([["name": "users", "kind": "table"], ["name": "removed", "kind": "table"]],
                request: CatalogRequest(kind: "objects", schema: schema, objectKind: "table"), profileID: profile)
            catalog.record([["name": "old"], ["name": "id"]],
                request: CatalogRequest(kind: "columns", schema: schema, object: "users", objectKind: "table"), profileID: profile)
        }
        catalog.record([["name": "users", "kind": "table"]],
            request: CatalogRequest(kind: "objects", schema: "public", objectKind: "table"), profileID: profile)
        catalog.record([["name": "new"]],
            request: CatalogRequest(kind: "columns", schema: "public", object: "users", objectKind: "table"), profileID: profile)
        #expect(catalog.context(profileID: profile).catalog.count == 3)
        #expect(catalog.context(profileID: profile).catalog.first { $0.schema == "public" }?.columns == ["new"])
        catalog.record([["name": "public"]], request: CatalogRequest(kind: "schemas"), profileID: profile)
        #expect(catalog.context(profileID: profile).catalog.count == 1)
    }

    @Test @MainActor func requestingEditorContextDoesNotCreateDatabaseSessions() async throws {
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), helperFactory: {
                Issue.record("Editor metadata must not start the database helper")
                return BackendClient(executableURL: URL(fileURLWithPath: "/nonexistent/dbeer-helper"))
            })
        let profile = UUID()
        let document = workspace.newDocument(profileID: profile, text: "SELECT * FROM users")
        await workspace.loadCompletionCatalog(profile)
        #expect(workspace.completionContext(profileID: profile).catalog.isEmpty)
        #expect(workspace.completions(profileID: profile).isEmpty)
        #expect(workspace.services.isEmpty && document.runtime == nil)
        await workspace.shutdown()
    }
}
