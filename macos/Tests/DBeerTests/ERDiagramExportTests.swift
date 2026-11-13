import CoreGraphics
import Combine
import Darwin
import Foundation
import ImageIO
import Testing
@testable import DBeer

// Pure geometry, native file encoders and private filesystem fixtures only.
// No windows, application activation, screenshots or visual inspection.
enum ERExportFixtures {
    static func snapshot(collapsed: Bool = false) -> ERDiagramExportSnapshot {
        let profile = UUID()
        let a = ERTableID(profileID: profile, schema: "schema<&>", name: "é")
        let b = ERTableID(profileID: profile, schema: "schema<&>", name: "e\u{301}")
        let key = TableForeignKey(name: "key<&>\u{1}", target: b.reference, columns: [.init(source: "parent", target: "id", position: 1)])
        let columns = [ERColumn(name: "id", nativeType: "integer", nullable: false, primaryKeyPosition: 1),
                       ERColumn(name: "parent", nativeType: "integer", nullable: true, primaryKeyPosition: nil),
                       ERColumn(name: "control\u{1}\u{202e}\\<&>\n", nativeType: "text", nullable: true, primaryKeyPosition: nil),
                       ERColumn(name: String(repeating: "e\u{301}", count: 150), nativeType: "text", nullable: true, primaryKeyPosition: nil)]
        let edge = ERRelationship(source: a, key: key)
        return .init(title: "ER Diagram", profileName: "Synthetic connection", scope: .diagram, tables: [a, b],
                     metadata: [a: .init(table: a, columns: columns, foreignKeys: [key], columnState: .available, relationshipState: .available),
                                b: .init(table: b, columns: [columns[0]], columnState: .partial("Synthetic denied metadata"), relationshipState: .stale("Changed after capture"))],
                     placements: [.init(table: a, point: .init(x: -400, y: -120), manual: true), .init(table: b, point: .init(x: 160, y: -60), manual: true)],
                     collapsed: collapsed ? [a] : [], relationships: [edge], relationshipDescriptions: [.init(id: edge.id, kind: .declared, targetProfileName: nil)], notice: "Only selected metadata is included.")
    }
    static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-er-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func decodedMetadata(_ value: String) throws -> [String: Any] {
        let prefix = "DBeerERExport/v1:"
        #expect(value.hasPrefix(prefix))
        let data = try #require(Data(base64Encoded: String(value.dropFirst(prefix.count))))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor static func waitFor(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
}

struct ERDiagramExportContentTests {
    @Test func controlEscapesAreReversibleAndUnicodeIdentityIsNotNormalized() throws {
        let raw = "a\u{1}\u{b}\u{85}\u{202e}\u{2028}\u{feff}\u{fffe}\\u{1}<&>\"'é e\u{301}"
        let displayed = ERDiagramExportText.display(raw)
        let recovered = try #require(ERDiagramExportText.original(displayed))
        #expect(Data(recovered.utf8) == Data(raw.utf8))
        #expect(!displayed.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0xfffe })
        #expect(ERDiagramExportText.original("bad\\u{x}") == nil)
        let metadata = try ERExportFixtures.snapshot().originalMetadata()
        let document = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        let tables = try #require(document["tables"] as? [[String: Any]])
        let names = try tables.map { table in
            let name = try #require(table["name"] as? String)
            return Data(name.utf8)
        }
        #expect(Set(names).count == 2)
    }

    @Test func scenePreservesManualGeometryAndMakesShorteningAndMissingFactsExplicit() throws {
        let snapshot = ERExportFixtures.snapshot()
        let scene = try ERDiagramExportScene.make(snapshot, options: .init())
        let cards = scene.primitives.compactMap { primitive -> CGRect? in
            if case .rectangle(let rect, let radius, _, _) = primitive, radius == 9 { return rect }; return nil
        }
        #expect(cards.count == 2)
        #expect(cards[1].minX - cards[0].minX == 560 && cards[1].minY - cards[0].minY == 60)
        #expect(cards.allSatisfy { scene.graphBounds.contains($0) })
        let texts = scene.primitives.compactMap { primitive -> String? in if case .text(let value, _, _, _, _, _) = primitive { return value }; return nil }
        #expect(texts.contains { $0.hasSuffix("…") })
        #expect(texts.contains { $0.contains("labels are shortened") })
        #expect(texts.contains { $0.contains("Control characters") })
        #expect(texts.contains { $0.contains("Synthetic denied metadata") })
        #expect(texts.contains { $0.contains("Changed after capture") })
    }

