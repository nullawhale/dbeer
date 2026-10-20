import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Synthetic, portable reference cases. Timings describe this native test host,
/// not end-to-end input latency or a Windows/Linux acceptance result.
@Suite(.serialized)
@MainActor
struct ParityBaselineTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixtures: URL { repository.appendingPathComponent("prototypes/gpui/parity/fixtures") }

    private struct ParserCase: Decodable {
        let id: String
        let engine: DatabaseEngine
        let sql: String
        let statements: [String]?
        let statementCount: Int?
        let diagnostics: Int
        let caretUTF16: Int?
        let selected: String?
    }

    @Test func sharedSQLCorpusPreservesSourceRangesAndDialectBoundaries() throws {
        let cases = try JSONDecoder().decode([ParserCase].self, from: Data(contentsOf: fixtures.appendingPathComponent("sql.json")))
        #expect(!cases.isEmpty)
        for item in cases {
            let parsed = SQLScriptParser.parse(item.sql, engine: item.engine)
            #expect(parsed.diagnostics.count == item.diagnostics, "Fixture \(item.id)")
            if let statements = item.statements { #expect(parsed.statements.map(\.sql) == statements, "Fixture \(item.id)") }
            if let count = item.statementCount { #expect(parsed.statements.count == count, "Fixture \(item.id)") }
            for statement in parsed.statements {
                #expect((item.sql as NSString).substring(with: statement.range) == statement.sql)
            }
            if let caret = item.caretUTF16 {
                #expect(SQLExecutionFragment.resolve(text: item.sql, selection: NSRange(location: caret, length: 0),
                    engine: item.engine)?.sourceSQL == item.selected, "Fixture \(item.id)")
            }
        }
    }

    private struct GridFixture: Decodable {
        let columns: [ResultColumn]
        let rows: [[String?]]
        let rowCount: Int
        let truncated: Bool
    }

    @Test func sharedGridAndThemeCorpusUsesProductionEncodersAndImporters() throws {
        let grid = try JSONDecoder().decode(GridFixture.self, from: Data(contentsOf: fixtures.appendingPathComponent("grid.json")))
        let set = ExportResultSet(columns: grid.columns, rows: grid.rows, commandTag: "SELECT", rowCount: Int64(grid.rowCount), truncated: grid.truncated)
        let data = try ResultExport.json([set])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sets = try #require(object["resultSets"] as? [[String: Any]])
        let rows = try #require(sets.first?["rows"] as? [[Any]])
        #expect(rows[0][0] is NSNull)
        #expect(rows[1][0] as? String == "")
        #expect(rows[1][1] as? String == "NULL")
        #expect(rows[0][1] as? String == "9007199254740993.123456789")
        #expect(rows[0][2] as? String == "AP8=")
        // The corpus deliberately collides with the usual CSV NULL marker.
        #expect(throws: ResultExportError.self) { try ResultExport.csv(set, nullMarker: "\\N") }
        let csv = try ResultExport.csv(set, nullMarker: "__PARITY_NULL__")
        #expect(!csv.isEmpty)
        for name in ["paper.json", "night.json", "include.jsonc", "textmate.tmTheme", "jetbrains.icls"] {
            let theme = try EditorThemeParser.load(from: fixtures.appendingPathComponent("themes/" + name), id: name)
            #expect(!theme.colors.isEmpty)
            #expect(theme.style(for: ["source.sql", "keyword.other.sql"]).foreground != nil)
        }
        #expect(ExecutionPolicy().environment == .unspecified)
        #expect(!ExecutionPolicy().readOnly)
    }

    private struct SignatureCase: Decodable {
        struct Relation: Decodable {
            let schema: String
            let name: String
            let kind: String
            let signatures: [SQLFunctionSignature]
        }
        struct Expected: Decodable {
            let present: Bool
            let name: String?
            let activeParameter: Int?
            let parameterText: String?
        }
        let id: String
        let engine: DatabaseEngine
        let sqlWithCaret: String
        let catalog: [Relation]?
        let expect: Expected
    }

    @Test func sharedSignatureCorpusPassesThroughBundledLSPAndSwiftUTF16Decoder() async throws {
        let cases = try JSONDecoder().decode([SignatureCase].self,
            from: Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/signature-help.json")))
        let service = SQLLanguageService(helperURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        let documentID = UUID()
        for item in cases {
            let marker = (item.sqlWithCaret as NSString).range(of: "|")
            let sql = item.sqlWithCaret.replacingOccurrences(of: "|", with: "")
            let catalog = (item.catalog ?? []).map {
                SQLCompletionRelation(schema: $0.schema, name: $0.name, kind: $0.kind, signatures: $0.signatures)
            }
            service.update(documentID: documentID, text: sql, engine: item.engine,
                context: SQLCompletionContext(profileID: nil, catalog: catalog))
            let help = await service.signatureHelp(documentID: documentID, offset: marker.location)
            #expect((help != nil) == item.expect.present, "Fixture \(item.id)")
            if let help {
                let selected = help.signatures[help.activeSignature]
                #expect(selected.label.hasPrefix((item.expect.name ?? "") + "("), "Fixture \(item.id)")
                #expect(selected.activeParameter == item.expect.activeParameter, "Fixture \(item.id)")
                if let expected = item.expect.parameterText {
                    let range = try #require(selected.activeParameterRange)
                    #expect((selected.label as NSString).substring(with: range) == expected, "Fixture \(item.id)")
                }
            }
        }
        await service.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEER_PARITY_MEASUREMENTS"] != nil,
        "Set DBEER_PARITY_MEASUREMENTS to record synthetic reference timings."))
    func measureFrozenReferenceWorkloads() throws {
        let output = try #require(ProcessInfo.processInfo.environment["DBEER_PARITY_MEASUREMENTS"])
        var metrics: [[String: Any]] = []
        func measure(_ id: String, input: String, samples: Int = 30, _ operation: () throws -> Void) throws {
            for _ in 0..<3 { try operation() }
            var times: [Double] = []
            for _ in 0..<samples {
                let start = DispatchTime.now().uptimeNanoseconds
                try operation()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            times.sort()
            metrics.append(["id": id, "input": input, "samples": samples, "warmups": 3,
                "unit": "ms", "p50": times[(samples - 1) / 2], "p95": times[Int(ceil(Double(samples) * 0.95)) - 1],
                "max": times.last!, "measurementKind": "synchronous-production-operation"])
        }
        let sql = (0..<1_000).map { "SELECT \($0), '😀 e\u{301} 世界';\r\n" }.joined()
        try measure("parse-1000-statements", input: "1000 SELECT statements; UTF-8, non-BMP, combining mark, CRLF") {
            #expect(SQLScriptParser.parse(sql, engine: .postgresql).statements.count == 1_000)
        }
        let columns = (0..<32).map { ResultColumn(index: $0, name: "column \($0)", typeOid: 25, nativeType: "text") }
        let rows: [[String?]] = (0..<1_000).map { row in (0..<32).map { column in column == 0 ? String(row) : "synthetic 😀 \(column)" } }
        let set = ExportResultSet(columns: columns, rows: rows, commandTag: "SELECT", rowCount: 1_000, truncated: false)
        try measure("json-1000x32", input: "1000 rows x 32 text columns; in-memory loaded-result JSON") {
            let data = try ResultExport.json([set])
            #expect(data.count > 1_000)
        }
        try measure("theme-jsonc-include", input: "Synthetic local JSONC include with alpha and scope override") {
            let theme = try EditorThemeParser.load(from: fixtures.appendingPathComponent("themes/include.jsonc"), id: "reference")
            #expect(theme.appearance == .light)
        }
        _ = NSApplication.shared
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.parity.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 960, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let table = try #require(scroll.documentView as? ResultGridTableView)
        var revision = 0
        try measure("grid-reload-layout-1000x32", input: "Native AppKit 960x540 window; 1000x32; change one cell, reload and layout; no compositor fence") {
            var changed = rows
            revision += 1
            changed[0][0] = String(revision)
            coordinator.update(columns: columns, rows: changed, in: scroll)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            #expect(table.numberOfRows == 1_000)
        }
        try measure("grid-select-visible-row", input: "Native loaded 1000x32 grid; select next visible row; redraw; no OS input injection") {
            revision += 1
            table.selectRowIndexes(IndexSet(integer: revision % 12), byExtendingSelection: false)
            scroll.displayIfNeeded()
        }
        let report: [String: Any] = ["schemaVersion": 1, "reference": "frozen SwiftUI/AppKit source in native Swift Testing host",
            "configuration": "debug test module; release signed app built separately", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": "arm64", "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "metrics": metrics,
            "unmeasured": ["OS input-to-present latency", "compositor frame pacing", "cold startup", "network and database latency", "Windows 11", "Ubuntu Wayland", "Ubuntu X11"]]
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
