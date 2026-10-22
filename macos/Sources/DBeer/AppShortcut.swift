import AppKit
import SwiftUI

/// String identifiers let future command groups join the registry without
/// teaching persistence about every command in the application.
struct AppCommandID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) { self.rawValue = rawValue }

    static let runCurrent = Self(rawValue: "query.runCurrent")
    static let runScript = Self(rawValue: "query.runScript")
    static let stop = Self(rawValue: "query.stop")
    static let runToJSON = Self(rawValue: "query.runToJSON")
    static let runToCSV = Self(rawValue: "query.runToCSV")
    static let copyAsJSON = Self(rawValue: "grid.copy.json")
    static let copyAsMarkdown = Self(rawValue: "grid.copy.markdown")
    static let copyAsSQLInsert = Self(rawValue: "grid.copy.insert")
    static let reopenClosedTab = Self(rawValue: "workspace.reopenClosedTab")

    var isGridCopyCommand: Bool {
        self == .copyAsJSON || self == .copyAsMarkdown || self == .copyAsSQLInsert
    }
}

enum AppCommandScope: String, Codable, Hashable, Sendable {
    case workspace, document, sqlDocument, grid

    func overlaps(_ other: Self) -> Bool {
        // SQL documents also contain result grids. A script shortcut and a
        // grid shortcut can therefore be active together in the same window.
        true
    }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .document: "Active document"
        case .sqlDocument: "SQL document"
        case .grid: "Result grid"
        }
    }
}

struct AppCommandDescriptor: Identifiable, Hashable, Sendable {
    let id: AppCommandID
    let title: String
    let scope: AppCommandScope
    let defaultShortcut: AppShortcut?

    init(id: AppCommandID, title: String, scope: AppCommandScope, defaultShortcut: AppShortcut? = nil) {
        self.id = id
        self.title = title
        self.scope = scope
        self.defaultShortcut = defaultShortcut
    }

    static let builtins: [Self] = [
        .init(id: .reopenClosedTab, title: "Reopen Closed Tab", scope: .workspace,
            defaultShortcut: AppShortcut(key: "t", modifiers: [.command, .shift])),
        .init(id: .runCurrent, title: "Run Selection or Current Statement", scope: .document,
            defaultShortcut: AppShortcut(key: "return", modifiers: .command)),
        .init(id: .runScript, title: "Run Script", scope: .sqlDocument,
            defaultShortcut: AppShortcut(key: "return", modifiers: [.command, .shift])),
        .init(id: .stop, title: "Stop", scope: .document),
        .init(id: .runToJSON, title: "Run to JSON File…", scope: .sqlDocument),
        .init(id: .runToCSV, title: "Run to CSV File…", scope: .sqlDocument),
        .init(id: .copyAsJSON, title: "Copy as JSON", scope: .grid,
            defaultShortcut: AppShortcut(key: "j", modifiers: [.command, .option])),
        .init(id: .copyAsMarkdown, title: "Copy as Markdown", scope: .grid,
            defaultShortcut: AppShortcut(key: "m", modifiers: [.command, .option])),
        .init(id: .copyAsSQLInsert, title: "Copy as SQL INSERT", scope: .grid,
            defaultShortcut: AppShortcut(key: "i", modifiers: [.command, .option])),
    ]
}

