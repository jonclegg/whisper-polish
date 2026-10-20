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
/// The lexicon's words sit in a trie, so words sharing a start share the work of
/// matching it, and a branch is dropped once nothing down it could match.
struct WordDecoder: Sendable {
    struct Candidate: Equatable {
        let word: String
        let score: Double
    }

    /// Words that start with a near miss of what's typed, like "restau" for "resyau":
    /// `words` indexes `wordIds`, and `loss` is what reading the touches as that start costs.
    struct Prefix: Equatable {
        let words: Range<Int>
        let loss: Double
    }

    /// Tuned with `TypingSimulationTests`, which types real messages with simulated sloppy taps.
    struct Settings: Sendable {
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
        /// Starts of words this close to the touches offer their completions, about one slip.
        var maxPrefixLoss = 6.0
        /// Fewer letters than this say too little to complete a near miss of them.
        var nearMissLetters = 3
        /// A near miss's completion goes ahead of one of exactly what's typed only when it scores this much better.
        var nearMissMargin = 2.0
    }

    /// Two words run together count only when both are this common.
    private static let maxSplitRank = 5_000
    private static let a = UInt8(ascii: "a")

    let lexicon: Lexicon
    var settings: Settings
    /// Key centers indexed by letter, a = 0.
    private let centers: [CGPoint]
    /// The trie in preorder from the root, node 0: each node's descendants run up to
    /// `subtreeEnd`, `letter` leads into it, and its words, in sorted order, run from
    /// `firstWord` to the next subtree's. A node ends a word when its first word is as long as it is deep.
    private let letter: [UInt8]
    private let subtreeEnd: [Int32]
    private let firstWord: [Int32]
    private let endsWord: [Bool]
    /// The trie's words as bytes, sorted.
    private let words: [[UInt8]]
    /// The next-word odds id of each of `words`, -1 for none.
    let wordIds: [Int]

    /// `oddsIds` finds a word's place in the next-word odds passed to `candidates`. Every
    /// lexicon word is a word model word, so the ids never change once the two are loaded.
    /// Building the trie takes a moment, so it's built once per process.
    init(lexicon: Lexicon, oddsIds: [String: Int], settings: Settings = Settings(), geometry: KeyGeometry = .letters) {
        self.lexicon = lexicon
        self.settings = settings
        centers = (0..<26).map { offset in
            geometry.centers[Character(Unicode.Scalar(Self.a + UInt8(offset)))] ?? CGPoint(x: -100, y: -100)
        }
        var words: [[UInt8]] = []
        for length in 1...32 {
            let bucket = lexicon.words(ofLength: length)
            for (word, rank) in zip(bucket.words, bucket.ranks) where Lexicon.isWord(word, rank: rank) { words.append(word) }
        }
        words.sort { $0.lexicographicallyPrecedes($1) }
        var letter: [UInt8] = []
        var subtreeEnd: [Int32] = []
        var firstWord: [Int32] = []
        var endsWord: [Bool] = []
        func build(_ range: Range<Int>, depth: Int) {
            let node = letter.count
            letter.append(depth == 0 ? 0 : words[range.lowerBound][depth - 1])
            subtreeEnd.append(0)
            firstWord.append(Int32(range.lowerBound))
            // Sorted, so a word that is this node's whole prefix comes first.
            let isWord = words[range.lowerBound].count == depth
            endsWord.append(isWord)
            var start = range.lowerBound + (isWord ? 1 : 0)
            while start < range.upperBound {
                let next = words[start][depth]
                var end = start + 1
                while end < range.upperBound, words[end][depth] == next { end += 1 }
                build(start..<end, depth: depth + 1)
                start = end
            }
            subtreeEnd[node] = Int32(letter.count)
        }
        build(0..<words.count, depth: 0)
        firstWord.append(Int32(words.count))
        self.letter = letter
        self.subtreeEnd = subtreeEnd
        self.firstWord = firstWord
        self.endsWord = endsWord
        self.words = words
        wordIds = words.map { oddsIds[String(decoding: $0, as: UTF8.self)] ?? -1 }
    }

