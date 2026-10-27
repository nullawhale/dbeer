import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DBeer

private final class R27NativeActionWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() { lock.lock(); finished = true; lock.unlock() }
    func failIfPending() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        FileHandle.standardError.write(Data("R27 native action exceeded its 20-second deadline; failing the UI test host.\n".utf8))
        Darwin._exit(70)
    }
}

actor SynchronizationWindowSchemaBackend: SchemaComparisonBackend {
    let base: SynchronizationSchemaBackend
    init() throws { base = try SynchronizationSchemaBackend() }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { try await base.start(request) }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        var response = try await base.request(operation, request)
        if operation == "plan", let first = response.plan?.steps.first {
            response.plan?.steps.insert(.init(id: "dependent", title: "Add dependent index", sql: "CREATE INDEX fixture_note ON target.orders (note);", destructive: false, manual: false, reason: "", dependsOn: [first.id], selected: true), at: 1)
        }
        return response
    }
    func shutdown() async { await base.shutdown() }
}

/// Explicitly requested native UI acceptance: owned windows and save panels,
/// native control/key-equivalent actions, synthetic helpers and private files.
@Suite(.serialized)
@MainActor
struct SynchronizationPlanWindowTests {
    private final class ApprovedSaveDestination: NSObject, NSOpenSavePanelDelegate {
        let allowed: Set<URL>
        private(set) var validations = 0
        init(allowed: [URL]) { self.allowed = Set(allowed.map(\.standardizedFileURL)) }
        func panel(_ sender: Any, validate url: URL) throws {
            let approved = allowed.contains(url.standardizedFileURL)
            FileHandle.standardError.write(Data("R27 Save delegate: allowed=\(approved), name=\(url.lastPathComponent), parent=\(url.deletingLastPathComponent().lastPathComponent)\n".utf8))
            guard approved else { throw CocoaError(.fileWriteNoPermission) }
            validations += 1
        }
    }

