import AppKit
import XCTest
@testable import DogballWhisper

@MainActor
final class FakeSelection: SelectionAccessing {
    var target = FixTarget(originalText: "i has a apple", sourcePID: 42, replacesSelection: true)
    var captureError: Error?
    var replaceError: Error?
    private(set) var captureCount = 0
    private(set) var replaced: [String] = []
    private(set) var copied: [String] = []
    private(set) var focusReturns = 0

    func capture() async throws -> FixTarget {
        captureCount += 1
        if let captureError { throw captureError }
        return target
    }
    func replace(_ target: FixTarget, with text: String) async throws {
        if let replaceError { throw replaceError }
        replaced.append(text)
    }
    func copyToClipboard(_ text: String) { copied.append(text) }
    func returnFocus(to target: FixTarget) { focusReturns += 1 }
}

final class FakeFixer: TextFixing, @unchecked Sendable {
    var result = "I have an apple."
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var received: [String] = []

    func fix(_ text: String, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        received.append(text)
        onText("I have")
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return result
    }
}

@MainActor
final class FakeFixPresenter: FixPresenting {
    enum Event: Equatable {
        case loading(title: String, subtitle: String)
        case streaming(String)
        case result(original: String, fixed: String, acceptTitle: String)
        case error(String)
        case hidden
    }

    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var events: [Event] = []

    func showLoading(title: String, subtitle: String) { events.append(.loading(title: title, subtitle: subtitle)) }
    func updateStreaming(text: String) { events.append(.streaming(text)) }
    func showResult(original: String, fixed: String, acceptTitle: String) {
        events.append(.result(original: original, fixed: fixed, acceptTitle: acceptTitle))
    }
    func showError(_ message: String) { events.append(.error(message)) }
    func hide() { events.append(.hidden) }
}

@MainActor
final class FixControllerTests: XCTestCase {
    private var selection: FakeSelection!
    private var fixer: FakeFixer!
    private var presenter: FakeFixPresenter!
    private var installed = true

    override func setUp() {
        super.setUp()
        selection = FakeSelection()
        fixer = FakeFixer()
        presenter = FakeFixPresenter()
        installed = true
    }

    private func makeController() -> FixController {
        FixController(
            selection: selection, fixer: fixer, presenter: presenter,
            isModelInstalled: { [unowned self] in self.installed })
    }

    /// Lets the streaming hops, which go through their own main-actor tasks,
    /// land before asserting.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testShowsWorkingThenTheEditForReview() async {
        let controller = makeController()
        await controller.trigger()?.value
        await settle()