    @Test func collapsedAndBoundaryCoverageRetainOriginalColumnsAndExactRelationships() throws {
        let base = ERExportFixtures.snapshot(), table = base.tables[0]
        let columns = (0..<30).map { ERColumn(name: "column_" + String($0), nativeType: "text", nullable: true, primaryKeyPosition: $0 == 29 ? 1 : nil) }
        let snapshot = ERDiagramExportSnapshot(title: base.title, profileName: base.profileName, scope: .selectedTable, tables: [table],
            metadata: [table: .init(table: table, columns: columns, columnState: .available, relationshipState: .available)],
            placements: [base.placements[0]], collapsed: [table], relationships: base.relationships,
            relationshipDescriptions: base.relationshipDescriptions, notice: nil)
        let scene = try ERDiagramExportScene.make(snapshot, options: .init(scope: .selectedTable))
        #expect(scene.exportedTables == [table])
        let texts = scene.primitives.compactMap { primitive -> String? in if case .text(let value, _, _, _, _, _) = primitive { return value }; return nil }
        #expect(texts.contains("11 of 30 columns"))
        #expect(texts.contains { $0.contains("outside this area") })
        let document = try #require(JSONSerialization.jsonObject(with: scene.originalMetadata) as? [String: Any])
        let tables = try #require(document["tables"] as? [[String: Any]])
        #expect((tables[0]["columns"] as? [[String: Any]])?.count == 30)
        #expect((document["relationships"] as? [[String: Any]])?.count == 1)
    }

