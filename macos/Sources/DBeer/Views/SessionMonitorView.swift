import AppKit
import SwiftUI

struct SessionMonitorView: View {
    @ObservedObject var model: SessionMonitorModel
    let close: () -> Void
    var saveEvidence: (() -> Void)? = nil
    var evidenceModel: SavedEvidenceModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isOffline ? "Saved Session Diagnostic" : "Session Monitor").font(.title2.weight(.semibold))
                    Text("\(model.profile.name) · Read-only observation").font(.caption).appSecondaryText()
                }
                Spacer()
                if !model.isOffline {
                    if let saveEvidence {
                        Button("Save Evidence", action: saveEvidence).disabled(model.snapshot == nil || model.isClosing || evidenceModel?.isBusy == true)
                            .controlHover().help("Save this observation, including visible SQL, sessions, waits and completeness notices, as an immutable local artifact.")
                    }
                    Toggle("Every 5 seconds", isOn: $model.autoRefresh).toggleStyle(.checkbox)
                        .disabled(model.isClosing).controlHover().accessibilityIdentifier("sessionMonitorAutoRefresh")
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.isBusy || model.isClosing).controlHover().accessibilityIdentifier("sessionMonitorRefresh")
                    Button("Stop") { Task { await model.stop() } }
                        .disabled(!model.isBusy && !model.autoRefresh || model.isClosing).controlHover()
                }
                if !model.isOffline { Button("Close", action: close).keyboardShortcut(.cancelAction).controlHover() }
            }.padding(18)
            if let evidenceModel { SavedEvidenceStatusView(model: evidenceModel).padding(.horizontal, 18).padding(.bottom, 6) }
            Divider()
            HStack {
                TextField("Filter sessions", text: $model.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityIdentifier("sessionMonitorFilter")
                Toggle("Waiting only", isOn: $model.waitingOnly).toggleStyle(.checkbox).controlHover()
                Picker("Sort by", selection: $model.sort) {
                    ForEach(SessionMonitorSort.allCases) { sort in Text(sort.title).tag(sort) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 170).controlHover()
                    .accessibilityLabel("Sort sessions by").accessibilityIdentifier("sessionMonitorSort")
                    .help("Unavailable durations are listed last.")
                Button {
                    model.sortDescending.toggle()
                } label: {
                    Image(systemName: model.sortDescending ? "arrow.down" : "arrow.up")
                }.help(model.sortDescending ? "Descending" : "Ascending").controlHover()
                    .accessibilityLabel(model.sortDescending ? "Sort ascending" : "Sort descending")
                    .accessibilityIdentifier("sessionMonitorSortDirection")
                Spacer()
                Text("\(model.visibleSessions.count) sessions · \(model.visibleWaitingCount) waiting · \(model.visibleBlockingCount) blocking")
                    .font(.caption).appSecondaryText()
            }.padding(.horizontal, 18).padding(.vertical, 10)
            notices
            VSplitView {
                sessions.frame(minHeight: 180, idealHeight: 260)
                HSplitView {
                    queryDetails.frame(minWidth: 350, idealWidth: 550)
                    waits.frame(minWidth: 330, idealWidth: 420)
                }.frame(minHeight: 180, idealHeight: 250)
            }
            Divider()
            HStack {
                if let snapshot = model.snapshot {
                    Text("Collected \(snapshot.collectedAt)\(model.isStale ? " · Stale" : "")")
                } else {
                    Text(model.isBusy ? "Connecting and collecting…" : "No observation collected")
                }
                Spacer()
                Text("Point-in-time observation; sessions and waits can change during collection.")
            }.font(.caption).appSecondaryText().padding(12)
        }
        .frame(minWidth: 1_000, idealWidth: 1_200, minHeight: 650, idealHeight: 760)
        .background(AppPalette.panel).tint(AppPalette.accent).focusEffectDisabled()
        .accessibilityElement(children: .contain).accessibilityIdentifier("sessionMonitor")
    }

    private var notices: some View {
        Group {
            if model.notice != nil || model.snapshot?.notices.isEmpty == false || model.snapshot?.sessionsComplete == false || model.snapshot?.waitsComplete == false {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if let notice = model.notice {
                            Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if let snapshot = model.snapshot {
                            if !snapshot.sessionsComplete || !snapshot.waitsComplete {
                                Label("Partial observation. Missing sessions or waits do not imply that no blocking exists.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in Text(notice).appSecondaryText() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
                }
                .font(.caption).textSelection(.enabled).frame(maxHeight: 128)
            }
        }
    }

    private var sessions: some View {
        Table(model.visibleSessions, selection: $model.selectedSessionID) {
            TableColumn("ID") { row in Text(row.id + (row.isMonitor ? " · Monitor" : "")) }.width(min: 75, ideal: 95)
            TableColumn("User") { row in Text(row.user ?? "—") }
            TableColumn("Database") { row in Text(row.database ?? "—") }
            TableColumn("Client") { row in Text(row.client ?? "—") }
            TableColumn("State") { row in Text(row.state ?? "—") }
            TableColumn("Waiting on") { row in Text(model.waitsOnCount(row.id) > 0 ? String(model.waitsOnCount(row.id)) : model.isWaiting(row) ? "Pending" : "—") }.width(min: 70, ideal: 85)
            TableColumn("Blocking") { row in Text(model.blocksCount(row.id) > 0 ? String(model.blocksCount(row.id)) : "—") }.width(min: 65, ideal: 75)
            TableColumn("Query ms") { row in Text(row.queryAgeMs ?? "—").monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Transaction ms") { row in Text(row.transactionAgeMs ?? "—").monospacedDigit() }.width(min: 90, ideal: 110)
            TableColumn("Wait") { row in Text([row.waitType, row.waitEvent].compactMap { $0 }.joined(separator: " · ")) }
        }
    }

    private var queryDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current / Last Query").font(.headline)
            if let session = model.selectedSession {
                Text("Session \(session.id) · \(session.application ?? "Application unavailable")")
                    .font(.caption).appSecondaryText().textSelection(.enabled)
                ScrollView([.horizontal, .vertical]) {
                    Text(session.query ?? "Query text is unavailable for this session.")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if session.queryTruncated { Text("Query text was truncated.").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Select a session to inspect its current or last query and related waits.").appSecondaryText()
                Spacer()
            }
        }.padding(16)
    }

    private var waits: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.selectedSessionID == nil ? "Blocking Relationships" : "Related Blocking").font(.headline)
                Spacer()
                if model.selectedSessionID != nil { Button("Show All") { model.selectedSessionID = nil }.controlHover() }
            }
            Text("\(model.visibleWaits.count) reported relationships").font(.caption).appSecondaryText()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.visibleWaits) { wait in
                        VStack(alignment: .leading, spacing: 3) {
                            endpoint(wait.waitingId)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: "arrow.turn.down.right").accessibilityHidden(true)
                                Text("blocked by")
                                endpoint(wait.blockingId)
                            }
                            Text(([wait.kind, wait.object, wait.lockMode] as [String?]).compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).appSecondaryText()
                        }.textSelection(.enabled)
                    }
                    if model.visibleWaits.isEmpty {
                        Text(model.selectedSession.map { model.isWaiting($0) } == true ?
                            "This session is waiting; a blocking session was not identified. Coverage and visibility notices still apply." :
                            "No waits reported for this selection. Coverage and visibility notices still apply.")
                            .appSecondaryText().textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }

    @ViewBuilder private func endpoint(_ id: String) -> some View {
        if model.containsSession(id) {
            Button(model.sessionLabel(id)) { model.selectSession(id) }
                .buttonStyle(.link).controlHover().help("Show session \(id)")
                .accessibilityLabel("Show " + model.sessionLabel(id))
        } else {
            Text(model.sessionLabel(id)).fontWeight(.medium)
        }
    }
}

/// A modeless window keeps SQL tabs usable while monitoring a busy server.
@MainActor
final class SessionMonitorWindowController: NSWindowController, NSWindowDelegate {
    let model: SessionMonitorModel
    private let requestClose: @MainActor () -> Void

    init(model: SessionMonitorModel, appearance: AppAppearance, evidenceModel: SavedEvidenceModel? = nil, saveEvidence: (@MainActor () -> Void)? = nil, requestClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.requestClose = requestClose
        let content = SessionMonitorView(model: model, close: requestClose, saveEvidence: saveEvidence, evidenceModel: evidenceModel).applicationTheme(appearance: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Session Monitor — \(model.profile.name)"
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { return nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    func finishClosing() { window?.delegate = nil; window?.close() }
}
