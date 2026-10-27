import Foundation
import Testing
@testable import DBeer

struct SQLFolderScannerTests {
    private final class Fixture {
        let container: URL
        let root: URL
        var attachment: SQLFolderAttachment { SQLFolderAttachment(id: UUID(uuidString: "F6B5C010-05B0-4DE1-914C-DF94814511CC")!, url: root) }

        init() throws {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            container = repository.appendingPathComponent("build/r12-r13/folders/\(UUID().uuidString)")
            root = container.appendingPathComponent("queries")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        @discardableResult func file(_ path: String, data: Data, under root: URL? = nil) throws -> URL {
            let url = (root ?? self.root).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        deinit { try? FileManager.default.removeItem(at: container) }
    }

    @Test func nameAndContentSearchRespectSQLScopeAndPreserveLineNumbers() throws {
        let fixture = try Fixture()
        _ = try fixture.file("migrations/customer.SQL", data: Data("-- first\r\nSELECT 'κόσμος';\r\n-- TARGET customer\r\n".utf8))
        _ = try fixture.file("notes.txt", data: Data("TARGET".utf8))
        _ = try fixture.file(".queries/hidden.sql", data: Data("-- target hidden\n".utf8))
        for ignored in [".git", "build", ".build", "target", "node_modules", "dist", "DerivedData"] {
            _ = try fixture.file(ignored + "/ignored.sql", data: Data("TARGET".utf8))
        }
        let outside = fixture.container.appendingPathComponent("outside")
        let outsideFile = try fixture.file("outside.sql", data: Data("TARGET outside".utf8), under: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked.sql"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("cycle"), withDestinationURL: fixture.root)
        let names = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "CUSTOMER", mode: .name)
        #expect(names.matches.map(\.relativePath) == ["migrations/customer.SQL"])
        #expect(names.matches[0].lineNumber == nil && names.matches[0].preview == nil)
        let contents = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "target", mode: .contents)
        #expect(Set(contents.matches.map(\.relativePath)) == [".queries/hidden.sql", "migrations/customer.SQL"])
        let customer = try #require(contents.matches.first { $0.relativePath == "migrations/customer.SQL" })
        #expect(customer.lineNumber == 3 && customer.preview == "-- TARGET customer")
        #expect(contents.skippedFiles == 0 && contents.unavailableFolders == 0 && !contents.isTruncated)
        let unicode = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "κόσμος", mode: .contents)
        #expect(unicode.matches.first?.lineNumber == 2 && unicode.matches.first?.preview == "SELECT 'κόσμος';")
    }

    @Test func contentSearchReportsUnreadableBinaryAndOversizedFiles() throws {
        let fixture = try Fixture()
        _ = try fixture.file("invalid.sql", data: Data([0xFF, 0xFE]))
        _ = try fixture.file("binary.sql", data: Data("TARGET\0hidden".utf8))
        _ = try fixture.file("large.sql", data: Data(repeating: 0x61, count: 2_000))
        _ = try fixture.file("valid.sql", data: Data("-- target\n".utf8))
        var limits = SQLFolderScanLimits.default
        limits.fileBytes = 100
        let batch = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "target", mode: .contents, limits: limits)
        #expect(batch.matches.map(\.relativePath) == ["valid.sql"])
        #expect(batch.skippedFiles == 3 && batch.notice != nil)
        #expect(batch.contentBytes <= limits.totalContentBytes)
    }

    @Test func searchAndTreeBudgetsReportTruncationWithoutTraversingEveryFile() throws {
        let fixture = try Fixture()
        for number in 0..<12 { _ = try fixture.file("match-\(number).sql", data: Data("-- match\n-- match again\n".utf8)) }
        var limits = SQLFolderScanLimits.default
        limits.results = 2
        let resultLimited = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "match", mode: .name, limits: limits)
        #expect(resultLimited.matches.count == 2 && resultLimited.isTruncated && resultLimited.notice != nil)
        #expect(resultLimited.inspectedFiles == 2)
        limits = .default
        limits.searchEntries = 3
        let workLimited = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "absent", mode: .name, limits: limits)
        #expect(workLimited.isTruncated && workLimited.inspectedEntries == 3 && workLimited.inspectedFiles <= 3)
        let tree = try SQLFolderScanner.children(attachment: fixture.attachment, directory: fixture.root, limit: 4)
        #expect(tree.entries.count == 4 && tree.isTruncated)
        limits = .default
        limits.matchesPerFile = 1
        let perFile = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "match", mode: .contents, limits: limits)
        #expect(perFile.matches.count == 12 && perFile.isTruncated)
    }

    @Test func replacedDirectoriesAndEscapingRequestsDoNotFollowSymlinks() throws {
        let fixture = try Fixture()
        _ = try fixture.file("nested/safe.sql", data: Data("-- safe".utf8))
        let outside = fixture.container.appendingPathComponent("outside")
        _ = try fixture.file("secret.sql", data: Data("-- sentinel".utf8), under: outside)
        let nested = fixture.root.appendingPathComponent("nested")
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        #expect(throws: SQLFolderError.self) { try SQLFolderScanner.children(attachment: fixture.attachment, directory: nested) }
        #expect(throws: SQLFolderError.self) { try SQLFolderScanner.children(attachment: fixture.attachment, directory: outside) }
        #expect(try SQLFolderScanner.search(attachments: [fixture.attachment], query: "sentinel", mode: .contents).matches.isEmpty)
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)
        let replaced = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "sentinel", mode: .contents)
        #expect(replaced.matches.isEmpty && replaced.unavailableFolders == 1 && replaced.notice != nil)
    }

    @Test func directoryDepthAndContentByteBudgetsAreExplicit() throws {
        let fixture = try Fixture()
        _ = try fixture.file("one/two/deep.sql", data: Data("-- target".utf8))
        _ = try fixture.file("root.sql", data: Data("-- target\n".utf8))
        var limits = SQLFolderScanLimits.default
        limits.directoryDepth = 1
        let shallow = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "target", mode: .contents, limits: limits)
        #expect(shallow.isTruncated && shallow.matches.map(\.relativePath) == ["root.sql"])
        limits = .default
        limits.totalContentBytes = 10
        let bounded = try SQLFolderScanner.search(attachments: [fixture.attachment], query: "target", mode: .contents, limits: limits)
        #expect(bounded.contentBytes <= 10 && bounded.isTruncated)
    }

    @Test func overlappingAttachmentsDoNotDuplicateTheSameSQLPath() throws {
        let fixture = try Fixture()
        _ = try fixture.file("one.sql", data: Data("-- target\n".utf8))
        _ = try fixture.file("nested/two.sql", data: Data("-- target\n".utf8))
        let nested = SQLFolderAttachment(url: fixture.root.appendingPathComponent("nested"))
        let batch = try SQLFolderScanner.search(attachments: [fixture.attachment, nested], query: "target", mode: .contents)
        #expect(batch.matches.count == 2 && Set(batch.matches.map(\.url)).count == 2)
        #expect(batch.inspectedFiles == 2 && !batch.isTruncated)
    }
}
