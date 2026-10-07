import Foundation
import llama

enum LlamaError: LocalizedError, Equatable {
    case modelLoadFailed
    case contextFailed
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "The on-device cleanup model could not be loaded."
        case .contextFailed: return "The on-device cleanup model could not start."
        case let .promptTooLong(tokens, limit):
            return "The dictation is too long for on-device cleanup (\(tokens) of \(limit) tokens)."
        case let .decodeFailed(code): return "On-device cleanup failed (llama.cpp error \(code))."
        }
    }
}

/// One GGUF model held in memory, completing raw prompts with greedy decoding.
///
/// An actor because llama.cpp's context is single-threaded state: two
/// dictations in flight queue here rather than interleaving tokens. Its methods
/// run on the cooperative pool, never on the main actor, so a load or a
/// generation never stalls the UI or the hotkey.
actor LlamaRunner {
    /// Room for the longest dictation S1-mini is meant for (~1,000 tokens) plus
    /// its prompt and an answer of similar length.
    static let contextTokens: UInt32 = 4096

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    private static let backend: Void = {
        llama_backend_init()
        // llama.cpp logs every tensor it loads to stderr; none of it is
        // actionable here, and failures surface as thrown errors instead.
        llama_log_set({ _, _, _ in }, nil)
    }()

    init(modelPath: String) throws {
        _ = Self.backend
        guard let model = llama_model_load_from_file(modelPath, llama_model_default_params()) else {
            throw LlamaError.modelLoadFailed
        }
        var params = llama_context_default_params()
        params.n_ctx = Self.contextTokens
        params.n_batch = Self.contextTokens
        params.no_perf = true
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaError.modelLoadFailed
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    /// One piece of a prompt. `special` pieces are the model's own chat
    /// template, where text like `<|im_start|>` must become control tokens;
    /// everything the user said goes in a non-special piece, so a dictation
    /// that happens to contain such text cannot rewrite the template.
    struct Segment: Sendable {
        let text: String
        let special: Bool
    }

    /// Continues the prompt until the model emits an end-of-generation token.
    ///
    /// Checks for cancellation between tokens, so the coordinator's cleanup
    /// timeout and the fix dialog's Cancel actually stop the work instead of
    /// waiting it out. `onText`, if given, receives the whole answer so far
    /// after every token, for showing it as it is written.
    func complete(_ segments: [Segment], onText: (@Sendable (String) -> Void)? = nil) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)

        var tokens: [llama_token] = []
        for (index, segment) in segments.enumerated() {
            tokens += try tokenize(segment.text, addBOS: index == 0, special: segment.special)
        }
        let limit = Int(Self.contextTokens)
        guard tokens.count < limit else {
            throw LlamaError.promptTooLong(tokens: tokens.count, limit: limit)
        }
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LlamaError.decodeFailed(status) }

        var output = Data()
        var position = tokens.count
        while position < limit {
            try Task.checkCancellation()
            var next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            output.append(piece(next))
            onText?(String(decoding: output, as: UTF8.self))
            position += 1
            let status = llama_decode(context, llama_batch_get_one(&next, 1))
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
        }
        // Pieces can split a multi-byte character, so decode once at the end.
        return String(decoding: output, as: UTF8.self)
    }

    private func tokenize(_ text: String, addBOS: Bool, special: Bool) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        let count = llama_tokenize(
            vocab, text, utf8Count, &tokens, Int32(tokens.count), addBOS, special)
        guard count >= 0 else {
            throw LlamaError.promptTooLong(tokens: Int(-count), limit: Int(Self.contextTokens))
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(_ token: llama_token) -> Data {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return Data(buffer.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) })
    }
}
