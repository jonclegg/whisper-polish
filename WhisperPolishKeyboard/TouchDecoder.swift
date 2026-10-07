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
/// word by how close its keys are to the touches plus how likely it is to come next.
struct WordDecoder {
    struct Candidate: Equatable {
        let word: String
        let score: Double
    }

    /// Tuned with `TypingSimulationTests`, which types real messages with simulated sloppy taps.
    struct Settings {
        /// Cost of a guess that adds or drops a letter instead of mistyping one.
        var editPenalty = 6.0
        /// Cost of two letters typed in the wrong order, the usual slip when two thumbs roll.
        var swapPenalty = 4.0
        /// Words further than this from the touches, about two slips plus some
        /// stray touch, are rewrites rather than fixes.
        var maxEditLoss = 13.0
        /// Two-letter words get one slip, or every word would be a fix for them.
        var maxShortWordLoss = 7.0
        /// How much the next-word odds count against where the finger landed.
        var oddsWeight = 1.0
        /// A real word that was typed is replaced only by one that beats it by this much.
        var realWordMargin = 4.0
        /// A word typed without its apostrophe gets it back when that's this many times likelier.
        var apostropheOddsRatio: Float = 2
        /// Words only the spell checker knows ("inly") get these log odds, so they can be fixed like slips.
        var spellCheckedLogOdds = -14.0
    }

    /// Two words run together count only when both are this common.
    private static let maxSplitRank = 5_000
    private static let a = UInt8(ascii: "a")

    let lexicon: Lexicon
    let settings: Settings
    /// Key centers indexed by letter, a = 0.
    private let centers: [CGPoint]
    /// Each length bucket's words as next-word odds ids, -1 for none.
    private let oddsIds: [Int: [Int]]
    private let oddsId: (String) -> Int?

    /// `oddsId` finds a word's place in the next-word odds passed to `candidates`.
    init(lexicon: Lexicon, settings: Settings = Settings(), geometry: KeyGeometry = .letters, oddsId: @escaping (String) -> Int?) {
        self.lexicon = lexicon
        self.settings = settings
        centers = (0..<26).map { offset in
            geometry.centers[Character(Unicode.Scalar(Self.a + UInt8(offset)))] ?? CGPoint(x: -100, y: -100)
        }
        var oddsIds: [Int: [Int]] = [:]
        for length in 1...32 {
            let words = lexicon.words(ofLength: length).words
            if !words.isEmpty { oddsIds[length] = words.map { oddsId(String(decoding: $0, as: UTF8.self)) ?? -1 } }
        }
        self.oddsIds = oddsIds
        self.oddsId = oddsId
    }

    /// How well the touches fit the letters exactly as typed.
    func spatialScore(typed: String, touches: [CGPoint?]) -> Double? {
        let letters = Array(typed.lowercased().utf8)
        guard touches.count == letters.count, letters.allSatisfy({ $0 >= Self.a && $0 < Self.a + 26 }) else { return nil }
        return spatialScore(letters, zip(letters, touches).map { letter, touch in touch ?? centers[Int(letter - Self.a)] })
    }

    /// How well the touches and the context fit the word exactly as typed, on the candidates' scale.
    func literalScore(typed: String, touches: [CGPoint?], odds: [Float]) -> Double? {
        guard let spatial = spatialScore(typed: typed, touches: touches) else { return nil }
        return spatial + prior(oddsId(typed.lowercased()), odds: odds)
    }