    @Test func actualPNGAndPDFContainGeometryAndExactOriginalNameMetadata() throws {
        let scene = try ERDiagramExportScene.make(ERExportFixtures.snapshot(), options: .init())
        let png = try ERDiagramExportRenderer.png(scene, scale: 1)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == Int(scene.size.width))
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == Int(scene.size.height))
        let pngInfo = try #require(properties[kCGImagePropertyPNGDictionary] as? NSDictionary)
        let description = try #require(pngInfo[kCGImagePropertyPNGDescription] as? String)
        let pngDocument = try ERExportFixtures.decodedMetadata(description)
        #expect((pngDocument["tables"] as? [[String: Any]])?.count == 2)
        let pdf = try ERDiagramExportRenderer.pdf(scene)
        #expect(pdf.starts(with: Data("%PDF-".utf8)))
        let provider = try #require(CGDataProvider(data: pdf as CFData)), document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == scene.size)
        let info = try #require(document.info), subjectKey = "Subject"
        var subject: CGPDFStringRef?
        #expect(CGPDFDictionaryGetString(info, subjectKey, &subject))
        let subjectValue = try #require(subject), cfText = try #require(CGPDFStringCopyTextString(subjectValue))
        let pdfDocument = try ERExportFixtures.decodedMetadata(cfText as String)
        #expect((pdfDocument["tables"] as? [[String: Any]])?.count == 2)
    }

    @Test func SVGIsValidStaticXMLWithOriginalControlsOnlyInReversibleMetadata() throws {
        let scene = try ERDiagramExportScene.make(ERExportFixtures.snapshot(), options: .init(appearance: .dark))
        let data = try ERDiagramExportRenderer.svg(scene)
        let parser = XMLParser(data: data), delegate = SVGDelegate()
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        #expect(parser.parse())
        #expect(!delegate.elements.contains("script") && !delegate.elements.contains("foreignObject"))
        #expect(!delegate.attributes.contains { $0.key == "href" || $0.key == "xlink:href" })
        #expect(!data.contains(1) && !data.contains(11))
        let original = try #require(Data(base64Encoded: delegate.metadata))
        #expect(original == scene.originalMetadata)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("&lt;&amp;&gt;") || xml.contains("&lt;"))
        #expect(xml.contains("\\u{1}"))
    }

    @Test func invalidGeometryAndRasterBudgetsFailBeforeAllocatingPixels() throws {
        let base = ERExportFixtures.snapshot()
        let invalid = ERDiagramExportSnapshot(title: base.title, profileName: base.profileName, scope: base.scope, tables: base.tables,
            metadata: base.metadata, placements: [.init(table: base.tables[0], point: .init(x: .infinity, y: 0))], collapsed: [],
            relationships: base.relationships, relationshipDescriptions: base.relationshipDescriptions, notice: nil)
        #expect(throws: ERDiagramExportFailure.self) { try invalid.validate() }
        let tooLarge = ERDiagramExportScene(size: CGSize(width: 20_000, height: 1), palette: .init(.light), primitives: [], originalMetadata: Data(), graphBounds: .zero, exportedTables: [])
        #expect(throws: ERDiagramExportFailure.self) { try ERDiagramExportRenderer.png(tooLarge, scale: 1) }
        #expect(throws: ERDiagramExportFailure.self) { try ERDiagramExportScene.make(base, options: .init(scale: 0.5)) }
    }

    @Test func logicalKindsExternalProfilesAndUnvalidatedIntentRemainExplicit() throws {
        let base = ERExportFixtures.snapshot(), a = base.tables[0], b = base.tables[1]
        let logical = ERRelationship(source: a, key: .init(name: "local mapping", target: b.reference,
            columns: [.init(source: "parent", target: "id", position: 1)]), logicalID: UUID())
        let remote = ERTableID(profileID: UUID(), schema: "external", name: "target")
        let external = ERRelationship(source: a, key: .init(name: "cross profile", target: remote.reference,
            columns: [.init(source: "parent", target: "id", position: 1)]), logicalID: UUID(), targetProfileID: remote.profileID, targetProfileName: "Other connection")
        let snapshot = ERDiagramExportSnapshot(title: base.title, profileName: base.profileName, scope: base.scope, tables: base.tables,
            metadata: base.metadata, placements: base.placements, collapsed: [], relationships: [logical, external],
            relationshipDescriptions: [.init(id: logical.id, kind: .logical, targetProfileName: nil),
                .init(id: external.id, kind: .logical, targetProfileName: "Other connection", sourceProfileName: "Source", validationNotice: "Current target metadata is unverified.")], notice: nil)
        let scene = try ERDiagramExportScene.make(snapshot, options: .init())
        #expect(scene.primitives.contains { if case .line(_, _, let dashed) = $0 { dashed } else { false } })
        let texts = scene.primitives.compactMap { primitive -> String? in if case .text(let value, _, _, _, _, _) = primitive { return value }; return nil }
        #expect(texts.contains { $0.contains("unverified") })
        let metadata = try #require(JSONSerialization.jsonObject(with: scene.originalMetadata) as? [String: Any])
        let edges = try #require(metadata["relationships"] as? [[String: Any]])
        #expect(edges.allSatisfy { $0["kind"] as? String == "logical" })
        #expect(edges.contains { $0["targetProfileName"] as? String == "Other connection" && $0["validationNotice"] as? String == "Current target metadata is unverified." })
    }

    private final class SVGDelegate: NSObject, XMLParserDelegate {
        var elements: [String] = [], attributes: [String: String] = [:], metadata = ""
        private var inMetadata = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String]) {
            elements.append(elementName); attributes.merge(attributeDict) { _, new in new }
            if elementName == "metadata" { inMetadata = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inMetadata { metadata += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if elementName == "metadata" { inMetadata = false } }
    }
}

