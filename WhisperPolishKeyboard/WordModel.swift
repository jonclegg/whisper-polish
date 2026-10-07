import Foundation

/// The keyboard's word LSTM, trained on public text by `scripts/keyboard-model`.
/// The file is memory-mapped, so its Float16 weights are clean pages the
/// system can drop rather than memory counted against the keyboard.
final class WordModel: @unchecked Sendable {
    static let boundary = 0
    static let unknown = 1

    /// The LSTM's memory after the words fed so far.
    struct State {
        fileprivate var hidden: [Float]
        fileprivate var cell: [Float]
    }

    /// Lowercased words by id; 0 is the sentence boundary and 1 an unknown word.
    let words: [String]
    let ids: [String: Int]
    let embeddingSize: Int
    let hiddenSize: Int

    private let data: Data
    private let embedding: Int
    private let inputWeights: Int
    private let hiddenWeights: Int
    private let projection: Int
    private let gateBias: Int
    private let projectionBias: Int
    private let outputBias: Int

    convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        guard data.count > 24, data.prefix(4) == Data("WPWM".utf8) else { throw ModelError.notAModel }
        func integer(_ offset: Int) -> Int {
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian })
        }
        guard integer(4) == 1 else { throw ModelError.unsupportedVersion }
        let vocabularySize = integer(8)
        embeddingSize = integer(12)
        hiddenSize = integer(16)
        var offset = Self.aligned(24)
        let vocabularyBytes = integer(20)
        words = String(decoding: data[offset..<offset + vocabularyBytes], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard words.count == vocabularySize else { throw ModelError.notAModel }
        ids = Dictionary(words.enumerated().map { ($1, $0) }) { first, _ in first }
        offset = Self.aligned(offset + vocabularyBytes)
        func take(_ count: Int, bytes: Int) -> Int {
            defer { offset = Self.aligned(offset + count * bytes) }
            return offset
        }
        let gates = 4 * hiddenSize
        embedding = take(vocabularySize * embeddingSize, bytes: 2)
        inputWeights = take(gates * embeddingSize, bytes: 2)
        hiddenWeights = take(gates * hiddenSize, bytes: 2)
        projection = take(embeddingSize * hiddenSize, bytes: 2)
        gateBias = take(gates, bytes: 4)
        projectionBias = take(embeddingSize, bytes: 4)
        outputBias = take(vocabularySize, bytes: 4)
        guard offset <= data.count else { throw ModelError.notAModel }
    }

    enum ModelError: Error {
        case notAModel
        case unsupportedVersion
    }

    var start: State {
        State(hidden: Array(repeating: 0, count: hiddenSize), cell: Array(repeating: 0, count: hiddenSize))
    }

    func id(of word: String) -> Int {
        ids[word.lowercased()] ?? Self.unknown
    }

    /// Feeds one word id (or the boundary) through the LSTM.
    func advance(_ state: inout State, with id: Int) {
        let size = hiddenSize
        var gates = [Float](repeating: 0, count: 4 * size)
        data.withUnsafeBytes { raw in
            let input = raw.baseAddress!.advanced(by: embedding + id * embeddingSize * 2).assumingMemoryBound(to: Float16.self)
            var inputVector = [Float](repeating: 0, count: embeddingSize)
            for n in 0..<embeddingSize { inputVector[n] = Float(input[n]) }
            let bias = raw.baseAddress!.advanced(by: gateBias).assumingMemoryBound(to: Float.self)
            let inputRows = raw.baseAddress!.advanced(by: inputWeights).assumingMemoryBound(to: Float16.self)
            let hiddenRows = raw.baseAddress!.advanced(by: hiddenWeights).assumingMemoryBound(to: Float16.self)
            inputVector.withUnsafeBufferPointer { x in
                state.hidden.withUnsafeBufferPointer { h in
                    for row in 0..<4 * size {
                        gates[row] = bias[row]
                            + Self.dot(inputRows.advanced(by: row * embeddingSize), x.baseAddress!, embeddingSize)
                            + Self.dot(hiddenRows.advanced(by: row * size), h.baseAddress!, size)
                    }
                }
            }
        }
        for n in 0..<size {
            let input = Self.sigmoid(gates[n])
            let forget = Self.sigmoid(gates[size + n])
            let cell = tanh(gates[2 * size + n])
            let output = Self.sigmoid(gates[3 * size + n])
            state.cell[n] = forget * state.cell[n] + input * cell
            state.hidden[n] = output * tanh(state.cell[n])
        }
    }

    /// How likely each id is to come next, summing to 1.
    func probabilities(after state: State) -> [Float] {
        let count = words.count
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let projectionRows = raw.baseAddress!.advanced(by: projection).assumingMemoryBound(to: Float16.self)
            let projectionOffsets = raw.baseAddress!.advanced(by: projectionBias).assumingMemoryBound(to: Float.self)
            var projected = [Float](repeating: 0, count: embeddingSize)
            state.hidden.withUnsafeBufferPointer { h in
                for row in 0..<embeddingSize {
                    projected[row] = projectionOffsets[row] + Self.dot(projectionRows.advanced(by: row * hiddenSize), h.baseAddress!, hiddenSize)
                }
            }
            let outputRows = raw.baseAddress!.advanced(by: embedding).assumingMemoryBound(to: Float16.self)
            let biases = raw.baseAddress!.advanced(by: outputBias).assumingMemoryBound(to: Float.self)
            let size = embeddingSize
            projected.withUnsafeBufferPointer { p in
                result.withUnsafeMutableBufferPointer { out in
                    // Rows split across cores: this is the bulk of the work.
                    let chunks = 4
                    let chunk = (count + chunks - 1) / chunks
                    DispatchQueue.concurrentPerform(iterations: chunks) { part in
                        for row in part * chunk..<min(count, (part + 1) * chunk) {
                            out[row] = biases[row] + Self.dot(outputRows.advanced(by: row * size), p.baseAddress!, size)
                        }
                    }
                }
            }
        }
        // The boundary is never a suggestion.
        result[Self.boundary] = -.infinity
        let largest = result.max()!
        var total: Float = 0
        for n in 0..<count {
            result[n] = exp(result[n] - largest)
            total += result[n]
        }
        for n in 0..<count { result[n] /= total }
        return result
    }

    /// A Float16 row times a Float vector; `count` is a multiple of 8.
    private static func dot(_ row: UnsafePointer<Float16>, _ vector: UnsafePointer<Float>, _ count: Int) -> Float {
        var sum = SIMD8<Float>.zero
        let rowRaw = UnsafeRawPointer(row)
        let vectorRaw = UnsafeRawPointer(vector)
        var n = 0
        while n < count {
            let weights = SIMD8<Float>(rowRaw.loadUnaligned(fromByteOffset: n * 2, as: SIMD8<Float16>.self))
            sum += weights * vectorRaw.loadUnaligned(fromByteOffset: n * 4, as: SIMD8<Float>.self)
            n += 8
        }
        return sum.sum()
    }

    private static func sigmoid(_ x: Float) -> Float {
        1 / (1 + exp(-x))
    }

    private static func aligned(_ offset: Int) -> Int {
        (offset + 15) / 16 * 16
    }
}
