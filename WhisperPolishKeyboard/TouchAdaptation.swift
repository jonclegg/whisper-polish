import Foundation

/// Where this user's touches land around each letter key, learned on the phone
/// from words they kept. Thumbs miss consistently, a little right of a key here
/// and low there, so key resolution and autocorrect aim at where the user
/// actually taps rather than at the key's drawn center.
struct TouchAdaptation: Codable, Equatable {
    /// How far a learned center can drift from the drawn one, in key widths and rows.
    static let maxOffset: CGFloat = 0.3
    /// Each touch moves its key's center this share of the way, once the key has a few touches.
    static let rate: CGFloat = 0.03
    /// Touches farther than this from the key's learned center are other slips, not a habit.
    static let farthest: CGFloat = 0.8

    /// Learned offsets from each letter's drawn center, a = 0.
    private var dx = [CGFloat](repeating: 0, count: 26)
    private var dy = [CGFloat](repeating: 0, count: 26)
    private var touches = [Int](repeating: 0, count: 26)

    /// Learns from a word the user kept, typed with `points[i]` for its i-th letter (nil where unknown).
    mutating func learn(_ word: String, points: [CGPoint?], drawn: KeyGeometry = .letters) {
        let letters = Array(word.lowercased())
        guard letters.count == points.count else { return }
        for (letter, point) in zip(letters, points) {
            guard let point, let index = Self.index(of: letter), let center = drawn.centers[letter] else { continue }
            let offsetX = point.x - center.x - dx[index]
            let offsetY = point.y - center.y - dy[index]
            guard abs(offsetX) < Self.farthest, abs(offsetY) < Self.farthest else { continue }
            touches[index] += 1
            // A plain mean for the first touches, then a slow moving one, so habits can change.
            let share = max(1 / CGFloat(touches[index]), Self.rate)
            dx[index] = min(max(dx[index] + share * offsetX, -Self.maxOffset), Self.maxOffset)
            dy[index] = min(max(dy[index] + share * offsetY, -Self.maxOffset), Self.maxOffset)
        }
    }

    /// The key centers to aim at. A key needs a few touches before it moves at all.
    func geometry(from drawn: KeyGeometry = .letters) -> KeyGeometry {
        var centers = drawn.centers
        for (letter, center) in drawn.centers {
            guard let index = Self.index(of: letter), touches[index] >= Self.touchesToTrust else { continue }
            centers[letter] = CGPoint(x: center.x + dx[index], y: center.y + dy[index])
        }
        return KeyGeometry(centers: centers)
    }

    static let touchesToTrust = 5

    private static let key = "KeyboardTouchAdaptation"

    /// It stays in the keyboard's own container, like everything learned from typing.
    static func load(from defaults: UserDefaults = .standard) -> TouchAdaptation {
        guard let data = defaults.data(forKey: key) else { return TouchAdaptation() }
        return try! JSONDecoder().decode(TouchAdaptation.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try! JSONEncoder().encode(self), forKey: Self.key)
    }

    private static func index(of letter: Character) -> Int? {
        guard let ascii = letter.asciiValue, ascii >= UInt8(ascii: "a"), ascii <= UInt8(ascii: "z") else { return nil }
        return Int(ascii - UInt8(ascii: "a"))
    }
}
