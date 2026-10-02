import Foundation

/// Letter key centers in key units (x in key widths, y in rows), laid out the
/// same way `KeyGridView` lays out the letters keyboard.
struct KeyGeometry: Sendable {
    let centers: [Character: CGPoint]

    static let letters: KeyGeometry = {
        var centers: [Character: CGPoint] = [:]
        let rows = KeyboardLayout.letters.rows(bottomRow: .standard, showsNextKeyboard: false)
        for (index, row) in rows.enumerated() {
            var x = (KeySpec.rowUnits - row.reduce(0) { $0 + $1.units }) / 2
            for spec in row {
                if case .character(let text) = spec.key, text.count == 1, let letter = text.first, letter.isLetter {
                    centers[letter] = CGPoint(x: x + spec.units / 2, y: CGFloat(index) + 0.5)
                }
                x += spec.units
            }
        }
        return KeyGeometry(centers: centers)
    }()
}

/// Where fingers land around the key they aim for: a 2D Gaussian whose spread
/// is a fraction of a key, so a near miss still says a lot about the intended key.
enum TouchModel {
    static let spreadX: CGFloat = 0.35
    static let spreadY: CGFloat = 0.3
    /// Touches this unlikely for a key rule it out.
    static let farthest = -12.0

    static func logLikelihood(of point: CGPoint, aimingAt center: CGPoint) -> Double {
        let dx = (point.x - center.x) / spreadX
        let dy = (point.y - center.y) / spreadY
        return -Double(dx * dx + dy * dy) / 2
    }
}

/// Picks the key a touch meant, like the system keyboard's invisible key
/// resizing: near a key's edge, the letter that more likely comes next wins.
enum KeyResolver {
    /// Touches this close to a key's center (in key units, per axis) always type that key.
    static let core: CGFloat = 0.25
    /// Keeps letters no known word continues with typable when touched squarely.
    static let oddsFloor = 0.002
    /// Below 1 so where the finger landed counts for more than what the word predicts.
    static let oddsWeight = 0.75

    static func resolve(
        _ point: CGPoint,
        nearest: Character,
        odds: [Character: Double],
        geometry: KeyGeometry = .letters
    ) -> Character {
        guard !odds.isEmpty, let center = geometry.centers[nearest],
              abs(point.x - center.x) >= core || abs(point.y - center.y) >= core else { return nearest }
        func score(_ letter: Character, _ center: CGPoint) -> Double {
            TouchModel.logLikelihood(of: point, aimingAt: center) + oddsWeight * log(odds[letter, default: 0] + oddsFloor)
        }
        var best = nearest
        var bestScore = score(nearest, center)
        for (letter, center) in geometry.centers where letter != nearest {
            guard abs(point.x - center.x) < 1.2, abs(point.y - center.y) < 1.2 else { continue }
            let candidate = score(letter, center)
            if candidate > bestScore {
                best = letter
                bestScore = candidate
            }
        }
        return best
    }
}

/// Finds the words a sequence of touches most likely spelled, scoring each
/// word by how close its keys are to the touches plus how common it is.
struct WordDecoder {
    struct Candidate: Equatable {
        let word: String
        let score: Double
    }

    /// Cost of a guess that adds, drops, or swaps a letter instead of mistyping one.
    static let editPenalty = 6.0
    /// How much less likely than the keys actually hit a word may be, about two
    /// slips onto neighboring keys; beyond that the word is a rewrite, not a fix.
    static let maxTouchLoss = 9.0
    /// Two words run together count only when both are this common.
    private static let maxSplitRank = 5_000
    /// Bonus for words that often follow the previous words.
    static let contextBonus = 2.0
    private static let unknownRank = 60_000

    private static let a = UInt8(ascii: "a")

    let lexicon: Lexicon
    /// Key centers indexed by letter, a = 0.
    private let centers: [CGPoint]

    init(lexicon: Lexicon, geometry: KeyGeometry = .letters) {
        self.lexicon = lexicon
        centers = (0..<26).map { offset in
            geometry.centers[Character(Unicode.Scalar(Self.a + UInt8(offset)))] ?? CGPoint(x: -100, y: -100)
        }
    }

