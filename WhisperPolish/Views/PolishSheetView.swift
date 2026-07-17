import SwiftUI

struct PolishSheetView: View {
    let hasAPIKey: Bool
    let onPolish: (PolishStyle) -> Void

    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    @State private var style: PolishStyle = .email
    @State private var showingNewStyle = false

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

                sectionLabel("Style")
                FlowChips(styles: PolishStyle.all(customJSON: customStylesJSON),
                          selection: $style,
                          onNewStyle: { showingNewStyle = true })

                if hasAPIKey {
                    Button {
                        onPolish(style)
                    } label: {
                        Text("Polish as \(style.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Color.polishTeal))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } else {
                    Text("Add your OpenRouter API key in Settings first.")
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
        }
        .sheet(isPresented: $showingNewStyle) {
            // Seed with the selected style's instruction so "duplicate and
            // tweak" is the natural way to make a new style.
            StyleEditorView(seedInstruction: style.instruction) { saved in
                style = saved
            }
        }
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
    @Binding var selection: PolishStyle
    var onNewStyle: () -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(styles) { style in
                Button {
                    selection = style
                } label: {
                    Text(style.name)
                        .font(.footnote.weight(selection == style ? .semibold : .regular))
                        .foregroundStyle(selection == style ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selection == style ? Color.polishTeal : Color(.systemGroupedBackground)))
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
