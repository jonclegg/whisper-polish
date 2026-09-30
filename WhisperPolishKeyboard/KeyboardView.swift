import SwiftUI
import UIKit

struct KeyboardView: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            styleChips

            HStack(spacing: 10) {
                Button(action: model.polish) {
                    HStack(spacing: 6) {
                        if model.isPolishing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "sparkle")
                        }
                        Text(model.isPolishing ? "Polishing…" : "Polish as \(model.selectedStyle.name)")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.polishTeal))
                }
                .disabled(model.isPolishing || !model.hasFullAccess)

                Button(action: model.record) {
                    VStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                        Text("Record")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 84)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.red))
                }
                .disabled(!model.hasFullAccess)
            }
            .buttonStyle(.plain)
            .frame(height: 72)

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)

            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var styleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.styles) { style in
                    let isSelected = style == model.selectedStyle
                    Button {
                        model.selectedStyle = style
                    } label: {
                        Text(style.name)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(isSelected ? Color.polishTeal : Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.needsInputModeSwitchKey {
                NextKeyboardButton(controller: model.controller)
                    .frame(width: 44)
            }
            key { model.insert(" ") } label: {
                Text("space")
            }
            key(action: model.deleteBackward) {
                Image(systemName: "delete.left")
            }
            .frame(width: 56)
            key { model.insert("\n") } label: {
                Image(systemName: "return")
            }
            .frame(width: 72)
        }
        .frame(height: 44)
    }

    private func key<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
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
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
