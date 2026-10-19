import Foundation
import Testing
@testable import DBeer

struct HelperProcessTests {
    @Test func helperPathIsRelativeToBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/Some Folder/DBeer.app", isDirectory: true)
        #expect(BackendClient.bundledExecutableURL(bundleURL: bundle).path ==
                "/Applications/Some Folder/DBeer.app/Contents/Helpers/dbeer-core")
    }

    @Test func bundledHelperAcknowledgesShutdownAndExits() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path),
                     "Run scripts/build-app.sh before the bundled helper lifecycle test.")
        let helper = BackendClient(executableURL: executable)
        try await helper.start()
        let shutdown = await helper.shutdown()
        let exit = await helper.waitForExit()
        #expect(shutdown.acknowledged)
        #expect(!shutdown.forced)
        #expect(exit.status == 0)
    }
}
