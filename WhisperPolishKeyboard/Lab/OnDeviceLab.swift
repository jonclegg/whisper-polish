import Foundation
import FoundationModels
import UIKit

/// EXPERIMENT: runs a plan of on-device polish trials inside the keyboard, one
/// step at a time, and records memory, speed and output for each. A step the
/// keyboard dies in (jetsam kills it silently) is recorded as killed the next
/// time the keyboard starts, and the plan moves on.
///
/// Files live in the App Group container under `lab/`:
/// `plan.json` (written by the app), `progress.json`, `results.jsonl`, `models/`.
enum OnDeviceLab {
    struct Plan: Codable {
        let steps: [Step]
        let inputs: [Input]
        let prompts: [String: [String: String]]
    }

    struct Step: Codable {
        let id: String
        let kind: String
        var model: String?
        var gpuLayers: Int32?
        var contextTokens: Int?
        var threads: Int32?
        var prompt: String?
        var inputCount: Int?
        var cacheBits: Int?
        var extraBuffers: Bool?
        var microBatch: Int?
        var cpuOnly: Bool?
        var draftLength: Int?
    }

    struct Input: Codable {
        let id: String
        let style: String
        let text: String
    }

    struct Progress: Codable {
        var next: Int
        var running: Int?
        var startedAt: Date?
        var updatedAt: Date
    }

