import AppKit
import SwiftUI

/// Editor-owned child windows, such as completion, retain the editor scheme.
@MainActor
protocol AppThemeIndependentWindow: AnyObject {}

extension View {
    /// The app and SQL editor keep independent palettes. Native controls still
    /// use the matching Aqua appearance for their bezels and interaction.
    @MainActor
    func applicationTheme(appearance: AppAppearance) -> some View {
        modifier(ApplicationThemeModifier(appearance: appearance))
    }

    /// Hierarchical `.secondary` can multiply opacity again over a custom
    /// foreground. Named palettes already provide a readable secondary color.
    @MainActor
    func appSecondaryText() -> some View { modifier(ApplicationSecondaryTextModifier()) }

    /// Grouped Forms own their scroll background separately from the window.
    @MainActor
    func appFormSurface() -> some View { modifier(ApplicationFormSurfaceModifier()) }
}

private struct ApplicationFormSurfaceModifier: ViewModifier {
    @Environment(\.applicationPaletteRevision) private var paletteRevision

    func body(content: Content) -> some View {
        let _ = paletteRevision
        content
            .scrollContentBackground(AppPalette.isCustom ? .hidden : .automatic)
            .background(AppPalette.isCustom ? AppPalette.panel : Color.clear)
    }
}

private struct ApplicationSecondaryTextModifier: ViewModifier {
    @Environment(\.applicationPaletteRevision) private var paletteRevision

    func body(content: Content) -> some View {
        let _ = paletteRevision
        content.foregroundStyle(AppPalette.isCustom ? AnyShapeStyle(AppPalette.secondaryText) : AnyShapeStyle(.secondary))
    }
}

private struct ApplicationPaletteRevisionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var applicationPaletteRevision: Int {
        get { self[ApplicationPaletteRevisionKey.self] }
        set { self[ApplicationPaletteRevisionKey.self] = newValue }
    }
}

private struct ApplicationThemeModifier: ViewModifier {
    @ObservedObject var appearance: AppAppearance

    func body(content: Content) -> some View {
        let _ = appearance.paletteRevision
        // Keep one structural identity while switching: rebuilding this subtree
        // would replace the editor's undo manager and native focus.
        content
            .environment(\.applicationPaletteRevision, appearance.paletteRevision)
            .foregroundStyle(
                appearance.selectedColorTheme == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(AppPalette.text),
                appearance.selectedColorTheme == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppPalette.secondaryText),
                appearance.selectedColorTheme == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(AppPalette.secondaryText))
            .background(appearance.selectedColorTheme == nil ? Color.clear : AppPalette.window)
            .background { ApplicationThemeAnchor() }
    }
}

private struct ApplicationThemeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> ApplicationThemeAnchorView { ApplicationThemeAnchorView() }

    func updateNSView(_ view: ApplicationThemeAnchorView, context: Context) {
        if let window = view.window { AppThemeSurface.apply(in: window) }
    }
}

private final class ApplicationThemeAnchorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(paletteChanged),
            name: .applicationPaletteDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { AppThemeSurface.apply(in: window) }
    }

    @objc private func paletteChanged() {
        if let window { AppThemeSurface.refresh(in: window) }
    }
}

/// Adapts owned AppKit surfaces without changing system colors, button drawing,
/// field editing delegates or the independently themed SQL editor hierarchy.
@MainActor
enum AppThemeSurface {
    private static let windows = NSMapTable<NSWindow, WindowStyle>.weakToStrongObjects()
    private static let views = NSMapTable<NSView, ViewStyle>.weakToStrongObjects()

    static func apply(in window: NSWindow) {
        guard !(window is NSSavePanel), !(window is AppThemeIndependentWindow),
              let content = window.contentView else { return }
        if AppPalette.isCustom {
            let original = windows.object(forKey: window) ?? WindowStyle(window: window)
            windows.setObject(original, forKey: window)
            if window.backgroundColor != AppPalette.nsColor(.window) {
                window.backgroundColor = AppPalette.nsColor(.window)
            }
        } else if let original = windows.object(forKey: window) {
            window.backgroundColor = original.background
            windows.removeObject(forKey: window)
        }
        apply(in: content)
    }

