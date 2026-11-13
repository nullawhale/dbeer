import AppKit
import SwiftUI

struct GridProfileView: View {
    let report: GridProfileReport
    var serverProfile: ((ResultColumn) throws -> GridProfileServerModel)? = nil
    var investigations: InvestigationLibraryModel? = nil
    var mayAttach: @MainActor () -> Bool = { true }
    @Environment(\.dismiss) private var dismiss
    private var columnID = SwiftUI.State<Int?>(initialValue: nil)
    private var server = SwiftUI.State<GridProfileServerModel?>(initialValue: nil)
    private var attaching = SwiftUI.State<Bool>(initialValue: false)
    private var error = SwiftUI.State<String?>(initialValue: nil)
    private var copying = SwiftUI.State<Bool>(initialValue: false)
    private var selected: GridProfileColumn? { report.columns.first { $0.id == columnID.wrappedValue } ?? report.columns.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Data Profile").font(.title2)
                Spacer()
                if investigations != nil { Button("Attach to Investigation…") { attaching.wrappedValue = true }.controlHover().disabled(!mayAttach()) }
                Button("Copy Report", action: copyReport).controlHover().disabled(copying.wrappedValue)
                Button("Done") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
            }
            Text(report.scope.title).font(.headline).textSelection(.enabled)
            Text("Frozen observation · " + report.scope.capturedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).appSecondaryText()
            Text(report.scope.notice).font(.caption).appSecondaryText().textSelection(.enabled)
            if report.scope.partial { Label("Partial or bounded observation", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Picker("Column", selection: Binding(get: { selected?.id }, set: { columnID.wrappedValue = $0 })) {
                ForEach(report.columns) { column in Text(column.sourceColumn.name).tag(Optional(column.id)) }
            }
            if let selected {
                GridProfileColumnView(column: selected)
                if let serverProfile {
                    Button("Capture First-N Server Sample…") {
                        do { server.wrappedValue = try serverProfile(selected.sourceColumn); error.wrappedValue = nil }
                        catch { self.error.wrappedValue = error.localizedDescription }
                    }.controlHover().help("Explicitly read a bounded sample using a separate readonly connection")
                }
            }
            if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(16).frame(minWidth: 600, idealWidth: 760, minHeight: 500, idealHeight: 620)
        .sheet(item: server.projectedValue) { model in GridProfileServerView(model: model, investigations: investigations, mayAttach: mayAttach) }
        .sheet(isPresented: attaching.projectedValue) {
            if let investigations { GridProfileAttachmentView(report: report, library: investigations, mayAttach: mayAttach) }
        }
    }
    private func copyReport() {
        let board = NSPasteboard.general
        let changeCount = board.changeCount
        copying.wrappedValue = true
        Task {
            let report = self.report
            let text = await Task.detached(priority: .userInitiated) { report.markdown }.value
            copying.wrappedValue = false
            guard text.utf8.count <= InvestigationLimits.maximumBlockBytes else {
                error.wrappedValue = "Select fewer columns to copy a report of at most 16 MiB."; return
            }
            guard board.changeCount == changeCount else { error.wrappedValue = "The clipboard changed while the report was prepared. Copy again."; return }
            board.clearContents(); board.setString(text, forType: .string)
        }
    }
}

private struct GridProfileColumnView: View {
    let column: GridProfileColumn
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                metric("Count", String(column.count)); metric("SQL NULL", String(column.nullCount))
                metric("DEFAULT", String(column.defaultCount)); metric("Distinct representations", String(column.distinctCount))
            }
            if let sum = column.sum {
                HStack {
                    metric("Exact sum", sum); metric("Exact average", column.average ?? "Unavailable")
                    metric("Minimum", column.minimum ?? "Unavailable"); metric("Maximum", column.maximum ?? "Unavailable")
                }
            }
            if column.average?.contains(" / ") == true { Text("The average is an exact fraction with a nonterminating decimal expansion.").font(.caption).appSecondaryText() }
            if let notice = column.numericNotice { Text(notice).font(.caption).appSecondaryText().textSelection(.enabled) }
            Text("Frequent captured representations").font(.headline)
            Text("Values group by captured bytes and native storage kind. Percentages use the \(column.count) observed rows.")
                .font(.caption).appSecondaryText()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(column.frequencies) { value in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(value.displayKind).font(.caption).appSecondaryText().frame(width: 80, alignment: .leading)
                                Text(value.preview + (value.isPreviewLimited ? " …" : "")).lineLimit(2).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text("\(value.count) · \(percentage(value.count))%").monospacedDigit()
                            }.font(.callout)
                            ProgressView(value: Double(value.count), total: Double(max(1, column.count)))
                                .accessibilityLabel("\(value.count) of \(column.count) observed rows")
                        }
                        .contextMenu {
                            Button("Copy Displayed Value") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(value.label, forType: .string)
                            }
                        }
                    }
                    if column.otherCount > 0 { Text("Other observed values · \(column.otherCount)").font(.caption).appSecondaryText() }
                }
            }.frame(minHeight: 150, maxHeight: .infinity)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).appSecondaryText()
            Text(value).font(.callout).monospacedDigit().textSelection(.enabled).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func percentage(_ count: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(count) * 100 / Double(max(1, column.count)))
    }
}

