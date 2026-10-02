import SwiftUI
import UIKit

extension Color {
    static let keyFill = Color(uiColor: .keyFill)
    static let modifierKeyFill = Color(uiColor: .modifierKeyFill)
}

struct KeyboardView: View {
    static let toolbarHeight: CGFloat = 40
    static let keysHeight: CGFloat = 54 * 4

    let model: KeyboardModel

    /// The keys are a UIKit sibling laid over the bottom; this view supplies the bar and the style picker.
    var body: some View {
        VStack(spacing: 0) {
            SuggestionBar(model: model)
                .frame(height: Self.toolbarHeight)
            if model.isPickingStyle {
                StylePickerView(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: Self.toolbarHeight + Self.keysHeight, alignment: .top)
        .animation(.snappy(duration: 0.25), value: model.isPickingStyle)
        .animation(.snappy(duration: 0.25), value: model.notice)
    }
}

/// The system keyboard's predictive bar, flanked by Polish (tap; hold for styles) and Record.
private struct SuggestionBar: View {
    let model: KeyboardModel

    @State private var isPolishPressed = false

    var body: some View {
        HStack(spacing: 4) {
            polishButton
            Group {
                if let notice = model.notice {
                    noticeContent(notice)
                } else {
                    suggestionSlots
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            circleButton(systemImage: "mic.fill", color: .red, action: model.record)
                .accessibilityLabel("Record in Whisper Polish")
        }
        .padding(.horizontal, 6)
    }

    private var polishButton: some View {
        Image(systemName: model.isPickingStyle ? "chevron.down" : "sparkle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.polishTeal))
            .scaleEffect(isPolishPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: isPolishPressed)
            .contentShape(Circle())
            .onTapGesture {
                if model.isPickingStyle { model.togglePicker() } else { model.polish() }
            }
            .onLongPressGesture(minimumDuration: 0.4, perform: model.togglePicker) { isPolishPressed = $0 }
            .accessibilityLabel("Polish as \(model.selectedStyle.name)")
            .accessibilityHint("Hold to choose a style")
    }

    private var suggestionSlots: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 0.5, height: 22)
                }
                slot(index < model.suggestions.count ? model.suggestions[index] : nil)
            }
        }
    }

    private func slot(_ suggestion: Suggestion?) -> some View {
        Button {
            if let suggestion { model.apply(suggestion) }
        } label: {
            Text(suggestion?.title ?? "")
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(suggestion?.isAutocorrection == true ? Color.keyFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionButtonStyle())
        .disabled(suggestion == nil)
    }

    @ViewBuilder
    private func noticeContent(_ notice: KeyboardModel.Notice) -> some View {
        switch notice {
        case .polishing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Polishing as \(model.selectedStyle.name)…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.polishTeal)
                    .lineLimit(1)
            }
        case .polished:
            HStack {
                noticeLabel("Polished as \(model.selectedStyle.name)", systemImage: "checkmark")
                Button(action: model.undoPolish) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.keyFill))
                }
                .buttonStyle(PressableButtonStyle())
            }
        case .dictated:
            noticeLabel("Dictation inserted", systemImage: "mic.fill")
        case .message(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
    }

    private func noticeLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.polishTeal)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private func circleButton(systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(color))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.keyFill.opacity(configuration.isPressed ? 0.7 : 0))
            )
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct StylePickerView: View {
    let model: KeyboardModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Polish style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 4)
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(model.styles) { style in
                        let isSelected = style == model.selectedStyle
                        chip(style.name, isSelected: isSelected) { model.selectStyle(style) }
                    }
                    Button(action: model.createStyle) {
                        Label("New style", systemImage: "plus")
                            .font(.footnote)
                            .foregroundStyle(Color.polishTeal)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.polishTeal.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .hidingScrollEdgeEffect()
    }

    private func chip(_ name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.polishTeal : Color.keyFill))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private extension View {
    /// iOS 26 blurs content under scroll edges, which smears a short keyboard panel.
    @ViewBuilder
    func hidingScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}
