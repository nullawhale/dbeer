import AppKit
import SwiftUI
import Testing
@testable import DBeer

/// Opt-in captures of production views backed by a disposable PostgreSQL.
/// No saved profiles, user databases, Keychain entries or app preferences are used.
@Suite(.serialized)
@MainActor
struct LandingScreenshotTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "The screenshot scenario did not finish.")
    }

    private func arrangeWorkspace(in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        // Set real divider positions so both appearances show the same useful
        // composition, independent of AppKit's initial split-view sizing.
        for split in descendants(content, of: NSSplitView.self) where split.subviews.count >= 2 {
            let hasCatalog = !descendants(split.subviews[0], of: NSOutlineView.self).isEmpty
            let hasResults = !descendants(split.subviews[0], of: ResultGridTableView.self).isEmpty
            let isSidebar = split.bounds.width > content.bounds.width - 60 && !hasResults
            if split.isVertical && (hasCatalog || isSidebar) {
                split.setPosition(250, ofDividerAt: 0)
            } else if split.isVertical && hasResults {
                split.setPosition(max(220, split.bounds.width - 280), ofDividerAt: 0)
            }
        }
        try await settle()
    }

    private func windowBitmap(_ window: NSWindow) async throws -> NSBitmapImageRep {
        let image = try await NativeOwnedWindowCapture.bitmap(window)
        image.size = try #require(window.contentView?.superview).bounds.size
        return image
    }

    private func capture(_ window: NSWindow, name: String, directory: URL) async throws {
        let image = try await windowBitmap(window)
        // Sheets are separate AppKit windows. Capture only this app's surfaces,
        // placing the real sheet at its actual window coordinates. This avoids
        // Screen Recording access and never captures another app or the desktop.
        if let sheet = window.attachedSheet {
            let sheetImage = try await windowBitmap(sheet)
            let context = try #require(NSGraphicsContext(bitmapImageRep: image))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            sheetImage.draw(in: NSRect(x: sheet.frame.minX - window.frame.minX,
                y: sheet.frame.minY - window.frame.minY,
                width: sheet.frame.width, height: sheet.frame.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func pressDisclosure(in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        let outline = try #require(descendants(content, of: NSOutlineView.self).first)
        try #require(outline.numberOfRows > 0)
        outline.expandItem(outline.item(atRow: 0))
        try await settle()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBEER_CAPTURE_LANDING"] == "1",
                   "Run scripts/capture-screenshots.sh to capture the landing gallery."))
    func captureRealPostgresWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        let appearance = environment["DBEER_CAPTURE_APPEARANCE"] ?? "dark"
        try #require(["light", "dark"].contains(appearance))
        let isDark = appearance == "dark"
        let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        let directory = URL(fileURLWithPath: try #require(environment["DBEER_QA_OUTPUT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: "disable")
        let artifactDirectory = directory.appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }
        let snapshotStore = ResultSnapshotStore(rootURL: artifactDirectory.appendingPathComponent("snapshots"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(),
            sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            resultSnapshots: ResultSnapshotsModel(store: snapshotStore),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshotStore, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .rollback },
            // Only this opt-in runner's disposable fixture SQL is authorized here.
            executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Taproom", settings: settings))
        let profile = try #require(workspace.library.selectedConnectionId)
        let query = try #require(workspace.selectedDocument)
        query.profileID = profile
        query.title = "Beer inventory"
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let icon = repository.appendingPathComponent("macos/Resources/\(isDark ? "AppIconDark" : "AppIcon").icns")
        application.applicationIconImage = NSImage(contentsOf: icon)
        for name in ["ToolbarIcon", "ToolbarIconDark"] {
            NSImage(contentsOf: repository.appendingPathComponent("macos/Resources/\(name).svg"))?.setName(name)
        }
        let content = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace)
            .preferredColorScheme(isDark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        do {
            // All fixture DDL is confined to the disposable database supplied by
            // capture-screenshots.sh. Fail if someone points this at existing data.
            for sql in [
                "CREATE TABLE beers (id integer PRIMARY KEY, name text NOT NULL, style text NOT NULL, abv numeric(3,1), stock integer NOT NULL)",
                """
                INSERT INTO beers VALUES
                  (1, 'Northern Lights', 'IPA', 6.5, 128),
                  (2, 'Velvet Stout', 'Stout', 5.8, 64),
                  (3, 'Golden Hour', 'Pilsner', 4.9, 256),
                  (4, 'Orchard Saison', 'Saison', 6.2, 48),
                  (5, 'Amber Trail', 'Amber Ale', 5.4, 96),
                  (6, 'Cloud Nine', 'Wheat', 4.7, 180),
                  (7, 'Midnight Porter', 'Porter', 6.0, 72),
                  (8, 'Copper Coast', 'Pale Ale', 5.6, 144)
                """,
            ] {
                await workspace.run(query, sql: sql)
                try #require(query.runtime?.result != nil && query.runtime?.queryFailure == nil)
            }
            query.text = """
            SELECT id, name, style, abv, stock
            FROM public.beers
            ORDER BY id;
            """
            await workspace.run(query)
            try #require(query.runtime?.result?.rows?.count == 8)
            try await pressDisclosure(in: window)
            let schema = try #require(workspace.catalogRoots[profile]?.first { $0.name == "public" })
            schema.isExpanded = true
            await workspace.expand(schema)
            let tables = try #require(schema.children?.first { $0.objectKind == "table" })
            tables.isExpanded = true
            await workspace.expand(tables)
            try await settle()
            try await arrangeWorkspace(in: window)
            let inventory = try #require(descendants(content, of: ResultGridTableView.self).first)
            for (column, width) in zip(inventory.tableColumns, [55.0, 180, 120, 75, 75]) { column.width = width }
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try await capture(window, name: "queries", directory: directory)

            let values = workspace.newDocument(profileID: profile, text: """
            SELECT
              9007199254740993::bigint AS batch_id,
              123456789.123456789::numeric AS amount,
              NULL::text AS note,
              ''::text AS empty,
              'NULL'::text AS literal;
            """)
            values.title = "Exact values"
            await workspace.run(values)
            let row = try #require(values.runtime?.result?.rows?.first)
            try #require(row == ["9007199254740993", "123456789.123456789", nil, "", "NULL"])
            try await settle()
            let table = try #require(descendants(content, of: NSTableView.self).first { !($0 is NSOutlineView) })
            try #require(table.numberOfColumns == 5)
            for (column, width) in zip(table.tableColumns, [165.0, 185, 75, 75, 75]) { column.width = width }
            try await arrangeWorkspace(in: window)
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try await capture(window, name: "types", directory: directory)

            let error = workspace.newDocument(profileID: profile, text: """
            SELECT id, name, missing_column
            FROM public.beers
            ORDER BY id;
            """)
            error.title = "SQL diagnostics"
            await workspace.run(error, sql: "BEGIN")
            await workspace.run(error)
            try #require(error.runtime?.queryFailure?.sqlState == "42703")
            try #require(error.runtime?.transactionStatus == .failedTransaction)
            try #require(error.errorPosition != nil)
            try await settle()
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try await capture(window, name: "errors", directory: directory)
            await workspace.run(error, sql: "ROLLBACK")

            let running = workspace.newDocument(profileID: profile, text: """
            -- A slow query to try the Stop button.
            SELECT pg_sleep(20);
            """)
            running.title = "Running query"
            let execution = Task { await workspace.run(running) }
            for _ in 0..<100 where running.runtime?.canStop != true { try await Task.sleep(for: .milliseconds(20)) }
            try #require(running.runtime?.canStop == true)
            try await settle()
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try await capture(window, name: "execution", directory: directory)
            await workspace.stop(running)
            await execution.value
            try #require(running.runtime?.queryFailure?.category == "cancelled")

            workspace.selectedDocumentID = query.id
            workspace.library.isConnectionEditorPresented = true
            try await settle()
            let sheet = try #require(window.attachedSheet)
            try #require(sheet.contentView != nil)
            sheet.makeFirstResponder(nil)
            policy.apply(to: sheet)
            try await settle()
            try await capture(window, name: "connection", directory: directory)
            workspace.library.isConnectionEditorPresented = false
            try await settle()

            try await captureNewFeatures(workspace: workspace, window: window, query: query,
                profile: profile, settings: settings, directory: directory, artifactDirectory: artifactDirectory)
            await workspace.shutdown()
        } catch {
            workspace.library.isConnectionEditorPresented = false
            await workspace.shutdown()
            throw error
        }
    }
    private func captureNewFeatures(workspace: ApplicationWorkspace, window: NSWindow, query: SQLDocument,
                                    profile: UUID, settings: ConnectionSettings, directory: URL,
                                    artifactDirectory: URL) async throws {
        let content = try #require(window.contentView)
        let policy = NativeButtonFocusPolicy()
        // Every new feature uses real production models and this disposable database.
        for document in workspace.documents.filter({ $0.id != query.id }) {
            await workspace.closeDocument(document)
        }
        workspace.sidebarPanel = nil
        let lowStock = workspace.newDocument(profileID: profile, text: """
        SELECT name, stock
        FROM public.beers
        WHERE stock < 100
        ORDER BY stock;
        """)
        lowStock.title = "Low stock"
        await workspace.run(lowStock)
        try #require(lowStock.runtime?.result?.rows?.count == 4)
        try #require(workspace.splitDocument(lowStock.id, direction: .right) != nil)
        let summary = try #require(workspace.selectedDocument)
        summary.title = "Inventory totals"
        summary.text = """
        SELECT count(*) AS beers,
               sum(stock) AS bottles
        FROM public.beers;
        """
        await workspace.run(summary)
        try #require(summary.runtime?.result?.rows?.count == 1)
        try #require(lowStock.runtime?.sessionId != summary.runtime?.sessionId)
        try await settle()
        try await arrangeWorkspace(in: window)
        for grid in descendants(content, of: ResultGridTableView.self) {
            for (column, width) in zip(grid.tableColumns, [165.0, 80]) { column.width = width }
        }
        policy.apply(to: window)
        try await settle()
        try await capture(window, name: "panes", directory: directory)

        workspace.mergePanes()
        workspace.sidebarPanel = .investigations
        let investigation = try #require(await workspace.newInvestigation(title: "Inventory review"))
        let model = try #require(investigation.investigationModel)
        try #require(workspace.addInvestigationMarkdown(investigation, text: """
        # Restocking notes

        Check beers with fewer than 100 bottles before placing the next order.
        Keep the original inventory as an offline baseline alongside this query.
        """) != nil)
        let block = try #require(workspace.addInvestigationSQL(investigation, text: lowStock.text, profileID: profile))
        let snapshot = try #require(workspace.snapshotCapture(for: query))
        let saved = try #require(await workspace.resultSnapshots.save(snapshot))
        try #require(workspace.addInvestigationSnapshot(investigation, snapshotID: saved.id,
            explanation: "Original inventory before the restocking review.") != nil)
        model.selectBlock(block)
        let blockSQL = try #require(model.sqlDocument(for: block))
        await workspace.run(blockSQL)
        try #require(blockSQL.runtime?.result?.rows?.count == 4)
        try #require(await workspace.saveInvestigation(investigation))
        try await settle()
        try await arrangeWorkspace(in: window)
        policy.apply(to: window)
        try await capture(window, name: "investigations", directory: directory)

        // Comparison captures remain opt-in for private design review.
        guard ProcessInfo.processInfo.environment["DBEER_CAPTURE_COMPARISONS"] == "1" else { return }

        workspace.sidebarPanel = .connections
        workspace.selectedDocumentID = query.id
        for sql in [
            "CREATE SCHEMA review",
            "CREATE TABLE review.beers (LIKE public.beers INCLUDING ALL)",
            "INSERT INTO review.beers SELECT * FROM public.beers",
            "UPDATE review.beers SET stock = 160 WHERE id = 1",
            "DELETE FROM review.beers WHERE id = 8",
            "INSERT INTO review.beers VALUES (9, 'Harvest Lager', 'Lager', 5.0, 120)",
        ] {
            await workspace.run(summary, sql: sql)
            try #require(summary.runtime?.queryFailure == nil)
        }
        try #require(await workspace.library.saveConnection(name: "Taproom review", settings: settings))
        let target = try #require(workspace.library.selectedConnectionId)
        let helper = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let data = DataComparisonModel(profiles: workspace.library.savedConnections, resolve: { _, _ in settings },
            factory: { DataComparisonHelperBackend(executableURL: helper, scratchParentURL: artifactDirectory) })
        data.sourceID = profile
        data.targetID = target
        data.sourceTable = .init(schema: "public", name: "beers")
        data.targetTable = .init(schema: "review", name: "beers")
        await data.readMetadata()
        try await waitUntil { data.descriptors != nil || data.error != nil }
        try #require(data.error == nil && data.metadataMatches)
        let columnOrder = ["id", "stock", "name", "style", "abv"]
        data.mappings.sort {
            (columnOrder.firstIndex(of: $0.source) ?? columnOrder.count)
                < (columnOrder.firstIndex(of: $1.source) ?? columnOrder.count)
        }
        let key = try #require(data.mappings.firstIndex { $0.source == "id" })
        data.mappings[key].key = true
        await data.compare()
        try await waitUntil { data.page != nil || data.error != nil }
        try #require(data.error == nil && data.summary?.comparison.changedRows == 1)
        let changed = try #require(data.page?.rows.first { $0.kind == "changed" })
        data.selectRow(changed)
        let changedValue = try #require(changed.cells.first {
            data.capturedMappings[$0.mapping].source == "stock"
        }?.right)
        await data.inspect(changedValue, title: "Target")
        try #require(data.valueChunk != nil)
        workspace.dataComparison = data
        try await settle()
        let dataSheet = try #require(window.attachedSheet)
        dataSheet.setContentSize(NSSize(width: 1160, height: 700))
        policy.apply(to: dataSheet)
        try await settle()
        try await capture(window, name: "comparison", directory: directory)
        await data.close()
        workspace.dataComparison = nil
        try await settle()

        for sql in [
            "ALTER TABLE review.beers ADD COLUMN notes text",
            "ALTER TABLE review.beers ALTER COLUMN stock TYPE bigint",
            "CREATE INDEX beers_style_idx ON review.beers (style)",
        ] {
            await workspace.run(summary, sql: sql)
            try #require(summary.runtime?.queryFailure == nil)
        }
        let structure = SchemaComparisonModel(profiles: workspace.library.savedConnections, resolve: { _ in settings },
            factory: { SchemaComparisonHelperBackend(client: BackendClient(executableURL: helper)) })
        structure.sourceID = profile
        structure.targetID = target
        structure.mappings.schemas = [.init(source: "public", target: "review")]
        await structure.start()
        try await waitUntil { structure.page != nil || structure.error != nil }
        try #require(structure.error == nil && structure.summary?.fullEquality == false)
        try #require((structure.summary?.differenceCount ?? 0) > 0)
        workspace.schemaComparison = structure
        try await settle()
        let schemaSheet = try #require(window.attachedSheet)
        schemaSheet.setContentSize(NSSize(width: 1080, height: 700))
        policy.apply(to: schemaSheet)
        try await settle()
        try await capture(window, name: "schemas", directory: directory)
        await structure.close()
        workspace.schemaComparison = nil
    }

}
