import XCTest

/// Holds space on the Whisper Polish keyboard and drags, then reports the
/// caret's visual line after every move the host saw.
final class FloatingCursorUITests: XCTestCase {
    private static let resultsPath = "/tmp/fc-results.txt"
    private static let prose = """
    The morning started slowly with coffee on the porch and a long list of errands that never seemed to get shorter no matter how early we began.

    By noon the sun was high, the dog had found three new places to nap, and the neighbors were already arguing about whose turn it was to mow the strip of grass between the houses.

    We drove into town after lunch. The hardware store was out of the hinges we needed, so we wandered through the farmers market instead and came home with peaches, honey, and a basket of tomatoes far too large for two people.

    In the evening the wind picked up and rattled the screen door. We made a salad with the tomatoes, sliced the peaches over ice cream, and talked about nothing in particular until the stars came out.

    Tomorrow we will try the other hardware store, the one across the river, and maybe stop at the bakery that only opens on weekends.
    """
    private static let longParagraph = [
        "Every word here sits in one long paragraph with no line breaks at all, so only wrapping makes rows.",
        "The river behind the old mill runs quiet in late summer, low enough to cross on the flat stones.",
        "Nobody remembers who built the footbridge, but everyone has an opinion about who should fix it.",
        "On Saturdays the market fills the square with folding tables, hand-painted signs, and arguments over plums.",
        "A man with a cart sells lemonade for a dollar and tells anyone who listens about his time at sea.",
        "By late afternoon the shadows stretch across the cobblestones and the vendors start packing crates.",
        "Children chase pigeons around the fountain while their parents count change and compare tomatoes.",
        "When the bells ring at six the square empties quickly, leaving only paper bags and a few stray cats.",
    ].joined(separator: " ")

    override func setUp() {
        continueAfterFailure = true
    }

    func testBuildOnly() {}

    func testQuick() {
        let app = XCUIApplication()
        app.launchEnvironment = ["HARNESS_TEXT": Self.prose, "HARNESS_CURSOR": "end", "HARNESS_INSET": "16", "HARNESS_FONT_SIZE": "17"]
        app.launch()
        run(app, "quick long-up", by: CGVector(dx: 0, dy: -320))
        app.terminate()
    }

    func testDrags() {
        let fields: [(name: String, inset: String, font: String)] = [
            ("wide17", "16", "17"),
            ("narrow17", "60", "17"),
            ("wide24", "16", "24"),
        ]
        let drags: [(name: String, text: String, cursor: String, delta: CGVector)] = [
            ("up", Self.prose, "end", CGVector(dx: 0, dy: -190)),
            ("long-up", Self.prose, "end", CGVector(dx: 0, dy: -320)),
            ("down", Self.prose, "start", CGVector(dx: 0, dy: 60)),
            ("diagonal", Self.prose, "end", CGVector(dx: -150, dy: -150)),
            ("sideways", Self.prose, "end", CGVector(dx: -160, dy: 0)),
            ("paragraph-up", Self.longParagraph, "end", CGVector(dx: 0, dy: -190)),
        ]
        for field in fields {
            for drag in drags {
                let app = XCUIApplication()
                app.launchEnvironment = [
                    "HARNESS_TEXT": drag.text,
                    "HARNESS_CURSOR": drag.cursor,
                    "HARNESS_INSET": field.inset,
                    "HARNESS_FONT_SIZE": field.font,
                ]
                app.launch()
                run(app, "\(field.name) \(drag.name)", by: drag.delta)
                app.terminate()
            }
        }
    }

    /// The space bar's center, found from the toolbar above the keys.
    private func spaceKey(_ app: XCUIApplication) -> CGPoint {
        let record = app.buttons["Record in Whisper Polish"]
        if !record.waitForExistence(timeout: 10) {
            let next = app.keyboards.buttons["Next keyboard"]
            XCTAssertTrue(next.waitForExistence(timeout: 5), "No keyboard switch key")
            next.tap()
            XCTAssertTrue(record.waitForExistence(timeout: 5), "Whisper Polish keyboard never appeared")
        }
        return CGPoint(x: app.frame.midX, y: record.frame.midY + 20 + 54 * 3.5)
    }

    private func run(_ app: XCUIApplication, _ name: String, by delta: CGVector) {
        let space = spaceKey(app)
        let trace = app.staticTexts["trace"]
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: space.x, dy: space.y))
        let startTrace = trace.label
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(delta), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        let visits = trace.label.dropFirst(startTrace.count).trimmingCharacters(in: .whitespaces)
        let line = "\(name) [start \(startTrace)]: \(visits)\n"
        print("FCRESULT " + line)
        if !FileManager.default.fileExists(atPath: Self.resultsPath) {
            FileManager.default.createFile(atPath: Self.resultsPath, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: Self.resultsPath)!
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }
}
