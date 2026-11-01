import Foundation
import Testing
@testable import DBeer

/// Text parsing and in-memory mapping only; no windows, databases or file panels.
struct DelimitedTextImportTests {
    private func parse(_ text: String, options: DelimitedImportOptions = DelimitedImportOptions()) throws -> DelimitedImportDocument {
        try DelimitedTextImport.parse(data: Data(text.utf8), options: options)
    }

    @Test func csvPreservesExactValuesQuotedLineEndingsAndPhysicalRecordPositions() throws {
        let source = "id,note,amount\r\n1,\"a\r\nb\",9007199254740993.12345678901234567890\r\n2,\"a\"\"b\",  Unicode 🐋  \r\n"
        let document = try parse(source)
        #expect(document.headers == ["id", "note", "amount"])
        #expect(document.rows.map(\.number) == [2, 4])
        #expect(document.rows.map(\.ordinal) == [2, 3])
        #expect(document.rows[0].fields[1] == DelimitedImportField(text: "a\r\nb", wasQuoted: true))
        #expect(document.rows[0].fields[2].text == "9007199254740993.12345678901234567890")
        #expect(document.rows[1].fields[1].text == "a\"b")
        #expect(document.rows[1].fields[2].text == "  Unicode 🐋  ")
    }

    @Test func nullMarkersAreExplicitUnquotedAndDistinctFromEmptyText() throws {
        let document = try parse(#"\N,"\N",,"",NULL,"NULL""#, options: DelimitedImportOptions(hasHeader: false))
        let fields = document.rows[0].fields
        let defaults = try fields.map { try $0.value(options: DelimitedImportOptions(), binary: false) }
        #expect(defaults == [.null, ChangeValue(kind: "text", value: #"\N"#), ChangeValue(kind: "text", value: ""),
            ChangeValue(kind: "text", value: ""), ChangeValue(kind: "text", value: "NULL"), ChangeValue(kind: "text", value: "NULL")])
        let explicitNull = DelimitedImportOptions(nullMarker: "NULL", emptyFieldsAreNull: true)
        let explicit = try fields.map { try $0.value(options: explicitNull, binary: false) }
        #expect(explicit[0] == ChangeValue(kind: "text", value: #"\N"#))
        #expect(explicit[2] == .null && explicit[3] == ChangeValue(kind: "text", value: ""))
        #expect(explicit[4] == .null && explicit[5] == ChangeValue(kind: "text", value: "NULL"))
        let disabled = DelimitedImportOptions(nullMarker: nil)
        #expect(try fields[0].value(options: disabled, binary: false) == ChangeValue(kind: "text", value: #"\N"#))
    }

    @Test func blankRecordsAreRetainedAndFinalTerminatorsDoNotInventRows() throws {
        let noHeader = DelimitedImportOptions(hasHeader: false)
        let document = try parse("a\r\n\r\n\"\"\r\n", options: noHeader)
        #expect(document.headers == ["Column 1"])
        #expect(document.rows.count == 3)
        #expect(document.rows.map { $0.fields[0].text } == ["a", "", ""])
        #expect(document.rows.map { $0.fields[0].wasQuoted } == [false, false, true])
        #expect(try parse("a,b,", options: noHeader).rows[0].fields.map(\.text) == ["a", "b", ""])
        #expect(try parse("a,b\n", options: noHeader).rows.count == 1)
        #expect(try parse("\n", options: noHeader).rows.count == 1)
        #expect(try parse("header\n").rows.isEmpty)
        #expect(throws: DelimitedImportError.self) { try parse("a,b\n\n", options: noHeader) }
    }

    @Test func explicitTabDelimiterSupportsCsvQuotingAndEveryRecordEnding() throws {
        let options = DelimitedImportOptions(delimiter: .tab, hasHeader: false)
        let document = try parse("a\t\"b\tc\"\rd\t\"e\nf\"\ng\th\r\n", options: options)
        #expect(document.headers == ["Column 1", "Column 2"])
        #expect(document.rows.map(\.number) == [1, 2, 4])
        #expect(document.rows[0].fields[1].text == "b\tc")
        #expect(document.rows[1].fields[1].text == "e\nf")
        #expect(document.rows[2].fields[1].text == "h")
        #expect(try parse("a,b\n", options: options).headers == ["Column 1"])
        #expect(try parse("a\tb\n", options: DelimitedImportOptions(hasHeader: false)).headers == ["Column 1"])
    }

    @Test func malformedQuotesAndWidthsReportLocationsWithoutEchoingData() throws {
        let cases: [(String, DelimitedImportError.Reason, Int, Int)] = [
            ("a,b\n1,secret\"text", .unexpectedQuote, 2, 2),
            ("a,b\n1,\"secret\"text", .unexpectedAfterQuote, 2, 2),
            ("a,b\n1,\"secret", .unclosedQuote, 2, 2),
            ("a,b\n1", .inconsistentWidth, 2, 2),
            ("a,b\n1,2,3", .inconsistentWidth, 2, 3),
        ]
        for (source, reason, line, column) in cases {
            do {
                _ = try parse(source)
                Issue.record("Malformed import was accepted")
            } catch let error as DelimitedImportError {
                #expect(error.reason == reason && error.line == line && error.column == column)
                #expect(!error.localizedDescription.contains("secret"))
            }
        }
    }

    @Test func utf8BomIsOptionalButInvalidEncodingsAndEmptyFilesAreRejected() throws {
        let plain = Data("name\n🐋\n".utf8)
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(plain)
        #expect(try DelimitedTextImport.parse(data: plain, options: DelimitedImportOptions()) ==
            DelimitedTextImport.parse(data: bom, options: DelimitedImportOptions()))
        for bytes in [Data(), Data([0xEF, 0xBB, 0xBF]), Data([0x61, 0x0A, 0xFF]), Data([0xC0, 0x80]), Data([0xED, 0xA0, 0x80])] {
            #expect(throws: DelimitedImportError.self) { try DelimitedTextImport.parse(data: bytes, options: DelimitedImportOptions()) }
        }
        let interior = try parse("name\n\u{FEFF}value")
        #expect(interior.rows[0].fields[0].text == "\u{FEFF}value")
    }

    @Test func parserEnforcesInputRowsColumnsAndDataCellBudgetsWithoutTruncation() throws {
        let maximum = DelimitedTextImport.maximumInputBytes
        #expect(throws: DelimitedImportError.self) {
            try DelimitedTextImport.parse(data: Data(repeating: 97, count: maximum + 1), options: DelimitedImportOptions())
        }
        let rows = "value\n" + String(repeating: "x\n", count: DelimitedTextImport.maximumRows)
        #expect(try parse(rows).rows.count == 10_000)
        #expect(throws: DelimitedImportError.self) { try parse(rows + "x\n") }
        let columns = Array(repeating: "x", count: 256).joined(separator: ",")
        #expect(try parse(columns + "\n" + columns).headers.count == 256)
        #expect(throws: DelimitedImportError.self) { try parse(columns + ",x") }
        let ten = Array(repeating: "x", count: 10).joined(separator: ",")
        #expect(try parse(ten + "\n" + String(repeating: ten + "\n", count: 10_000)).rows.count == 10_000)
        let eleven = Array(repeating: "x", count: 11).joined(separator: ",")
        #expect(throws: DelimitedImportError.self) { try parse(eleven + "\n" + String(repeating: eleven + "\n", count: 9_091)) }
    }

    @Test func mappingUsesSourceIndicesPreservesDuplicatesAndChecksCanonicalBase64() throws {
        let document = try parse("same,same,skip,bin\nexact,1.00000000000000000001,discard,AAE=\n\\N,\"\\N\",discard,\"\"")
        #expect(document.headers == ["same", "same", "skip", "bin"])
        let result = try document.mappedRows(mapping: ["first", "second", nil, "bytes"], binaryColumns: ["bytes"], options: DelimitedImportOptions())
        #expect(result[0] == [ChangeValue(kind: "text", value: "exact"), ChangeValue(kind: "text", value: "1.00000000000000000001"), ChangeValue(kind: "binary", value: "AAE=")])
        #expect(result[1] == [.null, ChangeValue(kind: "text", value: #"\N"#), ChangeValue(kind: "binary", value: "")])
        for text in ["AA", "A A=", "AA==\n", "AB==", "not Base64"] {
            #expect(throws: DelimitedImportValueError.self) {
                try DelimitedImportField(text: text, wasQuoted: false).value(options: DelimitedImportOptions(), binary: true)
            }
        }
        let invalid = try parse("name,bin\nvalue,AB==")
        do {
            _ = try invalid.mappedRows(mapping: ["name", "bytes"], binaryColumns: ["bytes"], options: DelimitedImportOptions())
            Issue.record("Noncanonical binary import was accepted")
        } catch let error as DelimitedImportError {
            #expect(error.line == 2 && error.column == 2 && error.reason == .invalidBase64)
        }
    }

    @Test func mappingRejectsAmbiguousDestinationsAndExcessValueBytesBeforeReturningRows() throws {
        let document = try parse("a,b\nx,y")
        for mapping: [String?] in [["same", "same"], [nil, nil], ["only"], ["", nil]] {
            #expect(throws: DelimitedImportError.self) {
                try document.mappedRows(mapping: mapping, binaryColumns: [], options: DelimitedImportOptions())
            }
        }
        let limit = DelimitedTextImport.maximumMappedValueBytes
        let exact = try parse(String(repeating: "x", count: limit), options: DelimitedImportOptions(hasHeader: false))
        #expect(try exact.mappedRows(mapping: ["text"], binaryColumns: [], options: DelimitedImportOptions())[0][0].value?.utf8.count == limit)
        let excessive = try parse(String(repeating: "é", count: limit / 2 + 1), options: DelimitedImportOptions(hasHeader: false))
        #expect(throws: DelimitedImportError.self) {
            try excessive.mappedRows(mapping: ["text"], binaryColumns: [], options: DelimitedImportOptions())
        }
        var malformed = document
        malformed.rows[0].fields.removeLast()
        #expect(throws: DelimitedImportError.self) {
            try malformed.mappedRows(mapping: ["a", "b"], binaryColumns: [], options: DelimitedImportOptions())
        }
    }

    @Test func nullMarkersAndDestinationIdentifiersUseExactUtf8Bytes() throws {
        let composed = "é", decomposed = "e\u{301}"
        let options = DelimitedImportOptions(nullMarker: composed)
        #expect(options != DelimitedImportOptions(nullMarker: decomposed))
        #expect(try DelimitedImportField(text: composed, wasQuoted: false).value(options: options, binary: false) == .null)
        #expect(try DelimitedImportField(text: decomposed, wasQuoted: false).value(options: options, binary: false).value?.utf8.elementsEqual(decomposed.utf8) == true)
        let document = try parse("a,b\nAA==,ordinary")
        let values = try document.mappedRows(mapping: [composed, decomposed], binaryColumns: [composed], options: DelimitedImportOptions())
        #expect(values[0].map(\.kind) == ["binary", "text"])
        let nul = try parse("a,b\nordinary,\"contains\0NUL\"")
        do {
            _ = try nul.mappedRows(mapping: ["a", "b"], binaryColumns: [], options: DelimitedImportOptions())
            Issue.record("NUL text reached the import request")
        } catch let error as DelimitedImportError {
            #expect(error.line == 2 && error.column == 2 && error.reason == .invalidText)
        }
    }
}
