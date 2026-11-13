import AppKit

@MainActor
final class ResultGridFindBar: NSView {
    let field = NSSearchField()
    let scope = NSPopUpButton()
    let matchingOnly = NSButton(checkboxWithTitle: "Matches only", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    var changed: (() -> Void)?
    var navigate: ((Int) -> Void)?
    var dismissed: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 64))
        autoresizingMask = [.width]
        field.placeholderString = "Find in loaded rows"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changeSearch)
        field.setAccessibilityLabel("Find in loaded rows")
        field.setAccessibilityIdentifier("gridSearchField")
        scope.addItems(withTitles: ["All columns", "Selected columns"])
        scope.target = self
        scope.action = #selector(changeSearch)
        scope.setAccessibilityLabel("Search columns")
        matchingOnly.target = self
        matchingOnly.action = #selector(changeSearch)
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        status.setAccessibilityIdentifier("gridSearchStatus")
        for (button, image, label, action) in [
            (previous, "chevron.up", "Previous matching cell", #selector(previousMatch)),
            (next, "chevron.down", "Next matching cell", #selector(nextMatch)),
            (close, "xmark", "Close result search", #selector(closeSearch)),
        ] {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        let searchRow = NSStackView(views: [field, previous, next, close])
        let optionsRow = NSStackView(views: [scope, matchingOnly, status])
        for row in [searchRow, optionsRow] {
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            for view in row.arrangedSubviews { (view as? NSControl)?.controlSize = .small }
        }
        let stack = NSStackView(views: [searchRow, optionsRow])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func updateStatus(loadedRows: Int, visibleRows: Int, matches: Int, active: Int?) {
        let matchText = active.map { "\($0 + 1)/\(matches)" } ?? "\(matches) matching cells"
        status.stringValue = field.stringValue.isEmpty ? "\(loadedRows) loaded rows" :
            "\(matchText) · \(loadedRows) loaded rows" + (matchingOnly.state == .on ? " · \(visibleRows) shown" : "")
        status.toolTip = status.stringValue
        status.setAccessibilityValue(status.stringValue)
        previous.isEnabled = matches > 0
        next.isEnabled = matches > 0
        status.textColor = AppPalette.isCustom ? AppPalette.nsColor(.secondaryText) : .secondaryLabelColor
    }

    @objc private func changeSearch() { changed?() }
    @objc private func previousMatch() { navigate?(-1) }
    @objc private func nextMatch() { navigate?(1) }
    @objc private func closeSearch() { dismissed?() }
}
