import Foundation
import Testing
@testable import DBeer

/// Pure values and a synthetic stdio peer. No app, UI, databases or credentials.
struct ExplainDMLNativeTests {
    private var support: ExplainSupport {
        .init(engine: .postgresql, serverVersion: "17.6", format: "json", modes: [.plan, .analyze],
            dml: .init(analyze: ["insert", "update", "delete", "dataModifyingCTE"], analyzeTargetExecution: "executes"))
    }
    private func request(_ sql: String = "UPDATE fixture SET value = :p", transaction: String = "idle") -> ExplainRequest {
        .init(sql: sql, mode: .analyze, parameters: [.init(name: "p", type: .decimal, value: "9007199254740993.1200")],
            context: .init(documentId: "source", targetDocumentId: "target", rangeLocation: 42,
                rangeLength: sql.utf16.count, profileId: "profile", sessionId: "owner", transactionStatus: transaction),
            writeIntent: .init(expectedTransactionStatus: transaction))
    }

    @Test func batchTreatsDMLAsPlanCandidatesAndKeepsOriginalSelections() throws {
        let text = "BEGIN; INSERT INTO fixture VALUES ('🍺'); UPDATE fixture SET value = 2; DELETE FROM fixture; WITH changed AS (DELETE FROM fixture RETURNING *) SELECT * FROM changed; COMMIT"
        let parsed = SQLScriptParser.parse(text, engine: .postgresql).statements
        let values = try ExplainBatchStatement.candidates(text: text, selections: [parsed[4].range, parsed[1].range], engine: .postgresql)
        #expect(values.map(\.action) == [.execute, .plan, .plan, .plan, .plan, .execute])
        #expect(values.filter(\.selectedByDefault).map(\.range) == [parsed[1].range, parsed[4].range])
        #expect(values.allSatisfy { $0.matches(text) })
        #expect(ExplainDMLAdmission.possibleDML(parsed[4].sql, engine: .postgresql))
        #expect(!ExplainDMLAdmission.possibleDML("SELECT 'UPDATE fixture'", engine: .postgresql))
        #expect(!ExplainDMLAdmission.possibleDML("DELETE FROM fixture", engine: .cassandra))
    }

    @Test func authoritativeFormsRespectEngineSupport() {
        let mysql = ExplainSupport(engine: .mysql, serverVersion: "8.0.18", format: "tree", modes: [.plan, .analyze],
            dml: .init(analyze: ["mysqlMultiTableUpdate", "mysqlMultiTableDelete"], analyzeTargetExecution: "suppresses"))
        #expect(ExplainDMLAdmission.accepts(.init(statement: "insert"), support: mysql, mode: .plan))
        #expect(!ExplainDMLAdmission.accepts(.init(statement: "insert"), support: mysql, mode: .analyze))
        #expect(!ExplainDMLAdmission.accepts(.init(statement: "update"), support: mysql, mode: .analyze))
        #expect(ExplainDMLAdmission.accepts(.init(statement: "update", mysqlMultiTable: true), support: mysql, mode: .analyze))
        let sqlite = ExplainSupport(engine: .sqlite, serverVersion: "3.46", format: "queryPlan", modes: [.plan], dml: .init(analyze: [], analyzeTargetExecution: "unavailable"))
        #expect(ExplainDMLAdmission.accepts(.init(statement: "delete"), support: sqlite, mode: .plan))
        #expect(!ExplainDMLAdmission.accepts(.init(statement: "delete"), support: sqlite, mode: .analyze))
        #expect(!ExplainDMLAdmission.accepts(.init(statement: "select", dataModifyingCTE: true), support: sqlite, mode: .plan))
    }