    /// `touches[i]` is where the i-th letter of `typed` was touched, or nil to
    /// assume the key's center; `odds` are the next-word odds. Words up to two
    /// added, dropped, or swapped letters away are considered too, since
    /// key-by-key matching can't find those. Runs on every keystroke, so it
    /// works on bytes rather than Strings.
    func candidates(typed: String, touches: [CGPoint?], odds: [Float], limit: Int = 3) -> [Candidate] {
        let letters = Array(typed.lowercased().utf8)
        guard touches.count == letters.count, !letters.isEmpty,
              letters.allSatisfy({ $0 >= Self.a && $0 < Self.a + 26 }) else { return [] }
        let observed = zip(letters, touches).map { letter, touch in touch ?? centers[Int(letter - Self.a)] }
        let literal = spatialScore(letters, observed) ?? 0

        var best: [[UInt8]: Double] = [:]
        var slips = Slips(letters: letters, observed: observed, centers: centers, settings: settings)
        let maxLoss = letters.count >= 3 ? settings.maxEditLoss : settings.maxShortWordLoss
        let maxEdits = Int(maxLoss / settings.editPenalty)
        for length in max(1, letters.count - maxEdits)...(letters.count + maxEdits) {
            let bucket = lexicon.words(ofLength: length)
            let ids = oddsIds[length] ?? []
            for (index, (word, rank)) in zip(bucket.words, bucket.ranks).enumerated() where word != letters && Lexicon.isWord(word, rank: rank) {
                guard slips.mayStart(word), let loss = slips.loss(to: word, limit: maxLoss) else { continue }
                best[word] = literal - loss + prior(ids[index] >= 0 ? ids[index] : nil, odds: odds)
            }
        }
        let shifted = literal - settings.editPenalty
        // A missed space bar: "letme" is "let me".
        for split in 1..<letters.count {
            let first = Array(letters[..<split])
            let second = Array(letters[split...])
            guard let firstRank = lexicon.rank(ofLowercased: first), firstRank < Self.maxSplitRank, Lexicon.isWord(first, rank: firstRank),
                  let secondRank = lexicon.rank(ofLowercased: second), secondRank < Self.maxSplitRank, Lexicon.isWord(second, rank: secondRank)
            else { continue }
            let phrase = first + [UInt8(ascii: " ")] + second
            best[phrase] = shifted + log(Lexicon.weight(rank: max(firstRank, secondRank)))
        }
        return best
            .map { Candidate(word: String(decoding: $0.key, as: UTF8.self), score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
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

    private func prior(_ id: Int?, odds: [Float]) -> Double {
        settings.oddsWeight * log(Double(id.map { odds[$0] } ?? 0) + 1e-7)
    }
}

/// How far a word is from what was typed: a touch read as a key other than the
/// one typed costs what the touch model says that key loses, and each added,
/// dropped, or swapped letter costs a penalty. It's an edit distance that knows
/// a near miss on a neighboring key is cheap and a key across the keyboard isn't.
private struct Slips {
    private static let a = UInt8(ascii: "a")

    let letters: [UInt8]
    let settings: WordDecoder.Settings
    /// `costs[touch * 26 + letter]`, infinite for keys too far from the touch.
    private let costs: [Double]
    /// Distance rows, reused across words because this runs for thousands of words per keystroke.
    private var earlier: [Double] = []
    private var previous: [Double] = []
    private var current: [Double] = []

    init(letters: [UInt8], observed: [CGPoint], centers: [CGPoint], settings: WordDecoder.Settings) {
        self.letters = letters
        self.settings = settings
        var costs = [Double](repeating: .infinity, count: letters.count * 26)
        for (touch, point) in observed.enumerated() {
            let typed = TouchModel.logLikelihood(of: point, aimingAt: centers[Int(letters[touch] - Self.a)])
            for letter in 0..<26 {
                let likelihood = TouchModel.logLikelihood(of: point, aimingAt: centers[letter])
                if likelihood >= TouchModel.farthest { costs[touch * 26 + letter] = typed - likelihood }
            }
            costs[touch * 26 + Int(letters[touch] - Self.a)] = 0
        }
        self.costs = costs
    }

    private func cost(_ touch: Int, _ letter: UInt8) -> Double {
        costs[touch * 26 + Int(letter &- Self.a)]
    }

    /// Words must start near the first touch, unless its letter was doubled,
    /// swapped, or missed; checking the rest of the word list would be too slow.
    func mayStart(_ word: [UInt8]) -> Bool {
        cost(0, word[0]).isFinite
            || (letters.count > 1 && word[0] == letters[1])
            || (word.count > 1 && word[1] == letters[0])
    }

    /// The cheapest way the touches could have been meant as `word`, or nil past `limit`.
    mutating func loss(to word: [UInt8], limit: Double) -> Double? {
        let edit = settings.editPenalty
        let width = word.count + 1
        if current.count < width {
            earlier = Array(repeating: 0, count: width)
            previous = earlier
            current = earlier
        }
        for column in 0..<width { previous[column] = Double(column) * edit }
        var previousBest = 0.0
        for touch in 1...letters.count {
            current[0] = Double(touch) * edit
            var rowBest = current[0]
            for column in 1..<width {
                var value = min(previous[column], current[column - 1]) + edit
                value = min(value, previous[column - 1] + cost(touch - 1, word[column - 1]))
                if touch > 1, column > 1, letters[touch - 1] == word[column - 2], letters[touch - 2] == word[column - 1] {
                    value = min(value, earlier[column - 2] + settings.swapPenalty)
                }
                current[column] = value
                rowBest = min(rowBest, value)
            }
            // A swap reaches back two rows, so both have to be out of reach.
            if rowBest > limit, previousBest > limit { return nil }
            previousBest = rowBest
            swap(&earlier, &previous)
            swap(&previous, &current)
        }
        let loss = previous[width - 1]
        return loss <= limit ? loss : nil
    }
}
