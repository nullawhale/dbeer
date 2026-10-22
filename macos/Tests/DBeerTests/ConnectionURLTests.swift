import Foundation
import Testing
@testable import DBeer

/// URL parsing, draft updates and in-memory profile storage only. No UI,
/// database connections, native credential access or application activation.
@MainActor
struct ConnectionURLTests {
    @Test(arguments: ["postgres", "postgresql", "jdbc:postgresql"])
    func postgresURLsDecodeCredentialsAndTLS(scheme: String) throws {
        let url = try ConnectionURL.parse("\(scheme)://reader%40team:p%40ss%3Aword@db.example.test:5433/team%2Fdata?sslmode=verify-ca&sslrootcert=%2Ffixtures%2Fteam%20ca.pem")
        #expect(url.engine == .postgresql && url.host == "db.example.test" && url.port == 5433)
        #expect(url.database == "team/data" && url.user == "reader@team")
        let passwordDecoded = url.password == "p@ss:word"
        #expect(passwordDecoded)
        #expect(url.sslMode == "verify-ca" && url.sslRootCert == "/fixtures/team ca.pem")
    }

    @Test(arguments: ["mysql", "jdbc:mysql"])
    func mysqlURLsAcceptNativeAndJDBCTLSOptions(scheme: String) throws {
        let modeName = scheme.hasPrefix("jdbc:") ? "sslMode" : "ssl-mode"
        let url = try ConnectionURL.parse("\(scheme)://db.example.test/warehouse?user=reader&password=fixture&\(modeName)=VERIFY_IDENTITY&ssl-ca=%2Ffixtures%2Fca.pem")
        #expect(url.engine == .mysql && url.port == 3306 && url.database == "warehouse")
        #expect(url.user == "reader" && url.sslMode == "verify-full" && url.sslRootCert == "/fixtures/ca.pem")
        let passwordDecoded = url.password == "fixture"
        #expect(passwordDecoded)
    }

    @Test(arguments: ["DISABLED", "REQUIRED", "VERIFY_CA", "VERIFY_IDENTITY"])
    func mysqlTLSModesRetainTheirMeaning(mode: String) throws {
        let expected = ["DISABLED": "disable", "REQUIRED": "require", "VERIFY_CA": "verify-ca", "VERIFY_IDENTITY": "verify-full"]
        let url = try ConnectionURL.parse("mysql://host.test/db?ssl-mode=\(mode)")
        #expect(url.sslMode == expected[mode])
    }

    @Test func queryCredentialsDecodeOnceAndRespectJDBCPlusEncoding() throws {
        let native = try ConnectionURL.parse("postgresql://host.test/db?user=reader+team&password=p%2540%2Bq")
        let jdbc = try ConnectionURL.parse("jdbc:postgresql://host.test/db?user=reader+team&password=p%2540%2Bq")
        #expect(native.user == "reader+team" && jdbc.user == "reader team")
        let nativePasswordDecodedOnce = native.password == "p%40+q"
        let jdbcPasswordDecodedOnce = jdbc.password == "p%40+q"
        #expect(nativePasswordDecodedOnce && jdbcPasswordDecodedOnce)
        let queryDatabase = try ConnectionURL.parse("postgresql://host.test?dbname=warehouse")
        #expect(queryDatabase.database == "warehouse")
    }

