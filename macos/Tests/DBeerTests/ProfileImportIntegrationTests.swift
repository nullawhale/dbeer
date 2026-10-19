import Foundation
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ProfileImportIntegrationTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
        !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty &&
        ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN"] == "1" &&
        !(ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN_PATH"] ?? "").isEmpty))
    func importsPreviewWithNewIdentitiesAndOwnCredentialsThenConnectsBothEngines() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-import-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let postgres = try postgresSettings(environment)
        let mysql = try mysqlSettings(environment)
        let keychainPath = environment["DBEER_TEST_KEYCHAIN_PATH"] ?? ""
        let credentials = KeychainConnectionCredentialStore(service: "dev.dbeer.tests.import." + UUID().uuidString,
            keychainURL: URL(fileURLWithPath: keychainPath))
        let store = FileConnectionLibraryStore(fileURL: directory.appendingPathComponent("connections.json"))
        let workspace = ApplicationWorkspace(connectionStore: store, credentialStore: credentials,
            helperFactory: { BackendClient(executableURL: executable) })
        var accounts: Set<UUID> = []
        do {
            await workspace.start()
            var originalSettings = postgres
            let originalSecret = "original-import-fixture-" + UUID().uuidString
            originalSettings.password = originalSecret
            let saved = await workspace.library.saveConnection(name: "Shared PostgreSQL", settings: originalSettings)
            try #require(saved, "Could not prepare the existing import fixture.")
            let existingID = try #require(workspace.library.selectedConnectionId)
            accounts.insert(existingID)
            let existing = try #require(workspace.library.savedConnections.first { $0.id == existingID })

            var portableMySQL = mysql
            if mysql.sslRootCert != nil {
                portableMySQL.sslRootCert = directory.appendingPathComponent("missing-public-ca.pem").path
            }
            let sourceProfiles = [existing, SavedConnection(name: "Shared MySQL", settings: portableMySQL)]
            let portable = try ProfileTransfer.encode(sourceProfiles)
            let portableText = String(decoding: portable, as: UTF8.self)
            let excludesSecrets = !portableText.contains("password") && !portableText.contains("privateKey") &&
                !portableText.contains(originalSecret) &&
                [postgres.password, mysql.password].filter { !$0.isEmpty }.allSatisfy { !portableText.contains($0) }
            let excludesUUIDs = sourceProfiles.allSatisfy { !portableText.contains($0.id.uuidString) }
            #expect(excludesSecrets)
            #expect(excludesUUIDs)
            let portableFile = directory.appendingPathComponent("shared-profiles.json")
            try portable.write(to: portableFile)
            workspace.importPreview = try ProfileTransfer.preview(Data(contentsOf: portableFile))
            let preview = try #require(workspace.importPreview)
            #expect(preview.count == 2)
            #expect(preview.map { $0.profile.engine } == [.postgresql, .mysql])
            #expect(preview.map { $0.profile.sslMode } == [postgres.sslMode, mysql.sslMode])
            let previewIdentitiesAreFresh = Set(preview.map(\.id)).isDisjoint(with: Set(sourceProfiles.map(\.id)))
            #expect(previewIdentitiesAreFresh)
            let previewDidNotWrite = workspace.library.savedConnections == [existing]
            #expect(previewDidNotWrite)
            let originalSecretBeforeImport = try await credentials.password(for: existingID) == originalSecret
            #expect(originalSecretBeforeImport)

            if let ca = mysql.sslRootCert {
                let mysqlPreviewIndex = try #require(workspace.importPreview?.firstIndex { $0.profile.engine == .mysql })
                #expect(workspace.importPreview?[mysqlPreviewIndex].requiresCASelection == true)
                await workspace.importProfiles()
                let missingCABlockedImport = workspace.library.savedConnections == [existing] && workspace.importError != nil
                #expect(missingCABlockedImport)
                // The native CA chooser only assigns this public path. Avoid a
                // modal panel while exercising the same pre-import state.
                workspace.importPreview?[mysqlPreviewIndex].profile.sslRootCert = ca
                #expect(workspace.importPreview?[mysqlPreviewIndex].requiresCASelection == false)
                #expect(workspace.importPreview?[mysqlPreviewIndex].profile.sslMode == "verify-full")
            }

            await workspace.importProfiles()
            accounts.formUnion(workspace.library.savedConnections.map(\.id))
            #expect(workspace.importPreview == nil && workspace.importError == nil)
            let imported = workspace.library.savedConnections.filter { $0.id != existingID }
            try #require(imported.count == 2, "The workspace did not import both profile fixtures.")
            let importedIdentitiesAreFresh = Set(imported.map(\.id)).isDisjoint(with: Set(sourceProfiles.map(\.id)))
            #expect(importedIdentitiesAreFresh)
            let existingProfilePreserved = workspace.library.savedConnections.first { $0.id == existingID } == existing
            let existingSecretPreserved = try await credentials.password(for: existingID) == originalSecret
            #expect(existingProfilePreserved)
            #expect(existingSecretPreserved)

            for engine in [DatabaseEngine.postgresql, .mysql] {
                let importedProfile = try #require(imported.first { $0.engine == engine })
                let settings = engine == .postgresql ? postgres : mysql
                let emptyImportedSecret = try await credentials.password(for: importedProfile.id) == ""
                #expect(emptyImportedSecret)
                #expect(importedProfile.sslMode == settings.sslMode)
                #expect(importedProfile.sslRootCert == settings.sslRootCert)
                let edited = await workspace.library.saveConnection(name: importedProfile.name,
                    settings: settings, id: importedProfile.id)
                try #require(edited, "Could not save the imported profile's own credentials.")
                let ownCredentialSaved = try await credentials.password(for: importedProfile.id) == settings.password
                #expect(ownCredentialSaved)
                await workspace.connectProfile(importedProfile.id)
                let service = try #require(workspace.services[importedProfile.id])
                try #require(service.connectionState == .connected, "The imported service session did not connect.")
                let document = workspace.newDocument(profileID: importedProfile.id, text: "SELECT 1")
                await workspace.run(document)
                let runtime = try #require(document.runtime)
                let querySucceeded = runtime.queryFailure == nil && runtime.result?.rows == [["1"]]
                #expect(querySucceeded)
                #expect(runtime.connectionState == .connected && runtime.engine == engine)
                #expect(runtime.sessionId != nil && runtime.sessionId != service.sessionId)
            }
            let durable = try await FileConnectionLibraryStore(fileURL: directory.appendingPathComponent("connections.json")).load()
            #expect(Set(durable.connections.map(\.id)) == accounts)
            let originalCredentialStillPreserved = try await credentials.password(for: existingID) == originalSecret
            let originalStillPreserved = durable.connections.first { $0.id == existingID } == existing &&
                originalCredentialStillPreserved
            #expect(originalStillPreserved)
            await workspace.shutdown()
            for id in accounts { try await credentials.deletePassword(for: id) }
        } catch {
            accounts.formUnion(workspace.library.savedConnections.map(\.id))
            await workspace.shutdown()
            for id in accounts { try? await credentials.deletePassword(for: id) }
            throw error
        }
    }

    private func postgresSettings(_ environment: [String: String]) throws -> ConnectionSettings {
        guard let components = URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""),
              let host = components.host, let user = components.user else { throw FixtureError.configuration }
        let options = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last })
        return ConnectionSettings(host: host, port: components.port ?? 5432,
            database: String(components.path.dropFirst()), user: user, password: components.password ?? "",
            sslMode: options["sslmode"] ?? "verify-full", sslRootCert: options["sslrootcert"])
    }

    private func mysqlSettings(_ environment: [String: String]) throws -> ConnectionSettings {
        guard let port = Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "") else { throw FixtureError.configuration }
        let ca = environment["DBEER_TEST_MYSQL_CA_FILE"].flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil }
        return ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
            port: port,
            database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
            password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
            sslMode: ca != nil ? "verify-full" : (environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable"),
            sslRootCert: ca, engine: .mysql)
    }

    private enum FixtureError: Error { case configuration }
}
