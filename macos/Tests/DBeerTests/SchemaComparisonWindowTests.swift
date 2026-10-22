import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Explicit UI scope: owned synthetic windows, native control actions, no saved
/// credentials, database sessions or global keyboard/mouse automation.
@Suite(.serialized)
@MainActor
struct SchemaComparisonWindowTests {
    private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var text: String {
            let label: String? = value("accessibilityLabel"); let plain: String? = value("accessibilityValue")
            return [label, plain].compactMap { $0 }.joined(separator: " ")
        }
    }
    private func elements(_ window: NSWindow) -> [Element] {
        var result: [Element] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object); result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []; children.forEach(visit)
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        if let content = window.contentView { visit(content) }; return result
    }
    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.identifier == id }, "Missing schema control: \(id)")
    }
    private func press(_ id: String, _ window: NSWindow) throws {
        let item = try element(id, window)
        if let button = (item.object as? NSButton) ?? ((item.object as? NSCell)?.controlView as? NSButton) {
            try #require(button.isEnabled); button.performClick(nil)
        } else { try #require(item.flag("isAccessibilityEnabled", fallback: true) && item.flag("accessibilityPerformPress")) }
    }
    private func waitFor(_ window: NSWindow, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
            if condition() { return }
        } while ContinuousClock.now < deadline
        try #require(condition(), "Schema window controls: \(elements(window).compactMap(\.identifier).sorted())")
    }
    private func host(_ model: SchemaComparisonModel, scheme: ColorScheme, width: CGFloat = 1000, close: @escaping () -> Void = {}) -> NSWindow {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: width, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synthetic schema comparison verification"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: SchemaComparisonView(model: model, close: close).preferredColorScheme(scheme))
        window.makeKeyAndOrderFront(nil); return window
    }
    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"], let content = window.contentView else { return }
        let view = content.superview ?? content; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
    @Test func nativeCompareShowsDirectionDifferencesAndExportInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let profiles = SchemaComparisonTestFixtures.profiles(); let backend = try SchemaComparisonTestBackend()
            var created = 0
            let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { created += 1; return backend })
            let window = host(model, scheme: scheme); defer { window.close() }
            try await waitFor(window) { elements(window).contains { $0.identifier == "schemaCompareStart" } }
            #expect(created == 0 && model.sourceID == nil && model.targetID == nil)
            #expect(!(try element("schemaCompareStart", window)).flag("isAccessibilityEnabled", fallback: true))
            #expect(try element("schemaCompareScope", window).text.contains("Read-only"))
            _ = try element("schemaCompareSource", window); _ = try element("schemaCompareTarget", window)
            try capture(window, name: "schema-config-\(scheme)")
            model.sourceID = profiles[0].id; model.targetID = profiles[1].id
            try await waitFor(window) { (try? element("schemaCompareStart", window).flag("isAccessibilityEnabled")) == true }
            try press("schemaCompareStart", window)
            try await waitFor(window) { model.page != nil && elements(window).contains { $0.identifier == "schemaCompareConclusion" } }
            #expect(created == 1 && model.summary?.fullEquality == false)
            #expect(try element("schemaCompareConclusion", window).text.contains("differences"))
            #expect(try element("schemaCompareDirection", window).text.contains("Source fixture → Target fixture"))
            #expect((try element("schemaCompareExport", window)).flag("isAccessibilityEnabled", fallback: true))
            #expect(window.attachedSheet == nil)
            try capture(window, name: "schema-report-\(scheme)")
            await model.loadPage(collection: "issues")
            #expect(model.page?.issues.isEmpty == true)
            try press("schemaCompareReset", window)
            try await waitFor(window) { !model.hasStarted }
            #expect(created == 1)
            await model.close()
        }
    }
    @Test func stopAndCloseControlsReleaseTheDedicatedHelper() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(); let backend = try SchemaComparisonTestBackend(running: true)
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend })
        model.sourceID = profiles[0].id; model.targetID = profiles[0].id
        var closed = false
        let window = host(model, scheme: .light, width: 780, close: { closed = true }); defer { window.close() }
        try await waitFor(window) { (try? element("schemaCompareStart", window).flag("isAccessibilityEnabled")) == true }
        try press("schemaCompareStart", window)
        try await waitFor(window) { elements(window).contains { $0.identifier == "schemaCompareStop" } }
        try press("schemaCompareStop", window)
        try await waitFor(window) { model.phase == .cancelled }
        #expect(await backend.operations.contains("cancel"))
        try press("schemaCompareClose", window); #expect(closed)
        await model.close()
    }
}
