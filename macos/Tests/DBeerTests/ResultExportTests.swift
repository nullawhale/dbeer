import Foundation
import Testing
@testable import DBeer

struct ResultExportTests {
    private var result: ExportResultSet {
        ExportResultSet(columns: [
            ResultColumn(index: 0, name: "x", typeOid: 25, nativeType: "text"),
            ResultColumn(index: 1, name: "x", typeOid: 1700, nativeType: "numeric"),
            ResultColumn(index: 2, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")
        ], rows: [[nil, "9007199254740993.123456789", "AP8="], ["", "NULL", nil],
            ["κόσμος, \"🌍\"\nsecond line", "", "AA=="]], commandTag: "SELECT 10000", rowCount: 10_000, truncated: true)
    }

    @Test func jsonKeepsOrderDuplicatesPrecisionNullAndBinaryWithoutHidingTruncation() throws {
        let data = try ResultExport.json([result])
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(document["version"] as? Int == 1)
        let sets = try #require(document["resultSets"] as? [[String: Any]])
        let metadata = try #require(sets.first?["metadata"] as? [String: Any])
        let columns = try #require(metadata["columns"] as? [[String: Any]])
        #expect(columns.map { $0["name"] as? String } == ["x", "x", "bytes"])
        #expect(columns[2]["encoding"] as? String == "base64")
        #expect(metadata["truncated"] as? Bool == true)
        #expect(metadata["rowCount"] as? Int == 10_000)
        #expect(metadata["displayedRowCount"] as? Int == 3)
        let rows = try #require(sets.first?["rows"] as? [[Any]])
        #expect(rows[0][0] is NSNull)
        #expect(rows[0][1] as? String == "9007199254740993.123456789")
        #expect(rows[0][2] as? String == "AP8=")
        #expect(rows[1][0] as? String == "")
        #expect(rows[1][1] as? String == "NULL")
    }

    @Test func csvUsesUTF8QuotedFieldsAndAnExplicitCollisionFreeNullMarker() throws {
        let text = String(decoding: try ResultExport.csv(result, nullMarker: "\\N"), as: UTF8.self)
        #expect(text.hasPrefix("x,x,bytes\r\n\\N,9007199254740993.123456789,AP8=\r\n,NULL,\\N\r\n"))
        #expect(text.contains("\"κόσμος, \"\"🌍\"\"\nsecond line\",,AA==\r\n"))
        #expect(throws: ResultExportError.self) { try ResultExport.csv(result, nullMarker: "NULL") }
        #expect(throws: ResultExportError.self) { try ResultExport.csv(result, nullMarker: "") }
    }

    @Test func atomicWriteReplacesOnlyOnSuccessAndRemovesTemporaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("result.json")
        try Data("old".utf8).write(to: file)
        let data = try ResultExport.json([result])
        try ResultExport.write(data, to: file)
        #expect(try Data(contentsOf: file) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["result.json"])
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
        #expect(throws: ResultExportError.self) {
            try ResultExport.write(Data("new".utf8), to: folder.appendingPathComponent("missing/result.json"))
        }
        #expect(try Data(contentsOf: file) == data)
    }
}
