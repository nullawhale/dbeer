import Foundation
import Testing
@testable import DBeer

/// Synthetic fixed-column decoding and exact-value checks only. No UI, helper
/// process, credentials, or database connection is used by this suite.
struct PostgresTypeCatalogTests {
    private func reference(oid: String = "40001", kind: String = "enum") -> PostgresTypeReference {
        .init(profileID: UUID(), serviceSessionID: "captured-service", serviceGeneration: UUID(), engine: .postgresql,
            database: "fixture", schema: "public", name: "status", objectKind: kind, localOID: oid,
            settingsRevision: UUID(), policy: ExecutionPolicy(readOnly: true))
    }

    private func response(_ columns: [String], rows: [[String?]], truncated: Bool = false) -> BackendMessage {
        BackendMessage(type: "query.result", requestId: "fixture", sessionId: "captured-service", queryId: "query",
            transactionStatus: .idle, durationMs: 1,
            columns: columns.enumerated().map { ResultColumn(index: $0.offset, name: $0.element, nativeType: "text") },
            rows: rows, commandTag: "SELECT \(rows.count)", rowCount: Int64(rows.count), displayedRowCount: rows.count,
            truncated: truncated)
    }

    private func detailRow() -> [String?] {
        ["status", "enum", "public", "40001", "enum", "owner", "CREATE TYPE public.status AS ENUM (E'');",
         "complete", "An unused enum", "true", "true", "true", "No removal or reordering.", "Readonly preview is permitted."]
    }

