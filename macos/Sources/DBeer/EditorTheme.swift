import AppKit
import Foundation

enum EditorThemeAppearance: String, Codable, Sendable {
    case light, dark
}

struct EditorThemeColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        guard hex.first == "#" else { return nil }
        let digits = String(hex.dropFirst())
        guard [3, 4, 6, 8].contains(digits.count),
              digits.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let value = UInt64(digits, radix: 16) else { return nil }
        switch digits.count {
        case 3, 4:
            let hasAlpha = digits.count == 4
            red = Double((value >> (hasAlpha ? 12 : 8)) & 15) / 15
            green = Double((value >> (hasAlpha ? 8 : 4)) & 15) / 15
            blue = Double((value >> (hasAlpha ? 4 : 0)) & 15) / 15
            alpha = hasAlpha ? Double(value & 15) / 15 : 1
        default:
            let hasAlpha = digits.count == 8
            red = Double((value >> (hasAlpha ? 24 : 16)) & 255) / 255
            green = Double((value >> (hasAlpha ? 16 : 8)) & 255) / 255
            blue = Double((value >> (hasAlpha ? 8 : 0)) & 255) / 255
            alpha = hasAlpha ? Double(value & 255) / 255 : 1
        }
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var brightness: Double { red * 0.2126 + green * 0.7152 + blue * 0.0722 }
}

struct EditorThemeTokenStyle: Codable, Equatable, Sendable {
    var foreground: EditorThemeColor?
    var background: EditorThemeColor?
    /// nil inherits; an empty string explicitly clears inherited font traits.
    var fontStyle: String?

    init(foreground: EditorThemeColor? = nil, background: EditorThemeColor? = nil, fontStyle: String? = nil) {
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
    }
}

struct EditorThemeTokenRule: Codable, Equatable, Sendable {
    let scopes: [String]
    let style: EditorThemeTokenStyle
}

struct EditorTheme: Identifiable, Codable, Equatable, Sendable {
    var id: String
    let name: String
    let appearance: EditorThemeAppearance
    let colors: [String: EditorThemeColor]
    let tokenRules: [EditorThemeTokenRule]
    var isImported: Bool

    func color(_ key: String, default fallback: NSColor) -> NSColor {
        colors[key]?.nsColor ?? fallback
    }

    /// The stack runs from outermost to innermost, e.g. source.sql, string.quoted.single.sql.
    /// Supports dotted scopes, comma alternatives, parent chains and scope exclusions.
    /// This maps our SQL lexer to TextMate theme rules; it does not load grammars or extensions.
    func style(for scopes: [String]) -> EditorThemeTokenStyle {
        var matches: [(score: Int, order: Int, style: EditorThemeTokenStyle)] = []
        for (index, rule) in tokenRules.enumerated() {
            if rule.scopes.isEmpty {
                matches.append((0, index, rule.style))
            } else if let score = rule.scopes.compactMap({ Self.matchScore($0, stack: scopes) }).max() {
                matches.append((score, index, rule.style))
            }
        }
        matches.sort { $0.score == $1.score ? $0.order < $1.order : $0.score < $1.score }
        var result = EditorThemeTokenStyle()
        for match in matches {
            if let foreground = match.style.foreground { result.foreground = foreground }
            if let background = match.style.background { result.background = background }
            if let fontStyle = match.style.fontStyle { result.fontStyle = fontStyle }
        }
        return result
    }

    private static func matchScore(_ selector: String, stack: [String]) -> Int? {
        // Complex grouping/union/intersection syntax is deliberately ignored rather than misapplied.
        guard !selector.contains(where: { "()|&>".contains($0) }) else { return nil }
        let exclusions = selector.components(separatedBy: " - ")
        for exclusion in exclusions.dropFirst() where chainScore(exclusion, stack: stack) != nil { return nil }
        return chainScore(exclusions[0], stack: stack)
    }

