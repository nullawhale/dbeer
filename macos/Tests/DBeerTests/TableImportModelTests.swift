import Foundation
import Testing
@testable import DBeer

/// Closure-backed protocol fixtures only. No windows, file panels, database
/// connections, application activation or SQL/value logs.
@MainActor
private final class ImportModelBackend {
    var calls: [String] = []
    var current = true
    var allowed = true
    var readonly = false
    var confirm = true
    var changedCount = 0
    var authorizationCount = 0
    var applyCount = 0
    var unknownApply = false
    var cancelledApply = false
    var failingRow: Int?
    var sessionKnownClosed = false
    var disconnectFails = false
    var remoteConnectionLost = false
    var pausePreview = false
    var pauseApply = false
    var pauseAuthorization = false
    var previewGate: CheckedContinuation<Void, Never>?
    var applyGate: CheckedContinuation<Void, Never>?
    var authorizationGate: CheckedContinuation<Void, Never>?
    var previewRequest: TableImportRequest?
    var applyRequest: TableImportRequest?
    var columns: [TableImportColumn] = [
        .init(name: "id", nativeType: "bigint", nullable: false, hasDefault: true, generated: false, binary: false),
        .init(name: "label", nativeType: "text", nullable: true, hasDefault: false, generated: false, binary: false),
        .init(name: "payload", nativeType: "bytea", nullable: true, hasDefault: false, generated: false, binary: true),
        .init(name: "computed", nativeType: "integer", nullable: true, hasDefault: false, generated: true, binary: false)
    ]
    let fingerprint = String(repeating: "a", count: 64)

    func model() -> TableImportModel {
        TableImportModel(profile: SavedConnection(name: "Fixture", settings: .init(
            host: "fixture.invalid", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable",
            policy: .init(environment: .development, readOnly: readonly))),
            schema: "public", table: "samples",
            connect: { self.calls.append("connect"); return "import-session" },
            send: request,
            authorize: { request, _, _ in
                self.authorizationCount += 1
                if self.pauseAuthorization { await withCheckedContinuation { self.authorizationGate = $0 } }
                return self.confirm ? "reviewed-import" : nil
            },
            bindingIsCurrent: { self.current }, operationsAllowed: { self.allowed },
            sessionIsKnownClosed: { self.sessionKnownClosed },
            changed: { self.changedCount += 1 })
    }

    func request(_ command: BackendCommand) async throws -> BackendMessage {
        calls.append(command.type)
        if command.type == "disconnect" {
            if disconnectFails { throw BackendTransportError(.notReady) }
            return BackendMessage(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        }
        if command.type == "cancel" {
            return BackendMessage(type: "cancel.ack", requestId: command.requestId, sessionId: command.sessionId,
                queryId: command.queryId, status: "accepted")
        }
        let request = command.tableImport!
        var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId,
            sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle)
        switch command.type {
        case "import.describe":
            reply.tableImport = .init(columns: columns, fingerprint: fingerprint)
        case "import.preview":
            previewRequest = request
            if pausePreview { await withCheckedContinuation { previewGate = $0 } }
            reply.tableImport = .init(fingerprint: fingerprint, rowCount: request.rows?.count, sql: "synthetic bound INSERT template")
        case "import.apply":
            applyCount += 1
            applyRequest = request
            #expect(command.authorization == "reviewed-import")
            if pauseApply { await withCheckedContinuation { applyGate = $0 } }
            if unknownApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
            if cancelledApply || failingRow != nil || remoteConnectionLost {
                var failure = BackendMessage(type: "error", requestId: command.requestId,
                    sessionId: command.sessionId, queryId: command.queryId, transactionStatus: .idle)
                failure.category = cancelledApply ? "cancelled" : "sql"
                failure.message = cancelledApply ? "The import was cancelled." : "The import was rolled back."
                failure.connected = !remoteConnectionLost
                failure.outcomeUnknown = remoteConnectionLost
                if let failingRow { failure.tableImport = .init(row: failingRow) }
                throw BackendRemoteError(reply: failure)
            }
            reply.tableImport = .init(rowCount: request.rows?.count)
        default:
            throw BackendRequestError.invalidCommand
        }
        return reply
    }

    func releasePreview() { previewGate?.resume(); previewGate = nil }
    func releaseApply() { applyGate?.resume(); applyGate = nil }
    func releaseAuthorization() { authorizationGate?.resume(); authorizationGate = nil }
}

