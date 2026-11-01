import Foundation
import Testing
@testable import DBeer

/// Pure value and local fixture checks. No windows, application activation or database sessions.
@MainActor
struct QueryParameterModelTests {
    private func input(_ type: QueryParameterType, _ value: String, isNull: Bool = false) -> SQLParameterInput {
        SQLParameterInput(definition: SQLParameterDefinition(name: "value", type: type), value: value, isNull: isNull)
    }

    @Test func nullEmptyTextAndLiteralNullRemainDistinctOnTheWire() throws {
        let bindings = try [input(.text, "", isNull: true), input(.text, ""), input(.text, "NULL")].map { try $0.validate() }
        #expect(bindings.map(\.value) == [nil, "", "NULL"])
        let data = try JSONEncoder().encode(bindings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(Set(object[0].keys) == ["name", "type", "value"])
        #expect(object[0]["value"] is NSNull)
        #expect(try JSONDecoder().decode([QueryParameterBinding].self, from: data) == bindings)
        let missingValue = Data(#"{"name":"value","type":"text"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(QueryParameterBinding.self, from: missingValue) }
    }

    @Test func exactNumbersAreValidatedWithoutFloatingPointConversion() throws {
        for value in ["-9223372036854775808", "9223372036854775807", "+001", "-0"] {
            #expect(try input(.integer, value).validate().value == value)
        }
        for value in ["9223372036854775808", "-9223372036854775809", "1.0", "1e2", " 1", "1\n", "١"] {
            #expect(throws: QueryParameterError.self) { try input(.integer, value).validate() }
        }
        for value in ["9007199254740993.12345678901234567890", "-0.000000000000000001", "+001.2300", "42"] {
            #expect(try input(.decimal, value).validate().value == value)
        }
        for value in ["1e3", ".5", "1.", "NaN", "Infinity", "1,2", "1\n", ""] {
            #expect(throws: QueryParameterError.self) { try input(.decimal, value).validate() }
        }
    }

    @Test func booleansDatesAndWallTimeTimestampsHaveUnambiguousSyntax() throws {
        for value in ["true", "false"] { #expect(try input(.boolean, value).validate().value == value) }
        for value in ["TRUE", "False", "1", "0", " true", ""] {
            #expect(throws: QueryParameterError.self) { try input(.boolean, value).validate() }
        }
        for value in ["0001-01-01", "2000-02-29", "2024-02-29", "9999-12-31"] {
            #expect(try input(.date, value).validate().value == value)
        }
        for value in ["0000-01-01", "1900-02-29", "2025-02-29", "2026-04-31", "2026-00-01", "2026-01-00", "2026-1-01", "2026-01-01Z"] {
            #expect(throws: QueryParameterError.self) { try input(.date, value).validate() }
        }
        for value in ["2026-11-01 00:00:00", "2026-11-01 23:59:59.1", "2024-02-29 12:34:56.123456"] {
            #expect(try input(.timestamp, value).validate().value == value)
        }
        for value in ["2026-11-01T12:34:56", "2026-11-01 24:00:00", "2026-11-01 12:60:00", "2026-11-01 12:34:60", "2026-11-01 12:34:56.", "2026-11-01 12:34:56.1234567", "2026-11-01 12:34:56Z", "2026-11-01 12:34:56+03:00", "2025-02-29 12:34:56"] {
            #expect(throws: QueryParameterError.self) { try input(.timestamp, value).validate() }
        }
        #expect(try input(.integer, "invalid", isNull: true).validate().value == nil)
    }

    @Test func definitionNamesCountsAndValueBytesAreBounded() throws {
        let valid = ["a", "_", "order_id", "ID2", String(repeating: "a", count: 64)]
        for name in valid { #expect(SQLParameterDefinition(name: name, type: .text).isValid) }
        for name in ["", "1id", "a-b", ":id", "résumé", "value\n", String(repeating: "a", count: 65)] {
            #expect(!SQLParameterDefinition(name: name, type: .text).isValid)
        }
        let definitions = (0..<128).map { SQLParameterDefinition(name: "p\($0)", type: .text) }
        try SQLParameterDefinition.validate(definitions)
        #expect(throws: QueryParameterError.self) {
            try SQLParameterDefinition.validate(definitions + [SQLParameterDefinition(name: "extra", type: .text)])
        }
        #expect(throws: QueryParameterError.self) { try SQLParameterDefinition.validate([definitions[0], definitions[0]]) }
        let limit = SQLParameterInput.maximumValueBytes
        #expect(try input(.text, String(repeating: "x", count: limit)).validate().value?.utf8.count == limit)
        #expect(throws: QueryParameterError.self) { try input(.text, String(repeating: "é", count: limit / 2 + 1)).validate() }
        let first = input(.text, String(repeating: "x", count: limit / 2 + 1))
        var second = first
        second.definition.name = "other"
        #expect(throws: QueryParameterError.self) { try SQLParameterInput.validate([first, second]) }
        #expect(throws: QueryParameterError.self) { try input(.text, "contains\0NUL").validate() }
    }

    @Test func libraryMetadataRoundTripsDefinitionsAndPreservesThemWhenRenamed() throws {
        let library = SQLLibrary()
        let definitions = [SQLParameterDefinition(name: "customer_id", type: .integer), SQLParameterDefinition(name: "since", type: .timestamp)]
        let entry = try library.upsertEntry(fileURL: URL(fileURLWithPath: "/query-parameter-fixtures/report.sql"), parameters: definitions)
        let encoded = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(SQLLibraryEntry.self, from: encoded) == entry)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metadata = try #require(object["parameters"] as? [[String: Any]])
        #expect(metadata.allSatisfy { Set($0.keys) == ["name", "type"] })
        let renamed = try library.upsertEntry(id: entry.id, fileURL: URL(fileURLWithPath: "/query-parameter-fixtures/renamed.sql"), tags: ["kept"])
        #expect(renamed.parameters == definitions)
        let cleared = try library.upsertEntry(id: entry.id, fileURL: renamed.fileURL, parameters: [])
        #expect(cleared.parameters.isEmpty)
        let originalShape = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        #expect(Set(originalShape.keys) == ["id", "fileURL", "folder", "tags", "scope"])
        #expect(try JSONDecoder().decode(SQLLibraryEntry.self, from: JSONSerialization.data(withJSONObject: originalShape)).parameters.isEmpty)
    }

    @Test func malformedDefinitionsNeverReplaceExistingLibraryMetadata() throws {
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: URL(fileURLWithPath: "/query-parameter-fixtures/report.sql"))
        let before = library.snapshot
        #expect(throws: (any Error).self) {
            try library.upsertEntry(id: entry.id, fileURL: entry.fileURL,
                parameters: [SQLParameterDefinition(name: "repeated", type: .integer), SQLParameterDefinition(name: "repeated", type: .text)])
        }
        #expect(library.snapshot == before)
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for parameters: Any in [NSNull(), [["name": "id", "type": "integer", "value": "not metadata"]], [["name": "id", "type": "future"]]] {
            var object = original
            object["parameters"] = parameters
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SQLLibraryEntry.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func sharedQueryParameterFixtureKeepsTypedValuesAndRejectsMalformedBindings() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/query-parameters-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["capability"] as? String == "queryParametersV1")
        let execute = try #require(fixture["execute"] as? [String: Any])
        let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: execute))
        let bindings = try #require(command.parameters)
        try QueryParameterBinding.validate(bindings)
        #expect(bindings.map(\.type) == [.text, .integer, .decimal, .boolean, .date, .timestamp, .text, .text])
        #expect(bindings[1].value == "-9223372036854775808")
        #expect(bindings[2].value == "12345678901234567890.123456789")
        #expect(bindings[6].value == nil && bindings[7].value == "")
        let assessment = try #require(fixture["assessment"] as? [String: Any])
        let assessmentCommand = try JSONDecoder().decode(BackendCommand.self,
            from: JSONSerialization.data(withJSONObject: assessment))
        #expect(assessmentCommand.operations?.first?.parameters == bindings)
        let malformed = try #require(fixture["invalidParameters"] as? [Any])
        for value in malformed {
            let invalidData = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Error).self) {
                let invalid = try JSONDecoder().decode([QueryParameterBinding].self, from: invalidData)
                try QueryParameterBinding.validate(invalid)
            }
        }
    }
}