struct AppShortcut: Codable, Hashable, Sendable {
    let key: String
    let modifierRawValue: UInt

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = Self.canonicalKey(key)
        modifierRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let specialKeys: [UInt16: String] = [
            36: "return", 76: "return", 48: "tab", 53: "escape", 51: "delete",
            117: "forwardDelete", 123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow",
            115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
        ]
        let key: String
        if let special = specialKeys[event.keyCode] { key = special }
        else if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            // Native Command equivalents keep their familiar physical Latin
            // letters on non-Latin layouts. Latin layouts retain their own
            // character mapping; Control/Option never use this fallback.
            if event.modifierFlags.contains(.command),
               characters.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && !$0.isASCII }),
               let latin = Self.commandLatinKeyCodes[event.keyCode] {
                key = latin
            } else { key = characters }
        } else { return nil }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    var modifiers: NSEvent.ModifierFlags { .init(rawValue: modifierRawValue) }
    var isFunctionKey: Bool { Self.functionKeyNumber(key) != nil }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "tab": .tab
        case "escape": .escape
        case "delete": .delete
        case "forwardDelete": .deleteForward
        case "leftArrow": .leftArrow
        case "rightArrow": .rightArrow
        case "upArrow": .upArrow
        case "downArrow": .downArrow
        case "home": .home
        case "end": .end
        case "pageUp": .pageUp
        case "pageDown": .pageDown
        default:
            if let number = Self.functionKeyNumber(key), let scalar = UnicodeScalar(0xF703 + number) {
                KeyEquivalent(Character(scalar))
            } else { KeyEquivalent(key.first ?? " ") }
        }
    }

    var displayString: String {
        let modifierSymbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let symbols = modifierSymbols.compactMap { modifiers.contains($0.0) ? $0.1 : nil }.joined()
        let keySymbols = ["return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫", "forwardDelete": "⌦",
            "leftArrow": "←", "rightArrow": "→", "upArrow": "↑", "downArrow": "↓", "home": "↖", "end": "↘",
            "pageUp": "⇞", "pageDown": "⇟", " ": "Space"]
        return symbols + (keySymbols[key] ?? key.uppercased())
    }

    func matches(event: NSEvent) -> Bool { Self(event: event) == self }

    /// Recanonicalize decoded values and reject representations which cannot be
    /// expressed by both native events and SwiftUI menu key equivalents.
    var isCanonical: Bool {
        modifierRawValue == modifiers.intersection(Self.supportedModifiers).rawValue &&
            key == Self.canonicalKey(key) && (Self.namedKeys.contains(key) || Self.functionKeyNumber(key) != nil ||
                (key.count == 1 && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)))
    }

    private static let namedKeys: Set<String> = ["return", "tab", "escape", "delete", "forwardDelete",
        "leftArrow", "rightArrow", "upArrow", "downArrow", "home", "end", "pageUp", "pageDown"]

    private static func canonicalKey(_ key: String) -> String {
        switch key {
        case "\r", "\n", "return", "Return": "return"
        case "\t", "tab", "Tab": "tab"
        case "\u{1B}", "escape", "Escape": "escape"
        case "\u{7F}", "delete", "Delete": "delete"
        case "\u{F728}": "forwardDelete"
        case "\u{F702}": "leftArrow"
        case "\u{F703}": "rightArrow"
        case "\u{F700}": "upArrow"
        case "\u{F701}": "downArrow"
        case "\u{F729}": "home"
        case "\u{F72B}": "end"
        case "\u{F72C}": "pageUp"
        case "\u{F72D}": "pageDown"
        default:
            if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
               (0xF704...0xF726).contains(scalar.value) {
                "f\(scalar.value - 0xF703)"
            } else { namedKeys.contains(key) ? key : key.lowercased() }
        }
    }

    private static func functionKeyNumber(_ key: String) -> UInt32? {
        guard key.hasPrefix("f"), let number = UInt32(key.dropFirst()), (1...35).contains(number),
              key == "f\(number)" else { return nil }
        return number
    }

    private static let commandLatinKeyCodes: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
    ]
}

struct AppShortcutOverride: Codable, Hashable, Sendable {
    /// An explicit nil is persisted as an unbound command, distinct from the
    /// absence of an override (which follows the command's default).
    let shortcut: AppShortcut?

    init(shortcut: AppShortcut?) { self.shortcut = shortcut }

    private enum CodingKeys: String, CodingKey { case shortcut, isDisabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .isDisabled) == true {
            guard !container.contains(.shortcut) else {
                throw DecodingError.dataCorruptedError(forKey: .shortcut, in: container,
                    debugDescription: "A disabled shortcut cannot have a key.")
            }
            shortcut = nil
        } else {
            shortcut = try container.decode(AppShortcut.self, forKey: .shortcut)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let shortcut { try container.encode(shortcut, forKey: .shortcut) }
        else { try container.encode(true, forKey: .isDisabled) }
    }
}

@MainActor
final class AppShortcutStore: ObservableObject {
    static let preferenceKey = "appCommandShortcuts.v1"
    static let backupPrefix = "appCommandShortcuts.backup."