    private struct Element {
        let object: NSObject
        func legacy<T>(_ attribute: String) -> T? {
            let namesSelector = NSSelectorFromString("accessibilityAttributeNames")
            let valueSelector = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: namesSelector), object.responds(to: valueSelector),
                  let names = object.perform(namesSelector)?.takeUnretainedValue() as? [String], names.contains(attribute) else { return nil }
            return object.perform(valueSelector, with: attribute)?.takeUnretainedValue() as? T
        }
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            let modern = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
            if let string = modern as? String, !string.isEmpty { return modern }
            if let children = modern as? [NSObject], !children.isEmpty { return modern }
            let attributes = ["accessibilityIdentifier": "AXIdentifier", "accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole", "accessibilityLabel": "AXTitle", "accessibilityValue": "AXValue"]
            if let attribute = attributes[name], let fallback: T = legacy(attribute) { return fallback }
            if name == "accessibilityLabel", let description: T = legacy("AXDescription") { return description }
            return modern
        }
        func press() -> Bool {
            if flag("accessibilityPerformPress") { return true }
            let namesSelector = NSSelectorFromString("accessibilityActionNames")
            let actionSelector = NSSelectorFromString("accessibilityPerformAction:")
            guard object.responds(to: namesSelector), object.responds(to: actionSelector),
                  let actions = object.perform(namesSelector)?.takeUnretainedValue() as? [String], actions.contains("AXPress") else { return false }
            typealias Action = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(object.method(for: actionSelector), to: Action.self)(object, actionSelector, "AXPress" as NSString)
            return true
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var role: String? { value("accessibilityRole") }
        var label: String? { value("accessibilityLabel") }
        var text: String {
            let label: String? = value("accessibilityLabel"), plain: String? = value("accessibilityValue")
            return [label, plain].compactMap { $0 }.joined(separator: " ")
        }
        var enabled: Bool {
            let legacyEnabled: NSNumber? = legacy("AXEnabled")
            return legacyEnabled?.boolValue ?? (object as? NSButton)?.isEnabled ?? flag("isAccessibilityEnabled", fallback: true)
        }
        var selected: Bool {
            if let button = object as? NSButton { return button.state == .on }
            let number: NSNumber? = value("accessibilityValue")
            if let number { return number.intValue == 1 }
            let string: String? = value("accessibilityValue")
            return string == "1"
        }
    }
    private func elements(_ window: NSWindow) -> [Element] {
        var result: [Element] = []; var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let item = Element(object: object); result.append(item)
            let children: [NSObject] = item.value("accessibilityChildren") ?? []; children.forEach(visit)
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(window)
        if let content = window.contentView { visit(content) }; return result
    }
    private func find(_ id: String, _ window: NSWindow) -> Element? { elements(window).first { $0.identifier == id } }
    private func element(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(find(id, window), "Missing synchronization control: \(id)")
    }
    private func nativeAction(_ action: @escaping @MainActor () throws -> Void) async throws {
        // Dispatch native actions in the run-loop modes used by panels and event
        // tracking. Objective-C exceptions can bypass Swift error handling, so a
        // lost continuation must fail the host instead of leaving verification hung.
        let watchdog = R27NativeActionWatchdog()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { watchdog.failIfPending() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            RunLoop.main.perform(inModes: [.default, .common, .modalPanel, .eventTracking]) {
                let result = MainActor.assumeIsolated { Result { try action() } }
                watchdog.finish()
                continuation.resume(with: result)
            }
        }
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        try await waitFor(window) { elements(window).contains { $0.identifier == id && $0.enabled } }
        let item = try element(id, window)
        try await nativeAction {
            if let button = (item.object as? NSButton) ?? ((item.object as? NSCell)?.controlView as? NSButton) {
                try #require(button.isEnabled); button.performClick(nil)
            } else { try #require(item.enabled && item.press()) }
        }
    }
    private func pressOwnedRemoteSave(_ panel: NSSavePanel, stage: String, output: URL) async -> Bool {
        let ownPID = getpid(), prompt = panel.prompt ?? "Save"
        let title = Element(object: panel).label ?? panel.title ?? "Save"
        let identifier = Element(object: panel).identifier ?? "save-panel"
        let frame = panel.frame
        let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let expected = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        let watchdog = R27NativeActionWatchdog()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { watchdog.failIfPending() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // All AX objects stay on this worker. The main actor is free to
                // answer its own accessibility server and run the save delegate.
                func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
                }
                func text(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
                func bounds(_ element: AXUIElement) -> CGRect? {
                    guard let position = attribute(element, "AXPosition"), let size = attribute(element, "AXSize"),
                          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
                    return CGRect(origin: point, size: dimensions)
                }
                func matches(_ actual: CGRect) -> Bool {
                    abs(actual.minX - expected.minX) < 4 && abs(actual.minY - expected.minY) < 4 &&
                    abs(actual.width - expected.width) < 4 && abs(actual.height - expected.height) < 4
                }
                var diagnostics: [[String: String]] = []
                func perform() -> Bool {
                    guard AXIsProcessTrusted() else {
                        diagnostics.append(["result": "The test host lacks accessibility trust."]); return false
                    }
                    let application = AXUIElementCreateApplication(ownPID)
                    AXUIElementSetMessagingTimeout(application, 1)
                    var returnedPID: pid_t = 0
                    guard AXUIElementGetPid(application, &returnedPID) == .success, returnedPID == ownPID else { return false }
                    for _ in 0..<8 {
                        let windows = attribute(application, "AXWindows") as? [AXUIElement] ?? []
                        for window in windows {
                            AXUIElementSetMessagingTimeout(window, 1)
                            let windowTitle = text(window, "AXTitle"), windowID = text(window, "AXIdentifier")
                            let actual = bounds(window)
                            diagnostics.append(["role": text(window, "AXRole"), "title": windowTitle, "id": windowID,
                                "frame": actual.map { NSStringFromRect($0) } ?? "unavailable", "expectedFrame": NSStringFromRect(expected)])
                            guard (windowID == identifier || windowTitle == title || windowTitle == prompt), let actual, matches(actual) else { continue }
                            var queue: [(AXUIElement, Int)] = [(window, 0)], visited = Set<CFHashCode>(), count = 0
                            while !queue.isEmpty && count < 2_048 {
                                let (element, depth) = queue.removeFirst(); count += 1
                                guard depth < 40, visited.insert(CFHash(element)).inserted else { continue }
                                AXUIElementSetMessagingTimeout(element, 1)
                                let role = text(element, "AXRole"), label = text(element, "AXTitle")
                                if role == "AXButton", label == prompt, (attribute(element, "AXEnabled") as? NSNumber)?.boolValue == true {
                                    var names: CFArray?
                                    guard AXUIElementCopyActionNames(element, &names) == .success,
                                          (names as? [String])?.contains("AXPress") == true else { continue }
                                    let result = AXUIElementPerformAction(element, "AXPress" as CFString)
                                    diagnostics.append(["result": "Owned Save AXPress", "success": String(result == .success)])
                                    return result == .success
                                }
                                let children = attribute(element, "AXChildren") as? [AXUIElement] ?? []
                                queue.append(contentsOf: children.map { ($0, depth + 1) })
                            }
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                    return false
                }
                let result = perform()
                if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output.appendingPathComponent("save-panel-own-ax-\(stage).json"))
                }
                watchdog.finish(); continuation.resume(returning: result)
            }
        }
    }

    private func pressPanelSave(_ panel: NSSavePanel, stage: String) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("build/r27-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let prompt = panel.prompt
        func saveButton() -> Element? {
            elements(panel).first { item in
                let title = (item.object as? NSButton)?.title ?? item.label ?? ""
                return (item.role == "AXButton" || item.object is NSButton) && title == prompt && item.enabled
            }
        }
        try await nativeAction {
            let snapshot = elements(panel).map { item in
                ["class": String(describing: type(of: item.object)), "role": item.role ?? "", "id": item.identifier ?? "", "label": String((item.label ?? "").prefix(256)), "enabled": String(item.enabled)]
            }
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("save-panel-ax-\(stage).json"))
        }
        if let item = saveButton() {
            try await nativeAction {
                FileHandle.standardError.write(Data("R27 Save AX: \(stage) native Save press entered\n".utf8))
                if let button = item.object as? NSButton { button.performClick(nil) }
                else { try #require(item.press(), "The owned Save button did not accept its native press action.") }
                FileHandle.standardError.write(Data("R27 Save AX: \(stage) native Save press returned\n".utf8))
            }
        } else {
            let pressed = await pressOwnedRemoteSave(panel, stage: stage, output: output)
            try #require(pressed, "The current test host's exact Save panel could not be pressed through public AX; see save-panel-own-ax-\(stage).json.")
        }
    }
    private func waitFor(_ window: NSWindow, message: String? = nil, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        repeat {
            try await nativeAction { window.contentView?.layoutSubtreeIfNeeded() }
            if condition() { return }
        } while ContinuousClock.now < deadline
        try #require(condition(), Comment(rawValue: message ?? "Synchronization controls: \(elements(window).compactMap(\.identifier).sorted())"))
    }
    private func host<V: View>(_ view: V, scheme: ColorScheme, width: CGFloat, height: CGFloat = 780) -> NSWindow {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: .init(x: 90, y: 90, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "DBeer synchronization SQL verification"
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(scheme))
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); return window
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
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) async throws {
        try await nativeAction {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            if window is NSSavePanel { FileHandle.standardError.write(Data("R27 Save key: default-button event entered\n".utf8)) }
            let handled = window.performKeyEquivalent(with: event)
            if !handled { window.sendEvent(event) }
            if window is NSSavePanel { FileHandle.standardError.write(Data("R27 Save key: default-button event returned\n".utf8)) }
        }
    }
    private func planSheet(_ window: NSWindow, ready: @MainActor () -> Bool) async throws -> NSWindow {
        try await waitFor(window) { ready() && window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await waitFor(sheet) { elements(sheet).contains { $0.identifier == "syncPlanPreview" } }
        return sheet
    }

    @Test func nativeSchemaPlanSelectionDependenciesAndRoutingInBothAppearancesAndSizes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(900), 1120] {
                let profiles = SchemaComparisonTestFixtures.profiles(), backend = try SynchronizationWindowSchemaBackend()
                var opened: [UUID] = []; var closed = false
                let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend }, openPlan: { _, target in opened.append(target.id); return true })
                model.sourceID = profiles[0].id; model.targetID = profiles[1].id
                let window = host(SchemaComparisonView(model: model, close: { closed = true }), scheme: scheme, width: width)
                defer { window.close() }
                try await press("schemaCompareStart", window)
                try await waitFor(window) { model.summary != nil }
                try await press("schemaComparePlan", window)
                let sheet = try await planSheet(window) { model.planDraft != nil }
                sheet.setContentSize(.init(width: width, height: width == 900 ? 660 : 780))
                try await waitFor(sheet) { find("syncPlanStep-create-column", sheet)?.selected == true }
                let draft = try #require(model.planDraft)
                #expect(try element("syncPlanDirection", sheet).text.contains("Source fixture → Target fixture"))
                #expect(try element("syncPlanTarget", sheet).text.contains("target.example:5432"))
                #expect(!(try element("syncPlanStep-drop-column", sheet)).selected)
                #expect(!(try element("syncPlanStep-convert-type", sheet)).enabled)
                #expect(try element("syncPlanDependencies-dependent", sheet).text.contains("Add target column"))
                #expect(draft.sql?.contains("ADD COLUMN") == true && draft.sql?.contains("DROP COLUMN") == false)
                try capture(sheet, name: "sync-schema-\(scheme)-\(Int(width))")
                try await press("syncPlanStep-create-column", sheet)
                try await waitFor(sheet) { draft.sql == nil && elements(sheet).contains { $0.identifier == "syncPlanSelectionError" } }
                #expect(!(try element("syncPlanSave", sheet)).enabled)
                #expect(!(try element("syncPlanOpen", sheet)).enabled)
                #expect(try element("syncPlanSelectionError", sheet).text.contains("required operation"))
                try await press("syncPlanStep-create-column", sheet)
                try await press("syncPlanStep-drop-column", sheet)
                try await waitFor(sheet) { draft.sql?.contains("DROP COLUMN") == true }
                #expect(try element("syncPlanOpen", sheet).enabled)
                // The cancel key belongs to the inner plan, leaving its comparison intact.
                try await key("\u{1b}", code: 53, window: sheet)
                try await waitFor(window) { model.planDraft == nil && window.attachedSheet == nil }
                #expect(!closed && opened.isEmpty && model.summary != nil)
                try await press("schemaComparePlan", window)
                let reopened = try await planSheet(window) { model.planDraft != nil }
                try await press("syncPlanOpen", reopened)
                try await waitFor(reopened) { opened.count == 1 }
                #expect(opened == [profiles[1].id] && model.planDraft?.isValid == false)
                #expect(!(try element("syncPlanOpen", reopened)).enabled)
                model.dismissPlan()
                try await waitFor(window) { window.attachedSheet == nil }
                try await press("schemaCompareClose", window); #expect(closed)
                await model.close()
            }
        }
    }

    @Test func nativeDataPlanRequiresExplicitDestructiveSelectionInBothAppearancesAndSizes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(980), 1160] {
                let profiles = DataComparisonTestFixtures.profiles(), backend = try SynchronizationDataBackend()
                var opened: [UUID] = []
                let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { backend }, openPlan: { _, target in opened.append(target.id); return true })
                DataComparisonTestFixtures.configure(model, profiles)
                let window = host(DataComparisonView(model: model, close: {}), scheme: scheme, width: width, height: 800)
                defer { window.close() }
                try await press("dataCompareDescribe", window)
                try await waitFor(window) { model.metadataMatches && !model.isWorking }
                try await press("dataCompareKey-0", window)
                model.sourceLimit = 3; model.targetLimit = 3
                try await press("dataCompareStart", window)
                try await waitFor(window) { model.summary != nil }
                try await press("dataComparePlan", window)
                let sheet = try await planSheet(window) { model.planDraft != nil }
                sheet.setContentSize(.init(width: width == 980 ? 900 : 1120, height: width == 980 ? 660 : 780))
                let draft = try #require(model.planDraft)
                #expect(!(try element("syncPlanStep-delete-row-0", sheet)).selected)
                #expect(!(try element("syncPlanOpen", sheet)).enabled)
                #expect(!(try element("syncPlanSave", sheet)).enabled)
                #expect(try element("syncPlanDirection", sheet).text.contains("Source fixture → Target fixture"))
                try capture(sheet, name: "sync-data-\(scheme)-\(width == 980 ? "minimum" : "default")")
                try await press("syncPlanStep-delete-row-0", sheet)
                try await waitFor(sheet) { draft.sql?.contains("DELETE FROM") == true && find("syncPlanOpen", sheet)?.enabled == true }
                // Moving focus through the owned native window must preserve the draft.
                sheet.recalculateKeyViewLoop(); sheet.selectNextKeyView(nil)
                #expect(sheet.firstResponder != nil && draft.selected.contains("delete-row-0"))
                if scheme == .light && width == 1160 { try await key("\r", code: 36, window: sheet) }
                else { try await press("syncPlanOpen", sheet) }
                try await waitFor(sheet) { opened.count == 1 }
                #expect(opened == [profiles[1].id])
                await model.close()
            }
        }
    }

    @Test func commandObserversDetachBeforeClosingTheirWorkspaceOwner() async throws {
        var workspace: ApplicationWorkspace? = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), automaticallyWatchFiles: false)
        let registry = try #require(workspace?.commands)
        let window = host(Text("Command lifecycle fixture"), scheme: .light, width: 900, height: 660)
        defer { window.close() }
        workspace?.presentationWindow = window
        let context = AppCommandContext(documentID: nil, focus: .workspace, isWorkspaceWindow: true, hasModal: false)
        #expect(registry.canPerform(.newSQLTab, context: context))
        _ = registry.perform(.newSQLTab, context: context)
        #expect(workspace?.documents.count == 1)
        var changes = 0
        let observation = registry.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        NotificationCenter.default.post(name: NSApplication.willUpdateNotification, object: NSApplication.shared)
        #expect(changes > 0)
        await workspace?.shutdown()
        let before = changes
        workspace?.presentationWindow = nil; workspace = nil
        for name in [NSApplication.willUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        registry.shortcuts.objectWillChange.send()
        #expect(changes == before)
    }

    @Test(.enabled(if: AXIsProcessTrusted()))
    func nativeSavePanelUsesReviewedSelectionAndRefusesRetiredDrafts() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles()
        let draft = SynchronizationPlanDraft(plan: try SynchronizationPlanTestFixtures.schema(), source: profiles[0], target: profiles[1], open: { _, _ in true })
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/r27/save-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var panels: [NSSavePanel] = []
        let directories = ["reviewed", "changed", "retired"].map { directory.appendingPathComponent($0, isDirectory: true) }
        for folder in directories { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let filename = "synchronization-plan.sql"
        let destinations = directories.map { $0.appendingPathComponent(filename) }
        let delegate = ApprovedSaveDestination(allowed: destinations)
        let view = SynchronizationPlanView(draft: draft, close: {}, makeSavePanel: {
            let panel = NSSavePanel(); panel.directoryURL = directories[panels.count]; panel.delegate = delegate
            panels.append(panel); return panel
        })
        let window = host(view, scheme: .light, width: 1120)
        defer {
            let closingPanels = panels
            RunLoop.main.perform(inModes: [.default, .common, .modalPanel, .eventTracking]) { MainActor.assumeIsolated { closingPanels.forEach { $0.cancel(nil) }; window.close() } }
        }
        try await waitFor(window, message: "Save SQL button was not enabled.") { find("syncPlanSave", window)?.enabled == true }
        let expected = try #require(draft.sql)
        try await key("s", code: 1, modifiers: .command, window: window)
        try await waitFor(window, message: "Command-S did not present the owned Save panel.") { panels.count == 1 && panels[0].isVisible }
        let panel = panels[0]
        let destination = destinations[0]
        try await waitFor(window, message: "Reviewed Save panel did not navigate to fixture directory/name (directory: \(panel.directoryURL?.lastPathComponent ?? "nil"), name: \(panel.nameFieldStringValue)).") {
            panel.directoryURL?.standardizedFileURL.path == directories[0].standardizedFileURL.path && panel.nameFieldStringValue == filename
        }
        try #require(panel.directoryURL?.standardizedFileURL.path == directories[0].standardizedFileURL.path && panel.nameFieldStringValue == filename)
        FileHandle.standardError.write(Data("R27 Save stage: scheduling capture\n".utf8))
        try await nativeAction {
            FileHandle.standardError.write(Data("R27 Save stage: capture entered\n".utf8))
            try capture(panel, name: "sync-save-panel-light")
            FileHandle.standardError.write(Data("R27 Save stage: capture returned\n".utf8))
        }
        try await pressPanelSave(panel, stage: "reviewed")
        try await waitFor(window, message: "Reviewed Save panel did not complete its exact fixture SQL write.") { draft.saved && FileManager.default.fileExists(atPath: destination.path) }
        #expect(panel.url?.standardizedFileURL == destination.standardizedFileURL)
        #expect(delegate.validations >= 1)
        #expect(try String(contentsOf: destination, encoding: .utf8) == expected)
        try await press("syncPlanSave", window)
        try await waitFor(window, message: "Second owned Save panel was not presented.") { panels.count == 2 && panels[1].isVisible }
        let changedPanel = panels[1]
        let changedDestination = destinations[1]
        try await waitFor(window, message: "Changed-selection Save panel did not navigate to its fixture directory/name.") {
            changedPanel.directoryURL?.standardizedFileURL.path == directories[1].standardizedFileURL.path && changedPanel.nameFieldStringValue == filename
        }
        try #require(changedPanel.directoryURL?.standardizedFileURL.path == directories[1].standardizedFileURL.path && changedPanel.nameFieldStringValue == filename)
        draft.selected.insert("drop-column")
        try await pressPanelSave(changedPanel, stage: "changed")
        try await waitFor(window, message: "Changed-selection Save callback did not reject the unreviewed SQL.") { !panels[1].isVisible && draft.error != nil }
        #expect(panels[1].url?.standardizedFileURL == changedDestination.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: changedDestination.path))
        #expect(draft.error?.contains("selected operations changed") == true)
        try await press("syncPlanSave", window)
        try await waitFor(window, message: "Third owned Save panel was not presented.") { panels.count == 3 && panels[2].isVisible }
        let retiredPanel = panels[2]
        let retiredDestination = destinations[2]
        try await waitFor(window, message: "Retired-draft Save panel did not navigate to its fixture directory/name.") {
            retiredPanel.directoryURL?.standardizedFileURL.path == directories[2].standardizedFileURL.path && retiredPanel.nameFieldStringValue == filename
        }
        try #require(retiredPanel.directoryURL?.standardizedFileURL.path == directories[2].standardizedFileURL.path && retiredPanel.nameFieldStringValue == filename)
        draft.invalidate()
        try await pressPanelSave(retiredPanel, stage: "retired")
        try await waitFor(window, message: "Retired-draft Save panel did not close.") { !panels[2].isVisible }
        #expect(panels[2].url?.standardizedFileURL == retiredDestination.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: retiredDestination.path))
    }

    @Test func emptyManualAndLongWarningPlansKeepControlsReachable() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles()
        for scheme in [ColorScheme.light, .dark] {
            for manual in [false, true] {
                var plan = try SynchronizationPlanTestFixtures.schema()
                plan.steps = manual ? plan.steps.filter(\.manual) : []
                let draft = SynchronizationPlanDraft(plan: plan, source: profiles[0], target: profiles[1], open: { _, _ in true })
                var back = false
                let window = host(SynchronizationPlanView(draft: draft, close: { back = true }), scheme: scheme, width: 900, height: 660)
                defer { window.close() }
                try await waitFor(window) { elements(window).contains { $0.identifier == "syncPlanPreview" } }
                #expect(draft.sql == nil && draft.selectionError == nil)
                #expect(!elements(window).contains { $0.identifier == "syncPlanSelectionError" })
                #expect(!(try element("syncPlanSave", window)).enabled)
                #expect(!(try element("syncPlanOpen", window)).enabled)
                #expect(try element("syncPlanPreview", window).text.contains(manual ? "manual SQL" : "No synchronization SQL is needed"))
                try capture(window, name: "sync-\(manual ? "manual" : "empty")-\(scheme)-minimum")
                try await press("syncPlanBack", window); #expect(back)
            }
        }
        var plan = try SynchronizationPlanTestFixtures.schema()
        plan.warnings = (0..<64).map { "Warning \($0): " + String(repeating: "Dependency and partial-execution context. ", count: 60) }
        let draft = SynchronizationPlanDraft(plan: plan, source: profiles[0], target: profiles[1], open: { _, _ in true })
        let window = host(SynchronizationPlanView(draft: draft, close: {}), scheme: .dark, width: 900, height: 660)
        defer { window.close() }
        try await waitFor(window) { find("syncPlanSave", window)?.enabled == true }
        #expect(window.contentView?.bounds.height == 660)
        try capture(window, name: "sync-long-warnings-dark-minimum")
        #expect(try element("syncPlanBack", window).enabled)
        #expect(try element("syncPlanOpen", window).enabled)
    }
}