    @Test func strictColumnsWidthsFlagsAndIdentityRejectMalformedMetadata() throws {
        let ref = reference()
        let valid = response(PostgresTypeCatalog.detailColumns, rows: [detailRow()])
        #expect(try PostgresTypeCatalog.decodeDetails(valid, reference: ref).addEnumValueSupported)
        var bad = valid
        bad.columns?[1] = ResultColumn(index: 1, name: "name", nativeType: "text")
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
        bad = valid
        bad.rows?[0][3] = "40002"
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
        bad = valid
        bad.rows?[0][9] = "yes"
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
        bad = valid
        bad.rows?[0].removeLast()
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
        bad = valid
        bad.truncated = true
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
        bad = valid
        bad.rows = []
        bad.displayedRowCount = 0
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeDetails(bad, reference: ref) }
    }

    @Test func enumOrderIsServerOrderAndEmptyOrCanonicallyEquivalentLabelsRemainExact() throws {
        let labels = ["z", "", "a\\b", " spaced ", "é", "e\u{301}", "🌍"]
        let rows: [[String?]] = labels.enumerated().map { index, label in [label, String(index + 1), "\(index).5"] }
        let reply = response(PostgresTypeCatalog.valueColumns, rows: rows)
        let values = try PostgresTypeCatalog.decodeEnumValues(reply)
        #expect(values.map(\.position) == [1, 2, 3, 4, 5, 6, 7])
        #expect(values.map { Data($0.label.utf8) } == labels.map { Data($0.utf8) })
        #expect(values[1].label.isEmpty && values[0].label == "z" && values[6].label == "🌍")
        #expect(try PostgresTypeCatalog.decodeEnumValues(response(PostgresTypeCatalog.valueColumns, rows: [])).isEmpty)
        #expect(try PostgresTypeCatalog.decodeEnumValues(response(PostgresTypeCatalog.valueColumns, rows: [], truncated: true)).isEmpty)
        var malformed = reply
        malformed.rows?[1][1] = "1"
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeEnumValues(malformed) }
        malformed = reply
        malformed.rows?[1][0] = nil
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeEnumValues(malformed) }
        malformed = reply
        malformed.rows?[1][0] = "z"
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeEnumValues(malformed) }
    }

    @Test func dependencyAddressesPreserveSubobjectsAndNullableObjectNames() throws {
        let rows: [[String?]] = [
            ["incoming", "table column", "public", "orders", "public.orders.state", "normal", "1259", "42001", "2", "1247", "40001", "0"],
            ["outgoing", "extension", nil, nil, "synthetic_extension", "extension", "1247", "40001", "0", "3079", "50001", "0"]
        ]
        let decoded = try PostgresTypeCatalog.decodeDependencies(response(PostgresTypeCatalog.dependencyColumns, rows: rows))
        #expect(decoded[0].objectSubID == "2" && decoded[0].direction == "incoming")
        #expect(decoded[1].objectSchema == nil && decoded[1].objectName == nil && decoded[1].dependencyClass == "extension")
        var invalid = rows
        invalid[0][8] = "-1"
        #expect(throws: PostgresTypeCatalogFailure.self) {
            try PostgresTypeCatalog.decodeDependencies(response(PostgresTypeCatalog.dependencyColumns, rows: invalid))
        }
        #expect(try PostgresTypeCatalog.decodeDependencies(response(PostgresTypeCatalog.dependencyColumns, rows: [])).isEmpty)
    }

    @Test func definitionsAndPreviewKeepUnavailableSeparateFromPartialAndRejectProvenanceSQL() throws {
        let ref = reference()
        var row = detailRow()
        row[7] = "partial"
        #expect(try PostgresTypeCatalog.decodeDetails(response(PostgresTypeCatalog.detailColumns, rows: [row]), reference: ref).definition != nil)
        row[7] = "unavailable"
        row[6] = nil
        let unavailable = try PostgresTypeCatalog.decodeDetails(response(PostgresTypeCatalog.detailColumns, rows: [row]), reference: ref)
        #expect(unavailable.definitionStatus == .unavailable && unavailable.definition == nil)
        let change = TypeChange(operation: "addEnumValue", value: "")
        let sql = "ALTER TYPE public.status ADD VALUE E'';"
        let reply = response(PostgresTypeCatalog.previewColumns, rows: [[sql, "Commit before using the added label."]])
        #expect(try PostgresTypeCatalog.decodePreview(reply, change: change).sql == sql)
        var bad = reply
        bad.sql = sql
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodePreview(bad, change: change) }
        bad = reply
        bad.truncated = true
        #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodePreview(bad, change: change) }
    }

    @Test func boundedTypePropertiesAllowPartialDetailsWithoutCreateSQL() throws {
        for kind in ["enum", "domain", "composite"] {
            let objectKind = kind == "enum" ? "enum" : "type"
            let ref = reference(kind: objectKind)
            var row = detailRow()
            row[1] = objectKind
            row[4] = kind
            row[6] = nil
            row[7] = "partial"
            row[8] = "Category: \(kind)\nType properties exceed the metadata bound. A complete CREATE definition is unavailable."
            row[10] = "false"
            row[11] = "false"
            row[12] = kind == "enum"
                ? "Enum labels exceed the metadata bound, so value previews are unavailable."
                : "Only type rename is supported here; structural changes require reviewed manual SQL."
            let decoded = try PostgresTypeCatalog.decodeDetails(response(PostgresTypeCatalog.detailColumns, rows: [row]), reference: ref)
            #expect(decoded.definitionStatus == .partial && decoded.definition == nil && decoded.renameSupported)
            #expect(decoded.details?.contains("metadata bound") == true && !decoded.addEnumValueSupported)
            try PostgresTypeCatalog.validateChange(TypeChange(operation: "renameType", newName: "renamed"),
                details: decoded, values: nil, valuesComplete: false)
            row[7] = "complete"
            #expect(throws: PostgresTypeCatalogFailure.self) {
                try PostgresTypeCatalog.decodeDetails(response(PostgresTypeCatalog.detailColumns, rows: [row]), reference: ref)
            }
        }
    }

    @Test func operationValidationPreservesEmptyLabelsAndRejectsUnavailableOrOversizedNames() throws {
        let details = try PostgresTypeCatalog.decodeDetails(response(PostgresTypeCatalog.detailColumns, rows: [detailRow()]), reference: reference())
        let values = [PostgresEnumValue(label: "", position: 1, sortOrder: "1")]
        try PostgresTypeCatalog.validateChange(TypeChange(operation: "addEnumValue", value: ""), details: details, values: values, valuesComplete: true)
        try PostgresTypeCatalog.validateChange(TypeChange(operation: "renameEnumValue", oldValue: "", value: "🌍\\'"),
            details: details, values: values, valuesComplete: true)
        for change in [TypeChange(operation: "renameType", newName: ""),
                       TypeChange(operation: "renameType", newName: String(repeating: "🌍", count: 16)),
                       TypeChange(operation: "addEnumValue", value: "a\0b"),
                       TypeChange(operation: "addEnumValue"),
                       TypeChange(operation: "deleteEnumValue", oldValue: "") ] {
            #expect(throws: PostgresTypeCatalogFailure.self) {
                try PostgresTypeCatalog.validateChange(change, details: details, values: values, valuesComplete: true)
            }
        }
        #expect(throws: PostgresTypeCatalogFailure.self) {
            try PostgresTypeCatalog.validateChange(TypeChange(operation: "renameEnumValue", oldValue: "", value: "next"),
                details: details, values: values, valuesComplete: false)
        }
    }

    @Test func treeAndSearchColumnsRequireCanonicalLocalHandlesAndKeepKindsSeparate() throws {
        let reply = response(PostgresTypeCatalog.objectColumns, rows: [
            ["status", "enum", "public", "40001", "enum"],
            ["code", "type", "public", "40002", "domain"],
            ["orders", "table", "public", nil, nil]
        ])
        let objects = try PostgresTypeCatalog.decodeObjects(reply)
        #expect(objects.map(\.kind) == ["enum", "type", "table"])
        for oid in ["0", "01", "-1", "4294967296", "text"] {
            var bad = reply
            bad.rows?[0][3] = oid
            #expect(throws: PostgresTypeCatalogFailure.self) { try PostgresTypeCatalog.decodeObjects(bad) }
        }
        let first = reference(oid: "1")
        let second = PostgresTypeReference(profileID: first.profileID, serviceSessionID: "another-service", serviceGeneration: UUID(),
            engine: .postgresql, database: first.database, schema: first.schema, name: first.name, objectKind: first.objectKind,
            localOID: "2", settingsRevision: UUID(), policy: first.policy)
        #expect(first.qualifiedIdentity == second.qualifiedIdentity && first != second)
    }
}
