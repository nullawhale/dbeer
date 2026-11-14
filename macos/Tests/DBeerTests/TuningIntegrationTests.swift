import Foundation
import Testing
@testable import DBeer

/// The normal bundled helper and native stdout decoder, with only runner-owned
/// disposable PG/MySQL endpoints. No workspace, saved profiles, stores, SSH,
/// Keychain, NSApp, windows, activation or default decision presenter is used.
@Suite(.serialized)
@MainActor
struct TuningIntegrationTests {
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty))
    func postgresActualWireAdviceValidationAndExplicitTransactionSettings() async throws { try await exercise(.postgresql) }
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
    func mysqlActualWireAdviceValidationAndNoAdviceArrays() async throws { try await exercise(.mysql) }

    private final class Reviews {
        var operations: [String] = []
        func accept(_ operation: OperationRequest, _ assessment: OperationAssessment) -> Bool {
            guard assessment.valid, assessment.decision != "deny", assessment.operations.count == 1 else { return false }
            if operation.type == "tuning.validate" || operation.type == "tuning.setting" {
                #expect(assessment.decision == "confirm")
                operations.append(operation.type)
            }
            return true
        }
    }
    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            return .init(host: env["DBEER_TEST_MYSQL_HOST"] ?? "localhost",
                port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")), database: env["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer",
                user: env["DBEER_TEST_MYSQL_USER"] ?? "dbeer", password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "",
                sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable", sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        }
        let url = try #require(URLComponents(string: env["DBEER_TEST_DSN"] ?? ""))
        return .init(host: try #require(url.host), port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: try #require(url.user), password: url.password ?? "", sslMode: "disable")
    }
    private func grant(_ client: BackendClient, session: String, operation: OperationRequest, reviews: Reviews,
                       expected: String? = nil) async throws -> String {
        let reply = try await client.request(.assess(sessionId: session, operations: [operation]))
        try reply.validate()
        let assessment = try #require(reply.assessment)
        if let expected { #expect(assessment.decision == expected) }
        try #require(reviews.accept(operation, assessment))
        #expect(reply.sessionId == session && reply.queryId != nil)
        return try #require(assessment.authorization)
    }
    private func execute(_ client: BackendClient, session: String, sql: String, reviews: Reviews) async throws -> BackendMessage {
        let authorization = try await grant(client, session: session, operation: .init(type: "execute", sql: sql), reviews: reviews)
        var command = BackendCommand.execute(sessionId: session, sql: sql); command.authorization = authorization
        let reply = try await client.request(command)
        try reply.validate()
        try #require(reply.type == "query.result" && reply.outcomeUnknown != true && reply.sessionId == session)
        return reply
    }
    private func validate(_ client: BackendClient, session: String, request: TuningValidationRequest,
                          reviews: Reviews) async throws -> BackendMessage {
        let before = reviews.operations.count
        let authorization = try await grant(client, session: session, operation: .init(type: "tuning.validate", tuningValidation: request), reviews: reviews, expected: "confirm")
        var command = BackendCommand.tuningValidate(sessionId: session, request: request); command.authorization = authorization
        let reply = try await client.request(command)
        #expect(reviews.operations.count == before + 1 && reply.type == "tuning.validate.result")
        return reply
    }
    private func applySetting(_ client: BackendClient, session: String, request: TuningSettingRequest,
                              reviews: Reviews) async throws -> TuningSettingResult {
        let before = reviews.operations.count
        let authorization = try await grant(client, session: session, operation: .init(type: "tuning.setting", tuningSetting: request), reviews: reviews, expected: "confirm")
        var command = BackendCommand.tuningSet(sessionId: session, request: request); command.authorization = authorization
        let reply = try await client.request(command)
        #expect(reviews.operations.count == before + 1 && reply.transactionStatus == .transaction)
        return try #require(reply.tuningSetting)
    }
    private func exercise(_ engine: DatabaseEngine) async throws {
        let configuration = try settings(engine), reviews = Reviews()
        let repository = TuningNativeFixture.root
        let executable = ProcessInfo.processInfo.environment["DBEER_TEST_HELPER"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let client = BackendClient(executableURL: executable)
        let table = "f7_native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let schema = engine == .postgresql ? "public" : configuration.database
        try #require(schema.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil)
        let qualified = schema + "." + table
        try await client.start()
        var owner: String?
        do {
            let connected = try await client.request(.connect(configuration))
            let session = try #require(connected.sessionId); owner = session
            let support = try #require(connected.explainSupport)
            #expect(await client.supportsTuning())
            #expect(connected.capabilities?.contains(TuningInspectRequest.capability) == true)
            #expect(TuningTransportAdmission.validOwner(support: support, engine: engine,
                capabilities: Set(connected.capabilities ?? []), helperSupports: await client.supportsTuning()))
            let other = try #require(await client.request(.connect(configuration)).sessionId)
            let binaryType = engine == .postgresql ? "bytea" : "blob"
            let binaryValue = engine == .postgresql ? "decode('0001ff','hex')" : "X'0001ff'"
            _ = try await execute(client, session: session, sql: "CREATE TABLE " + qualified + " (id bigint, note text, amount numeric(30,3), payload " + binaryType + ")", reviews: reviews)
            _ = try await execute(client, session: session, sql: "INSERT INTO " + qualified + " VALUES (1,NULL,9007199254740993.125," + binaryValue + "),(1,'',9007199254740993.125," + binaryValue + "),(2,'NULL',0.000," + binaryValue + ")", reviews: reviews)
            if engine == .postgresql { _ = try await execute(client, session: session, sql: "SET search_path = pg_catalog, public", reviews: reviews) }
            let sql = "SELECT id, note, amount, payload FROM " + qualified + " WHERE id = :first OR id = :second"
            let context = ExplainContext(documentId: "native-source", targetDocumentId: "native-source", rangeLocation: 0,
                rangeLength: sql.utf16.count, profileId: "native-fixture-profile", sessionId: session, transactionStatus: "idle")
            let source = ExplainRequest(sql: sql, mode: .plan,
                parameters: [.init(name: "first", type: .integer, value: "1"), .init(name: "second", type: .integer, value: "2")],
                context: context, options: engine == .mysql ? .init(mysql: .init(format: .json)) : nil)
            let estimateGrant = try await grant(client, session: session, operation: .init(type: "explain.run", explain: source), reviews: reviews, expected: "allow")
            var explain = BackendCommand.explain(sessionId: session, request: source); explain.authorization = estimateGrant
            let planReply = try await client.request(explain)
            let capture = try #require(planReply.explain)
            #expect(capture.valid && capture.complete && capture.status == "tree" && capture.support == support)
            let inspectionRequest = TuningInspectRequest(version: 1, source: source, capture: capture, target: .init(schema: schema, table: table, create: false))
            let inspected = try await client.request(.tuningInspect(sessionId: session, request: inspectionRequest))
            let inspection = try #require(inspected.tuningInspection)
            #expect(inspection.valid && inspection.indexes.count == 1 && inspection.variants.count == 1)
            let candidate = try #require(inspection.variants.first)
            #expect(candidate.validation == "unvalidated" && candidate.request.parameters == source.parameters)
            var comparison = TuningValidationRequest(version: 1, original: source, variant: candidate.request,
                target: inspectionRequest.target, metadataFingerprint: inspection.metadataFingerprint,
                maxRows: 100, maxBytes: 65_536, timeoutMs: 5_000, comparison: "multiset")
            let equal = try #require(await validate(client, session: session, request: comparison, reviews: reviews).tuningValidation)
            #expect(equal.state == "observedEqual" && equal.complete && equal.originalRows == 3 && equal.variantRows == 3)
            comparison.maxRows = 1
            let bounded = try #require(await validate(client, session: session, request: comparison, reviews: reviews).tuningValidation)
            #expect(bounded.state == "inconclusive" && !bounded.complete)
            comparison.maxRows = 100
            // Another ordinary physical owner does not consume this owner's exact reviewed grant.
            let independentGrant = try await grant(client, session: session, operation: .init(type: "tuning.validate", tuningValidation: comparison), reviews: reviews, expected: "confirm")
            _ = try await execute(client, session: other, sql: "SELECT 1", reviews: reviews)
            var independent = BackendCommand.tuningValidate(sessionId: session, request: comparison); independent.authorization = independentGrant
            #expect(try await client.request(independent).tuningValidation?.state == "observedEqual")
            let staleGrant = try await grant(client, session: session, operation: .init(type: "tuning.validate", tuningValidation: comparison), reviews: reviews, expected: "confirm")
            _ = try await client.request(.tuningInspect(sessionId: session, request: inspectionRequest))
            var stale = BackendCommand.tuningValidate(sessionId: session, request: comparison); stale.authorization = staleGrant
            do { _ = try await client.request(stale); Issue.record("Same-owner inspection failed to retire a validation grant") }
            catch let error as BackendRequestError { #expect(error == .invalidCommand) }
            // Explicit fixture DDL, separately assessed; inspection never applies advice.
            _ = try await execute(client, session: session, sql: "CREATE INDEX " + table + "_id ON " + qualified + " (id)", reviews: reviews)
            let noIndexAdvice = try #require(await client.request(.tuningInspect(sessionId: session, request: inspectionRequest)).tuningInspection)
            #expect(noIndexAdvice.indexes.isEmpty)
            var equality = source
            equality.sql = "SELECT id, note, amount, payload FROM " + qualified + " WHERE id = :first"
            equality.parameters = [try #require(source.parameters?.first)]
            equality.context?.documentId = "native-equality-source"
            equality.context?.rangeLength = equality.sql.utf16.count
            let equalityGrant = try await grant(client, session: session, operation: .init(type: "explain.run", explain: equality), reviews: reviews, expected: "allow")
            var equalityCommand = BackendCommand.explain(sessionId: session, request: equality); equalityCommand.authorization = equalityGrant
            let equalityCapture = try #require(await client.request(equalityCommand).explain)
            let emptyRequest = TuningInspectRequest(version: 1, source: equality, capture: equalityCapture, target: inspectionRequest.target)
            let noAdvice = try #require(await client.request(.tuningInspect(sessionId: session, request: emptyRequest)).tuningInspection)
            #expect(noAdvice.indexes.isEmpty && noAdvice.variants.isEmpty)
            comparison.metadataFingerprint = noAdvice.metadataFingerprint
            #expect(try await validate(client, session: session, request: comparison, reviews: reviews).tuningValidation?.state == "observedEqual")
            var dedicated = configuration; dedicated.sessionPurpose = "structure"
            let structure = try await client.request(.connect(dedicated))
            let structureOwner = try #require(structure.sessionId)
            #expect(structure.capabilities?.contains(TuningInspectRequest.capability) != true)
            var foreign = inspectionRequest; foreign.source.context?.sessionId = structureOwner
            do { _ = try await client.request(.tuningInspect(sessionId: structureOwner, request: foreign)); Issue.record("Dedicated structure owner admitted tuning") }
            catch let error as BackendRequestError { #expect(error == .invalidCommand) }
            _ = try await client.request(.disconnect(sessionId: structureOwner))
            if engine == .postgresql {
                let begun = try await execute(client, session: session, sql: "BEGIN", reviews: reviews)
                #expect(begun.transactionStatus == .transaction)
                var transactionContext = context; transactionContext.transactionStatus = "transaction"
                let observe = TuningSettingObservationRequest(version: 1, context: transactionContext, name: "work_mem")
                let before = try #require(await client.request(.tuningObserveSetting(sessionId: session, request: observe)).tuningSettingObservation)
                let desired = before.workMemKiB <= 1_048_512 ? before.workMemKiB + 64 : before.workMemKiB - 64
                let setting = TuningSettingRequest(version: 1, context: transactionContext, name: "work_mem", expectedValueKiB: before.workMemKiB, valueKiB: desired)
                let applied = try await applySetting(client, session: session, request: setting, reviews: reviews)
                #expect(applied.beforeKiB == before.workMemKiB && applied.requestedKiB == desired)
                let observed = try #require(await client.request(.tuningObserveSetting(sessionId: session, request: observe)).tuningSettingObservation)
                #expect(observed.workMemKiB == desired)
                let restored = try await applySetting(client, session: session, request: applied.restore, reviews: reviews)
                #expect(restored.requestedKiB == before.workMemKiB && reviews.operations.filter { $0 == "tuning.setting" }.count == 2)
                #expect(try await client.request(.tuningObserveSetting(sessionId: session, request: observe)).tuningSettingObservation?.workMemKiB == before.workMemKiB)
                let rolledBack = try await execute(client, session: session, sql: "ROLLBACK", reviews: reviews)
                #expect(rolledBack.transactionStatus == .idle)
                do { _ = try await client.request(.tuningObserveSetting(sessionId: session, request: observe)); Issue.record("Expired transaction context admitted setting observation") }
                catch let error as BackendRequestError { #expect(error == .invalidCommand) }
            }
            _ = try await execute(client, session: session, sql: "DROP TABLE " + qualified, reviews: reviews)
            _ = try await client.request(.disconnect(sessionId: other))
            _ = try await client.request(.disconnect(sessionId: session))
        } catch {
            if let owner {
                _ = try? await execute(client, session: owner, sql: "ROLLBACK", reviews: reviews)
                _ = try? await execute(client, session: owner, sql: "DROP TABLE IF EXISTS " + qualified, reviews: reviews)
            }
            _ = await client.shutdown(); throw error
        }
        #expect(await client.shutdown().acknowledged)
    }
}
