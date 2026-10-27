import SwiftUI

struct WorkspaceStatusBar: View {
    @ObservedObject var workspace: ApplicationWorkspace
    let editConnection: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.selectedDocument?.runtime?.transactionLabel ?? "No session")
                .appSecondaryText().lineLimit(1)
            Spacer(minLength: 8)
            if let document = workspace.selectedDocument {
                Text(document.isSnapshot ? "Offline result snapshot" : document.runtime?.connectionSummary ?? (document.table == nil
                    ? "Session opens on first Run" : "Session opens on Load Data"))
                    .appSecondaryText().lineLimit(1).truncationMode(.middle)
            }
            Divider().frame(height: 14)
            WorkspaceNotificationsButton(notifications: workspace.notifications, appearance: workspace.appearance,
                connections: workspace.library.savedConnections, editConnection: editConnection)
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 30)
    }
}

private struct WorkspaceNotificationsButton: View {
    @ObservedObject var notifications: WorkspaceNotifications
    @ObservedObject var appearance: AppAppearance
    let connections: [SavedConnection]
    let editConnection: (UUID) -> Void
    private var isPresented = SwiftUI.State(initialValue: false)

    var body: some View {
        Button { isPresented.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell.badge").hidden()
                    .overlay {
                        Image(systemName: notifications.unreadCount > 0 ? "bell.badge" : "bell")
                    }
                    .accessibilityHidden(true)
                Text("\(WorkspaceNotifications.maximumCount)").hidden()
                    .overlay(alignment: .trailing) { Text("\(notifications.entries.count)") }
                    .monospacedDigit()
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(notifications.unreadCount > 0 ? Color.orange : AppPalette.secondaryText)
            .padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).controlHover()
        .help("Notifications · \(notifications.unreadCount) unread")
        .accessibilityLabel("Notifications")
        .accessibilityValue("\(notifications.entries.count) total, \(notifications.unreadCount) unread")
        .accessibilityIdentifier("workspaceNotifications")
        .popover(isPresented: isPresented.projectedValue, arrowEdge: .bottom) {
            WorkspaceNotificationsList(notifications: notifications, connections: connections) { id in
                isPresented.wrappedValue = false
                editConnection(id)
            }
                .applicationTheme(appearance: appearance)
        }
    }
}

private struct WorkspaceNotificationsList: View {
    @ObservedObject var notifications: WorkspaceNotifications
    @Environment(\.dismiss) private var dismiss
    let connections: [SavedConnection]
    let editConnection: (UUID) -> Void
    private var clearRequestID = SwiftUI.State<UUID?>(initialValue: nil)
    private var renderedHeight = SwiftUI.State<CGFloat>(initialValue: 0)
    private var clearHeight = SwiftUI.State<CGFloat?>(initialValue: nil)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                Button("Clear All") {
                    clearHeight.wrappedValue = renderedHeight.wrappedValue > 0 ? renderedHeight.wrappedValue : nil
                    notifications.clear()
                    clearRequestID.wrappedValue = UUID()
                }.controlHover()
                    .disabled(notifications.entries.isEmpty)
                    .accessibilityIdentifier("clearWorkspaceNotifications")
            }.padding(12)
            Divider()
            if notifications.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell").font(.title2).accessibilityHidden(true)
                    Text("No notifications")
                }
                .appSecondaryText().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notifications.entries) { entry in
                            notificationRow(entry)
                            if entry.id != notifications.entries.last?.id { Divider() }
                        }
                    }
                }.frame(maxHeight: 360)
            }
        }
        .frame(width: 380, height: clearHeight.wrappedValue, alignment: .top)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { renderedHeight.wrappedValue = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in renderedHeight.wrappedValue = height }
            }
            .allowsHitTesting(false)
        }
        .background(AppPalette.background)
        .accessibilityIdentifier("workspaceNotificationsList")
        .onAppear { notifications.markAllRead() }
        .onChange(of: notifications.entries.first?.id) { _, _ in notifications.markAllRead() }
        .task(id: clearRequestID.wrappedValue) {
            guard let requestID = clearRequestID.wrappedValue else { return }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard !Task.isCancelled, clearRequestID.wrappedValue == requestID else { return }
            dismiss()
        }
        .onDisappear {
            clearRequestID.wrappedValue = nil
            clearHeight.wrappedValue = nil
            renderedHeight.wrappedValue = 0
        }
    }

    private func notificationRow(_ entry: WorkspaceNotification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let connection = entry.connection {
                        let current = connections.first { $0.id == connection.id }
                        Button(connection.name) { editConnection(connection.id) }
                            .buttonStyle(.plain).controlHover()
                            .foregroundStyle(current == nil ? AppPalette.secondaryText : AppPalette.accent)
                            .lineLimit(1).truncationMode(.middle)
                            .disabled(current == nil)
                            .help(current.map { "Edit connection \($0.name)" } ?? "This connection is no longer available")
                            .accessibilityLabel("Edit connection \(connection.name)")
                            .accessibilityIdentifier("notificationConnection-\(entry.id.uuidString)")
                    } else {
                        Text(entry.source)
                    }
                    Spacer()
                    Text(entry.createdAt, style: .time)
                }.font(.caption).appSecondaryText()
                Text(entry.message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ControlIconButton(systemName: "xmark") { notifications.dismiss(entry.id) }
                .help("Dismiss notification").accessibilityLabel("Dismiss notification")
        }
        .padding(12)
    }
}
