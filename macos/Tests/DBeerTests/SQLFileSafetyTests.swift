import Darwin
import Foundation
import Testing
@testable import DBeer

/// File publication tests use isolated local files and deterministic race hooks.
/// They do not open a chooser, application, window or database connection.
struct SQLFileSafetyTests {
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/r12-r13/files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func exactUTF8BOMMixedLineBreaksAndPermissionsSurviveSave() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quoted name.sql")
        let original = Data("\u{feff}SELECT 'κόσμος 🐋';\r\n-- combining e\u{301}\nSELECT '';\r".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let loaded = try SQLFileBinding.read(url)
        #expect(Data(loaded.text.utf8) == original && loaded.text.unicodeScalars.first?.value == 0xfeff)
        #expect(loaded.sha256 == SQLFileBinding.digestText(loaded.text))
        let saved = try SQLFileBinding.write(loaded.text, to: url, expectedVersion: loaded.version)
        #expect(Data(saved.text.utf8) == original && saved.identity != loaded.identity)
        #expect(try Data(contentsOf: url) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func reviewedVersionRejectsAReplacementEvenWhenItsBytesMatch() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("version.sql")
        let accepted = Data("SELECT 'accepted';".utf8)
        try accepted.write(to: url)
        let original = try SQLFileBinding.read(url)
        try accepted.write(to: url, options: .atomic)
        let replacement = try SQLFileBinding.read(url)
        #expect(replacement.sha256 == original.sha256 && replacement.identity != original.identity)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("SELECT 'local';", to: url, expectedVersion: original.version)
        }
        #expect(try Data(contentsOf: url) == accepted)
        let saved = try SQLFileBinding.write("SELECT 'reviewed local';", to: url, expectedVersion: replacement.version)
        #expect(try SQLFileBinding.read(url) == saved)
    }

    @Test func nilVersionAndLegacyNilHashCannotReplaceExistingFiles() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.sql")
        let external = Data("SELECT 'external';".utf8)
        try external.write(to: url)
        #expect(throws: SQLFileBindingError.self) { try SQLFileBinding.write("local", to: url, expectedVersion: nil) }
        #expect(throws: SQLFileBindingError.self) { try SQLFileBinding.write("local", to: url, expectedSHA256: nil) }
        #expect(try Data(contentsOf: url) == external)
    }

    @Test func aDestinationCreatedAtPublicationIsNeverReplaced() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("new.sql")
        let external = Data("SELECT 'new external';".utf8)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("SELECT 'local';", to: url, expectedVersion: nil) { stage, _ in
                if stage == .willPublish { try external.write(to: url) }
            }
        }
        #expect(try Data(contentsOf: url) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func aFileReplacedAfterTheFinalCheckIsRestoredWithoutLosingExternalBytes() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boundary.sql")
        try Data("SELECT 'accepted';".utf8).write(to: url)
        let accepted = try SQLFileBinding.read(url)
        let external = Data("SELECT 'external at boundary';".utf8)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("SELECT 'local';", to: url, expectedVersion: accepted.version) { stage, _ in
                if stage == .willDisplace { try external.write(to: url, options: .atomic) }
            }
        }
        #expect(try Data(contentsOf: url) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func aFileAppearingAfterDisplacementKeepsBothExternalVersions() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent.sql")
        let accepted = Data("SELECT 'accepted';".utf8)
        let external = Data("SELECT 'new external';".utf8)
        try accepted.write(to: url)
        let loaded = try SQLFileBinding.read(url)
        do {
            _ = try SQLFileBinding.write("SELECT 'local';", to: url, expectedVersion: loaded.version) { stage, _ in
                if stage == .didDisplace { try external.write(to: url) }
            }
            Issue.record("A concurrently created destination must prevent publication.")
        } catch let error as SQLFileBindingError {
            let recovered = try #require(error.recoveryURL)
            #expect(try Data(contentsOf: recovered) == accepted)
            #expect(try Data(contentsOf: url) == external)
        }
    }

    @Test func aChangedDisplacedInodeIsRestoredAndAFailedWriteRestoresTheOriginal() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.sql")
        try Data("SELECT 'accepted';".utf8).write(to: url)
        let loaded = try SQLFileBinding.read(url)
        let external = Data("SELECT 'external through old handle';".utf8)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("local", to: url, expectedVersion: loaded.version) { stage, recovery in
                if stage == .didDisplace, let recovery { try external.write(to: recovery) }
            }
        }
        #expect(try Data(contentsOf: url) == external)
        let retry = try SQLFileBinding.read(url)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("local", to: url, expectedVersion: retry.version) { stage, _ in
                if stage == .didDisplace { throw SQLFileBindingError.write }
            }
        }
        #expect(try Data(contentsOf: url) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func aLaterReplacementAfterPublicationIsKeptAndReportedWithRecovery() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("after.sql")
        let accepted = Data("SELECT 'accepted';".utf8)
        let external = Data("SELECT 'external after publication';".utf8)
        try accepted.write(to: url)
        let loaded = try SQLFileBinding.read(url)
        do {
            _ = try SQLFileBinding.write("local", to: url, expectedVersion: loaded.version) { stage, _ in
                if stage == .didPublish { try external.write(to: url, options: .atomic) }
            }
            Issue.record("A replacement during publication must be reported.")
        } catch let error as SQLFileBindingError {
            let recovered = try #require(error.recoveryURL)
            #expect(try Data(contentsOf: recovered) == accepted)
            #expect(try Data(contentsOf: url) == external)
        }
    }

    @Test func deletingThePublishedFileRestoresTheOriginalWithoutAStaleRecoveryURL() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("deleted-after.sql")
        let accepted = Data("SELECT 'accepted';".utf8)
        try accepted.write(to: url)
        let loaded = try SQLFileBinding.read(url)
        do {
            _ = try SQLFileBinding.write("local", to: url, expectedVersion: loaded.version) { stage, _ in
                if stage == .didPublish { try FileManager.default.removeItem(at: url) }
            }
            Issue.record("A deletion during publication must be reported.")
        } catch let error as SQLFileBindingError {
            #expect(error.recoveryURL == nil)
            if case .changed = error {} else { Issue.record("A successful rollback must report a changed destination.") }
        }
        #expect(try SQLFileBinding.read(url) == loaded)
        #expect(try Data(contentsOf: url) == accepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
    }

    @Test func aReplacedParentCannotRedirectPublicationIntoAnotherDirectory() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("project", isDirectory: true)
        let moved = directory.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let url = original.appendingPathComponent("query.sql")
        let accepted = Data("SELECT 'accepted';".utf8)
        let external = Data("SELECT 'new parent';".utf8)
        try accepted.write(to: url)
        let loaded = try SQLFileBinding.read(url)
        #expect(throws: SQLFileBindingError.self) {
            try SQLFileBinding.write("local", to: url, expectedVersion: loaded.version) { stage, _ in
                if stage == .willDisplace {
                    try FileManager.default.moveItem(at: original, to: moved)
                    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
                    try external.write(to: url)
                }
            }
        }
        #expect(try Data(contentsOf: url) == external)
        #expect(try Data(contentsOf: moved.appendingPathComponent("query.sql")) == accepted)
    }
}
