import Foundation
import Testing
@testable import DBeer

private actor TransferCredentials: ConnectionCredentialStore {
    private var values: [UUID: String]
    private(set) var writes: [UUID] = []
    init(_ values: [UUID: String]) { self.values = values }
    func password(for id: UUID) -> String? { values[id] }
    func savePassword(_ password: String, for id: UUID) { values[id] = password; writes.append(id) }
    func deletePassword(for id: UUID) { values[id] = nil }
}

struct ProfileTransferTests {
    private func profile(engine: DatabaseEngine = .postgresql, ca: String? = nil) -> SavedConnection {
        SavedConnection(name: "Team \(engine.displayName)", settings: ConnectionSettings(host: "localhost",
            port: engine.defaultPort, database: engine.defaultDatabase, user: engine.defaultUser,
            password: "must-never-be-exported", sslMode: "verify-full", sslRootCert: ca, engine: engine))
    }

    @Test func portableProfilesContainNoSecretsOrUUIDsAndEveryPreviewGetsNewIdentity() throws {
        let profiles = [profile(), profile(engine: .mysql)]
        let data = try ProfileTransfer.encode(profiles)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("password") && !text.contains("privateKey") && !text.contains("must-never-be-exported"))
        #expect(profiles.allSatisfy { !text.contains($0.id.uuidString) })
        let first = try ProfileTransfer.preview(data)
        let second = try ProfileTransfer.preview(data)
        #expect(first.map { $0.profile.engine } == [.postgresql, .mysql])
        #expect(first.map { $0.profile.sslMode } == ["verify-full", "verify-full"])
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(profiles.map(\.id))))
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(first.allSatisfy { $0.profile.settings(password: "").password.isEmpty && !$0.requiresCASelection })
    }

    @Test func absentOrUnreadableCARequiresReplacementWhileTLSModeStaysIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ca = directory.appendingPathComponent("ca.pem")
        var imported = try #require(ProfileTransfer.preview(ProfileTransfer.encode([profile(ca: ca.path)])).first)
        #expect(imported.requiresCASelection)
        #expect(imported.profile.sslMode == "verify-full")
        try Data("public CA fixture".utf8).write(to: ca)
        #expect(!imported.requiresCASelection)
        imported.profile.sslRootCert = directory.path
        #expect(imported.requiresCASelection)
        imported.profile.sslRootCert = ca.path
        #expect(!imported.requiresCASelection && imported.profile.sslMode == "verify-full")
        try FileManager.default.removeItem(at: ca)
        #expect(imported.requiresCASelection)
    }

    @Test func strictPreviewRejectsCorruptionSecretsUnknownFieldsVersionsAndDuplicateKeys() throws {
        let data = try ProfileTransfer.encode([profile(engine: .mysql)])
        let base = String(decoding: data, as: UTF8.self)
        let invalid = ["{invalid", base.replacingOccurrences(of: "\"version\" : \(ProfileTransfer.currentVersion)", with: "\"version\" : 99"),
            base.replacingOccurrences(of: "\"engine\" : \"mysql\"", with: "\"engine\" : \"unknown\""),
            base.replacingOccurrences(of: "\"port\" : 3306", with: "\"port\" : 0"),
            base.replacingOccurrences(of: "\"verify-full\"", with: "\"prefer\""),
            base.replacingOccurrences(of: "\"name\" :", with: "\"password\" : \"hidden\", \"name\" :"),
            base.replacingOccurrences(of: "\"name\" :", with: "\"privateKey\" : \"hidden\", \"name\" :"),
            base.replacingOccurrences(of: "\"name\" :", with: "\"id\" : \"\(UUID().uuidString)\", \"name\" :"),
            base.replacingOccurrences(of: "\"name\" :", with: "\"futureField\" : true, \"name\" :"),
            base.replacingOccurrences(of: "\"engine\" :", with: "\"engine\" : \"postgresql\", \"engine\" :"),
            base.replacingOccurrences(of: "\"engine\" :", with: "\"engine\" : \"postgresql\", \"\\u0065ngine\" :")]
        for text in invalid {
            #expect(text != base)
            #expect(throws: ProfileTransferError.self) { _ = try ProfileTransfer.preview(Data(text.utf8)) }
        }
        #expect(throws: ProfileTransferError.self) { _ = try ProfileTransfer.preview(Data(repeating: 32, count: ProfileTransfer.maxFileBytes + 1)) }
    }

    @Test func profileFileReplacementIsAtomicPrivateAndLeavesNoTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("team.dbeer.json")
        try Data("old contents".utf8).write(to: url)
        try ProfileTransfer.write([profile()], to: url)
        #expect(try ProfileTransfer.preview(Data(contentsOf: url)).count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let original = try Data(contentsOf: url)
        var invalid = profile()
        invalid.port = 0
        #expect(throws: ProfileTransferError.self) { try ProfileTransfer.write([invalid], to: url) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @MainActor
    @Test func workspaceImportsOnlySelectedProfilesAndIgnoresUnselectedMissingCA() async throws {
        let existing = profile()
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [existing], selectedConnectionId: existing.id))
        let credentials = TransferCredentials([existing.id: "original-secret"])
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: credentials)
        let missingCA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let preview = try ProfileTransfer.preview(ProfileTransfer.encode([existing, profile(engine: .mysql, ca: missingCA)]))
        workspace.importPreview = preview
        #expect(!workspace.canImportProfiles)
        workspace.selectImportProfile(preview[1].id, selected: false)
        #expect(workspace.canImportProfiles)
        await workspace.importProfiles()
        #expect(workspace.importPreview == nil && workspace.importError == nil)
        let saved = await store.load().connections
        #expect(saved.count == 2)
        #expect(saved.contains(existing))
        let imported = try #require(saved.first { $0.id != existing.id })
        #expect(imported.engine == .postgresql && imported.name == existing.name)
        #expect(!preview.map(\.id).contains(imported.id))
        #expect(await credentials.password(for: existing.id) == "original-secret")
        #expect(await credentials.writes == [imported.id])
    }

    @MainActor
    @Test func emptySelectionNeverWritesAndSelectedMissingCAStillBlocksImport() async throws {
        let store = MemoryConnectionLibraryStore()
        let credentials = TransferCredentials([:])
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: credentials)
        let missingCA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let preview = try ProfileTransfer.preview(ProfileTransfer.encode([profile(), profile(engine: .mysql, ca: missingCA)]))
        workspace.importPreview = preview
        workspace.selectAllImportProfiles(false)
        #expect(workspace.selectedImportProfiles.isEmpty && !workspace.canImportProfiles)
        await workspace.importProfiles()
        #expect(workspace.importPreview?.count == 2 && workspace.importError == nil)
        #expect(await credentials.writes.isEmpty)
        workspace.selectAllImportProfiles(true)
        #expect(workspace.selectedImportProfiles.count == 2 && !workspace.canImportProfiles)
        await workspace.importProfiles()
        #expect(workspace.importPreview == preview && workspace.importError != nil)
        #expect(await store.load().connections.isEmpty)
        #expect(await credentials.writes.isEmpty)
    }

    @MainActor
    @Test func importingThroughTheLibraryNeverOverwritesAnExistingProfileOrCredential() async throws {
        let existing = profile()
        let store = MemoryConnectionLibraryStore(library: SavedConnectionLibrary(connections: [existing], selectedConnectionId: existing.id))
        let credentials = TransferCredentials([existing.id: "original-secret"])
        let preview = try ProfileTransfer.preview(ProfileTransfer.encode([existing]))
        #expect(await credentials.writes.isEmpty)
        let model = WorkspaceModel(connectionStore: store, credentialStore: credentials)
        for item in preview {
            #expect(await model.saveConnection(name: item.profile.name, settings: item.profile.settings(password: "")))
        }
        let importedID = try #require(model.selectedConnectionId)
        #expect(importedID != existing.id)
        #expect(model.savedConnections.count == 2)
        #expect(model.savedConnections.first { $0.id == existing.id } == existing)
        #expect(await credentials.password(for: existing.id) == "original-secret")
        #expect(await credentials.password(for: importedID) == "")
        #expect(await credentials.writes == [importedID])
    }
}
