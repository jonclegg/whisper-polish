import Foundation

extension Lexicon {
    /// The keyboard's real word lists, read straight from the repository.
    static let repository: Lexicon = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperPolishKeyboard/Lexicon")
        return Lexicon(
            words: try! String(contentsOf: folder.appendingPathComponent("words.txt"), encoding: .utf8),
            casedAfter: try! String(contentsOf: folder.appendingPathComponent("cased-after.txt"), encoding: .utf8)
        )
    }()
}

extension WordModel {
    /// The keyboard's real word model, read straight from the repository.
    static let repository: WordModel = {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try! WordModel(contentsOf: folder.appendingPathComponent("WhisperPolishKeyboard/Lexicon/word-model.bin"))
    }()
}

/// What a host like Messages reports before the cursor: back to the start of the
/// sentence holding the character before the cursor.
func sentenceHostReport(_ before: String) -> String {
    let characters = Array(before)
    guard !characters.isEmpty else { return "" }
    func startsSentence(_ index: Int) -> Bool {
        index == 0 || characters[index - 1] == "\n"
            || (index > 1 && characters[index - 1] == " " && ".!?".contains(characters[index - 2]))
    }
    var start = characters.count - 1
    while !startsSentence(start) { start -= 1 }
    return String(characters[start...])
}