        XCTAssertEqual(fixer.received, ["i has a apple"])
        XCTAssertEqual(presenter.events.first, .loading(
            title: "Fixing selected text…", subtitle: "Running S1-mini by Superwhisper on this Mac"))
        XCTAssertTrue(presenter.events.contains(.result(
            original: "i has a apple", fixed: "I have an apple.", acceptTitle: "Replace")))
        XCTAssertFalse(controller.isProcessing)
    }

    func testReplacePastesTheFixOverTheSelection() async {
        let controller = makeController()
        await controller.trigger()?.value
        presenter.onAccept?()
        await settle()
        XCTAssertEqual(selection.replaced, ["I have an apple."])
        XCTAssertTrue(selection.copied.isEmpty)
    }

    // Esc or Dismiss after the review hands focus back without changing anything.
    func testDismissLeavesTheTextAloneAndReturnsFocus() async {
        let controller = makeController()
        await controller.trigger()?.value
        presenter.onDismiss?()
        XCTAssertTrue(selection.replaced.isEmpty)
        XCTAssertEqual(selection.focusReturns, 1)
    }

    // Fixit's fallback: nothing selected means fix the clipboard, and
    // accepting copies rather than pastes.
    func testClipboardTextIsCopiedBackRatherThanPasted() async {
        selection.target = FixTarget(originalText: "i has a apple", sourcePID: 42, replacesSelection: false)
        let controller = makeController()
        await controller.trigger()?.value
        XCTAssertEqual(presenter.events.first, .loading(
            title: "Fixing clipboard text…", subtitle: "Running S1-mini by Superwhisper on this Mac"))
        XCTAssertEqual(presenter.events.last, .result(
            original: "i has a apple", fixed: "I have an apple.", acceptTitle: "Copy to Clipboard"))

        presenter.onAccept?()
        XCTAssertEqual(selection.copied, ["I have an apple."])
        XCTAssertTrue(selection.replaced.isEmpty)
    }

    func testTheAnswerIsShownAsItIsWritten() async {
        fixer.delay = 0.05
        let controller = makeController()
        await controller.trigger()?.value
        XCTAssertTrue(presenter.events.contains(.streaming("I have")))
    }

    func testCancelStopsTheModelAndClosesTheDialog() async throws {
        fixer.delay = 5
        let controller = makeController()
        let work = controller.trigger()
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        presenter.onCancel?()
        await work?.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(presenter.events.last, .hidden)
        XCTAssertFalse(presenter.events.contains { if case .result = $0 { return true } else { return false } })
        XCTAssertEqual(selection.focusReturns, 1)
        XCTAssertFalse(controller.isProcessing)
    }

    // A second ⌘⇧1 while one is running would copy the dialog's own text.
    func testASecondPressWhileWorkingIsIgnored() async {
        fixer.delay = 0.1
        let controller = makeController()
        let first = controller.trigger()
        XCTAssertNil(controller.trigger())
        await first?.value
        XCTAssertEqual(selection.captureCount, 1)
        XCTAssertNotNil(controller.trigger())
    }

    func testAMissingModelIsReportedWithoutTouchingTheClipboard() async {
        installed = false
        let controller = makeController()
        await controller.trigger()?.value
        XCTAssertEqual(selection.captureCount, 0)
        XCTAssertEqual(presenter.events, [.error(S1MiniError.notInstalled.localizedDescription)])
    }

    func testNothingToFixIsReported() async {
        selection.captureError = FixError.noSelection
        let controller = makeController()
        await controller.trigger()?.value
        XCTAssertEqual(presenter.events, [.error(FixError.noSelection.localizedDescription)])
        XCTAssertTrue(fixer.received.isEmpty)
    }

    func testAModelFailureIsReported() async {
        fixer.error = LlamaError.decodeFailed(-1)
        let controller = makeController()
        await controller.trigger()?.value
        XCTAssertEqual(presenter.events.last, .error(LlamaError.decodeFailed(-1).localizedDescription))
    }

    func testAFailedPasteIsReported() async {
        selection.replaceError = FixError.pasteFailed
        let controller = makeController()
        await controller.trigger()?.value
        presenter.onAccept?()
        await settle()
        XCTAssertEqual(presenter.events.last, .error(FixError.pasteFailed.localizedDescription))
    }

    // A triple-clicked paragraph ends in a newline the model trims away;
    // Replace must not join it onto the next paragraph.
    func testReplaceKeepsTheSelectionsSurroundingWhitespace() async {
        selection.target = FixTarget(originalText: "  i has a apple\n", sourcePID: 42, replacesSelection: true)
        let controller = makeController()
        await controller.trigger()?.value
        presenter.onAccept?()
        await settle()
        XCTAssertEqual(selection.replaced, ["  I have an apple.\n"])
    }

    func testSurroundingWhitespaceIsOnlyAddedBackWhenThereWasSome() {
        let target = FixTarget(originalText: "i has", sourcePID: nil, replacesSelection: true)
        XCTAssertEqual(target.restoringSurroundingWhitespace("I have."), "I have.")
        let padded = FixTarget(originalText: "\ti has\n\n", sourcePID: nil, replacesSelection: true)
        XCTAssertEqual(padded.restoringSurroundingWhitespace("I have."), "\tI have.\n\n")
    }
}

