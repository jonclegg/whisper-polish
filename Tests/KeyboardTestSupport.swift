import Foundation

extension Lexicon {
    /// The keyboard's real word lists, read straight from the repository.
    static let repository: Lexicon = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperPolishKeyboard/Lexicon")
        return Lexicon(words: try! String(contentsOf: folder.appendingPathComponent("words.txt"), encoding: .utf8))
    }()
}

extension WordModel {
    /// The keyboard's real word model, read straight from the repository.
    static let repository: WordModel = {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try! WordModel(contentsOf: folder.appendingPathComponent("WhisperPolishKeyboard/Lexicon/word-model.bin"))
    }()
}
