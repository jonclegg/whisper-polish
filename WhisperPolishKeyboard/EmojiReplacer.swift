import Foundation

/// Swaps finished shortcuts from `EmojiShortcuts` for their emoji ("lol " becomes
/// "😂 "), and offers emoji for words on the bar. A backspace right after a swap
/// brings back what was typed, and finishing it again then leaves it alone.
struct EmojiReplacer {
    /// A shortcut and the emoji that replaced it.
    struct Swap: Equatable {
        let original: String
        let emoji: String
    }

    /// An emoji for the bar: the text it replaces and whether finishing that text swaps it in anyway.
    struct Offer: Equatable {
        let emoji: String
        let replaces: String
        let swaps: Bool
    }

    /// The last swap and what finished it, until the next key.
    private var lastSwap: (swap: Swap, separator: String)?
    /// A shortcut a backspace put back, left alone the next time it's finished.
    private var putBack: String?

    /// The shortcut `before` (the text before the cursor) ends with, if finishing it swaps it.
    static func shortcut(endingWith before: String) -> Swap? {
        let token = lastToken(of: before)
        return EmojiShortcuts.swapped[token.lowercased()].map { Swap(original: token, emoji: $0) }
    }

    /// The emoji the bar offers for what `before` ends with, if any.
    static func offer(endingWith before: String) -> Offer? {
        if let swap = shortcut(endingWith: before) { return Offer(emoji: swap.emoji, replaces: swap.original, swaps: true) }
        let token = lastToken(of: before)
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        // Phrases first, so "thumbs up" isn't offered as "up".
        let head = before.dropLast(token.count)
        if head.hasSuffix(" ") {
            let earlier = lastToken(of: String(head.dropLast()))
            let phrase = earlier + " " + token
            if !earlier.isEmpty, let emoji = EmojiShortcuts.offered[phrase.lowercased()] {
                return Offer(emoji: emoji, replaces: phrase, swaps: false)
            }
        }
        return EmojiShortcuts.offered[token.lowercased()].map { Offer(emoji: $0, replaces: token, swaps: false) }
    }

    /// The bar with an emoji for what `before` ends with. One that finishing swaps in shows as
    /// the autocorrection, in place of the predictor's; one that's only offered takes the last slot,
    /// so the bar keeps its best completions. `partialWord` is the word being typed, which the bar starts with.
    static func bar(_ suggestions: [Suggestion], before: String, partialWord: String, swapsShortcuts: Bool) -> [Suggestion] {
        guard let offer = offer(endingWith: before) else { return suggestions }
        let swaps = offer.swaps && swapsShortcuts
        var bar = suggestions.filter { !(swaps && $0.isAutocorrection) && $0.text != offer.emoji }
        let emoji = Suggestion(text: offer.emoji, isAutocorrection: swaps, replaces: offer.replaces)
        if swaps {
            bar.insert(emoji, at: partialWord.isEmpty ? 0 : min(1, bar.count))
        } else if bar.count >= 3 {
            bar[2] = emoji
        } else {
            bar.append(emoji)
        }
        return Array(bar.prefix(3))
    }

    /// Called as the word before the cursor is finished, before the space or punctuation
    /// goes in: the swap to make, if it ends with a shortcut and `allowed` (the option is on
    /// and the field holds writing).
    mutating func finish(before: String, allowed: Bool) -> Swap? {
        guard allowed, let swap = Self.shortcut(endingWith: before) else {
            putBack = nil
            return nil
        }
        guard putBack != swap.original else {
            putBack = nil
            return nil
        }
        putBack = nil
        return swap
    }

    /// Call once the swap and the `separator` that finished it are in.
    mutating func swapped(_ swap: Swap, separator: String) {
        lastSwap = (swap, separator)
    }

    /// The edit a backspace makes instead of deleting one character, right after a swap:
    /// how many characters to delete before the cursor, and the text to put back.
    mutating func backspace(before: String) -> (delete: Int, insert: String)? {
        defer { lastSwap = nil }
        guard let (swap, separator) = lastSwap, before.hasSuffix(swap.emoji + separator) else { return nil }
        putBack = swap.original
        return (swap.emoji.count + separator.count, swap.original)
    }

    /// Any other key, or a change the keyboard didn't make, ends the chance to undo.
    mutating func keyTyped() {
        lastSwap = nil
    }

    private static func lastToken(of text: String) -> String {
        String(text.reversed().prefix { !$0.isWhitespace }.reversed())
    }
}
