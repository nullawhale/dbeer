import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Explicitly authorized UI coverage in private synthetic windows. It uses
/// native accessibility actions and no global keyboard/mouse automation.
@Suite(.serialized)
@MainActor
struct ResultComparisonUIIntegrationTests {
    private struct Element {
        var object: NSObject
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
            let label: String? = value("accessibilityLabel")
            let value: String? = self.value("accessibilityValue")
            return [label, value].compactMap { $0 }.joined(separator: " ")
        }
    }
    private func elements(_ window: NSWindow) -> [Element] {
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: AnyObject) {
            guard seen.insert(ObjectIdentifier(value)).inserted else { return }
            if let object = value as? NSObject {
                let element = Element(object: object)
                result.append(element)
                let children: [Any] = element.value("accessibilityChildren") ?? []
                children.forEach { visit($0 as AnyObject) }
            }
            if let view = value as? NSView { view.subviews.forEach { visit($0) } }
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        return result
    }
    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.identifier == id }, "Missing comparison control: \(id)")
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        let item = try element(id, window)
        let button = (item.object as? NSButton) ?? ((item.object as? NSCell)?.controlView as? NSButton)
        if let button, button.isEnabled { button.performClick(nil) }
        else { try #require(item.flag("isAccessibilityEnabled", fallback: true) && item.flag("accessibilityPerformPress")) }
        try await Task.sleep(for: .milliseconds(100))
    }
    private func waitFor(_ window: NSWindow, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Comparison window identifiers: \(elements(window).compactMap(\.identifier).sorted())")
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func nativeControlsExposeExplicitMatchingPartialResultsWideRowsAndExactChunks() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store, columns: 4, partial: true)
        let source = String(repeating: "x", count: 65_535) + "🌍" + String(repeating: "y", count: 10_000)
        var row = ResultComparisonTestFixtures.row(columns: 4)
        row.cells[0].right = ResultComparisonTestFixtures.preview(source, ref: "ui-exact")
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(complete: false),
            rows: [row], values: ["ui-exact": source], cellPageSize: 2)
        var helperStarts = 0
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: {
            helperStarts += 1; return service
        })
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 1160, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synthetic result comparison verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResultComparisonView(model: model).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await waitFor(window) { elements(window).contains { $0.identifier == "startResultComparison" } }
        #expect(helperStarts == 0 && model.leftID == nil && model.rightID == nil)
        #expect(!(try element("startResultComparison", window)).flag("isAccessibilityEnabled", fallback: true))
        await model.configure(left: snapshots[0].id, right: snapshots[1].id)
        model.setMode(.rowOrder)
        try await waitFor(window) { elements(window).contains { $0.identifier == "comparisonRowOrderWarning" } }
        #expect(helperStarts == 0)
        #expect(try element("comparisonLeftPartial", window).text.contains("Partial snapshot"))
        #expect(try element("comparisonRightPartial", window).text.contains("Partial snapshot"))
        try await press("startResultComparison", window)
        #expect(helperStarts == 1 && model.phase == .running)
        await model.pollNow()
        try await waitFor(window) { elements(window).contains { $0.identifier == "comparisonWideRowNotice" } }
        #expect(try element("comparisonConclusion", window).text.contains("Partial inputs"))
        try await press("comparisonNextColumns", window)
        #expect(model.selectedRow?.cells.map(\.mapping) == [2, 3])
        try await press("comparisonPreviousColumns", window)
        try await press("comparisonInspect-ui-exact", window)
        try await waitFor(window) { model.valueChunk != nil && elements(window).contains { $0.identifier == "comparisonValueUTF8Boundary" } }
        #expect(model.valueTextWindow?.trailingBytes == 1)
        try await press("comparisonNextValueChunk", window)
        #expect(model.valueTextWindow?.text.contains("🌍") == true)
        try await press("resetResultComparison", window)
        try await waitFor(window) { model.phase == .idle && model.summary == nil }
        #expect(helperStarts == 1)
        #expect(await service.operations.contains("cancel"))
        #expect(await service.operations.contains("close"))
        await model.close()
        #expect(model.phase == .closed)
    }

    @Test func nativeStopControlCancelsAnAdmittedJobWithoutKeyboardOrMouseEvents() async throws {
        let root = ResultComparisonTestFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResultSnapshotStore(rootURL: root)
        let snapshots = try await ResultComparisonTestFixtures.snapshots(store)
        let service = ResultComparisonTestBackend(summary: ResultComparisonTestFixtures.summary(), rows: [])
        let model = ResultComparisonModel(store: store, snapshots: snapshots, pollDelay: .seconds(60), backendFactory: { service })
        await ResultComparisonTestFixtures.configure(model, snapshots: snapshots)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1160, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResultComparisonView(model: model).preferredColorScheme(.light))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await waitFor(window) { elements(window).contains { $0.identifier == "startResultComparison" } }
        try await press("startResultComparison", window)
        try await waitFor(window) { elements(window).contains { $0.identifier == "stopResultComparison" } }
        try await press("stopResultComparison", window)
        try await waitFor(window) { model.phase == .cancelled }
        #expect(await service.operations.suffix(2) == ["cancel", "close"])
        #expect(await service.shutdowns >= 1)
        await model.close()
    }
}
