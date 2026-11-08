// Polishes every input with Apple's on-device Foundation Models, using the
// app's polish prompt as the session instructions.
//
// Usage: swift polish_apple.swift INPUTS.jsonl SYSTEM_PROMPTS.json OUT.jsonl
import Foundation
import FoundationModels

let arguments = CommandLine.arguments
let inputs = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
}
let prompts = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: String]
let model = SystemLanguageModel.default
print("availability:", model.availability)
var lines: [String] = []
for row in inputs {
    let style = row["style"] as! String
    let text = row["text"] as! String
    let session = LanguageModelSession(instructions: prompts[style]!)
    let started = Date()
    var output: String
    do {
        output = try await session.respond(to: arguments.count > 4 ? text : "<transcript>\n\(text)\n</transcript>", options: GenerationOptions(temperature: 0.7)).content
    } catch {
        output = "ERROR: \(error)"
    }
    var result = row
    result["output"] = output
    result["model"] = "apple-foundation"
    result["seconds"] = Date().timeIntervalSince(started)
    lines.append(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    print(row["id"]!, String(format: "%.1fs", Date().timeIntervalSince(started)), output.prefix(60).replacingOccurrences(of: "\n", with: " "))
}
try (lines.joined(separator: "\n") + "\n").write(toFile: arguments[3], atomically: true, encoding: .utf8)
