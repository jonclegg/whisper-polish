import Foundation

/// Runs a `Predictor` on a queue of its own, so touches and edits never wait on
/// the word model. Work runs in the order it's handed over, so learning a word
/// always lands before the next prediction that should know it. Every keyboard
/// in the process shares the queue, so one closing and the next opening line up.
final class PredictionEngine: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.jonclegg.WhisperPolish.Keyboard.prediction", qos: .userInteractive)
    /// What a keyboard in this process last saved, which is what the file holds: only
    /// the keyboard writes it, so the next one to open skips decoding it. Only touched on `queue`.
    nonisolated(unsafe) static var savedPersonal: PersonalModel?

    /// Only touched on `queue`.
    private let predictor = Predictor()

    func perform(_ work: @escaping @Sendable (Predictor) -> Void) {
        Self.queue.async { [predictor] in work(predictor) }
    }

    /// Runs `work` after what's already queued and waits for it until `deadline`;
    /// nil if it isn't done by then, though it still runs.
    func performAndWait<Result>(until deadline: DispatchTime, _ work: @escaping @Sendable (Predictor) -> Result) -> Result? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Result>()
        Self.queue.async { [predictor] in
            box.value = work(predictor)
            done.signal()
        }
        guard done.wait(timeout: deadline) == .success else { return nil }
        return box.value
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }
}
