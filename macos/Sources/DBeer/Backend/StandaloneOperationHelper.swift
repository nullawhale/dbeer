import Foundation

/// Owns the process and private files of one standalone database operation.
actor StandaloneOperationHelper {
    enum Feature: CaseIterable, Sendable {
        case dataTransfer, databaseTools

        fileprivate var scratchPrefix: String {
            switch self {
            case .dataTransfer: "dbeer-transfer-"
            case .databaseTools: "dbeer-database-tools-owner-"
            }
        }
    }

    private let feature: Feature
    private let client: BackendClient
    private let ownerID = UUID()
    private let scratchURL: URL
    private var closed = false
    private var startup: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?

    init(feature: Feature, executableURL: URL = BackendClient.bundledExecutableURL(), arguments: [String] = [],
         scratchParentURL: URL = FileManager.default.temporaryDirectory) {
        self.feature = feature
        let scratch = scratchParentURL.appendingPathComponent(feature.scratchPrefix + UUID().uuidString, isDirectory: true)
        scratchURL = scratch
        client = BackendClient(executableURL: executableURL, arguments: arguments,
            environment: ["DBEER_TRANSFER_ROOT": scratch.path, "DBEER_DATABASE_TOOLS_ROOT": scratch.path])
    }

    func prepare(connections: [ConnectionSettings]) async throws {
        guard !closed else { throw CancellationError() }
        if startup == nil {
            try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            startup = Task { try await client.start() }
        }
        try await startup?.value
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let supported = switch feature {
        case .dataTransfer: await client.supportsDataTransfer()
        case .databaseTools: await client.supportsDatabaseTools()
        }
        guard supported else { throw BackendRequestError.invalidCommand }
        for settings in connections where settings.ssh != nil {
            var trusted = false
            for _ in 0..<17 {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                try await SSHConnectionReview.prepare(settings, client: client, ownerID: ownerID)
                // A shared first-trust review belongs to its original helper.
                // This process must verify its own route before using it.
                let ownProbe = try await client.request(.sshProbe(settings))
                if ownProbe.ssh?.status == "trusted" { trusted = true; break }
            }
            guard trusted else { throw BackendTransportError(.invalidMessage) }
        }
    }

    func request(_ command: BackendCommand) async throws -> BackendMessage {
        guard !closed else { throw CancellationError() }
        return try await client.request(command)
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        await SSHConnectionReview.cancel(ownerID: ownerID)
        _ = try? await startup?.value
        _ = await client.shutdown()
        // The child has exited, including a forced exit. Remove private files
        // even if Go could not finish its deferred cleanup.
        try? FileManager.default.removeItem(at: scratchURL)
    }
}
