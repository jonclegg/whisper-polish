import SwiftUI

/// Read-only findings from a fact-check run. Advisory by design: nothing here
/// edits the note.
struct FactCheckReportView: View {
    let report: FactCheckReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if report.findings.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(report.sorted) { finding in
                                FactCheckFindingRow(finding: finding)
                            }
                        } footer: {
                            footer
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Fact check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing to check")
                .font(.headline)
            Text("No specific factual claims turned up in this note.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            footer
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var footer: some View {
        Text("Checked by \(FactCheckService.displayName(for: report.model)) with web search. Treat this as a second opinion, not a verdict.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct FactCheckFindingRow: View {
    let finding: FactCheckFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VerdictBadge(verdict: finding.verdict)

            Text(finding.claim)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)

            if !finding.note.isEmpty {
                Text(finding.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ForEach(finding.sources) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text(source.title.isEmpty ? source.url : source.title)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct VerdictBadge: View {
    let verdict: FactCheckFinding.Verdict

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
    }

    private var title: String {
        switch verdict {
        case .supported: return "Supported"
        case .contradicted: return "Contradicted"
        case .unverifiable: return "Unverified"
        }
    }

    private var icon: String {
        switch verdict {
        case .supported: return "checkmark.circle.fill"
        case .contradicted: return "exclamationmark.triangle.fill"
        case .unverifiable: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch verdict {
        case .supported: return Color.polishTeal
        case .contradicted: return Color(red: 0.78, green: 0.18, blue: 0.15)
        case .unverifiable: return Color.secondary
        }
    }
}

#Preview {
    FactCheckReportView(report: FactCheckReport(
        findings: [
            FactCheckFinding(
                claim: "The Apollo 11 landing was in 1968.",
                verdict: .contradicted,
                note: "Apollo 11 landed on 20 July 1969. Apollo 8 orbited the Moon in December 1968.",
                sources: [.init(title: "nasa.gov", url: "https://www.nasa.gov/mission/apollo-11/")]
            ),
            FactCheckFinding(
                claim: "Swift was open-sourced in 2015.",
                verdict: .supported,
                note: "Apple released Swift under the Apache 2.0 licence in December 2015.",
                sources: [.init(title: "swift.org", url: "https://www.swift.org/")]
            ),
            FactCheckFinding(
                claim: "Their Q3 churn came in under four percent.",
                verdict: .unverifiable,
                note: "No public filing or report covers this figure.",
                sources: []
            ),
        ],
        model: FactCheckService.model
    ))
}
