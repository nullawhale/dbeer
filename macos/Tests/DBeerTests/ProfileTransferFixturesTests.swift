import Foundation
import Testing
@testable import DBeer

/// Shared, synthetic Swift/Rust interoperability fixtures. No credential store
/// or database is opened. Execution is deferred to final integration.
struct ProfileTransferFixturesTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/profile-transfer")
    }
    @Test func macWindowsLinuxMacStagesPreserveSettingsPoliciesAndFreshIdentity() throws {
        var identities = Set<UUID>()
        for name in ["mac-export", "windows-remapped", "linux-remapped", "mac-return"] {
            let data = try Data(contentsOf: root.appendingPathComponent(name + "-v2.json"))
            let rows = try ProfileTransfer.preview(data)
            #expect(rows.count == 3)
            #expect(rows.allSatisfy { identities.insert($0.id).inserted })
            #expect(rows[0].profile.engine == .postgresql && rows[0].profile.port == 5432)
            #expect(rows[0].profile.sslMode == "verify-full" && rows[0].profile.policy == ExecutionPolicy(environment: .production, readOnly: true))
            #expect(rows[1].profile.engine == .mysql && rows[1].profile.port == 3306)
            #expect(rows[1].profile.sslMode == "verify-ca" && rows[1].profile.policy == ExecutionPolicy(environment: .staging, readOnly: false))
            #expect(rows[2].profile.sslRootCert == nil && rows[2].profile.port == 65535)
            let exported = try ProfileTransfer.encode(rows.map(\.profile))
            var expected = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            expected["version"] = ProfileTransfer.currentVersion
            #expect(try JSONSerialization.jsonObject(with: exported) as? NSDictionary == expected as NSDictionary)
            let text = String(decoding: exported, as: UTF8.self)
            #expect(!text.contains("password") && !text.contains("privateKey"))
            #expect(rows.allSatisfy { !text.contains($0.id.uuidString) })
        }
    }
    @Test func legacyOmittedAndNullPolicyUseSwiftDefaultsAndExplicitValuesSurvive() throws {
        let rows = try ProfileTransfer.preview(Data(contentsOf: root.appendingPathComponent("legacy-v1.json")))
        #expect(rows[0].profile.policy == ExecutionPolicy())
        #expect(rows[1].profile.policy == ExecutionPolicy(environment: .development, readOnly: true))
        #expect(rows[2].profile.policy == ExecutionPolicy())
    }
    @Test func boundedMalformedFixturesRejectUnknownsSecretsDuplicatesAndInvalidSettings() throws {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("invalid"), includingPropertiesForKeys: nil)
        #expect(files.count >= 25)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(throws: ProfileTransferError.self) { _ = try ProfileTransfer.preview(data) }
        }
        #expect(throws: ProfileTransferError.self) { try ProfileTransfer.encode([]) }
        let data = try Data(contentsOf: root.appendingPathComponent("mac-export-v2.json"))
        let row = try #require(ProfileTransfer.preview(data).first)
        #expect(throws: ProfileTransferError.self) { try ProfileTransfer.encode(Array(repeating: row.profile, count: ProfileTransfer.maxProfiles + 1)) }
    }
    @Test func windowsDriveAndUNCHintsNeverBecomeLocalMacTrustAndRequireExplicitRemap() throws {
        for path in ["/ca/team.pem", "C:\\CA\\team.pem", "C:/CA/team.pem", "\\\\server\\public-ca\\team.pem"] {
            #expect(ProfileTransfer.validCAHint(path))
        }
        for path in ["", "ca.pem", "C:ca.pem", "\\ca.pem", "\\\\server", "\\\\?\\C:\\ca.pem", "\\\\.\\device\\ca.pem", "https://example.test/ca.pem", "bad\0path"] {
            #expect(!ProfileTransfer.validCAHint(path))
        }
        let rows = try ProfileTransfer.preview(Data(contentsOf: root.appendingPathComponent("windows-remapped-v2.json")))
        #expect(rows[0].requiresCASelection && rows[1].requiresCASelection)
        #expect(rows[0].profile.sslMode == "verify-full" && rows[1].profile.sslMode == "verify-ca")
        #expect(!rows[2].requiresCASelection)
    }
}
