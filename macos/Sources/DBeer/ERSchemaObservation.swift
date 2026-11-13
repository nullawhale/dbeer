import Combine
import Foundation

/// Transient observation owns a readonly monitor connection and stops after
/// failures or scope changes. Restored diagrams never instantiate an observer.
@MainActor
final class ERSchemaObservation: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?
    private let engine: DatabaseEngine
    private let tables: [SchemaObservationTable]
    private let connect: @MainActor () async throws -> String
    private let send: @MainActor (BackendCommand) async throws -> BackendMessage
    private let isCurrent: @MainActor () -> Bool
    private let cancelPreparation: @MainActor () -> Void
    private let metadataChanged: @MainActor (String) -> Void
    private let changed: @MainActor () -> Void
    private var sessionID: String?
    private var queryID: String?
    private var generation: UInt64 = 0
    private var revision: String?
    private var timer: Task<Void, Never>?
    private var operation: Task<Void, Never>?

    init(engine: DatabaseEngine, tables: [SchemaObservationTable],
         connect: @escaping @MainActor () async throws -> String,
         send: @escaping @MainActor (BackendCommand) async throws -> BackendMessage,
         isCurrent: @escaping @MainActor () -> Bool,
         cancelPreparation: @escaping @MainActor () -> Void,
         metadataChanged: @escaping @MainActor (String) -> Void,
         changed: @escaping @MainActor () -> Void = {}) {
        self.engine = engine; self.tables = tables; self.connect = connect; self.send = send
        self.isCurrent = isCurrent; self.cancelPreparation = cancelPreparation; self.metadataChanged = metadataChanged; self.changed = changed
    }
    deinit { timer?.cancel(); operation?.cancel() }

    func start() async {
        guard !enabled, !isBusy, isCurrent(), SchemaObservationRequest(action: "poll", tables: tables).valid else { return }
        generation &+= 1
        enabled = true; revision = nil; notice = nil; changed()
        await refresh()
        guard enabled else { return }
        metadataChanged("Schema observation started. Build explicitly to refresh the diagram baseline.")
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.enabled else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard enabled, !isBusy else { return }
        let token = generation
        isBusy = true; changed()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.queryID = nil; self.changed() }
            do {
                let result = try await self.request(.init(action: "poll", tables: self.tables), token: token)
                guard self.current(token) else { return }
                guard result.complete else { throw ERDiagramFailure(result.notices.joined(separator: " ")) }
                if let previous = self.revision, previous != result.revision {
                    self.metadataChanged("A schema change was observed. Build explicitly to refresh diagram metadata.")
                }
                self.revision = result.revision
                self.notice = self.engine == .postgresql ? "Watching database DDL notifications." : "Checking selected table fingerprints every five seconds."
            } catch {
                guard self.generation == token else { return }
                self.enabled = false; self.timer?.cancel()
                self.notice = "Observation stopped. \(error.localizedDescription) Enable it explicitly to retry."
                self.metadataChanged("Schema observation ended. Existing metadata may be stale. Build explicitly to refresh.")
                await self.disconnect()
            }
        }
        operation = task
        await task.value
        if generation == token { operation = nil }
    }

    func preview(remove: Bool) async throws -> SchemaObservation {
        guard !enabled, !isBusy, engine == .postgresql, isCurrent() else { throw CancellationError() }
        generation &+= 1; let token = generation
        isBusy = true; changed()
        defer { isBusy = false; queryID = nil; changed() }
        do {
            let result = try await request(.init(action: remove ? "previewRemove" : "previewInstall", tables: []), token: token)
            guard current(token), remove ? result.canRemove : result.canInstall else {
                throw ERDiagramFailure(remove ? "The expected installation or removal privilege could not be verified." : "Installation requires a PostgreSQL superuser and an unused dbeer_schema_watch_v1 schema.")
            }
            await disconnect()
            return result
        } catch { await disconnect(); throw error }
    }

    private func request(_ request: SchemaObservationRequest, token: UInt64) async throws -> SchemaObservation {
        guard current(token) else { throw CancellationError() }
        if sessionID == nil {
            let opened = try await connect()
            guard current(token) else { _ = try? await send(.disconnect(sessionId: opened)); throw CancellationError() }
            sessionID = opened
        }
        guard current(token), let sessionID else { throw CancellationError() }
        let query = UUID().uuidString; queryID = query
        let reply = try await send(.init(type: "monitor.schema", requestId: UUID().uuidString, sessionId: sessionID, queryId: query, schemaObservation: request))
        guard current(token), reply.type == "monitor.schema.result", reply.sessionId == sessionID, reply.queryId == query,
              reply.connected == true, reply.transactionStatus == .idle, let result = reply.schemaObservation,
              result.valid, result.engine == engine, result.action == request.action, result.tables == request.tables else { throw BackendTransportError(.invalidMessage) }
        return result
    }
    private func current(_ token: UInt64) -> Bool { generation == token && !Task.isCancelled && isCurrent() }

    func stop() async {
        enabled = false; generation &+= 1
        timer?.cancel(); timer = nil; operation?.cancel(); cancelPreparation()
        if let sessionID, let queryID { _ = try? await send(.cancel(sessionId: sessionID, queryId: queryID)) }
        await operation?.value; operation = nil
        await disconnect(); isBusy = false; notice = "Schema observation is off."; changed()
    }
    private func disconnect() async {
        if let sessionID { _ = try? await send(.disconnect(sessionId: sessionID)) }
        sessionID = nil
    }
}
