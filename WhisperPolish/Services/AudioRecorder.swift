import AVFoundation
import Observation

@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Rolling window of normalized mic levels (0...1) for the live waveform.
    private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    static let levelWindowSize = 40
    /// The meter reports full scale before it has processed real audio, and
    /// the mic's auto-gain settles during the first fraction of a second —
    /// both would draw a spurious burst of tall bars when recording starts.
    static let meterWarmUp: TimeInterval = 0.3

    /// Maps a metered dBFS reading (-160...0) to a 0...1 bar level,
    /// treating anything inside the warm-up window as silence.
    static func normalizedLevel(fromDb db: Float, at time: TimeInterval) -> Float {
        guard time >= meterWarmUp else { return 0 }
        return max(0, min(1, (db + 50) / 50))
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Session activation takes ~200ms and would freeze the record-button
    /// morph animation if run on the main thread, so it happens detached.
    func start() async throws {
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        }.value

        let dir = URL.documentsDirectory.appending(path: "Audio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(UUID().uuidString).wav")

        // 16kHz mono PCM — exactly what Parakeet wants, no resampling needed.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        self.fileURL = url
        self.elapsed = 0
        // Pre-fill with silence so the waveform is full-width from the first
        // frame instead of growing bar by bar from the center.
        self.levels = Array(repeating: 0, count: Self.levelWindowSize)
        self.isRecording = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            self.elapsed = recorder.currentTime
            let db = recorder.averagePower(forChannel: 0)
            self.levels.append(Self.normalizedLevel(fromDb: db, at: recorder.currentTime))
            if self.levels.count > Self.levelWindowSize { self.levels.removeFirst() }
        }
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        timer?.invalidate()
        timer = nil
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileURL, duration)
    }

    func cancel() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
    }
}
