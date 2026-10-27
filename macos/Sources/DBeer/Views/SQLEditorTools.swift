import AppKit
import Combine

@MainActor private final class EditorPanelContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// Folding changes generated glyphs only. NSTextStorage always contains the
/// complete source, so files, execution, Undo and diagnostics share coordinates.
@MainActor final class SQLFoldingLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
    var hiddenRanges: [NSRange] = [] {
        didSet {
            guard let storage = textStorage else { return }
            invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0,
                             actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes indexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        for index in 0..<range.length {
            let position = indexes[index]
            var low = 0, high = hiddenRanges.count
            while low < high {
                let middle = (low + high) / 2
                if hiddenRanges[middle].location <= position { low = middle + 1 } else { high = middle }
            }
            if low > 0, NSLocationInRange(position, hiddenRanges[low - 1]) { properties[index] = .null }
        }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: indexes,
                                    font: font, forGlyphRange: range)
        }
        return range.length
    }
}

@MainActor final class SQLEditorToolsController: NSObject, NSTextFieldDelegate {
    private weak var editor: SQLTextView?
    private var documentID: UUID?
    private var engine: DatabaseEngine = .postgresql
    private var service: SQLLanguageService?
    private var context: SQLCompletionContext = .empty
    private var generation = 0
    private var analysisTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private(set) var analysis: SQLEditorAnalysis?
    private(set) var collapsedRanges: [NSRange] = []
    private var visibleFoldRanges: [(range: NSRange, lineCount: Int)] = []
    private let fallbackShortcuts = AppShortcutStore()
    nonisolated(unsafe) private var preferenceObservation: NSObjectProtocol?
    private var findPanel: NSPanel?
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let matchCase = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let regex = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let inSelection = NSButton(checkboxWithTitle: "In selection", target: nil, action: nil)
    private var searchRanges: [NSRange]?
    private var replacing = false
    private var searchTask: Task<Void, Never>?
    private var searchActionTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var referenceRanges: [NSRange] = []
    var revealCatalogObject: ((SQLEditorDefinition) -> Void)?

