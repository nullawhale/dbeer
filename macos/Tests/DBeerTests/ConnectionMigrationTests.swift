import Foundation
import Testing
@testable import DBeer

struct ConnectionMigrationTests {
    private func legacy(id: UUID, selected: UUID? = nil) -> Data {
        Data("""
        {"connections":[{"id":"\(id.uuidString)","name":"Team database","host":"localhost",
        "port":5432,"database":"postgres","user":"postgres","sslMode":"verify-full"}],
        "selectedConnectionId":"\((selected ?? id).uuidString)"}
        """.utf8)
    }

    @Test func unversionedProfilesMigrateAtomicallyWithExactBackupAndOriginalUUID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("connections.json")
        let id = UUID()
        let original = legacy(id: id)
        try original.write(to: url)
        let store = FileConnectionLibraryStore(fileURL: url)
        let migrated = try await store.load()
        #expect(migrated.version == 2)
        #expect(migrated.selectedConnectionId == id)
        #expect(migrated.connections.first?.id == id)
        #expect(migrated.connections.first?.engine == .postgresql)
        #expect(migrated.connections.first?.settings(password: "retained-in-keychain").engine == .postgresql)
        let backup = url.appendingPathExtension("v1.backup")
        #expect(try Data(contentsOf: backup) == original)
        let written = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect(!String(decoding: written, as: UTF8.self).contains("password"))
        #expect(try await store.load() == migrated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
        for file in [url, backup] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    @Test func existingBackupIsNeverReplacedByAnotherLegacyMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("connections.json")
        let backup = url.appendingPathExtension("v1.backup")
        let previous = Data("original older backup".utf8)
        try previous.write(to: backup)
        let original = legacy(id: UUID())
        try original.write(to: url)
        _ = try await FileConnectionLibraryStore(fileURL: url).load()
        #expect(try Data(contentsOf: backup) == previous)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "backup" && $0.lastPathComponent != backup.lastPathComponent }
        #expect(backups.count == 1)
        let newBackup = try #require(backups.first)
        #expect(try Data(contentsOf: newBackup) == original)
    }

    @Test func unknownVersionCorruptionAndMissingV2EngineCannotBeOverwritten() async throws {
        let id = UUID()
        let invalidFiles = [Data("{ invalid".utf8),
            Data("{\"version\":99,\"connections\":[]}".utf8),
            Data(("{\"version\":2," + String(decoding: legacy(id: id), as: UTF8.self).dropFirst()).utf8),
            Data(String(decoding: legacy(id: id), as: UTF8.self)
                .replacingOccurrences(of: "\"port\":5432", with: "\"port\":0").utf8)]
        for data in invalidFiles {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("connections.json")
            try data.write(to: url)
            let store = FileConnectionLibraryStore(fileURL: url)
            await #expect(throws: ConnectionLibraryError.self) { _ = try await store.load() }
            await #expect(throws: ConnectionLibraryError.self) { try await store.save(SavedConnectionLibrary()) }
            #expect(try Data(contentsOf: url) == data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["connections.json"])
        }
    }

    @Test func engineIdentitySurvivesRoundTripAndDistinguishesOtherwiseIdenticalProfiles() throws {
        let postgres = ConnectionSettings(host: "localhost", port: 5432, database: "work", user: "user",
            password: "secret", sslMode: "verify-full")
        var mysql = postgres
        mysql.engine = .mysql
        let profile = SavedConnection(name: "MySQL", settings: mysql)
        #expect(!profile.matches(postgres))
        #expect(profile.matches(mysql))
        #expect(profile.settings(password: "secret") == mysql)
        #expect(try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(profile)) == profile)
    }

    @Test func enginePickerUpdatesOnlyUntouchedDefaultsAndUsesSupportedTLSModes() {
        var draft = ConnectionDraft(connection: nil)
        draft.name = "MySQL"
        draft.sslMode = "prefer"
        draft.selectEngine(.mysql)
        #expect(draft.port == "3306" && draft.database == "mysql" && draft.user == "root")
        #expect(draft.sslMode == "verify-full")
        #expect(draft.settings?.engine == .mysql)
        draft.port = "13306"
        draft.database = "team"
        draft.user = "analyst"
        draft.selectEngine(.postgresql)
        #expect(draft.port == "13306" && draft.database == "team" && draft.user == "analyst")
        #expect(draft.settings?.engine == .postgresql)
        draft.selectEngine(.mysql)
        draft.sslMode = "prefer"
        #expect(draft.settings == nil)
    }
}