    /// How well the touches fit the letters exactly as typed.
    func spatialScore(typed: String, touches: [CGPoint?]) -> Double? {
        let letters = Array(typed.lowercased().utf8)
        guard touches.count == letters.count, letters.allSatisfy({ $0 >= Self.a && $0 < Self.a + 26 }) else { return nil }
        return spatialScore(letters, zip(letters, touches).map { letter, touch in touch ?? centers[Int(letter - Self.a)] })
    }

    /// How well the touches and the context fit the word exactly as typed, on the candidates' scale.
    func literalScore(typed: String, touches: [CGPoint?], oddsId: Int?, odds: [Float]) -> Double? {
        guard let spatial = spatialScore(typed: typed, touches: touches) else { return nil }
        return spatial + prior(oddsId, odds: odds)
    }

    /// The scale candidates and completions share for how likely a word is to come next.
    func prior(_ id: Int?, odds: [Float]) -> Double {
        settings.oddsWeight * log(Double(id.map { odds[$0] } ?? 0) + 1e-7)
    }

    /// `touches[i]` is where the i-th letter of `typed` was touched, or nil to
    /// assume the key's center; `odds` are the next-word odds. Words up to two
    /// added, dropped, or swapped letters away are considered too, since
    /// key-by-key matching can't find those. Runs on every keystroke, so it
    /// works on bytes rather than Strings.
    func candidates(typed: String, touches: [CGPoint?], odds: [Float], limit: Int = 3) -> [Candidate] {
        decode(typed: typed, touches: touches, odds: odds, limit: limit).candidates
    }