    /// `touches[i]` is where the i-th letter of `typed` was touched, or nil to
    /// assume the key's center. Words one added, dropped, or swapped letter
    /// away are considered too, since key-by-key matching can't find those.
    /// Runs on every keystroke, so it works on bytes rather than Strings.
    func candidates(typed: String, touches: [CGPoint?], likelyWords: [String], limit: Int = 3) -> [Candidate] {
        let letters = Array(typed.lowercased().utf8)
        guard touches.count == letters.count, !letters.isEmpty,
              letters.allSatisfy({ $0 >= Self.a && $0 < Self.a + 26 }) else { return [] }
        let observed = zip(letters, touches).map { letter, touch in touch ?? centers[Int(letter - Self.a)] }
        let likely = Set(likelyWords.map { $0.lowercased() })
        let literal = spatialScore(letters, observed) ?? 0

        var best: [[UInt8]: Double] = [:]
        let sameLength = lexicon.words(ofLength: letters.count)
        for (word, rank) in zip(sameLength.words, sameLength.ranks) where word != letters {
            guard let spatial = spatialScore(word, observed), spatial >= literal - Self.maxTouchLoss else { continue }
            best[word] = spatial + prior(word, rank: rank, likely: likely)
        }
        let shifted = literal - Self.editPenalty
        for word in Self.edits(of: letters) where word != letters && Self.isWordLength(word) {
            guard let rank = lexicon.rank(ofLowercased: word) else { continue }
            let spatial = word.count == letters.count ? max(spatialScore(word, observed) ?? shifted, shifted) : shifted
            best[word] = max(best[word] ?? -.infinity, spatial + prior(word, rank: rank, likely: likely))
        }
        // A missed space bar: "letme" is "let me".
        for split in 1..<letters.count {
            let first = Array(letters[..<split])
            let second = Array(letters[split...])
            guard Self.isWordLength(first), Self.isWordLength(second),
                  let firstRank = lexicon.rank(ofLowercased: first), firstRank < Self.maxSplitRank,
                  let secondRank = lexicon.rank(ofLowercased: second), secondRank < Self.maxSplitRank else { continue }
            let phrase = first + [UInt8(ascii: " ")] + second
            best[phrase] = shifted + log(Lexicon.weight(rank: max(firstRank, secondRank)))
        }
        return best
            .map { Candidate(word: String(decoding: $0.key, as: UTF8.self), score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
    }

    /// The word list has every letter as a "word"; only "a" and "i" really are.
    private static func isWordLength(_ word: [UInt8]) -> Bool {
        word.count > 1 || word == [UInt8(ascii: "a")] || word == [UInt8(ascii: "i")]
    }

    /// Words one inserted, deleted, or swapped neighboring letter away.
    private static func edits(of letters: [UInt8]) -> [[UInt8]] {
        var edits: [[UInt8]] = []
        edits.reserveCapacity(27 * (letters.count + 1))
        for index in letters.indices {
            var deleted = letters
            deleted.remove(at: index)
            if !deleted.isEmpty { edits.append(deleted) }
            if index + 1 < letters.count {
                var swapped = letters
                swapped.swapAt(index, index + 1)
                edits.append(swapped)
            }
        }
        for index in 0...letters.count {
            for offset in 0..<26 {
                var inserted = letters
                inserted.insert(a + UInt8(offset), at: index)
                edits.append(inserted)
            }
        }
        return edits
    }

    private func spatialScore(_ word: [UInt8], _ points: [CGPoint]) -> Double? {
        var total = 0.0
        for index in word.indices {
            let score = TouchModel.logLikelihood(of: points[index], aimingAt: centers[Int(word[index] &- Self.a)])
            if score < TouchModel.farthest { return nil }
            total += score
        }
        return total
    }

    private func prior(_ word: [UInt8], rank: Int, likely: Set<String>) -> Double {
        let bonus = likely.isEmpty || !likely.contains(String(decoding: word, as: UTF8.self)) ? 0 : Self.contextBonus
        return log(Lexicon.weight(rank: rank)) + bonus
    }
}
