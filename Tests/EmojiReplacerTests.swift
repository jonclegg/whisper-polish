import UIKit
import XCTest

final class EmojiReplacerTests: XCTestCase {
    /// A text field the replacer's edits are applied to, the way `KeyboardModel` applies them.
    private struct Field {
        var text = ""
        var replacer = EmojiReplacer()
        var allowed = true

        mutating func type(_ characters: String) {
            for character in characters {
                if character == " " || ".,?!".contains(character) {
                    finish(String(character))
                } else {
                    replacer.keyTyped()
                    text.append(character)
                }
            }
        }

        mutating func finish(_ separator: String) {
            replacer.keyTyped()
            let swap = replacer.finish(before: text, allowed: allowed)
            if let swap { text = String(text.dropLast(swap.original.count)) + swap.emoji }
            text += separator
            if let swap { replacer.swapped(swap, separator: separator) }
        }

        mutating func backspace() {
            if let undo = replacer.backspace(before: text) {
                text = String(text.dropLast(undo.delete)) + undo.insert
            } else {
                text = String(text.dropLast())
            }
            replacer.keyTyped()
        }
    }

    func testAFinishedShortcutBecomesItsEmoji() {
        var field = Field()
        field.type("that was great lol ")
        XCTAssertEqual(field.text, "that was great 😂 ")
    }

    func testPunctuationFinishesAShortcutToo() {
        var field = Field()
        field.type("omg!")
        XCTAssertEqual(field.text, "😱!")
        field = Field()
        field.type("thx.")
        XCTAssertEqual(field.text, "🙏.")
    }

    func testAnyCaseCounts() {
        var field = Field()
        field.type("LOL Lol lOl ")
        XCTAssertEqual(field.text, "😂 😂 😂 ")
    }

    func testEmoticonsAreSwappedToo() {
        var field = Field()
        field.type("see you soon :) <3 :D ")
        XCTAssertEqual(field.text, "see you soon 🙂 ❤️ 😄 ")
    }

    func testOneBackspaceRightAfterBringsTheTextBack() {
        var field = Field()
        field.type("lol ")
        field.backspace()
        XCTAssertEqual(field.text, "lol")
        // Finishing it again leaves it as typed.
        field.type(" ok")
        XCTAssertEqual(field.text, "lol ok")
    }

    func testABackspaceAfterAnotherKeyIsAnOrdinaryBackspace() {
        var field = Field()
        field.type("lol a")
        field.backspace()
        field.backspace()
        XCTAssertEqual(field.text, "😂")
    }

    func testOnlyWholeShortcutsAreSwapped() {
        var field = Field()
        field.type("lolly (lol hello:) tyler ")
        XCTAssertEqual(field.text, "lolly (lol hello:) tyler ")
    }

    func testWordsThatAreOnlyOfferedStayWords() {
        var field = Field()
        field.type("I love pizza and 100 ")
        XCTAssertEqual(field.text, "I love pizza and 100 ")
    }

    func testNothingIsSwappedInFieldsThatArentWriting() {
        final class Traits: NSObject, UITextInputTraits {
            var keyboardType: UIKeyboardType = .default
            var autocorrectionType: UITextAutocorrectionType = .default
            var returnKeyType: UIReturnKeyType = .default
            var textContentType: UITextContentType! = nil
        }
        for change in [{ (traits: Traits) in traits.keyboardType = .URL },
                       { $0.keyboardType = .emailAddress },
                       { $0.keyboardType = .webSearch },
                       { $0.returnKeyType = .search },
                       { $0.textContentType = .password },
                       { $0.autocorrectionType = .no }] {
            let traits = Traits()
            change(traits)
            var field = Field()
            field.allowed = WritingField.holdsWriting(traits)
            field.type("lol :) ")
            XCTAssertEqual(field.text, "lol :) ")
        }
        var off = Field()
        off.allowed = false
        off.type("lol ")
        XCTAssertEqual(off.text, "lol ", "The option turned off")
    }

    func testTheBarOffersAWordsEmojiInItsLastSlot() {
        let bar = [Suggestion(text: "love"), Suggestion(text: "lovely"), Suggestion(text: "loved")]
        XCTAssertEqual(
            EmojiReplacer.bar(bar, before: "I love", partialWord: "love", swapsShortcuts: true),
            [Suggestion(text: "love"), Suggestion(text: "lovely"), Suggestion(text: "❤️", replaces: "love")]
        )
    }

    func testTheBarShowsASwappedShortcutAsTheAutocorrection() {
        let bar = [Suggestion(text: "thx", isQuoted: true, learns: true), Suggestion(text: "the", isAutocorrection: true), Suggestion(text: "then")]
        XCTAssertEqual(
            EmojiReplacer.bar(bar, before: "ok thx", partialWord: "thx", swapsShortcuts: true),
            [Suggestion(text: "thx", isQuoted: true, learns: true), Suggestion(text: "🙏", isAutocorrection: true, replaces: "thx"), Suggestion(text: "then")]
        )
        // With swapping off it's only offered, and autocorrect keeps its say.
        XCTAssertEqual(
            EmojiReplacer.bar(bar, before: "ok thx", partialWord: "thx", swapsShortcuts: false),
            [Suggestion(text: "thx", isQuoted: true, learns: true), Suggestion(text: "the", isAutocorrection: true), Suggestion(text: "🙏", replaces: "thx")]
        )
    }

    func testTheBarOffersEmojiForPhrasesNumbersAndEmoticons() {
        let predictions = [Suggestion(text: "to"), Suggestion(text: "for"), Suggestion(text: "and")]
        XCTAssertEqual(EmojiReplacer.bar(predictions, before: "thumbs up", partialWord: "up", swapsShortcuts: true).last, Suggestion(text: "👍", replaces: "thumbs up"))
        XCTAssertEqual(EmojiReplacer.bar(predictions, before: "that's 100", partialWord: "", swapsShortcuts: true).last, Suggestion(text: "💯", replaces: "100"))
        XCTAssertEqual(EmojiReplacer.bar(predictions, before: "nice :)", partialWord: "", swapsShortcuts: true).first, Suggestion(text: "🙂", isAutocorrection: true, replaces: ":)"))
        XCTAssertEqual(EmojiReplacer.bar(predictions, before: "nice ", partialWord: "", swapsShortcuts: true), predictions)
    }
}
