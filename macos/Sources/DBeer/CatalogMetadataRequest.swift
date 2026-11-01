import Foundation

/// One metadata consumer owns cancellation of one queued or submitted request.
/// Cancelling the task alone stops only queued work; submitted work also needs
/// a correlated helper cancellation and a terminal reply before another load.
@MainActor
final class CatalogMetadataRequest {
    let queryID = UUID().uuidString
    var task: Task<BackendMessage, Error>?
    var submitted = false
    var finished = false
    var cancelled = false
}
