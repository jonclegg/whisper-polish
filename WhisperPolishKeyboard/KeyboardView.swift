import SwiftUI
import UIKit

extension Color {
    static let keyFill = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
    static let modifierKeyFill = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1)
            : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
    })
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
            } else {
                KeysView(model: model)
            }
        }
        .frame(height: Self.toolbarHeight + Self.rowHeight * 4, alignment: .top)
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
        .buttonStyle(.plain)
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

private struct KeysView: View {
    let model: KeyboardModel

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / KeySpec.rowUnits
            VStack(spacing: 0) {
                ForEach(Array(model.layout.rows(showsNextKeyboard: model.needsInputModeSwitchKey).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, spec in
                            KeyView(spec: spec, unit: unit, model: model)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct KeyView: View {
    let spec: KeySpec
    let unit: CGFloat
    let model: KeyboardModel

    @GestureState private var isPressed = false

    var body: some View {
        if spec.key == .nextKeyboard {
            NextKeyboardButton(controller: model.controller)
                .padding(.horizontal, 3)
                .padding(.vertical, 6)
                .frame(width: unit * spec.units, height: KeyboardView.rowHeight)
        } else {
            cap
                .padding(.horizontal, 3)
                .padding(.vertical, 6)
                .frame(width: unit * spec.units, height: KeyboardView.rowHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isPressed) { _, pressed, _ in pressed = true }
                        .onEnded { _ in model.keyUp(spec.key) }
                )
                .onChange(of: isPressed) { _, pressed in
                    if pressed {
                        model.keyDown(spec.key)
                    } else {
                        model.keyReleased()
                    }
                }
        }
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fill)
            .shadow(color: .black.opacity(0.3), radius: 0, y: 1)
            .overlay { label.foregroundStyle(.primary) }
            .overlay(alignment: .bottom) {
                if isPressed, case .character = spec.key {
                    popup
                }
            }
    }

    private var fill: Color {
        switch spec.key {
        case .character, .space:
            return isPressed ? .modifierKeyFill : .keyFill
        case .shift where model.shift != .off:
            return .keyFill
        default:
            return isPressed ? .keyFill : .modifierKeyFill
        }
    }

    @ViewBuilder
    private var label: some View {
        switch spec.key {
        case .character:
            Text(displayedCharacter)
                .font(.system(size: 23))
        case .shift:
            Image(systemName: shiftSymbol)
                .font(.system(size: 18, weight: .medium))
        case .delete:
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
        case .space:
            Text("space").font(.system(size: 16))
        case .returnKey:
            Text("return").font(.system(size: 16))
        case .layout(let layout):
            Text(layout.switchLabel).font(.system(size: 16))
        case .nextKeyboard:
            EmptyView()
        }
    }

    private var popup: some View {
        Text(displayedCharacter)
            .font(.system(size: 32))
            .foregroundStyle(.primary)
            .frame(width: unit + 10, height: 50)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.keyFill).shadow(color: .black.opacity(0.25), radius: 3, y: 1))
            .offset(y: -46)
            .allowsHitTesting(false)
    }

    private var displayedCharacter: String {
        guard case .character(let character) = spec.key else { return "" }
        return model.shift == .off ? character : character.uppercased()
    }

    private var shiftSymbol: String {
        switch model.shift {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .locked: return "capslock.fill"
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
        .buttonStyle(.plain)
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

/// The globe key must be a UIKit control so it can show the system
/// keyboard-switcher menu on long press.
private struct NextKeyboardButton: UIViewRepresentable {
    let controller: UIInputViewController

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor(Color.modifierKeyFill)
        button.layer.cornerRadius = 8
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
