import Foundation

typealias CatalogMetadataPageHandler = @MainActor (CatalogMetadataCollection) throws -> Void

/// Collects one frozen catalog observation through the profile's existing
/// serialized service queue. Each submitted page retains targeted cancellation.
@MainActor
enum CatalogMetadataLoader {
    typealias Sender = @MainActor (BackendCommand) async throws -> BackendMessage

    static func load(_ selector: CatalogRequest, sessionID: String, request: CatalogMetadataRequest? = nil,
                     isCurrent: @MainActor () -> Bool, onPage: CatalogMetadataPageHandler? = nil, send: Sender) async throws -> BackendMessage {
        var accumulator = CatalogMetadataAccumulator()
        var cursor: String?
        var captureID: String?
        var lastRequestID = ""
        var lastQueryID = ""
        func release() async {
            guard let captureID else { return }
            _ = try? await send(BackendCommand(type: "catalog.close", requestId: UUID().uuidString,
                sessionId: sessionID, queryId: UUID().uuidString,
                catalogMetadata: .init(captureIds: [captureID])))
        }
        do {
            repeat {
                try Task.checkCancellation()
                guard isCurrent(), request?.cancelled != true else { throw CatalogMetadataFailure("The metadata context changed. Refresh explicitly.") }
                let queryID = UUID().uuidString
                request?.queryID = queryID
                request?.submitted = true
                let command = BackendCommand(type: "catalog.page", requestId: UUID().uuidString,
                    sessionId: sessionID, queryId: queryID,
                    catalogMetadata: .init(selectors: [selector], cursor: cursor))
                let reply = try await send(command)
                request?.submitted = false
                guard let page = reply.catalogMetadata?.collections.first,
                      reply.catalogMetadata?.collections.count == 1 else { throw BackendTransportError(.invalidMessage) }
                if let captureID, captureID != page.captureId { throw BackendTransportError(.invalidMessage) }
                if captureID == nil { captureID = page.captureId }
                guard isCurrent(), request?.cancelled != true else { throw CatalogMetadataFailure("The metadata context changed. Refresh explicitly.") }
                try accumulator.append(page, selector: selector)
                try Task.checkCancellation()
                try onPage?(page)
                guard isCurrent(), request?.cancelled != true else { throw CatalogMetadataFailure("The metadata context changed. Refresh explicitly.") }
                try Task.checkCancellation()
                cursor = page.nextCursor
                lastRequestID = reply.requestId
                lastQueryID = queryID
            } while cursor != nil
            let result = try accumulator.result(requestId: lastRequestID, sessionId: sessionID, queryId: lastQueryID)
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}
