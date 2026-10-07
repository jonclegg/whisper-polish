import XCTest

final class WordModelTests: XCTestCase {
    private struct Case: Decodable {
        let ids: [Int]
        let top: [Int]
        let logits: [Float]
    }

    /// The Swift model ranks words the way the numpy reference does, from the same Float16 weights.
    func testMatchesTheReferenceImplementation() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let model = try WordModel(contentsOf: folder.deletingLastPathComponent().appendingPathComponent("WhisperPolishKeyboard/Lexicon/word-model.bin"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: folder.appendingPathComponent("Fixtures/word-model.json")))
        for testCase in cases {
            var state = model.start
            for id in testCase.ids { model.advance(&state, with: id) }
            let probabilities = model.probabilities(after: state)
            let expected = zip(testCase.top, testCase.logits).filter { $0.0 != WordModel.boundary }
            let ranked = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }.prefix(expected.count)
            XCTAssertEqual(Array(ranked), expected.map(\.0), "after \(testCase.ids.map { model.words[$0] })")
            // Log-odds between words are logit differences.
            let (first, firstLogit) = expected[0]
            for (id, logit) in expected.dropFirst() {
                XCTAssertEqual(log(probabilities[first] / probabilities[id]), firstLogit - logit, accuracy: 0.01)
            }
        }
    }

    func testPredictionIsQuickEnoughForEveryWord() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let model = try WordModel(contentsOf: folder.appendingPathComponent("WhisperPolishKeyboard/Lexicon/word-model.bin"))
        var state = model.start
        measure {
            model.advance(&state, with: model.id(of: "the"))
            _ = model.probabilities(after: state)
        }
    }
}
