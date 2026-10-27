import AppKit
import ApplicationServices
import Carbon
import Foundation
import XCTest
import XCUIAutomation

/// Exercises only the externally launched, signed application. No DBeer source
/// is imported and no application state or process is injected by this runner.
@MainActor
final class SSHApplicationTests: XCTestCase {
    private struct Configuration: Decodable {
        let installAppPath: String
        let bundleIdentifier: String
        let expectedVersion: String
        let expectedBuild: String
        let phase: String
        let launchPolicy: String
        let ownedPID: Int32
        let smokeProfileID: UUID
        let smokeProfileEngine: String
        let inputSourceOriginalID: String
        let inputSourceASCIIID: String
        let resultFile: String
        let disconnectEvidenceFile: String
        let sshHost: String
        let sshPort: Int
        let sshFingerprint: String
        let manualPassphraseFile: String?
    }

    private struct Evidence: Encodable {
        var version = 1
        let phase: String
        let appPath: String
        let expectedBuild: String
        let pid: Int32
        let profileID: UUID
        var engine = "postgresql"
        var passed = false
        var normalQuit = false
        var firstConnect = false
        var hostKeyReview = false
        var hostKeyCancelled = false
        var encryptedKey = false
        var encryptedKeyPassphraseSource = "preprovisionedKeychain"
        var passphraseCancelled = false
        var incorrectPassphraseRejected = false
        var nativePassphraseEntered = false
        var readyForForcedTermination = false
        var twoTabs = false
        var independentSessions = false
        var stoppedQuery = false
        var otherTabUnaffected = false
        var profileDisconnected = false
        var firstBackendPID: Int?
        var secondBackendPID: Int?
    }

    private struct DisconnectEvidence: Decodable {
        let profileID: UUID
        let ownedPID: Int32
        let tunnelStoppedWhileAppAlive: Bool
        let ownedListenerClosedWhileAppAlive: Bool
        let databaseSessionsGoneWhileAppAlive: Bool
    }

    private enum Rejection: Error {
        case unsafeConfiguration, wrongApplication, unexpectedProcess, missingControl, queryFailed, quitFailed
        case inputSourceUnavailable, inputSourceChanged, inputSourceSelectionFailed
        case missingHostKeyReview, wrongFingerprint, secretPromptUnexpected, missingTab, sharedDatabaseSession
    }

    func testSSHConnectionLifecycle() throws {
        continueAfterFailure = false
        let configuration = try loadConfiguration()
        let appURL = URL(fileURLWithPath: configuration.installAppPath, isDirectory: true).resolvingSymlinksInPath()
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == configuration.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == configuration.expectedVersion,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == configuration.expectedBuild else {
            throw Rejection.wrongApplication
        }
        try assertOwnedApplication(configuration, at: appURL)
        let app = XCUIApplication(url: appURL)
        // activate attaches; launch/terminate would replace or kill the fixture.
        app.activate()
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        var completed = false
        defer {
            if !completed {
                try? restorePhaseInputSource(configuration)
                captureFailure(app, configuration: configuration, appURL: appURL)
            }
        }
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 15) else { throw Rejection.missingControl }
        let profile = window.descendants(matching: .any).matching(identifier: "profile-" + configuration.smokeProfileID.uuidString).firstMatch
        guard profile.waitForExistence(timeout: 10) else { throw Rejection.missingControl }
        var evidence = Evidence(phase: configuration.phase, appPath: appURL.path, expectedBuild: configuration.expectedBuild,
            pid: configuration.ownedPID, profileID: configuration.smokeProfileID)

        if configuration.manualPassphraseFile != nil {
            evidence.encryptedKeyPassphraseSource = "nativeSecurePrompt"
        }
        if configuration.phase == "ssh-crash" {
            try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
            if configuration.manualPassphraseFile != nil {
                try enterPassphrase(app: app, configuration: configuration, appURL: appURL, incorrect: false)
                evidence.nativePassphraseEntered = true
            }
            _ = try newTab(profile: profile, app: app, configuration: configuration, appURL: appURL)
            _ = try selectValue("SELECT pg_backend_pid()::text AS dbeer_ssh_ui_crash_pid", column: "dbeer_ssh_ui_crash_pid",
                app: app, configuration: configuration, appURL: appURL)
            evidence.firstConnect = true
            evidence.encryptedKey = true
            evidence.readyForForcedTermination = true
            evidence.passed = true
            captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-ready-for-forced-termination")
            try restorePhaseInputSource(configuration)
            publish(evidence)
            completed = true
            return
        }
        if configuration.manualPassphraseFile != nil {
            try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
            let prompt = try passphrasePrompt(app: app)
            try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
            try visibleButton("Cancel", in: prompt.container).click()
            guard prompt.field.waitForNonExistence(timeout: 10) else { throw Rejection.secretPromptUnexpected }
            evidence.passphraseCancelled = true
        }
        try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
        if configuration.manualPassphraseFile != nil {
            try enterPassphrase(app: app, configuration: configuration, appURL: appURL, incorrect: true)
        }
        let firstReview = try hostKeyReview(app: app, configuration: configuration)
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-first-host-key-review")
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        try visibleButton("Cancel", in: firstReview.container).click()
        guard firstReview.button.waitForNonExistence(timeout: 10) else { throw Rejection.missingHostKeyReview }
        evidence.hostKeyCancelled = true
        checkpoint("trust-cancelled")
        Thread.sleep(forTimeInterval: 1)

