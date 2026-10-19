import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct AppShortcutTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "dev.dbeer.shortcut-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func event(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags,
                       window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    @Test func defaultsPersistOverridesAndExplicitUnbindingAndReset() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.shortcut(for: .runCurrent) == AppShortcut(key: "return", modifiers: .command))
        #expect(store.shortcut(for: .runScript) == AppShortcut(key: "return", modifiers: [.command, .shift]))
        #expect(store.shortcut(for: .stop) == nil)
        let custom = AppShortcut(key: "r", modifiers: [.control, .shift])
        #expect(store.update(custom, for: .runCurrent) == nil)
        #expect(store.update(nil, for: .runScript) == nil)
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.shortcut(for: .runCurrent) == custom)
        #expect(restored.shortcut(for: .runScript) == nil)
        #expect(restored.overrides[.runScript] != nil)
        #expect(restored.restoreDefault(for: .runCurrent) == nil)
        #expect(restored.shortcut(for: .runCurrent) == AppShortcut(key: "return", modifiers: .command))
        restored.resetDefaults()
        #expect(defaults.object(forKey: AppShortcutStore.preferenceKey) == nil)
        #expect(AppShortcutStore(defaults: defaults).shortcut(for: .runScript) != nil)
    }

    @Test func persistedSwapsAreValidatedAsACompleteAssignment() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let current = store.shortcut(for: .runCurrent)
        let script = store.shortcut(for: .runScript)
        #expect(store.update(nil, for: .runCurrent) == nil)
        #expect(store.update(current, for: .runScript) == nil)
        #expect(store.update(script, for: .runCurrent) == nil)
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.shortcut(for: .runCurrent) == script)
        #expect(restored.shortcut(for: .runScript) == current)
        #expect(restored.restoreDefault(for: .runCurrent) != nil)
        #expect(restored.shortcut(for: .runCurrent) == script)
    }

    @Test func invalidUnknownAndConflictingPersistedEntriesAreIgnored() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let custom = AppShortcut(key: "r", modifiers: .command)
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppShortcutOverride(shortcut: custom)))
        let reserved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AppShortcutOverride(shortcut: AppShortcut(key: "c", modifiers: .command))))
        let object: [String: Any] = [
            AppCommandID.runCurrent.rawValue: reserved,
            AppCommandID.runScript.rawValue: ["unrecognized": true],
            AppCommandID.stop.rawValue: valid,
            AppCommandID.runToJSON.rawValue: valid,
            AppCommandID.runToCSV.rawValue: ["shortcut": ["key": "", "modifierRawValue": 0]],
            "unknown.command": ["isDisabled": true],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AppShortcutStore.preferenceKey)
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.overrides.isEmpty)
        #expect(restored.shortcut(for: .runCurrent) == AppShortcut(key: "return", modifiers: .command))
        #expect(restored.shortcut(for: .runScript) == AppShortcut(key: "return", modifiers: [.command, .shift]))
        defaults.set(Data("invalid JSON".utf8), forKey: AppShortcutStore.preferenceKey)
        #expect(AppShortcutStore(defaults: defaults).overrides.isEmpty)
    }

    @Test func editsAndRegisteredResetPreserveUnknownValuesAndFutureEnvelopes() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let future: [String: Any] = [
            "future.grid.copy": ["version": 7, "binding": ["keys": ["x", "j"], "mode": "chord"], "disabled": NSNull()],
            "future.metadata": ["schema": 9, "commands": ["future.command": ["payload": [1, true, "value"]]]],
            "future.primitive": "opaque value",
            "future.array": [NSNull(), false, 42],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: future), forKey: AppShortcutStore.preferenceKey)
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.overrides.isEmpty)
        #expect(store.update(AppShortcut(key: "r", modifiers: .command), for: .stop) == nil)
        #expect(store.update(nil, for: .runScript) == nil)
        #expect(store.restoreDefault(for: .stop) == nil)
        var entries = try storedEntries(defaults)
        for (key, value) in future {
            #expect(try canonicalJSON(entries[key]) == canonicalJSON(value))
        }
        #expect(entries[AppCommandID.runScript.rawValue] != nil)
        store.resetDefaults()
        entries = try storedEntries(defaults)
        #expect(try canonicalJSON(entries) == canonicalJSON(future))
        #expect(backupValues(defaults).isEmpty)
    }

    @Test func invalidKnownEntriesAreQuarantinedBeforeAnAcceptedEdit() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let incompatible: [String: Any] = ["version": 8, "shortcut": ["keySequence": ["r", "r"], "context": "future"]]
        let future: [String: Any] = ["payload": ["preserve": true]]
        let initial: [String: Any] = [AppCommandID.runCurrent.rawValue: incompatible, "future.command": future]
        let original = try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted, .sortedKeys])
        defaults.set(original, forKey: AppShortcutStore.preferenceKey)
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.shortcut(for: .runCurrent) == AppShortcut(key: "return", modifiers: .command))
        #expect(store.overrides[.runCurrent] == nil)
        #expect(backupValues(defaults).isEmpty)
        #expect(store.update(AppShortcut(key: "r", modifiers: .command), for: .stop) == nil)
        var entries = try storedEntries(defaults)
        #expect(entries[AppCommandID.runCurrent.rawValue] == nil)
        #expect(backupValues(defaults).contains { ($0 as? Data) == original })
        #expect(store.restoreDefault(for: .stop) == nil)
        entries = try storedEntries(defaults)
        #expect(entries[AppCommandID.runCurrent.rawValue] == nil)
        #expect(store.update(nil, for: .runCurrent) == nil)
        entries = try storedEntries(defaults)
        #expect(try canonicalJSON(entries[AppCommandID.runCurrent.rawValue]) == canonicalJSON(["isDisabled": true]))
        #expect(try canonicalJSON(entries["future.command"]) == canonicalJSON(future))
        #expect(store.restoreDefault(for: .runCurrent) == nil)
        entries = try storedEntries(defaults)
        #expect(entries[AppCommandID.runCurrent.rawValue] == nil)
        #expect(try canonicalJSON(entries["future.command"]) == canonicalJSON(future))
    }

    @Test func acceptedShortcutSurvivesReloadAfterConflictingEntriesAreQuarantined() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcut = AppShortcut(key: "r", modifiers: .command)
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppShortcutOverride(shortcut: shortcut)))
        let object: [String: Any] = [AppCommandID.stop.rawValue: entry, AppCommandID.runToJSON.rawValue: entry,
            "future.command": ["opaque": true]]
        let original = try JSONSerialization.data(withJSONObject: object)
        defaults.set(original, forKey: AppShortcutStore.preferenceKey)
        let store = AppShortcutStore(defaults: defaults)
        #expect(store.overrides.isEmpty)
        #expect(store.update(shortcut, for: .runToCSV) == nil)
        let restored = AppShortcutStore(defaults: defaults)
        #expect(restored.shortcut(for: .runToCSV) == shortcut)
        #expect(restored.shortcut(for: .stop) == nil)
        #expect(restored.shortcut(for: .runToJSON) == nil)
        #expect(backupValues(defaults).contains { ($0 as? Data) == original })
        #expect(try canonicalJSON(storedEntries(defaults)["future.command"]) == canonicalJSON(["opaque": true]))
    }

    @Test func corruptAndIncompatibleBlobsAreBackedUpExactlyBeforeUpdateOrReset() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let rawValues: [Data] = [Data("corrupt \u{00} preferences".utf8), Data("[1, {\"future\":true}]".utf8)]
        for (index, raw) in rawValues.enumerated() {
            defaults.set(raw, forKey: AppShortcutStore.preferenceKey)
            let store = AppShortcutStore(defaults: defaults)
            let previousCount = backupValues(defaults).count
            #expect(defaults.data(forKey: AppShortcutStore.preferenceKey) == raw)
            #expect(store.shortcut(for: .runCurrent) == AppShortcut(key: "return", modifiers: .command))
            #expect(store.update(AppShortcut(key: "r", modifiers: []), for: .stop) != nil)
            #expect(backupValues(defaults).count == previousCount)
            if index == 0 {
                #expect(store.update(AppShortcut(key: "r", modifiers: .control), for: .stop) == nil)
            } else { store.resetDefaults() }
            #expect(backupValues(defaults).count == previousCount + 1)
            #expect(backupValues(defaults).contains { ($0 as? Data) == raw })
        }
        // A repeated corrupt value receives its own backup instead of replacing
        // a previous recovery copy with the same bytes or a timestamp key.
        let raw = rawValues[0]
        defaults.set(raw, forKey: AppShortcutStore.preferenceKey)
        let previousCount = backupValues(defaults).count
        AppShortcutStore(defaults: defaults).resetDefaults()
        #expect(backupValues(defaults).count == previousCount + 1)
        #expect(defaults.object(forKey: AppShortcutStore.preferenceKey) == nil)
    }

    private func storedEntries(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try #require(defaults.data(forKey: AppShortcutStore.preferenceKey))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func canonicalJSON(_ value: Any?) throws -> Data {
        let value = try #require(value)
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private func backupValues(_ defaults: UserDefaults) -> [Any] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(AppShortcutStore.backupPrefix) }.map(\.value)
    }

    @Test func rejectsNativeEditingNavigationAndMissingModifiersButAllowsSafeAlternatives() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let protected: [AppShortcut] = [
            .init(key: "r", modifiers: []), .init(key: "r", modifiers: .shift),
            .init(key: "c", modifiers: .command), .init(key: "v", modifiers: [.command, .shift]),
            .init(key: "z", modifiers: .command), .init(key: "s", modifiers: [.command, .shift]),
            .init(key: "q", modifiers: [.command, .option]), .init(key: " ", modifiers: .command),
            .init(key: "p", modifiers: .control), .init(key: "e", modifiers: .option),
            .init(key: "leftArrow", modifiers: .option), .init(key: "tab", modifiers: .control),
            .init(key: "escape", modifiers: .command), .init(key: "delete", modifiers: .command),
            .init(key: "return", modifiers: .option), .init(key: "return", modifiers: .control),
            .init(key: "'", modifiers: .control), .init(key: "\"", modifiers: .control), .init(key: "/", modifiers: .control),
        ]
        for shortcut in protected {
            #expect(store.update(shortcut, for: .stop) != nil, "Protected \(shortcut.displayString)")
            #expect(store.shortcut(for: .stop) == nil)
        }
        let allowed: [AppShortcut] = [.init(key: "r", modifiers: .control),
            .init(key: "j", modifiers: .command),
            .init(key: "f5", modifiers: .option)]
        for shortcut in allowed {
            #expect(store.update(shortcut, for: .stop) == nil)
            #expect(store.shortcut(for: .stop) == shortcut)
        }
    }

    @Test func conflictsFollowContextOverlapAndDocumentCommandsOverlapEveryContext() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let gridID = AppCommandID(rawValue: "grid.test")
        let descriptors = AppCommandDescriptor.builtins + [
            .init(id: gridID, title: "Grid Test", scope: .grid),
        ]
        let store = AppShortcutStore(defaults: defaults, descriptors: descriptors)
        let shortcut = AppShortcut(key: "r", modifiers: .command)
        #expect(store.update(shortcut, for: .runScript) == nil)
        #expect(store.update(shortcut, for: gridID) != nil)
        #expect(store.update(shortcut, for: .runCurrent) != nil)
        #expect(store.update(shortcut, for: .runToJSON) != nil)
        #expect(store.update(shortcut, for: .stop) != nil)
        #expect(store.update(nil, for: .runScript) == nil)
        #expect(store.update(shortcut, for: gridID) == nil)
        #expect(store.update(shortcut, for: .stop) != nil)
        #expect(store.update(nil, for: gridID) == nil)
        #expect(store.update(shortcut, for: .stop) == nil)
        #expect(AppShortcutStore(defaults: defaults, descriptors: descriptors).shortcut(for: .stop) == shortcut)
    }

    @Test func futureGridExportDefaultsCanBeUpdatedRestoredAndPersisted() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let gridDefaults: [AppCommandDescriptor] = [("json", "j"), ("markdown", "m"), ("insert", "i")].map { name, key in
            .init(id: AppCommandID(rawValue: "grid.copy.\(name)"), title: "Copy \(name)", scope: .grid,
                defaultShortcut: AppShortcut(key: key, modifiers: [.command, .option]))
        }
        let descriptors = AppCommandDescriptor.builtins + gridDefaults
        let store = AppShortcutStore(defaults: defaults, descriptors: descriptors)
        for descriptor in gridDefaults {
            #expect(store.validationError(for: descriptor.defaultShortcut, command: descriptor.id) == nil)
            #expect(store.update(nil, for: descriptor.id) == nil)
            #expect(store.restoreDefault(for: descriptor.id) == nil)
            #expect(store.update(descriptor.defaultShortcut, for: descriptor.id) == nil)
        }
        let restored = AppShortcutStore(defaults: defaults, descriptors: descriptors)
        for descriptor in gridDefaults {
            #expect(restored.shortcut(for: descriptor.id) == descriptor.defaultShortcut)
            #expect(restored.overrides[descriptor.id] != nil)
        }
        #expect(store.update(AppShortcut(key: "m", modifiers: [.command, .option]), for: .stop) != nil)
        #expect(store.update(AppShortcut(key: "m", modifiers: .command), for: gridDefaults[1].id) != nil)
    }

    @Test func eventMatchingNormalizesCaseFlagsAndReturnVariants() throws {
        let shortcut = AppShortcut(key: "R", modifiers: [.command, .shift, .capsLock, .numericPad])
        #expect(shortcut.key == "r")
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.displayString == "⇧⌘R")
        #expect(shortcut.matches(event: try event("R", code: 15, modifiers: [.command, .shift, .capsLock])))
        #expect(!shortcut.matches(event: try event("r", code: 15, modifiers: .command)))
        let run = AppShortcut(key: "return", modifiers: .command)
        #expect(run.matches(event: try event("\r", code: 36, modifiers: .command)))
        #expect(run.matches(event: try event("\u{3}", code: 76, modifiers: [.command, .numericPad, .function])))
        #expect(run.keyEquivalent == .return)
        #expect(run.eventModifiers == .command)
        #expect(run.displayString == "⌘↩")
        let function = AppShortcut(key: "f5", modifiers: .option)
        #expect(function.displayString == "⌥F5")
        #expect(function.matches(event: try event("\u{F708}", code: 96, modifiers: [.option, .function])))
    }

    @Test func commandEquivalentsOnNonLatinLayoutsPreserveNativeEditingAndCustomKeys() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let copyEvent = try event("σ", code: 8, modifiers: .command)
        let copy = try #require(AppShortcut(event: copyEvent))
        #expect(copy == AppShortcut(key: "c", modifiers: .command))
        #expect(store.update(copy, for: .runCurrent) != nil)
        let custom = AppShortcut(key: "j", modifiers: .command)
        #expect(custom.matches(event: try event("ο", code: 38, modifiers: .command)))
        #expect(AppShortcut(event: try event("ο", code: 38, modifiers: .control))?.key == "ο")
        #expect(AppShortcut(event: try event("a", code: 12, modifiers: .command))?.key == "a")
    }

    @Test func nativeRecorderCapturesFocusedEventsValidatesAndPreservesTabAndEscape() throws {
        _ = NSApplication.shared
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 150))
        let recorder = ShortcutRecorderButton(frame: NSRect(x: 20, y: 70, width: 145, height: 26))
        let next = NSButton(title: "Next", target: nil, action: nil)
        next.frame = NSRect(x: 190, y: 70, width: 80, height: 26)
        recorder.nextKeyView = next
        next.nextKeyView = recorder
        content.addSubview(recorder)
        content.addSubview(next)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        var error: String?
        recorder.record = { shortcut in
            error = store.update(shortcut, for: .stop)
            return error
        }
        recorder.beginRecording()
        #expect(recorder.isRecording)
        #expect(window.firstResponder === recorder)
        #expect(recorder.performKeyEquivalent(with: try event("c", code: 8, modifiers: .command, window: window)))
        #expect(error != nil)
        #expect(recorder.isRecording)
        #expect(store.shortcut(for: .stop) == nil)
        recorder.keyDown(with: try event("r", code: 15, modifiers: .control, window: window))
        #expect(error == nil)
        #expect(!recorder.isRecording)
        #expect(store.shortcut(for: .stop) == AppShortcut(key: "r", modifiers: .control))
        recorder.beginRecording()
        recorder.keyDown(with: try event("\u{1B}", code: 53, modifiers: [], window: window))
        #expect(!recorder.isRecording)
        #expect(store.shortcut(for: .stop) == AppShortcut(key: "r", modifiers: .control))
        recorder.beginRecording()
        recorder.keyDown(with: try event("\t", code: 48, modifiers: [], window: window))
        #expect(!recorder.isRecording)
        #expect(window.firstResponder === next)
    }

    @Test func settingsExposeNativeRecordersAndFeedbackInBothAppearances() async throws {
        _ = NSApplication.shared
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppShortcutStore(defaults: defaults)
        for (theme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let hosting = NSHostingView(rootView: ShortcutSettingsView(store: store).environment(\.colorScheme, theme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            let recorders = descendants(hosting).compactMap { $0 as? ShortcutRecorderButton }
            #expect(recorders.count == store.descriptors.count)
            for recorder in recorders {
                #expect(recorder.isEnabled)
                #expect(recorder.focusRingType == .none)
                #expect(recorder.subviews.contains { $0 is NativeButtonHoverView })
                #expect(!recorder.title.isEmpty)
                #expect(recorder.frame.width >= 140)
                #expect(recorder.accessibilityLabel()?.hasPrefix("Shortcut for ") == true)
            }
            window.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
