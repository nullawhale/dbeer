import SwiftUI

/// Tool windows share a compact edge strip and open beside the working panes.
struct WorkspaceSidebarRail: View {
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject private var commands: AppCommandRegistry

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        commands = workspace.commands
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(WorkspaceSidebarPanel.allCases) { panel in
                    panelButton(panel)
                }
            }.padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(width: 34)
        .background(AppPalette.isCustom ? AppPalette.panel : Color.primary.opacity(0.035), ignoresSafeAreaEdges: [])
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar panels")
        .accessibilityIdentifier("workspaceSidebarRail")
    }

    private func panelButton(_ panel: WorkspaceSidebarPanel) -> some View {
        let selected = workspace.sidebarPanel == panel
        return Button { workspace.toggleSidebar(panel) } label: {
            VerticalSidebarLabelLayout {
                HStack(spacing: 6) {
                    Image(systemName: panel.systemImage)
                    Text(panel.title)
                }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 32)
                .rotationEffect(.degrees(-90))
            }
            .frame(width: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? AppPalette.accent.opacity(0.12) : Color.clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(AppPalette.accent).frame(width: 2).allowsHitTesting(false) }
        }
        .controlHover()
        .disabled(!workspace.canManageWorkspace)
        .help(commands.help(for: panel.command))
        .accessibilityLabel(panel.title)
        .accessibilityValue(selected ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("toggleSidebar-\(panel.rawValue)")
    }
}

/// Rotation changes drawing only; swap the measured axes for layout and hit testing.
private struct VerticalSidebarLabelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first else { return .zero }
        let size = label.sizeThatFits(.unspecified)
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

struct WorkspaceSidebarCloseButton: View {
    @ObservedObject var workspace: ApplicationWorkspace
    let panel: WorkspaceSidebarPanel

    var body: some View {
        ControlIconButton(systemName: "sidebar.left") { workspace.toggleSidebar(panel) }
            .disabled(!workspace.canManageWorkspace)
            .help("Hide \(panel.title)")
            .accessibilityLabel("Hide \(panel.title)")
            .accessibilityIdentifier("hideSidebar-\(panel.rawValue)")
    }
}