    override init() {
        super.init()
        preferenceObservation = NotificationCenter.default.addObserver(forName: .editorPreferencesChanged,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let editor = self?.editor { SQLEditorPreferences.shared.apply(to: editor) }
                }
            }
    }
    deinit {
        if let preferenceObservation { NotificationCenter.default.removeObserver(preferenceObservation) }
        analysisTask?.cancel()
        commandTask?.cancel()
        searchTask?.cancel()
        searchActionTask?.cancel()
    }

    func configure(editor: SQLTextView, documentID: UUID, engine: DatabaseEngine,
                   languageService: SQLLanguageService?, completionContext: SQLCompletionContext) {
        let changed = self.editor !== editor || self.documentID != documentID || self.engine != engine ||
            context != completionContext || service !== languageService
        self.editor = editor; self.documentID = documentID; self.engine = engine
        service = languageService; context = completionContext
        SQLEditorPreferences.shared.apply(to: editor)
        if changed { generation += 1; analysis = nil; referenceRanges = []; expandAll(); requestAnalysis() }
    }

    func detach() {
        generation += 1
        analysisTask?.cancel(); commandTask?.cancel(); searchTask?.cancel(); searchActionTask?.cancel()
        if let panel = findPanel { panel.parent?.removeChildWindow(panel); panel.close() }
        editor = nil; service = nil; documentID = nil
    }

    func canPerform(_ command: SQLToolCommand) -> Bool {
        guard let editor, !editor.hasMarkedText() else { return false }
        if [.toggleLineComment, .toggleBlockComment].contains(command), engine == .mongodb { return false }
        if [.formatSelection].contains(command) { return editor.isEditable && editor.editorSelections.contains { $0.length > 0 } }
        if command == .formatCurrent { return editor.isEditable && !editor.hasMultipleEditorSelections }
        if command.textAction != nil || [.replace, .formatCurrent, .formatDocument].contains(command) { return editor.isEditable }
        return true
    }

    func perform(_ command: SQLToolCommand) {
        guard canPerform(command), let editor else { return }
        if let action = command.textAction { editor.performEditorAction(action); return }
        if [.outline, .definition, .showInformation, .collapseCurrent, .collapseAll].contains(command), analysis == nil {
            guard let service, let documentID else { message("Language assistance is unavailable."); return }
            commandTask?.cancel()
            let source = editor.string, caret = editor.selectedRange().location, captured = generation
            commandTask = Task { [weak self, weak editor] in
                guard let result = await service.editorAnalysis(documentID: documentID, offset: caret),
                      !Task.isCancelled, let self, let editor, editor.string == source, self.generation == captured,
                      editor.selectedRange().location == caret else { return }
                self.analysis = result; self.referenceRanges = result.references
                self.perform(command)
            }
            return
        }
        switch command {
        case .find, .replace: showFind(replace: command == .replace)
        case .findNext: find(forward: true)
        case .findPrevious: find(forward: false)
        case .formatCurrent, .formatSelection, .formatDocument: format(command)
        case .goToLine: goToLine()
        case .nextStatement, .previousStatement: moveStatement(forward: command == .nextStatement)
        case .outline: showOutline()
        case .definition, .showInformation: showDefinition(informationOnly: command == .showInformation)
        case .collapseCurrent: collapseCurrent()
        case .expandCurrent: expandCurrent()
        case .collapseAll: collapseAll()
        case .expandAll: expandAll()
        default: break
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let editor, editor.window?.firstResponder === editor else { return false }
        // Workspace-backed views route every binding through the shared command
        // registry. Standalone preview/test editors use the same persisted store.
        guard editor.commandEvent == nil else { return false }
        if let command = SQLToolCommand.allCases.first(where: {
            fallbackShortcuts.shortcut(for: $0.commandID)?.matches(event: event) == true && canPerform($0)
        }) { perform(command); return true }
        return false
    }

    func prepareForEdit() { expandAll() }
    func textDidChange() {
        generation += 1; analysis = nil; referenceRanges = []; expandAll()
        if !replacing { searchRanges = nil; inSelection.state = .off }
        requestAnalysis()
        if findPanel?.isVisible == true { updateSearchStatus() }
    }
    func selectionDidChange() {
        guard let editor else { return }
        analysis = nil; referenceRanges = []
        reveal(editor.editorSelections.first ?? editor.selectedRange())
        requestAnalysis()
    }

    private func requestAnalysis() {
        analysisTask?.cancel()
        guard let editor, let service, let documentID else { return }
        let source = editor.string, caret = editor.editorSelections.first?.location ?? 0
        let captured = generation
        analysisTask = Task { [weak self, weak editor] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            guard let result = await service.editorAnalysis(documentID: documentID, offset: caret),
                  !Task.isCancelled, let self, let editor, editor.string == source, self.generation == captured else { return }
            self.analysis = result
            self.referenceRanges = result.references
            editor.needsDisplay = true
        }
    }

    private func options() -> EditorSearchOptions {
        .init(caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on,
              regularExpression: regex.state == .on)
    }
    private func matches() throws -> [NSTextCheckingResult] {
        try EditorSearch.matches(text: editor?.string ?? "", query: findField.stringValue, options: options(),
                                 ranges: inSelection.state == .on ? searchRanges : nil)
    }
    func controlTextDidChange(_ obj: Notification) { updateSearchStatus() }
    @objc private func searchOptionsChanged() { updateSearchStatus() }
    private func updateSearchStatus() {
        searchTask?.cancel(); searchGeneration += 1
        let captured = searchGeneration, source = editor?.string ?? "", query = findField.stringValue
        let options = options(), ranges = inSelection.state == .on ? searchRanges : nil
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let label = await Task.detached {
                do { let count = try EditorSearch.matches(text: source, query: query, options: options, ranges: ranges).count
                    return "\(count) \(count == 1 ? "match" : "matches")"
                } catch let error as EditorSearch.LimitError { return error.localizedDescription }
                catch { return "Invalid regular expression" }
            }.value
            guard !Task.isCancelled, let self, self.searchGeneration == captured else { return }
            self.status.stringValue = label
        }
    }
    func showFind(replace: Bool) {
        guard let editor, let window = editor.window else { return }
        if findPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 210),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Find and Replace"; panel.isReleasedWhenClosed = false
            panel.contentView = EditorPanelContentView(frame: NSRect(x: 0, y: 0, width: 560, height: 210))
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            findField.placeholderString = "Find"; findField.delegate = self; findField.setAccessibilityIdentifier("editorFindField")
            replaceField.placeholderString = "Replace with"; replaceField.setAccessibilityIdentifier("editorReplaceField")
            status.setAccessibilityIdentifier("editorSearchStatus")
            stack.addArrangedSubview(findField); stack.addArrangedSubview(replaceField)
            let toggles = NSStackView(views: [matchCase, wholeWord, regex, inSelection]); toggles.spacing = 12
            for toggle in [matchCase, wholeWord, regex, inSelection] { toggle.target = self; toggle.action = #selector(searchOptionsChanged) }
            for toggle in [matchCase, wholeWord, regex, inSelection] {
                toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
                toggle.setContentHuggingPriority(.required, for: .horizontal)
            }
            stack.addArrangedSubview(toggles)
            let buttons = NSStackView(views: [button("Previous", #selector(previousMatch)), button("Next", #selector(nextMatch)),
                button("Replace", #selector(replaceMatch)), button("Replace All", #selector(replaceAllMatches))])
            buttons.spacing = 8; stack.addArrangedSubview(buttons); stack.addArrangedSubview(status)
            panel.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
                findField.widthAnchor.constraint(equalTo: stack.widthAnchor), replaceField.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            findPanel = panel
        }
        searchRanges = editor.editorSelections.filter { $0.length > 0 }
        if searchRanges?.isEmpty == true { searchRanges = nil }
        inSelection.isEnabled = searchRanges != nil
        if searchRanges == nil { inSelection.state = .off }
        if let range = searchRanges?.first, range.length < 512 { findField.stringValue = (editor.string as NSString).substring(with: range) }
        replaceField.isHidden = false
        findPanel?.appearance = editor.appearance
        if let panel = findPanel, panel.parent !== window { window.addChildWindow(panel, ordered: .above); panel.center() }
        findPanel?.makeKeyAndOrderFront(nil); findPanel?.makeFirstResponder(findField)
        updateSearchStatus()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
    @objc private func nextMatch() { find(forward: true) }
    @objc private func previousMatch() { find(forward: false) }
    @discardableResult func find(forward: Bool) -> Task<Void, Never>? {
        guard let editor else { return nil }
        let selection = editor.editorSelections.first ?? editor.selectedRange()
        let source = editor.string, query = findField.stringValue, options = options()
        let ranges = inSelection.state == .on ? searchRanges : nil
        searchActionTask?.cancel()
        let task = Task { [weak self, weak editor] in
            let result = await Task.detached { () -> (ranges: [NSRange], error: String?) in
                do { return (try EditorSearch.matches(text: source, query: query, options: options, ranges: ranges).map(\.range), nil) }
                catch let error as EditorSearch.LimitError { return ([], error.localizedDescription) }
                catch { return ([], "Invalid regular expression") }
            }.value
            guard !Task.isCancelled, let self, let editor, editor.string == source else { return }
            if let error = result.error { self.status.stringValue = error; return }
            let found = result.ranges
            guard !found.isEmpty else { self.status.stringValue = "0 matches"; return }
            let match = forward ? (found.first { $0.location >= NSMaxRange(selection) && $0 != selection } ?? found[0]) :
                (found.last { $0.location < selection.location } ?? found[found.count - 1])
            self.select(match, focus: false); self.updateSearchStatus()
        }
        searchActionTask = task
        return task
    }
    @objc private func replaceMatch() { replaceMatches(all: false) }
    @objc private func replaceAllMatches() { replaceMatches(all: true) }
    @discardableResult func replaceMatches(all: Bool) -> Task<Void, Never>? {
        guard let editor, editor.isEditable else { return nil }
        let selected = editor.editorSelections.first ?? editor.selectedRange()
        let source = editor.string, query = findField.stringValue, replacement = replaceField.stringValue, options = options()
        let ranges = inSelection.state == .on ? searchRanges : nil
        searchActionTask?.cancel()
        let task = Task { [weak self, weak editor] in
            let result = await Task.detached { () -> (edits: [SQLTextEdit], error: String?) in
                do {
                    let found = try EditorSearch.matches(text: source, query: query, options: options, ranges: ranges)
                    let expression = try EditorSearch.expression(query, options: options)
                    let targets = all ? found : found.filter { $0.range == selected }
                    return (targets.map { match in SQLTextEdit(range: match.range, text: options.regularExpression ?
                        expression.replacementString(for: match, in: source, offset: 0, template: replacement) : replacement) }, nil)
                } catch let error as EditorSearch.LimitError { return ([], error.localizedDescription) }
                catch { return ([], "Invalid regular expression") }
            }.value
            guard !Task.isCancelled, let self, let editor, editor.isEditable, editor.string == source else { return }
            if let error = result.error { self.status.stringValue = error; return }
            guard !result.edits.isEmpty else { self.find(forward: true); return }
            self.replacing = true; defer { self.replacing = false }
            for edit in result.edits { self.reveal(edit.range) }
            editor.applyEditorEdits(result.edits, actionName: all ? "Replace All" : "Replace")
            self.searchRanges = nil; self.inSelection.state = .off
            self.updateSearchStatus()
            if !all { self.find(forward: true) }
        }
        searchActionTask = task
        return task
    }

    private func format(_ command: SQLToolCommand) {
        guard let editor, let service, let documentID else { message("Language assistance is unavailable."); return }
        let ranges: [NSRange?]
        if command == .formatDocument { ranges = [nil] }
        else if command == .formatSelection { ranges = editor.editorSelections.filter { $0.length > 0 }.map(Optional.some) }
        else {
            guard let range = SQLExecutionFragment.resolve(text: editor.string, selection: editor.selectedRange(), engine: engine)?.range else { return }
            ranges = [range]
        }
        let source = editor.string, captured = generation, preferences = SQLEditorPreferences.shared
        let options = SQLEditorFormatOptions(insertSpaces: !preferences.usesTabs, tabSize: preferences.indentWidth,
                                            keywordCase: preferences.keywordCase)
        Task { [weak self, weak editor] in
            var edits: [SQLTextEdit] = []
            for range in ranges {
                guard let result = await service.format(documentID: documentID, range: range, options: options),
                      let self, let editor, editor.string == source, self.generation == captured else { return }
                if let error = result.error { self.message(error); return }
                edits += result.edits.map { SQLTextEdit(range: $0.range, text: $0.text) }
            }
            guard let self, let editor, editor.string == source, self.generation == captured else { return }
            self.expandAll(); editor.applyEditorEdits(edits, actionName: "Format")
        }
    }

    func select(_ range: NSRange, focus: Bool = true) {
        guard let editor, range.location <= editor.string.utf16.count, range.length <= editor.string.utf16.count - range.location else { return }
        reveal(range); editor.setEditorSelections([range]); editor.scrollRangeToVisible(range)
        if focus { editor.window?.makeFirstResponder(editor) }
    }
    func reveal(_ range: NSRange) {
        let old = collapsedRanges
        collapsedRanges.removeAll { fold in NSIntersectionRange(fold, range).length > 0 || NSLocationInRange(range.location, fold) }
        if old != collapsedRanges { updateFolds() }
    }
    private func goToLine() {
        let field = NSTextField(string: "1")
        let alert = NSAlert(); alert.messageText = "Go to Line"; alert.accessoryView = field
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.addButton(withTitle: "Go"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let line = Int(field.stringValue), line > 0, let editor else { return }
        let source = editor.string as NSString; var offset = 0
        for _ in 1..<line { guard offset < source.length else { break }; offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0))) }
        select(NSRange(location: min(offset, source.length), length: 0))
    }
    private func moveStatement(forward: Bool) {
        guard let editor else { return }
        let ranges: [NSRange]
        if engine == .mongodb {
            ranges = (analysis?.symbols.map(\.selectionRange) ?? []).sorted { $0.location < $1.location }
        } else {
            ranges = analysis?.symbols.filter { $0.kind == "statement" }.map(\.selectionRange) ??
                SQLScriptParser.parse(editor.string, engine: engine).statements.map(\.range)
        }
        let offset = editor.selectedRange().location
        if let range = forward ? ranges.first(where: { $0.location > offset }) : ranges.last(where: { $0.location < offset }) {
            select(NSRange(location: range.location, length: 0))
        }
    }
    private func showOutline() {
        guard let analysis, !analysis.symbols.isEmpty else { requestAnalysis(); message("Document structure is loading. Try again shortly."); return }
        let symbols = analysis.symbols.sorted { a, b in a.range.location == b.range.location ? a.range.length > b.range.length : a.range.location < b.range.location }
        choose(title: "Document Outline", labels: symbols.map { "\($0.kind): \($0.name)" }) { [weak self] index in
            self?.select(symbols[index].selectionRange)
        }
    }
    private func showDefinition(informationOnly: Bool) {
        guard let analysis, !analysis.definitions.isEmpty else { requestAnalysis(); message("No definition in this document or the loaded catalog. Connect and Refresh to load metadata."); return }
        let definitions = analysis.definitions
        let open: (Int) -> Void = { [weak self] index in
            let definition = definitions[index]
            if informationOnly {
                self?.message(([definition.schema, definition.name, definition.kind, definition.detail].compactMap { $0 }).joined(separator: " · "))
            } else if let range = definition.range { self?.select(range) }
            else if let reveal = self?.revealCatalogObject { reveal(definition) }
            else { self?.message(definition.detail ?? "\(definition.schema.map { $0 + "." } ?? "")\(definition.name) · \(definition.kind)") }
        }
        if definitions.count == 1 { open(0) }
        else { choose(title: "Choose Definition", labels: definitions.map { "\($0.schema.map { $0 + "." } ?? "")\($0.name) · \($0.kind)" }, selected: open) }
    }
    private func choose(title: String, labels: [String], selected: @escaping (Int) -> Void) {
        let menu = NSMenu(title: title)
        for (index, label) in labels.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(chosenItem(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; menu.addItem(item)
        }
        choiceHandler = selected
        if let editor { menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: editor) }
        choiceHandler = nil
    }
    private var choiceHandler: ((Int) -> Void)?
    @objc private func chosenItem(_ sender: NSMenuItem) { choiceHandler?(sender.tag) }
    private func message(_ text: String) {
        guard let window = editor?.window else { return }
        let alert = NSAlert(); alert.messageText = "Editor"; alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    func collapseAll() {
        guard let editor else { return }
        collapsedRanges = (analysis?.folds ?? []).compactMap { hiddenPart(of: $0, source: editor.string) }
        updateFolds()
    }
    func collapseCurrent() {
        guard let editor else { return }
        let location = editor.selectedRange().location
        if let range = analysis?.folds.filter({ NSLocationInRange(location, $0) }).min(by: { $0.length < $1.length }),
           let hidden = hiddenPart(of: range, source: editor.string), !collapsedRanges.contains(hidden) {
            let header = (editor.string as NSString).lineRange(for: NSRange(location: range.location, length: 0)).location
            editor.setEditorSelections([NSRange(location: header, length: 0)])
            collapsedRanges.append(hidden); updateFolds()
        }
    }
    func expandCurrent() {
        guard let editor else { return }
        let source = editor.string as NSString, caret = editor.selectedRange().location
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        collapsedRanges.removeAll { ($0.location >= NSMaxRange(line) - 2 && $0.location < NSMaxRange(line)) || NSLocationInRange(caret, $0) }; updateFolds()
    }
    func expandAll() { if !collapsedRanges.isEmpty { collapsedRanges = []; updateFolds() } }
    private func hiddenPart(of range: NSRange, source: String) -> NSRange? {
        let source = source as NSString
        guard range.location < source.length, NSMaxRange(range) <= source.length else { return nil }
        let start = NSMaxRange(source.lineRange(for: NSRange(location: range.location, length: 0)))
        let end = NSMaxRange(range)
        guard end > start else { return nil }
        // Hide the header's newline too; otherwise every hidden block leaves an
        // empty layout line. Keep its first line visible as the folding anchor.
        var hiddenStart = start - 1
        if hiddenStart > range.location, source.character(at: hiddenStart) == 10, source.character(at: hiddenStart - 1) == 13 {
            hiddenStart -= 1
        }
        return NSRange(location: max(range.location, hiddenStart), length: end - max(range.location, hiddenStart))
    }
    private func updateFolds() {
        var visible: [NSRange] = []
        for range in collapsedRanges.sorted(by: { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }) {
            if let last = visible.last, NSMaxRange(last) >= NSMaxRange(range) { continue }
            if let last = visible.last, NSMaxRange(last) > range.location {
                visible[visible.count - 1] = NSUnionRange(last, range)
            } else { visible.append(range) }
        }
        visibleFoldRanges = visible.map { range in
            let content = ((editor?.string ?? "") as NSString).substring(with: range)
            let count = content.reduce(into: 0) { result, character in
                if character == "\r" || character == "\n" || character == "\r\n" { result += 1 }
            }
            return (range, count)
        }
        (editor?.layoutManager as? SQLFoldingLayoutManager)?.hiddenRanges = visible
        editor?.needsDisplay = true; editor?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    func drawOverlay(in editor: SQLTextView, rect: NSRect) {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        if editor.editorSelectionLimitReached {
            let label = "Multiple cursors limited to 4,096." as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
            let size = label.size(withAttributes: attributes)
            let bounds = NSRect(x: max(editor.visibleRect.minX + 8, editor.visibleRect.maxX - size.width - 16),
                                y: editor.visibleRect.minY + 5, width: size.width + 8, height: size.height + 4)
            NSColor.controlBackgroundColor.setFill(); bounds.fill()
            label.draw(at: NSPoint(x: bounds.minX + 4, y: bounds.minY + 2), withAttributes: attributes)
        }
        for fold in visibleFoldRanges {
            let range = fold.range
            let glyph = layout.glyphIndexForCharacter(at: max(0, range.location - 1))
            let bounds = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let hasError = editor.syntaxDiagnostics.contains { NSIntersectionRange($0.range, range).length > 0 } ||
                editor.syntaxErrorPosition.map { NSLocationInRange($0, range) } == true
            let label = "  ⋯ \(fold.lineCount) lines" + (hasError ? " ⚠" : "")
            let point = NSPoint(x: min(bounds.maxX + editor.textContainerOrigin.x, container.containerSize.width - 90),
                                y: bounds.minY + editor.textContainerOrigin.y)
            (label as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        if editor.editorSelections.count == 1 {
            for range in referenceRanges where range.length > 0 && NSMaxRange(range) <= editor.string.utf16.count &&
                !collapsedRanges.contains(where: { NSIntersectionRange(range, $0).length > 0 }) {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container) { rect, _ in
                    let bounds = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
                    NSBezierPath(rect: bounds.insetBy(dx: -1, dy: -1)).stroke()
                }
            }
        }
    }
}
