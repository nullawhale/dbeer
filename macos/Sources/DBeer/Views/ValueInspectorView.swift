import AppKit
import SwiftUI

/// Keeps inspection local to this result view; it never edits a grid or opens a session.
struct InspectedResultTableView: View {
    let table: ResultTableView
    var rowDetails: GridRowDetailsView?
    @StateObject private var inspector = ValueInspectorModel()

    var body: some View {
        HSplitView {
            inspectedTable.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            if let rowDetails {
                rowDetails.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            } else {
                ValueInspectorView(model: inspector)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 600, maxHeight: .infinity)
            }
        }
        .onDisappear { inspector.cancel() }
    }

    private var inspectedTable: ResultTableView {
        var view = table
        view.onInspectValue = { inspector.select($0) }
        return view
    }
}

struct ValueInspectorView: View {
    @ObservedObject var model: ValueInspectorModel
    private var wrap = SwiftUI.State(initialValue: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Value Inspector").font(.headline).padding(12)
            Divider()
            if let value = model.selection {
                VStack(alignment: .leading, spacing: 5) {
                    Text(value.name).font(.callout.weight(.medium)).textSelection(.enabled).lineLimit(2)
                    Text("Row \(value.row + 1) · Column \(value.column + 1)")
                        .font(.caption).monospacedDigit().appSecondaryText()
                    Text([value.nativeType, value.description].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).appSecondaryText().textSelection(.enabled)
                    HStack(spacing: 8) {
                        Toggle("Wrap", isOn: wrap.projectedValue).toggleStyle(.checkbox).controlHover()
                            .help("Wrap long lines without changing the value")
                            .accessibilityIdentifier("valueInspectorWrap")
                        Spacer(minLength: 0)
                        if model.content.formatted != nil {
                            Toggle("Format JSON", isOn: $model.formatted).toggleStyle(.checkbox).controlHover()
                                .help("Show formatted JSON while preserving the original value")
                                .accessibilityIdentifier("valueInspectorFormatJSON")
                        }
                    }.font(.caption)
                    HStack(spacing: 4) {
                        TextField("Find in value", text: $model.query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.moveMatch(1) }
                            .accessibilityLabel("Find in value").accessibilityIdentifier("valueInspectorSearch")
                        if !model.query.isEmpty {
                            Text(model.matches.isEmpty ? "0" : "\(model.matchIndex + 1)/\(model.matches.count)\(model.matches.count == 10_000 ? "+" : "")")
                                .font(.caption2).monospacedDigit().appSecondaryText()
                            ControlIconButton(systemName: "chevron.up") { model.moveMatch(-1) }
                                .disabled(model.matches.isEmpty).help("Previous match").accessibilityLabel("Previous match")
                            ControlIconButton(systemName: "chevron.down") { model.moveMatch(1) }
                                .disabled(model.matches.isEmpty).help("Next match").accessibilityLabel("Next match")
                        }
                    }
                }.padding(12)
                if model.isProcessing {
                    ProgressView("Preparing preview…").controlSize(.small).font(.caption).padding(.horizontal, 12)
                }
                if let notice = model.content.notice {
                    Text(notice).font(.caption).appSecondaryText().padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
                InspectorTextView(text: model.text, tokens: model.tokens, wrap: wrap.wrappedValue, matches: model.matches,
                    activeMatch: model.matches.indices.contains(model.matchIndex) ? model.matches[model.matchIndex] : nil)
                    .accessibilityIdentifier("valueInspectorText")
            } else {
                Text("Select a cell to inspect its value. Use the arrow keys to move between cells.")
                    .font(.callout).appSecondaryText().padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(AppPalette.panel)
        .accessibilityElement(children: .contain).accessibilityIdentifier("valueInspector")
    }
}

/// A read-only native text view preserves selectable source text and normal Copy/Find keys.
private struct InspectorTextView: NSViewRepresentable {
    let text: String
    let tokens: [InspectorToken]
    let wrap: Bool
    let matches: [NSRange]
    let activeMatch: NSRange?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("Inspected value")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let changed = !view.string.utf8.elementsEqual(text.utf8)
        if changed { view.string = text; view.scrollToBeginningOfDocument(nil) }
        view.backgroundColor = AppPalette.nsColor(.panel)
        view.insertionPointColor = AppPalette.nsColor(.text)
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor]
        if changed || coordinator.tokens != tokens || coordinator.appearance != colorScheme ||
            coordinator.textColor != AppPalette.nsColor(.text) {
            let entire = NSRange(location: 0, length: (text as NSString).length)
            view.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: AppPalette.nsColor(.text)], range: entire)
            for token in tokens where NSMaxRange(token.range) <= entire.length {
                let color: NSColor
                switch token.kind {
                case .key, .markup: color = .systemPurple
                case .string: color = .systemRed
                case .number: color = .systemBlue
                case .literal: color = .systemOrange
                case .comment: color = .secondaryLabelColor
                }
                view.textStorage?.addAttribute(.foregroundColor, value: color, range: token.range)
            }
            coordinator.tokens = tokens
            coordinator.appearance = colorScheme
            coordinator.textColor = AppPalette.nsColor(.text)
        }
        if changed || coordinator.wrap != wrap {
            view.isHorizontallyResizable = !wrap
            view.textContainer?.widthTracksTextView = wrap
            view.textContainer?.containerSize = NSSize(width: wrap ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            view.frame.size.width = max(1, scroll.contentSize.width)
            scroll.hasHorizontalScroller = !wrap
            coordinator.wrap = wrap
        }
        if changed || coordinator.matches != matches {
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            for range in matches {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3),
                    forCharacterRange: range)
            }
            coordinator.matches = matches
        }
        if let activeMatch, changed || coordinator.activeMatch != activeMatch {
            view.scrollRangeToVisible(activeMatch)
        }
        coordinator.activeMatch = activeMatch
    }

    final class Coordinator {
        var tokens: [InspectorToken] = []
        var matches: [NSRange] = []
        var activeMatch: NSRange?
        var wrap: Bool?
        var appearance: ColorScheme?
        var textColor: NSColor?
    }
}