    let descriptors: [AppCommandDescriptor]
    @Published private(set) var overrides: [AppCommandID: AppShortcutOverride] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, descriptors: [AppCommandDescriptor] = AppCommandDescriptor.builtins) {
        self.defaults = defaults
        var seen: Set<AppCommandID> = []
        self.descriptors = descriptors.filter { seen.insert($0.id).inserted }
        loadOverrides()
    }

    func shortcut(for command: AppCommandID) -> AppShortcut? {
        if let override = overrides[command] { return override.shortcut }
        return descriptors.first { $0.id == command }?.defaultShortcut
    }

    func validationError(for shortcut: AppShortcut?, command: AppCommandID) -> String? {
        guard let descriptor = descriptors.first(where: { $0.id == command }) else { return "Unknown command." }
        guard let shortcut else { return nil }
        if let error = Self.nativeValidationError(shortcut, command: descriptor.id, scope: descriptor.scope) { return error }
        if let conflict = descriptors.first(where: {
            $0.id != command && descriptor.scope.overlaps($0.scope) && self.shortcut(for: $0.id) == shortcut
        }) { return "This shortcut is already assigned to \(conflict.title)." }
        return nil
    }

    @discardableResult
    func update(_ shortcut: AppShortcut?, for command: AppCommandID) -> String? {
        if let error = validationError(for: shortcut, command: command) { return error }
        let value = AppShortcutOverride(shortcut: shortcut)
        overrides[command] = value
        persist(updating: [command: value])
        return nil
    }

    @discardableResult
    func restoreDefault(for command: AppCommandID) -> String? {
        guard let descriptor = descriptors.first(where: { $0.id == command }) else { return "Unknown command." }
        if let error = validationError(for: descriptor.defaultShortcut, command: command) { return error }
        overrides.removeValue(forKey: command)
        persist(removing: [command])
        return nil
    }

    func resetDefaults() {
        overrides = [:]
        persist(removing: Set(descriptors.map(\.id)))
    }

    private static func nativeValidationError(_ shortcut: AppShortcut, command: AppCommandID,
                                              scope: AppCommandScope) -> String? {
        guard shortcut.isCanonical else { return "Choose a single key supported by macOS." }
        let modifiers = shortcut.modifiers
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return "Include Command, Control, or Option in the shortcut."
        }
        let key = shortcut.key
        if key == "return", !modifiers.contains(.command) {
            return "This shortcut is reserved for inserting a native newline or line break."
        }
        // These keys remain available for traversal, selection, deletion and
        // cancellation, including their word/document-navigation variants.
        let navigation: Set<String> = ["tab", "escape", "delete", "forwardDelete", "leftArrow", "rightArrow",
            "upArrow", "downArrow", "home", "end", "pageUp", "pageDown"]
        if navigation.contains(key) { return "This shortcut is reserved for text editing or navigation." }
        if modifiers.contains(.command) {
            let editing: Set<String> = ["a", "c", "x", "v", "z", "y"]
            let baseCommands: Set<String> = ["e", "f", "g", "h", "m", "n", "o", "p", "q", "s", "t", "w",
                ",", ".", "`", "[", "]", "?", "/"]
            let shiftedCommands: Set<String> = ["e", "f", "g", "h", "n", "o", "p", "q", "s", "t", "w", "`", "[", "]", "?", "/"]
            let optionCommands: Set<String> = ["d", "h", "q", "w"]
            let controlCommands: Set<String> = ["f", "q"]
            // R21 assigns grid Markdown export to Command-Option-M. Keep this
            // explicit grid-only exception; ordinary Command-M still belongs
            // to macOS, as does Minimize All outside the grid context.
            let minimizeAll = key == "m" && modifiers == [.command, .option] && scope != .grid
            // The standard reopen binding belongs only to this workspace
            // command. Other commands cannot claim it after unbinding Reopen.
            let reopensClosedTab = command == .reopenClosedTab && scope == .workspace &&
                key == "t" && modifiers == [.command, .shift]
            let reserved = editing.contains(key) || key == " " ||
                (modifiers == .command && baseCommands.contains(key)) ||
                (modifiers == [.command, .shift] && shiftedCommands.contains(key) && !reopensClosedTab) ||
                (modifiers == [.command, .option] && optionCommands.contains(key)) ||
                (modifiers == [.command, .control] && controlCommands.contains(key)) ||
                (modifiers.contains(.shift) && ["3", "4", "5", "6"].contains(key)) || minimizeAll
            if reserved {
                return "This shortcut is reserved for a standard macOS or application command."
            }
        } else if modifiers.contains(.control) {
            let nativeTextKeys: Set<String> = ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "u", "v", "w", "y", " ", "'", "\"", "/"]
            if nativeTextKeys.contains(key) { return "This shortcut is reserved for native text editing." }
        } else if modifiers.contains(.option), key != "return", !shortcut.isFunctionKey {
            // Option-printable keys type accents and symbols in native fields.
            return "Option with a character key is reserved for typing accents and symbols."
        }
        return nil
    }

    private func loadOverrides() {
        guard let entries = Self.entries(from: defaults.object(forKey: Self.preferenceKey)) else { return }
        overrides = validatedOverrides(in: entries)
    }

    private static func entries(from storedValue: Any?) -> [String: Any]? {
        guard let data = storedValue as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func validatedOverrides(in entries: [String: Any]) -> [AppCommandID: AppShortcutOverride] {
        var validated: [AppCommandID: AppShortcutOverride] = [:]
        for descriptor in descriptors {
            guard let value = entries[descriptor.id.rawValue],
                  JSONSerialization.isValidJSONObject(value),
                  let entryData = try? JSONSerialization.data(withJSONObject: value),
                  let entry = try? JSONDecoder().decode(AppShortcutOverride.self, from: entryData),
                  entry.shortcut.map({ Self.nativeValidationError($0, command: descriptor.id, scope: descriptor.scope) == nil }) ?? true else { continue }
            validated[descriptor.id] = entry
        }
        func effectiveShortcut(for descriptor: AppCommandDescriptor) -> AppShortcut? {
            if let entry = validated[descriptor.id] { return entry.shortcut }
            return descriptor.defaultShortcut
        }
        // Validate the complete persisted assignment so valid swaps survive.
        // Remove conflicting overrides and repeat because falling back to a
        // default can reveal a second conflict with another stored override.
        while true {
            var rejected: Set<AppCommandID> = []
            for (index, descriptor) in descriptors.enumerated() {
                guard let shortcut = effectiveShortcut(for: descriptor) else { continue }
                for other in descriptors.dropFirst(index + 1)
                    where descriptor.scope.overlaps(other.scope) && effectiveShortcut(for: other) == shortcut {
                    if validated[descriptor.id] != nil { rejected.insert(descriptor.id) }
                    if validated[other.id] != nil { rejected.insert(other.id) }
                }
            }
            guard !rejected.isEmpty else { break }
            for id in rejected { validated.removeValue(forKey: id) }
        }
        return validated
    }

    private func persist(removing removed: Set<AppCommandID> = [],
                         updating updates: [AppCommandID: AppShortcutOverride] = [:]) {
        // Unknown command values and future metadata remain opaque. Rejected
        // known entries are quarantined in the exact backup, so they cannot
        // conflict with a newly accepted binding on the next launch.
        let storedValue = defaults.object(forKey: Self.preferenceKey)
        let existingEntries = Self.entries(from: storedValue)
        var entries = existingEntries ?? [:]
        let validated = validatedOverrides(in: entries)
        let hasInvalidEntry = descriptors.contains {
            entries[$0.id.rawValue] != nil && validated[$0.id] == nil
        }
        if let storedValue, existingEntries == nil || hasInvalidEntry {
            // Keep the exact original property-list value, especially Data,
            // before an edit replaces corrupt or incompatible preferences.
            defaults.set(storedValue, forKey: Self.backupPrefix + UUID().uuidString)
        }
        for descriptor in descriptors where entries[descriptor.id.rawValue] != nil && validated[descriptor.id] == nil {
            entries.removeValue(forKey: descriptor.id.rawValue)
        }
        for command in removed { entries.removeValue(forKey: command.rawValue) }
        for (command, value) in updates {
            guard let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            entries[command.rawValue] = object
        }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.preferenceKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) {
            defaults.set(data, forKey: Self.preferenceKey)
        }
    }
}