    static var directory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)!.appendingPathComponent("lab")
    }

    private static var planURL: URL { directory.appendingPathComponent("plan.json") }
    private static var progressURL: URL { directory.appendingPathComponent("progress.json") }
    private static var resultsURL: URL { directory.appendingPathComponent("results.jsonl") }

    private static var isRunning = false

    /// Called each time the keyboard appears. Runs every remaining step in turn.
    @MainActor
    static func resume(host: UIView, report: @escaping @MainActor (String) -> Void) {
        guard !isRunning, let plan = try? JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL)) else { return }
        var progress = loadProgress()
        if let running = progress.running {
            append(["step": plan.steps[running].id, "status": "killed", "after_seconds": Date().timeIntervalSince(progress.startedAt ?? Date())])
            progress.next = running + 1
            progress.running = nil
            save(progress)
        }
        guard progress.next < plan.steps.count else { return report("Lab: all \(plan.steps.count) steps done") }
        isRunning = true
        Task { @MainActor in
            while progress.next < plan.steps.count {
                let index = progress.next
                let step = plan.steps[index]
                progress.running = index
                progress.startedAt = Date()
                save(progress)
                report("Lab \(index + 1)/\(plan.steps.count): \(step.id)…")
                LabMemory.breadcrumb("step-start \(step.id)")
                var result: [String: Any] = ["step": step.id, "kind": step.kind, "memory_before": LabMemory.snapshot()]
                let started = Date()
                let beating = progress
                let heartbeat = Task.detached {
                    while true {
                        try? await Task.sleep(for: .seconds(3))
                        if Task.isCancelled { return }
                        save(beating)
                    }
                }
                do {
                    let details = try await run(step, plan: plan, host: host)
                    result.merge(details) { $1 }
                    result["status"] = "ok"
                } catch {
                    result["status"] = "error"
                    result["error"] = "\(error)"
                }
                heartbeat.cancel()
                await heartbeat.value
                result["seconds"] = Date().timeIntervalSince(started)
                result["memory_after"] = LabMemory.snapshot()
                append(result)
                progress.running = nil
                progress.next = index + 1
                save(progress)
            }
            isRunning = false
            report("Lab: all \(plan.steps.count) steps done")
        }
    }

    // MARK: - Steps

    @MainActor
    private static func run(_ step: Step, plan: Plan, host: UIView) async throws -> [String: Any] {
        switch step.kind {
        case "probe": return probe()
        case "writingTools":
            guard #available(iOS 18.2, *) else { throw LabError.unsupportedOS }
            return writingTools(host: host)
        case "foundation":
            guard #available(iOS 26, *) else { throw LabError.unsupportedOS }
            return try await foundation(step, plan: plan)
        case "foundationBurst":
            guard #available(iOS 26, *) else { throw LabError.unsupportedOS }
            return await foundationBurst(plan: plan)
        case "mmapTouch": return try await Task.detached { try mmapTouch(step) }.value
        case "llama": return try await Task.detached { try llama(step, plan: plan) }.value
        case "dirty": return await Task.detached { dirty() }.value
        default: throw LabError.unknownStep(step.kind)
        }
    }

    private static func probe() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return [
            "device": machine,
            "os": UIDevice.current.systemVersion,
            "physical_memory_mb": Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576,
            "limit_estimate_mb": LabMemory.footprintMB() + LabMemory.availableMB(),
            "cpu_count": ProcessInfo.processInfo.activeProcessorCount,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
        ]
    }

    @available(iOS 18.2, *)
    @MainActor
    private static func writingTools(host: UIView) -> [String: Any] {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        textView.text = "um so i think we should like meet tmrw at 3"
        textView.writingToolsBehavior = .complete
        host.addSubview(textView)
        defer { textView.removeFromSuperview() }
        textView.selectAll(nil)
        let canShow = textView.canPerformAction(#selector(UIResponder.showWritingTools(_:)), withSender: nil)
        return [
            "coordinator_available": UIWritingToolsCoordinator.isWritingToolsAvailable,
            "text_view_behavior": textView.writingToolsBehavior.rawValue,
            "can_show_writing_tools": canShow,
        ]
    }

    @available(iOS 26, *)
    @MainActor
    private static func foundation(_ step: Step, plan: Plan) async throws -> [String: Any] {
        let model = SystemLanguageModel.default
        var details: [String: Any] = ["availability": "\(model.availability)"]
        guard model.isAvailable else { return details }
        let promptName = step.prompt ?? "app"
        var outputs: [[String: Any]] = []
        let watcher = LabMemory.PeakWatcher()
        watcher.start()
        for input in plan.inputs.prefix(step.inputCount ?? plan.inputs.count) {
            let session = LanguageModelSession(instructions: plan.prompts[promptName]![input.style]!)
            let user = promptName == "app" ? "<transcript>\n\(input.text)\n</transcript>" : input.text
            let started = Date()
            do {
                let response = try await session.respond(to: user, options: GenerationOptions(temperature: 0.3))
                outputs.append(["id": input.id, "style": input.style, "output": response.content, "seconds": Date().timeIntervalSince(started)])
            } catch {
                outputs.append(["id": input.id, "style": input.style, "error": "\(error)", "seconds": Date().timeIntervalSince(started)])
            }
        }
        details["peak_footprint_mb"] = watcher.stop()
        details["outputs"] = outputs
        return details
    }

    /// Eight short requests back to back, to see whether the keyboard gets rate limited.
    @available(iOS 26, *)
    @MainActor
    private static func foundationBurst(plan: Plan) async -> [String: Any] {
        var results: [String] = []
        for _ in 0..<8 {
            let session = LanguageModelSession(instructions: "Fix the grammar. Reply with the fixed text only.")
            do {
                _ = try await session.respond(to: "me and him goes to the store yesterday")
                results.append("ok")
            } catch {
                results.append("\(error)")
            }
        }
        return ["results": results]
    }

    /// Maps a model file shared and read-only and reads every page.
    private static func mmapTouch(_ step: Step) throws -> [String: Any] {
        let path = directory.appendingPathComponent("models/\(step.model!)").path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw LabError.missingModel(step.model!) }
        defer { close(descriptor) }
        var status = stat()
        fstat(descriptor, &status)
        let size = Int(status.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), base != MAP_FAILED else { throw LabError.mmap }
        defer { munmap(base, size) }
        let before = LabMemory.snapshot()
        var checksum: UInt64 = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset < size {
            checksum &+= UInt64(bytes[offset])
            offset += 16_384
        }
        return ["file_mb": Double(size) / 1_048_576, "before": before, "after_touch": LabMemory.snapshot(), "checksum": checksum]
    }

    private static func llama(_ step: Step, plan: Plan) throws -> [String: Any] {
        let path = directory.appendingPathComponent("models/\(step.model!)").path
        guard FileManager.default.fileExists(atPath: path) else { throw LabError.missingModel(step.model!) }
        let watcher = LabMemory.PeakWatcher()
        watcher.start()
        let loadStarted = Date()
        let polisher = try LlamaPolisher(
            modelPath: path,
            gpuLayers: step.gpuLayers ?? 0,
            contextTokens: step.contextTokens ?? 1536,
            threads: step.threads ?? 4,
            cacheBits: step.cacheBits ?? 8,
            extraBuffers: step.extraBuffers ?? true,
            microBatch: step.microBatch ?? 512,
            outputsPerBatch: (step.draftLength ?? 0) + 1,
            cpuOnly: step.cpuOnly ?? false,
            trace: LabMemory.breadcrumb
        )
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        let afterLoad = LabMemory.snapshot()
        let promptName = step.prompt ?? "compact"
        var outputs: [[String: Any]] = []
        for input in plan.inputs.prefix(step.inputCount ?? 3) {
            let system = promptName == "tuned" ? nil : plan.prompts[promptName]?[input.style]
            let user: String
            switch promptName {
            case "app": user = "<transcript>\n\(input.text)\n</transcript>"
            case "tuned": user = "Style: \(plan.prompts["instruction"]![input.style]!)\n\nText:\n\(input.text)"
            default: user = input.text
            }
            let prompt = try polisher.prompt(system: system, user: user)
            do {
                let output = try polisher.complete(prompt, maxTokens: 700, draftLength: step.draftLength ?? 0)
                outputs.append([
                    "id": input.id, "style": input.style, "output": output.text,
                    "prompt_tokens": output.promptTokens, "generated_tokens": output.generatedTokens,
                    "prefill_seconds": output.prefillSeconds, "decode_seconds": output.decodeSeconds,
                    "decode_steps": output.decodeSteps,
                    "footprint_mb": LabMemory.footprintMB(),
                ])
            } catch {
                outputs.append(["id": input.id, "style": input.style, "error": "\(error)"])
            }
        }
        return [
            "load_seconds": loadSeconds, "after_load": afterLoad,
            "peak_footprint_mb": watcher.stop(), "outputs": outputs,
        ]
    }

    /// Allocates and dirties memory in 4 MB steps until iOS says less than 8 MB is left.
    private static func dirty() -> [String: Any] {
        var blocks: [UnsafeMutableRawPointer] = []
        defer { blocks.forEach { free($0) } }
        var trace: [[String: Double]] = []
        while LabMemory.availableMB() > 8, blocks.count < 1000 {
            let block = malloc(4 * 1_048_576)!
            memset(block, 1, 4 * 1_048_576)
            blocks.append(block)
            if blocks.count % 5 == 0 { trace.append(LabMemory.snapshot()) }
        }
        return ["allocated_mb": blocks.count * 4, "at_stop": LabMemory.snapshot(), "trace": trace]
    }

    // MARK: - Files

    private static func loadProgress() -> Progress {
        (try? JSONDecoder.lab.decode(Progress.self, from: Data(contentsOf: progressURL))) ?? Progress(next: 0, running: nil, startedAt: nil, updatedAt: Date())
    }

    private static func save(_ progress: Progress) {
        var progress = progress
        progress.updatedAt = Date()
        try? JSONEncoder.lab.encode(progress).write(to: progressURL, options: .atomic)
    }

    private static func append(_ result: [String: Any]) {
        var line = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{\"error\":\"unencodable\"}".utf8)
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: resultsURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: resultsURL)
        }
    }

    enum LabError: Error {
        case unknownStep(String), missingModel(String), mmap, unsupportedOS
    }
}

extension JSONDecoder {
    static let lab: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let lab: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