        try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
        if configuration.manualPassphraseFile != nil {
            try enterPassphrase(app: app, configuration: configuration, appURL: appURL, incorrect: true)
        }
        let secondReview = try hostKeyReview(app: app, configuration: configuration)
        evidence.hostKeyReview = true
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        secondReview.button.click()
        guard secondReview.button.waitForNonExistence(timeout: 10) else { throw Rejection.missingHostKeyReview }
        checkpoint("trust-accepted")
        if configuration.manualPassphraseFile != nil {
            let notifications = window.buttons["workspaceNotifications"]
            guard notifications.waitForExistence(timeout: 20) else { throw Rejection.missingControl }
            let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "1 unread"), object: notifications)
            guard XCTWaiter.wait(for: [failed], timeout: 20) == .completed else { throw Rejection.queryFailed }
            try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
            notifications.click()
            let message = "SSH authentication or forwarding failed"
            let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", message, message)).firstMatch
            guard error.waitForExistence(timeout: 10) else { throw Rejection.queryFailed }
            evidence.incorrectPassphraseRejected = true
            try keyboardAction("ssh-close-failure-notification", configuration: configuration) { app.typeKey(.escape, modifierFlags: []) }
            try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
            try enterPassphrase(app: app, configuration: configuration, appURL: appURL, incorrect: false)
            evidence.nativePassphraseEntered = true
        }

        let firstTab = try newTab(profile: profile, app: app, configuration: configuration, appURL: appURL)
        let firstPID = try selectValue("SELECT pg_backend_pid()::text AS dbeer_ssh_ui_first_pid", column: "dbeer_ssh_ui_first_pid",
            app: app, configuration: configuration, appURL: appURL)
        guard let firstBackend = Int(firstPID), firstBackend > 0 else { throw Rejection.queryFailed }
        evidence.firstBackendPID = firstBackend
        evidence.firstConnect = true
        // The selected key is encrypted. The fixture independently records
        // whether its passphrase came from the secure prompt or Keychain.
        evidence.encryptedKey = true
        try runStatement("CREATE TEMP TABLE dbeer_ssh_ui_first(id integer)", app: app, configuration: configuration, appURL: appURL)
        try expectValue("SELECT CASE WHEN COUNT(*)=1 THEN 'yes' ELSE 'no' END AS dbeer_ssh_ui_first_temp FROM information_schema.tables WHERE table_name='dbeer_ssh_ui_first' AND table_type='LOCAL TEMPORARY'", column: "dbeer_ssh_ui_first_temp", app: app, configuration: configuration, appURL: appURL, expected: "yes")

        let secondTab = try newTab(profile: profile, app: app, configuration: configuration, appURL: appURL)
        guard firstTab != secondTab else { throw Rejection.missingTab }
        let secondPID = try selectValue("SELECT pg_backend_pid()::text AS dbeer_ssh_ui_second_pid", column: "dbeer_ssh_ui_second_pid", app: app, configuration: configuration, appURL: appURL)
        guard let secondBackend = Int(secondPID), secondBackend > 0, secondBackend != firstBackend else { throw Rejection.sharedDatabaseSession }
        evidence.secondBackendPID = secondBackend
        try expectValue("SELECT CASE WHEN COUNT(*)=0 THEN 'isolated' ELSE 'shared' END AS dbeer_ssh_ui_isolation FROM information_schema.tables WHERE table_name='dbeer_ssh_ui_first' AND table_type='LOCAL TEMPORARY'", column: "dbeer_ssh_ui_isolation", app: app, configuration: configuration, appURL: appURL, expected: "isolated")
        try runStatement("CREATE TEMP TABLE dbeer_ssh_ui_second(id integer)", app: app, configuration: configuration, appURL: appURL)
        try expectValue("SELECT 'second-ready' AS dbeer_ssh_ui_second_ready", column: "dbeer_ssh_ui_second_ready", app: app, configuration: configuration, appURL: appURL, expected: "second-ready")
        evidence.twoTabs = true
        evidence.independentSessions = true
        checkpoint("two-tab-ready")
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-two-independent-tabs")
        Thread.sleep(forTimeInterval: 1)

        try selectTab(firstTab, app: app, configuration: configuration, appURL: appURL)
        try startStatement("SELECT pg_sleep(30) AS dbeer_ssh_ui_sleep", app: app, configuration: configuration, appURL: appURL)
        let stop = window.buttons["Stop"]
        try waitEnabled(stop, enabled: true, timeout: 10)
        guard !window.buttons["runQuery"].isEnabled else { throw Rejection.queryFailed }
        checkpoint("long-running")
        Thread.sleep(forTimeInterval: 1)
        try selectTab(secondTab, app: app, configuration: configuration, appURL: appURL)
        try expectValue("SELECT 'other-tab-ok' AS dbeer_ssh_ui_other_tab", column: "dbeer_ssh_ui_other_tab", app: app, configuration: configuration, appURL: appURL, expected: "other-tab-ok")
        try selectTab(firstTab, app: app, configuration: configuration, appURL: appURL)
        guard stop.isEnabled else { throw Rejection.queryFailed }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        stop.click()
        try waitEnabled(window.buttons["runQuery"], enabled: true, timeout: 15)
        guard !stop.isEnabled, window.staticTexts["Query cancelled"].waitForExistence(timeout: 5) else { throw Rejection.queryFailed }
        evidence.stoppedQuery = true
        checkpoint("query-stopped")
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-stopped-query")
        try expectValue("SELECT CASE WHEN COUNT(*)=1 THEN 'recovered' ELSE 'lost' END AS dbeer_ssh_ui_recovered FROM information_schema.tables WHERE table_name='dbeer_ssh_ui_first' AND table_type='LOCAL TEMPORARY'", column: "dbeer_ssh_ui_recovered", app: app, configuration: configuration, appURL: appURL, expected: "recovered")
        try selectTab(secondTab, app: app, configuration: configuration, appURL: appURL)
        try expectValue("SELECT 'still-alive' AS dbeer_ssh_ui_second_after_stop", column: "dbeer_ssh_ui_second_after_stop", app: app, configuration: configuration, appURL: appURL, expected: "still-alive")
        evidence.otherTabUnaffected = true

        try chooseProfileAction("Disconnect", profile: profile, app: app, configuration: configuration, appURL: appURL)
        guard window.staticTexts["Session opens on first Run"].waitForExistence(timeout: 15) else { throw Rejection.missingControl }
        checkpoint("profile-disconnected")
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-profile-disconnected")
        try waitForDisconnectEvidence(configuration)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        evidence.profileDisconnected = true
        try quitNormally(app: app, configuration: configuration, appURL: appURL)
        try restorePhaseInputSource(configuration)
        evidence.normalQuit = true
        evidence.passed = true
        publish(evidence)
        completed = true
    }

    private func publish(_ evidence: Evidence) {
        guard let encoded = try? JSONEncoder().encode(evidence) else { return }
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = evidence.phase + "-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        FileHandle.standardOutput.write(Data(("DBEER_ACCEPTANCE_EVIDENCE " + String(decoding: encoded, as: UTF8.self) + "\n").utf8))
    }

    private func passphrasePrompt(app: XCUIApplication) throws -> (container: XCUIElement, field: XCUIElement) {
        let prompt = try visibleDialog(containingButton: "Connect", app: app, timeout: 15)
        let fields = prompt.container.secureTextFields
        guard fields.count == 1, prompt.container.staticTexts["SSH Private Key Passphrase"].exists else {
            throw Rejection.secretPromptUnexpected
        }
        return (prompt.container, fields.firstMatch)
    }

    private func enterPassphrase(app: XCUIApplication, configuration: Configuration, appURL: URL, incorrect: Bool) throws {
        guard let path = configuration.manualPassphraseFile else { throw Rejection.unsafeConfiguration }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, (1...256).contains(size.intValue) else { throw Rejection.unsafeConfiguration }
        let secret: String
        if incorrect { secret = "synthetic-incorrect-passphrase" }
        else { secret = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .newlines) }
        let prompt = try passphrasePrompt(app: app)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        prompt.field.click()
        // XCTest's authorized native Paste action supplies the secure field
        // without logging the generated passphrase or requiring separate raw
        // event-posting privileges. Preserve every clipboard item and format.
        let clipboard = NSPasteboard.general
        let originalCount = clipboard.changeCount
        let previous: [NSPasteboardItem] = try (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { throw Rejection.unsafeConfiguration }
            }
            return copy
        }
        guard clipboard.changeCount == originalCount else { throw Rejection.unsafeConfiguration }
        clipboard.clearContents()
        var ownedClipboardCount = clipboard.changeCount
        defer {
            // Never overwrite a clipboard changed outside this test.
            if clipboard.changeCount == ownedClipboardCount {
                clipboard.clearContents()
                if !previous.isEmpty {
                    XCTAssertTrue(clipboard.writeObjects(previous), "The owned synthetic clipboard could not restore its previous items.")
                }
            }
        }
        let wroteSecret = clipboard.setString(secret, forType: .string)
        ownedClipboardCount = clipboard.changeCount
        guard wroteSecret else { throw Rejection.unsafeConfiguration }
        try keyboardAction("ssh-native-secure-paste", configuration: configuration) {
            prompt.field.typeKey("v", modifierFlags: .command)
        }
        guard clipboard.changeCount == ownedClipboardCount else { throw Rejection.unsafeConfiguration }
        Thread.sleep(forTimeInterval: 0.1)
        let enteredCount = (prompt.field.value as? String)?.utf16.count ?? -1
        recordOwnershipDiagnostic(["reason": "owned-secure-input-length", "expectedPID": configuration.ownedPID,
            "expectedCharacterCount": secret.utf16.count, "enteredCharacterCount": enteredCount,
            "eventPostingAllowed": CGPreflightPostEventAccess(), "accessibilityTrusted": AXIsProcessTrusted(),
            "inputMethod": "nativeSecurePaste"])
        guard enteredCount == -1 || enteredCount == secret.utf16.count else { throw Rejection.secretPromptUnexpected }
        try visibleButton("Connect", in: prompt.container).click()
        guard prompt.field.waitForNonExistence(timeout: 10) else { throw Rejection.secretPromptUnexpected }
    }

    private func hostKeyReview(app: XCUIApplication, configuration: Configuration) throws -> (container: XCUIElement, button: XCUIElement) {
        guard app.secureTextFields.count == 0 else { throw Rejection.secretPromptUnexpected }
        let review = try visibleDialog(containingButton: "Trust and Connect", app: app, timeout: 15)
        let values = review.container.descendants(matching: .any).allElementsBoundByIndex.flatMap { [$0.label, $0.value as? String].compactMap { $0 } }
        guard values.contains(where: { $0.contains(configuration.sshFingerprint) }),
              values.contains(where: { $0.contains(configuration.sshHost + ":" + String(configuration.sshPort)) }) else { throw Rejection.wrongFingerprint }
        return review
    }

    private func tabIDs(_ app: XCUIApplication) -> Set<String> {
        Set(app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectDocument-")).allElementsBoundByIndex
            .map(\.identifier).filter { UUID(uuidString: String($0.dropFirst("selectDocument-".count))) != nil })
    }

    private func newTab(profile: XCUIElement, app: XCUIApplication, configuration: Configuration, appURL: URL) throws -> String {
        let previous = tabIDs(app)
        try chooseProfileAction("New SQL Tab", profile: profile, app: app, configuration: configuration, appURL: appURL)
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let added = tabIDs(app).subtracting(previous)
            if added.count == 1, let identifier = added.first { return identifier }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw Rejection.missingTab
    }

    private func selectTab(_ identifier: String, app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        // A tab containing SwiftUI ProgressView is exposed as an activity
        // indicator while busy. Its stable identifier and pointer target remain.
        let matches = app.windows.firstMatch.descendants(matching: .any).matching(identifier: identifier)
            .allElementsBoundByIndex.filter { element in
                let frame = element.frame
                return frame.width > 0 && frame.height > 0 && !frame.isInfinite && !frame.isNull && element.isHittable
            }
        guard matches.count == 1, let tab = matches.first else { throw Rejection.missingTab }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        tab.click()
    }

    private func startStatement(_ sql: String, app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        guard app.secureTextFields.count == 0 else { throw Rejection.secretPromptUnexpected }
        let window = app.windows.firstMatch
        let editor = window.textViews["sqlEditor"]
        guard editor.waitForExistence(timeout: 10) else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        editor.click()
        try keyboardAction("ssh-query-selection", configuration: configuration) { editor.typeKey("a", modifierFlags: .command) }
        try keyboardAction("ssh-query-text", configuration: configuration) { editor.typeText(sql) }
        let run = window.buttons["runQuery"]
        try waitEnabled(run, enabled: true, timeout: 10)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        run.click()
        // Each independently opened tab may request its own unsaved SSH
        // credential. Exercise that native prompt instead of waiting for the
        // modal sheet to disappear without supplying the requested secret.
        if configuration.manualPassphraseFile != nil,
           app.secureTextFields.firstMatch.waitForExistence(timeout: 1.5) {
            try enterPassphrase(app: app, configuration: configuration, appURL: appURL, incorrect: false)
        }
    }

    private func runStatement(_ sql: String, app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        try startStatement(sql, app: app, configuration: configuration, appURL: appURL)
        // The application must leave the request's busy state, and the next
        // result assertion verifies this statement's session-side effect.
        Thread.sleep(forTimeInterval: 0.4)
        try waitEnabled(app.windows.firstMatch.buttons["runQuery"], enabled: true, timeout: 15)
    }

    private func expectValue(_ sql: String, column: String, app: XCUIApplication, configuration: Configuration,
                             appURL: URL, expected: String) throws {
        let actual = try selectValue(sql, column: column, app: app, configuration: configuration, appURL: appURL)
        // Throw through Swift so the outer defer can restore the input source
        // and capture safe diagnostics before XCTest records the failed test.
        guard actual == expected else { throw Rejection.queryFailed }
    }

    private func selectValue(_ sql: String, column: String, app: XCUIApplication, configuration: Configuration, appURL: URL) throws -> String {
        try runStatement(sql, app: app, configuration: configuration, appURL: appURL)
        let table = app.windows.firstMatch.tables["Query results"]
        guard table.waitForExistence(timeout: 15) else {
            if app.secureTextFields.count == 0 {
                try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
                let notifications = app.windows.firstMatch.buttons["workspaceNotifications"]
                if notifications.exists, notifications.isHittable {
                    notifications.click()
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            throw Rejection.queryFailed
        }
        let cell = table.descendants(matching: .any).matching(NSPredicate(format: "label == %@", column + ", row 1")).firstMatch
        guard cell.waitForExistence(timeout: 15), let value = cell.value as? String else { throw Rejection.queryFailed }
        return value
    }

    private func waitEnabled(_ element: XCUIElement, enabled: Bool, timeout: TimeInterval) throws {
        guard element.waitForExistence(timeout: timeout) else { throw Rejection.missingControl }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { throw Rejection.queryFailed }
    }

    private func waitForDisconnectEvidence(_ configuration: Configuration) throws {
        // The independent fixture must observe transport and database teardown
        // while the app is still alive. Quit cannot supply this evidence later.
        let path = configuration.disconnectEvidenceFile
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { throw Rejection.queryFailed }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
              let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0 && bytes.intValue <= 16384 else { throw Rejection.unsafeConfiguration }
        let report = try JSONDecoder().decode(DisconnectEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard report.profileID == configuration.smokeProfileID, report.ownedPID == configuration.ownedPID,
              report.tunnelStoppedWhileAppAlive, report.ownedListenerClosedWhileAppAlive,
              report.databaseSessionsGoneWhileAppAlive,
              NSRunningApplication(processIdentifier: configuration.ownedPID)?.isTerminated == false else { throw Rejection.queryFailed }
        checkpoint("disconnect-externally-confirmed")
    }

    private func captureFailure(_ app: XCUIApplication, configuration: Configuration, appURL: URL) {
        let snapshot = ownershipSnapshot(configuration, at: appURL, requireForeground: true)
        var details = snapshot.details
        let foreground = NSWorkspace.shared.frontmostApplication
        details["foregroundBundleIdentifier"] = foreground?.bundleIdentifier ?? ""
        details["foregroundApplicationName"] = foreground?.localizedName ?? ""
        recordOwnershipDiagnostic(details)
        // Foreign UI may be a system authorization prompt. Record its process
        // identity only; never capture it or enter credentials into it.
        guard snapshot.failure == nil else { return }
        let secureCount = app.secureTextFields.count
        guard secureCount == 0 else {
            recordOwnershipDiagnostic(["reason": "owned-secret-prompt", "expectedPID": configuration.ownedPID,
                "secureTextFieldCount": secureCount])
            return
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ssh-lifecycle-owned-failure-ax.txt"
        tree.lifetime = .keepAlways
        add(tree)
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-lifecycle-failure")
    }

    private func captureSafeWindow(_ app: XCUIApplication, configuration: Configuration, appURL: URL, name: String) {
        guard ownershipSnapshot(configuration, at: appURL, requireForeground: true).failure == nil,
              app.secureTextFields.count == 0, app.windows.firstMatch.exists else { return }
        captureWindow(app, name: name)
    }

    private func checkpoint(_ stage: String) {
        let data = try? JSONSerialization.data(withJSONObject: ["stage": stage], options: [.sortedKeys])
        if let data { FileHandle.standardOutput.write(Data(("DBEER_SSH_UI_STAGE " + String(decoding: data, as: UTF8.self) + "\n").utf8)) }
    }

    private func captureMenuDiagnostic(_ app: XCUIApplication, configuration: Configuration, appURL: URL, title: String) {
        guard ownershipSnapshot(configuration, at: appURL, requireForeground: true).failure == nil,
              app.secureTextFields.count == 0 else { return }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ssh-profile-menu-" + title.replacingOccurrences(of: " ", with: "-") + "-ax.txt"
        tree.lifetime = .keepAlways
        add(tree)
        let rows = app.menus.allElementsBoundByIndex.map { menu -> [String: Any] in
            ["identifier": menu.identifier, "label": menu.label, "frame": NSStringFromRect(menu.frame),
             "items": menu.menuItems.allElementsBoundByIndex.map { item -> [String: Any] in
                ["identifier": item.identifier, "label": item.label, "enabled": item.isEnabled,
                 "hittable": item.isHittable, "frame": NSStringFromRect(item.frame)]
             }]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
            let details = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            details.name = "ssh-profile-menu-elements.json"
            details.lifetime = .keepAlways
            add(details)
        }
        captureSafeWindow(app, configuration: configuration, appURL: appURL, name: "ssh-profile-menu-selection-failure")
    }

    private func loadConfiguration() throws -> Configuration {
        guard let path = ProcessInfo.processInfo.environment["DBEER_ACCEPTANCE_CONFIG"], path.hasPrefix("/") else { throw Rejection.unsafeConfiguration }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { throw Rejection.unsafeConfiguration }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard configuration.installAppPath.hasPrefix("/"), configuration.installAppPath.hasSuffix(".app"),
              configuration.bundleIdentifier == "dev.dbeer.app", configuration.expectedVersion == "0.2.0", configuration.expectedBuild == "8",
              ["ssh-lifecycle", "ssh-crash"].contains(configuration.phase), configuration.launchPolicy == "attach", configuration.ownedPID > 1,
              configuration.smokeProfileEngine == "postgresql", !configuration.inputSourceOriginalID.isEmpty, !configuration.inputSourceASCIIID.isEmpty,
              configuration.resultFile.hasPrefix("/"), configuration.disconnectEvidenceFile.hasPrefix("/"),
              URL(fileURLWithPath: configuration.disconnectEvidenceFile).lastPathComponent == "disconnect-evidence.json",
              URL(fileURLWithPath: configuration.disconnectEvidenceFile).deletingLastPathComponent().resolvingSymlinksInPath() ==
                  URL(fileURLWithPath: configuration.resultFile).deletingLastPathComponent().resolvingSymlinksInPath(),
              !configuration.sshHost.isEmpty, (1...65535).contains(configuration.sshPort),
              configuration.sshFingerprint.hasPrefix("SHA256:") else { throw Rejection.unsafeConfiguration }
        if let path = configuration.manualPassphraseFile {
            guard URL(fileURLWithPath: path).lastPathComponent == "manual-passphrase",
                  URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath() ==
                    URL(fileURLWithPath: configuration.resultFile).deletingLastPathComponent().resolvingSymlinksInPath() else {
                throw Rejection.unsafeConfiguration
            }
        }
        return configuration
    }

    private func visibleDialog(containingButton title: String, app: XCUIApplication,
                               timeout: TimeInterval, requireHittable: Bool = true) throws -> (container: XCUIElement, button: XCUIElement) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let containers = app.dialogs.allElementsBoundByIndex + app.sheets.allElementsBoundByIndex + app.windows.allElementsBoundByIndex
            for container in containers {
                if let button = findVisibleButton(title, in: container, requireHittable: requireHittable) { return (container, button) }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw Rejection.missingControl
    }

    private func visibleButton(_ title: String, in container: XCUIElement) throws -> XCUIElement {
        guard let button = findVisibleButton(title, in: container) else { throw Rejection.missingControl }
        return button
    }

    private func findVisibleButton(_ title: String, in container: XCUIElement, requireHittable: Bool = true) -> XCUIElement? {
        guard container.exists else { return nil }
        let bounds = container.frame
        guard bounds.width > 0, bounds.height > 0, !bounds.isInfinite, !bounds.isNull else { return nil }
        return container.buttons.matching(identifier: title).allElementsBoundByIndex.first { button in
            let frame = button.frame
            return frame.width > 0 && frame.height > 0 && !frame.isInfinite && !frame.isNull &&
                bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) && (!requireHittable || button.isHittable)
        }
    }

    private func captureWindow(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func captureElementHierarchy(_ element: XCUIElement, name: String) {
        let hierarchy = XCTAttachment(string: element.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        if element.exists, element.frame.width > 0, element.frame.height > 0,
           !element.frame.isInfinite, !element.frame.isNull {
            let image = XCTAttachment(screenshot: element.screenshot())
            image.name = name + "-panel"
            image.lifetime = .keepAlways
            add(image)
        }
    }

    private func quitNormally(app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        // Exercise the application's real asynchronous termination path, rather
        // than XCUIApplication.terminate(), which sends SIGKILL.
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        try keyboardAction("normal-quit", configuration: configuration) {
            app.typeKey("q", modifierFlags: .command)
        }
        try waitForNormalExit(app: app, configuration: configuration)
    }

    private func waitForNormalExit(app: XCUIApplication, configuration: Configuration) throws {
        guard app.wait(for: .notRunning, timeout: 15),
              NSRunningApplication(processIdentifier: configuration.ownedPID)?.isTerminated != false else {
            throw Rejection.quitFailed
        }
    }

    private func keyboardAction(_ name: String, configuration: Configuration, action: () throws -> Void) throws {
        // Keep one ASCII lease for the phase, rechecking immediately before
        // each keyboard action. The outer fixture restores it if XCTest aborts.
        let original = try currentInputSource()
        let originalID = try inputSourceID(original)
        guard originalID == configuration.inputSourceOriginalID || originalID == configuration.inputSourceASCIIID else {
            throw Rejection.inputSourceChanged
        }
        let ascii = try enabledInputSource(id: configuration.inputSourceASCIIID)
        guard try inputSourceFlag(ascii, kTISPropertyInputSourceIsASCIICapable) else {
            throw Rejection.inputSourceUnavailable
        }
        guard try inputSourceID(currentInputSource()) == originalID else { throw Rejection.inputSourceChanged }
        if originalID != configuration.inputSourceASCIIID {
            guard TISSelectInputSource(ascii) == noErr else { throw Rejection.inputSourceSelectionFailed }
        }
        guard try inputSourceID(currentInputSource()) == configuration.inputSourceASCIIID else {
            throw Rejection.inputSourceSelectionFailed
        }
        recordInputSource(name, status: "selectedASCII", currentID: configuration.inputSourceASCIIID)
        try assertOwnedApplication(configuration,
            at: URL(fileURLWithPath: configuration.installAppPath, isDirectory: true).resolvingSymlinksInPath(),
            requireForeground: true)
        try action()
    }

    private func restorePhaseInputSource(_ configuration: Configuration) throws {
        let currentID = try inputSourceID(currentInputSource())
        if currentID != configuration.inputSourceOriginalID {
            // Never overwrite a different source selected outside this test.
            guard currentID == configuration.inputSourceASCIIID else { throw Rejection.inputSourceChanged }
            let original = try enabledInputSource(id: configuration.inputSourceOriginalID)
            guard try inputSourceID(currentInputSource()) == configuration.inputSourceASCIIID else {
                throw Rejection.inputSourceChanged
            }
            guard TISSelectInputSource(original) == noErr else { throw Rejection.inputSourceSelectionFailed }
        }
        guard try inputSourceID(currentInputSource()) == configuration.inputSourceOriginalID else {
            throw Rejection.inputSourceSelectionFailed
        }
        recordInputSource("phase-cleanup", status: "restored", currentID: configuration.inputSourceOriginalID)
    }

    private func currentInputSource() throws -> TISInputSource {
        guard let copied = TISCopyCurrentKeyboardInputSource() else { throw Rejection.inputSourceUnavailable }
        return copied.takeRetainedValue()
    }

    private func inputSourceProperty(_ source: TISInputSource, _ key: CFString) throws -> CFTypeRef {
        guard let pointer = TISGetInputSourceProperty(source, key) else { throw Rejection.inputSourceUnavailable }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    }

    private func inputSourceID(_ source: TISInputSource) throws -> String {
        let value = try inputSourceProperty(source, kTISPropertyInputSourceID)
        guard CFGetTypeID(value) == CFStringGetTypeID() else { throw Rejection.inputSourceUnavailable }
        return unsafeBitCast(value, to: CFString.self) as String
    }

    private func inputSourceFlag(_ source: TISInputSource, _ key: CFString) throws -> Bool {
        let value = try inputSourceProperty(source, key)
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Rejection.inputSourceUnavailable }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func enabledInputSource(id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let copied = TISCreateInputSourceList(filter, false) else { throw Rejection.inputSourceUnavailable }
        let sources = copied.takeRetainedValue()
        guard CFArrayGetCount(sources) == 1, let pointer = CFArrayGetValueAtIndex(sources, 0) else {
            throw Rejection.inputSourceUnavailable
        }
        let source = unsafeBitCast(pointer, to: TISInputSource.self)
        guard try inputSourceID(source) == id,
              try inputSourceFlag(source, kTISPropertyInputSourceIsEnabled),
              try inputSourceFlag(source, kTISPropertyInputSourceIsSelectCapable) else {
            throw Rejection.inputSourceUnavailable
        }
        return source
    }

    private func recordInputSource(_ action: String, status: String, currentID: String) {
        let details = ["action": action, "status": status, "currentID": currentID]
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
            let record = "DBEER_ACCEPTANCE_INPUT_SOURCE " + String(decoding: data, as: UTF8.self) + "\n"
            FileHandle.standardOutput.write(Data(record.utf8))
        }
    }

    private func chooseProfileAction(_ title: String, profile: XCUIElement, app: XCUIApplication,
                                     configuration: Configuration, appURL: URL) throws {
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        profile.rightClick()
        // AppKit can expose a context menu as an application sibling rather
        // than an outline descendant. Only the one visible, hittable menu in
        // this owned process may match; closed menu-bar alternatives are excluded.
        let deadline = Date().addingTimeInterval(5)
        var visibleMenus: [XCUIElement] = []
        repeat {
            visibleMenus = app.menus.allElementsBoundByIndex.filter { menu in
                let frame = menu.frame
                let items = menu.menuItems.matching(identifier: title)
                guard frame.width > 0 && frame.height > 0 && !frame.isInfinite && !frame.isNull,
                      items.count == 1 else { return false }
                let item = items.firstMatch
                let target = item.frame
                return item.isHittable && target.width > 0 && target.height > 0 && !target.isInfinite && !target.isNull &&
                    frame.contains(CGPoint(x: target.midX, y: target.midY))
            }
            if !visibleMenus.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        guard visibleMenus.count == 1, let menu = visibleMenus.first else {
            captureMenuDiagnostic(app, configuration: configuration, appURL: appURL, title: title)
            throw Rejection.missingControl
        }
        let matches = menu.menuItems.matching(identifier: title)
        guard matches.count == 1 else { throw Rejection.missingControl }
        let item = matches.firstMatch
        guard item.isEnabled, item.frame.width > 0, item.frame.height > 0,
              !item.frame.isInfinite, !item.frame.isNull,
              menu.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        item.click()
    }

    private func assertOwnedApplication(_ configuration: Configuration, at appURL: URL,
                                       requireForeground: Bool = false) throws {
        let snapshot = ownershipSnapshot(configuration, at: appURL, requireForeground: requireForeground)
        if snapshot.failure != nil {
            recordOwnershipDiagnostic(snapshot.details)
            throw Rejection.unexpectedProcess
        }
    }

    private func ownershipSnapshot(_ configuration: Configuration, at appURL: URL,
                                   requireForeground: Bool) -> (failure: String?, details: [String: Any]) {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == configuration.bundleIdentifier || $0.executableURL?.lastPathComponent == "DBeer"
        }
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let failure: String?
        if candidates.count != 1 { failure = "candidate-count" }
        else if let running = candidates.first {
            if running.processIdentifier != configuration.ownedPID { failure = "pid" }
            else if running.bundleURL?.resolvingSymlinksInPath() != appURL { failure = "bundle-url" }
            else if running.executableURL?.resolvingSymlinksInPath() != appURL.appendingPathComponent("Contents/MacOS/DBeer") { failure = "executable-url" }
            else if running.isTerminated { failure = "terminated" }
            else if requireForeground && foregroundPID != configuration.ownedPID { failure = "foreground" }
            else { failure = nil }
        } else { failure = "candidate-count" }
        let details: [String: Any] = [
            "reason": failure ?? "none", "expectedPID": configuration.ownedPID,
            "expectedAppPath": appURL.path, "foregroundPID": foregroundPID ?? -1,
            "candidates": candidates.map { running -> [String: Any] in
                ["pid": running.processIdentifier, "bundleIdentifier": running.bundleIdentifier ?? "",
                 "bundlePath": running.bundleURL?.resolvingSymlinksInPath().path ?? "",
                 "executablePath": running.executableURL?.resolvingSymlinksInPath().path ?? "",
                 "terminated": running.isTerminated]
            }
        ]
        return (failure, details)
    }

    private func recordOwnershipDiagnostic(_ details: [String: Any]) {
        if let encoded = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
            let record = "DBEER_ACCEPTANCE_OWNERSHIP_DIAGNOSTIC " + String(decoding: encoded, as: UTF8.self) + "\n"
            FileHandle.standardOutput.write(Data(record.utf8))
            let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
            attachment.name = "ownership-diagnostic.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
