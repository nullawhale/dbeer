import Darwin
import Foundation
import Testing
@testable import DBeer

@MainActor
struct SchemaBundleScalabilityTests {
    @Test func hundredsOfFinishedObjectsKeepDescriptorUseBounded() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let before = (0..<1_024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        let destination = root.appendingPathComponent("many-objects")
        let publication = try SchemaBundleDirectory(destination: destination)
        var files: [SchemaBundleFile] = []
        for index in 0..<600 {
            let (file, bytes) = SchemaBundleFixtures.file("object-\(index).sql")
            try publication.begin(file); try publication.append(bytes, to: file); try publication.finish(file)
            files.append(file)
        }
        let after = (0..<1_024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        #expect(after <= before + 32)
        try await publication.publish(expectedFiles: files)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 600)
    }
    @Test func directoryEnforcesDeclaredByteQuotaBeforeOpeningAnotherFile() throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let publication = try SchemaBundleDirectory(destination: root.appendingPathComponent("bundle"))
        let first = SchemaBundleFile(id: "first", path: "first", bytes: SchemaBundleManifest.maximumBytes, sha256: String(repeating: "a", count: 64))
        try publication.begin(first)
        let (second, _) = SchemaBundleFixtures.file("second")
        #expect(throws: SchemaBundleFailure.self) { try publication.begin(second) }
    }
}
