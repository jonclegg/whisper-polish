import XCTest

final class PredictionEngineTests: XCTestCase {
    func testWorkRunsInTheOrderItWasHandedOver() {
        let engine = PredictionEngine()
        engine.perform { $0.setLexicon(.repository, wordModel: .repository, decoder: .repository) }
        for _ in 0..<2 { engine.perform { $0.learnTyped("blorptastic", after: ["so"]) } }
        let learned = engine.performAndWait(until: .now() + 30) { $0.learnedWords }
        XCTAssertEqual(learned, ["blorptastic"])
    }

    func testWaitingGivesUpAtTheDeadline() {
        let engine = PredictionEngine()
        let release = DispatchSemaphore(value: 0)
        engine.perform { _ in release.wait() }
        XCTAssertNil(engine.performAndWait(until: .now() + .milliseconds(20)) { _ in true })
        release.signal()
        XCTAssertEqual(engine.performAndWait(until: .now() + 5) { _ in true }, true)
    }
}
