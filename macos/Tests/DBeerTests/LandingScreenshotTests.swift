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

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func capture(_ window: NSWindow, name: String, directory: URL) throws {
        let content = try #require(window.contentView)
        let frame = try #require(content.superview)
        let image = try bitmap(frame)
        // Sheets are separate AppKit windows. Capture only this app's surfaces,
        // placing the real sheet at its actual window coordinates. This avoids
        // Screen Recording access and never captures another app or the desktop.
        if let sheet = window.attachedSheet, let sheetFrame = sheet.contentView?.superview {
            let sheetImage = try bitmap(sheetFrame)
            let context = try #require(NSGraphicsContext(bitmapImageRep: image))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            sheetImage.draw(in: NSRect(x: sheet.frame.minX - window.frame.minX,
                y: sheet.frame.minY - window.frame.minY,
                width: sheet.frame.width, height: sheet.frame.height))
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
        let url = try #require(URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""))
        let directory = URL(fileURLWithPath: try #require(environment["DBEER_QA_OUTPUT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = ConnectionSettings(host: try #require(url.host), port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: try #require(url.user), password: url.password ?? "",
            sslMode: "disable")
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: { _ in .rollback },
            helperFactory: { BackendClient(executableURL: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")) })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Taproom", settings: settings))
        let profile = try #require(workspace.library.selectedConnectionId)
        let query = try #require(workspace.selectedDocument)
        query.profileID = profile
        query.title = "Beer inventory"
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let icon = repository.appendingPathComponent("macos/Resources/AppIconDark.icns")
        application.applicationIconImage = NSImage(contentsOf: icon)
        for name in ["ToolbarIcon", "ToolbarIconDark"] {
            NSImage(contentsOf: repository.appendingPathComponent("macos/Resources/\(name).svg"))?.setName(name)
        }
        let content = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
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
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try capture(window, name: "queries", directory: directory)

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
            for (column, width) in zip(table.tableColumns, [190.0, 215, 130, 130, 130]) { column.width = width }
            policy.apply(to: window)
            window.makeFirstResponder(descendants(content, of: NSTextView.self).first)
            try await settle()
            try capture(window, name: "types", directory: directory)

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
            try capture(window, name: "errors", directory: directory)
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
            try capture(window, name: "execution", directory: directory)
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
            try capture(window, name: "connection", directory: directory)
            workspace.library.isConnectionEditorPresented = false
            try await settle()
            await workspace.shutdown()
        } catch {
            workspace.library.isConnectionEditorPresented = false
            await workspace.shutdown()
            throw error
        }
    }
}
