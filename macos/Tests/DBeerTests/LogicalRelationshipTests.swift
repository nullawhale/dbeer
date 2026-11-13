import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct LogicalRelationshipTests {
    private func profile(_ name: String = "Source", engine: DatabaseEngine = .postgresql) -> SavedConnection {
        SavedConnection(name: name, settings: .init(host: "do-not-copy-host.example", port: engine.defaultPort,
            database: "private-database", user: "private-user", password: "never-persist-password", sslMode: "disable", engine: engine))
    }
    private func endpoint(_ profile: SavedConnection, _ name: String) -> LogicalRelationshipEndpoint {
        .init(profile: profile, reference: .init(schema: profile.engine == .sqlite ? "main" : "public", name: name, kind: "table"))
    }
    private func relationship(_ source: SavedConnection, _ target: SavedConnection) -> LogicalRelationship {
        .init(name: "Confirmed composite link", source: endpoint(source, "orders"), target: endpoint(target, "customers"),
              columns: [.init(source: "tenant_id", target: "tenant", sourceType: "numeric(40,0)", targetType: "numeric(40,0)"),
                        .init(source: "customer_id", target: "id", sourceType: "text", targetType: "text")])
    }
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logical-links-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.json")
    }

    @Test func confirmedCompositeCrossProfileIntentRestoresPrivatelyWithoutConnections() async throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = profile(), second = profile("Target", engine: .mysql)
        let link = relationship(first, second)
        let store = LogicalRelationshipStore(fileURL: url)
        await store.load(); try await store.saveConfirmed(link)
        let restored = LogicalRelationshipStore(fileURL: url)
        await restored.load()
        #expect(restored.isLoaded && restored.relationships == [link])
        #expect(restored.relationships.first?.isCrossProfile == true)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("never-persist-password") && !text.contains("do-not-copy-host.example") && !text.contains("private-user"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
    }

    @Test func exactNamesAndProfileBindingsDoNotCollapseOrSilentlyRebind() throws {
        var source = profile(); let target = profile("Target")
        let first = relationship(source, target)
        var changed = first
        changed.columns[0].source = "\u{00e9}"
        var decomposed = changed; decomposed.columns[0].source = "e\u{0301}"
        #expect(changed != decomposed)
        let a = endpoint(source, "\u{00e9}"), b = endpoint(source, "e\u{0301}")
        #expect(Set([a, b]).count == 2)
        source.name = "Human label renamed"
        #expect(first.source.matches(source))
        source.host = "another-server.example"
        #expect(!first.source.matches(source))
        var duplicate = first; duplicate.columns.append(first.columns[0])
        #expect(!duplicate.isValid)
        let bytes = try JSONEncoder().encode(first)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["serverConstraint"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LogicalRelationship.self, from: unknown) }
    }

    @Test func staleWritersAndMalformedLibrariesPreserveOriginalBytesAndDrafts() async throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = profile(), target = profile("Target")
        let a = LogicalRelationshipStore(fileURL: url), b = LogicalRelationshipStore(fileURL: url)
        await a.load(); await b.load()
        let link = relationship(source, target)
        try await a.saveConfirmed(link)
        let original = try Data(contentsOf: url)
        var other = link; other.id = UUID(); other.name = "A stale writer"
        do { try await b.saveConfirmed(other); Issue.record("A stale library instance overwrote the confirmed link.") }
        catch { #expect(error as? LogicalRelationshipError == .changed) }
        let retained = try Data(contentsOf: url)
        #expect(b.relationships.isEmpty && retained == original)
        let future = Data("{\"version\":999,\"relationships\":[]}".utf8)
        try future.write(to: url)
        let futureStore = LogicalRelationshipStore(fileURL: url)
        await futureStore.load()
        #expect(!futureStore.isLoaded && futureStore.error != nil)
        do { try await futureStore.saveConfirmed(link); Issue.record("A future library was replaced.") }
        catch { #expect(error as? LogicalRelationshipError == .busy) }
        let futureRetained = try Data(contentsOf: url)
        #expect(futureRetained == future)
        let duplicate = Data("{\"version\":1,\"version\":1,\"relationships\":[]}".utf8)
        try duplicate.write(to: url)
        let duplicateStore = LogicalRelationshipStore(fileURL: url); await duplicateStore.load()
        #expect(!duplicateStore.isLoaded && duplicateStore.error != nil)
        #expect(try Data(contentsOf: url) == duplicate)
    }

    @Test func credentialProviderAndKeyRotationDoNotPersistOrRebindConnectionIdentity() throws {
        var saved = profile()
        saved.ssh = .init(host: "tunnel.example", user: "fixture", authMethod: .privateKey, identityFile: "/synthetic/secret-key-one")
        saved.passwordCommand = .init(executable: "/synthetic/provider-one", arguments: ["secret-provider-argument-one"])
        let bound = endpoint(saved, "orders")
        saved.ssh?.identityFile = "/synthetic/secret-key-two"
        saved.passwordCommand = .init(executable: "/synthetic/provider-two", arguments: ["secret-provider-argument-two"])
        #expect(bound.matches(saved))
        let encoded = String(decoding: try JSONEncoder().encode(bound), as: UTF8.self)
        #expect(!encoded.contains("synthetic") && !encoded.contains("provider") && !encoded.contains("secret-key"))
        saved.ssh?.host = "replacement-tunnel.example"
        #expect(!bound.matches(saved))
    }

    @Test func symlinkLibrariesCannotSupplyOrReceiveConfirmedIntent() async throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outside = url.deletingLastPathComponent().appendingPathComponent("outside.json")
        let original = Data("{\"version\":1,\"relationships\":[]}".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        let store = LogicalRelationshipStore(fileURL: url)
        await store.load()
        #expect(!store.isLoaded && store.error != nil)
        let outsideRetained = try Data(contentsOf: outside)
        #expect(outsideRetained == original)
    }

    @Test func inferenceStaysUnconfirmedUntilExplicitFreshValidationAndSave() async throws {
        let url = try temporaryURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = profile(), target = profile("Target", engine: .mysql)
        var reads = 0
        let store = LogicalRelationshipStore(fileURL: url); await store.load()
        let editor = LogicalRelationshipEditorModel(sourceProfileID: source.id, reference: .init(schema: "public", name: "orders", kind: "table"),
            profiles: { [source, target] }, mayStart: { true }, isCurrent: { true }, reader: { endpoint, _ in
                reads += 1
                return endpoint.profileID == source.id
                    ? [.init(name: "customer_id", nativeType: "bigint", nullable: true, primaryKeyPosition: nil)]
                    : [.init(name: "id", nativeType: "bigint", nullable: false, primaryKeyPosition: 1)]
            }, cancel: { _, _ in })
        editor.targetProfileID = target.id; editor.targetSchema = "public"; editor.targetName = "customers"
        #expect(reads == 0 && !editor.canConfirm)
        await editor.loadColumns(); editor.inferSuggestions()
        #expect(reads == 2 && editor.suggestions.count == 1 && store.relationships.isEmpty)
        editor.choose(try #require(editor.suggestions.first))
        #expect(!editor.canConfirm && store.relationships.isEmpty)
        await editor.validate()
        #expect(reads == 4 && editor.canConfirm)
        await editor.confirm(in: store)
        #expect(editor.saved && store.relationships.count == 1 && store.relationships.first?.origin == .nameTypeSuggestion)
        editor.columns[0].source = "changed"
        #expect(!editor.canConfirm)
    }

    @Test func changedProfilesAndCanceledReadsCannotConfirmStaleMapping() async throws {
        @MainActor final class Gate {
            var entered = false
            var continuation: CheckedContinuation<Void, Never>?
            func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
            func release() { continuation?.resume(); continuation = nil }
        }
        let source = profile(), target = profile("Target")
        var profiles = [source, target]
        let gate = Gate(); var reads = 0; var cancels = 0
        let editor = LogicalRelationshipEditorModel(relationship: relationship(source, target), profiles: { profiles }, mayStart: { true }, isCurrent: { true },
            reader: { _, pending in
                reads += 1; pending.submitted = true
                await gate.wait(); pending.submitted = false
                return [.init(name: "id", nativeType: "text", nullable: false, primaryKeyPosition: 1)]
            }, cancel: { _, _ in cancels += 1 })
        let task = Task { await editor.validate() }
        for _ in 0..<1_000 { if gate.entered { break }; await Task.yield() }
        #expect(gate.entered)
        profiles[0].host = "replacement.example"
        editor.stop(); gate.release(); await task.value
        #expect(reads == 1 && cancels == 1 && !editor.canConfirm && !editor.isReading)
    }
}
