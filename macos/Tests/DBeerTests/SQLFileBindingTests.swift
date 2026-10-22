import Foundation
import Testing
@testable import DBeer

/// Local files only; no native chooser, application or window is opened.
struct SQLFileBindingTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/r09/files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func boundSaveChecksAcceptedBytesInsteadOfTheRecoveredEditedDraft() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("analysis.sql")
        let original = "SELECT 'κόσμος 😀';\r\n-- \u{0301}preserve bytes\r\n"
        try Data(original.utf8).write(to: url)
        let loaded = try SQLFileBinding.read(url)
        #expect(Data(loaded.text.utf8) == Data(original.utf8))
        let edited = original + "SELECT 'local changes';\r\n"
        let savedHash = try SQLFileBinding.write(edited, to: url, expectedSHA256: loaded.sha256)
        let reread = try SQLFileBinding.read(url)
        #expect(Data(reread.text.utf8) == Data(edited.utf8))
        #expect(savedHash == reread.sha256 && savedHash != loaded.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["analysis.sql"])
    }

    @Test func externallyChangedOrMissingBindingKeepsTheExternalFileAndDraft() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.sql")
        try Data("SELECT 'accepted';".utf8).write(to: url)
        let loaded = try SQLFileBinding.read(url)
        let external = Data("SELECT 'external version';".utf8)
        try external.write(to: url)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("SELECT 'recovered draft';", to: url, expectedSHA256: loaded.sha256)
        }
        #expect(try Data(contentsOf: url) == external)
        try FileManager.default.removeItem(at: url)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("SELECT 'recovered draft';", to: url, expectedSHA256: loaded.sha256)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func explicitSaveAsWritesANewBindingWithoutChangingTheOriginal() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.sql")
        let destination = directory.appendingPathComponent("recovered.sql")
        let originalBytes = Data("SELECT 'external';".utf8)
        try originalBytes.write(to: original)
        let hash = try SQLFileBinding.write("SELECT 'recovered';", to: destination, expectedSHA256: nil)
        #expect(try SQLFileBinding.read(destination).sha256 == hash)
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func symlinksDirectoriesRemoteURLsAndInvalidUTF8AreNotRecoveredFileTargets() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.sql")
        let alias = directory.appendingPathComponent("alias.sql")
        let invalid = directory.appendingPathComponent("invalid.sql")
        let originalBytes = Data("SELECT 'preserve';".utf8)
        try originalBytes.write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        try Data([0xff, 0xfe, 0xff]).write(to: invalid)
        for target in [alias, directory, URL(string: "https://example.invalid/query.sql")!] {
            #expect(throws: SQLFileBindingError.self) { try SQLFileBinding.read(target) }
            #expect(throws: SQLFileBindingError.self) {
                try SQLFileBinding.write("SELECT 'draft';", to: target, expectedSHA256: nil)
            }
        }
        #expect(throws: SQLFileBindingError.self) { try SQLFileBinding.read(invalid) }
        #expect(try Data(contentsOf: original) == originalBytes)
    }
}
