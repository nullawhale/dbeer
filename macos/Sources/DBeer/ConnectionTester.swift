import Combine
import Foundation

/// A disposable helper keeps draft checks independent of workspace sessions and
/// credential persistence. Its shutdown also bounds cancellation of a stalled open.
@MainActor
final class ConnectionTester: ObservableObject {
    enum State: Equatable {
        case idle, testing, cancelling, succeeded, cancelled, failed(String)
    }

    @Published private(set) var state: State = .idle
    private let helperFactory: () -> BackendClient
    private var client: BackendClient?
    private var sshProfileId: String?
    private var cancellationRequested = false

    init(helperFactory: @escaping () -> BackendClient = { BackendClient() }) {
        self.helperFactory = helperFactory
    }

    var isTesting: Bool { state == .testing || state == .cancelling }

    func reset() {
        if !isTesting { state = .idle }
    }

    func cancel() {
        guard isTesting else { return }
        cancellationRequested = true
        state = .cancelling
        if let sshProfileId { SSHConnectionReview.cancel(profileId: sshProfileId) }
        if let client { Task { _ = await client.shutdown() } }
    }

    func test(_ settings: ConnectionSettings) async {
        guard !isTesting else { return }
        guard settings.hasValidNativeFields else {
            state = .failed("Enter valid connection settings before testing.")
            return
        }
        var settings = settings
        // SSH reviews and tunnels must not share an identity with live profiles.
        settings.ssh?.profileId = UUID().uuidString
        sshProfileId = settings.ssh?.profileId
        cancellationRequested = false
        state = .testing
        let client = helperFactory()
        self.client = client
        var outcome: State = .succeeded
        do {
            try await client.start()
            try checkCancellation()
            try await SSHConnectionReview.prepare(settings, client: client)
            try checkCancellation()
            let reply = try await client.request(.connect(settings))
            guard let sessionId = reply.sessionId else { throw BackendTransportError(.invalidMessage) }
            // Close even a session that arrived after the user cancelled.
            _ = try await client.request(.disconnect(sessionId: sessionId))
            try checkCancellation()
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        _ = await client.shutdown()
        self.client = nil
        sshProfileId = nil
        state = cancellationRequested || Task.isCancelled ? .cancelled : outcome
    }

    private func checkCancellation() throws {
        if cancellationRequested { throw CancellationError() }
        try Task.checkCancellation()
    }
}
