import SwiftUI

/// A segmented choice keeps every button's hover and cursor region separate.
struct ControlSegmentPicker<Value: Hashable>: View {
    struct Choice: Identifiable {
        let title: String
        let value: Value

        var id: Value { value }

        init(_ title: String, value: Value) {
            self.title = title
            self.value = value
        }
    }

    private let title: String
    @Binding private var selection: Value
    private let choices: [Choice]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.applicationPaletteRevision) private var paletteRevision
    @FocusState private var focusedChoice: Value?

    init(_ title: String, selection: Binding<Value>, choices: [Choice]) {
        self.title = title
        self._selection = selection
        self.choices = choices
    }

    var body: some View {
        let _ = paletteRevision
        LabeledContent(title) {
            HStack(spacing: ControlHoverAppearance.gap) {
                ForEach(choices) { choice in
                    Button {
                        selection = choice.value
                        focusedChoice = choice.value
                    } label: {
                        Text(choice.title)
                            .foregroundStyle(AppPalette.isCustom
                                ? AnyShapeStyle((selection == choice.value ? AppPalette.selectionText : AppPalette.text)
                                    .opacity(isEnabled ? 1 : 0.45))
                                : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: ControlHoverAppearance.cornerRadius)
                            .fill(selection == choice.value
                                ? (AppPalette.isCustom ? AppPalette.selection : AppPalette.accent.opacity(0.12)) : Color.clear)
                            .padding(ControlHoverAppearance.inset)
                    }
                    .controlHover()
                    .environment(\.controlKeyboardFocus, focusedChoice == choice.value)
                    .focusEffectDisabled()
                    .focused($focusedChoice, equals: choice.value)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(selection == choice.value ? .isSelected : [])
                }
            }
            .padding(ControlHoverAppearance.inset)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: ControlHoverAppearance.cornerRadius))
            .onMoveCommand(perform: moveSelection)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard isEnabled, let focusedChoice,
              let index = choices.firstIndex(where: { $0.value == focusedChoice }) else { return }
        let nextIndex: Int
        switch direction {
        case .left, .up: nextIndex = max(0, index - 1)
        case .right, .down: nextIndex = min(choices.count - 1, index + 1)
        default: return
        }
        let next = choices[nextIndex].value
        selection = next
        self.focusedChoice = next
    }
}
