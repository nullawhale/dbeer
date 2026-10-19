import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    // Use property-wrapper storage on the CLT-only Swift toolchain.
    private var editingConnectionState = SwiftUI.State<SavedConnection?>(initialValue: nil)
    private let amber = AppPalette.accent
    private let graphite = AppPalette.background

    init(model: WorkspaceModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ConnectionsSidebar(model: model, onCreate: newConnection, onEdit: editConnection)
                VStack(spacing: 0) {
                    if let error = model.errorMessage, model.queryFailure == nil {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .accessibilityIdentifier("connectionError")
                        Divider()
                    }
                    VSplitView {
                        sqlEditor
                            .frame(minHeight: 160, idealHeight: 220, maxHeight: 420)
                        results
                            .frame(minHeight: 200, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .background(graphite)
        .tint(amber)
        .focusEffectDisabled()
        .toolbar {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                windowTitle.sharedBackgroundVisibility(.hidden)
            } else {
                windowTitle
            }
            #else
            windowTitle
            #endif
        }
        .sheet(isPresented: $model.isConnectionEditorPresented, onDismiss: {
            editingConnectionState.wrappedValue = nil
        }) {
            ConnectionEditorView(model: model, connection: editingConnectionState.wrappedValue) {
                model.isConnectionEditorPresented = false
                editingConnectionState.wrappedValue = nil
            }
        }
    }

    private var windowTitle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 7) {
                Image(nsImage: toolbarIcon)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("DBeer").fontWeight(.semibold)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
    }

    private var toolbarIcon: NSImage {
        let name = colorScheme == .dark ? "ToolbarIconDark" : "ToolbarIcon"
        return NSImage(named: NSImage.Name(name)) ?? NSApplication.shared.applicationIconImage
    }

    private func newConnection() {
        editingConnectionState.wrappedValue = nil
        model.dismissConnectionsError()
        model.isConnectionEditorPresented = true
    }

    private func editConnection(_ connection: SavedConnection) {
        editingConnectionState.wrappedValue = connection
        model.dismissConnectionsError()
        model.isConnectionEditorPresented = true
    }

    private var sqlEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("SQL").font(.headline)
                Spacer()
                Button {
                    Task { await model.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }.controlHover()
                .connectionButtonFocus()
                .disabled(!model.canStop)
                .accessibilityIdentifier("stopQuery")
                Button {
                    Task { await model.run() }
                } label: {
                    HStack(spacing: 8) {
                        Label("Run", systemImage: "play")
                        Text("⌘↩").opacity(0.65)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }.controlHover()
                .buttonStyle(.borderedProminent)
                .connectionButtonFocus()
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRun)
                .help("Run the entire SQL command (⌘↩)")
                .accessibilityIdentifier("runQuery")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            SQLEditorView(text: $model.sql, isEditable: !model.isExecuting)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityLabel("SQL editor")
                .accessibilityIdentifier("sqlEditor")
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.queryFailure == nil ? "Results" : "Error").font(.headline)
                Text("Read only")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                if model.isExecuting {
                    ProgressView().controlSize(.small)
                    Text(model.queryPhase.label).font(.callout).foregroundStyle(.secondary)
                    elapsedTime
                } else if let result = model.result {
                    Text("\(result.displayedRowCount ?? 0) shown")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(duration(result.durationMs ?? 0))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                } else if let milliseconds = model.queryDurationMs {
                    Text(duration(milliseconds))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()

            if model.isExecuting {
                emptyState(symbol: "hourglass", title: model.queryPhase.label,
                    message: model.cancellationMessage ?? "Waiting for PostgreSQL to finish.")
            } else if let failure = model.queryFailure {
                queryError(failure)
            } else if let result = model.result {
                if result.truncated == true || result.displayNotice != nil {
                    Label(result.displayNotice ?? "Result truncated. Showing \(result.displayedRowCount ?? 0) of \(result.rowCount ?? 0) rows.",
                        systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(amber.opacity(0.07))
                    Divider()
                }
                if let columns = result.columns, !columns.isEmpty {
                    ResultTableView(columns: columns, rows: result.rows ?? [])
                        .accessibilityIdentifier("queryResults")
                } else {
                    emptyState(symbol: "checkmark.circle", title: "Command completed",
                        message: result.commandTag ?? "Done")
                }
            } else {
                if model.sessionId == nil, model.savedConnections.isEmpty {
                    emptyState(symbol: "server.rack", title: "Create a connection",
                        message: "Use + in Connections to add a PostgreSQL connection.")
                } else {
                    emptyState(symbol: "tablecells", title: model.sessionId == nil ? "Connect to PostgreSQL" : "Ready for a query",
                        message: model.sessionId == nil ? "Choose a saved connection and click Connect." : "Run the SQL above to see its result.")
                }
            }
        }
    }

    private func queryError(_ failure: WorkspaceModel.QueryFailure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(failure.title, systemImage: failure.category == "cancelled" ? "stop.circle" : "exclamationmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(failure.category == "cancelled" ? Color.secondary : Color.red)
                Text(failure.message).textSelection(.enabled)
                if let sqlState = failure.sqlState {
                    Text("SQLSTATE \(sqlState)")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if failure.outcomeUnknown {
                    Label("The SQL outcome is unknown. Check the database before running this command again.", systemImage: "questionmark.circle")
                        .foregroundStyle(amber)
                }
                if model.transactionStatus == .failedTransaction {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Failed transaction", systemImage: "exclamationmark.circle").foregroundStyle(amber)
                        Text("Run ROLLBACK to restore the session.").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        emptyStateContent(symbol: symbol, title: title, message: message)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateContent(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(amber.opacity(0.8))
            Text(title).font(.title3.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(model.connectionSummary).lineLimit(1)
            Spacer(minLength: 10)
            if let result = model.result {
                Text(result.commandTag ?? "").fontDesign(.monospaced)
                Text("·")
                Text("\(result.rowCount ?? 0) rows")
            }
            if model.sessionId != nil {
                Text("·")
                Text(model.transactionLabel)
                    .foregroundStyle(model.transactionStatus == .failedTransaction ? amber : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.02))
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(duration(model.elapsedMilliseconds(at: context.date)))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func duration(_ milliseconds: Double) -> String {
        milliseconds < 1_000 ? "\(milliseconds.formatted(.number.precision(.fractionLength(0)))) ms" :
            "\((milliseconds / 1_000).formatted(.number.precision(.fractionLength(1)))) s"
    }

}