    static func refresh(in window: NSWindow) {
        apply(in: window)
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            for child in view.subviews { invalidate(child) }
        }
        if let content = window.contentView { invalidate(content) }
    }

    private static func apply(in view: NSView) {
        // The ruler and clip view belong to the SQL editor as well. Skipping
        // the entire scroll view also preserves a different editor appearance.
        if view is SQLTextView || (view as? NSScrollView)?.documentView is SQLTextView { return }
        if let grid = view as? ResultGridTableView {
            grid.applyApplicationPalette()
            return
        }
        if AppPalette.isCustom {
            if let style = views.object(forKey: view) ?? ViewStyle(view: view) {
                views.setObject(style, forKey: view)
                style.apply(to: view)
            }
        } else if let style = views.object(forKey: view) {
            style.restore(to: view)
            views.removeObject(forKey: view)
        }
        for child in view.subviews { apply(in: child) }
    }

    @MainActor
    private final class WindowStyle: NSObject {
        let background: NSColor
        init(window: NSWindow) { background = window.backgroundColor }
    }

    @MainActor
    private final class ViewStyle: NSObject {
        private enum Kind {
            case field(text: NSColor?, background: NSColor?, secondary: Bool)
            case text(text: NSColor?, background: NSColor, insertion: NSColor, selection: [NSAttributedString.Key: Any])
            case scroll(background: NSColor)
            case clip(background: NSColor)
            case table(background: NSColor, grid: NSColor, alternating: Bool)
            case effect(ApplicationThemeBackingView)
        }
        private let kind: Kind

        init?(view: NSView) {
            if let field = view as? NSTextField {
                let original = field.textColor
                // Preserve explicit status/error colors and attributed labels.
                let secondary = original == .secondaryLabelColor || original == .tertiaryLabelColor ||
                    original == .disabledControlTextColor
                let standard = original == nil || secondary || original == .labelColor ||
                    original == .controlTextColor || original == .textColor
                guard standard || field.isEditable else { return nil }
                // A sheet created while a scheme is already active can inherit
                // its foreground from SwiftUI before this adapter sees it.
                // Restore that inherited role to its native semantic color.
                let nativeText = original == AppPalette.nsColor(.text) ? NSColor.textColor : original
                kind = .field(text: nativeText, background: field.backgroundColor, secondary: secondary)
            } else if let text = view as? NSTextView {
                let originalText = text.textColor == AppPalette.nsColor(.text) ? NSColor.textColor : text.textColor
                let originalBackground = text.backgroundColor == AppPalette.nsColor(.control)
                    ? NSColor.textBackgroundColor : text.backgroundColor
                let originalInsertion: NSColor = text.insertionPointColor == AppPalette.nsColor(.accent)
                    ? NSColor.textColor : (text.insertionPointColor ?? .textColor)
                let originalSelection: [NSAttributedString.Key: Any] =
                    text.selectedTextAttributes[.backgroundColor] as? NSColor == AppPalette.nsColor(.selection)
                        ? [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
                        : text.selectedTextAttributes
                kind = .text(text: originalText, background: originalBackground,
                    insertion: originalInsertion, selection: originalSelection)
            } else if let table = view as? NSTableView {
                kind = .table(background: table.backgroundColor, grid: table.gridColor,
                    alternating: table.usesAlternatingRowBackgroundColors)
            } else if let scroll = view as? NSScrollView {
                kind = .scroll(background: scroll.backgroundColor)
            } else if let clip = view as? NSClipView {
                kind = .clip(background: clip.backgroundColor)
            } else if let effect = view as? NSVisualEffectView {
                let backing = ApplicationThemeBackingView(frame: effect.bounds)
                backing.autoresizingMask = [.width, .height]
                effect.addSubview(backing, positioned: .below, relativeTo: nil)
                kind = .effect(backing)
            } else { return nil }
        }

        func apply(to view: NSView) {
            switch kind {
            case .field(_, _, let secondary):
                guard let field = view as? NSTextField else { return }
                let text = AppPalette.nsColor(secondary ? .secondaryText : .text)
                if field.textColor != text { field.textColor = text }
                if field.drawsBackground, field.backgroundColor != AppPalette.nsColor(.control) {
                    field.backgroundColor = AppPalette.nsColor(.control)
                }
            case .text:
                guard let text = view as? NSTextView else { return }
                if text.textColor != AppPalette.nsColor(.text) { text.textColor = AppPalette.nsColor(.text) }
                if text.backgroundColor != AppPalette.nsColor(.control) { text.backgroundColor = AppPalette.nsColor(.control) }
                if text.insertionPointColor != AppPalette.nsColor(.accent) { text.insertionPointColor = AppPalette.nsColor(.accent) }
                let selection = AppPalette.nsColor(.selection)
                if text.selectedTextAttributes[.backgroundColor] as? NSColor != selection {
                    text.selectedTextAttributes = [.backgroundColor: selection, .foregroundColor: AppPalette.nsColor(.selectionText)]
                }
            case .scroll:
                if let scroll = view as? NSScrollView, scroll.backgroundColor != AppPalette.nsColor(.panel) {
                    scroll.backgroundColor = AppPalette.nsColor(.panel)
                }
            case .clip:
                if let clip = view as? NSClipView, clip.backgroundColor != AppPalette.nsColor(.panel) {
                    clip.backgroundColor = AppPalette.nsColor(.panel)
                }
            case .table:
                guard let table = view as? NSTableView else { return }
                let background = AppPalette.nsColor(table is NSOutlineView ? .sidebar : .panel)
                if table.backgroundColor != background { table.backgroundColor = background }
                if table.gridColor != AppPalette.nsColor(.border) { table.gridColor = AppPalette.nsColor(.border) }
                if table.usesAlternatingRowBackgroundColors { table.usesAlternatingRowBackgroundColors = false }
            case .effect: break
            }
        }

        func restore(to view: NSView) {
            switch kind {
            case .field(let text, let background, _):
                (view as? NSTextField)?.textColor = text
                (view as? NSTextField)?.backgroundColor = background
            case .text(let color, let background, let insertion, let selection):
                guard let text = view as? NSTextView else { return }
                text.textColor = color
                text.backgroundColor = background
                text.insertionPointColor = insertion
                text.selectedTextAttributes = selection
            case .scroll(let background): (view as? NSScrollView)?.backgroundColor = background
            case .clip(let background): (view as? NSClipView)?.backgroundColor = background
            case .table(let background, let grid, let alternating):
                guard let table = view as? NSTableView else { return }
                table.backgroundColor = background
                table.gridColor = grid
                table.usesAlternatingRowBackgroundColors = alternating
            case .effect(let backing): backing.removeFromSuperview()
            }
        }
    }
}

private final class ApplicationThemeBackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        AppPalette.nsColor(.panel).setFill()
        dirtyRect.fill()
    }
}
