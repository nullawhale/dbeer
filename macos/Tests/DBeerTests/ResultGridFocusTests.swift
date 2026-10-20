import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ResultGridFocusTests {
    @MainActor private final class MenuSample {
        let menu: NSMenu
        let table: ResultGridTableView
        var sampled = false

        init(menu: NSMenu, table: ResultGridTableView) {
            self.menu = menu
            self.table = table
        }
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func activate(_ window: NSWindow) async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 {
            if application.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(25))
            window.makeKey()
        }
        try #require(application.isActive && window.isKeyWindow)
        // Let dismissal and activation events settle before opening the next
        // contextual menu; an old closing event can otherwise cancel it.
        try await Task.sleep(for: .milliseconds(75))
    }

    private func press(_ identifier: String, in root: NSView) throws {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let object = object as? NSObject {
                let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
                if object.responds(to: identifierSelector),
                   object.perform(identifierSelector)?.takeUnretainedValue() as? String == identifier { return object }
                let childrenSelector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: childrenSelector),
                   let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
                    for child in children { if let found = find(child as AnyObject) { return found } }
                }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        let element = try #require(find(root))
        let nativeButton = (element as? NSButton) ?? ((element as? NSCell)?.controlView as? NSButton)
        if let nativeButton {
            #expect(nativeButton.isEnabled)
            nativeButton.performClick(nil)
        } else {
            let press = NSSelectorFromString("accessibilityPerformPress")
            try #require(element.responds(to: press))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            #expect(unsafeBitCast(element.method(for: press), to: Action.self)(element, press))
        }
    }

    @Test func cellEditorKeepsTypingSelectionAndStagingWithAmberFocus() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let document = SQLDocument()
        let column = ResultColumn(index: 0, name: "value", typeOid: 25, nativeType: "text")
        let grid = GridDraft(reference: TableReference(schema: "public", name: "fixture", kind: "table"),
            result: BackendMessage(type: "query.result", requestId: "fixture", columns: [column], rows: [["original"]]),
            metadata: [["name": "value", "nativeType": "text", "primaryKey": "1", "editable": "true"]])
        let host = NSHostingView(rootView: DataGridView(document: document, workspace: workspace, grid: grid))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await activate(window)
        let policy = NativeButtonFocusPolicy()
        policy.start()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(descendants(host, of: ResultGridTableView.self).first)
        let cell = table.frameOfCell(atColumn: 0, row: 0)
        let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
        let expand = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: expand)
        try await Task.sleep(for: .milliseconds(150))
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        defer { if window.attachedSheet === sheet { window.endSheet(sheet) } }
        try await activate(sheet)
        let editor = try #require(descendants(content, of: NSTextView.self).first { $0.isEditable && !$0.isFieldEditor })
        #expect(sheet.makeFirstResponder(editor))
        try await Task.sleep(for: .milliseconds(50))
        policy.apply(to: sheet)
        #expect(editor.focusRingType == .none)
        #expect(editor.textContainerInset == NSSize(width: 4, height: 4))
        #expect(editor.textContainer?.lineFragmentPadding == 0)
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.focusRingType == .none)
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            sheet.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(50))
            content.layoutSubtreeIfNeeded()
            let rect = scroll.convert(scroll.bounds, to: content).insetBy(dx: -3, dy: -3).intersection(content.bounds)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: rect))
            content.cacheDisplay(in: rect, to: bitmap)
            var bluePixels = 0
            var amberPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.blueComponent > color.redComponent + 0.2 &&
                        color.blueComponent > color.greenComponent + 0.1 { bluePixels += 1 }
                    if color.redComponent > color.blueComponent + 0.2 &&
                        color.greenComponent > color.blueComponent + 0.1 { amberPixels += 1 }
                }
            }
            #expect(bluePixels == 0, "Unexpected blue cell editor focus border in \(theme)")
            #expect(amberPixels > 0, "Focused cell editor must keep a visible amber border in \(theme)")
            if let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: destination.appendingPathComponent("grid-cell-editor-focus-\(theme).png"))
            }
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("staged value", replacementRange: editor.selectedRange())
        let selection = NSRange(location: 0, length: 6)
        editor.setSelectedRange(selection)
        #expect(editor.string == "staged value")
        #expect(editor.selectedRange() == selection)
        #expect(grid.pendingCount == 0)

        try press("stageGridCellChange", in: content)
        try await Task.sleep(for: .milliseconds(100))
        #expect(grid.value(row: 0, column: 0) == ChangeValue(kind: "text", value: "staged value"))
        #expect(grid.pendingCount == 1)
        await workspace.shutdown()
        _ = policy
    }

    @Test func resultSelectionAndContextMenusKeepAmberBordersInBothAppearances() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: NSPasteboard.Name("dev.dbeer.tests.grid-focus.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let coordinator = ResultTableView.Coordinator(pasteboard: board)
        let scroll = coordinator.makeScrollView()
        coordinator.update(columns: [ResultColumn(index: 0, name: "value", typeOid: 25)],
            rows: [["one"], ["two"]], in: scroll)
        let table = try #require(scroll.documentView as? ResultGridTableView)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        try await activate(window)
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.focusRingType == .none)
        #expect(table.focusRingType == .none)
        #expect(window.makeFirstResponder(table))

        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            for (click, type, modifiers) in [
                ("right", NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                ("control", .leftMouseDown, .control),
            ] {
                try await activate(window)
                let cell = table.frameOfCell(atColumn: 0, row: 0)
                let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let menu = try #require(table.menu(for: event))
                let selection = try #require(table.cellSelection)
                let sample = MenuSample(menu: menu, table: table)
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        defer { sample.menu.cancelTrackingWithoutAnimation() }
                        do {
                            let rect = sample.table.rect(ofRow: 0).insetBy(dx: -3, dy: -3).intersection(sample.table.bounds)
                            let bitmap = try #require(sample.table.bitmapImageRepForCachingDisplay(in: rect))
                            sample.table.cacheDisplay(in: rect, to: bitmap)
                            var bluePixels = 0
                            var amberPixels = 0
                            for y in 0..<bitmap.pixelsHigh {
                                for x in 0..<bitmap.pixelsWide {
                                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                    if color.blueComponent > color.redComponent + 0.2 &&
                                        color.blueComponent > color.greenComponent + 0.1 { bluePixels += 1 }
                                    if color.redComponent > color.blueComponent + 0.2 &&
                                        color.greenComponent > color.blueComponent + 0.1 { amberPixels += 1 }
                                }
                            }
                            #expect(bluePixels == 0, "Unexpected blue grid border in \(theme) during \(click)-click")
                            #expect(amberPixels > 0, "Grid selection must stay visible in \(theme)")
                            if let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                                try bitmap.representation(using: .png, properties: [:])?.write(
                                    to: destination.appendingPathComponent("grid-context-menu-\(theme)-\(click).png"))
                            }
                            sample.menu.performActionForItem(at: 2)
                            sample.sampled = true
                        } catch { Issue.record(error) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
                NSMenu.popUpContextMenu(sample.menu, with: event, for: table)
                timer.invalidate()
                #expect(sample.sampled)
                #expect(table.cellSelection == selection)
                #expect(board.string(forType: .string) == "one")
                #expect(table.focusRingType == .none)
            }
        }
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        #expect(table.cellSelection?.focus == ResultGridCell(row: 1, column: 0))
    }
}