private struct GridProfileServerView: View {
    @ObservedObject var model: GridProfileServerModel
    var investigations: InvestigationLibraryModel?
    var mayAttach: @MainActor () -> Bool
    @Environment(\.dismiss) private var dismiss
    private var showReport = SwiftUI.State<Bool>(initialValue: false)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("First-N Server Sample").font(.title2); Spacer(); Button("Done") { Task { await model.close(); dismiss() } }.controlHover().keyboardShortcut(.cancelAction) }
            Text("\(model.table.schema).\(model.table.name) · \(model.column.name)").font(.headline).textSelection(.enabled)
            Text("A new readonly connection reads committed table rows independently from SQL-tab transactions. Capture is capped at 8 MiB of selected values in pages of at most 200 rows. Rows use the adapter's default browser ordering without this tab's filters, relationship restrictions or custom sorting, and may change between pages.")
                .font(.caption).appSecondaryText()
            HStack {
                Picker("First rows", selection: $model.rowLimit) {
                    ForEach([200, 1_000, 5_000, 10_000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                Picker("Deadline", selection: $model.timeoutSeconds) {
                    ForEach([15, 30, 60, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }.disabled(model.isBusy)
            HStack {
                Button("Capture Sample") { Task { await model.capture() } }.controlHover().disabled(!model.canStartAction)
                Button("Stop") { Task { await model.stop() } }.controlHover().disabled(!model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.rowsCaptured) rows captured").font(.caption).monospacedDigit().appSecondaryText()
            }
            if let report = model.report {
                Text(report.scope.notice).font(.caption).appSecondaryText().textSelection(.enabled)
                Button("View Captured Profile…") { showReport.wrappedValue = true }.controlHover()
                if let column = report.columns.first { GridProfileColumnView(column: column) }
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Spacer(minLength: 0)
        }.padding(16).frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 620)
            .interactiveDismissDisabled(model.isBusy)
            .onDisappear { Task { await model.close() } }
            .sheet(isPresented: showReport.projectedValue) { if let report = model.report { GridProfileView(report: report, investigations: investigations, mayAttach: mayAttach) } }
    }
}

private struct GridProfileAttachmentView: View {
    @ObservedObject var library: InvestigationLibraryModel
    @StateObject private var attachment: GridProfileAttachment
    @Environment(\.dismiss) private var dismiss
    private var target = SwiftUI.State<UUID?>(initialValue: nil)
    init(report: GridProfileReport, library: InvestigationLibraryModel, mayAttach: @escaping @MainActor () -> Bool) {
        self.library = library
        self._attachment = StateObject(wrappedValue: GridProfileAttachment(report: report, library: library, mayAttach: mayAttach))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Data Profile").font(.title2)
            Picker("Investigation", selection: target.projectedValue) {
                Text("New Investigation").tag(UUID?.none)
                ForEach(library.documents) { Text($0.title).tag(Optional($0.id)) }
            }.disabled(attachment.isSaving || attachment.pendingDocumentID != nil)
            Text("The captured scope, exact aggregates and value-frequency previews are saved as a Markdown block.")
                .font(.caption).appSecondaryText()
            if let error = attachment.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.controlHover().keyboardShortcut(.cancelAction).disabled(attachment.isSaving)
                Button(attachment.pendingDocumentID == nil ? "Attach" : "Retry Save") {
                    Task { if await attachment.save(to: target.wrappedValue) { dismiss() } }
                }.controlHover().disabled(attachment.isSaving || !library.isLoaded)
            }
        }.padding(16).frame(width: 480)
            .task { await library.restore() }
            .interactiveDismissDisabled(attachment.isSaving)
    }
}
