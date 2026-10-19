import AppKit
import Carbon
import Foundation
import XCTest
import XCUIAutomation

/// External-process acceptance only: no import of DBeer and no injected app code.
/// The fixture launcher provisions secrets through the archived application's
/// supported stdin channel. This runner never reads or enters a password.
@MainActor
final class InstalledApplicationTests: XCTestCase {
    private struct Configuration: Decodable {
        let installAppPath: String
        let bundleIdentifier: String
        let expectedBuild: String
        let phase: String
        let launchPolicy: String
        let ownedPID: Int32
        let smokeProfileID: UUID?
        let smokeProfileEngine: String?
        let portableProfilesPath: String?
        let importProfileNames: [String]?
        let inputSourceOriginalID: String
        let inputSourceASCIIID: String
        let resultFile: String
    }

    private struct Evidence: Encodable {
        var version = 1
        let phase: String
        let appPath: String
        let expectedBuild: String
        let pid: Int32
        let profileID: UUID?
        let engine: String?
        var passed = false
        var connected = false
        var querySucceeded = false
        var normalQuit = false
        var importPreviewSeen = false
        var importedProfilesConfirmed = false
        var closeCancelled = false
        var appAliveAfterCancel = false
        var longQueryObserved = false
        var stoppedAndClosed = false
    }

    private enum Rejection: Error {
        case unsafeConfiguration, wrongApplication, unexpectedProcess, missingControl, queryFailed, quitFailed
        case missingGoToSheet, missingPathTextField, incorrectEnteredPath, goToSheetDidNotClose
        case inputSourceUnavailable, inputSourceChanged, inputSourceSelectionFailed
    }

    func testInstalledAppQueryAndQuit() throws {
        continueAfterFailure = false
        let configuration = try loadConfiguration()
        let appURL = URL(fileURLWithPath: configuration.installAppPath, isDirectory: true).resolvingSymlinksInPath()
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == configuration.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.1.0",
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == configuration.expectedBuild else {
            throw Rejection.wrongApplication
        }
        try assertOwnedApplication(configuration, at: appURL)
        let app = XCUIApplication(url: appURL)
        // Never use launch(): Apple documents that it kills an existing instance.
        // activate() attaches without terminating the provisioned process.
        app.activate()
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        var phaseCompleted = false
        defer {
            if !phaseCompleted {
                do { try restorePhaseInputSource(configuration) }
                catch { recordInputSource("phase-cleanup", status: "restorationRejected", currentID: "unverified") }
                captureFailure(app: app, configuration: configuration, appURL: appURL)
            }
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "The installed application did not expose a window.")

        var evidence = Evidence(phase: configuration.phase, appPath: appURL.path, expectedBuild: configuration.expectedBuild,
            pid: configuration.ownedPID, profileID: configuration.smokeProfileID, engine: configuration.smokeProfileEngine)
        if configuration.phase == "build5-import" {
            try importProfiles(app: app, configuration: configuration, appURL: appURL)
            evidence.importPreviewSeen = true
            evidence.importedProfilesConfirmed = true
            try quitNormally(app: app, configuration: configuration, appURL: appURL)
        } else {
            try queryFixture(app: app, configuration: configuration, appURL: appURL)
            evidence.connected = true
            evidence.querySucceeded = true
            if configuration.phase == "build5-postgresql" {
                try closeRunningQuery(app: app, configuration: configuration, appURL: appURL)
                evidence.closeCancelled = true
                evidence.appAliveAfterCancel = true
                evidence.longQueryObserved = true
                evidence.stoppedAndClosed = true
            } else {
                try quitNormally(app: app, configuration: configuration, appURL: appURL)
            }
        }
        try restorePhaseInputSource(configuration)
        evidence.normalQuit = true
        evidence.passed = true
        let encoded = try JSONEncoder().encode(evidence)
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = configuration.phase + "-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The generated Apple UI runner is sandboxed. Its caller writes the
        // result file from this nonsecret single-line record after XCTest PASS.
        let record = "DBEER_ACCEPTANCE_EVIDENCE " + String(decoding: encoded, as: UTF8.self) + "\n"
        FileHandle.standardOutput.write(Data(record.utf8))
        phaseCompleted = true
    }

