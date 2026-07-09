import SwiftUI

struct PolishSheetView: View {
    let hasAPIKey: Bool
    let onPolish: (PolishStyle, PolishRewriteMode, String) -> Void

    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.stealthByDefault) private var stealthByDefault = false
    @AppStorage(SettingsKeys.voiceMatchSample) private var voiceSample = ""
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    @State private var style: PolishStyle = .email
    @State private var mode: PolishRewriteMode = .normal
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

                // A verbatim style formats without rewriting, so the rewrite
                // modes — all strategies for rewriting harder — don't apply.
                if !style.isVerbatim {
                    sectionLabel("Rewrite mode")
                    VStack(spacing: 10) {
                        ForEach(PolishRewriteMode.allCases) { mode in
                            let isEnabled = isModeEnabled(mode)
                            PolishModeCard(
                                mode: mode,
                                isSelected: self.mode == mode,
                                isEnabled: isEnabled,
                                onSelect: {
                                    guard isEnabled else { return }
                                    self.mode = mode
                                }
                            )
                        }
                    }

                    modePreview
                }

                if hasAPIKey {
                    VStack(spacing: 7) {
                        Button {
                            guard canRunSelectedMode else { return }
                            onPolish(style, style.isVerbatim ? .normal : mode, voiceSample)
                        } label: {
                            Text(ctaTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Capsule().fill(canRunSelectedMode ? Color.polishTeal : Color(.systemGray3)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRunSelectedMode)

                        if let hint = modeHint {
                            Text(hint)
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
            mode = stealthByDefault ? .translationHop : .normal
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

    private var canRunSelectedMode: Bool {
        style.isVerbatim || isModeEnabled(mode)
    }

    private var ctaTitle: String {
        canRunSelectedMode ? "Polish as \(style.name)" : "Configure in Settings"
    }

    private var modeHint: String? {
        if mode == .voiceMatch && !canRunSelectedMode {
            return "Add a writing sample in Settings to use Voice Match."
        }
        return nil
    }

    private var hasVoiceSample: Bool {
        !voiceSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isModeEnabled(_ mode: PolishRewriteMode) -> Bool {
        mode != .voiceMatch || hasVoiceSample
    }

    @ViewBuilder
    private var modePreview: some View {
        switch mode {
        case .normal:
            EmptyView()
        case .voiceMatch:
            ModePreviewRows(rows: [
                ("signature", "Uses the writing sample saved in Settings"),
                ("text.quote", "\(voiceSample.count) characters configured"),
            ])
        case .naturalAudit:
            ModePreviewRows(rows: [
                ("text.magnifyingglass", "Stiff phrase cleanup"),
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

private struct PolishModeCard: View {
    let mode: PolishRewriteMode
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(iconBackground))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(mode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isEnabled ? .primary : .secondary)
                        if let badge = mode.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isEnabled ? Color.polishTeal : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(isEnabled ? Color.polishTealSoft : Color(.systemFill)))
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
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.52)
    }

    private var iconColor: Color {
        if !isEnabled { return Color(.systemGray2) }
        return isSelected ? .white : Color.polishTeal
    }

    private var iconBackground: Color {
        if !isEnabled { return Color(.systemFill) }
        return isSelected ? Color.polishTeal : Color.polishTealSoft
    }
}

private extension PolishRewriteMode {
    var icon: String {
        switch self {
        case .normal: return "bolt.fill"
        case .voiceMatch: return "person.text.rectangle"
        case .naturalAudit: return "checklist.checked"
        case .altTranslation: return "arrow.triangle.2.circlepath"
        case .translationHop: return "globe"
        }
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
