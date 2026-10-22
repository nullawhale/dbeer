import Foundation
import Testing
@testable import DBeer

/// Pure formatting and selection checks never create an application or pasteboard.
struct ResultCopyTests {
    private let textColumn = ResultColumn(index: 0, name: "value", typeOid: 25, nativeType: "text")

    @Test func selectionKeepsCallerOrderDuplicateNamesAndSourceOrdinals() throws {
        let columns = [ResultColumn(index: 0, name: "x", typeOid: 25),
            ResultColumn(index: 1, name: "x", typeOid: 1700), ResultColumn(index: 2, name: "y", typeOid: 25)]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [["first", "9007199254740993.123456789", "last"], ["second", "-0.000000000000000001", "end"]],
            rowIndices: [1, 0], columnIndices: [1, 0])
        #expect(payload.version == 1)
        #expect(payload.columns.map(\.name) == ["x", "x"])
        #expect(payload.columns.map(\.index) == [1, 0])
        #expect(payload.sourceRows == [1, 0] && payload.sourceColumnIndices == [1, 0])
        #expect(payload.values.map { $0.map(\.value) } == [["-0.000000000000000001", "second"],
            ["9007199254740993.123456789", "first"]])
    }

    @Test func defaultTSVPreservesExistingNullEmptyUnicodeAndMultilineEncoding() throws {
        let columns = [textColumn, ResultColumn(index: 1, name: "value", typeOid: 25)]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [[nil, ""], ["\\N", "tabs\tand\n\"quotes\""], ["NULL", "κόσμος 🌍"]],
            rowIndices: [0, 1, 2], columnIndices: [0, 1])
        #expect(try ResultCopy.text(payload, format: .tsv, includesHeaders: false) ==
            "\\N\t\"\"\n\"\\N\"\t\"tabs\tand\n\"\"quotes\"\"\"\nNULL\tκόσμος 🌍")
    }

    @Test func delimitedFormatsKeepNullDefaultBinaryAndLiteralMarkersDistinct() throws {
        let columns = [textColumn, ResultColumn(index: 1, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [[nil, ""], ["", "AP8="], ["NULL", nil], ["<DEFAULT>", nil],
                ["<DEFAULT>", nil], ["<BINARY:AP8=>", nil], ["\\N", nil]],
            valueKinds: [["null", "binary"], ["text", "binary"], ["text", "null"], ["default", "null"],
                ["text", "null"], ["text", "null"], ["text", "null"]],
            rowIndices: Array(0..<7), columnIndices: [0, 1])
        #expect(payload.values[0][1] == ResultClipboardValue(kind: .binary, value: ""))
        #expect(payload.values[3][0] == ResultClipboardValue(kind: .default, value: nil))
        #expect(try ResultCopy.text(payload, format: .tsv, includesHeaders: false) ==
            "\\N\t<BINARY:>\n\"\"\t<BINARY:AP8=>\nNULL\t\\N\n<DEFAULT>\t\\N\n\"<DEFAULT>\"\t\\N\n\"<BINARY:AP8=>\"\t\\N\n\"\\N\"\t\\N")
        #expect(try ResultCopy.text(payload, format: .csv, includesHeaders: false) ==
            "\\N,<BINARY:>\r\n\"\",<BINARY:AP8=>\r\nNULL,\\N\r\n<DEFAULT>,\\N\r\n\"<DEFAULT>\",\\N\r\n\"<BINARY:AP8=>\",\\N\r\n\"\\N\",\\N")
    }

    @Test func csvAndTSVQuoteHeadersWithTheSameRulesAsValues() throws {
        let columns = [ResultColumn(index: 0, name: "x,\"x\"", typeOid: 25),
            ResultColumn(index: 1, name: "line\r\nnext", typeOid: 25),
            ResultColumn(index: 2, name: "<DEFAULT>", typeOid: 25),
            ResultColumn(index: 3, name: "x\ty", typeOid: 25)]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [["a,b", "a\rb\nc", "\"quoted\"", "a\tb"]], rowIndices: [0], columnIndices: [0, 1, 2, 3])
        #expect(try ResultCopy.text(payload, format: .csv, includesHeaders: true) ==
            "\"x,\"\"x\"\"\",\"line\r\nnext\",\"<DEFAULT>\",x\ty\r\n\"a,b\",\"a\rb\nc\",\"\"\"quoted\"\"\",a\tb")
        #expect(try ResultCopy.text(payload, format: .tsv, includesHeaders: true) ==
            "\"x,\"\"x\"\"\"\t\"line\r\nnext\"\t\"<DEFAULT>\"\t\"x\ty\"\na,b\t\"a\rb\nc\"\t\"\"\"quoted\"\"\"\t\"a\tb\"")
    }

    @Test func legacyPostgresBinaryNormalizesIncludingEmptyBytes() throws {
        let columns = [ResultColumn(index: 0, name: "bytes", typeOid: 17, nativeType: "bytea")]
        let payload = try ResultCopy.selection(columns: columns, rows: [["\\x000102fF"], ["\\x"], [nil]],
            rowIndices: [0, 1, 2], columnIndices: [0])
        #expect(payload.columns[0].encoding == "base64")
        #expect(payload.values == [[ResultClipboardValue(kind: .binary, value: "AAEC/w==")],
            [ResultClipboardValue(kind: .binary, value: "")], [ResultClipboardValue(kind: .null, value: nil)]])
    }

    @Test func jsonRoundTripsTypedPayloadWithoutCoercingNumbersOrDuplicateNames() throws {
        let columns = [textColumn, ResultColumn(index: 1, name: "value", typeOid: 1700),
            ResultColumn(index: 2, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [[nil, "9007199254740993.123456789", "AP8="], ["", "NULL", ""], ["<DEFAULT>", "line\n🌍", nil]],
            valueKinds: [["null", "text", "binary"], ["text", "text", "binary"], ["default", "text", "null"]],
            rowIndices: [0, 1, 2], columnIndices: [0, 1, 2])
        let json = try ResultCopy.text(payload, format: .json, includesHeaders: false)
        #expect(try JSONDecoder().decode(ResultClipboardPayload.self, from: Data(json.utf8)) == payload)
        #expect(try ResultCopy.text(payload, format: .json, includesHeaders: true) == json)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let values = try #require(object["values"] as? [[[String: Any]]])
        #expect(values[0][1]["value"] as? String == "9007199254740993.123456789")
        #expect(values[1][0]["value"] as? String == "")
        #expect(values[1][1]["value"] as? String == "NULL")
        #expect(values[2][0]["kind"] as? String == "default")
    }

    @Test func markdownEscapesMarkupAndKeepsWhitespaceAsExplicitJSONStrings() throws {
        let columns = [ResultColumn(index: 0, name: "x|x", typeOid: 25),
            ResultColumn(index: 1, name: "x|x", typeOid: 25)]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [[" a\tb\r\n\"κόσμος\" ", "*_[link]~`|<b>&\\N"], [nil, ""], ["NULL", "<DEFAULT>"]],
            rowIndices: [0, 1, 2], columnIndices: [0, 1])
        let markdown = try ResultCopy.text(payload, format: .markdown, includesHeaders: true)
        #expect(markdown.hasPrefix("| x&#124;x | x&#124;x |\n| --- | --- |\n"))
        #expect(markdown.contains("\" a&#92;tb&#92;r&#92;n&#92;\"κόσμος&#92;\" \""))
        #expect(markdown.contains("&#42;&#95;&#91;link&#93;&#126;&#96;&#124;&lt;b&gt;&amp;&#92;&#92;N"))
        #expect(markdown.contains("| &#92;N | \"\" |"))
        #expect(markdown.contains("| \"NULL\" | \"&lt;DEFAULT&gt;\" |"))
        #expect(markdown.split(separator: "\n").count == 5)
        #expect(try ResultCopy.text(payload, format: .markdown, includesHeaders: false).hasPrefix("|  |  |\n| --- | --- |\n"))
    }

    @Test func markdownMarkersRemainDistinctFromQuotedLiteralValues() throws {
        let columns = [textColumn, ResultColumn(index: 1, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")]
        let payload = try ResultCopy.selection(columns: columns, rows: [["<DEFAULT>", "AP8="], ["<BINARY:AP8=>", nil]],
            valueKinds: [["default", "binary"], ["text", "null"]], rowIndices: [0, 1], columnIndices: [0, 1])
        #expect(try ResultCopy.text(payload, format: .markdown, includesHeaders: true) ==
            "| value | bytes |\n| --- | --- |\n| &lt;DEFAULT&gt; | &lt;BINARY:AP8=&gt; |\n| \"&lt;BINARY:AP8=&gt;\" | &#92;N |")
    }

    @Test func markdownHeadersPreserveCombiningAndPrependScalarsAtQuoteBoundaries() throws {
        let name = "\u{0301}name\u{0600}"
        let payload = try ResultCopy.selection(columns: [ResultColumn(index: 0, name: name, typeOid: 25)],
            rows: [["value"]], rowIndices: [0], columnIndices: [0])
        let markdown = try ResultCopy.text(payload, format: .markdown, includesHeaders: true)
        #expect(Data(markdown.utf8) == Data("| \(name) |\n| --- |\n| \"value\" |".utf8))
    }

    @Test func delimitedEscapingRecognizesPunctuationScalarsInsideGraphemesAndCRLF() throws {
        let columns = [ResultColumn(index: 0, name: ",\u{0301}", typeOid: 25),
            ResultColumn(index: 1, name: "\"\u{0301}", typeOid: 25)]
        let payload = try ResultCopy.selection(columns: columns,
            rows: [[",\u{0301}", "\"\u{0301}"], ["a\r\nb", "plain"]],
            rowIndices: [0, 1], columnIndices: [0, 1])
        let csv = try ResultCopy.text(payload, format: .csv, includesHeaders: true)
        let tsv = try ResultCopy.text(payload, format: .tsv, includesHeaders: true)
        #expect(Data(csv.utf8) == Data("\",\u{0301}\",\"\"\"\u{0301}\"\r\n\",\u{0301}\",\"\"\"\u{0301}\"\r\n\"a\r\nb\",plain".utf8))
        #expect(Data(tsv.utf8) == Data(",\u{0301}\t\"\"\"\u{0301}\"\n,\u{0301}\t\"\"\"\u{0301}\"\n\"a\r\nb\"\tplain".utf8))
    }

    @Test func markdownEscapesPunctuationScalarsWhenCombinedWithMarks() throws {
        let payload = try ResultCopy.selection(columns: [ResultColumn(index: 0, name: "|\u{0301}", typeOid: 25)],
            rows: [["*\u{0301}|\u{0301}"]], rowIndices: [0], columnIndices: [0])
        let markdown = try ResultCopy.text(payload, format: .markdown, includesHeaders: true)
        #expect(Data(markdown.utf8) == Data("| &#124;\u{0301} |\n| --- |\n| \"&#42;\u{0301}&#124;\u{0301}\" |".utf8))
    }

    @Test func invalidSelectionCannotSilentlyDropOrDuplicateValues() {
        for indices in [[], [-1], [1], [0, 0]] {
            #expect(throws: ResultCopyError.self) {
                try ResultCopy.selection(columns: [textColumn], rows: [["x"]], rowIndices: indices, columnIndices: [0])
            }
            #expect(throws: ResultCopyError.self) {
                try ResultCopy.selection(columns: [textColumn], rows: [["x"]], rowIndices: [0], columnIndices: indices)
            }
        }
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [textColumn], rows: [["x", "extra"]], rowIndices: [0], columnIndices: [0])
        }
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [textColumn], rows: [["x"]], valueKinds: [], rowIndices: [0], columnIndices: [0])
        }
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [textColumn], rows: [["x"]], valueKinds: [["unknown"]], rowIndices: [0], columnIndices: [0])
        }
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [textColumn], rows: [["x"]], valueKinds: [["null"]], rowIndices: [0], columnIndices: [0])
        }
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [textColumn], rows: [[nil]], valueKinds: [["text"]], rowIndices: [0], columnIndices: [0])
        }
    }

    @Test(arguments: ["not base64", "AA", "AB==", "AA==\n", "!AA=="])
    func malformedBase64NeverBecomesTextOrTruncatedBinary(value: String) {
        let column = ResultColumn(index: 0, name: "bytes", engine: .mysql, nativeType: "BLOB", encoding: "base64")
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [column], rows: [[value]], rowIndices: [0], columnIndices: [0])
        }
    }

    @Test(arguments: ["not hex", "\\x0", "\\xgg", "\\x+f", "\\x-0", "\\x🌍", "\\x\u{0301}ff"])
    func malformedLegacyBinaryNeverBecomesText(value: String) {
        let column = ResultColumn(index: 0, name: "bytes", typeOid: 17, nativeType: "bytea")
        #expect(throws: ResultCopyError.self) {
            try ResultCopy.selection(columns: [column], rows: [[value]], rowIndices: [0], columnIndices: [0])
        }
    }

    @Test func malformedTypedPayloadsAreRejectedBeforeAnyFormatIsGenerated() throws {
        let text = ResultClipboardValue(kind: .text, value: "exact")
        let badPayloads = [
            ResultClipboardPayload(version: 2, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [0], values: [[text]]),
            ResultClipboardPayload(version: 1, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [], values: [[text]]),
            ResultClipboardPayload(version: 1, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [0], values: [[]]),
            ResultClipboardPayload(version: 1, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [0],
                values: [[ResultClipboardValue(kind: .null, value: "lost")]]),
            ResultClipboardPayload(version: 1, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [0],
                values: [[ResultClipboardValue(kind: .text, value: nil)]]),
            ResultClipboardPayload(version: 1, columns: [textColumn], sourceRows: [0], sourceColumnIndices: [0],
                values: [[ResultClipboardValue(kind: .binary, value: "AA==")]])
        ]
        for payload in badPayloads {
            for format in ResultCopyFormat.allCases {
                #expect(throws: ResultCopyError.self) { try ResultCopy.text(payload, format: format, includesHeaders: true) }
            }
        }
    }

    @Test func sqlInsertRequiresAnAdapterAndExplicitTarget() throws {
        let payload = try ResultCopy.selection(columns: [textColumn], rows: [["not executed"]], rowIndices: [0], columnIndices: [0])
        #expect(throws: ResultCopyError.self) { try ResultCopy.text(payload, format: .sqlInsert, includesHeaders: true) }
    }
}
