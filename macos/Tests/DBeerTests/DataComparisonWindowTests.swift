import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Explicit UI scope: owned synthetic windows, native control actions, no saved
/// credentials, database sessions or global keyboard/mouse automation.
@Suite(.serialized)
@MainActor
struct DataComparisonWindowTests {
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
        try #require(elements(window).first { $0.identifier == id }, "Missing data control: \(id)")
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        try await waitFor(window) { elements(window).contains { $0.identifier == id && $0.flag("isAccessibilityEnabled", fallback: true) } }
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
        try #require(condition(), "Data window controls: \(elements(window).compactMap(\.identifier).sorted())")
    }
    private func host(_ model: DataComparisonModel, scheme: ColorScheme, width: CGFloat = 1160, close: @escaping () -> Void = {}) -> NSWindow {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: width, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synthetic data comparison verification"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: DataComparisonView(model: model, close: close).preferredColorScheme(scheme))
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
    @Test func nativeMetadataKeySelectionPartialReportAndExactValuesInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let profiles = DataComparisonTestFixtures.profiles(), backend = try DataComparisonTestBackend()
            var created = 0
            let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { created += 1; return backend })
            let window = host(model, scheme: scheme); defer { window.close() }
            try await waitFor(window) { elements(window).contains { $0.identifier == "dataCompareDescribe" } }
            #expect(created == 0 && model.sourceLimit == 10_000 && model.targetLimit == 10_000)
            #expect(!(try element("dataCompareStart", window)).flag("isAccessibilityEnabled", fallback: true))
            DataComparisonTestFixtures.configure(model, profiles)
            try await waitFor(window) { (try? element("dataCompareDescribe", window).flag("isAccessibilityEnabled")) == true }
            #expect(created == 0)
            try await press("dataCompareDescribe", window)
            try await waitFor(window) { model.descriptors != nil && !model.isWorking && elements(window).contains { $0.identifier == "dataCompareKey-0" } }
            #expect(created == 1 && model.mappings.allSatisfy { !$0.key })
            #expect(!(try element("dataCompareStart", window)).flag("isAccessibilityEnabled", fallback: true))
            #expect(try element("dataCompareOriginalsNotice", window).text.contains("Excluded columns are retained"))
            try capture(window, name: "data-config-\(scheme)")
            try await press("dataCompareKey-0", window)
            model.sourceLimit = 3; model.targetLimit = 3
            try await waitFor(window) { model.canCompare && (try? element("dataCompareStart", window).flag("isAccessibilityEnabled")) == true }
            try await press("dataCompareStart", window)
            try await waitFor(window) { model.page != nil && elements(window).contains { $0.identifier == "dataCompareInspect-source-value" } }
            #expect(created == 2 && model.summary?.comparison.complete == false)
            #expect(try element("dataCompareConclusion", window).text.contains("Partial capture"))
            #expect(try element("dataCompareDirection", window).text.contains("Source fixture → Target fixture"))
            try await press("dataCompareInspect-source-value", window)
            try await waitFor(window) { model.valueChunk != nil && elements(window).contains { $0.identifier == "dataCompareNextValue" } }
            #expect(model.valueChunk?.text == "9007199254740993.123456789")
            try capture(window, name: "data-report-\(scheme)")
            try await press("dataCompareNextColumns", window)
            try await waitFor(window) { model.selectedRow?.cellOffset == 2 }
            try await press("dataCompareInspect-source-binary", window)
            try await waitFor(window) { model.valueChunk?.valueRef == "source-binary" && elements(window).contains { $0.identifier == "dataCompareBinaryValue" } }
            #expect(model.valueChunk?.text == "AP8=")
            try await press("dataCompareReset", window)
            try await waitFor(window) { model.summary == nil && model.phase == .closed }
            #expect(created == 2)
            await model.close()
        }
    }
    @Test func nativeStopAndUTF8ChunkPagingRemainBounded() async throws {
        let profiles = DataComparisonTestFixtures.profiles(), backend = try DataComparisonTestBackend()
        let data = Data((String(repeating: "x", count: 65_535) + "🌍tail").utf8)
        await backend.setLargeValue(data)
        let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { backend })
        DataComparisonTestFixtures.configure(model, profiles)
        let window = host(model, scheme: .dark); defer { window.close() }
        await model.readMetadata(); try await waitFor(window) { model.descriptors != nil && !model.isWorking }
        model.mappings[0].key = true; model.sourceLimit = 3; model.targetLimit = 3
        try await waitFor(window) { (try? element("dataCompareStart", window).flag("isAccessibilityEnabled")) == true }
        try await press("dataCompareStart", window)
        try await waitFor(window) { elements(window).contains { $0.identifier == "dataCompareInspect-source-value" } }
        try await press("dataCompareInspect-source-value", window)
        try await waitFor(window) { model.valueChunk != nil && elements(window).contains { $0.identifier == "dataCompareNextValue" } }
        #expect(model.valueText?.trailingBytes == 1 && model.valueText?.text.contains("�") == false)
        try await press("dataCompareNextValue", window)
        try await waitFor(window) { model.valueChunk?.offset != 0 }
        #expect(model.valueText?.text.contains("🌍") == true)
        await model.reset()
        await backend.setRunning(true)
        try await waitFor(window) { (try? element("dataCompareStart", window).flag("isAccessibilityEnabled")) == true }
        try await press("dataCompareStart", window)
        try await waitFor(window) { elements(window).contains { $0.identifier == "dataCompareStop" } }
        try await press("dataCompareStop", window)
        try await waitFor(window) { model.phase == .cancelled && !model.isStopping }
        #expect(await backend.operations.contains("cancel"))
        await model.close()
    }
}
