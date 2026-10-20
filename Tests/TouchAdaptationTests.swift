import XCTest

final class TouchAdaptationTests: XCTestCase {
    private let drawn = KeyGeometry.letters

    private func touches(_ word: String, dx: CGFloat, dy: CGFloat) -> [CGPoint?] {
        word.map { CGPoint(x: drawn.centers[$0]!.x + dx, y: drawn.centers[$0]!.y + dy) }
    }

    func testKeysMoveToWhereTheyreTouched() {
        var adaptation = TouchAdaptation()
        for _ in 0..<20 { adaptation.learn("dog", points: touches("dog", dx: 0.2, dy: 0.1)) }
        let learned = adaptation.geometry()
        XCTAssertEqual(learned.centers["d"]!.x, drawn.centers["d"]!.x + 0.2, accuracy: 0.001)
        XCTAssertEqual(learned.centers["o"]!.y, drawn.centers["o"]!.y + 0.1, accuracy: 0.001)
        XCTAssertEqual(learned.centers["q"], drawn.centers["q"], "Untouched keys stay put")
    }

    func testAKeyNeedsAFewTouchesBeforeItMoves() {
        var adaptation = TouchAdaptation()
        for _ in 0..<(TouchAdaptation.touchesToTrust - 1) { adaptation.learn("a", points: touches("a", dx: 0.2, dy: 0)) }
        XCTAssertEqual(adaptation.geometry().centers["a"], drawn.centers["a"])
        adaptation.learn("a", points: touches("a", dx: 0.2, dy: 0))
        XCTAssertNotEqual(adaptation.geometry().centers["a"], drawn.centers["a"])
    }

    func testOffsetsAreCappedAndStrayTouchesIgnored() {
        var adaptation = TouchAdaptation()
        for _ in 0..<50 { adaptation.learn("k", points: touches("k", dx: 0.6, dy: 0)) }
        XCTAssertEqual(adaptation.geometry().centers["k"]!.x, drawn.centers["k"]!.x + TouchAdaptation.maxOffset, accuracy: 0.001)
        var steady = TouchAdaptation()
        for _ in 0..<10 { steady.learn("k", points: touches("k", dx: 0.1, dy: 0)) }
        steady.learn("k", points: touches("k", dx: -2, dy: 0))
        XCTAssertEqual(steady.geometry().centers["k"]!.x, drawn.centers["k"]!.x + 0.1, accuracy: 0.001)
    }

    func testAHabitCanChange() {
        var adaptation = TouchAdaptation()
        for _ in 0..<20 { adaptation.learn("e", points: touches("e", dx: 0.2, dy: 0)) }
        for _ in 0..<200 { adaptation.learn("e", points: touches("e", dx: -0.1, dy: 0)) }
        XCTAssertEqual(adaptation.geometry().centers["e"]!.x, drawn.centers["e"]!.x - 0.1, accuracy: 0.02)
    }

    func testTheDecoderAimsAtLearnedCenters() {
        // Touches a quarter key right of each key mean nothing once the keys are learned there.
        var decoder = WordDecoder.repository
        let typed = touches("hello", dx: 0.25, dy: 0)
        let before = decoder.spatialScore(typed: "hello", touches: typed)!
        var adaptation = TouchAdaptation()
        for _ in 0..<10 { adaptation.learn("hello", points: typed) }
        decoder.aim(at: adaptation.geometry())
        XCTAssertLessThan(before, -1)
        XCTAssertEqual(decoder.spatialScore(typed: "hello", touches: typed)!, 0, accuracy: 0.001)
    }

    func testItSurvivesBeingSaved() throws {
        var adaptation = TouchAdaptation()
        for _ in 0..<10 { adaptation.learn("hey", points: touches("hey", dx: 0.1, dy: 0.05)) }
        XCTAssertEqual(try JSONDecoder().decode(TouchAdaptation.self, from: JSONEncoder().encode(adaptation)), adaptation)
    }
}
