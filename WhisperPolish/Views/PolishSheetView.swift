import SwiftUI

struct PolishSheetView: View {
    let accessMode: CloudAccessMode
    let hasGroqKey: Bool
    let hasOpenRouterKey: Bool
    let hasSubscription: Bool
    let onPolish: (PolishSheetChoice, PolishModel) -> Void

    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""
    @AppStorage(SettingsKeys.polishModel) private var modelRaw = PolishModel.default.rawValue

    @State private var choice: PolishSheetChoice = .style(.email)
    @State private var style: PolishStyle = .email
    @State private var model: PolishModel = .default
    @State private var showingNewStyle = false
    @State private var showingModelPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Polish this note", systemImage: "sparkle")
                        .font(.headline)
                    Text("Pick the shape you want the rewrite to take.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 18)

                Button {
                    choice = .quickCleanup
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "text.badge.checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(choice == .quickCleanup ? Color.polishTeal : .secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(QuickCleanup.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(QuickCleanup.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if choice == .quickCleanup {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.polishTeal)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.systemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(choice == .quickCleanup ? Color.polishTeal : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)

                sectionLabel("Style")
                FlowChips(
                    styles: PolishStyle.all(customJSON: customStylesJSON),
                    selection: selectedStyle,
                    onSelect: { picked in
                        style = picked
                        choice = .style(picked)
                    },
                    onNewStyle: { showingNewStyle = true }
                )

                if choice != .quickCleanup {
                    if accessMode == .personalKey {
                        sectionLabel("Model")
                        Button {
                            showingModelPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .font(.footnote.weight(.semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color(.systemGroupedBackground)))
                        }
                        .buttonStyle(.plain)
                    } else {
                        sectionLabel("Cloud plan")
                        Label("Cost-controlled cloud model", systemImage: "cloud.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.polishTeal)
                    }
                }

                if availability == .ready {
                    Button {
                        onPolish(choice, model)
                    } label: {
                        Text(choice.confirmTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Color.polishTeal))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } else if let message = availability.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color(.systemGroupedBackground)))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .onAppear {
            style = PolishStyle.find(id: defaultStyleRaw, customJSON: customStylesJSON) ?? .email
            choice = .style(style)
            model = PolishModel.resolved(rawValue: modelRaw)
            modelRaw = model.rawValue
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerView(selection: $model)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: model) { _, newValue in
            modelRaw = newValue.rawValue
        }
        .sheet(isPresented: $showingNewStyle) {
            StyleEditorView(seedInstruction: style.instruction) { saved in
                style = saved
                choice = .style(saved)
            }
        }
    }

    private var selectedStyle: PolishStyle? {
        if case .style(let style) = choice { return style }
        return nil
    }

    private var availability: PolishAvailability {
        .of(
            choice: choice,
            accessMode: accessMode,
            hasGroqKey: hasGroqKey,
            hasOpenRouterKey: hasOpenRouterKey,
            hasSubscription: hasSubscription
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

/// Wrapping row of style chips, with a trailing chip to create a new style.
private struct FlowChips: View {
    let styles: [PolishStyle]
    let selection: PolishStyle?
    var onSelect: (PolishStyle) -> Void
    var onNewStyle: () -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(styles) { style in
                let selected = selection == style
                Button {
                    onSelect(style)
                } label: {
                    Text(style.name)
                        .font(.footnote.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selected ? Color.polishTeal : Color(.systemGroupedBackground)))
                }
                .buttonStyle(.plain)
            }
            Button(action: onNewStyle) {
                Label("New style", systemImage: "plus")
                    .font(.footnote)
                    .foregroundStyle(Color.polishTeal)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().strokeBorder(Color.polishTeal.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Minimal left-aligned wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