    @Test func exactIntentBindsBytesValuesOptionsRangeAndTransaction() {
        let original = request("UPDATE fixture SET value = 'é'")
        var changed = original
        changed.sql = "UPDATE fixture SET value = 'e\u{0301}'"
        changed.context?.rangeLength = changed.sql.utf16.count
        #expect(original.exactBindingData != changed.exactBindingData)
        changed = original; changed.parameters?[0].value = "9007199254740993.12"
        #expect(original.exactBindingData != changed.exactBindingData)
        changed = original; changed.options = .init(postgresql: .init(timing: false))
        #expect(original.exactBindingData != changed.exactBindingData)
        changed = original; changed.context?.rangeLocation += 1
        #expect(original.exactBindingData != changed.exactBindingData)
        changed = original; changed.writeIntent?.expectedTransactionStatus = "transaction"
        #expect(!changed.valid && original.exactBindingData != changed.exactBindingData)
        #expect(original.portable.context == nil && original.portable.writeIntent == nil)
    }

    @Test func artifactsVersionSixRetainsFactsAndRejectsNewFieldsUnderEveryOldHeader() throws {
        let captured = request()
        let facts = ExplainDMLResult(target: .init(statement: "update"), execution: "completed", persistence: "transactionPending",
            transactionBefore: "idle", transactionAfter: "transaction", affectedRowsUnavailableReason: "notReported", targetExecution: "executed")
        let result = ExplainResult(support: support, mode: .analyze, status: "rawOnly", raw: "synthetic native plan",
            complete: true, diagnostic: "Synthetic capture", roots: [], nodes: [], metrics: [:], dml: facts)
        var plan = ExplainPlanModel(request: captured, sourceText: captured.sql, sourceRange: NSRange(location: 42, length: captured.sql.utf16.count), profileID: UUID())
        plan.result = result
        let artifact = try PlanArtifact.capture(plan, title: "Recorded DML effects")
        let text = try artifact.encoded()
        let restored = try PlanArtifact.decode(text)
        #expect(restored.version == 6 && restored.result.dml == facts)
        #expect(restored.request.writeIntent == nil && restored.request.context == nil && restored.displayPlan.sessionID == nil)
        #expect(restored.request.parameters == captured.parameters && restored.displayPlan.dmlOutcome == facts)
        #expect(restored.displayPlan.dmlOutcome?.persistenceLabel ==
            "At acknowledgement, target changes were uncommitted in the captured transaction")
        #expect(ExplainDMLResult.transactionAvailabilityCaveat.contains("does not establish"))
        let original = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        for version in 1...5 {
            var legacy = original; legacy["version"] = version
            legacy["request"] = ["sql": captured.sql, "mode": "analyze"]
            var legacyResult = try #require(legacy["result"] as? [String: Any])
            let recordedDML = legacyResult.removeValue(forKey: "dml")
            var legacySupport = try #require(legacyResult["support"] as? [String: Any])
            let recordedSupport = legacySupport.removeValue(forKey: "dml")
            legacyResult["support"] = legacySupport; legacy["result"] = legacyResult
            let legacyText = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
            #expect(try PlanArtifact.decode(legacyText).version == version)
            for field in ["result", "support"] {
                for value in [NSNull(), field == "result" ? recordedDML! : recordedSupport!] as [Any] {
                    var object = legacy
                    var injectedResult = legacyResult
                    if field == "result" { injectedResult["dml"] = value }
                    else { var injectedSupport = legacySupport; injectedSupport["dml"] = value; injectedResult["support"] = injectedSupport }
                    object["result"] = injectedResult
                    let injectedText = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                    #expect(throws: (any Error).self) { try PlanArtifact.decode(injectedText) }
                }
            }
        }
        #expect(!text.contains("writeIntent") && !text.contains("targetDocumentId") && !text.contains("authorization"))
    }

    @Test func completedSQLAndUnknownPersistenceRemainDistinct() {
        let facts = ExplainDMLResult(target: .init(statement: "update"), execution: "completed", persistence: "unknown",
            transactionBefore: "idle", transactionAfter: "unknown", affectedRowsUnavailableReason: "notReported", targetExecution: "executed")
        #expect(ExplainDMLAdmission.accepts(facts, request: request(), support: support, transactionStatus: nil,
            sqlCompleted: true, outcomeUnknown: true, sqlNotExecuted: nil))
        #expect(!ExplainDMLAdmission.accepts(facts, request: request(), support: support, transactionStatus: .idle,
            sqlCompleted: true, outcomeUnknown: true, sqlNotExecuted: nil))
        #expect(facts.executionLabel == "SQL execution completed" && facts.persistenceLabel.contains("unknown"))
        #expect(facts.affectedRowsLabel.contains("reliable DML count"))
    }

    @Test func mysqlSuppressionFactsRemainExplicitOffline() throws {
        let mysql = ExplainSupport(engine: .mysql, serverVersion: "8.4.13", format: "tree", modes: [.plan, .analyze],
            dml: .init(analyze: ["mysqlMultiTableUpdate", "mysqlMultiTableDelete"], analyzeTargetExecution: "suppresses"))
        let facts = ExplainDMLResult(target: .init(statement: "update", mysqlMultiTable: true), execution: "completed",
            persistence: "notExecuted", transactionBefore: "transaction", transactionAfter: "transaction",
            affectedRowsUnavailableReason: "notReported", targetExecution: "suppressed")
        let captured = request("UPDATE fixture a, other b SET a.value = :p WHERE a.id = b.id", transaction: "transaction")
        var plan = ExplainPlanModel(request: captured, sourceText: captured.sql,
            sourceRange: NSRange(location: 42, length: captured.sql.utf16.count), profileID: UUID())
        plan.result = .init(support: mysql, mode: .analyze, status: "rawOnly", raw: "Synthetic runtime diagnostic",
            complete: true, diagnostic: "Synthetic capture", roots: [], nodes: [], metrics: [:], dml: facts)
        let offline = try PlanArtifact.decode(PlanArtifact.capture(plan, title: "Suppressed target rows").encoded())
        #expect(offline.result.support.dml?.analyzeTargetExecution == "suppresses")
        #expect(offline.displayPlan.dmlOutcome?.targetExecution == "suppressed")
        #expect(offline.displayPlan.dmlOutcome?.persistenceLabel.contains("does not exclude routine or external effects") == true)
        #expect(offline.request.writeIntent == nil && offline.request.context == nil && offline.displayPlan.sessionID == nil)
    }

}

