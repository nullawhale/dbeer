import AppKit
import Foundation
import Testing
@testable import DBeer

/// SwiftUI focus effects and native AppKit control rings need separate coverage.
/// NSControl and its cell expose the same ring setting through both APIs.
@Suite(.serialized)
@MainActor
struct NativeButtonFocusTests {
    private func window(content: NSView, width: CGFloat = 1180, height: CGFloat = 760) async throws -> NSWindow {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        // Activating a command-line test host completes on the next main-loop
        // turn. Focus feedback deliberately stays hidden in a non-key window.
        for _ in 0..<20 {
            if window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(25))
            window.makeKey()
        }
        try #require(window.isKeyWindow)
        return window
    }

    private func expectNoNativeRing(_ control: NSControl) {
        #expect(control.focusRingType == .none)
        #expect(control.cell?.focusRingType == NSFocusRingType.none)
    }

    @Test func nativeButtonsPopupsSegmentsAndFieldsReplaceSystemRings() async throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let button = NSButton(title: "Connect", target: nil, action: nil)
        let disabled = NSButton(title: "Stop", target: nil, action: nil)
        disabled.isEnabled = false
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["disable", "verify-full"])
        let segmented = NSSegmentedControl(labels: ["System", "Dark", "Light"],
            trackingMode: .selectOne, target: nil, action: nil)
        let textField = NSTextField(string: "Host")
        let secureField = NSSecureTextField(string: "")
        let controls: [NSControl] = [button, disabled, popup, segmented, textField, secureField]
        for (index, control) in controls.enumerated() {
            control.frame = NSRect(x: 20, y: CGFloat(20 + index * 35), width: 250, height: 25)
            control.focusRingType = .exterior
            control.cell?.focusRingType = .exterior
            content.addSubview(control)
        }
        let window = try await window(content: content, width: 500, height: 300)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)

        for control in [button, disabled, popup, segmented] as [NSControl] { expectNoNativeRing(control) }
        for field in [textField, secureField] {
            expectNoNativeRing(field)
        }
        // Taking focus must not restore the native ring after the policy ran.
        #expect(window.makeFirstResponder(button))
        policy.apply(to: window)
        expectNoNativeRing(button)
        #expect(button.subviews.compactMap { $0 as? NativeButtonHoverView }.first?.isNativeKeyboardFocused == true)
        #expect(window.makeFirstResponder(textField))
        policy.apply(to: window)
        expectNoNativeRing(textField)
        #expect(textField.subviews.compactMap { $0 as? NativeFieldFocusView }.first?.isFocused == true)
        #expect(button.subviews.compactMap { $0 as? NativeButtonHoverView }.first?.isNativeKeyboardFocused == false)
    }

    @Test func notificationsCoverButtonsInsertedAfterStartupAndNewSheets() async throws {
        let policy = NativeButtonFocusPolicy()
        policy.start()
        defer { _ = policy }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = try await window(content: content, width: 500, height: 300)
        defer { window.close() }
        let inserted = NSButton(title: "Disconnect", target: nil, action: nil)
        inserted.focusRingType = .exterior
        inserted.cell?.focusRingType = .exterior
        content.addSubview(inserted)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        expectNoNativeRing(inserted)

        // A SwiftUI state transition can create another native button in the
        // same window; the application update notification must catch it too.
        inserted.focusRingType = .exterior
        inserted.cell?.focusRingType = .exterior
        NotificationCenter.default.post(name: NSApplication.willUpdateNotification, object: NSApplication.shared)
        expectNoNativeRing(inserted)

        let sheetContent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.focusRingType = .exterior
        cancel.cell?.focusRingType = .exterior
        sheetContent.addSubview(cancel)
        let sheet = NSWindow(contentRect: sheetContent.bounds, styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = sheetContent
        defer { window.endSheet(sheet); sheet.close() }
        // Set the ring before presenting the sheet to verify that the new
        // key-window notification covers controls outside the original window.
        cancel.focusRingType = .exterior
        cancel.cell?.focusRingType = .exterior
        window.beginSheet(sheet, completionHandler: nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: sheet)
        expectNoNativeRing(cancel)
    }

    @Test func fieldFocusPreservesNativeEditorsSelectionAndTyping() async throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let number = NSTextField(string: "5432")
        number.formatter = NumberFormatter()
        let fields: [NSTextField] = [NSTextField(string: "Host"), NSSecureTextField(string: "secret"),
            NSSearchField(string: "catalog"), number]
        for (index, field) in fields.enumerated() {
            field.frame = NSRect(x: 20, y: CGFloat(20 + index * 45), width: 300, height: 25)
            field.focusRingType = .exterior
            field.cell?.focusRingType = .exterior
            content.addSubview(field)
        }
        let window = try await window(content: content, width: 400, height: 240)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)

        for field in fields {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            let selection = NSRange(location: 0, length: (editor.string as NSString).length)
            editor.setSelectedRange(selection)
            policy.apply(to: window)
            policy.apply(to: window)
            let overlays = field.subviews.compactMap { $0 as? NativeFieldFocusView }
            let overlay = try #require(overlays.first)
            #expect(overlays.count == 1)
            expectNoNativeRing(field)
            #expect(overlay.isFocused)
            #expect(!overlay.isAccessibilityElement())
            #expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil)
            #expect(field.currentEditor() === editor)
            #expect(editor.selectedRange() == selection)
            editor.insertText("42", replacementRange: selection)
            #expect(editor.string == "42")
            #expect(window.makeFirstResponder(nil))
            policy.apply(to: window)
            #expect(!overlay.isFocused)
            #expect(field.stringValue == "42")
        }
    }

    private func focusPaint(_ overlay: NativeFieldFocusView, appearance: NSAppearance) throws -> [NSColor] {
        let width = Int(overlay.bounds.width)
        let height = Int(overlay.bounds.height)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance { overlay.draw(overlay.bounds) }
        context.flushGraphics()
        return (0..<height).flatMap { y in
            (0..<width).compactMap { x in
                bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            }
        }.filter { $0.alphaComponent > 0.05 }
    }

    @Test func compactAndBorderlessFieldsKeepTheSameTextToFocusBorderSpacing() async throws {
        let plain = NSTextField(string: "Database")
        plain.isBezeled = false
        plain.isBordered = false
        let fields = [plain, NSTextField(string: "Tab name"), NSSecureTextField(string: "secret")]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        for (index, field) in fields.enumerated() {
            field.frame = NSRect(x: 20, y: 20 + index * 45, width: 300, height: index == 0 ? 14 : 24)
            content.addSubview(field)
        }
        let window = try await window(content: content, width: 400, height: 180)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for field in fields {
            for height: CGFloat in [14, 24] {
                field.setFrameSize(NSSize(width: 260, height: height))
                policy.apply(to: window)
                let overlay = try #require(field.subviews.compactMap { $0 as? NativeFieldFocusView }.first)
                let textRect = try #require(field.cell).drawingRect(forBounds: field.bounds)
                let border = overlay.frame.insetBy(dx: 1, dy: 1)
                #expect(textRect.minX - border.minX == 3)
                #expect(border.maxX - textRect.maxX == 3)
                #expect(textRect.minY - border.minY == 3)
                #expect(border.maxY - textRect.maxY == 3)
            }
        }
    }

    @Test func fieldFocusPaintIsAmberInBothThemesAndFollowsFocus() async throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let field = NSTextField(string: "Host")
        field.frame = NSRect(x: 20, y: 20, width: 300, height: 25)
        content.addSubview(field)
        let window = try await window(content: content, width: 400, height: 100)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            #expect(window.makeFirstResponder(field))
            policy.apply(to: window)
            let overlay = try #require(field.subviews.compactMap { $0 as? NativeFieldFocusView }.first)
            let focusedColors = try focusPaint(overlay, appearance: appearance)
            #expect(!focusedColors.isEmpty)
            #expect(focusedColors.allSatisfy { $0.redComponent > $0.greenComponent && $0.greenComponent > $0.blueComponent })
            #expect(window.makeFirstResponder(nil))
            policy.apply(to: window)
            #expect(try focusPaint(overlay, appearance: appearance).isEmpty)
        }
    }

    @Test func containerRingsAreRemovedButSystemPanelFieldsKeepTheirAppearance() async throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let scroll = NSScrollView(frame: content.bounds)
        let text = NSTextView(frame: scroll.bounds)
        scroll.documentView = text
        content.addSubview(scroll)
        let table = NSTableView(frame: .zero)
        content.addSubview(table)
        let label = NSTextField(labelWithString: "Uneditable label")
        label.focusRingType = .exterior
        content.addSubview(label)
        let resultLabel = NSTextField(labelWithString: "Selectable grid result")
        resultLabel.isSelectable = true
        resultLabel.focusRingType = .exterior
        content.addSubview(resultLabel)
        for view in [scroll, text, table] as [NSView] { view.focusRingType = .exterior }
        let window = try await window(content: content, width: 500, height: 300)
        defer { window.close() }
        let policy = NativeButtonFocusPolicy()
        policy.apply(to: window)
        for view in [scroll, text, table] as [NSView] { #expect(view.focusRingType == .none) }
        #expect(label.focusRingType == .exterior)
        #expect(!label.subviews.contains { $0 is NativeFieldFocusView })
        expectNoNativeRing(resultLabel)
        #expect(!resultLabel.subviews.contains { $0 is NativeFieldFocusView })

        let panel = NSSavePanel()
        let panelContent = try #require(panel.contentView)
        let systemField = NSTextField(string: "Export")
        systemField.frame = NSRect(x: 20, y: 20, width: 200, height: 25)
        systemField.focusRingType = .exterior
        panelContent.addSubview(systemField)
        defer { panel.close() }
        policy.apply(to: panel)
        #expect(systemField.focusRingType == .exterior)
        #expect(!systemField.subviews.contains { $0 is NativeFieldFocusView })
    }

}
