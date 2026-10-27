import SwiftUI

struct WorkspaceNotificationToast: View {
    @ObservedObject var notifications: WorkspaceNotifications
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !notifications.activeToasts.isEmpty {
                ViewThatFits(in: .vertical) {
                    toastStack.fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        toastStack
                    }
                    .defaultScrollAnchor(.bottom)
                }
                .frame(width: 380)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: notifications.activeToasts.map(\.id))
    }

    private var toastStack: some View {
        VStack(spacing: 8) {
            ForEach(notifications.activeToasts.reversed()) { entry in
                WorkspaceNotificationToastCard(notifications: notifications, entry: entry)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

private struct WorkspaceNotificationToastCard: View {
    @ObservedObject var notifications: WorkspaceNotifications
    let entry: WorkspaceNotification
    @Environment(\.applicationPaletteRevision) private var paletteRevision
    private var hoverSource = SwiftUI.State(initialValue: UUID())

    init(notifications: WorkspaceNotifications, entry: WorkspaceNotification) {
        self.notifications = notifications
        self.entry = entry
    }

    var body: some View {
        let _ = paletteRevision
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.connection?.name ?? entry.source)
                    .font(.caption.weight(.semibold)).appSecondaryText()
                    .lineLimit(1).truncationMode(.middle)
                Text(entry.message)
                    .font(.callout).foregroundStyle(AppPalette.text)
                    .lineLimit(5).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ControlIconButton(systemName: "xmark") { notifications.dismissToast(entry.id) }
                .help("Dismiss notification banner")
                .accessibilityLabel("Dismiss notification banner")
                .accessibilityIdentifier("dismissWorkspaceNotificationToast")
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            remainingTimeStrip.padding(.horizontal, 12).padding(.bottom, 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppPalette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspaceNotificationToast")
        .onHover { hovering in
            if hovering {
                notifications.pauseToast(entry.id, source: hoverSource.wrappedValue)
            } else {
                notifications.resumeToast(entry.id, source: hoverSource.wrappedValue)
            }
        }
        .onDisappear { notifications.resumeToast(entry.id, source: hoverSource.wrappedValue) }
    }

    private var remainingTimeStrip: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: notifications.isToastPaused(entry.id))) { _ in
            let fraction = notifications.toastRemainingFraction(entry.id)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppPalette.accent.opacity(0.15))
                    Capsule().fill(AppPalette.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
