import SwiftUI
import UIKit

/// EXPERIMENT: the app side of the on-device polish lab. Launched with `-lab`,
/// it moves a plan and models copied into Documents/lab into the App Group,
/// keeps a text field focused so the keyboard shows and runs the plan, brings
/// the keyboard back whenever it dies, and mirrors results into Documents.
struct LabView: View {
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var status = "Starting…"
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let groupLab = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!
        .appendingPathComponent("lab")
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device polish lab").font(.headline)
            Text(status).font(.footnote.monospaced())
            TextField("The keyboard runs the lab here", text: $text, axis: .vertical)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
            Spacer()
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            Self.importFiles()
            isFocused = true
        }
        .onReceive(timer) { _ in tick() }
    }

    private static func importFiles() {
        let manager = FileManager.default
        let source = documents.appendingPathComponent("lab")
        try? manager.createDirectory(at: groupLab.appendingPathComponent("models"), withIntermediateDirectories: true)
        // Deletes the lab's models and results, and any partial downloads, to give the space back.
        if ProcessInfo.processInfo.arguments.contains("-labClean") {
            try? manager.removeItem(at: groupLab)
            try? manager.removeItem(at: source)
            for name in (try? manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path)) ?? [] {
                try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent(name))
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-labReset") {
            try? manager.removeItem(at: groupLab.appendingPathComponent("progress.json"))
            try? manager.removeItem(at: groupLab.appendingPathComponent("results.jsonl"))
            try? manager.removeItem(at: groupLab.appendingPathComponent("breadcrumbs.log"))
        }
        for name in (try? manager.contentsOfDirectory(atPath: source.path)) ?? [] {
            let from = source.appendingPathComponent(name)
            if name == "models" {
                for model in (try? manager.contentsOfDirectory(atPath: from.path)) ?? [] {
                    let target = groupLab.appendingPathComponent("models/\(model)")
                    try? manager.removeItem(at: target)
                    try? manager.moveItem(at: from.appendingPathComponent(model), to: target)
                }
            } else {
                let target = groupLab.appendingPathComponent(name)
                try? manager.removeItem(at: target)
                try? manager.moveItem(at: from, to: target)
            }
        }
    }

    private func tick() {
        let manager = FileManager.default
        let results = Self.groupLab.appendingPathComponent("results.jsonl")
        let mirror = Self.documents.appendingPathComponent("lab-results.jsonl")
        try? manager.removeItem(at: mirror)
        try? manager.copyItem(at: results, to: mirror)
        let crumbs = Self.documents.appendingPathComponent("lab-breadcrumbs.log")
        try? manager.removeItem(at: crumbs)
        try? manager.copyItem(at: Self.groupLab.appendingPathComponent("breadcrumbs.log"), to: crumbs)
        let resultCount = ((try? String(contentsOf: results, encoding: .utf8)) ?? "").split(separator: "\n").count
        guard let planData = try? Data(contentsOf: Self.groupLab.appendingPathComponent("plan.json")),
              let plan = try? JSONSerialization.jsonObject(with: planData) as? [String: Any],
              let steps = plan["steps"] as? [Any] else {
            status = "No plan in the App Group"
            return
        }
        let progressData = try? Data(contentsOf: Self.groupLab.appendingPathComponent("progress.json"))
        let progress = progressData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let next = progress?["next"] as? Int ?? 0
        let updatedAt = (progress?["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let models = (try? manager.contentsOfDirectory(atPath: Self.groupLab.appendingPathComponent("models").path)) ?? []
        status = "steps \(next)/\(steps.count) · results \(resultCount) · models \(models.count)"
        guard next < steps.count else { return }
        // A dead keyboard stops beating; refocusing starts a fresh one.
        let stale = Date().timeIntervalSince(updatedAt ?? .distantPast) > 900
        if stale {
            status += " · relaunching keyboard"
            isFocused = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isFocused = true }
        }
    }
}
