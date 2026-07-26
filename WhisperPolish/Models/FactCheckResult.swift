import Foundation

/// One checkable claim pulled out of a note, plus what the web said about it.
struct FactCheckFinding: Codable, Equatable, Identifiable {
    enum Verdict: String, Codable, Equatable {
        case supported
        case contradicted
        case unverifiable
    }

    struct Source: Codable, Equatable, Identifiable {
        let title: String
        let url: String

        var id: String { url }
    }

    let id = UUID()
    let claim: String
    let verdict: Verdict
    let note: String
    let sources: [Source]

    // `id` is ours, not the model's; keep it out of the wire format so a
    // decode never fails on a missing field we never asked for.
    private enum CodingKeys: String, CodingKey {
        case claim, verdict, note, sources
    }

    init(claim: String, verdict: Verdict, note: String, sources: [Source]) {
        self.claim = claim
        self.verdict = verdict
        self.note = note
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claim = try container.decode(String.self, forKey: .claim)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        // A model that invents a fourth verdict shouldn't sink the whole
        // report. Anything we don't recognise is treated as unproven.
        let raw = try container.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        verdict = Verdict(rawValue: raw.lowercased()) ?? .unverifiable
    }
}

/// The result of one fact-check run. Ephemeral: tied to the exact text that
/// produced it, discarded when the report sheet closes.
struct FactCheckReport: Equatable, Identifiable {
    let id = UUID()
    let findings: [FactCheckFinding]
    let model: String

    var contradicted: [FactCheckFinding] { findings.filter { $0.verdict == .contradicted } }

    /// Findings sorted so the things worth your attention come first.
    var sorted: [FactCheckFinding] {
        findings.sorted { rank($0.verdict) < rank($1.verdict) }
    }

    private func rank(_ verdict: FactCheckFinding.Verdict) -> Int {
        switch verdict {
        case .contradicted: return 0
        case .unverifiable: return 1
        case .supported: return 2
        }
    }
}