    private func queryFixture(app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        guard let profileID = configuration.smokeProfileID else { throw Rejection.unsafeConfiguration }
        let window = app.windows.firstMatch

        let profile = window.descendants(matching: .any)
            .matching(identifier: "profile-" + profileID.uuidString).firstMatch
        guard profile.waitForExistence(timeout: 10) else { throw Rejection.missingControl }
        try chooseProfileAction("Connect", profile: profile, app: app, configuration: configuration, appURL: appURL)
        try chooseProfileAction("New SQL Tab", profile: profile, app: app, configuration: configuration, appURL: appURL)

        let editor = window.textViews["sqlEditor"]
        guard editor.waitForExistence(timeout: 10) else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        editor.click()
        try keyboardAction("query-editor", configuration: configuration) {
            editor.typeKey("a", modifierFlags: .command)
        }
        try keyboardAction("query-text", configuration: configuration) {
            editor.typeText("SELECT 1 AS dbeer_acceptance_smoke")
        }
        let run = window.buttons["runQuery"]
        guard run.waitForExistence(timeout: 5), run.isEnabled else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        run.click()

        let table = window.tables["Query results"]
        guard table.waitForExistence(timeout: 15) else { throw Rejection.queryFailed }
        let value = table.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND value == %@", "dbeer_acceptance_smoke, row 1", "1")).firstMatch
        guard value.waitForExistence(timeout: 15) else { throw Rejection.queryFailed }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        captureWindow(app, name: configuration.phase + "-installed-query")
    }

