import Combine
import CryptoKit
import Foundation

protocol SchemaComparisonBackend: Sendable {
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse
    func inspect(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse
    func shutdown() async
}
extension SchemaComparisonBackend {
    func inspect(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        throw BackendRequestError.invalidCommand
    }
}
actor SchemaComparisonHelperBackend: SchemaComparisonBackend {
    private let client: BackendClient
    private let owner: UUID
    init(owner: UUID = UUID(), client: BackendClient = BackendClient()) { self.owner = owner; self.client = client }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        try await client.start()
        for (index, settings) in [request.source?.connection, request.target?.connection].compactMap({ $0 }).enumerated() {
            try Task.checkCancellation()
            try await SSHConnectionReview.prepare(settings, client: client, ownerID: owner,
                reviewID: "schema-comparison:" + owner.uuidString + ":" + String(index))
        }
        return try await self.request("start", request)
    }
    func inspect(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        guard request.valid(for: "schema.import.start") else { throw BackendRequestError.invalidCommand }
        try await client.start()
        try Task.checkCancellation()
        return try await self.request("import.start", request)
    }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        let reply = try await client.request(.compareSchema(operation, request))
        guard let response = reply.schemaComparison else { throw BackendTransportError(.invalidMessage) }
        return response
    }
    func shutdown() async { await SSHConnectionReview.cancel(ownerID: owner); _ = await client.shutdown() }
}

enum SchemaComparisonSourceMode: String, CaseIterable { case connection, bundle }

@MainActor
final class SchemaComparisonModel: ObservableObject, Identifiable {
    let id = UUID()
    let profiles: [SavedConnection]
    @Published var sourceID: UUID?
    @Published var targetID: UUID?
    @Published var sourceMode = SchemaComparisonSourceMode.connection
    @Published var targetMode = SchemaComparisonSourceMode.connection
    @Published private(set) var sourceBundle: SchemaImportedSource?
    @Published private(set) var targetBundle: SchemaImportedSource?
    @Published private(set) var inspectingSource = false
    @Published private(set) var inspectingTarget = false
    @Published private(set) var sourceImportError: String?
    @Published private(set) var targetImportError: String?
    private var activeSourceBundle: SchemaImportedSource?
    private var activeTargetBundle: SchemaImportedSource?
    private struct Inspection {
        var token: UUID
        var service: any SchemaComparisonBackend
        var job: String?
    }
    private var inspections: [Bool: Inspection] = [:]
    @Published var mappings = SchemaMappings()
    @Published private(set) var phase = ResultComparisonState.closed
    @Published private(set) var hasStarted = false
    @Published private(set) var sourceProfile: SavedConnection?
    @Published private(set) var targetProfile: SavedConnection?
    @Published private(set) var summary: SchemaComparisonSummary?
    @Published private(set) var page: SchemaComparisonPage?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var valueText: String?
    @Published private(set) var valueHasMore = false
    @Published private(set) var valueOffset: Int64 = 0
    @Published private(set) var valueNextOffset: Int64 = 0
    @Published private(set) var valueTotalBytes: Int64 = 0
    @Published private(set) var valueBoundaryBytes = 0
    @Published private(set) var exportComplete = false
    @Published private(set) var selectedDifference: SchemaDifference?
    @Published private(set) var diff: ComparisonTextDiff?
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var diffError: String?
    @Published private(set) var planDraft: SynchronizationPlanDraft?
    @Published private(set) var isGeneratingPlan = false
    private var planGeneration = UUID()
    private let openPlan: @MainActor (String, SavedConnection) -> Bool
    private let validatePlanTarget: @MainActor (SavedConnection) -> Bool
    private let resolve: @MainActor (SavedConnection, UUID) async throws -> ConnectionSettings
    private let factory: @MainActor (UUID) -> any SchemaComparisonBackend
    private let current: @MainActor ([SavedConnection]) -> Bool
    private let startAllowed: @MainActor () -> Bool
    private var attempt = UUID()
    private var backend: (any SchemaComparisonBackend)?
    private var jobID: String?
    private var generation = UUID()
    private var pageGeneration = UUID()
    private var valueGeneration = UUID()
    private var diffGeneration = UUID()
    private var poll: Task<Void, Never>?
    private var offsets: [Int64] = [0]
    private var selectedPreview: SchemaValuePreview?
    private var valueOffsets: [Int64] = [0]

