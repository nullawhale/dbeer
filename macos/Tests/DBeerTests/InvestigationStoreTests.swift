import Darwin
import Foundation
import Testing
@testable import DBeer

/// Local value/file tests only; these tests never create a window or a helper.
struct InvestigationStoreTests {
    private func directory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/r18/investigation-store/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture() -> StoredInvestigations {
        StoredInvestigations(documents: [StoredInvestigation(title: "Exact source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), blocks: [
                StoredInvestigationBlock(kind: .markdown, text: "# e\u{301} κόσμος 🐋\r\n\nNULL is text here."),
                StoredInvestigationBlock(kind: .sql, text: "BEGIN;\r\nSELECT '', NULL, 'NULL', 9007199254740993;\n", profileID: UUID()),
                StoredInvestigationBlock(kind: .snapshot, snapshotID: UUID(), explanation: "Missing is meaningful.\r\n"),
                StoredInvestigationBlock(kind: .sql, text: "SELECT 'explicitly unbound';", profileID: nil)
            ])])
    }

    private func object(_ value: StoredInvestigations) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }

    @Test func exactSourceOrderAndOpaqueReferencesRoundTripPrivately() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Investigations")
        let url = root.appendingPathComponent("library.json")
        let stored = fixture()
        let store = FileInvestigationStore(fileURL: url)
        try await store.save(stored)
        let restored = try await FileInvestigationStore(fileURL: url).load()
        #expect(restored == stored)
        for (original, loaded) in zip(stored.documents[0].blocks, restored.documents[0].blocks) {
            #expect(original.id == loaded.id && original.text.utf8.elementsEqual(loaded.text.utf8))
            #expect(original.explanation.utf8.elementsEqual(loaded.explanation.utf8))
        }
        let json = try object(restored)
        let record = try #require((json["documents"] as? [[String: Any]])?.first)
        let blocks = try #require(record["blocks"] as? [[String: Any]])
        #expect(Set(json.keys) == ["version", "documents"])
        #expect(Set(record.keys) == ["id", "title", "createdAt", "updatedAt", "blocks"])
        #expect(Set(blocks[0].keys) == ["id", "kind", "text"])
        #expect(Set(blocks[1].keys) == ["id", "kind", "text", "profileID"])
        #expect(Set(blocks[2].keys) == ["id", "kind", "snapshotID", "explanation"])
        #expect(Set(blocks[3].keys) == ["id", "kind", "text"])
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["library.json", ".library.lock"])
    }

    @Test(arguments: InvestigationWriteStage.allCases)
    func everyFailedPublicationStageKeepsPreviousBytes(stage: InvestigationWriteStage) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let original = fixture()
        try await FileInvestigationStore(fileURL: url).save(original)
        let bytes = try Data(contentsOf: url)
        var changed = original
        changed.documents[0].blocks[0].text = "A complete newer document must not partially replace the original."
        let failing = FileInvestigationStore(fileURL: url, writeInterceptor: {
            if $0 == stage { throw InvestigationStoreError.write }
        })
        await #expect(throws: InvestigationStoreError.self) { try await failing.save(changed) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await FileInvestigationStore(fileURL: url).load() == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["library.json", ".library.lock"])
    }

    @Test func malformedFutureUnknownAndCrossKindFieldsBlockReplacement() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let valid = fixture()
        let base = try object(valid)
        let records = try #require(base["documents"] as? [[String: Any]])
        let blocks = try #require(records[0]["blocks"] as? [[String: Any]])
        var malformed = [Data("{broken".utf8)]
        var objects: [[String: Any]] = [
            base.merging(["version": 2]) { _, new in new },
            base.merging(["version": NSNull()]) { _, new in new },
            base.merging(["password": "forbidden fixture"]) { _, new in new },
            base.merging(["documents": records + records]) { _, new in new }
        ]
        func alteredDocument(_ record: [String: Any]) -> [String: Any] {
            base.merging(["documents": [record]]) { _, new in new }
        }
        for key in ["id", "title", "createdAt", "updatedAt", "blocks"] {
            var record = records[0]; record.removeValue(forKey: key)
            objects.append(alteredDocument(record))
        }
        objects.append(alteredDocument(records[0].merging(["connection": ["password": "forbidden"]]) { _, new in new }))
        objects.append(alteredDocument(records[0].merging(["blocks": blocks + [blocks[0]]]) { _, new in new }))
        for (index, fields) in [(0, ["profileID", "snapshotID", "explanation"]),
                                (1, ["snapshotID", "explanation"]),
                                (2, ["text", "profileID", "rows", "sessionId", "runtime"])] {
            for field in fields {
                for value in [NSNull(), "forbidden fixture"] as [Any] {
                    var changed = blocks
                    changed[index][field] = value
                    objects.append(alteredDocument(records[0].merging(["blocks": changed]) { _, new in new }))
                }
            }
        }
        for index in blocks.indices {
            for field in ["id", "kind"] {
                var changed = blocks; changed[index].removeValue(forKey: field)
                objects.append(alteredDocument(records[0].merging(["blocks": changed]) { _, new in new }))
            }
        }
        for id in [NSNull(), "../../snapshot", "not-a-uuid"] as [Any] {
            var changed = blocks; changed[2]["snapshotID"] = id
            objects.append(alteredDocument(records[0].merging(["blocks": changed]) { _, new in new }))
        }
        malformed += try objects.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        for bytes in malformed {
            try bytes.write(to: url)
            let store = FileInvestigationStore(fileURL: url)
            await #expect(throws: InvestigationStoreError.self) { _ = try await store.load() }
            await #expect(throws: InvestigationStoreError.self) { try await store.save(StoredInvestigations()) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func invalidInMemoryValuesCannotReplaceAValidLibrary() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let original = fixture()
        let store = FileInvestigationStore(fileURL: url)
        try await store.save(original)
        let bytes = try Data(contentsOf: url)
        var malformed: [StoredInvestigations] = []
        var changed = original; changed.version = 99; malformed.append(changed)
        changed = original; changed.documents += changed.documents; malformed.append(changed)
        changed = original; changed.documents[0].blocks += [changed.documents[0].blocks[0]]; malformed.append(changed)
        changed = original; changed.documents[0].title = " "; malformed.append(changed)
        changed = original; changed.documents[0].title = String(repeating: "a", count: InvestigationLimits.maximumTitleBytes + 1); malformed.append(changed)
        changed = original; changed.documents[0].updatedAt = changed.documents[0].createdAt.addingTimeInterval(-1); malformed.append(changed)
        changed = original; changed.documents[0].blocks[0].text = String(repeating: "🐋", count: InvestigationLimits.maximumBlockBytes / 4 + 1); malformed.append(changed)
        changed = original; changed.documents[0].blocks[0].profileID = UUID(); malformed.append(changed)
        changed = original; changed.documents[0].blocks[1].snapshotID = UUID(); malformed.append(changed)
        changed = original; changed.documents[0].blocks[2].text = "SELECT 'never execute';"; malformed.append(changed)
        changed = original; changed.documents[0].blocks[2].snapshotID = nil; malformed.append(changed)
        for value in malformed {
            await #expect(throws: InvestigationStoreError.self) { try await store.save(value) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func interruptedTemporaryFilesAreDiscardedWithoutBecomingLibraryRecords() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let value = fixture()
        try await FileInvestigationStore(fileURL: url).save(value)
        let interrupted = directory.appendingPathComponent(".investigation-\(UUID()).tmp")
        try Data("{incomplete newer SQL".utf8).write(to: interrupted)
        let unrelated = directory.appendingPathComponent("unrelated.tmp")
        try Data("retain unrelated files".utf8).write(to: unrelated)
        #expect(try await FileInvestigationStore(fileURL: url).load() == value)
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func unreadableAndSymlinkLibrariesAreNeverReplaced() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let target = directory.appendingPathComponent("target.json")
        try await FileInvestigationStore(fileURL: target).save(fixture())
        let bytes = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let symlink = FileInvestigationStore(fileURL: url)
        await #expect(throws: InvestigationStoreError.self) { _ = try await symlink.load() }
        await #expect(throws: InvestigationStoreError.self) { try await symlink.save(StoredInvestigations()) }
        #expect(try Data(contentsOf: target) == bytes)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try #require(geteuid() != 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        await #expect(throws: InvestigationStoreError.self) { _ = try await symlink.load() }
        await #expect(throws: InvestigationStoreError.self) { try await symlink.save(StoredInvestigations()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
