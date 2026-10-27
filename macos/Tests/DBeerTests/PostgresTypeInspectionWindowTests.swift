import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// UI suite: explicitly authorized owned windows with a protocol stub. Keep it
/// separate from default non-UI filters. No global input, clipboard, database,
/// Keychain, or external Accessibility permission is used here.
@Suite(.serialized)
@MainActor
struct PostgresTypeInspectionWindowTests {
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
        var nativeButton: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var isEnabledAction: Bool {
            if let button = nativeButton { return button.window != nil && button.isEnabled && !button.isHiddenOrHasHiddenAncestor }
            let role: String? = value("accessibilityRole")
            return role == NSAccessibility.Role.button.rawValue && flag("isAccessibilityEnabled") &&
                object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
        var text: String {
            let label: String? = value("accessibilityLabel")
            let plain: String? = value("accessibilityValue")
            let attributed: NSAttributedString? = value("accessibilityValue")
            return [label, plain, attributed?.string].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func elements(in root: NSObject) -> [Element] {
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit)
            if let view = object as? NSView { view.subviews.forEach(visit) }
            if let window = object as? NSWindow {
                if let content = window.contentView { visit(content) }
                if let sheet = window.attachedSheet { visit(sheet) }
            }
        }
        visit(root)
        return result
    }

    private func findElement(_ id: String, in root: NSObject) -> Element? {
        elements(in: root).first { $0.identifier == id }
    }

    private func element(_ id: String, in root: NSObject) throws -> Element {
        try #require(findElement(id, in: root), "Missing PostgreSQL type control: \(id)")
    }

    private func hasExposedText(_ fragments: [String], in window: NSWindow) -> Bool {
        elements(in: window.attachedSheet ?? window).contains { element in
            fragments.allSatisfy { element.text.contains($0) }
        }
    }

