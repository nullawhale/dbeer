import SwiftUI

extension View {
    func connectionButtonFocus() -> some View {
        modifier(ConnectionButtonFocus())
    }
}

private struct ConnectionButtonFocus: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .focusEffectDisabled()
            .environment(\.controlKeyboardFocus, isFocused)
    }
}
