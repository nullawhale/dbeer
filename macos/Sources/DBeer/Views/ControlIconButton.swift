import SwiftUI

/// Keep icon-only actions independent of the surrounding text and toolbar size.
struct ControlIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlHover()
    }
}
