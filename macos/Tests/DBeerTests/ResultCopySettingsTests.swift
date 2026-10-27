import Foundation
import Testing
@testable import DBeer

@MainActor
struct ResultCopySettingsTests {
    @Test func freshSettingsPreserveDefaultCommandCopyBehavior() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ResultCopySettings(defaults: defaults)
        #expect(settings.options == ResultCopyOptions(format: .tsv, includesHeaders: false))
        #expect(defaults.object(forKey: ResultCopySettings.preferenceKey) == nil)
    }

    @Test func everyFormatAndHeaderPreferenceSurviveRecreation() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ResultCopySettings(defaults: defaults)
        for format in ResultCopyFormat.allCases {
            for headers in [true, false] {
                settings.options = ResultCopyOptions(format: format, includesHeaders: headers)
                #expect(ResultCopySettings(defaults: defaults).options == settings.options)
            }
        }
        settings.reset()
        #expect(settings.options == .default)
        #expect(ResultCopySettings(defaults: defaults).options == .default)
    }

    @Test func nestedPreferenceEditsPersistBothFields() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ResultCopySettings(defaults: defaults)
        settings.options.format = .csv
        settings.options.includesHeaders = true
        #expect(ResultCopySettings(defaults: defaults).options == ResultCopyOptions(format: .csv, includesHeaders: true))
    }

    @Test(arguments: ["not json", "null", "{}", "{\"format\":\"xml\",\"includesHeaders\":true}",
        "{\"format\":\"csv\",\"includesHeaders\":\"yes\"}"])
    func corruptOrUnknownPreferencesFallBackToCompatibleDefaults(value: String) {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(value.utf8), forKey: ResultCopySettings.preferenceKey)
        let settings = ResultCopySettings(defaults: defaults)
        #expect(settings.options == .default)
        settings.options = ResultCopyOptions(format: .markdown, includesHeaders: true)
        #expect(ResultCopySettings(defaults: defaults).options == settings.options)
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "dev.dbeer.tests.copy-settings.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