final class InlineDiffBuilderTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 14)

    func testIdenticalTextHasNoMarkup() {
        let segments = split(InlineDiffBuilder.attributedDiff(original: "same text", fixed: "same text", font: font))
        XCTAssertEqual(segments.fixed, "same text")
        XCTAssertEqual(segments.deleted, "")
        XCTAssertEqual(segments.added, "")
    }

    func testMarkedSegmentsReconstructBothTexts() {
        let cases: [(original: String, fixed: String)] = [
            ("hello world", "hello there"),
            ("I goes to school", "I go to school"),
            ("", "brand new"),
            ("all gone", ""),
            ("keep  double  spaces", "keep  double  spaces!"),
            ("emoji 🎉 stays", "emoji 🎉 remains"),
        ]
        for (original, fixed) in cases {
            let segments = split(InlineDiffBuilder.attributedDiff(original: original, fixed: fixed, font: font))
            XCTAssertEqual(segments.original, original, "\(original) -> \(fixed)")
            XCTAssertEqual(segments.fixed, fixed, "\(original) -> \(fixed)")
        }
    }

    func testAChangedWordIsShownStruckThroughThenItsReplacement() {
        XCTAssertEqual(
            InlineDiffBuilder.operations(original: "hello world", fixed: "hello there").map(\.1),
            [.plain, .plain, .deleted, .added])
        let segments = split(InlineDiffBuilder.attributedDiff(original: "hello world", fixed: "hello there", font: font))
        XCTAssertEqual(segments.deleted, "world")
        XCTAssertEqual(segments.added, "there")
    }

    /// Plain and deleted segments must make the original, plain and added
    /// segments the fixed text.
    private func split(_ diff: NSAttributedString)
        -> (original: String, fixed: String, deleted: String, added: String)
    {
        var original = "", fixed = "", deleted = "", added = ""
        diff.enumerateAttributes(in: NSRange(location: 0, length: diff.length)) { attributes, range, _ in
            let token = (diff.string as NSString).substring(with: range)
            if attributes[.strikethroughStyle] != nil {
                original += token
                deleted += token
            } else if attributes[.backgroundColor] != nil {
                fixed += token
                added += token
            } else {
                original += token
                fixed += token
            }
        }
        return (original, fixed, deleted, added)
    }
}

/// The real ⌘C capture, against a private pasteboard, with the posted ⌘C
/// replaced by a simulated app that copies its selection.
@MainActor
final class PasteboardSelectionTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.jonclegg.DogballWhisper.tests.fix"))
        pasteboard.clearContents()
        pasteboard.setString("what the user had copied", forType: .string)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func selection(copies selected: String?, trusted: Bool = true) -> PasteboardSelection {
        let pasteboard = pasteboard!
        return PasteboardSelection(
            inserter: FakeInserter(), pasteboard: pasteboard, isTrusted: { trusted },
            postCopy: {
                guard let selected else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    pasteboard.clearContents()
                    pasteboard.setString(selected, forType: .string)
                }
            })
    }

    func testCapturesTheSelectionAndGivesTheClipboardBack() async throws {
        let target = try await selection(copies: "i has a apple").capture()
        XCTAssertEqual(target.originalText, "i has a apple")
        XCTAssertTrue(target.replacesSelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had copied")
    }

    func testFallsBackToTheClipboardWhenNothingIsSelected() async throws {
        let target = try await selection(copies: nil).capture()
        XCTAssertEqual(target.originalText, "what the user had copied")
        XCTAssertFalse(target.replacesSelection)
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had copied")
    }

    func testNothingSelectedAndAnEmptyClipboardIsAnError() async {
        pasteboard.clearContents()
        do {
            _ = try await selection(copies: nil).capture()
            XCTFail("expected noSelection")
        } catch {
            XCTAssertEqual(error as? FixError, .noSelection)
        }
    }

    func testWithoutAccessibilityNothingIsCopied() async {
        do {
            _ = try await selection(copies: "i has", trusted: false).capture()
            XCTFail("expected accessibilityRequired")
        } catch {
            XCTAssertEqual(error as? FixError, .accessibilityRequired)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had copied")
    }

    func testAPasteTheInserterRefusesIsReported() async {
        let inserter = FakeInserter()
        inserter.outcome = .copiedToClipboard
        let sut = PasteboardSelection(inserter: inserter, pasteboard: pasteboard, isTrusted: { true }, postCopy: {})
        do {
            try await sut.replace(FixTarget(originalText: "a", sourcePID: nil, replacesSelection: true), with: "A")
            XCTFail("expected pasteFailed")
        } catch {
            XCTAssertEqual(error as? FixError, .pasteFailed)
        }
        XCTAssertEqual(inserter.inserted, ["A"])
    }
}
