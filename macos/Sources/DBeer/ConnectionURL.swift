import Foundation

/// Imports the URL subset representable by native connection fields. Raw URLs
/// and passwords never become profile metadata or error descriptions.
struct ConnectionURL {
    let engine: DatabaseEngine
    let host: String
    let port: Int
    let database: String
    let user: String?
    let password: String?
    let sslMode: String?
    let sslRootCert: String?

    enum Failure: LocalizedError, Equatable {
        case invalid, unsupportedEngine, unsupportedOption, duplicateOption, invalidTLS, engineMismatch

        var errorDescription: String? {
            switch self {
            case .invalid: "Enter a URL with one host, a port from 1 to 65535, and a database name. Percent-encode special characters."
            case .unsupportedEngine: "Use a PostgreSQL or MySQL URL, optionally prefixed with jdbc:."
            case .unsupportedOption: "This URL includes options DBeer cannot apply. Supported options are user, password, database name and database TLS mode or CA file."
            case .duplicateOption: "Remove duplicate or conflicting connection options from the URL."
            case .invalidTLS: "The URL specifies a TLS mode that this database engine does not support in DBeer."
            case .engineMismatch: "The URL must use this saved connection's database engine. Create or duplicate a connection to use another engine."
            }
        }
    }

    static func parse(_ input: String) throws -> Self {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              hasValidEscapes(text) else { throw Failure.invalid }
        let jdbc = text.lowercased().hasPrefix("jdbc:")
        if jdbc { text = String(text.dropFirst(5)) }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else { throw Failure.invalid }
        let engine: DatabaseEngine
        switch scheme {
        case "postgres", "postgresql": engine = .postgresql
        case "mysql": engine = .mysql
        default: throw Failure.unsupportedEngine
        }
        guard text.lowercased().hasPrefix(scheme + "://"), components.fragment == nil,
              let rawHost = components.percentEncodedHost else { throw Failure.invalid }
        var host = try decode(rawHost)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard validHost(host) else { throw Failure.invalid }
        let authority = text.dropFirst(scheme.count + 3).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.hasSuffix(":"), authority.filter({ $0 == "@" }).count <= 1 else { throw Failure.invalid }
        let endpoint = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        let portText: Substring?
        if endpoint.hasPrefix("[") {
            guard let end = endpoint.firstIndex(of: "]") else { throw Failure.invalid }
            let suffix = endpoint[endpoint.index(after: end)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { throw Failure.invalid }
            portText = suffix.isEmpty ? nil : suffix.dropFirst()
        } else {
            let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw Failure.invalid }
            portText = parts.count == 2 ? parts[1] : nil
        }
        let port: Int
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(portText), (1...65_535).contains(value) else { throw Failure.invalid }
            port = value
        } else { port = engine.defaultPort }

        var options: [String: String] = [:]
        if let user = components.percentEncodedUser { options["user"] = try decode(user) }
        if let password = components.percentEncodedPassword { options["password"] = try decode(password) }
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            guard path.hasPrefix("/"), !path.dropFirst().contains("/") else { throw Failure.invalid }
            options["database"] = try decode(String(path.dropFirst()))
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw Failure.invalid }
                let name = try decode(String(parts[0]), formEncoded: jdbc)
                let value = try decode(String(parts[1]), formEncoded: jdbc)
                let key: String
                switch (engine, name) {
                case (_, "user"), (_, "password"): key = name
                case (.postgresql, "dbname"): key = "database"
                case (.postgresql, "sslmode"), (.mysql, "ssl-mode"), (.mysql, "sslMode"): key = "sslMode"
                case (.postgresql, "sslrootcert"), (.mysql, "ssl-ca"): key = "sslRootCert"
                default: throw Failure.unsupportedOption
                }
                guard options[key] == nil else { throw Failure.duplicateOption }
                options[key] = value
            }
        }
        guard let database = options["database"], !database.isEmpty,
              database.utf8.count <= 1_024, (options["user"]?.utf8.count ?? 0) <= 1_024 else { throw Failure.invalid }
        var sslMode: String?
        if let mode = options["sslMode"] {
            sslMode = engine == .mysql ? mysqlTLSModes[mode.uppercased()] : mode
            guard let sslMode, engine.sslModes.contains(sslMode) else { throw Failure.invalidTLS }
        }
        return Self(engine: engine, host: host, port: port, database: database, user: options["user"],
            password: options["password"], sslMode: sslMode, sslRootCert: options["sslRootCert"])
    }

    /// A canonical preview deliberately excludes the password, including passwords
    /// imported through query parameters. SSH and execution policy stay separate.
    static func format(engine: DatabaseEngine, host: String, port: String, database: String,
                       user: String, sslMode: String, sslRootCert: String) -> String? {
        guard [.postgresql, .mysql].contains(engine), validHost(host), !database.isEmpty, !database.contains("\0"),
              let port = Int(port), (1...65_535).contains(port), engine.sslModes.contains(sslMode) else { return nil }
        var components = URLComponents()
        components.scheme = engine == .postgresql ? "postgresql" : "mysql"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.percentEncodedPath = "/" + encode(database)
        if !user.isEmpty { components.percentEncodedUser = encode(user) }
        let mode = engine == .postgresql ? sslMode : mysqlTLSModes.first(where: { $0.value == sslMode })?.key
        guard let mode else { return nil }
        var query = [URLQueryItem(name: engine == .postgresql ? "sslmode" : "ssl-mode", value: mode)]
        if !sslRootCert.isEmpty {
            query.append(URLQueryItem(name: engine == .postgresql ? "sslrootcert" : "ssl-ca", value: sslRootCert))
        }
        components.queryItems = query
        guard let result = components.string, result.utf8.count <= 16_384 else { return nil }
        return result
    }

    private static let mysqlTLSModes = ["DISABLED": "disable", "REQUIRED": "require", "VERIFY_CA": "verify-ca", "VERIFY_IDENTITY": "verify-full"]

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 1_024 &&
            !host.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) } &&
            !host.contains(where: { "/\\,@?#[]%".contains($0) }) &&
            (!host.contains(":") || CassandraSettings.isNumericAddress(host))
    }

    private static func decode(_ value: String, formEncoded: Bool = false) throws -> String {
        let encoded = formEncoded ? value.replacingOccurrences(of: "+", with: "%20") : value
        guard let decoded = encoded.removingPercentEncoding, !decoded.contains("\0") else { throw Failure.invalid }
        return decoded
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private static func hasValidEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}
