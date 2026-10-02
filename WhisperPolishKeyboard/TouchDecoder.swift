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
    static let editPenalty = 7.0
    /// Bonus for words that often follow the previous words.
    static let contextBonus = 2.0
    private static let unknownRank = 60_000

    let lexicon: Lexicon
    var geometry: KeyGeometry = .letters

    /// `touches[i]` is where the i-th letter of `typed` was touched, or nil to
    /// assume the key's center. `guesses` (from the spell checker) cover
    /// added or missing letters, which key-by-key matching can't.
    func candidates(
        typed: String,
        touches: [CGPoint?],
        likelyWords: [String],
        guesses: [String] = [],
        limit: Int = 3
    ) -> [Candidate] {
        let typed = typed.lowercased()
        guard touches.count == typed.count else { return [] }
        var observed: [CGPoint] = []
        for (letter, touch) in zip(typed, touches) {
            guard let point = touch ?? geometry.centers[letter] else { return [] }
            observed.append(point)
        }
        let likely = Set(likelyWords.map { $0.lowercased() })
        let literal = spatialScore(typed, observed) ?? 0

        var best: [String: Double] = [:]
        for (word, rank) in lexicon.words(ofLength: typed.count) where word != typed {
            guard let spatial = spatialScore(word, observed) else { continue }
            best[word] = spatial + prior(word, rank: rank, likely: likely)
        }
        for guess in guesses {
            let word = guess.lowercased()
            guard word != typed, !word.contains(" ") else { continue }
            let shifted = literal - Self.editPenalty
            let spatial = word.count == typed.count ? max(spatialScore(word, observed) ?? shifted, shifted) : shifted
            let score = spatial + prior(word, rank: lexicon.rank(of: word) ?? Self.unknownRank, likely: likely)
            best[word] = max(best[word] ?? -.infinity, score)
        }
        return best
            .map { Candidate(word: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
    }

    private func spatialScore(_ word: String, _ points: [CGPoint]) -> Double? {
        var total = 0.0
        for (letter, point) in zip(word, points) {
            guard let center = geometry.centers[letter] else { return nil }
            let score = TouchModel.logLikelihood(of: point, aimingAt: center)
            if score < TouchModel.farthest { return nil }
            total += score
        }
        return total
    }

    private func prior(_ word: String, rank: Int, likely: Set<String>) -> Double {
        log(Lexicon.weight(rank: rank)) + (likely.contains(word) ? Self.contextBonus : 0)
    }
}