    init(profiles: [SavedConnection], resolve: @escaping @MainActor (SavedConnection) async throws -> ConnectionSettings,
         factory: (@MainActor () -> any SchemaComparisonBackend)? = nil,
         openPlan: @escaping @MainActor (String, SavedConnection) -> Bool = { _, _ in false },
         validatePlanTarget: @escaping @MainActor (SavedConnection) -> Bool = { _ in true },
         resolveOwned: (@MainActor (SavedConnection, UUID) async throws -> ConnectionSettings)? = nil,
         ownedFactory: (@MainActor (UUID) -> any SchemaComparisonBackend)? = nil,
         current: @escaping @MainActor ([SavedConnection]) -> Bool = { _ in true },
         startAllowed: @escaping @MainActor () -> Bool = { true }) {
        self.profiles = profiles.filter { $0.engine != .mongodb }
        self.resolve = resolveOwned ?? { profile, _ in try await resolve(profile) }
        self.factory = ownedFactory ?? { owner in factory?() ?? SchemaComparisonHelperBackend(owner: owner) }
        self.openPlan = openPlan; self.validatePlanTarget = validatePlanTarget
        self.current = current; self.startAllowed = startAllowed
    }
    var boundProfileIDs: Set<UUID> { Set([sourceProfile, targetProfile].compactMap { $0?.id }) }
    var isWorking: Bool { hasStarted && phase.isWorking }
    var isInspecting: Bool { inspectingSource || inspectingTarget }
    var sourceEngine: DatabaseEngine? { sourceMode == .bundle ? sourceBundle?.source.databaseEngine : profiles.first { $0.id == sourceID }?.engine }
    var targetEngine: DatabaseEngine? { targetMode == .bundle ? targetBundle?.source.databaseEngine : profiles.first { $0.id == targetID }?.engine }
    var comparisonEngine: DatabaseEngine? { summary.flatMap { DatabaseEngine(rawValue: $0.engine) } ?? sourceProfile?.engine ?? activeSourceBundle?.source.databaseEngine }
    var sourceTitle: String { sourceProfile?.name ?? activeSourceBundle?.label ?? "Source" }
    var targetTitle: String { targetProfile?.name ?? activeTargetBundle?.label ?? "Target" }
    var canStart: Bool {
        guard !hasStarted, !isInspecting, startAllowed(), mappings.valid,
              let sourceEngine, sourceEngine == targetEngine else { return false }
        let selected = [sourceMode == .connection ? profiles.first { $0.id == sourceID } : nil,
                        targetMode == .connection ? profiles.first { $0.id == targetID } : nil].compactMap { $0 }
        guard current(selected) else { return false }
        func covered(_ bundle: SchemaImportedSource?, schemas: [String]) -> Bool {
            guard let bundle, bundle.valid else { return false }
            let names = Set(bundle.schemas.map { Data($0.utf8) })
            return schemas.allSatisfy { names.contains(Data($0.utf8)) }
        }
        return (sourceMode != .bundle || covered(sourceBundle, schemas: mappings.schemas.map(\.source))) &&
            (targetMode != .bundle || covered(targetBundle, schemas: mappings.schemas.map(\.target)))
    }
    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, current([sourceProfile, targetProfile].compactMap { $0 }) else { throw CancellationError() }
    }
    var canPrevious: Bool { !isLoading && offsets.count > 1 }
    var canNext: Bool { !isLoading && page?.hasMore == true }
    func start() async {
        guard canStart, let engine = sourceEngine else { return }
        let source = sourceMode == .connection ? profiles.first { $0.id == sourceID } : nil
        let target = targetMode == .connection ? profiles.first { $0.id == targetID } : nil
        let sourceFile = sourceMode == .bundle ? sourceBundle : nil
        let targetFile = targetMode == .bundle ? targetBundle : nil
        let mapping = mappings
        generation = UUID(); let token = generation
        sourceProfile = source; targetProfile = target
        activeSourceBundle = sourceFile; activeTargetBundle = targetFile
        hasStarted = true; phase = .pending; error = nil
        attempt = UUID(); let service = factory(attempt); backend = service
        do {
            var sourceSide: SchemaComparisonSide
            if let source {
                var settings = try await resolve(source, attempt)
                try requireCurrent(token)
                settings.policy.readOnly = true; settings.sessionPurpose = nil
                sourceSide = .init(connection: settings)
            } else { sourceSide = .init(bundle: sourceFile?.source) }
            var targetSide: SchemaComparisonSide
            if let target {
                var settings = try await resolve(target, attempt)
                try requireCurrent(token)
                settings.policy.readOnly = true; settings.sessionPurpose = nil
                targetSide = .init(connection: settings)
            } else { targetSide = .init(bundle: targetFile?.source) }
            try requireCurrent(token)
            let request = SchemaComparisonRequest(source: sourceSide, target: targetSide, mappings: mapping)
            guard request.valid(for: "schema.start") else { throw BackendRequestError.invalidCommand }
            let reply = try await service.start(request)
            try requireCurrent(token)
            guard reply.valid(for: "schema.start.result") else { throw BackendTransportError(.invalidMessage) }
            jobID = reply.jobId; phase = reply.state
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        guard let self, let job = self.jobID else { return }
                        try self.requireCurrent(token)
                        let status = try await service.request("status", .init(jobId: job))
                        try self.requireCurrent(token)
                        guard status.jobId == job, status.valid(for: "schema.status.result") else { throw BackendTransportError(.invalidMessage) }
                        self.phase = status.state
                        if status.state == .completed {
                            guard status.summary?.engine == engine.rawValue, status.summary?.mappings == mapping,
                                  Self.originMatches(status.summary?.source.origin, sourceFile),
                                  Self.originMatches(status.summary?.target.origin, targetFile) else { throw BackendTransportError(.invalidMessage) }
                            self.summary = status.summary
                            await self.loadPage(collection: "differences"); return
                        }
                        if !status.state.isWorking { self.error = status.message; return }
                    } catch is CancellationError {
                        guard let self, self.generation == token else { return }
                        self.phase = .cancelled; self.error = "The selected source context changed. Create a new comparison."
                        await service.shutdown(); return
                    } catch {
                        guard let self, self.generation == token else { return }
                        self.phase = .failed; self.error = "Schema comparison could not be completed."
                        await service.shutdown(); return
                    }
                }
            }
        } catch {
            guard generation == token else { await service.shutdown(); return }
            phase = .failed; self.error = "Schema comparison could not start. Reinspect historical sources or check live connections and metadata permissions."
            await service.shutdown()
        }
    }
    func inspectBundle(at directory: URL, target: Bool, allowSQLChanges: Bool = false) async {
        guard !hasStarted, startAllowed(), current([]) else { return }
        let modelGeneration = generation
        await cancelInspection(target: target)
        guard generation == modelGeneration, !hasStarted, startAllowed(), current([]) else { return }
        let descriptor = SchemaBundleSourceDescriptor(path: directory.path, allowSQLChanges: allowSQLChanges)
        guard directory.isFileURL, descriptor.valid(inspecting: true) else { return }
        if target { targetMode = .bundle; targetBundle = nil; targetImportError = nil; inspectingTarget = true }
        else { sourceMode = .bundle; sourceBundle = nil; sourceImportError = nil; inspectingSource = true }
        let token = UUID(); let service = factory(token)
        inspections[target] = Inspection(token: token, service: service)
        defer {
            if inspections[target]?.token == token {
                inspections[target] = nil
                if target { inspectingTarget = false } else { inspectingSource = false }
            }
        }
        func requireInspection() throws {
            try Task.checkCancellation()
            guard generation == modelGeneration, inspections[target]?.token == token, !hasStarted, current([]),
                  (target ? targetMode : sourceMode) == .bundle else { throw CancellationError() }
        }
        do {
            let started = try await service.inspect(.init(bundle: descriptor))
            try requireInspection()
            guard started.valid(for: "schema.import.start.result") else { throw BackendTransportError(.invalidMessage) }
            inspections[target]?.job = started.jobId
            while true {
                try await Task.sleep(for: .milliseconds(100))
                try requireInspection()
                let status = try await service.request("import.status", .init(jobId: started.jobId))
                try requireInspection()
                guard status.jobId == started.jobId, status.valid(for: "schema.import.status.result") else { throw BackendTransportError(.invalidMessage) }
                if status.state == .completed {
                    guard let imported = status.importSummary, imported.valid,
                          imported.source.path.utf8.elementsEqual(descriptor.path.utf8),
                          imported.source.allowSQLChanges == allowSQLChanges else { throw BackendTransportError(.invalidMessage) }
                    if target { targetBundle = imported } else { sourceBundle = imported }
                    _ = try? await service.request("import.close", .init(jobId: started.jobId))
                    await service.shutdown(); return
                }
                if !status.state.isWorking {
                    let message = status.message ?? "The schema bundle could not be inspected."
                    if target { targetImportError = message } else { sourceImportError = message }
                    await service.shutdown(); return
                }
            }
        } catch is CancellationError {
            await service.shutdown()
        } catch {
            if inspections[target]?.token == token {
                let message = "The schema bundle could not be inspected. Check its manifest and SQL files, or choose Import Modified SQL for supported Git edits."
                if target { targetImportError = message } else { sourceImportError = message }
            }
            await service.shutdown()
        }
    }
    func cancelInspection(target: Bool) async {
        let inspection = inspections.removeValue(forKey: target)
        if target { inspectingTarget = false } else { inspectingSource = false }
        if let inspection {
            if let job = inspection.job { _ = try? await inspection.service.request("import.cancel", .init(jobId: job)) }
            await inspection.service.shutdown()
        }
    }

    private static func originMatches(_ origin: SchemaHistoricalOrigin?, _ bundle: SchemaImportedSource?) -> Bool {
        guard let bundle else { return origin == nil }
        return origin?.valid == true && origin?.manifestSha256 == bundle.source.manifestSha256 &&
            origin?.contentSha256 == bundle.source.contentSha256 && origin?.modifiedSQL == bundle.modifiedSQL &&
            origin?.manualObjects == bundle.manualObjects && origin?.label.utf8.elementsEqual(bundle.label.utf8) == true
    }
    func stop() async {
        guard isWorking else { return }
        dismissPlan(); generation = UUID(); poll?.cancel(); phase = .cancelled
        cancelReviews()
        if let backend { if let jobID { _ = try? await backend.request("cancel", .init(jobId: jobID)) }; await backend.shutdown() }
    }
    func close() async {
        dismissPlan(); generation = UUID(); pageGeneration = UUID(); valueGeneration = UUID(); clearDiff(); poll?.cancel(); phase = .closed
        cancelReviews(); isLoading = false
        await cancelInspection(target: false); await cancelInspection(target: true)
        if let backend { if let jobID { _ = try? await backend.request("close", .init(jobId: jobID)) }; await backend.shutdown() }
        backend = nil; page = nil; valueText = nil
    }
    private func cancelReviews() {
        SSHConnectionReview.cancel(ownerID: attempt)
        for profile in [sourceProfile, targetProfile].compactMap({ $0 }) {
            SSHConnectionReview.cancel(profileId: DataComparisonCredentials.promptID(profile.id, attempt))
        }
    }
    func reset() async { await close(); hasStarted = false; summary = nil; error = nil; offsets = [0]; exportComplete = false; sourceProfile = nil; targetProfile = nil; activeSourceBundle = nil; activeTargetBundle = nil }
    var canGeneratePlan: Bool { phase == .completed && current([sourceProfile, targetProfile].compactMap { $0 }) && summary != nil && !isGeneratingPlan && comparisonEngine.map { [.postgresql, .mysql, .sqlite].contains($0) } == true }
    func dismissPlan() { planGeneration = UUID(); planDraft?.invalidate(); planDraft = nil; isGeneratingPlan = false }
    func generatePlan() async {
        guard canGeneratePlan, let backend, let jobID, let summary else { return }
        dismissPlan(); isGeneratingPlan = true; error = nil
        let token = generation; let requestToken = planGeneration
        defer { if planGeneration == requestToken { isGeneratingPlan = false } }
        do {
            let reply = try await backend.request("plan", .init(jobId: jobID, modelDigest: summary.modelDigest))
            guard !Task.isCancelled, generation == token, planGeneration == requestToken, phase == .completed, current([sourceProfile, targetProfile].compactMap { $0 }) else { return }
            guard reply.jobId == jobID, reply.valid(for: "schema.plan.result"), let plan = reply.plan,
                  plan.modelDigest == summary.modelDigest, plan.engine == summary.engine else { throw BackendTransportError(.invalidMessage) }
            let sourceEndpoint: SynchronizationPlanEndpoint
            if let sourceProfile { sourceEndpoint = .init(profile: sourceProfile) }
            else if let activeSourceBundle, let endpoint = SynchronizationPlanEndpoint(bundle: activeSourceBundle) { sourceEndpoint = endpoint }
            else { throw BackendTransportError(.invalidMessage) }
            let targetEndpoint: SynchronizationPlanEndpoint
            if let targetProfile { targetEndpoint = .init(profile: targetProfile) }
            else if let activeTargetBundle, let endpoint = SynchronizationPlanEndpoint(bundle: activeTargetBundle) { targetEndpoint = endpoint }
            else { throw BackendTransportError(.invalidMessage) }
            planDraft = SynchronizationPlanDraft(plan: plan, source: sourceEndpoint, target: targetEndpoint, current: { [weak self] in
                guard let self else { return false }
                return self.generation == token && self.planGeneration == requestToken && self.phase == .completed &&
                    self.current([self.sourceProfile, self.targetProfile].compactMap { $0 })
            }, validateTarget: { [weak self] target in self?.validatePlanTarget(target) == true }, open: { [weak self] sql, target in
                guard let self, self.generation == token, self.planGeneration == requestToken, self.phase == .completed,
                      self.summary?.modelDigest == plan.modelDigest else { return false }
                return self.openPlan(sql, target)
            })
        } catch { if generation == token, planGeneration == requestToken { self.error = "The SQL plan could not be generated. A compatible helper and complete supported metadata are required." } }
    }
    func loadPage(collection: String, offset: Int64 = 0) async {
        guard phase == .completed, current([sourceProfile, targetProfile].compactMap { $0 }), let backend, let jobID else { return }
        let token = generation; pageGeneration = UUID(); let pageToken = pageGeneration
        isLoading = true; error = nil; clearDiff()
        defer { if pageGeneration == pageToken { isLoading = false } }
        do {
            let response = try await backend.request("page", .init(jobId: jobID, collection: collection, offset: offset))
            guard generation == token, pageGeneration == pageToken, current([sourceProfile, targetProfile].compactMap { $0 }) else { return }
            guard response.jobId == jobID, response.valid(for: "schema.page.result"), let result = response.page,
                  result.collection == collection, result.offset == offset else { throw BackendTransportError(.invalidMessage) }
            if page?.collection != collection { offsets = [0] }; page = result
        } catch { if generation == token, pageGeneration == pageToken { self.error = "The report page could not be read." } }
    }
    func nextPage() async { guard canNext, let page else { return }; offsets.append(page.nextOffset); await loadPage(collection: page.collection, offset: page.nextOffset) }
    func previousPage() async { guard canPrevious, let page else { return }; offsets.removeLast(); await loadPage(collection: page.collection, offset: offsets.last ?? 0) }
    private func clearValue() {
        valueGeneration = UUID(); selectedPreview = nil; valueText = nil; valueHasMore = false
        valueOffsets = [0]; valueOffset = 0; valueNextOffset = 0; valueTotalBytes = 0; valueBoundaryBytes = 0
    }
    private func clearDiff() {
        clearValue(); diffGeneration = UUID(); selectedDifference = nil; diff = nil; diffError = nil; isLoadingDiff = false
    }
    func inspectDifference(_ difference: SchemaDifference) async {
        guard phase == .completed, current([sourceProfile, targetProfile].compactMap { $0 }), let backend, let jobID, page?.differences.contains(difference) == true else { return }
        if selectedDifference != difference { clearValue() }
        diffGeneration = UUID(); let requestToken = diffGeneration; let token = generation
        selectedDifference = difference; diff = nil; diffError = nil; isLoadingDiff = true
        defer { if diffGeneration == requestToken { isLoadingDiff = false } }
        do {
            let response = try await backend.request("diff", .init(jobId: jobID, offset: difference.index))
            guard !Task.isCancelled, generation == token, diffGeneration == requestToken, current([sourceProfile, targetProfile].compactMap { $0 }) else { return }
            guard response.jobId == jobID, response.valid(for: "schema.diff.result"), response.offset == difference.index, let result = response.diff else { throw BackendTransportError(.invalidMessage) }
            diff = result
        } catch {
            if !Task.isCancelled, generation == token, diffGeneration == requestToken { diffError = "The difference could not be read." }
        }
    }
    func inspect(_ preview: SchemaValuePreview) async {
        selectedPreview = preview; valueOffsets = [0]
        await loadValue(preview, offset: 0)
    }
    func nextValue() async {
        guard valueHasMore, let selectedPreview else { return }
        let offset = max(valueOffset + 1, valueNextOffset - 3)
        valueOffsets.append(offset)
        await loadValue(selectedPreview, offset: offset)
    }
    func previousValue() async {
        guard valueOffsets.count > 1, let selectedPreview else { return }
        valueOffsets.removeLast()
        await loadValue(selectedPreview, offset: valueOffsets.last ?? 0)
    }
    var canPreviousValue: Bool { valueOffsets.count > 1 }
    private func loadValue(_ preview: SchemaValuePreview, offset: Int64) async {
        guard let backend, let jobID, phase == .completed else { return }
        valueGeneration = UUID(); let valueToken = valueGeneration; let token = generation
        do {
            let response = try await backend.request("value", .init(jobId: jobID, offset: offset, maxBytes: 65_536, valueRef: preview.valueRef))
            guard generation == token, valueGeneration == valueToken, current([sourceProfile, targetProfile].compactMap { $0 }) else { return }
            guard response.jobId == jobID, response.valid(for: "schema.value.result"), let chunk = response.value,
                  chunk.offset == offset, chunk.valueRef == preview.valueRef, chunk.totalBytes == preview.totalBytes,
                  let data = chunk.data, data.count <= 65_536 else { throw BackendTransportError(.invalidMessage) }
            let window = ResultComparisonModel.textWindow(data)
            guard let window else { throw BackendTransportError(.invalidMessage) }
            valueText = window.text; valueHasMore = chunk.hasMore
            valueOffset = offset; valueNextOffset = chunk.nextOffset; valueTotalBytes = chunk.totalBytes
            valueBoundaryBytes = window.leadingBytes + window.trailingBytes
        } catch { if generation == token, valueGeneration == valueToken { self.error = "The property value could not be read." } }
    }
    func export(to destination: URL) async {
        guard let backend, let jobID, phase == .completed, current([sourceProfile, targetProfile].compactMap { $0 }), !isExporting else { return }
        isExporting = true; exportComplete = false; error = nil
        let token = generation; defer { isExporting = false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".dbeer-schema-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let maximumBytes = 192 * 1_024 * 1_024
            let parent = try SQLFileBinding.parentIdentity(of: destination)
            let reviewed = try SQLFileBinding.reviewedVersion(at: destination, maximumBytes: maximumBytes)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
            var offset: Int64 = 0; var total: Int64?; var digest: String?; var hash = SHA256()
            repeat {
                try Task.checkCancellation()
                let response = try await backend.request("export", .init(jobId: jobID, offset: offset))
                try requireCurrent(token)
                guard response.jobId == jobID, response.valid(for: "schema.export.result"), let chunk = response.export,
                      chunk.offset == offset, chunk.totalBytes == (total ?? chunk.totalBytes), chunk.sha256 == (digest ?? chunk.sha256),
                      let data = chunk.data else { throw BackendTransportError(.invalidMessage) }
                total = chunk.totalBytes; digest = chunk.sha256; offset = chunk.nextOffset
                try handle.write(contentsOf: data); hash.update(data: data)
                if !chunk.hasMore { break }
            } while true
            guard let digest, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw BackendTransportError(.invalidMessage) }
            try handle.synchronize(); try handle.close()
            try requireCurrent(token)
            try SQLFileBinding.publishPreparedFile(temporary, to: destination, expectedVersion: reviewed, expectedParent: parent,
                                                   expectedSHA256: digest, maximumBytes: maximumBytes)
            exportComplete = true
        } catch is CancellationError { return }
        catch let failure as SQLFileBindingError {
            if generation == token { self.error = failure.errorDescription }
        }
        catch { if generation == token { self.error = "The report could not be exported. The destination was left unchanged." } }
    }
}

@MainActor
enum SchemaComparisonCredentials {
    static func settings(_ profile: SavedConnection, store: any ConnectionCredentialStore) async throws -> ConnectionSettings {
        let secret = profile.engine != .sqlite && profile.passwordCommand == nil ? try await store.password(for: profile.id) ?? "" : ""
        var settings = profile.settings(password: secret)
        if var ssh = settings.ssh {
            if ssh.authMethod == .password {
                ssh.password = try await store.secret(for: profile.id, purpose: .sshPassword)
                if ssh.password == nil { ssh.password = try await SSHConnectionReview.requestSecret(passphrase: false, profileId: profile.id.uuidString, configuration: ssh.configuration) }
            } else if ssh.authMethod == .privateKey {
                ssh.passphrase = try await store.secret(for: profile.id, purpose: .sshPassphrase)
                if ssh.passphrase == nil { ssh.passphrase = try await SSHConnectionReview.requestSecret(passphrase: true, profileId: profile.id.uuidString, configuration: ssh.configuration) }
            }
            settings.ssh = ssh
        }
        return settings
    }
}
