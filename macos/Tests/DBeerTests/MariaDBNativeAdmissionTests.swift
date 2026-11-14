import Foundation
import Testing
@testable import DBeer

/// Pure values and private framed Python peers only; no databases, stores or native UI.
struct MariaDBNativeAdmissionTests {
    private var target: StructureTarget { .init(schema: "fixture", table: "owned", create: false) }
    private func numericDraft(scale: Int, change: Bool = false) -> StructureDraft {
        let type = StructureDataType(kind: "numeric", precision: 65, scale: scale)
        return change
            ? .init(columns: [], changes: [.init(name: "amount", type: type)])
            : .init(columns: [.init(name: "amount", type: type, nullable: true, default: .init(kind: "none"))])
    }
    private func physicalDraft(engine: String = "InnoDB", algorithm: String = "INPLACE") -> StructurePhysicalDraft {
        .init(version: 1, target: target, intent: .init(kind: "storageEngine", engine: engine, algorithm: algorithm, lock: "SHARED"))
    }
    private func preview(session: String, draft: StructureDraft) -> BackendCommand {
        .init(type: "structure.preview", requestId: UUID().uuidString, sessionId: session, queryId: UUID().uuidString,
              structure: .init(baselineId: "baseline", draft: draft))
    }
    private func physical(_ operation: String, session: String, draft: StructurePhysicalDraft? = nil) -> BackendCommand {
        .init(type: "structure.physical." + operation, requestId: UUID().uuidString, sessionId: session, queryId: UUID().uuidString,
              structure: .init(physical: .init(draft: draft)))
    }
    private func settings(_ engine: DatabaseEngine) -> ConnectionSettings {
        .init(host: "synthetic.invalid", port: engine.defaultPort, database: "synthetic", user: "synthetic", password: "",
              sslMode: "disable", engine: engine, sqlite: engine == .sqlite ? .init(path: "/synthetic/unused.sqlite") : nil)
    }
    private func client(baselineScale: Int = 30) -> BackendClient {
        BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        cap='tableStructurePhysicalV1';owners={};serial=0;scale=int(sys.argv[1])
        def send(v): print(json.dumps(v),flush=True)
        for line in sys.stdin:
            c=json.loads(line);typ=c['type'];base=dict(requestId=c['requestId'])
            if typ=='hello':send(dict(base,type='hello.ack',protocolVersion=6,capabilities=[cap]));continue
            if typ=='shutdown':send(dict(base,type='shutdown.ack'));break
            if typ=='connect':
                serial+=1;session='owner-'+str(serial);engine=c['connection']['engine'];owners[session]=engine
                send(dict(base,type='connect.result',sessionId=session,engine=engine,transactionStatus='idle',connected=True,capabilities=[cap] if engine!='sqlite' else []));continue
            base['sessionId']=c['sessionId']
            if typ=='disconnect':send(dict(base,type='disconnect.ack'));continue
            base['queryId']=c['queryId']
            if typ!='structure.physical.status':send(dict(base,type='query.started'))
            if typ in ['structure.physical.status','structure.physical.close']:
                send(dict(base,type=typ+'.result',connected=False,structure=dict(physical={})));continue
            if typ=='structure.load':
                column=dict(name='amount',nativeType='numeric(65,'+str(scale)+')',nullable=True,editableType=dict(kind='numeric',precision=65,scale=scale))
                baseline=dict(id='baseline',target=c['structure']['target'],engine=owners[c['sessionId']],fingerprint='a'*64,columns=[column],limitations=[])
                send(dict(base,type=typ+'.result',connected=True,transactionStatus='idle',structure=dict(baseline=baseline)));continue
            send(dict(base,type='error',category='syntheticPreviewReached',message='Typed preview reached private peer',connected=True,outcomeUnknown=False,sqlNotExecuted=True))
        """, String(baselineScale)])
    }
    private func expectPreview(_ client: BackendClient, _ command: BackendCommand, admitted: Bool) async throws {
        if admitted {
            do { _ = try await client.request(command); Issue.record("Private preview peer did not report its admission marker.") }
            catch let error as BackendRemoteError {
                #expect(error.reply.category == "syntheticPreviewReached" && error.reply.sqlNotExecuted == true)
            }
        } else {
            do { _ = try await client.request(command); Issue.record("Foreign or unknown owner admitted MariaDB structure syntax.") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
        }
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql, .mariadb, .sqlite])
    func observedNumericScaleUsesTheBaselineEngine(_ engine: DatabaseEngine) throws {
        for scale in [30, 31, 38, 39] {
            let baseline = StructureBaseline(id: "baseline", target: target, engine: engine.rawValue,
                fingerprint: String(repeating: "a", count: 64),
                columns: [.init(name: "amount", nativeType: "numeric", nullable: true, editableType: .init(kind: "numeric", precision: 65, scale: scale))], limitations: [])
            let expected = scale <= (engine == .mariadb ? 38 : 30)
            #expect(baseline.valid == expected)
            let decoded = try JSONDecoder().decode(StructureBaseline.self, from: JSONEncoder().encode(baseline))
            #expect(decoded.valid == expected && decoded == baseline)
        }
    }

    @Test func unknownOwnersRetainOnlyThePreviousSyntaxBounds() {
        for change in [false, true] {
            #expect(numericDraft(scale: 30, change: change).valid(for: nil))
            #expect(!numericDraft(scale: 31, change: change).valid(for: nil))
            #expect(!numericDraft(scale: 38, change: change).valid(for: nil))
        }
        #expect(physicalDraft().valid(for: nil))
        #expect(!physicalDraft(algorithm: "NOCOPY").valid(for: nil))
        #expect(!physicalDraft(engine: "Aria").valid(for: nil))
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql, .mariadb, .sqlite])
    func directNumericPreviewRequiresTheExactLiveMariaDBOwner(_ engine: DatabaseEngine) async throws {
        let client = client()
        do {
            try await client.start()
            _ = try await client.request(.connect(settings(engine == .mariadb ? .mysql : .mariadb)))
            let session = try #require(await client.request(.connect(settings(engine))).sessionId)
            for change in [false, true] {
                for scale in [30, 31, 38, 39] {
                    try await expectPreview(client, preview(session: session, draft: numericDraft(scale: scale, change: change)),
                        admitted: scale <= (engine == .mariadb ? 38 : 30))
                }
            }
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func directUnknownOwnerPreservesLegacyNumericPreview() async throws {
        let client = client()
        do {
            try await client.start()
            for otherOwnerExists in [false, true] {
                if otherOwnerExists { _ = try await client.request(.connect(settings(.mariadb))) }
                for change in [false, true] {
                    for scale in [30, 31, 38] {
                        try await expectPreview(client, preview(session: "unrecorded-owner", draft: numericDraft(scale: scale, change: change)), admitted: scale == 30)
                    }
                }
                try await expectPreview(client, physical("preview", session: "unrecorded-owner", draft: physicalDraft(engine: "Aria", algorithm: "NOCOPY")), admitted: false)
            }
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql, .mariadb])
    func directPhysicalPreviewRequiresTheExactLiveMariaDBOwner(_ engine: DatabaseEngine) async throws {
        let client = client()
        do {
            try await client.start()
            _ = try await client.request(.connect(settings(engine == .mariadb ? .mysql : .mariadb)))
            let session = try #require(await client.request(.connect(settings(engine))).sessionId)
            try await expectPreview(client, physical("preview", session: session, draft: physicalDraft()), admitted: true)
            for draft in [physicalDraft(algorithm: "NOCOPY"), physicalDraft(engine: "Aria"), physicalDraft(engine: "Aria", algorithm: "NOCOPY")] {
                try await expectPreview(client, physical("preview", session: session, draft: draft), admitted: engine == .mariadb)
            }
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test(arguments: [(DatabaseEngine.postgresql, 38), (.mysql, 38), (.mariadb, 38), (.mariadb, 39), (.sqlite, 38), (.mysql, 30)])
    func directBaselineAdmissionUsesItsObservedEngine(_ input: (DatabaseEngine, Int)) async throws {
        let client = client(baselineScale: input.1)
        do {
            try await client.start()
            let session = try #require(await client.request(.connect(settings(input.0))).sessionId)
            let command = BackendCommand(type: "structure.load", requestId: UUID().uuidString, sessionId: session,
                queryId: UUID().uuidString, structure: .init(target: target))
            if input.1 <= (input.0 == .mariadb ? 38 : 30) {
                #expect(try await client.request(command).structure?.baseline?.valid == true)
            } else {
                do { _ = try await client.request(command); Issue.record("Baseline admitted numeric scale outside its engine contract.") }
                catch let error as BackendTransportError { #expect(error.code == .invalidMessage) }
            }
            _ = await client.shutdown()
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func physicalLossRetiresMariaDBExtensionsAndPreservesStatusUntilDisconnectAcknowledgement() async throws {
        let client = client()
        do {
            try await client.start()
            let session = try #require(await client.request(.connect(settings(.mariadb))).sessionId)
            #expect(try await client.request(physical("status", session: session)).connected == false)
            try await expectPreview(client, preview(session: session, draft: numericDraft(scale: 38)), admitted: false)
            try await expectPreview(client, physical("preview", session: session, draft: physicalDraft(engine: "Aria", algorithm: "NOCOPY")), admitted: false)
            #expect(try await client.request(physical("status", session: session)).connected == false)
            _ = try await client.request(physical("close", session: session))
            _ = try await client.request(physical("status", session: session))
            _ = try await client.request(.disconnect(sessionId: session))
            do { _ = try await client.request(physical("status", session: session)); Issue.record("Disconnect acknowledgement retained physical status admission.") }
            catch { #expect(error as? BackendRequestError == .invalidCommand) }
            #expect(await client.shutdown().acknowledged)
        } catch { _ = await client.shutdown(); throw error }
    }

    @Test func explainOptionDecodersRejectUnusedMariaDBEnvelopes() throws {
        for raw in [#"{"mysql":{"format":"json"}}"#, #"{"postgresql":{"buffers":false}}"#] {
            let options = try JSONDecoder().decode(ExplainOptions.self, from: Data(raw.utf8))
            #expect(options.valid)
            for foreign in [#"{}"#, #"{"unknown":true}"#, "null"] {
                let mixed = String(raw.dropLast()) + #", "mariadb":"# + foreign + "}"
                #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptions.self, from: Data(mixed.utf8)) }
            }
        }
        for raw in [#"{"mysql":{"plan":["json"],"analyze":[],"jsonAnalyzeRequiresVersion2":false}}"#,
                    #"{"postgresql":{"plan":[],"analyze":[]}}"#] {
            let support = try JSONDecoder().decode(ExplainOptionSupport.self, from: Data(raw.utf8))
            #expect(support.valid(engine: support.mysql == nil ? .postgresql : .mysql))
            for foreign in [#"{}"#, #"{"unknown":true}"#, "null"] {
                let mixed = String(raw.dropLast()) + #", "mariadb":"# + foreign + "}"
                #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptionSupport.self, from: Data(mixed.utf8)) }
            }
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptions.self, from: Data(#"{"mariadb":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ExplainOptionSupport.self, from: Data(#"{"mariadb":{}}"#.utf8)) }
    }
}
