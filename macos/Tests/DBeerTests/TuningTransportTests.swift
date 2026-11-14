import Foundation
import Testing
@testable import DBeer

/// Framed transport against a synthetic Python peer. No database, app, workspace,
/// credentials, persistence, windows, views or decision presenter is constructed.
struct TuningTransportTests {
    private func client(_ scenario: String) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import copy,json,sys
        scenario,path=sys.argv[1:]
        with open(path) as source:f=json.load(source)
        cap='tuningV1';caps=[cap,'explainParametersV1'];support=f['inspectRequest']['capture']['support'];grants={};connections=0;held=None;explain_writes=0
        def send(r):print(json.dumps(r),flush=True)
        for line in sys.stdin:
            c=json.loads(line);kind=c['type'];r=dict(type='',requestId=c['requestId'])
            for key in ['sessionId','queryId']:
                if key in c:r[key]=c[key]
            if kind=='hello':r.update(type='hello.ack',protocolVersion=6,capabilities=[] if scenario=='missingHelper' else caps)
            elif kind=='connect':
                connections+=1
                ownercaps=[] if scenario=='missingOwner' or scenario=='otherOwner' and connections>1 else caps
                r.update(type='connect.result',sessionId='owner' if connections==1 else 'other-owner',transactionStatus='transaction' if scenario in ['setting','unknownSetting'] else 'idle',engine='postgresql',capabilities=ownercaps,explainSupport=copy.deepcopy(support))
            elif kind=='operation.assess':
                operation=c['operations'][0];grants['grant']=copy.deepcopy(operation)
                assessed=dict(kind='read' if operation['type'] in ['tuning.validate','explain.run'] else 'write',statements=[])
                if operation['type']=='explain.run':assessed['explain']=dict(sql='EXPLAIN '+operation['explain']['sql'],mode='plan',support=copy.deepcopy(support))
                if operation['type']=='tuning.setting':assessed['tuningSetting']=copy.deepcopy(f['settingPreview'])
                r.update(type='operation.assessment',assessment=dict(decision='allow' if scenario=='blanketAllow' else 'confirm',policy=dict(environment='unspecified',readOnly=False),operations=[assessed],authorization='grant'))
            elif kind.startswith('tuning.'):
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                if kind=='tuning.inspect':
                    value=copy.deepcopy(f['inspection'])
                    if scenario=='wrongSupport':value['serverVersion']='different owner'
                    if scenario=='wrongVariant':value['variants'][0]['request']['parameters'][0]['value']='9007199254740992'
                    r.update(type='tuning.inspect.result',transactionStatus='idle',tuningInspection=value)
                elif kind=='tuning.validate':
                    assert grants.pop(c['authorization'])==dict(type=kind,tuningValidation=c['tuningValidation'])
                    r.update(type='tuning.validate.result',transactionStatus='idle',tuningValidation=copy.deepcopy(f['validation']))
                elif kind=='tuning.setting.observe':r.update(type='tuning.setting.observe.result',transactionStatus='transaction',tuningSettingObservation=copy.deepcopy(f['settingObservation']))
                elif kind=='tuning.setting':
                    assert grants.pop(c['authorization'])==dict(type=kind,tuningSetting=c['tuningSetting'])
                    if scenario=='unknownSetting':r.update(type='error',category='connection',message='Synthetic lost acknowledgement',connected=True,outcomeUnknown=True)
                    else:r.update(type='tuning.setting.result',transactionStatus='transaction',tuningSetting=copy.deepcopy(f['settingResult']))
                else:raise RuntimeError('unexpected tuning family')
                if scenario=='physical':r['connected']=False
            elif kind=='explain.run':
                explain_writes+=1
                assert grants.pop(c['authorization'])==dict(type=kind,explain=c['explain'])
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                if scenario=='captureCancel':held=copy.deepcopy(c);continue
                r.update(type='explain.result',transactionStatus='idle',durationMs=0,sqlCompleted=True,explain=copy.deepcopy(f['inspectRequest']['capture']))
            elif kind=='execute':
                send(dict(type='query.started',requestId=c['requestId'],sessionId=c['sessionId'],queryId=c['queryId']))
                r.update(type='query.result',transactionStatus='idle',durationMs=0,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
                if c['sql']=='SELECT synthetic_explain_write_count':r.update(columns=[dict(index=0,name='writes')],rows=[[str(explain_writes)]],rowCount=1,displayedRowCount=1,commandTag='SELECT 1')
            elif kind=='cancel':
                grants.clear();r.update(type='cancel.ack',status='accepted')
                if held is not None:
                    assert c['sessionId']==held['sessionId'] and c['queryId']==held['queryId']
                    send(r);send(dict(type='error',requestId=held['requestId'],sessionId=held['sessionId'],queryId=held['queryId'],category='cancelled',message='Synthetic capture cancelled',connected=True,outcomeUnknown=False,transactionStatus='idle'));held=None;continue
            elif kind=='disconnect':r.update(type='disconnect.ack')
            elif kind=='shutdown':r.update(type='shutdown.ack');send(r);break
            else:raise RuntimeError('unexpected command')
            send(r)
        """, scenario, TuningNativeFixture.root.appendingPathComponent("protocol/fixtures/tuning-v1/contract.json").path])
    }
    private func connect(_ client: BackendClient, role: String? = nil) async throws -> String {
        try await client.start()
        var settings = ConnectionSettings(host: "localhost", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable")
        settings.sessionPurpose = role
        return try #require(await client.request(.connect(settings)).sessionId)
    }
    @Test(arguments: ["paired", "missingHelper", "missingOwner", "role", "otherOwner", "wrongSupport", "wrongVariant"])
    func inspectionRequiresPairedOrdinaryPhysicalOwnerAndExactCandidate(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            var session = try await connect(client, role: scenario == "role" ? "structure" : nil)
            if scenario == "otherOwner" { session = try #require(await client.request(.connect(.init(host: "localhost", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable"))).sessionId) }
            var request = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest")
            request.source.context?.sessionId = session
            if scenario == "paired" {
                let reply = try await client.request(.tuningInspect(sessionId: session, request: request))
                #expect(reply.tuningInspection?.valid == true)
            } else {
                do { _ = try await client.request(.tuningInspect(sessionId: session, request: request)); Issue.record("Unnegotiated or foreign tuning evidence was accepted") }
                catch let error as BackendRequestError { #expect(error == .invalidCommand) }
                catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }
    @Test(arguments: ["paired", "replay", "changedRequest", "grantRetired", "blanketAllow"])
    func validationAlwaysUsesFreshExactOneUseReviewedGrant(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            let session = try await connect(client)
            let validation = try TuningNativeFixture.decode(TuningValidationRequest.self, "validationRequest")
            let operation = OperationRequest(type: "tuning.validate", tuningValidation: validation)
            if scenario == "blanketAllow" {
                do { _ = try await client.request(.assess(sessionId: session, operations: [operation])); Issue.record("Blanket allow authorized paired validation") }
                catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            } else {
                let assessment = try await client.request(.assess(sessionId: session, operations: [operation]))
                var command = BackendCommand.tuningValidate(sessionId: session, request: validation)
                command.authorization = assessment.assessment?.authorization
                if scenario == "changedRequest" { command.tuningValidation?.maxRows -= 1 }
                if scenario == "grantRetired" {
                    let inspection = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest")
                    _ = try await client.request(.tuningInspect(sessionId: session, request: inspection))
                }
                if ["changedRequest", "grantRetired"].contains(scenario) {
                    do { _ = try await client.request(command); Issue.record("A changed or retired grant was admitted") }
                    catch let error as BackendRequestError { #expect(error == .invalidCommand) }
                } else {
                    let reply = try await client.request(command)
                    #expect(reply.tuningValidation?.state == "observedEqual")
                    do { _ = try await client.request(command); Issue.record("One-use grant was replayed") }
                    catch let error as BackendRequestError { #expect(error == .invalidCommand) }
                }
            }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }
    @Test func independentOwnerReadPreservesExactReviewedGrant() async throws {
        let client = client("twoOwners")
        do {
            let owner = try await connect(client)
            let independent = try #require(await client.request(.connect(.init(host: "localhost", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable"))).sessionId)
            let validation = try TuningNativeFixture.decode(TuningValidationRequest.self, "validationRequest")
            let assessment = try await client.request(.assess(sessionId: owner, operations: [.init(type: "tuning.validate", tuningValidation: validation)]))
            _ = try await client.request(.execute(sessionId: independent, sql: "SELECT synthetic_read"))
            var command = BackendCommand.tuningValidate(sessionId: owner, request: validation); command.authorization = assessment.assessment?.authorization
            #expect(try await client.request(command).tuningValidation?.state == "observedEqual")
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func staleCaptureAndAssessmentCleanupPreserveNewForegroundGrant() async throws {
        let client = client("cleanup")
        do {
            let owner = try await connect(client)
            let source = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest").source
            let oldAssessment = try await client.request(.assess(sessionId: owner, operations: [.init(type: "explain.run", explain: source)]))
            var capture = BackendCommand.explain(sessionId: owner, request: source); capture.authorization = oldAssessment.assessment?.authorization
            _ = try await client.request(capture)
            let validation = try TuningNativeFixture.decode(TuningValidationRequest.self, "validationRequest")
            let foreground = try await client.request(.assess(sessionId: owner, operations: [.init(type: "tuning.validate", tuningValidation: validation)]))
            await client.cancelPendingCapture(sessionID: owner, queryID: try #require(capture.queryId))
            await client.discardAssessmentIfCurrent(oldAssessment)
            var command = BackendCommand.tuningValidate(sessionId: owner, request: validation); command.authorization = foreground.assessment?.authorization
            #expect(try await client.request(command).tuningValidation?.state == "observedEqual")
            let retired = try await client.request(.assess(sessionId: owner, operations: [.init(type: "tuning.validate", tuningValidation: validation)]))
            await client.discardAssessmentIfCurrent(retired)
            command = .tuningValidate(sessionId: owner, request: validation); command.authorization = retired.assessment?.authorization
            do { _ = try await client.request(command); Issue.record("A stopped late assessment retained authority") }
            catch let error as BackendRequestError { #expect(error == .invalidCommand) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func explicitStopCancelsExactPendingCaptureAndLeavesLaterAndIndependentQueriesUsable() async throws {
        let client = client("captureCancel"), started = TuningCaptureStartedGate()
        do {
            let owner = try await connect(client)
            let other = try #require(await client.request(.connect(.init(host: "localhost", port: 5432, database: "synthetic", user: "fixture", password: "", sslMode: "disable"))).sessionId)
            let source = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest").source
            let assessed = try await client.request(.assess(sessionId: owner, operations: [.init(type: "explain.run", explain: source)]))
            var capture = BackendCommand.explain(sessionId: owner, request: source); capture.authorization = assessed.assessment?.authorization
            let command = capture
            let pending = Task {
                do {
                    let reply = try await client.request(command) { event in
                        if event.type == "query.started" { Task { await started.signal() } }
                    }
                    await started.signal(); return reply
                } catch { await started.signal(); throw error }
            }
            await started.wait()
            await client.cancelPendingCapture(sessionID: owner, queryID: try #require(capture.queryId))
            do { _ = try await pending.value; Issue.record("The explicit capture cancel did not cancel its query") }
            catch let error as BackendRemoteError { #expect(error.reply.category == "cancelled" && error.reply.outcomeUnknown == false) }
            _ = try await client.request(.execute(sessionId: other, sql: "SELECT independent_synthetic_read"))
            let validation = try TuningNativeFixture.decode(TuningValidationRequest.self, "validationRequest")
            let foreground = try await client.request(.assess(sessionId: owner, operations: [.init(type: "tuning.validate", tuningValidation: validation)]))
            await client.cancelPendingCapture(sessionID: owner, queryID: try #require(capture.queryId))
            var next = BackendCommand.tuningValidate(sessionId: owner, request: validation); next.authorization = foreground.assessment?.authorization
            #expect(try await client.request(next).tuningValidation?.state == "observedEqual")
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["stoppedLease", "cancelledTask"])
    func stoppedBeforeTransportAdmissionWritesZeroExplainsAndActiveCaptureStillRuns(_ scenario: String) async throws {
        let client = client("preAdmission"), ready = TuningCaptureStartedGate(), release = TuningCaptureStartedGate()
        do {
            let owner = try await connect(client)
            let source = try TuningNativeFixture.decode(TuningInspectRequest.self, "inspectRequest").source
            let assessed = try await client.request(.assess(sessionId: owner, operations: [.init(type: "explain.run", explain: source)]))
            var capture = BackendCommand.explain(sessionId: owner, request: source); capture.authorization = assessed.assessment?.authorization
            let command = capture, admission = ExplainCollectorAdmission()
            let queued = Task {
                await ready.signal(); await release.wait()
                return try await client.request(command, captureAdmission: admission)
            }
            await ready.wait()
            if scenario == "stoppedLease" { admission.cancel() } else { queued.cancel() }
            await release.signal()
            do { _ = try await queued.value; Issue.record("Stopped capture entered the transport") }
            catch let error as BackendRequestError { #expect(error == .cancelledBeforeDispatch) }
            let before = try await client.request(.execute(sessionId: owner, sql: "SELECT synthetic_explain_write_count"))
            #expect(before.rows?.first?.first == "0")
            await client.discardAssessmentIfCurrent(assessed)
            let fresh = try await client.request(.assess(sessionId: owner, operations: [.init(type: "explain.run", explain: source)]))
            var positive = BackendCommand.explain(sessionId: owner, request: source); positive.authorization = fresh.assessment?.authorization
            let reply = try await client.request(positive, captureAdmission: ExplainCollectorAdmission())
            #expect(reply.explain?.valid == true)
            let after = try await client.request(.execute(sessionId: owner, sql: "SELECT synthetic_explain_write_count"))
            #expect(after.rows?.first?.first == "1")
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: ["setting", "unknownSetting"])
    func settingObservationAndChangeKeepExistingTransactionAndUnknownAcknowledgement(_ scenario: String) async throws {
        let client = client(scenario)
        do {
            let session = try await connect(client)
            let observe = try TuningNativeFixture.decode(TuningSettingObservationRequest.self, "settingObservationRequest")
            let observation = try await client.request(.tuningObserveSetting(sessionId: session, request: observe))
            #expect(observation.tuningSettingObservation?.workMemKiB == 4_096)
            let request = try TuningNativeFixture.decode(TuningSettingRequest.self, "settingRequest")
            let assessment = try await client.request(.assess(sessionId: session, operations: [.init(type: "tuning.setting", tuningSetting: request)]))
            var command = BackendCommand.tuningSet(sessionId: session, request: request); command.authorization = assessment.assessment?.authorization
            if scenario == "setting" {
                let reply = try await client.request(command)
                #expect(reply.tuningSetting?.restore.valueKiB == 4_096)
            } else {
                do { _ = try await client.request(command); Issue.record("Unknown acknowledgement became success") }
                catch let error as BackendRemoteError { #expect(error.reply.outcomeUnknown == true && error.reply.tuningSetting == nil) }
            }
            do { _ = try await client.request(command); Issue.record("A setting grant was replayed") }
            catch let error as BackendRequestError { #expect(error == .invalidCommand) }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }
}

private actor TuningCaptureStartedGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { started = true; waiter?.resume(); waiter = nil }
    func wait() async { if !started { await withCheckedContinuation { waiter = $0 } } }
}