    @Test(arguments: ["postgresql", "mysql"])
    func IPv6AndEncodedDatabaseNamesRoundTripWithoutPasswords(scheme: String) throws {
        let engine: DatabaseEngine = scheme == "mysql" ? .mysql : .postgresql
        let formatted = try #require(ConnectionURL.format(engine: engine, host: "2001:db8::1", port: String(engine.defaultPort),
            database: "team/資料 ?#", user: "reader@team", sslMode: "verify-full", sslRootCert: "/fixtures/a+b & ca.pem"))
        let url = try ConnectionURL.parse(formatted)
        #expect(url.host == "2001:db8::1" && url.database == "team/資料 ?#" && url.user == "reader@team")
        #expect(url.sslMode == "verify-full" && url.sslRootCert == "/fixtures/a+b & ca.pem")
        #expect(url.password == nil && !formatted.contains("password"))
    }

    @Test(arguments: [
        "https://db.example.test/db", "cassandra://host.test/db",
        "postgresql://host.test/", "postgresql:///db", "postgresql://host.test:0/db",
        "postgresql://host.test:65536/db", "postgresql://host.test:9999999999999999999999999/db",
        "postgresql://host.test:/db", "postgresql://host.test:abc/db",
        "postgresql://one.test,two.test/db", "postgresql://one.test:5432,two.test:5432/db",
        "postgresql://host.test/a/b", "postgresql://host.test/db#fragment",
        "postgresql://host.test/db?password=%ZZ", "postgresql://host.test/db?password=%FF",
        "postgresql://host.test/db?password=%00", "postgresql://host.test/db?user",
        "postgresql://host.test/db?user=a&user=b", "postgresql://a@host.test/db?user=b",
        "postgresql://host.test/db?dbname=other", "postgresql://host.test/db?sslmode=invalid",
        "postgresql://host.test/db?sslmode=require&sslmode=disable", "postgresql://host.test/db?sslcert=client.pem",
        "postgresql://host.test/db?options=secret", "mysql://host.test/db?ssl-mode=PREFERRED",
        "mysql://host.test/db?ssl-mode=VERIFY_IDENTITY&sslMode=DISABLED", "mysql://host.test/db?useSSL=false"
    ])
    func unsupportedOrAmbiguousURLsAreRejected(input: String) {
        #expect(throws: ConnectionURL.Failure.self) { try ConnectionURL.parse(input) }
    }

    @Test func errorsNeverExposeRawURLsOrTheirContents() {
        let secret = "fixture-sensitive-value"
        for input in ["postgresql://reader:\(secret)@host.test:0/db", "mysql://host.test/db?\(secret)=1", "postgresql://host.test/db?password=\(secret)&sslmode=invalid"] {
            do {
                _ = try ConnectionURL.parse(input)
                Issue.record("Malformed URL was accepted")
            } catch {
                let redacted = !error.localizedDescription.contains(secret) && !error.localizedDescription.contains(input)
                #expect(redacted)
            }
        }
    }

    @Test func applyingURLPreservesUnspecifiedSettingsAndChangesOnlyTheDraft() throws {
        var draft = ConnectionDraft(connection: nil)
        draft.name = "Team"
        draft.user = "existing-reader"
        draft.password = "fixture-existing-password"
        draft.sslMode = "verify-ca"
        draft.sslRootCert = "/fixtures/ca.pem"
        draft.policy = ExecutionPolicy(environment: .production, readOnly: true)
        draft.sshEnabled = true
        draft.sshHost = "bastion.example.test"
        draft.sshUser = "operator"
        let sshId = draft.settings?.ssh?.profileId
        try draft.applyConnectionURL("postgresql://db.example.test:5440/warehouse")
        #expect(draft.host == "db.example.test" && draft.port == "5440" && draft.database == "warehouse")
        #expect(draft.name == "Team" && draft.user == "existing-reader" && draft.sslMode == "verify-ca")
        #expect(draft.sslRootCert == "/fixtures/ca.pem" && draft.policy.environment == .production && draft.policy.readOnly)
        #expect(draft.settings?.ssh?.profileId == sshId && draft.sshHost == "bastion.example.test")
        let passwordPreserved = draft.password == "fixture-existing-password"
        #expect(passwordPreserved)
        let preview = try #require(draft.connectionURL)
        let parsedPreview = try ConnectionURL.parse(preview)
        let previewHasNoPassword = !preview.contains(draft.password) && parsedPreview.password == nil
        #expect(previewHasNoPassword)
    }

    @Test func newProfilesCanSwitchEngineAndSavedProfilesRejectMismatchesAtomically() throws {
        var draft = ConnectionDraft(connection: nil)
        try draft.applyConnectionURL("jdbc:mysql://db.example.test/team?user=reader&password=fixture-url-password&sslMode=REQUIRED")
        #expect(draft.engine == .mysql && draft.port == "3306" && draft.user == "reader" && draft.sslMode == "require")
        let passwordImported = draft.password == "fixture-url-password"
        #expect(passwordImported)
        let source = SavedConnection(name: "Team", settings: try #require(draft.settings))
        var edit = ConnectionDraft(connection: source)
        edit.password = "fixture-current-password"
        let before = edit.settings
        #expect(throws: ConnectionURL.Failure.engineMismatch) {
            try edit.applyConnectionURL("postgresql://other.test/other?user=other&password=replacement")
        }
        let unchanged = edit.settings == before
        #expect(unchanged && edit.name == source.name && edit.engine == .mysql)
        #expect(throws: ConnectionURL.Failure.self) { try edit.applyConnectionURL("mysql://other.test/other?ssl-mode=PREFERRED") }
        let unchangedAfterBadTLS = edit.settings == before
        #expect(unchangedAfterBadTLS)
    }

    @Test func savingURLCredentialsKeepsSecretsOutOfProfileMetadata() async throws {
        let library = MemoryConnectionLibraryStore()
        let credentials = MemoryConnectionCredentialStore()
        let model = WorkspaceModel(connectionStore: library, credentialStore: credentials)
        var draft = ConnectionDraft(connection: nil)
        draft.name = "URL profile"
        try draft.applyConnectionURL("postgresql://reader:fixture-url-secret@db.example.test/team?sslmode=require")
        let settings = try #require(draft.settings)
        try #require(await model.saveConnection(name: draft.name, settings: settings))
        let id = try #require(model.selectedConnectionId)
        let savedPassword = await credentials.password(for: id) == "fixture-url-secret"
        #expect(savedPassword)
        let metadata = String(decoding: try JSONEncoder().encode(await library.load()), as: UTF8.self)
        let metadataHasNoSecret = !metadata.contains("fixture-url-secret") && !metadata.contains("postgresql://")
        #expect(metadataHasNoSecret)
        await model.shutdown()
    }
}
