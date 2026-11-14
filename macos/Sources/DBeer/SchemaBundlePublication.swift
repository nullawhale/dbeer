import Foundation

enum SchemaBundleVerificationPhase: Sendable { case beforePublish, afterPublish }
struct SchemaBundleVerificationProgress: Sendable {
    let phase: SchemaBundleVerificationPhase
    let fileID: String
    let offset: Int64
    let workerIsMainThread: Bool
}
typealias SchemaBundleVerificationHook = @Sendable (SchemaBundleVerificationProgress) async throws -> Void

/// Stop can retire file verification without waiting for its executor or I/O.
final class SchemaBundlePublicationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try Task.checkCancellation()
        guard lock.withLock({ !cancelled }) else { throw CancellationError() }
    }
    func commit(_ body: () throws -> Void) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try Task.checkCancellation()
            try body()
        }
    }
}
