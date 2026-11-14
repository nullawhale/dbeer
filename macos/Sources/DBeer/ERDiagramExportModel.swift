import Combine
import Foundation

@MainActor
final class ERDiagramExportModel: ObservableObject {
    enum Phase: Equatable { case ready, rendering, saving, stopping, completed, cancelled, failed, closed }
    typealias Renderer = @Sendable (ERDiagramExportSnapshot, ERDiagramExportFormat, ERDiagramExportOptions) throws -> Data
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    let documentID: UUID
    let profileID: UUID
    private let available: @MainActor @Sendable () -> Bool
    private let startAllowed: @MainActor @Sendable () -> Bool
    private var generation = UUID()
    private var operationID: UUID?
    @Published private var operation: Task<Void, Never>?
    @Published private var retiring = false
    private var renderWorker: Task<Data, any Error>?
    private var cancellation: ERDiagramExportCancellation?

    init(documentID: UUID, profileID: UUID, startAllowed: @escaping @MainActor @Sendable () -> Bool = { true },
         available: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.documentID = documentID; self.profileID = profileID; self.startAllowed = startAllowed; self.available = available
    }
    var isWorking: Bool { phase == .rendering || phase == .saving || phase == .stopping }
    var canStart: Bool { !retiring && phase != .closed && operation == nil && startAllowed() && available() }
    var status: String? {
        switch phase {
        case .ready, .closed: nil
        case .rendering: "Rendering diagram…"
        case .saving: "Saving diagram…"
        case .stopping: "Stopping export…"
        case .completed: "Diagram exported."
        case .cancelled: "Export stopped."
        case .failed: error
        }
    }
    func report(_ error: any Error) {
        guard operation == nil else { return }
        phase = .failed
        self.error = (error as? ERDiagramExportFailure)?.errorDescription ?? "The diagram could not be exported."
    }

    func export(_ snapshot: ERDiagramExportSnapshot, format: ERDiagramExportFormat, options: ERDiagramExportOptions,
                to destination: URL, sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
                renderer: @escaping Renderer = { snapshot, format, options in try ERDiagramExportRenderer.render(snapshot, format: format, options: options) },
                publicationHook: ERDiagramExportPublicationHook? = nil,
                cleanupHook: ERDiagramExportCleanupHook? = nil) async {
        guard canStart else { return }
        let token = UUID(), cancellation = ERDiagramExportCancellation()
        generation = token; operationID = token; self.cancellation = cancellation
        phase = .rendering; progress = 0; error = nil; savedURL = nil
        let task = Task { @MainActor [self] in
            await perform(snapshot, format: format, options: options, destination: destination, token: token,
                          cancellation: cancellation, sourceIsCurrent: sourceIsCurrent,
                          renderer: renderer, publicationHook: publicationHook, cleanupHook: cleanupHook)
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }

    private func perform(_ snapshot: ERDiagramExportSnapshot, format: ERDiagramExportFormat, options: ERDiagramExportOptions,
                         destination: URL, token: UUID, cancellation: ERDiagramExportCancellation,
                         sourceIsCurrent: @escaping @MainActor @Sendable () -> Bool,
                         renderer: @escaping Renderer, publicationHook: ERDiagramExportPublicationHook?,
                         cleanupHook: ERDiagramExportCleanupHook?) async {
        var publication: ERDiagramExportFile?
        do {
            try requireCurrent(token, source: sourceIsCurrent)
            // Pin destination ownership before rendering can suspend.
            let output = try ERDiagramExportFile(destination: destination)
            publication = output
            let worker = Task.detached(priority: .userInitiated) { try renderer(snapshot, format, options) }
            renderWorker = worker
            let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
            renderWorker = nil
            try requireCurrent(token, source: sourceIsCurrent)
            guard data.count <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.tooLarge }
            phase = .saving
            try await output.publish(data, cancellation: cancellation, isCurrent: { [weak self] in
                guard let self else { return false }
                return self.generation == token && self.available() && sourceIsCurrent()
            }, hook: { [weak self] item in
                guard let self else { throw CancellationError() }
                await MainActor.run {
                    guard self.generation == token else { return }
                    let stage: Double = switch item.phase { case .writing: 0; case .beforePublish: 1; case .afterPublish: 2 }
                    self.progress = (stage + Double(item.offset) / Double(max(1, data.count))) / 3
                }
                try await publicationHook?(item)
            }, didCommit: {
                self.savedURL = destination; self.progress = 1; self.phase = .completed
            })
        } catch is CancellationError {
            if generation == token { phase = .cancelled }
        } catch {
            if generation == token { phase = .failed; self.error = (error as? ERDiagramExportFailure)?.errorDescription ?? "The diagram could not be exported." }
        }
        if let publication { await publication.finishOwnership(hook: cleanupHook) }
        if operationID == token {
            renderWorker = nil; operation = nil; operationID = nil; self.cancellation = nil
            if phase == .stopping { phase = .cancelled }
        }
    }

    func stop() async {
        guard let operation, phase != .completed else { return }
        generation = UUID(); cancellation?.cancel(); renderWorker?.cancel(); operation.cancel(); phase = .stopping
        await operation.value
    }
    func preventNewExports() { retiring = true }
    func close() async { retiring = true; await stop(); phase = .closed }

    private func requireCurrent(_ token: UUID, source: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard generation == token, available(), source() else { throw CancellationError() }
    }
}
