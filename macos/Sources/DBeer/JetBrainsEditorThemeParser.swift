import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports the editor scheme exported by IntelliJ-based IDEs. UI theme plugins
/// and IDE extensions are not loaded or executed.
enum JetBrainsEditorThemeParser {
    static func parse(data: Data, name: String = "Imported Theme", id: String = UUID().uuidString,
                      isImported: Bool = true) throws -> EditorTheme {
        let scheme = try read(data)
        guard scheme.parent != nil || !scheme.colors.isEmpty || !scheme.attributes.isEmpty else {
            throw EditorThemeImportError.invalidFormat
        }
        var inherited = try parentScheme(named: scheme.parent, active: [])
        inherited.merge(scheme)
        return try inherited.theme(name: name, id: id, isImported: isImported)
    }

    private static func parentScheme(named name: String?, active: Set<String>) throws -> Scheme {
        guard let name, !name.isEmpty else { return Scheme() }
        guard !active.contains(name) else { throw EditorThemeImportError.referenceCycle }
        let resource: String
        switch name {
        case "Default": resource = "jetbrains-default"
        case "Darcula": resource = "jetbrains-darcula"
        default: throw JetBrainsThemeImportError.unsupportedParent(name)
        }
        guard let url = Bundle.module.url(forResource: resource, withExtension: "icls", subdirectory: "EditorThemes"),
              let data = try? Data(contentsOf: url) else { throw EditorThemeImportError.unreadable }
        let scheme = try read(data)
        var inherited = try parentScheme(named: scheme.parent, active: active.union([name]))
        inherited.merge(scheme)
        return inherited
    }