private actor ERExportGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        guard !entered else { return }; entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
struct ERDiagramExportPublicationTests {
    @Test func newFilePublicationKeepsPrivatePermissionsAndRefusesExistingOrSymlinkTargets() async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("diagram.svg"), data = Data("synthetic export".utf8)
        let output = try ERDiagramExportFile(destination: destination)
        try await output.publish(data, cancellation: .init(), isCurrent: { true })
        await output.finishOwnership()
        #expect(try Data(contentsOf: destination) == data)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: ERDiagramExportFailure.self) { try ERDiagramExportFile(destination: destination) }
        let link = root.appendingPathComponent("link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: ERDiagramExportFailure.self) { try ERDiagramExportFile(destination: link) }
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test(arguments: [ERDiagramExportPublicationPhase.writing, .beforePublish, .afterPublish])
    func cancellationAtRealChunkBoundariesRemovesOnlyTheOwnedOutput(phase: ERDiagramExportPublicationPhase) async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("diagram.bin"), output = try ERDiagramExportFile(destination: destination)
        let token = ERDiagramExportCancellation(), gate = ERExportGate(), data = Data(repeating: 0x5a, count: 160 * 1_024)
        let task = Task { () -> Bool in
            do {
                try await output.publish(data, cancellation: token, isCurrent: { true }, hook: { item in
                    #expect(!item.workerIsMainThread)
                    if item.phase == phase && item.offset == 65_536 { await gate.pause() }
                }); return true
            } catch { return false }
        }
        try await ERExportFixtures.waitFor { await gate.entered }
        token.cancel(); await gate.release()
        let succeeded = await task.value
        #expect(!succeeded); await output.finishOwnership()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func postRenameReplacementAndSameInodeMutationArePreserved() async throws {
        for replace in [true, false] {
            let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("diagram.bin"), output = try ERDiagramExportFile(destination: destination)
            let token = ERDiagramExportCancellation(), gate = ERExportGate(), data = Data(repeating: 0x61, count: 160 * 1_024)
            let task = Task { () -> Bool in
                do { try await output.publish(data, cancellation: token, isCurrent: { true }, hook: { item in if item.phase == .afterPublish && item.offset == 65_536 { await gate.pause() } }); return true }
                catch { return false }
            }
            try await ERExportFixtures.waitFor { await gate.entered }
            let foreign = Data("external bytes".utf8)
            if replace { try FileManager.default.removeItem(at: destination); try foreign.write(to: destination) }
            else { let file = try FileHandle(forWritingTo: destination); try file.truncate(atOffset: 0); try file.write(contentsOf: foreign); try file.close() }
            token.cancel(); await gate.release()
            let succeeded = await task.value
            #expect(!succeeded); await output.finishOwnership()
            #expect(try Data(contentsOf: destination) == foreign)
        }
    }

    @Test func parentReplacementCannotReceiveThePinnedExport() async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("destination"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("diagram.bin"), output = try ERDiagramExportFile(destination: destination)
        let token = ERDiagramExportCancellation(), gate = ERExportGate(), data = Data(repeating: 0x61, count: 160 * 1_024)
        let task = Task { () -> Bool in
            do { try await output.publish(data, cancellation: token, isCurrent: { true }, hook: { item in if item.phase == .beforePublish && item.offset == 65_536 { await gate.pause() } }); return true }
            catch { return false }
        }
        try await ERExportFixtures.waitFor { await gate.entered }
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let foreign = Data("foreign destination".utf8); try foreign.write(to: destination)
        await gate.release()
        let succeeded = await task.value
        #expect(!succeeded); await output.finishOwnership()
        #expect(try Data(contentsOf: destination) == foreign)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
}

@MainActor
struct ERDiagramExportModelTests {
    @MainActor private final class Context { var current = true; var canStart = true }
    private struct ReadinessChange: Sendable { let emission: Int; let canStart: Bool }
    @MainActor private final class ReadinessObservations {
        var emitted = 0
        var values: [ReadinessChange] = []
    }
    @Test func normalModelRendersARealSVGAndAcknowledgedStopKeepsIt() async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = ERExportFixtures.snapshot(), destination = root.appendingPathComponent("diagram.svg")
        let model = ERDiagramExportModel(documentID: UUID(), profileID: snapshot.tables[0].profileID)
        await model.export(snapshot, format: .svg, options: .init(), to: destination)
        #expect(model.phase == .completed && model.savedURL == destination)
        await model.stop()
        #expect(model.phase == .completed && FileManager.default.fileExists(atPath: destination.path))
        let parser = XMLParser(data: try Data(contentsOf: destination)); #expect(parser.parse())
    }