    /// Wait for the actual presentation or model condition. There are no fixed
    /// settling sleeps after actions, appearance changes, or field edits.
    private func waitFor(_ window: NSWindow, stage: String = "type presentation", _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            NativeButtonFocusPolicy().apply(to: window)
            if let sheet = window.attachedSheet { sheet.contentView?.layoutSubtreeIfNeeded() }
            if let sheet = window.attachedSheet { NativeButtonFocusPolicy().apply(to: sheet) }
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
            if condition() { return }
        } while ContinuousClock.now < deadline
        let contentBounds = window.contentView.map { String(describing: $0.bounds) } ?? "missing"
        let controllerSize = window.contentViewController.map { String(describing: $0.preferredContentSize) } ?? "missing"
        let tables = window.contentView.map { content in
            descendants(content, of: NSTableView.self).map {
                "rows=\($0.numberOfRows), columns=\($0.numberOfColumns), bounds=\($0.bounds), visible=\($0.visibleRect)"
            }
        } ?? []
        try #require(condition(), "Type window stage: \(stage); content: \(contentBounds); controller: \(controllerSize); tables: \(tables); identifiers: \(elements(in: window).compactMap(\.identifier).sorted())")
    }

    private func readyForKeys(_ window: NSWindow, responder: NSResponder? = nil) async throws {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        try await waitFor(window, stage: "owned-window key readiness") {
            let target = window.attachedSheet ?? window
            if !target.isKeyWindow { target.makeKeyAndOrderFront(nil) }
            return application.isActive && application.keyWindow === target && target.isKeyWindow
        }
        let target = window.attachedSheet ?? window
        if let responder {
            try #require(target.makeFirstResponder(responder))
            try await waitFor(window, stage: "owned-window first responder readiness") {
                target.firstResponder === responder || (responder as? NSTextField)?.currentEditor() === target.firstResponder
            }
        }
    }

    private func host(_ content: some View, width: CGFloat = 1280, scheme: ColorScheme = .light) async throws -> NSWindow {
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synthetic PostgreSQL type verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Match SwiftUI's controller-backed presentation and keyboard shortcut
        // context while keeping all events inside this owned synthetic window.
        let contentSize = NSSize(width: width, height: 800)
        window.contentViewController = NSHostingController(rootView: AnyView(content.preferredColorScheme(scheme)
            .frame(width: contentSize.width, height: contentSize.height)))
        try sizeHost(window, to: contentSize)
        window.makeKeyAndOrderFront(nil)
        try await readyForKeys(window)
        return window
    }

    private func performPress(_ item: Element) throws {
        if let button = item.nativeButton {
            try #require(button.isEnabled)
            button.performClick(nil)
        } else {
            try #require(item.flag("isAccessibilityEnabled", fallback: true) && item.flag("accessibilityPerformPress"))
        }
    }

    private func enabledAction(in window: NSWindow, matching predicate: (Element) -> Bool) -> Element? {
        let identified = elements(in: window.attachedSheet ?? window).filter(predicate)
        let candidates = identified.flatMap { item in
            // SwiftUI can put the identifier on an AX wrapper around the
            // native button. Resolve only actions inside that exact wrapper.
            item.isEnabledAction ? [item] : elements(in: item.object).filter(\.isEnabledAction)
        }
        return candidates.first { $0.nativeButton != nil } ?? candidates.first
    }

    private func waitForEnabled(_ id: String, in window: NSWindow) async throws -> Element {
        try await waitFor(window, stage: "enabled action \(id)") { enabledAction(in: window) { $0.identifier == id } != nil }
        return try #require(enabledAction(in: window) { $0.identifier == id }, "No live enabled action for \(id)")
    }

    private func press(_ id: String, in window: NSWindow) async throws {
        let item = try await waitForEnabled(id, in: window)
        try performPress(item)
    }

    private func pressLabel(_ label: String, in window: NSWindow) async throws {
        let matches: (Element) -> Bool = {
            let value: String? = $0.value("accessibilityLabel")
            return value == label
        }
        try await waitFor(window) { enabledAction(in: window, matching: matches) != nil }
        let item = try #require(enabledAction(in: window, matching: matches), "Missing live type section button: \(label)")
        try performPress(item)
    }

    private func field(_ id: String, in window: NSWindow) throws -> NSTextField {
        let item = try element(id, in: window)
        if let field = item.object as? NSTextField { return field }
        if let field = (item.object as? NSCell)?.controlView as? NSTextField { return field }
        if let view = item.object as? NSView,
           let field = descendants(view, of: NSTextField.self).first(where: \.isEditable) { return field }
        let content = try #require((window.attachedSheet ?? window).contentView)
        return try #require(descendants(content, of: NSTextField.self).first { $0.accessibilityIdentifier() == id })
    }

    private func replace(_ text: String, in id: String, window: NSWindow) async throws {
        let field = try field(id, in: window)
        try await readyForKeys(window, responder: field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        try #require((window.attachedSheet ?? window).firstResponder === editor)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await waitFor(window) { field.stringValue.utf8.elementsEqual(text.utf8) }
        _ = try await waitForEnabled("previewPostgresTypeDDL", in: window)
    }

    private func choose(_ title: String, in window: NSWindow) async throws {
        func popup() -> NSPopUpButton? {
            guard let content = (window.attachedSheet ?? window).contentView else { return nil }
            return descendants(content, of: NSPopUpButton.self).first { $0.isEnabled && $0.itemTitles.contains(title) }
        }
        // SwiftUI owns each native menu item's action. Its popup adapter has
        // no NSControl target/action, so dispatch the actual menu selection.
        try await waitFor(window, stage: "native popup menu choice \(title)") {
            guard let menu = popup()?.menu else { return false }
            menu.update()
            return menu.items.contains { $0.title == title && $0.isEnabled && $0.action != nil }
        }
        let menu = try #require(popup()?.menu, "Missing native menu for popup choice: \(title)")
        let item = try #require(menu.items.first { $0.title == title && $0.isEnabled && $0.action != nil })
        menu.performActionForItem(at: menu.index(of: item))
        try await waitFor(window, stage: "rendered popup selection \(title)") { popup()?.titleOfSelectedItem == title }
    }

    private func sizeHost(_ window: NSWindow, to size: NSSize) throws {
        let controller = try #require(window.contentViewController as? NSHostingController<AnyView>)
        controller.preferredContentSize = size
        window.setContentSize(size)
        controller.view.setFrameSize(size)
        controller.view.autoresizingMask = [.width, .height]
        controller.view.layoutSubtreeIfNeeded()
    }

    private func table(containing identifiers: Set<String>, in window: NSWindow) -> NSTableView? {
        guard let content = (window.attachedSheet ?? window).contentView else { return nil }
        return descendants(content, of: NSTableView.self).first { table in
            identifiers.isSubset(of: Set(elements(in: table).compactMap(\.identifier)))
        }
    }

    private func key(_ window: NSWindow, characters: String, code: UInt16,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let target = window.attachedSheet ?? window
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func catalogMenu(for node: CatalogNode, in window: NSWindow) throws -> NSMenu {
        let content = try #require(window.contentView)
        let region = try #require(descendants(content, of: CatalogContextMenuView.self).first)
        for table in descendants(content, of: NSOutlineView.self) {
            for index in 0..<table.numberOfRows {
                guard let row = table.rowView(atRow: index, makeIfNecessary: true),
                      elements(in: row).contains(where: { $0.identifier == "catalogObject-\(node.id.uuidString)" }) else { continue }
                let bounds = table.rect(ofRow: index)
                let point = table.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let menu = try #require(region.menu(for: event))
                menu.update()
                return menu
            }
        }
        throw PostgresTypeCatalogFailure(message: "The synthetic type row has no native context-menu anchor.")
    }

    private func withFixture(readOnly: Bool = false,
                             _ body: @MainActor (PostgresTypeTestFixture) async throws -> Void) async throws {
        let fixture = try await PostgresTypeTestFixture.make(readOnly: readOnly)
        do { try await body(fixture); await fixture.finish() }
        catch { await fixture.finish(); throw error }
    }

    @Test func catalogGroupsMenusAndSearchOpenTheDedicatedInspector() async throws {
        try await withFixture { fixture in
            let workspace = fixture.workspace
            try await fixture.connect()
            let schema = CatalogNode(profileID: fixture.profile.id, name: "public", kind: .schema,
                schema: "public", engine: .postgresql)
            await workspace.expand(schema)
            let enums = try #require(schema.children?.first { $0.name == "Enums" })
            let types = try #require(schema.children?.first { $0.name == "User-defined Types" })
            #expect(enums.objectKind == "enum" && types.objectKind == "type")
            await workspace.expand(enums)
            let node = try #require(enums.children?.first { $0.objectKind == "enum" })
            schema.isExpanded = true
            enums.isExpanded = true
            let catalogSize = NSSize(width: 380, height: 800)
            let content = List { CatalogBranchView(node: schema, workspace: workspace) }
                .listStyle(.sidebar).catalogContextMenu()
                .frame(width: catalogSize.width, height: catalogSize.height)
            let window = try await host(content, width: catalogSize.width)
            defer { window.close() }
            try sizeHost(window, to: catalogSize)
            try await waitFor(window, stage: "initial expanded catalog enum row") {
                guard let content = window.contentView else { return false }
                return content.bounds.size == catalogSize &&
                    descendants(content, of: NSOutlineView.self).contains { !$0.visibleRect.isEmpty } &&
                    elements(in: window).contains { $0.identifier == "catalogObject-\(node.id.uuidString)" }
            }
            #expect(!node.isExpandable)
            let menu = try catalogMenu(for: node, in: window)
            #expect(menu.item(withTitle: "Inspect Type…")?.isEnabled == true)
            #expect(menu.item(withTitle: "Copy Name")?.isEnabled == true)
            #expect(menu.item(withTitle: "Refresh")?.isEnabled == true)
            #expect(menu.item(withTitle: "Open Data") == nil)
            #expect(menu.item(withTitle: "Structure and Definition…") == nil)
            menu.performActionForItem(at: menu.index(of: try #require(menu.item(withTitle: "Inspect Type…"))))
            try await waitFor(window, stage: "catalog menu inspector metadata") {
                workspace.typeInspection?.details != nil && workspace.typeInspection?.isLoading == false
            }
            #expect(workspace.inspection == nil)
            #expect(workspace.typeInspection?.reference.localOID == node.localOID)
            workspace.dismissPostgresTypeInspection()

            workspace.catalogSearch = "status"
            await workspace.searchCatalog()
            let result = try #require(workspace.catalogSearchResults[fixture.profile.id]?.first { $0.isPostgresType })
            let host = try #require(window.contentViewController as? NSHostingController<AnyView>)
            host.rootView = AnyView(List { CatalogBranchView(node: result, workspace: workspace, showSchema: true) }
                .listStyle(.sidebar).catalogContextMenu()
                .frame(width: catalogSize.width, height: catalogSize.height))
            try sizeHost(window, to: catalogSize)
            try await waitFor(window, stage: "replacement search result row") {
                guard let content = window.contentView else { return false }
                return content.bounds.size == catalogSize &&
                    descendants(content, of: NSOutlineView.self).contains { !$0.visibleRect.isEmpty } &&
                    elements(in: window).contains { $0.identifier == "catalogObject-\(result.id.uuidString)" }
            }
            try await press("catalogObject-\(result.id.uuidString)", in: window)
            try await waitFor(window, stage: "search row inspector metadata") {
                workspace.typeInspection?.details != nil && workspace.typeInspection?.isLoading == false
            }
            #expect(workspace.typeInspection?.reference.localOID == result.localOID)
            let commands = try fixture.commands()
            #expect(!commands.contains { $0.catalog?.kind == "columns" && ["enum", "type"].contains($0.catalog?.objectKind ?? "") })

            let cassandra = CatalogNode(profileID: UUID(), name: "address", kind: .object, schema: "work",
                objectKind: "type", engine: .cassandra)
            #expect(cassandra.isExpandable && !cassandra.isPostgresType)
        }
    }

    @Test func valuesDependenciesLimitationsAndExactEnumInputsRemainVisibleInBothAppearances() async throws {
        try await withFixture { fixture in
            let workspace = fixture.workspace
            try await fixture.connect()
            await workspace.inspect(fixture.node())
            var model = try #require(workspace.typeInspection)
            let window = try await host(ApplicationWorkspaceView(workspace: workspace), scheme: .light)
            workspace.presentationWindow = window
            defer { window.close() }
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeInspection" } }
            let limitations = try #require(model.details?.operationLimitations)
            try #require(!limitations.isEmpty)
            try await waitFor(window, stage: "visible type operation limitations") {
                hasExposedText(["Removal, reordering, and CASCADE"], in: window) &&
                    hasExposedText([limitations], in: window)
            }
            let values = try #require(model.enumValues)
            try #require(!values.isEmpty)
            let valueIdentifiers = Set(values.map { "postgresEnumValue-\($0.position)" })
            try await pressLabel("Enum Values", in: window)
            try await waitFor(window) { table(containing: valueIdentifiers, in: window)?.numberOfRows == values.count }
            let valueTable = try #require(table(containing: valueIdentifiers, in: window))
            #expect(valueTable.numberOfColumns == 3)
            for (index, value) in values.enumerated() {
                let row = try #require(valueTable.rowView(atRow: index, makeIfNecessary: true))
                let displayed = elements(in: row)
                #expect(displayed.contains {
                    $0.identifier == "postgresEnumValue-\(value.position)" &&
                        $0.text.contains(PostgresTypeInspectionView.labelDisplay(value.label))
                })
                #expect(displayed.contains { $0.text.contains(value.sortOrder) })
            }
            #expect(values.map(\.position) == Array(1...values.count))
            #expect(values.contains { $0.label.isEmpty })
            #expect(elements(in: window).contains { $0.text.contains("\"\" (empty label)") })
            #expect(PostgresTypeInspectionView.labelDisplay("  ") == "\"  \"")
            #expect(PostgresTypeInspectionView.labelDisplay("a\\b") == "\"a\\\\b\"")

            let dependencyValues = try #require(model.dependencies)
            let incoming = try #require(dependencyValues.first { $0.direction == "incoming" })
            let outgoing = try #require(dependencyValues.first { $0.direction == "outgoing" })
            let dependencyIdentifiers = Set(dependencyValues.map { "postgresTypeDependency-\($0.id)" })
            try await pressLabel("Dependencies", in: window)
            try await waitFor(window) { table(containing: dependencyIdentifiers, in: window)?.numberOfRows == dependencyValues.count }
            let dependencyTable = try #require(table(containing: dependencyIdentifiers, in: window))
            #expect(dependencyTable.numberOfColumns == 4)
            for dependency in dependencyValues {
                #expect(elements(in: dependencyTable).contains {
                    $0.identifier == "postgresTypeDependency-\(dependency.id)" && $0.text.contains(dependency.objectIdentity)
                })
            }
            try await waitFor(window, stage: "visible dependency scope notice") {
                hasExposedText(["pg_depend", "Dynamic SQL", "shared-cluster dependencies are excluded"], in: window)
            }
            try await choose("Incoming · Uses This Type", in: window)
            try await waitFor(window) {
                table(containing: ["postgresTypeDependency-\(incoming.id)"], in: window)?.numberOfRows == 1 &&
                !elements(in: window).contains { $0.identifier == "postgresTypeDependency-\(outgoing.id)" }
            }
            try await choose("Outgoing · Used by This Type", in: window)
            try await waitFor(window) {
                table(containing: ["postgresTypeDependency-\(outgoing.id)"], in: window)?.numberOfRows == 1 &&
                !elements(in: window).contains { $0.identifier == "postgresTypeDependency-\(incoming.id)" }
            }
            try await choose("All Direct Dependencies", in: window)
            try await waitFor(window) { table(containing: dependencyIdentifiers, in: window)?.numberOfRows == dependencyValues.count }

            try await press("dismissPostgresTypeInspection", in: window)
            try await waitFor(window) { window.attachedSheet == nil && workspace.typeInspection == nil }
            await workspace.inspect(fixture.node("append_status"))
            model = try #require(workspace.typeInspection)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeInspection" } }
            #expect(model.enumValues?.contains { $0.label.isEmpty } == false)
            try await choose("Add Enum Value at End", in: window)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeNewEnumValue" } }
            #expect(try field("postgresTypeNewEnumValue", in: window).stringValue.isEmpty)
            let emptyLabelPreview = try await waitForEnabled("previewPostgresTypeDDL", in: window)
            #expect(emptyLabelPreview.isEnabledAction)
            try await press("previewPostgresTypeDDL", in: window)
            try await waitFor(window) { model.preview != nil && findElement("postgresTypeDDLChange", in: window) != nil }
            #expect(model.preview?.change.operation == "addEnumValue" && model.preview?.change.value == "")
            #expect(try element("postgresTypeDDLChange", in: window).text.contains("\"\" (empty label)"))
            try await waitFor(window, stage: "visible new enum value commit warning") {
                hasExposedText(["newly added enum value", "transaction commits"], in: window)
            }
            try await press("discardPostgresTypePreview", in: window)
            try await waitFor(window) { model.preview == nil && !model.isPreparingPreview }
            try await press("dismissPostgresTypeInspection", in: window)
            try await waitFor(window) { window.attachedSheet == nil && workspace.typeInspection == nil }
            await workspace.inspect(fixture.node())
            model = try #require(workspace.typeInspection)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeInspection" } }
            try await choose("Rename Enum Value", in: window)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeOldEnumValue" } }
            let empty = try #require(values.first { $0.label.isEmpty })
            try await choose("\(empty.position). \"\" (empty label)", in: window)
            let exact = "  🌍\\next'  "
            try await replace(exact, in: "postgresTypeNewEnumValue", window: window)
            try await press("previewPostgresTypeDDL", in: window)
            try await waitFor(window) { model.preview != nil && findElement("postgresTypeDDLChange", in: window) != nil }
            #expect(model.preview?.change.oldValue == "")
            #expect(model.preview?.change.value?.utf8.elementsEqual(exact.utf8) == true)
            try await press("discardPostgresTypePreview", in: window)
            try await waitFor(window) {
                model.preview == nil && findElement("postgresTypeNewEnumValue", in: window) != nil &&
                    findElement("openPostgresTypeSQLTab", in: window) == nil
            }
            #expect(!elements(in: window).contains { $0.identifier == "openPostgresTypeSQLTab" })

            let hosting = try #require(window.contentViewController as? NSHostingController<AnyView>)
            let workspaceSize = NSSize(width: 1280, height: 800)
            for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
                hosting.rootView = AnyView(ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(scheme)
                    .frame(width: workspaceSize.width, height: workspaceSize.height))
                try sizeHost(window, to: workspaceSize)
                let sheet = try #require(window.attachedSheet)
                window.appearance = NSAppearance(named: appearance)
                sheet.appearance = NSAppearance(named: appearance)
                sheet.setContentSize(NSSize(width: 640, height: 760))
                try await waitFor(window, stage: "\(scheme) workspace and narrow inspector geometry") {
                    window.contentView?.bounds.size == workspaceSize && workspace.typeInspection === model &&
                        sheet.contentView?.bounds.width == 640 &&
                        findElement("postgresTypeNewEnumValue", in: window) != nil &&
                        elements(in: window).contains { $0.identifier == "previewPostgresTypeDDL" }
                }
                #expect(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
                let field = try field("postgresTypeNewEnumValue", in: window)
                let content = try #require(sheet.contentView)
                #expect(!field.visibleRect.isEmpty)
                #expect(content.bounds.insetBy(dx: -1, dy: -1).contains(field.convert(field.bounds, to: content)))
                #expect(field.focusRingType == .none)
            }

            model.enumValues = []
            model.enumValuesComplete = false
            try await pressLabel("Enum Values", in: window)
            try await waitFor(window, stage: "incomplete enum values notice") {
                hasExposedText(["enum value list is incomplete", "Missing labels or ordering"], in: window) &&
                    hasExposedText(["No values were returned in this incomplete response."], in: window)
            }
            model.enumValuesComplete = true
            try await waitFor(window, stage: "complete empty enum values notice") {
                hasExposedText(["This enum has no values."], in: window) &&
                    !hasExposedText(["enum value list is incomplete"], in: window) &&
                    !hasExposedText(["No values were returned in this incomplete response."], in: window)
            }
            model.dependencies = []
            model.dependenciesComplete = false
            try await pressLabel("Dependencies", in: window)
            try await waitFor(window, stage: "incomplete dependencies notice") {
                hasExposedText(["dependency list is incomplete", "cannot establish that the type has no other dependencies"], in: window) &&
                    hasExposedText(["No dependencies were returned in this incomplete scope."], in: window)
            }
            model.dependencies = nil
            model.dependenciesError = "Dependencies are unavailable for this fixture."
            try await waitFor(window, stage: "unavailable dependencies notice") {
                hasExposedText(["Dependencies are unavailable for this fixture."], in: window) &&
                    !hasExposedText(["No dependencies were returned in this incomplete scope."], in: window) &&
                    !hasExposedText(["No direct pg_depend links in this scope."], in: window)
            }

            let details = try #require(model.details)
            for status in [PostgresTypeDefinitionStatus.partial, .unavailable] {
                model.details = PostgresTypeDetails(typeKind: details.typeKind, owner: details.owner,
                    definition: status == .partial ? details.definition : nil, definitionStatus: status,
                    details: details.details, renameSupported: false, addEnumValueSupported: false,
                    renameEnumValueSupported: false, operationLimitations: "Extension-managed type: use the extension's supported workflow.",
                    permissionHint: details.permissionHint)
                try await pressLabel("Definition", in: window)
                try await waitFor(window, stage: "\(status.rawValue) definition and unavailable operations notices") {
                    hasExposedText([status == .partial ? "Partial definition: some properties cannot be reconstructed."
                        : "A complete CREATE definition is unavailable for this type."], in: window) &&
                        hasExposedText(["Extension-managed type: use the extension's supported workflow."], in: window) &&
                        hasExposedText(["DDL preview is unavailable for this type."], in: window) &&
                        findElement("previewPostgresTypeDDL", in: window) == nil
                }
            }
        }
    }

    @Test func keyboardPreviewAndExplicitOpenKeepTheCapturedProfileAndPaneWithoutExecution() async throws {
        try await withFixture(readOnly: true) { fixture in
            let workspace = fixture.workspace
            try await fixture.connect()
            let left = workspace.newDocument(profileID: fixture.otherProfile.id, text: "SELECT left_fixture;", in: .left)
            let right = workspace.newDocument(profileID: fixture.profile.id, text: "SELECT right_fixture;", in: .right)
            workspace.selectDocument(right.id, in: .right)
            let window = try await host(ApplicationWorkspaceView(workspace: workspace), scheme: .dark)
            workspace.presentationWindow = window
            defer { window.close() }
            await workspace.inspect(fixture.node())
            let model = try #require(workspace.typeInspection)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeNewName" } }
            let exact = "  Renamed \"🌍\\  "
            try await replace(exact, in: "postgresTypeNewName", window: window)
            let nativeField = try field("postgresTypeNewName", in: window)
            try await readyForKeys(window, responder: nativeField)
            let previewAction = try await waitForEnabled("previewPostgresTypeDDL", in: window)
            #expect(previewAction.isEnabledAction)
            let sheet = try #require(window.attachedSheet)
            #expect(sheet.performKeyEquivalent(with: try key(window, characters: "\r", code: 36, modifiers: .command)))
            try await waitFor(window) { model.preview != nil && elements(in: window).contains { $0.identifier == "openPostgresTypeSQLTab" } }
            #expect(model.reference.policy.readOnly)
            #expect(model.preview?.change.newName?.utf8.elementsEqual(exact.utf8) == true)
            #expect(try element("postgresTypeDDLDestination", in: window).text.contains("right pane"))
            let expectedSQL = try #require(model.preview?.sql)
            let before = workspace.documents.count
            workspace.selectDocument(left.id, in: .left)
            try await press("openPostgresTypeSQLTab", in: window)
            try await waitFor(window) { workspace.documents.count == before + 1 }
            let draft = try #require(workspace.documents.last)
            #expect(draft.profileID == fixture.profile.id && draft.text == expectedSQL)
            #expect(workspace.pane(containing: draft.id) == .right)
            #expect(workspace.activePaneID == .left && workspace.selectedDocument(in: .left)?.id == left.id)
            #expect(draft.runtime == nil && draft.executions.isEmpty)
            let commands = try fixture.commands()
            #expect(!commands.contains { ["execute", "operation.assess", "operation.authorize", "changes.apply"].contains($0.type) })
            #expect(commands.filter { $0.type == "connect" }.count == 1)
        }
    }

    @Test func cancelStopAndEscapeDismissCorrelatePendingRequestsWithoutReopeningTheInspector() async throws {
        try await withFixture { fixture in
            let workspace = fixture.workspace
            try await fixture.connect()
            let window = try await host(ApplicationWorkspaceView(workspace: workspace), scheme: .light)
            workspace.presentationWindow = window
            defer { window.close() }
            await workspace.inspect(fixture.node())
            let first = try #require(workspace.typeInspection)
            try await waitFor(window) { elements(in: window).contains { $0.identifier == "postgresTypeNewName" } }
            try await replace("hold-preview", in: "postgresTypeNewName", window: window)
            try await press("previewPostgresTypeDDL", in: window)
            try await fixture.waitForCatalog("typeDDL")
            let request = try #require(fixture.commands().last { $0.catalog?.kind == "typeDDL" })
            try await waitFor(window) { first.isPreparingPreview && elements(in: window).contains { $0.identifier == "discardPostgresTypePreview" } }
            #expect(!elements(in: window).contains { $0.identifier == "postgresTypeNewName" })
            try await press("discardPostgresTypePreview", in: window)
            try await waitFor(window) {
                !first.isPreparingPreview && findElement("postgresTypeNewName", in: window) != nil &&
                    (try? fixture.commands().contains { $0.type == "cancel" && $0.queryId == request.queryId }) == true
            }
            #expect(first.preview == nil && workspace.documents.count == 0)

            try await replace("fresh after cancellation", in: "postgresTypeNewName", window: window)
            try await press("previewPostgresTypeDDL", in: window)
            try await waitFor(window) { first.preview != nil && findElement("postgresTypeDDLChange", in: window) != nil }
            #expect(first.preview?.change.newName == "fresh after cancellation")
            #expect(try element("postgresTypeDDLChange", in: window).text.contains("fresh after cancellation"))
            try await press("discardPostgresTypePreview", in: window)
            try await waitFor(window) { first.preview == nil && elements(in: window).contains { $0.identifier == "postgresTypeNewName" } }
            #expect(!elements(in: window).contains { $0.identifier == "openPostgresTypeSQLTab" })

            try await replace("hold-preview", in: "postgresTypeNewName", window: window)
            try await press("previewPostgresTypeDDL", in: window)
            try await fixture.waitForCatalog("typeDDL", count: 3)
            try await waitFor(window) { first.isPreparingPreview && elements(in: window).contains { $0.identifier == "stopPostgresTypeInspection" } }
            try await press("stopPostgresTypeInspection", in: window)
            try await waitFor(window) {
                !first.isPreparingPreview && first.cancellationNotice != nil && findElement("postgresTypeNewName", in: window) != nil
            }
            #expect(first.preview == nil)

            try await replace("hold-preview", in: "postgresTypeNewName", window: window)
            try await press("previewPostgresTypeDDL", in: window)
            try await fixture.waitForCatalog("typeDDL", count: 4)
            let finalRequest = try #require(fixture.commands().last { $0.catalog?.kind == "typeDDL" })
            try await readyForKeys(window)
            _ = try await waitForEnabled("dismissPostgresTypeInspection", in: window)
            let sheet = try #require(window.attachedSheet)
            #expect(sheet.performKeyEquivalent(with: try key(window, characters: "\u{1b}", code: 53)))
            try await waitFor(window) {
                workspace.typeInspection == nil && window.attachedSheet == nil &&
                    (try? fixture.commands().contains { $0.type == "cancel" && $0.queryId == finalRequest.queryId }) == true
            }
            try fixture.releaseHeld()
            await workspace.inspect(fixture.node("another", oid: "40002"))
            let replacement = try #require(workspace.typeInspection)
            try await waitFor(window) { !replacement.isLoading && replacement.details != nil }
            #expect(replacement.id != first.id && replacement.preview == nil)
            #expect(workspace.typeInspection === replacement && workspace.documents.count == 0)
        }
    }
}
