import Foundation
import llama

/// Runs a GGUF model through llama.cpp inside the keyboard, with the weights
/// memory-mapped so their clean pages don't count against the keyboard's memory limit.
final class LlamaPolisher {
    struct Output {
        let text: String
        let promptTokens: Int
        let generatedTokens: Int
        let prefillSeconds: Double
        let decodeSeconds: Double
        /// Model evaluations while writing; fewer than generatedTokens when drafts are accepted.
        let decodeSteps: Int
    }

    enum Failure: LocalizedError {
        case load, context, template, tooLong(Int), decode(Int32)
        var errorDescription: String? {
            switch self {
            case .load: "model didn't load"
            case .context: "context didn't start"
            case .template: "no usable chat template"
            case .tooLong(let count): "prompt too long (\(count) tokens)"
            case .decode(let code): "decode failed (\(code))"
            }
        }
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let template: String
    private let contextTokens: Int
    private let threads: Int32
    /// Hears progress events (load stages, tokens written); the on-device lab logs them.
    private let trace: ((String) -> Void)?

    init(modelPath: String, gpuLayers: Int32, contextTokens: Int, threads: Int32, cacheBits: Int, extraBuffers: Bool, microBatch: Int, cpuOnly: Bool, trace: ((String) -> Void)? = nil) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParams.n_gpu_layers = gpuLayers
        // Repacking copies the weights into anonymous memory, which counts against the limit.
        modelParams.use_extra_bufts = extraBuffers
        // An empty device list keeps Metal from wrapping the weights in GPU buffers.
        let noDevices = UnsafeMutablePointer<ggml_backend_dev_t?>.allocate(capacity: 1)
        noDevices.initialize(to: nil)
        defer { noDevices.deallocate() }
        if cpuOnly {
            modelParams.devices = noDevices
            modelParams.no_host = true
        }
        trace?("load-start \(modelPath.split(separator: "/").last!)")
        guard let model = llama_model_load_from_file(modelPath, modelParams) else { throw Failure.load }
        trace?("weights-loaded")
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextTokens)
        params.n_batch = UInt32(microBatch)
        params.n_ubatch = UInt32(microBatch)
        params.op_offload = gpuLayers != 0
        params.n_threads = threads
        params.n_threads_batch = threads
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        switch cacheBits {
        case 4:
            params.type_k = GGML_TYPE_Q4_0
            params.type_v = GGML_TYPE_Q4_0
        case 8:
            params.type_k = GGML_TYPE_Q8_0
            params.type_v = GGML_TYPE_Q8_0
        default:
            break
        }
        params.no_perf = true
        params.offload_kqv = gpuLayers != 0
        guard let context = llama_init_from_model(model, params), let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw Failure.context
        }
        trace?("context-ready")
        guard let template = llama_model_chat_template(model, nil) else {
            llama_free(context)
            llama_model_free(model)
            throw Failure.template
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        self.template = String(cString: template)
        self.contextTokens = contextTokens
        self.threads = threads
        self.trace = trace
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    /// Applies the model's own chat template, without thinking for models that think.
    func prompt(system: String?, user: String) throws -> String {
        var roles: [(String, String)] = []
        if let system { roles.append(("system", system)) }
        roles.append(("user", user))
        let cStrings = roles.map { (strdup($0.0)!, strdup($0.1)!) }
        defer { cStrings.forEach { free($0.0); free($0.1) } }
        let messages = cStrings.map { llama_chat_message(role: UnsafePointer($0.0), content: UnsafePointer($0.1)) }
        var buffer = [CChar](repeating: 0, count: (system?.utf8.count ?? 0) * 2 + user.utf8.count * 2 + 512)
        var length = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
        if length > buffer.count {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        guard length > 0 else { throw Failure.template }
        var text = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if template.contains("<think>") { text += "<think>\n\n</think>\n\n" }
        return text
    }

    /// With `draftLength` > 0, writes by prompt lookup: drafts the next tokens from
    /// where the output's last words appear in the prompt and verifies them in one pass.
    func complete(_ prompt: String, maxTokens: Int, draftLength: Int = 0, onToken: (() -> Void)? = nil) throws -> Output {
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw Failure.tooLong(Int(-count)) }
        tokens = Array(tokens.prefix(Int(count)))
        guard tokens.count + 16 < contextTokens else { throw Failure.tooLong(tokens.count) }
        let prefillStarted = Date()
        let batchSize = Int(llama_n_batch(context))
        var start = 0
        while start < tokens.count {
            let end = min(start + batchSize, tokens.count)
            var slice = Array(tokens[start..<end])
            let status = slice.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard status == 0 else { throw Failure.decode(status) }
            start = end
        }
        let prefillSeconds = Date().timeIntervalSince(prefillStarted)
        trace?("prefilled \(tokens.count)")
        let decodeStarted = Date()
        if draftLength > 0 {
            let (output, generated, steps) = try decodeWithLookup(prompt: tokens, draftLength: draftLength, maxTokens: maxTokens)
            return Output(
                text: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                promptTokens: tokens.count, generatedTokens: generated, prefillSeconds: prefillSeconds,
                decodeSeconds: Date().timeIntervalSince(decodeStarted), decodeSteps: steps
            )
        }
        var output = Data()
        var generated = 0
        var position = tokens.count
        while position < contextTokens - 1, generated < maxTokens {
            var next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            var piece = [CChar](repeating: 0, count: 128)
            let length = llama_token_to_piece(vocab, next, &piece, 128, 0, false)
            output.append(contentsOf: piece.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) })
            generated += 1
            position += 1
            onToken?()
            if generated % 16 == 0 { trace?("generated \(generated)") }
            let status = llama_decode(context, llama_batch_get_one(&next, 1))
            guard status == 0 else { throw Failure.decode(status) }
        }
        return Output(
            text: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: tokens.count,
            generatedTokens: generated,
            prefillSeconds: prefillSeconds,
            decodeSeconds: Date().timeIntervalSince(decodeStarted),
            decodeSteps: generated
        )
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 128)
        let length = llama_token_to_piece(vocab, token, &buffer, 128, 0, false)
        return buffer.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) }
    }

    private func argmax(_ index: Int32, vocabularySize: Int) -> llama_token {
        let logits = llama_get_logits_ith(context, index)!
        var best = 0
        var bestValue = logits[0]
        for candidate in 1..<vocabularySize where logits[candidate] > bestValue {
            best = candidate
            bestValue = logits[candidate]
        }
        return llama_token(best)
    }

    /// The tokens that follow the latest match of the history's last 1-3 tokens in
    /// the prompt, preferring a match after the previous one so drafts walk forward.
    private func lookupDraft(history: [llama_token], promptCount: Int, length: Int, cursor: inout Int) -> [llama_token] {
        for size in stride(from: 3, through: 1, by: -1) where history.count > size {
            let tail = Array(history.suffix(size))
            var matches: [Int] = []
            var start = 0
            while start + size <= promptCount {
                if Array(history[start..<start + size]) == tail { matches.append(start + size) }
                start += 1
            }
            guard let end = matches.first(where: { $0 > cursor }) ?? matches.first, end < promptCount else { continue }
            cursor = end
            return Array(history[end..<min(end + length, promptCount)])
        }
        return []
    }

    private func decodeWithLookup(prompt tokens: [llama_token], draftLength: Int, maxTokens: Int) throws -> (Data, Int, Int) {
        let vocabularySize = Int(llama_vocab_n_tokens(vocab))
        let memory = llama_get_memory(context)
        var batch = llama_batch_init(Int32(draftLength + 1), 0, 1)
        defer { llama_batch_free(batch) }
        var next = argmax(-1, vocabularySize: vocabularySize)
        var history = tokens
        var output = Data()
        var generated = 0
        var steps = 0
        var position = tokens.count
        var cursor = 0
        while generated < maxTokens, position + draftLength + 1 < contextTokens, !llama_vocab_is_eog(vocab, next) {
            let draft = lookupDraft(history: history + [next], promptCount: tokens.count, length: draftLength, cursor: &cursor)
            let candidates = [next] + draft
            batch.n_tokens = Int32(candidates.count)
            for (index, token) in candidates.enumerated() {
                batch.token[index] = token
                batch.pos[index] = llama_pos(position + index)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = 0
                batch.logits[index] = 1
            }
            let status = llama_decode(context, batch)
            guard status == 0 else { throw Failure.decode(status) }
            steps += 1
            var accepted = [next]
            var predicted = argmax(0, vocabularySize: vocabularySize)
            while accepted.count <= draft.count, draft[accepted.count - 1] == predicted, !llama_vocab_is_eog(vocab, predicted) {
                accepted.append(predicted)
                predicted = argmax(Int32(accepted.count - 1), vocabularySize: vocabularySize)
            }
            for token in accepted { output.append(contentsOf: piece(token)) }
            generated += accepted.count
            history += accepted
            position += accepted.count
            if accepted.count < candidates.count {
                guard llama_memory_seq_rm(memory, 0, llama_pos(position), -1) else { throw Failure.decode(-2) }
            }
            next = predicted
            if generated % 16 < accepted.count { trace?("generated \(generated) in \(steps) steps") }
        }
        return (output, generated, steps)
    }
}