    @Test(arguments: ["stop", "close", "source"])
    func ownerChangesCancelPausedPublicationWithoutAllowingAnotherExport(action: String) async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = ERExportFixtures.snapshot(), destination = root.appendingPathComponent("diagram.bin"), second = root.appendingPathComponent("second.bin")
        let context = Context(), gate = ERExportGate()
        let model = ERDiagramExportModel(documentID: UUID(), profileID: snapshot.tables[0].profileID, startAllowed: { context.canStart }, available: { context.current })
        let task = Task { await model.export(snapshot, format: .svg, options: .init(), to: destination,
            renderer: { _, _, _ in Data(repeating: 0x5a, count: 160 * 1_024) },
            publicationHook: { item in if item.phase == .beforePublish && item.offset == 65_536 { await gate.pause() } }) }
        try await ERExportFixtures.waitFor { await gate.entered }
        context.canStart = false
        await model.export(snapshot, format: .svg, options: .init(), to: second)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        let close: Task<Void, Never>?
        if action == "stop" { close = Task { await model.stop() } }
        else if action == "close" { close = Task { await model.close() } }
        else { context.current = false; close = nil }
        if action != "source" { try await ERExportFixtures.waitFor { model.phase == .stopping } }
        await gate.release(); await task.value; await close?.value
        #expect(model.phase == (action == "close" ? .closed : .cancelled))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["failure", "sourceCancellation"])
    func cleanupCompletionPublishesRetryReadinessToSubscribers(action: String) async throws {
        let root = try ERExportFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = ERExportFixtures.snapshot(), destination = root.appendingPathComponent("diagram.bin")
        let retry = root.appendingPathComponent("retry.svg"), context = Context()
        let verification = ERExportGate(), cleanup = ERExportGate(), observations = ReadinessObservations()
        let model = ERDiagramExportModel(documentID: UUID(), profileID: snapshot.tables[0].profileID)
        let subscription = model.objectWillChange.sink { [weak model, weak observations] in
            guard let model, let observations else { return }
            let emission = MainActor.assumeIsolated {
                observations.emitted += 1
                return observations.emitted
            }
            // SwiftUI consumes objectWillChange on a later main-actor turn.
            Task { @MainActor in observations.values.append(.init(emission: emission, canStart: model.canStart)) }
        }
        defer { subscription.cancel() }
        let exporting = Task { await model.export(snapshot, format: .svg, options: .init(), to: destination,
            sourceIsCurrent: { context.current }, renderer: { _, _, _ in Data(repeating: 0x61, count: 160 * 1_024) },
            publicationHook: { item in if item.phase == .afterPublish && item.offset == 65_536 { await verification.pause() } },
            cleanupHook: { await cleanup.pause() }) }
        try await ERExportFixtures.waitFor { await verification.entered }
        if action == "failure" {
            // Corrupt an unread chunk so the real post-rename verifier fails.
            let file = try FileHandle(forWritingTo: destination)
            try file.seek(toOffset: 100 * 1_024); try file.write(contentsOf: Data([0x62])); try file.close()
        } else { context.current = false }
        await verification.release()
        try await ERExportFixtures.waitFor { await cleanup.entered }
        try await ERExportFixtures.waitFor { observations.values.last?.canStart == false }
        #expect(model.phase == (action == "failure" ? .failed : .cancelled))
        #expect(!model.canStart && observations.values.last?.canStart == false)
        let beforeRelease = observations.emitted
        await cleanup.release()
        // The subscriber must see readiness without waiting for the export
        // task or accepting a late read of an old, pre-cleanup notification.
        try await ERExportFixtures.waitFor {
            observations.values.contains { $0.emission > beforeRelease && $0.canStart }
        }
        await exporting.value
        await model.export(snapshot, format: .svg, options: .init(), to: retry)
        #expect(model.phase == .completed && FileManager.default.fileExists(atPath: retry.path))
        if action == "failure" {
            let kept = try Data(contentsOf: destination)
            #expect(kept[100 * 1_024] == 0x62)
        } else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
    }
}