struct ExplainDMLTransportTests {
    private func client(_ scenario: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys,copy
        scenario=sys.argv[1];caps=['explainDMLV1','explainParametersV1'];grants={};executions=0
        mysql=scenario in ['suppressed','suppressedUnknown']
        support=dict(engine='mysql' if mysql else 'postgresql',serverVersion='8.4.13' if mysql else '17.6',format='tree' if mysql else 'json',modes=['plan','analyze'],dml=dict(estimated=True,analyze=['mysqlMultiTableUpdate','mysqlMultiTableDelete'] if mysql else ['insert','update','delete','dataModifyingCTE'],analyzeTargetExecution='suppresses' if mysql else 'executes'))
        target=dict(statement='update',dataModifyingCTE=False,mysqlMultiTable=mysql)
        def send(v):print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            for key in ['sessionId','queryId']:
                if key in c:r[key]=c[key]
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=[] if scenario=='missingHelper' else caps)
            elif kind=='connect':r.update(type='connect.result',sessionId='owner',transactionStatus='idle',engine=support['engine'],capabilities=[] if scenario=='missingOwner' else caps,explainSupport=support)
            elif kind=='operation.assess':
                q=c['operations'][0]['explain'];token='grant';grants[token]=copy.deepcopy(q)
                preview=dict(sql='EXPLAIN '+q['sql'],mode=q['mode'],support=support,dml=target)
                r.update(type='operation.assessment',assessment=dict(decision='confirm',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='write',statements=[],explain=preview)],authorization=token))
            elif kind=='explain.run':
                assert grants.pop(c['authorization'])==c['explain'];executions+=1
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                facts=dict(target=copy.deepcopy(target),execution='completed',persistence='committed',transactionBefore='idle',transactionAfter='idle',affectedRowsUnavailableReason='notReported',targetExecution='suppressed' if mysql else 'executed')
                if scenario=='wrongTarget':facts['target']['statement']='delete'
                if scenario=='wrongBefore':facts['transactionBefore']='transaction'
                if scenario in ['unknownCommit','lostReady','postAckClosed','postAckPendingClosed','badFlags','suppressedUnknown']:
                    facts.update(execution='unknown' if scenario=='lostReady' else 'completed',persistence='notExecuted' if mysql else 'transactionPending' if scenario=='postAckPendingClosed' else 'committed' if scenario in ['postAckClosed','badFlags'] else 'unknown',transactionAfter='transaction' if scenario=='postAckPendingClosed' else 'idle' if scenario in ['postAckClosed','badFlags'] else 'unknown')
                    r.update(type='error',category='connection',message='Synthetic acknowledgement loss',connected=False,outcomeUnknown=scenario not in ['postAckClosed','postAckPendingClosed'],explainDML=facts)
                    if scenario=='lostReady':facts['targetExecution']='unknown'
                    if scenario in ['unknownCommit','postAckClosed','postAckPendingClosed','badFlags','suppressedUnknown']:r['sqlCompleted']=True
                elif scenario=='legacyCollision':r.update(type='error',category='connection',message='Invalid legacy flags',connected=False,outcomeUnknown=True,sqlCompleted=True)
                else:
                    if mysql:facts['persistence']='notExecuted'
                    result=dict(support=copy.deepcopy(support),mode='analyze',status='rawOnly',raw='Synthetic plan',complete=True,diagnostic='Synthetic capture',roots=[],nodes=[],metrics={})
                    if scenario!='missingFacts':result['dml']=facts
                    if scenario=='wrongSupport':result['support']['serverVersion']='different owner'
                    r.update(type='explain.result',transactionStatus='idle',sqlCompleted=True,durationMs=1,explain=result)
                    if scenario=='physical':r['connected']=False
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':r.update(type='shutdown.ack');send(r);break
            else:raise RuntimeError('unexpected command')
            send(r)
        """, scenario])
    }
    private func request(mysql: Bool = false) -> ExplainRequest {
        let sql = mysql ? "UPDATE fixture a, fixture_other b SET a.value = :p WHERE a.id = b.id" : "UPDATE fixture SET value = :p"
        return .init(sql: sql, mode: .analyze, parameters: [.init(name: "p", type: .text, value: "e\u{0301}' ; DELETE FROM excluded; --")],
            context: .init(documentId: "source", targetDocumentId: "target", rangeLocation: 12,
                rangeLength: sql.utf16.count, profileId: "profile", sessionId: "owner", transactionStatus: "idle"),
            writeIntent: .init(expectedTransactionStatus: "idle"))
    }
    private func connect(_ client: BackendClient, mysql: Bool = false) async throws {
        try await client.start()
        _ = try await client.request(.connect(.init(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable", engine: mysql ? .mysql : .postgresql)))
    }
    private func command(_ client: BackendClient, request: ExplainRequest) async throws -> BackendCommand {
        let assessed = try await client.request(.assess(sessionId: "owner", operations: [.init(type: "explain.run", explain: request)]))
        var command = BackendCommand.explain(sessionId: "owner", request: request)
        command.authorization = assessed.assessment?.authorization
        return command
    }

    @Test(arguments: ["paired", "missingHelper", "missingOwner", "wrongSupport", "wrongTarget", "wrongBefore", "missingFacts", "legacyCollision", "badFlags"])
    func typedEffectsRequireExactPhysicalOwnerRequestAndFlags(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await connect(client)
            if scenario == "missingHelper" || scenario == "missingOwner" {
                do { _ = try await command(client, request: request()); Issue.record("Unpaired intent was submitted") }
                catch { #expect(error as? BackendRequestError == .invalidCommand) }
            } else {
                let command = try await command(client, request: request())
                if scenario == "paired" {
                    let reply = try await client.request(command)
                    #expect(reply.explain?.dml?.persistence == "committed")
                } else {
                    do { _ = try await client.request(command); Issue.record("Foreign or malformed DML facts were accepted") }
                    catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
                }
            }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["unknownCommit", "lostReady", "postAckClosed", "postAckPendingClosed"])
    func acknowledgementLossPreservesKnownCompletionWithoutReplay(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await connect(client)
            let command = try await command(client, request: request())
            do { _ = try await client.request(command); Issue.record("Expected recorded remote uncertainty") }
            catch let error as BackendRemoteError {
                #expect(error.reply.outcomeUnknown == (!["postAckClosed", "postAckPendingClosed"].contains(scenario)))
                #expect(error.reply.explainDML?.persistence == (scenario == "postAckPendingClosed" ? "transactionPending" : scenario == "postAckClosed" ? "committed" : "unknown"))
                if scenario == "postAckPendingClosed" {
                    #expect(error.reply.connected == false && error.reply.transactionStatus == nil)
                    #expect(error.reply.explainDML?.transactionAfter == "transaction")
                    #expect(error.reply.explainDML?.persistenceLabel.hasPrefix("At acknowledgement") == true)
                }
                #expect((error.reply.sqlCompleted == true) == (scenario != "lostReady"))
                #expect(error.reply.explainDML?.execution == (scenario == "lostReady" ? "unknown" : "completed"))
            }
            do { _ = try await self.command(client, request: request()); Issue.record("Retired physical owner was reused") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func changedExactRequestCannotConsumeAnAssessedGrant() async throws {
        let client = client("paired")
        do {
            try await connect(client)
            var command = try await command(client, request: request())
            command.explain?.parameters?[0].value = "different typed value"
            do { _ = try await client.request(command); Issue.record("Changed values consumed the DML grant") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["physical", "explicit"])
    func completedFactsSurviveRetirementButCannotAuthorizeAnotherRequest(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await connect(client)
            let command = try await command(client, request: request())
            let reply = try await client.request(command)
            #expect(reply.explain?.dml?.persistence == "committed")
            if scenario == "explicit" { _ = try await client.request(.disconnect(sessionId: "owner")) }
            do { _ = try await self.command(client, request: request()); Issue.record("Retired owner was reused") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
            #expect(reply.explain?.dml?.execution == "completed")
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }


    @Test(arguments: ["suppressed", "suppressedUnknown"])
    func mysqlDiagnosticSuppressionDoesNotClaimTargetWritesOrRoutineSafety(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            try await connect(client, mysql: true)
            let command = try await command(client, request: request(mysql: true))
            if scenario == "suppressed" {
                let reply = try await client.request(command)
                #expect(reply.explain?.dml?.targetExecution == "suppressed" && reply.explain?.dml?.persistence == "notExecuted")
                #expect(reply.explain?.dml?.executionLabel.contains("target rows were not applied") == true)
            } else {
                do { _ = try await client.request(command); Issue.record("Expected unknown session/routine effects") }
                catch let error as BackendRemoteError {
                    #expect(error.reply.sqlCompleted == true && error.reply.outcomeUnknown == true)
                    #expect(error.reply.explainDML?.targetExecution == "suppressed" && error.reply.explainDML?.persistence == "notExecuted")
                    #expect(error.reply.explainDML?.transactionAfter == "unknown")
                }
            }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }


    @Test(arguments: ["policy", "context", "queuedCancel"])
    func definiteRefusalWithoutDMLFactsPreservesOtherPendingOwnersAndDoesNotResend(_ scenario: String) async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys,copy
        scenario=sys.argv[1];connections=0;attempts=0;pending_dml=None;pending_other=None;grant=None
        caps=['explainDMLV1','explainParametersV1']
        support=dict(engine='postgresql',serverVersion='17.6',format='json',modes=['plan','analyze'],dml=dict(estimated=True,analyze=['insert','update','delete','dataModifyingCTE'],analyzeTargetExecution='executes'))
        target=dict(statement='update',dataModifyingCTE=False,mysqlMultiTable=False)
        def send(v):print(json.dumps(v),flush=True)
        def identity(c):return dict(requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId'])
        def started(c):send(dict(type='query.started',**identity(c)))
        def result(c):send(dict(type='query.result',transactionStatus='idle',durationMs=1,columns=[dict(index=0,name='owner',typeOid=25)],rows=[[c['sessionId']]],commandTag='SELECT 1',rowCount=1,displayedRowCount=1,truncated=False,**identity(c)))
        def finish_pair():
            global pending_dml,pending_other
            if pending_dml is None or pending_other is None:return
            category={'policy':'policy','context':'conflict','queuedCancel':'cancelled'}[scenario]
            send(dict(type='error',category=category,message='Synthetic definite refusal',connected=True,transactionStatus='idle',sqlNotExecuted=True,outcomeUnknown=False,**identity(pending_dml)))
            result(pending_other);pending_dml=None;pending_other=None
        for line in sys.stdin:
            c=json.loads(line);kind=c['type']
            if kind=='hello':send(dict(type='hello.ack',requestId=c['requestId'],protocolVersion=6,capabilities=caps))
            elif kind=='connect':
                connections+=1;send(dict(type='connect.result',requestId=c['requestId'],sessionId='owner' if connections==1 else 'other-owner',transactionStatus='idle',engine='postgresql',capabilities=caps,explainSupport=support))
            elif kind=='operation.assess':
                q=c['operations'][0]['explain'];grant=copy.deepcopy(q)
                send(dict(type='operation.assessment',assessment=dict(decision='confirm',policy=dict(environment='unspecified',readOnly=False),operations=[dict(kind='write',statements=[],explain=dict(sql='EXPLAIN '+q['sql'],mode=q['mode'],support=support,dml=target))],authorization='grant'),**identity(c)))
            elif kind=='explain.run':
                attempts+=1;assert attempts==1 and c['authorization']=='grant' and c['explain']==grant
                if scenario=='queuedCancel':started(c)
                pending_dml=c;finish_pair()
            elif kind=='execute':
                assert c['sql']=='SELECT 1';started(c)
                if c['sessionId']=='other-owner' and attempts==0:pending_other=c;finish_pair()
                elif pending_dml is not None:pending_other=c;finish_pair()
                else:result(c)
            elif kind=='shutdown':
                assert attempts==1 and pending_dml is None and pending_other is None
                send(dict(type='shutdown.ack',requestId=c['requestId']));break
            else:raise RuntimeError('Unexpected request or replay: '+kind)
        """, scenario])
        do {
            try await connect(client)
            let other = try await client.request(.connect(.init(host: "localhost", port: 5432, database: "other-fixture",
                user: "fixture", password: "", sslMode: "disable")))
            #expect(other.sessionId == "other-owner")
            let command = try await command(client, request: request())
            let otherPending = Task { try await client.request(.execute(sessionId: "other-owner", sql: "SELECT 1")) }
            do { _ = try await client.request(command); Issue.record("Expected a definite remote refusal") }
            catch let error as BackendRemoteError {
                #expect(error.reply.sqlNotExecuted == true && error.reply.sqlCompleted != true && error.reply.outcomeUnknown == false)
                #expect(error.reply.explainDML == nil && error.reply.connected == true && error.reply.sessionId == "owner")
                #expect(error.reply.category == (scenario == "policy" ? "policy" : scenario == "context" ? "conflict" : "cancelled"))
            }
            let retained = try await otherPending.value
            #expect(retained.rows?.first?.first == "other-owner" && retained.transactionStatus == .idle)
            let sameOwner = try await client.request(.execute(sessionId: "owner", sql: "SELECT 1"))
            let otherOwner = try await client.request(.execute(sessionId: "other-owner", sql: "SELECT 1"))
            #expect(sameOwner.rows?.first?.first == "owner" && otherOwner.rows?.first?.first == "other-owner")
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

}
