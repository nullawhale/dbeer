import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

/// Opt-in review of the production comparison sheets with a real helper and a
/// disposable PostgreSQL. Profiles, credentials and workspace state stay in memory.
@Suite(.serialized)
@MainActor
struct ComparisonScreenshotTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "The comparison review did not reach the expected state.")
    }

    private func settle(_ sheet: NSWindow) async throws {
        sheet.contentView?.layoutSubtreeIfNeeded()
        sheet.contentView?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
    }

    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func press(_ identifier: String, in sheet: NSWindow) throws {
        var seen = Set<ObjectIdentifier>()
        var candidates: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if string(object, "accessibilityIdentifier") == identifier { candidates.append(object) }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector),
               let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(visit)
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        if let content = sheet.contentView { visit(content) }
        let item = try #require(candidates.first, "Missing comparison action: \(identifier)")
        if let button = (item as? NSButton) ?? ((item as? NSCell)?.controlView as? NSButton) {
            try #require(button.isEnabled)
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try #require(item.responds(to: selector))
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(item.method(for: selector), to: Action.self)
        try #require(action(item, selector), "The comparison action was not performed.")
    }

    private func capture(_ sheet: NSWindow, name: String, directory: URL) async throws {
        try await settle(sheet)
        let content = try #require(sheet.contentView)
        let frame = content.superview ?? content
        let bitmap: NSBitmapImageRep
        if #available(macOS 14.4, *) {
            let available = try await SCShareableContent.currentProcess
            let ownWindow = try #require(available.windows.first {
                $0.windowID == CGWindowID(sheet.windowNumber)
                    && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }, "The production comparison sheet was not available for capture.")
            let configuration = SCStreamConfiguration()
            configuration.width = Int(frame.bounds.width * 2)
            configuration.height = Int(frame.bounds.height * 2)
            configuration.scalesToFit = true
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            bitmap = NSBitmapImageRep(cgImage: image)
        } else {
            bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
            }
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func textIsVisible(_ fragment: String, in sheet: NSWindow) -> Bool {
        guard let content = sheet.contentView else { return false }
        return descendants(content, of: NSTextView.self).contains { $0.string.contains(fragment) }
    }

    private func requireVisibleDiffGlyphs(in sheet: NSWindow) throws {
        let content = try #require(sheet.contentView)
        let panes = descendants(content, of: NSTextView.self).filter {
            ["Source value", "Target value"].contains(string($0, "accessibilityLabel") ?? "")
        }
        try #require(panes.count == 2, "Expected both native diff text panes.")
        for pane in panes {
            let container = try #require(pane.textContainer)
            let layout = try #require(pane.layoutManager)
            layout.ensureLayout(for: container)
            let glyphs = layout.usedRect(for: container).offsetBy(dx: pane.textContainerOrigin.x, dy: pane.textContainerOrigin.y)
            try #require(!pane.string.isEmpty && layout.numberOfGlyphs > 0 && !glyphs.isEmpty && glyphs.intersects(pane.visibleRect),
                         "Diff glyph geometry: characters=\(pane.string.utf16.count), glyphs=\(layout.numberOfGlyphs), used=\(glyphs), visible=\(pane.visibleRect)")
        }
    }

    private func requireSQLDiff(in sheet: NSWindow, qualifiedTable: String) throws {
        let content = try #require(sheet.contentView)
        let panes = descendants(content, of: NSTextView.self).filter {
            ["Source value", "Target value"].contains(string($0, "accessibilityLabel") ?? "")
        }
        try #require(panes.count == 2, "Expected both native SQL diff panes.")
        for pane in panes {
            try #require(pane.string.contains("CREATE TABLE \(qualifiedTable)"),
                         "Schema comparisons should display SQL definitions in both panes.")
            try #require(!pane.string.contains("\"state\":"), "Raw metadata should stay in technical details.")
            let storage = try #require(pane.textStorage)
            let keyword = (pane.string as NSString).range(of: "CREATE TABLE")
            try #require(keyword.location != NSNotFound)
            try #require(storage.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor == SQLSyntaxPalette.keyword,
                         "SQL keywords should use the native syntax palette.")
            var hasChangedFragment = false
            storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value is NSColor && range.length > 0 { hasChangedFragment = true }
            }
            try #require(hasChangedFragment, "SQL diff panes should retain highlighted changed fragments.")
            try #require(pane.layoutManager?.showsInvisibleCharacters == false,
                         "SQL definitions should hide whitespace markers.")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEER_CAPTURE_COMPARISON_REVIEW"] == "1",
                   "Opt-in real PostgreSQL comparison sheet screenshots."))
    func captureRealComparisonSheets() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scope = environment["DBEER_CAPTURE_COMPARISON_SCOPE"] ?? "all"
        try #require(["all", "schema"].contains(scope))
        let schemaOnly = scope == "schema"
        try #require(environment["DBEER_REQUIRE_POSTGRES"] == "1", "Use scripts/test-postgres.sh for this disposable database scenario.")
        let dsn = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        let host = try #require(dsn.host)
        try #require(["127.0.0.1", "localhost", "::1"].contains(host))
        let appearance = environment["DBEER_CAPTURE_APPEARANCE"] ?? "dark"
        try #require(["light", "dark"].contains(appearance))
        let isDark = appearance == "dark"
        let directory = URL(fileURLWithPath: try #require(environment["DBEER_QA_OUTPUT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifacts = directory.appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let helper = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let settings = ConnectionSettings(host: host, port: dsn.port ?? 5432,
            database: String(dsn.path.dropFirst()), user: try #require(dsn.user), password: dsn.password ?? "", sslMode: "disable")
        let snapshots = ResultSnapshotStore(rootURL: artifacts.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback },
            // This opt-in test writes only its new disposable fixture schemas.
            executionDecision: { _ in true }, helperFactory: { BackendClient(executableURL: helper) })
        await workspace.start()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(isDark ? .dark : .light))
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        do {
            try #require(await workspace.library.saveConnection(name: "Taproom source", settings: settings))
            let source = try #require(workspace.library.selectedConnectionId)
            try #require(await workspace.library.saveConnection(name: "Taproom target", settings: settings))
            let target = try #require(workspace.library.selectedConnectionId)
            let document = try #require(workspace.selectedDocument)
            document.profileID = source
            document.title = "Comparison review"
            let sourceSchema = "taproom_source", targetSchema = "taproom_target"
            for sql in [
                "CREATE SCHEMA \(sourceSchema)",
                "CREATE SCHEMA \(targetSchema)",
                "CREATE TABLE \(sourceSchema).beers (id integer PRIMARY KEY, name text NOT NULL, style text NOT NULL, stock integer NOT NULL, notes text)",
                "CREATE TABLE \(targetSchema).beers (LIKE \(sourceSchema).beers INCLUDING ALL)",
                "INSERT INTO \(sourceSchema).beers VALUES (1, 'Northern Lights IPA', 'IPA', 128, E'Autumn release\\nDry hopping: Citra and Mosaic\\nPackaging: 330 ml cans\\nStatus: Ready for dispatch'), (2, 'Velvet Stout', 'Stout', 64, 'Roasted malt'), (3, 'Orchard Saison', 'Saison', 48, 'Seasonal batch')",
                "INSERT INTO \(targetSchema).beers SELECT * FROM \(sourceSchema).beers",
                "UPDATE \(targetSchema).beers SET name = 'Northern Lights Double IPA', stock = 160, notes = E'Autumn release\\nDry hopping: Citra, Mosaic and Galaxy\\nPackaging: 440 ml cans\\nStatus: Limited reserve' WHERE id = 1",
                "DELETE FROM \(targetSchema).beers WHERE id = 3",
                "INSERT INTO \(targetSchema).beers VALUES (4, 'Harvest Lager', 'Lager', 120, 'New arrival')",
            ] {
                await workspace.run(document, sql: sql)
                try #require(document.runtime?.queryFailure == nil && document.runtime?.result != nil, "The disposable comparison fixtures could not be prepared.")
            }
            document.text = "SELECT id, name, stock FROM \(sourceSchema).beers ORDER BY id;"
            await workspace.run(document)
            try #require(document.runtime?.queryFailure == nil)

            if !schemaOnly {
                let data = DataComparisonModel(profiles: workspace.library.savedConnections, resolve: { _, _ in settings },
                    factory: { DataComparisonHelperBackend(executableURL: helper, scratchParentURL: artifacts) })
                data.sourceID = source; data.targetID = target
                data.sourceTable = .init(schema: sourceSchema, name: "beers")
                data.targetTable = .init(schema: targetSchema, name: "beers")
                await data.readMetadata()
                try await waitUntil { data.error != nil || data.descriptors != nil && !data.isWorking }
                try #require(data.error == nil && data.metadataMatches, "Metadata: \(data.error ?? "selection mismatch")")
                let key = try #require(data.mappings.firstIndex { $0.source == "id" })
                data.mappings[key].key = true
                workspace.dataComparison = data
                try await waitUntil { window.attachedSheet != nil }
                let dataSheet = try #require(window.attachedSheet)
                dataSheet.setContentSize(NSSize(width: 1160, height: 780))
                dataSheet.makeFirstResponder(nil)
                try await capture(dataSheet, name: "data-setup", directory: directory)
                try press("dataCompareStart", in: dataSheet)
                try await waitUntil { data.error != nil || data.page != nil && data.diff != nil }
                try #require(data.error == nil && data.summary?.comparison.complete == true)
                try #require(data.summary?.comparison.changedRows == 1 && data.summary?.comparison.deletedRows == 1 && data.summary?.comparison.addedRows == 1)
                let changed = try #require(data.page?.rows.first { $0.kind == "changed" })
                if data.selectedRow?.index != changed.index { data.selectRow(changed) }
                let notesMapping = try #require(data.capturedMappings.firstIndex { $0.source == "notes" })
                try await settle(dataSheet)
                try press("dataCompareCell-\(notesMapping)", in: dataSheet)
                try await waitUntil {
                    data.error != nil || data.selectedCell?.mapping == notesMapping && data.diff != nil
                        && textIsVisible("Dry hopping: Citra and Mosaic", in: dataSheet)
                        && textIsVisible("Dry hopping: Citra, Mosaic and Galaxy", in: dataSheet)
                }
                try #require(data.error == nil && data.diff?.lines.contains { $0.kind == .changed } == true)
                try await settle(dataSheet)
                try requireVisibleDiffGlyphs(in: dataSheet)
                try await capture(dataSheet, name: "data-diff", directory: directory)
                await data.close()
                workspace.dataComparison = nil
                try await waitUntil { window.attachedSheet == nil }
            }

            for sql in [
                "ALTER TABLE \(targetSchema).beers ALTER COLUMN stock TYPE bigint",
                "ALTER TABLE \(targetSchema).beers ADD COLUMN tasting_notes text",
                "CREATE INDEX beers_style_idx ON \(targetSchema).beers (style)",
            ] {
                await workspace.run(document, sql: sql)
                try #require(document.runtime?.queryFailure == nil, "The disposable schema differences could not be prepared.")
            }
            let schema = SchemaComparisonModel(profiles: workspace.library.savedConnections, resolve: { _ in settings },
                factory: { SchemaComparisonHelperBackend(client: BackendClient(executableURL: helper)) })
            schema.sourceID = source; schema.targetID = target
            schema.mappings.schemas = [.init(source: sourceSchema, target: targetSchema)]
            workspace.schemaComparison = schema
            try await waitUntil { window.attachedSheet != nil }
            let schemaSheet = try #require(window.attachedSheet)
            schemaSheet.setContentSize(NSSize(width: 1160, height: 780))
            schemaSheet.makeFirstResponder(nil)
            if !schemaOnly { try await capture(schemaSheet, name: "schema-setup", directory: directory) }
            try press("schemaCompareStart", in: schemaSheet)
            try await waitUntil { schema.error != nil || schema.page != nil && schema.diff != nil }
            try #require(schema.error == nil && schema.summary?.fullEquality == false)
            try #require(schema.selectedDifference?.sourceRef?.name == "stock" && schema.selectedDifference?.property.contains("type") == true,
                         "The schema review should select the changed stock type.")
            try await waitUntil {
                (textIsVisible("integer", in: schemaSheet) || textIsVisible("int4", in: schemaSheet))
                    && (textIsVisible("bigint", in: schemaSheet) || textIsVisible("int8", in: schemaSheet))
            }
            try #require(schema.diff?.lines.contains { $0.kind == .changed } == true)
            try await settle(schemaSheet)
            try requireVisibleDiffGlyphs(in: schemaSheet)
            try requireSQLDiff(in: schemaSheet, qualifiedTable: "\"\(targetSchema)\".\"beers\"")
            try await capture(schemaSheet, name: "schema-diff", directory: directory)
            await schema.close()
            workspace.schemaComparison = nil
            await workspace.shutdown()
        } catch {
            await workspace.shutdown()
            throw error
        }
    }
}