    private static func read(_ data: Data) throws -> Scheme {
        guard data.count <= EditorThemeParser.maximumFileSize else { throw EditorThemeImportError.tooLarge }
        // JetBrains exports UTF-8. Reject DTDs outright, including internal
        // entities; disabling external expansion alone does not stop entity bombs.
        guard let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw EditorThemeImportError.invalidFormat }
        let delegate = TreeParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid,
              let root = delegate.root, root.name == "scheme" else { throw EditorThemeImportError.invalidFormat }
        var scheme = Scheme()
        scheme.name = root.attributes["name"]
        scheme.parent = root.attributes["parent_scheme"]
        for child in root.children {
            if child.name == "colors" {
                for option in child.children where option.name == "option" {
                    if let name = option.attributes["name"] { scheme.colors[name] = option.attributes["value"] ?? "" }
                }
            } else if child.name == "attributes" {
                for option in child.children where option.name == "option" {
                    guard let name = option.attributes["name"] else { continue }
                    var attribute = Attribute(base: option.attributes["baseAttributes"])
                    if let value = option.children.first(where: { $0.name == "value" }) {
                        attribute.hasValue = true
                        for field in value.children where field.name == "option" {
                            if let key = field.attributes["name"] { attribute.values[key] = field.attributes["value"] ?? "" }
                        }
                    }
                    if attribute.hasValue || attribute.base != nil { scheme.attributes[name] = attribute }
                }
            }
        }
        return scheme
    }

    private struct Attribute {
        var base: String?
        var hasValue = false
        var values: [String: String] = [:]
    }

    private struct Scheme {
        var name: String?
        var parent: String?
        var colors: [String: String] = [:]
        var attributes: [String: Attribute] = [:]

        mutating func merge(_ other: Scheme) {
            if let name = other.name { self.name = name }
            colors.merge(other.colors) { _, child in child }
            attributes.merge(other.attributes) { _, child in child }
        }

        func style(_ key: String, active: Set<String> = []) throws -> EditorThemeTokenStyle? {
            guard let attribute = attributes[key] else { return nil }
            guard !active.contains(key), active.count < 32 else { throw EditorThemeImportError.referenceCycle }
            if !attribute.hasValue, let base = attribute.base {
                return try style(base, active: active.union([key]))
            }
            var style = EditorThemeTokenStyle()
            if let value = attribute.values["FOREGROUND"], !value.isEmpty { style.foreground = try color(value) }
            if let value = attribute.values["BACKGROUND"], !value.isEmpty { style.background = try color(value) }
            // An explicit value replaces the parent TextAttributes, including
            // empty values, so a missing FONT_TYPE clears inherited bold/italic.
            if attribute.hasValue {
                let raw = attribute.values["FONT_TYPE"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
                guard let type = Int(raw), (0...3).contains(type) else { throw EditorThemeImportError.invalidFormat }
                style.fontStyle = [type & 1 != 0 ? "bold" : nil, type & 2 != 0 ? "italic" : nil]
                    .compactMap { $0 }.joined(separator: " ")
                if attribute.values["EFFECT_TYPE"] == "1" {
                    style.fontStyle = [style.fontStyle!, "underline"].filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
            return style
        }

        func theme(name fallbackName: String, id: String, isImported: Bool) throws -> EditorTheme {
            var palette: [String: EditorThemeColor] = [:]
            let mapping = [
                "CARET_COLOR": "editorCursor.foreground", "CARET_ROW_COLOR": "editor.lineHighlightBackground",
                "SELECTION_BACKGROUND": "editor.selectionBackground", "SELECTION_FOREGROUND": "editor.selectionForeground",
                "SELECTION_BACKGROUND_INACTIVE": "editor.inactiveSelectionBackground",
                "GUTTER_BACKGROUND": "editorGutter.background", "LINE_NUMBERS_COLOR": "editorLineNumber.foreground",
                "LINE_NUMBER_ON_CARET_ROW_COLOR": "editorLineNumber.activeForeground",
                "RIGHT_MARGIN_COLOR": "editorRuler.foreground", "LOOKUP_COLOR": "editorSuggestWidget.background",
                "LOOKUP_SELECTION_COLOR": "editorSuggestWidget.selectedBackground",
            ]
            for (source, destination) in mapping {
                if let raw = colors[source], !raw.isEmpty { palette[destination] = try color(raw) }
            }
            if let text = try style("TEXT") {
                palette["editor.foreground"] = text.foreground
                palette["editor.background"] = text.background
            }
            // AbstractColorsScheme supplies black/white for absent TEXT colors.
            // These are IntelliJ's real defaults, including the Default parent.
            if palette["editor.foreground"] == nil { palette["editor.foreground"] = EditorThemeColor(hex: "#000000") }
            if palette["editor.background"] == nil {
                palette["editor.background"] = try colors["BACKGROUND"].flatMap { $0.isEmpty ? nil : $0 }.map(color)
                    ?? EditorThemeColor(hex: "#FFFFFF")
            }
            var rules: [EditorThemeTokenRule] = []
            let generic: [(String, [String])] = [
                ("DEFAULT_KEYWORD", ["keyword"]), ("DEFAULT_STRING", ["string"]),
                ("DEFAULT_NUMBER", ["constant.numeric"]), ("DEFAULT_LINE_COMMENT", ["comment.line"]),
                ("DEFAULT_BLOCK_COMMENT", ["comment.block"]), ("DEFAULT_IDENTIFIER", ["variable.other"]),
                ("DEFAULT_OPERATION_SIGN", ["keyword.operator"]),
                ("DEFAULT_FUNCTION_CALL", ["entity.name.function"]),
            ]
            let sql: [(String, [String])] = [
                ("SQL_KEYWORD", ["keyword.other.sql", "keyword.control.sql"]), ("SQL_STRING", ["string.quoted.single.sql"]),
                ("SQL_NUMBER", ["constant.numeric.sql"]), ("SQL_COMMENT", ["comment.line.sql", "comment.line.double-dash.sql", "comment.block.sql"]),
                ("SQL_LINE_COMMENT", ["comment.line.sql", "comment.line.double-dash.sql"]), ("SQL_BLOCK_COMMENT", ["comment.block.sql"]),
                ("SQL_IDENTIFIER", ["variable.other.sql"]), ("SQL_COLUMN", ["variable.other.column.sql"]),
                ("SQL_DATABASE_OBJECT", ["variable.other.object.sql"]), ("SQL_FUNCTION", ["entity.name.function.sql"]),
                ("SQL_TYPE", ["storage.type.sql"]), ("SQL_OPERATION_SIGN", ["keyword.operator.sql"]),
            ]
            for (key, scopes) in generic + sql {
                if var value = try style(key) {
                    // TextAttributes inherit plain text colors when their own
                    // foreground/background are absent, rather than a broader
                    // syntax category's style.
                    if value.foreground == nil { value.foreground = palette["editor.foreground"] }
                    rules.append(EditorThemeTokenRule(scopes: scopes, style: value))
                }
            }
            for (key, destination) in [("ERRORS_ATTRIBUTES", "editorError.foreground"),
                ("WARNING_ATTRIBUTES", "editorWarning.foreground"), ("INFO_ATTRIBUTES", "editorInfo.foreground")] {
                if let attribute = attributes[key], let raw = attribute.values["EFFECT_COLOR"], !raw.isEmpty {
                    palette[destination] = try color(raw)
                }
            }
            func title(_ value: String) -> String {
                String(value.filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }.prefix(120))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let requestedTitle = title(name ?? fallbackName)
            let fallbackTitle = title(fallbackName)
            return EditorTheme(id: id, name: requestedTitle.isEmpty ? (fallbackTitle.isEmpty ? "Imported Theme" : fallbackTitle) : requestedTitle,
                appearance: palette["editor.background"]!.brightness > 0.5 ? .light : .dark,
                colors: palette, tokenRules: rules, isImported: isImported)
        }

        private func color(_ raw: String) throws -> EditorThemeColor {
            // IntelliJ serializes RGB without # and may drop leading zeroes.
            let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            guard !hex.isEmpty, hex.count <= 8,
                  hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
                throw EditorThemeImportError.invalidColor
            }
            let padded = hex.count <= 6 ? String(repeating: "0", count: 6 - hex.count) + hex : hex
            guard let result = EditorThemeColor(hex: "#" + padded) else { throw EditorThemeImportError.invalidColor }
            return result
        }
    }

    private final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    }

    private final class TreeParser: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var invalid = false
        var count = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard stack.count < 32, count < 20_000, namespaceURI == nil else {
                invalid = true; parser.abortParsing(); return
            }
            let node = Node(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node }
            else { invalid = true; parser.abortParsing(); return }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            invalid = true
            parser.abortParsing()
            return nil
        }
    }
}

enum JetBrainsThemeImportError: Error, LocalizedError {
    case unsupportedParent(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedParent:
            "This IntelliJ scheme uses an unavailable parent. Supported parents are Default and Darcula. Export a self-contained scheme or use one of these parents."
        }
    }
}
