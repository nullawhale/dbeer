import Foundation
import Testing
@testable import DBeer

// Model/protocol-only coverage. These tests create no windows and never read a real SSH config.
struct SSHConfigurationTests {
    private func configuration() -> SSHConfiguration {
        SSHConfiguration(host: "analytics-route", port: 0, user: "", authMethod: .openSSH,
            configFile: "/synthetic/ssh config")
    }

    @Test func localProfilesKeepConfigurationReferencesButTransfersExcludeThem() throws {
        let config = configuration()
        #expect(config.isValid)
        let settings = ConnectionSettings(host: "database.internal", port: 5432, database: "app", user: "reader",
            password: "fixture-secret", sslMode: "verify-full", ssh: config.runtime(profileId: UUID()))
        #expect(settings.hasValidNativeFields)
        let profile = SavedConnection(name: "Config", settings: settings)
        let localData = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(SavedConnection.self, from: localData)
        #expect(restored.ssh == config)
        #expect(!String(decoding: localData, as: UTF8.self).contains("fixture-secret"))
        let portable = try ProfileTransfer.encode([profile])
        let text = String(decoding: portable, as: UTF8.self)
        #expect(!text.contains("configFile") && !text.contains("/synthetic/ssh config"))
        let imported = try #require(ProfileTransfer.preview(portable).first)
        #expect(imported.profile.ssh?.authMethod == .openSSH)
        #expect(imported.profile.ssh?.configFile == nil)
        #expect(imported.profile.ssh?.host == "analytics-route")
        #expect(imported.id != profile.id)
        #expect(imported.profile.settings(password: "").hasValidNativeFields)
        var changed = settings
        changed.ssh?.configFile = "/synthetic/another config"
        #expect(!profile.matches(changed))
    }

    @Test func configurationModeRejectsMixedSettingsAndUnsafePaths() {
        let valid = configuration()
        for mutate: (inout SSHConfiguration) -> Void in [
            { $0.port = 22 }, { $0.user = "user" }, { $0.identityFile = "/synthetic/key" },
            { $0.configFile = "relative/config" }, { $0.configFile = "/synthetic/config\nHost *" },
            { $0.configFile = "/${FOREIGN}/config" }, { $0.host = "alias;command" }
        ] {
            var invalid = valid
            mutate(&invalid)
            #expect(!invalid.isValid)
        }
        let runtime = valid.runtime(profileId: UUID(), password: "foreign-secret")
        #expect(!runtime.isValid)
        var explicit = SSHConfiguration(host: "bastion.example", user: "user")
        explicit.configFile = "/synthetic/config"
        #expect(!explicit.isValid)
    }

    @Test func draftUsesTheAliasWithoutReadingConfigOrRequiringExplicitUserAndPort() throws {
        var draft = ConnectionDraft(connection: nil)
        draft.name = "Config"
        draft.sshEnabled = true
        draft.sshAuthMethod = .openSSH
        draft.sshHost = "analytics-route"
        draft.sshPort = "not-used"
        draft.sshUser = "not-used"
        draft.sshConfigFile = "/synthetic/missing-local-config"
        let settings = try #require(draft.settings)
        #expect(settings.ssh?.host == "analytics-route")
        #expect(settings.ssh?.port == 0 && settings.ssh?.user == "")
        #expect(settings.ssh?.configFile == draft.sshConfigFile)
        let profile = SavedConnection(name: "Config", settings: settings)
        let reopened = ConnectionDraft(connection: profile)
        #expect(reopened.sshAuthMethod == .openSSH && reopened.sshConfigFile == draft.sshConfigFile)
        draft.sshAuthMethod = .agent
        #expect(draft.settings == nil)
    }

    @MainActor @Test func anOlderHelperRejectsConfigModeBeforeWritingAnyCommand() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/synthetic/not-started"))
        let settings = ConnectionSettings(host: "database.internal", port: 5432, database: "app", user: "reader",
            password: "", sslMode: "verify-full", ssh: configuration().runtime(profileId: UUID()))
        await #expect(throws: BackendRequestError.unsupportedSSHConfiguration) {
            try await client.request(.sshProbe(settings))
        }
    }
}
