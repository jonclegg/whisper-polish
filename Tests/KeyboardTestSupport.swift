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
            nextWords: try! String(contentsOf: folder.appendingPathComponent("next-words.txt"), encoding: .utf8)
        )
    }()
}
