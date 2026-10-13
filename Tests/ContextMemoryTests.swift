import XCTest

final class ContextMemoryTests: XCTestCase {
    private let document = UUID()

    /// Feeds what a sentence-at-a-time host reports while `message` is typed one character at a time.
    private func typed(_ message: String) -> [String] {
        var memory = ContextMemory()
        var seen: [String] = []
        for end in message.indices {
            let before = String(message[...end])
            seen.append(memory.extend(sentenceHostReport(before), after: "", document: document))
        }
        return seen
    }

    func testRemembersEarlierSentencesWhileTyping() {
        let message = "Thanks for the help. I owe you one! See you Monday"
        XCTAssertEqual(sentenceHostReport(message), "See you Monday")
        XCTAssertEqual(typed(message), message.indices.map { String(message[...$0]) })
    }

    func testDeletingBackStaysInTheMessage() {
        var memory = ContextMemory()
        _ = memory.extend("Hi there. ", after: "", document: document)
        _ = memory.extend("I am", after: "", document: document)
        XCTAssertEqual(memory.extend("I a", after: "", document: document), "Hi there. I a")
    }

    func testAMovedCursorStartsOver() {
        var memory = ContextMemory()
        _ = memory.extend("Hi there. ", after: "", document: document)
        XCTAssertEqual(memory.extend("Hi th", after: "ere. ", document: document), "Hi th")
    }

    func testAnotherFieldOrAnEmptiedFieldStartsOver() {
        var memory = ContextMemory()
        _ = memory.extend("Hi there. ", after: "", document: document)
        XCTAssertEqual(memory.extend("", after: "", document: document), "")
        _ = memory.extend("Hi there. ", after: "", document: document)
        XCTAssertEqual(memory.extend("", after: "", document: UUID()), "")
    }

    func testTheHostWinsWhereItDisagrees() {
        var memory = ContextMemory()
        _ = memory.extend("Hi there. I am", after: "", document: document)
        XCTAssertEqual(memory.extend("We are", after: "", document: document), "We are")
    }

    func testKeepsOnlyRecentText() {
        var memory = ContextMemory()
        let long = String(repeating: "Okay. ", count: 200)
        XCTAssertEqual(memory.extend(long, after: "", document: document).count, ContextMemory.length)
    }
}