    /// The candidates, and the starts of words that are a near miss of what's typed
    /// (not what's typed itself), whose completions may be what was meant.
    func decode(typed: String, touches: [CGPoint?], odds: [Float], limit: Int = 3) -> (candidates: [Candidate], prefixes: [Prefix]) {
        let letters = Array(typed.lowercased().utf8)
        guard touches.count == letters.count, !letters.isEmpty,
              letters.allSatisfy({ $0 >= Self.a && $0 < Self.a + 26 }) else { return ([], []) }
        let observed = zip(letters, touches).map { letter, touch in touch ?? centers[Int(letter - Self.a)] }
        let literal = spatialScore(letters, observed) ?? 0

        var search = Search(decoder: self, letters: letters, observed: observed, odds: odds, literal: literal)
        search.run()
        var best = search.found
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
        let candidates = best
            .map { Candidate(word: String(decoding: $0.key, as: UTF8.self), score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
        return (candidates, search.prefixes)
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

    /// One walk of the trie for one set of touches. It's an edit distance that knows a
    /// near miss on a neighboring key is cheap and a key across the keyboard isn't: a
    /// touch read as a key other than the one typed costs what the touch model says that
    /// key loses, and each added, dropped, or swapped letter costs a penalty. Each trie
    /// node adds one row of distances below its parent's, for the word start it spells.
    private struct Search {
        let decoder: WordDecoder
        let letters: [UInt8]
        let odds: [Float]
        let literal: Double
        let maxLoss: Double
        let lengths: ClosedRange<Int>
        let prefixDepths: Range<Int>
        /// `costs[touch * 26 + letter]`, infinite for keys too far from the touch. A touch
        /// can fit another key better than the one it typed, so a cost can be below zero.
        private let costs: [Double]
        /// The least the touches from each one on can still add, for dropping only branches
        /// that can't come back under the limit.
        private let leastToCome: [Double]
        /// Distance rows by depth, `width` apiece: `rows[depth * width + touches]`.
        private var rows: [Double]
        private var rowBest: [Double]
        private let width: Int
        /// The letters of the word start being walked.
        private var path: [UInt8]
        private(set) var found: [[UInt8]: Double] = [:]
        private(set) var prefixes: [Prefix] = []

        init(decoder: WordDecoder, letters: [UInt8], observed: [CGPoint], odds: [Float], literal: Double) {
            self.decoder = decoder
            self.letters = letters
            self.odds = odds
            self.literal = literal
            let settings = decoder.settings
            maxLoss = letters.count >= 3 ? settings.maxEditLoss : settings.maxShortWordLoss
            let maxEdits = Int(maxLoss / settings.editPenalty)
            lengths = max(1, letters.count - maxEdits)...(letters.count + maxEdits)
            prefixDepths = letters.count >= settings.nearMissLetters ? (letters.count - 1)..<(letters.count + 2) : 0..<0
            var costs = [Double](repeating: .infinity, count: letters.count * 26)
            for (touch, point) in observed.enumerated() {
                let typed = TouchModel.logLikelihood(of: point, aimingAt: decoder.centers[Int(letters[touch] - WordDecoder.a)])
                for letter in 0..<26 {
                    let likelihood = TouchModel.logLikelihood(of: point, aimingAt: decoder.centers[letter])
                    if likelihood >= TouchModel.farthest { costs[touch * 26 + letter] = typed - likelihood }
                }
                costs[touch * 26 + Int(letters[touch] - WordDecoder.a)] = 0
            }
            self.costs = costs
            var leastToCome = [Double](repeating: 0, count: letters.count + 1)
            for touch in letters.indices.reversed() {
                leastToCome[touch] = leastToCome[touch + 1] + min(0, costs[(touch * 26)..<((touch + 1) * 26)].min()!)
            }
            self.leastToCome = leastToCome
            width = letters.count + 1
            let depths = lengths.upperBound + 1
            rows = [Double](repeating: 0, count: depths * width)
            rowBest = [Double](repeating: 0, count: depths)
            path = [UInt8](repeating: 0, count: depths)
            for touches in 0..<width { rows[touches] = Double(touches) * settings.editPenalty }
        }

        mutating func run() {
            var child = 1
            while child < Int(decoder.subtreeEnd[0]) {
                visit(child, depth: 1, startAllowed: true)
                child = Int(decoder.subtreeEnd[child])
            }
        }

        /// `startAllowed` is false below a first letter that's only allowed for words
        /// whose second letter was typed first. Words must start near the first touch,
        /// unless its letter was doubled, swapped, or missed; checking the rest of the
        /// word list would be too slow.
        private mutating func visit(_ node: Int, depth: Int, startAllowed: Bool) {
            let settings = decoder.settings
            let edit = settings.editPenalty
            let wordLetter = decoder.letter[node]
            path[depth - 1] = wordLetter
            var startAllowed = startAllowed
            if depth == 1 {
                startAllowed = cost(0, wordLetter).isFinite || (letters.count > 1 && wordLetter == letters[1])
            } else if depth == 2, !startAllowed {
                guard wordLetter == letters[0] else { return }
                startAllowed = true
            }
            let row = depth * width
            let above = row - width
            rows[row] = Double(depth) * edit
            var best = rows[row] + leastToCome[0]
            for touch in 1..<width {
                var value = min(rows[above + touch], rows[row + touch - 1]) + edit
                value = min(value, rows[above + touch - 1] + cost(touch - 1, wordLetter))
                if touch > 1, depth > 1, letters[touch - 1] == path[depth - 2], letters[touch - 2] == wordLetter {
                    value = min(value, rows[above - width + touch - 2] + settings.swapPenalty)
                }
                rows[row + touch] = value
                best = min(best, value + leastToCome[touch])
            }
            rowBest[depth] = best
            let loss = rows[row + width - 1]
            if startAllowed {
                if decoder.endsWord[node], lengths.contains(depth), loss <= maxLoss, depth != letters.count || !path[..<depth].elementsEqual(letters) {
                    let index = Int(decoder.firstWord[node])
                    let id = decoder.wordIds[index]
                    found[decoder.words[index]] = literal - loss + decoder.prior(id >= 0 ? id : nil, odds: odds)
                }
                if prefixDepths.contains(depth), loss <= settings.maxPrefixLoss, depth != letters.count || !path[..<depth].elementsEqual(letters) {
                    prefixes.append(Prefix(words: Int(decoder.firstWord[node])..<Int(decoder.firstWord[Int(decoder.subtreeEnd[node])]), loss: loss))
                }
            }
            // A swap reaches back two rows, so both have to be out of reach, whatever the touches still to come add.
            guard depth < lengths.upperBound, best <= maxLoss || rowBest[depth - 1] <= maxLoss else { return }
            var child = node + 1
            while child < Int(decoder.subtreeEnd[node]) {
                visit(child, depth: depth + 1, startAllowed: startAllowed)
                child = Int(decoder.subtreeEnd[child])
            }
        }

        private func cost(_ touch: Int, _ letter: UInt8) -> Double {
            costs[touch * 26 + Int(letter &- WordDecoder.a)]
        }
    }
}