    private func importProfiles(app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        guard let portablePath = configuration.portableProfilesPath, let names = configuration.importProfileNames,
              names.count == 2 else { throw Rejection.unsafeConfiguration }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        app.menuBars.menuBarItems["Connections"].click()
        let menu = app.menuItems["Import Connections…"]
        guard menu.waitForExistence(timeout: 5) else { throw Rejection.missingControl }
        menu.click()
        // Use the standard Open panel's Go to Folder path entry, not pasteboard
        // state or Finder/System Events automation.
        // Open is normally disabled until a file has been selected. Its finite
        // on-panel frame identifies the real control even in that initial state.
        let initialPanel = try visibleDialog(containingButton: "Open", app: app, timeout: 5, requireHittable: false)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        // The application-level shortcut is the event observed opening this
        // remote panel's Go to Folder sheet in the earlier acceptance run.
        try keyboardAction("open-go-to-folder", configuration: configuration) {
            app.typeKey("g", modifierFlags: [.command, .shift])
        }
        // These native identifiers are taken from the actual Open-panel AX
        // hierarchy. Never fall back to the main window's catalog Search field.
        let goToSheet = app.sheets.matching(identifier: "GoToWindow").firstMatch
        let field = goToSheet.textFields.matching(identifier: "PathTextField").firstMatch
        guard goToSheet.waitForExistence(timeout: 5) else {
            captureElementHierarchy(initialPanel.container, name: configuration.phase + "-missing-go-to-sheet-ax.txt")
            throw Rejection.missingGoToSheet
        }
        guard field.waitForExistence(timeout: 5),
              field.frame.width > 0, field.frame.height > 0, !field.frame.isInfinite, !field.frame.isNull,
              goToSheet.frame.width > 0, goToSheet.frame.height > 0,
              !goToSheet.frame.isInfinite, !goToSheet.frame.isNull,
              goToSheet.frame.contains(CGPoint(x: field.frame.midX, y: field.frame.midY)) else {
            captureElementHierarchy(goToSheet, name: configuration.phase + "-missing-path-field-ax.txt")
            throw Rejection.missingPathTextField
        }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        field.click()
        try keyboardAction("portable-profile-path", configuration: configuration) {
            field.typeKey("a", modifierFlags: .command)
        }
        try keyboardAction("portable-profile-path-text", configuration: configuration) {
            field.typeText(portablePath)
        }
        guard field.value as? String == portablePath else {
            captureElementHierarchy(goToSheet, name: configuration.phase + "-path-entry-ax.txt")
            throw Rejection.incorrectEnteredPath
        }
        try keyboardAction("portable-profile-path-submit", configuration: configuration) {
            field.typeKey(.return, modifierFlags: [])
        }
        guard goToSheet.waitForNonExistence(timeout: 5) else {
            captureElementHierarchy(initialPanel.container, name: configuration.phase + "-go-to-sheet-still-open-ax.txt")
            throw Rejection.goToSheetDidNotClose
        }
        let openPanel = try visibleDialog(containingButton: "Open", app: app, timeout: 5)
        guard openPanel.button.isEnabled else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        // The standard panel's Return action avoids the duplicate Touch Bar
        // Open element while retaining the native default-button behavior.
        try keyboardAction("open-portable-profile", configuration: configuration) {
            openPanel.container.typeKey(.return, modifierFlags: [])
        }
        let preview = app.sheets.firstMatch
        guard preview.waitForExistence(timeout: 10), preview.staticTexts["Import Connections"].exists else {
            throw Rejection.missingControl
        }
        for name in names {
            guard preview.staticTexts[name].waitForExistence(timeout: 5) else { throw Rejection.missingControl }
        }
        // Selectable SwiftUI Text may be a TextField/TextView, and macOS often
        // exposes its contents as AXValue instead of AXLabel. Check the exact
        // visible summary prefix without assuming an accessibility element type.
        let previewElements = preview.descendants(matching: .any).allElementsBoundByIndex
        let summaryTexts = previewElements.flatMap { element -> [String] in
            [element.label, element.value as? String].compactMap { $0 }
        }
        for engine in ["PostgreSQL", "MySQL"] {
            guard summaryTexts.contains(where: { $0.hasPrefix(engine + " ·") }) else {
                let hierarchy = XCTAttachment(string: preview.debugDescription)
                hierarchy.name = configuration.phase + "-preview-ax.txt"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                throw Rejection.missingControl
            }
        }
        captureWindow(app, name: configuration.phase + "-preview")
        let confirm = preview.buttons["Import"]
        guard confirm.isEnabled else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        confirm.click()
        guard preview.waitForNonExistence(timeout: 10) else { throw Rejection.missingControl }
        // The actual outline row combines name and engine in one AX label.
        // Its stable profile identifier belongs to the imported UUID, rather
        // than to a separate name-only StaticText.
        for (name, engine) in zip(names, ["PostgreSQL", "MySQL"]) {
            let row = app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "profile-", name + ", " + engine)).firstMatch
            guard row.waitForExistence(timeout: 5),
                  UUID(uuidString: String(row.identifier.dropFirst("profile-".count))) != nil else {
                throw Rejection.missingControl
            }
        }
        captureWindow(app, name: configuration.phase + "-imported")
    }

    private func closeRunningQuery(app: XCUIApplication, configuration: Configuration, appURL: URL) throws {
        let window = app.windows.firstMatch
        let editor = window.textViews["sqlEditor"]
        let run = window.buttons["runQuery"]
        let stop = window.buttons["Stop"]
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        guard app.windows.count == 1, editor.exists, run.isEnabled else { throw Rejection.missingControl }
        editor.click()
        try keyboardAction("long-query-editor", configuration: configuration) {
            editor.typeKey("a", modifierFlags: .command)
        }
        try keyboardAction("long-query-text", configuration: configuration) {
            editor.typeText("SELECT pg_sleep(30)")
        }
        run.click()
        guard stop.waitForExistence(timeout: 5) else { throw Rejection.queryFailed }
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: stop)
        guard XCTWaiter.wait(for: [running], timeout: 5) == .completed, !run.isEnabled else { throw Rejection.queryFailed }
        // Give the external fixture observer an opportunity to see the real
        // backend's active state. This runner asserts UI state, not server state.
        Thread.sleep(forTimeInterval: 1)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        captureWindow(app, name: configuration.phase + "-running-before-close")
        let close = window.buttons[XCUIIdentifierCloseWindow]
        guard close.exists else { throw Rejection.missingControl }
        close.click()
        let firstPrompt = try visibleDialog(containingButton: "Stop and Continue", app: app, timeout: 5)
        let cancel = try visibleButton("Cancel", in: firstPrompt.container)
        cancel.click()
        guard firstPrompt.button.waitForNonExistence(timeout: 5), window.exists, stop.isEnabled, !run.isEnabled else {
            throw Rejection.queryFailed
        }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        captureWindow(app, name: configuration.phase + "-close-cancelled")
        close.click()
        let secondPrompt = try visibleDialog(containingButton: "Stop and Continue", app: app, timeout: 5)
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        secondPrompt.button.click()
        try waitForNormalExit(app: app, configuration: configuration)
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

    private func captureFailure(app: XCUIApplication, configuration: Configuration, appURL: URL) {
        // Diagnostics must never throw in a defer and obscure the original error.
        let ownership = ownershipSnapshot(configuration, at: appURL, requireForeground: false)
        guard ownership.failure == nil else {
            recordOwnershipDiagnostic(ownership.details)
            return
        }
        let window = app.windows.firstMatch
        guard window.exists else { return }
        let hierarchy = XCTAttachment(string: window.debugDescription)
        hierarchy.name = configuration.phase + "-owned-window-failure-ax.txt"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == configuration.ownedPID else { return }
        let image = XCTAttachment(screenshot: window.screenshot())
        image.name = configuration.phase + "-owned-window-failure"
        image.lifetime = .keepAlways
        add(image)
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
        // The archived app exposes the profile context menu inside its Sidebar
        // outline. File's hidden New SQL Tab menu item must never participate.
        let sidebar = app.windows.firstMatch.outlines["Sidebar"]
        let deadline = Date().addingTimeInterval(5)
        var visibleMenus: [XCUIElement] = []
        repeat {
            visibleMenus = sidebar.menus.matching(identifier: "server.rack").allElementsBoundByIndex.filter { menu in
                let frame = menu.frame
                return frame.width > 0 && frame.height > 0 && !frame.isInfinite && !frame.isNull
            }
            if !visibleMenus.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        guard visibleMenus.count == 1, let menu = visibleMenus.first else { throw Rejection.missingControl }
        let matches = menu.menuItems.matching(identifier: title)
        guard matches.count == 1 else { throw Rejection.missingControl }
        let item = matches.firstMatch
        guard item.isEnabled, item.frame.width > 0, item.frame.height > 0,
              !item.frame.isInfinite, !item.frame.isNull,
              menu.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) else { throw Rejection.missingControl }
        try assertOwnedApplication(configuration, at: appURL, requireForeground: true)
        item.click()
    }

    private func loadConfiguration() throws -> Configuration {
        guard let path = ProcessInfo.processInfo.environment["DBEER_ACCEPTANCE_CONFIG"], path.hasPrefix("/") else {
            throw Rejection.unsafeConfiguration
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw Rejection.unsafeConfiguration
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard configuration.installAppPath.hasPrefix("/"), configuration.installAppPath.hasSuffix(".app"),
              configuration.bundleIdentifier == "dev.dbeer.app", ["5", "6"].contains(configuration.expectedBuild),
              configuration.launchPolicy == "attach", configuration.ownedPID > 1,
              !configuration.inputSourceOriginalID.isEmpty, !configuration.inputSourceASCIIID.isEmpty,
              !configuration.phase.isEmpty, configuration.resultFile.hasPrefix("/") else {
            throw Rejection.unsafeConfiguration
        }
        if configuration.phase == "build5-import" {
            guard configuration.expectedBuild == "5", configuration.portableProfilesPath?.hasPrefix("/") == true,
                  configuration.importProfileNames?.count == 2 else { throw Rejection.unsafeConfiguration }
        } else {
            guard configuration.smokeProfileID != nil,
                  let engine = configuration.smokeProfileEngine, ["postgresql", "mysql"].contains(engine),
                  configuration.phase == "build" + configuration.expectedBuild + "-" + engine else {
                throw Rejection.unsafeConfiguration
            }
        }
        return configuration
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