@Suite(.serialized)
@MainActor
struct TableImportModelTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func loaded(_ backend: ImportModelBackend, csv: String = "label\nsample\n") async -> TableImportModel {
        let model = backend.model()
        await model.load()
        await model.loadFile(data: Data(csv.utf8), name: "fixture.csv")
        return model
    }

    @Test func constructingAndParsingOnlyKeepTheDraftLocalUntilExplicitMetadataLoad() async {
        let backend = ImportModelBackend()
        let model = backend.model()
        await model.loadFile(data: Data("label\nsample\n".utf8), name: "fixture.csv")
        #expect(backend.calls.isEmpty && model.parsed?.rows.count == 1)
        #expect(!model.canPreview && model.hasDraft)
        await model.load()
        #expect(backend.calls == ["connect", "import.describe"] && model.mapping == ["label"])
        #expect(model.canPreview && model.preview == nil && !model.canApply)
        #expect(await model.close())
    }

    @Test func automaticMappingUsesOnlyExactUniqueNamesAndRejectsDuplicateTargets() async {
        let backend = ImportModelBackend()
        let model = await loaded(backend, csv: "Label,label,label,payload,computed,missing\nx,y,z,AQI=,7,q\n")
        #expect(model.mapping == [nil, nil, nil, "payload", nil, nil])
        model.setMapping(source: 1, target: "label")
        model.setMapping(source: 2, target: "label")
        #expect(!model.canPreview && model.validationMessage != nil)
        model.setMapping(source: 2, target: nil)
        #expect(model.canPreview)
        model.setMapping(source: 4, target: "computed")
        #expect(!model.canPreview && model.validationMessage != nil)
        #expect(await model.close())
    }

    @Test func canonicalUnicodeEquivalenceDoesNotCreateAnAutomaticHeaderMatch() async {
        let backend = ImportModelBackend()
        backend.columns = [.init(name: "e\u{301}", nativeType: "text", nullable: true, hasDefault: false, generated: false, binary: false)]
        let model = await loaded(backend, csv: "\u{e9}\nvalue\n")
        #expect(model.mapping == [nil] && !model.canPreview)
        model.setMapping(source: 0, target: backend.columns[0].name)
        #expect(model.canPreview)
        #expect(await model.close())
    }

    @Test func nullEmptyTextAndBinaryValuesReachOnlyTheReviewedRequest() async throws {
        let backend = ImportModelBackend()
        let model = await loaded(backend, csv: "label,payload\r\nfirst,AQI=\r\n\\N,\\N\r\n\"\",\"\"\r\n")
        #expect(model.canPreview && model.unmappedColumns.contains { $0.name == "id" && $0.hasDefault })
        await model.preparePreview()
        let request = try #require(backend.previewRequest)
        #expect(request.columns == ["label", "payload"])
        #expect(request.rows == [
            [.init(kind: "text", value: "first"), .init(kind: "binary", value: "AQI=")],
            [.null, .null],
            [.init(kind: "text", value: ""), .init(kind: "binary", value: "")]
        ])
        #expect(model.canApply && backend.applyCount == 0 && backend.authorizationCount == 0)
        #expect(model.preview?.sql == "synthetic bound INSERT template")
        model.setMapping(source: 0, target: nil)
        model.setMapping(source: 0, target: "label")
        #expect(model.preview == nil && !model.canApply)
        #expect(await model.close())
    }

    @Test func mappingRequiredColumnsAndOptionEditsRequireAFreshPreview() async throws {
        let backend = ImportModelBackend()
        backend.columns[0].hasDefault = false
        let model = await loaded(backend, csv: "id,label\n1,\n")
        model.setMapping(source: 0, target: nil)
        #expect(!model.canPreview && model.requiredUnmappedColumns.map(\.name) == ["id"])
        model.setMapping(source: 0, target: "id")
        await model.preparePreview()
        #expect(model.canApply)
        var options = model.options
        options.emptyFieldsAreNull = true
        model.options = options
        #expect(model.preview == nil && !model.canApply)
        try await eventually { !model.isParsing }
        await model.preparePreview()
        #expect(backend.previewRequest?.rows?.first?[1] == .null)
        #expect(model.canApply && backend.applyCount == 0)
        #expect(await model.close())
    }

    @Test func optionChangesDuringPreviewCannotInstallAStaleReview() async throws {
        let backend = ImportModelBackend()
        let model = await loaded(backend, csv: "label\n\u{e9}\n")
        backend.pausePreview = true
        let preparing = Task { await model.preparePreview() }
        defer { backend.releasePreview() }
        try await eventually { backend.previewGate != nil }
        var options = model.options
        options.nullMarker = "\u{e9}"
        model.options = options
        try await eventually { !model.isParsing }
        backend.releasePreview()
        await preparing.value
        #expect(model.preview == nil && !model.canApply && backend.applyCount == 0)
        #expect(model.error != nil)
        #expect(await model.close())
    }

    @Test func optionEditingRemainsAvailableWhileOnlyTheLatestParseCanInstall() async throws {
        let backend = ImportModelBackend()
        let model = await loaded(backend, csv: "label\nNA\n")
        var options = model.options
        options.nullMarker = "NA"
        model.options = options
        #expect(model.isParsing && model.canEditOptions && !model.canEdit)
        options.nullMarker = "NOT-NULL"
        model.options = options
        try await eventually { !model.isParsing }
        #expect(model.previewValue(row: 0, source: 0) == .init(kind: "text", value: "NA"))
        await model.preparePreview()
        #expect(backend.previewRequest?.rows?.first?.first == .init(kind: "text", value: "NA"))
        #expect(await model.close())
    }

    @Test func editedMappingOrConnectionDuringAuthorizationNeverSendsRows() async throws {
        for changeBinding in [false, true] {
            let backend = ImportModelBackend()
            let model = await loaded(backend)
            await model.preparePreview()
            backend.pauseAuthorization = true
            let applying = Task { await model.apply() }
            try await eventually { backend.authorizationGate != nil }
            if changeBinding { backend.current = false }
            else { model.setMapping(source: 0, target: nil) }
            backend.releaseAuthorization()
            await applying.value
            #expect(backend.applyCount == 0 && model.appliedRowCount == nil && !model.canApply)
            #expect(await model.close())
        }
    }

    @Test func oneSuccessfulApplyRetainsTerminalEvidenceAndBlocksAnotherBatch() async throws {
        let backend = ImportModelBackend()
        let model = await loaded(backend)
        await model.preparePreview()
        backend.pauseApply = true
        let applying = Task { await model.apply() }
        defer { backend.releaseApply() }
        try await eventually { backend.applyGate != nil }
        backend.current = false
        backend.releaseApply()
        await applying.value
        #expect(model.appliedRowCount == 1 && backend.changedCount == 1 && backend.applyCount == 1)
        #expect(model.invalidated && !model.canApply && !model.canPreview)
        await model.apply()
        await model.loadFile(data: Data("label\nanother\n".utf8), name: "another.csv")
        #expect(backend.applyCount == 1 && model.fileName == "fixture.csv")
        #expect(await model.close())
    }

    @Test func cancellationWaitsForTheTerminalAndInvalidatesTheReviewedRequest() async throws {
        let backend = ImportModelBackend()
        let model = await loaded(backend)
        await model.preparePreview()
        backend.pauseApply = true; backend.cancelledApply = true
        let applying = Task { await model.apply() }
        defer { backend.releaseApply() }
        try await eventually { backend.applyGate != nil }
        await model.stop()
        #expect(model.isBusy && model.isApplying && backend.calls.contains("cancel"))
        #expect(await model.close() == false)
        #expect(!backend.calls.contains("disconnect"))
        backend.releaseApply()
        await applying.value
        #expect(!model.isBusy && model.preview == nil && !model.canApply && !model.outcomeUnknown)
        await model.apply()
        #expect(backend.applyCount == 1)
        #expect(await model.close())
    }

    @Test func unknownCommitCannotBeRetriedOrReplacedWithAnotherFile() async {
        let backend = ImportModelBackend()
        let model = await loaded(backend)
        await model.preparePreview()
        backend.unknownApply = true
        await model.apply()
        #expect(model.outcomeUnknown && !model.canApply && !model.canPreview && backend.changedCount == 1)
        await model.apply()
        await model.load()
        await model.loadFile(data: Data("label\nanother\n".utf8), name: "another.csv")
        #expect(backend.applyCount == 1 && model.fileName == "fixture.csv")
        #expect(await model.close())
        #expect(model.outcomeUnknown)
    }

    @Test func aDeadHelperCanCloseAfterUnknownOutcomeWithoutRetainingFileValues() async {
        let backend = ImportModelBackend()
        let model = await loaded(backend)
        await model.preparePreview()
        backend.unknownApply = true
        await model.apply()
        backend.disconnectFails = true
        #expect(await model.close() == false)
        backend.sessionKnownClosed = true
        #expect(await model.close())
        #expect(model.outcomeUnknown && model.parsed == nil && model.fileName == nil && !model.hasDraft)
    }

    @Test func acknowledgedClosedConnectionDoesNotRequireAnotherDisconnect() async {
        let backend = ImportModelBackend()
        let model = await loaded(backend)
        await model.preparePreview()
        backend.remoteConnectionLost = true
        await model.apply()
        #expect(model.outcomeUnknown)
        #expect(await model.close())
        #expect(!backend.calls.contains("disconnect") && model.parsed == nil)
    }

    @Test func readonlyProfilesCanPreviewButCannotAuthorizeOrApply() async {
        let backend = ImportModelBackend()
        backend.readonly = true
        let model = await loaded(backend)
        #expect(model.canPreview)
        await model.preparePreview()
        #expect(model.preview != nil && !model.canApply)
        await model.apply()
        #expect(backend.authorizationCount == 0 && backend.applyCount == 0)
        #expect(await model.close())
    }

    @Test func aServerDataRowDiagnosticUsesTheFilesPhysicalLine() async {
        let backend = ImportModelBackend()
        let model = await loaded(backend, csv: "label\n\"first\ncontinued\"\nsecond\n")
        await model.preparePreview()
        backend.failingRow = 2
        await model.apply()
        #expect(model.error?.contains("Data row 2 (file line 4)") == true)
        #expect(!model.outcomeUnknown && !model.canApply && backend.changedCount == 0)
        #expect(await model.close())
    }
}
