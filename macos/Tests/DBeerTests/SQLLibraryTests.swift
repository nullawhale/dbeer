import Foundation
import Testing
@testable import DBeer

/// In-memory metadata only. No file reads, helpers, database sessions or UI.
@MainActor
struct SQLLibraryTests {
    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/sql-library-fixtures/" + name + ".sql") }

    @Test func oneFileKeepsItsIdentityAsMetadataChangesWithoutCopyingText() throws {
        let library = SQLLibrary()
        let first = try library.upsertEntry(fileURL: file("analysis"), folder: " Reports / Daily / ",
            tags: [" sales ", "Sales", "", "e\u{301}", "é"], scope: .allConnections)
        #expect(first.folder == "Reports/Daily" && first.tags == ["sales", "e\u{301}"])
        #expect(library.entry(at: file("nested/../analysis")) == first)
        let profile = UUID()
        let updated = try library.upsertEntry(id: first.id, fileURL: first.fileURL,
            folder: "Reports/Monthly", tags: ["finance"], scope: .profile(profile))
        #expect(updated.id == first.id && library.snapshot.entries == [updated])
        #expect(library.entry(id: first.id)?.scope == .profile(profile))
        let encoded = try JSONEncoder().encode(library.snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entry = try #require((object["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["id", "fileURL", "folder", "tags", "scope"])
        #expect(try JSONDecoder().decode(SQLLibrarySnapshot.self, from: encoded) == library.snapshot)
    }

    @Test func scopesCombineWithFoldersTagsAndSearchAcrossSharedProfileGroups() throws {
        let library = SQLLibrary()
        let development = UUID(), staging = UUID(), production = UUID()
        let group = try library.upsertGroup(name: " Non-production ", profileIDs: [development, staging, development])
        #expect(group.name == "Non-production" && group.profileIDs == [development, staging])
        let common = try library.upsertEntry(fileURL: file("common"), folder: "Reports", tags: ["daily"])
        let team = try library.upsertEntry(fileURL: file("team"), folder: "Reports", tags: ["sales"], scope: .group(group.id))
        let local = try library.upsertEntry(fileURL: file("production"), tags: ["sales"], scope: .profile(production))
        #expect(library.allows(entry: common, profileID: production))
        #expect(library.allows(entry: team, profileID: staging) && !library.allows(entry: team, profileID: production))
        #expect(library.allows(entry: local, profileID: production) && !library.allows(entry: local, profileID: development))
        #expect(library.filteredEntries(profileID: development).map(\.id) == [common.id, team.id])
        #expect(library.filteredEntries(query: "SALES", profileID: staging, folder: "reports", tag: "Sales") == [team])
        #expect(library.filteredEntries(query: "TEAM.SQL") == [team])
        #expect(library.filteredEntries(query: "reports", profileID: production) == [common])
        #expect(library.filteredEntries(profileID: nil).count == 3)
    }

    @Test func groupChangesAndDeletionNeverBroadenEntryScope() throws {
        let library = SQLLibrary()
        let first = UUID(), second = UUID()
        let group = try library.upsertGroup(name: "Team", profileIDs: [first])
        let entry = try library.upsertEntry(fileURL: file("shared"), scope: .group(group.id))
        #expect(library.allows(entry: entry, profileID: first))
        _ = try library.upsertGroup(id: group.id, name: "Renamed team", profileIDs: [second])
        #expect(!library.allows(entry: entry, profileID: first) && library.allows(entry: entry, profileID: second))
        library.removeGroup(group.id)
        #expect(library.entry(id: entry.id)?.scope == .group(group.id))
        #expect(library.snapshot.isValid && !library.allows(entry: entry, profileID: first))
        #expect(!library.allows(entry: entry, profileID: second))
        let replacement = try library.upsertGroup(name: "Renamed team", profileIDs: [first, second])
        #expect(replacement.id != group.id && !library.allows(entry: entry, profileID: first))
        #expect(library.filteredEntries(profileID: nil) == [entry])
        #expect(library.filteredEntries(profileID: first).isEmpty)
    }

    @Test func staleEntryCannotRetainScopeAfterEditingRemovalOrRebinding() throws {
        let library = SQLLibrary()
        let first = UUID(), second = UUID()
        let entry = try library.upsertEntry(fileURL: file("shared"), scope: .profile(first))
        #expect(library.allows(entry: entry, profileID: first))
        _ = try library.upsertEntry(id: entry.id, fileURL: entry.fileURL, scope: .profile(second))
        #expect(!library.allows(entry: entry, profileID: first) && library.allows(entry: entry, profileID: second))
        let moved = try library.upsertEntry(id: entry.id, fileURL: file("renamed"), scope: .profile(second))
        #expect(!library.allows(entry: entry, profileID: second) && library.allows(entry: moved, profileID: second))
        library.removeEntry(entry.id)
        #expect(!library.allows(entry: moved, profileID: second))
        #expect(library.entry(at: moved.fileURL) == nil && library.snapshot.entries.isEmpty)
    }

    @Test func invalidMutationsAndDuplicateRecordsKeepExistingMetadata() throws {
        let library = SQLLibrary()
        let entry = try library.upsertEntry(fileURL: file("shared"), folder: "Queries", tags: ["keep"])
        let group = try library.upsertGroup(name: "Development", profileIDs: [UUID()])
        let before = library.snapshot
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(fileURL: entry.fileURL) }
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(id: UUID(), fileURL: file("unknown")) }
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(fileURL: URL(string: "https://example.invalid/query.sql")!) }
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(fileURL: file("bad"), folder: "../outside") }
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(fileURL: file("bad"), tags: ["two\nlines"]) }
        #expect(throws: SQLLibraryError.self) { try library.upsertGroup(name: "development", profileIDs: []) }
        #expect(throws: SQLLibraryError.self) { try library.upsertGroup(id: UUID(), name: "Unknown", profileIDs: []) }
        #expect(throws: SQLLibraryError.self) { try library.upsertGroup(id: group.id, name: " ", profileIDs: []) }
        #expect(library.snapshot == before && library.error != nil)
        let updated = try library.upsertEntry(id: entry.id, fileURL: entry.fileURL, tags: ["retry"])
        #expect(library.error == nil && updated.tags == ["retry"])
    }

    @Test func restoringMissingFilesAndReferencesIsPureMetadataAndPreservesUnavailableScopes() throws {
        let missingProfile = UUID(), missingGroup = UUID()
        let entries = [SQLLibraryEntry(fileURL: file("not-present-profile"), scope: .profile(missingProfile)),
            SQLLibraryEntry(fileURL: file("not-present-group"), scope: .group(missingGroup))]
        let snapshot = SQLLibrarySnapshot(entries: entries)
        let library = SQLLibrary()
        #expect(library.restore(snapshot))
        #expect(library.snapshot == snapshot && library.entry(at: entries[0].fileURL) == entries[0])
        #expect(!library.allows(entry: entries[1], profileID: missingProfile))
        var invalid = snapshot
        invalid.entries.append(entries[0])
        #expect(!library.restore(invalid) && library.snapshot == snapshot && library.error != nil)
        let unavailable = SQLLibrary(snapshot: invalid)
        #expect(unavailable.snapshot.entries.isEmpty && unavailable.error != nil)
        #expect(try JSONDecoder().decode(SQLLibrarySnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func decodingRejectsUnknownFieldsMalformedScopesAndNonCanonicalMetadata() throws {
        let entry = SQLLibraryEntry(fileURL: file("strict"))
        let snapshot = SQLLibrarySnapshot(entries: [entry])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let record = try #require((object["entries"] as? [[String: Any]])?.first)
        let malformed: [[String: Any]] = [
            record.merging(["sql": "unwanted-copy"]) { _, newer in newer },
            record.merging(["scope": ["kind": "allConnections", "profileID": UUID().uuidString]]) { _, newer in newer },
            record.merging(["scope": ["kind": "profile"]]) { _, newer in newer },
            record.merging(["scope": ["kind": "future"]]) { _, newer in newer },
            record.merging(["folder": "nested/../outside"]) { _, newer in newer },
            record.merging(["tags": ["sales", "SALES"]]) { _, newer in newer },
            record.merging(["fileURL": "file:///sql-library-fixtures/nested/../strict.sql"]) { _, newer in newer },
            record.merging(["fileURL": "file:///sql-library-fixtures/note.txt"]) { _, newer in newer },
        ]
        for record in malformed {
            var changed = object
            changed["entries"] = [record]
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLLibrarySnapshot.self, from: data) }
        }
        var changed = object
        changed["future"] = true
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SQLLibrarySnapshot.self, from: data) }
    }

    @Test func everyScopeRoundTripsWithoutConnectionSettings() throws {
        let profile = UUID(), group = UUID()
        for scope: SQLLibraryScope in [.allConnections, .profile(profile), .group(group)] {
            let data = try JSONEncoder().encode(scope)
            #expect(try JSONDecoder().decode(SQLLibraryScope.self, from: data) == scope)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: ["kind", "profileID", "groupID"]))
        }
        let duplicateName = SQLLibrarySnapshot(groups: [SQLProfileGroup(name: "Team"), SQLProfileGroup(name: "team")])
        let duplicateProfiles = SQLLibrarySnapshot(groups: [SQLProfileGroup(name: "Team", profileIDs: [profile, profile])])
        #expect(!duplicateName.isValid && !duplicateProfiles.isValid)
    }

    @Test func entryLimitRejectsAnAdditionalRecordWithoutDroppingExistingRecords() throws {
        let entries = (0..<5_000).map { SQLLibraryEntry(fileURL: file("query-\($0)")) }
        let library = SQLLibrary(snapshot: SQLLibrarySnapshot(entries: entries))
        #expect(library.error == nil && library.snapshot.entries.count == 5_000)
        #expect(throws: SQLLibraryError.self) { try library.upsertEntry(fileURL: file("one-too-many")) }
        #expect(library.snapshot.entries == entries)
    }
}