    private static func chainScore(_ selector: String, stack: [String]) -> Int? {
        var components = selector.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !components.isEmpty else { return nil }
        if components[0].hasPrefix("L:") || components[0].hasPrefix("R:") {
            components[0] = String(components[0].dropFirst(2))
        }
        var stackIndex = stack.count - 1
        var score = 0
        for (componentIndex, component) in components.enumerated().reversed() {
            guard !component.isEmpty else { return nil }
            while stackIndex >= 0 && !(component == "*" || stack[stackIndex] == component || stack[stackIndex].hasPrefix(component + ".")) {
                stackIndex -= 1
            }
            guard stackIndex >= 0 else { return nil }
            // Nearest scope and deepest dotted selector win before parent specificity.
            if componentIndex == components.count - 1 {
                score += (stackIndex + 1) * 1_000_000 + component.split(separator: ".").count * 10_000
            } else {
                score += component.split(separator: ".").count * 100 + stackIndex
            }
            stackIndex -= 1
        }
        return score
    }
}

enum EditorThemeImportError: Error, LocalizedError {
    case invalidFormat, invalidColor, tooLarge, tooComplex, unsafeReference, referenceCycle, unreadable

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "This is not a supported VS Code, TextMate or JetBrains editor color scheme."
        case .invalidColor: "The theme contains an invalid color. Use #RGB, #RGBA, #RRGGBB or #RRGGBBAA."
        case .tooLarge: "The theme exceeds the import limit (1 MB per file, 4 MB total, 16 files)."
        case .tooComplex: "The theme exceeds the limit of 10,000 colors or token rules."
        case .unsafeReference: "Theme references must point to local files inside the selected theme's folder."
        case .referenceCycle: "The theme contains a circular or excessively deep include."
        case .unreadable: "The theme or one of its included files could not be read."
        }
    }
}

enum EditorThemeParser {
    static let maximumFileSize = 1_048_576
    static let maximumTotalSize = 4_194_304

