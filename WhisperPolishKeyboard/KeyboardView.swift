import SwiftUI
import UIKit

extension Color {
    static let keyFill = Color(uiColor: .keyFill)
    static let modifierKeyFill = Color(uiColor: .modifierKeyFill)
}

struct KeyboardView: View {
    static let toolbarHeight: CGFloat = 46
    static let rowHeight: CGFloat = 54

    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            KeyboardToolbar(model: model)
                .frame(height: Self.toolbarHeight)
            if model.isPickingStyle {
                StylePickerView(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                KeysView(model: model)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.toolbarHeight + Self.rowHeight * 4, alignment: .top)
        .animation(.snappy(duration: 0.25), value: model.isPickingStyle)
        .animation(.snappy(duration: 0.25), value: model.notice)
    }
}

private struct KeyboardToolbar: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 8) {
            if model.hasFullAccess {
                content
                pill(color: .red, action: model.record) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.white)
                        .frame(width: 14)
                }
                .accessibilityLabel("Record in Whisper Polish")
            } else {
                Text("Turn on Allow Full Access in Settings › General › Keyboard › Keyboards › Whisper Polish to polish and dictate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch model.notice {
        case nil:
            polishButton(showsStyle: true)
                .frame(maxWidth: .infinity)
            pill(color: .keyFill, action: { model.isPickingStyle.toggle() }) {
                Label("Style", systemImage: model.isPickingStyle ? "chevron.up" : "chevron.down")
                    .labelStyle(TrailingIconLabelStyle())
            }
        case .polishing:
            pill(color: .polishTeal, action: {}) {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Polishing as \(model.selectedStyle.name)…")
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
        case .polished:
            noticeLabel("Polished as \(model.selectedStyle.name)", systemImage: "checkmark")
            pill(color: .keyFill, action: model.undoPolish) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
        case .dictated:
            noticeLabel("Dictation inserted", systemImage: "mic.fill")
            polishButton(showsStyle: false)
        case .message(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        }
    }

    private func polishButton(showsStyle: Bool) -> some View {
        pill(color: .polishTeal, action: model.polish) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                Text("Polish")
                if showsStyle {
                    Text("· \(model.selectedStyle.name)")
                        .fontWeight(.medium)
                        .opacity(0.85)
                }
            }
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(maxWidth: showsStyle ? .infinity : nil)
        }
    }

    private func noticeLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.polishTeal)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
    }

    private func pill<Content: View>(color: Color, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Capsule().fill(color))
        }
        .buttonStyle(PressableButtonStyle())
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

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
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
