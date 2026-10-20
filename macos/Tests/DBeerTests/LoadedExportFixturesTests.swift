import Foundation
import Testing
@testable import DBeer

/// Prepared shared loaded-export cases. Execute only at final integration.
struct LoadedExportFixturesTests {
    private struct Fixture: Decodable {
        let version: Int
        let nullMarker: String
        let resultSets: [SetFixture]
        let csv: [String]
    }
    private struct SetFixture: Decodable {
        struct Metadata: Decodable {
            let columns: [ResultColumn]
            let commandTag: String
            let rowCount: Int64
            let displayedRowCount: Int
            let truncated: Bool
        }
        let metadata: Metadata
        let rows: [[String?]]
        var result: ExportResultSet {
            ExportResultSet(columns: metadata.columns, rows: rows, commandTag: metadata.commandTag,
                rowCount: metadata.rowCount, truncated: metadata.truncated)
        }
    }
    @Test func sharedJSONAndCSVKeepExactLoadedRowsAndDisclosureMetadata() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/loaded-export-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let encoded = try ResultExport.json(fixture.resultSets.map(\.result))
        let actual = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(actual["version"] as? Int == fixture.version)
        #expect((actual["resultSets"] as? NSArray) == (original["resultSets"] as? NSArray))
        for (index, set) in fixture.resultSets.enumerated() {
            #expect(set.metadata.displayedRowCount == set.rows.count)
            #expect(try ResultExport.csv(set.result, nullMarker: fixture.nullMarker) == Data(fixture.csv[index].utf8))
        }
        for marker in ["", "NULL", "\\N", "AP8="] {
            #expect(throws: ResultExportError.self) {
                try ResultExport.csv(fixture.resultSets[0].result, nullMarker: marker)
            }
        }
    }
}
