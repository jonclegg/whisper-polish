import SwiftUI

struct PolishSheetView: View {
    let hasAPIKey: Bool
    let onPolish: (PolishStyle, Bool) -> Void

    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.stealthByDefault) private var stealthByDefault = false
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    @State private var style: PolishStyle = .email
    @State private var mode: PolishRewriteMode = .quick
    @State private var voiceSample = ""
    @State private var showingNewStyle = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Polish this note", systemImage: "sparkle")
                        .font(.headline)
                    Text("Choose the shape, then choose how hard to rewrite it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 18)

                sectionLabel("Style")
                FlowChips(styles: PolishStyle.all(customJSON: customStylesJSON),
                          selection: $style,
                          onNewStyle: { showingNewStyle = true })

                sectionLabel("Rewrite mode")
                VStack(spacing: 10) {
                    ForEach(PolishRewriteMode.allCases) { mode in
                        PolishModeCard(
                            mode: mode,
                            isSelected: self.mode == mode,
                            onSelect: { self.mode = mode }
                        )
                    }
                }

                modePreview

                if hasAPIKey {
                    VStack(spacing: 7) {
                        Button {
                            guard mode.isRunnable else { return }
                            onPolish(style, mode.usesTranslationHop)
                        } label: {
                            Text(mode.isRunnable ? "Polish as \(style.name)" : "Mockup only")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Capsule().fill(mode.isRunnable ? Color.polishTeal : Color(.systemGray3)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!mode.isRunnable)

                        if !mode.isRunnable {
                            Text("This mode is staged for the next implementation pass.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
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
            mode = stealthByDefault ? .translationHop : .quick
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

    @ViewBuilder
    private var modePreview: some View {
        switch mode {
        case .quick:
            EmptyView()
        case .voiceMatch:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "signature")
                        .foregroundStyle(Color.polishTeal)
                    Text("Writing sample")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("\(voiceSample.count)/1200")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $voiceSample)
                    .font(.footnote)
                    .frame(minHeight: 84, maxHeight: 112)
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
                    )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGroupedBackground)))
        case .naturalAudit:
            ModePreviewRows(rows: [
                ("text.magnifyingglass", "AI-ism cleanup"),
                ("quote.bubble", "Plain wording pass"),
                ("lock.doc", "Protected names and links"),
            ])
        case .altTranslation:
            HStack(spacing: 8) {
                RoutePill("EN")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RoutePill("ZH")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RoutePill("TR")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RoutePill("EN")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGroupedBackground)))
        case .translationHop:
            ModePreviewRows(rows: [
                ("1.circle", "Chinese rewrite"),
                ("2.circle", "Japanese rewrite"),
                ("3.circle", "Finnish hop"),
                ("4.circle", "English finish"),
            ])
        }
    }
}

private enum PolishRewriteMode: String, CaseIterable, Identifiable {
    case quick
    case voiceMatch
    case naturalAudit
    case altTranslation
    case translationHop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: return "Normal"
        case .voiceMatch: return "Voice Match"
        case .naturalAudit: return "Natural Audit"
        case .altTranslation: return "Alt Translation"
        case .translationHop: return "Translation Hop"
        }
    }

    var subtitle: String {
        switch self {
        case .quick:
            return "Single model rewrite. Fastest."
        case .voiceMatch:
            return "Uses a writing sample to mirror cadence."
        case .naturalAudit:
            return "Second pass for stiff phrasing."
        case .altTranslation:
            return "Different cross-language route."
        case .translationHop:
            return "Current four-step chain."
        }
    }

    var icon: String {
        switch self {
        case .quick: return "bolt.fill"
        case .voiceMatch: return "person.text.rectangle"
        case .naturalAudit: return "checklist.checked"
        case .altTranslation: return "arrow.triangle.2.circlepath"
        case .translationHop: return "globe"
        }
    }

    var badge: String? {
        switch self {
        case .quick: return nil
        case .voiceMatch, .naturalAudit, .altTranslation: return "Preview"
        case .translationHop: return "Live"
        }
    }

    var isRunnable: Bool {
        switch self {
        case .quick, .translationHop:
            return true
        case .voiceMatch, .naturalAudit, .altTranslation:
            return false
        }
    }

    var usesTranslationHop: Bool { self == .translationHop }
}

private struct PolishModeCard: View {
    let mode: PolishRewriteMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Color.polishTeal)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.polishTeal : Color.polishTealSoft))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let badge = mode.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(mode.isRunnable ? Color.polishTeal : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(mode.isRunnable ? Color.polishTealSoft : Color(.systemFill)))
                        }
                    }
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.polishTeal : Color(.systemFill))
                    .font(.title3)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.polishTeal.opacity(0.85) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ModePreviewRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Label {
                    Text(row.1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.polishTeal)
                        .frame(width: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGroupedBackground)))
    }
}

private struct RoutePill: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.polishTeal)
            .frame(minWidth: 38)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.polishTealSoft))
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