    static func load(from url: URL, id: String = UUID().uuidString, isImported: Bool = true) throws -> EditorTheme {
        guard url.isFileURL else { throw EditorThemeImportError.unsafeReference }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if url.pathExtension.lowercased() == "icls" {
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: resolved)
                defer { try? handle.close() }
                data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            } catch { throw EditorThemeImportError.unreadable }
            guard data.count <= maximumFileSize else { throw EditorThemeImportError.tooLarge }
            return try JetBrainsEditorThemeParser.parse(data: data,
                name: url.deletingPathExtension().lastPathComponent, id: id, isImported: isImported)
        }
        var loader = Loader(root: resolved.deletingLastPathComponent())
        let document = try loader.load(url: resolved, depth: 0)
        return try document.theme(id: id, fallbackName: url.deletingPathExtension().lastPathComponent, isImported: isImported)
    }

    /// Parses standalone JSON/JSONC or plist data. Includes need a file URL and are rejected here.
    static func parse(data: Data, name: String = "Imported Theme", id: String = UUID().uuidString) throws -> EditorTheme {
        guard data.count <= maximumFileSize else { throw EditorThemeImportError.tooLarge }
        if String(data: data.prefix(1_024), encoding: .utf8)?.contains("<scheme") == true {
            return try JetBrainsEditorThemeParser.parse(data: data, name: name, id: id)
        }
        let object = try object(data: data)
        guard object["include"] == nil, !(object["tokenColors"] is String) else { throw EditorThemeImportError.unsafeReference }
        return try Document(object: object).theme(id: id, fallbackName: name, isImported: true)
    }

    private struct Loader {
        let root: URL
        var active: Set<URL> = []
        var totalSize = 0
        var fileCount = 0

        mutating func load(url: URL, depth: Int) throws -> Document {
            guard depth < 8, !active.contains(url) else { throw EditorThemeImportError.referenceCycle }
            guard fileCount < 16 else { throw EditorThemeImportError.tooLarge }
            active.insert(url)
            defer { active.remove(url) }
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            } catch { throw EditorThemeImportError.unreadable }
            totalSize += data.count
            fileCount += 1
            guard data.count <= maximumFileSize, totalSize <= maximumTotalSize else { throw EditorThemeImportError.tooLarge }
            let object = try EditorThemeParser.object(data: data)
            var document = Document()
            if let include = object["include"] {
                guard let path = include as? String else { throw EditorThemeImportError.invalidFormat }
                document = try load(url: reference(path, from: url), depth: depth + 1)
            }
            if let path = object["tokenColors"] as? String {
                let tokens = try load(url: reference(path, from: url), depth: depth + 1)
                document.merge(tokens)
            }
            document.merge(try Document(object: object))
            return document
        }

        private func reference(_ path: String, from url: URL) throws -> URL {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(":") else {
                throw EditorThemeImportError.unsafeReference
            }
            let result = url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard result.path.hasPrefix(root.path + "/") else { throw EditorThemeImportError.unsafeReference }
            return result
        }
    }

    private struct Document {
        var name: String?
        var appearance: EditorThemeAppearance?
        var colors: [String: EditorThemeColor] = [:]
        var rules: [EditorThemeTokenRule] = []

        init() {}

        init(object: [String: Any]) throws {
            name = (object["name"] as? String).map { value in
                String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(120))
            }
            switch object["type"] as? String {
            case "light", "hcLight": appearance = .light
            case "dark", "hc", "hcDark": appearance = .dark
            default: break
            }
            var explicitColors: [String: EditorThemeColor] = [:]
            if let values = object["colors"] as? [String: Any] {
                for (key, value) in values where !(value is NSNull) {
                    guard let value = value as? String, let color = EditorThemeColor(hex: value) else {
                        throw EditorThemeImportError.invalidColor
                    }
                    explicitColors[key] = color
                }
            } else if object["colors"] != nil { throw EditorThemeImportError.invalidFormat }
            let values: [[String: Any]]
            if let tokens = object["tokenColors"] as? [[String: Any]] { values = tokens }
            else if let settings = object["settings"] as? [[String: Any]] { values = settings }
            else if object["tokenColors"] == nil || object["tokenColors"] is String { values = [] }
            else { throw EditorThemeImportError.invalidFormat }
            for value in values {
                guard let settings = value["settings"] as? [String: Any] else { throw EditorThemeImportError.invalidFormat }
                var style = EditorThemeTokenStyle()
                for key in ["foreground", "background"] {
                    guard let raw = settings[key], !(raw is NSNull) else { continue }
                    guard let hex = raw as? String, let color = EditorThemeColor(hex: hex) else { throw EditorThemeImportError.invalidColor }
                    if key == "foreground" { style.foreground = color } else { style.background = color }
                }
                if let raw = settings["fontStyle"] {
                    guard let fontStyle = raw as? String else { throw EditorThemeImportError.invalidFormat }
                    style.fontStyle = fontStyle
                }
                var scopes: [String] = []
                if let raw = value["scope"] {
                    if let scope = raw as? String { scopes = [scope] }
                    else if let array = raw as? [String] { scopes = array }
                    else { throw EditorThemeImportError.invalidFormat }
                }
                scopes = scopes.flatMap { $0.components(separatedBy: ",") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if scopes.isEmpty {
                    if let foreground = style.foreground { colors["editor.foreground"] = foreground }
                    if let background = style.background { colors["editor.background"] = background }
                    for (source, destination) in [("caret", "editorCursor.foreground"), ("selection", "editor.selectionBackground"), ("selectionForeground", "editor.selectionForeground"), ("lineHighlight", "editor.lineHighlightBackground"), ("gutter", "editorGutter.background"), ("gutterForeground", "editorLineNumber.foreground")] {
                        if let raw = settings[source] {
                            guard let hex = raw as? String, let color = EditorThemeColor(hex: hex) else { throw EditorThemeImportError.invalidColor }
                            colors[destination] = color
                        }
                    }
                }
                rules.append(.init(scopes: scopes, style: style))
            }
            // Explicit VS Code editor colors take precedence over legacy TextMate defaults.
            colors.merge(explicitColors) { _, explicit in explicit }
        }

        mutating func merge(_ other: Document) {
            if let name = other.name { self.name = name }
            if let appearance = other.appearance { self.appearance = appearance }
            colors.merge(other.colors) { _, new in new }
            rules.append(contentsOf: other.rules)
        }

        func theme(id: String, fallbackName: String, isImported: Bool) throws -> EditorTheme {
            guard colors.count <= 10_000, rules.count <= 10_000 else { throw EditorThemeImportError.tooComplex }
            let supportedPrefixes = ["editor.", "editorCursor.", "editorGutter.", "editorLineNumber.",
                                     "editorError.", "editorWarning.", "editorInfo.", "editorSuggestWidget."]
            guard colors.keys.contains(where: { key in supportedPrefixes.contains { key.hasPrefix($0) } }) ||
                    rules.contains(where: { $0.style != EditorThemeTokenStyle() }) else {
                throw EditorThemeImportError.invalidFormat
            }
            let resolvedAppearance = appearance ?? ((colors["editor.background"]?.brightness ?? 0) > 0.5 ? .light : .dark)
            let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = String(String.UnicodeScalarView(fallbackName.unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }).prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            return EditorTheme(id: id, name: title?.isEmpty == false ? title! : (fallback.isEmpty ? "Imported Theme" : fallback),
                appearance: resolvedAppearance, colors: colors, tokenRules: rules, isImported: isImported)
        }
    }

    private static func object(data: Data) throws -> [String: Any] {
        let isBinaryPlist = data.starts(with: Data("bplist".utf8))
        guard isBinaryPlist || String(data: data, encoding: .utf8) != nil else { throw EditorThemeImportError.invalidFormat }
        let text = String(data: data, encoding: .utf8) ?? ""
        if isBinaryPlist || text.trimmingCharacters(in: .whitespacesAndNewlines).first == "<" {
            var plistData = data
            if !isBinaryPlist {
                guard !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw EditorThemeImportError.invalidFormat }
                var xml = text
                // Ordinary plist exports declare Apple's public DTD. Strip it before
                // parsing so even that declaration never needs external resolution.
                while let range = xml.range(of: "(?is)<!DOCTYPE[^>]*>", options: .regularExpression) {
                    let declaration = String(xml[range])
                    guard !declaration.contains("["), declaration.contains("DTD PLIST 1.0//EN"),
                          declaration.contains("www.apple.com/DTDs/PropertyList-1.0.dtd") else {
                        throw EditorThemeImportError.invalidFormat
                    }
                    xml.removeSubrange(range)
                }
                plistData = Data(xml.utf8)
            }
            guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                throw EditorThemeImportError.invalidFormat
            }
            return object
        }
        do {
            let stripped = try stripJSONComments(data)
            guard let object = try JSONSerialization.jsonObject(with: stripped) as? [String: Any] else {
                throw EditorThemeImportError.invalidFormat
            }
            return object
        } catch { throw EditorThemeImportError.invalidFormat }
    }

    private static func stripJSONComments(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw EditorThemeImportError.invalidFormat }
        let bytes = Array(text.utf8)
        var result = bytes
        var index = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let current = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if current == 92 { escaped = true }
                else if current == 34 { inString = false }
                index += 1
            } else if current == 34 {
                inString = true
                index += 1
            } else if current == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 {
                    result[index] = 32
                    index += 1
                }
            } else if current == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                result[index] = 32
                result[index + 1] = 32
                index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 42 && bytes[index + 1] == 47 {
                        result[index] = 32
                        result[index + 1] = 32
                        index += 2
                        closed = true
                        break
                    }
                    if bytes[index] != 10 && bytes[index] != 13 { result[index] = 32 }
                    index += 1
                }
                guard closed else { throw EditorThemeImportError.invalidFormat }
            } else { index += 1 }
        }
        guard !inString else { throw EditorThemeImportError.invalidFormat }
        // JSONC permits trailing commas. The second pass only touches commas outside strings.
        index = 0
        inString = false
        escaped = false
        while index < result.count {
            let current = result[index]
            if inString {
                if escaped { escaped = false }
                else if current == 92 { escaped = true }
                else if current == 34 { inString = false }
            } else if current == 34 { inString = true }
            else if current == 44 {
                var next = index + 1
                while next < result.count && [9, 10, 13, 32].contains(result[next]) { next += 1 }
                if next < result.count && [93, 125].contains(result[next]) { result[index] = 32 }
            }
            index += 1
        }
        return Data(result)
    }
}
