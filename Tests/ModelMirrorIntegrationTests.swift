import XCTest
import FluidAudio
@testable import WhisperPolish

/// Real end-to-end check against the live CloudFront mirror.
/// Gated behind RUN_MIRROR_IT so the fast unit suite stays fast.
/// Run with: `-only-testing:WhisperPolishTests/ModelMirrorIntegrationTests` and RUN_MIRROR_IT=1.
final class ModelMirrorIntegrationTests: XCTestCase {

    func testMirrorDownloadsAndLoadsOffline() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MIRROR_IT"] != nil,
            "Set RUN_MIRROR_IT=1 to run the live mirror download test")

        // 1. Download every manifest file from CloudFront into FluidAudio's cache dir.
        var lastFraction = 0.0
        try await ModelMirror.download { fraction in lastFraction = fraction }
        XCTAssertEqual(lastFraction, 1.0, accuracy: 0.001, "progress should reach 100%")

        // 2. Every required file is present at the right size.
        XCTAssertTrue(ModelMirror.isComplete(), "all files should be present after download")

        // 3. With network fetching disabled, FluidAudio must still load the model —
        //    which only works if the mirror delivered a complete, correct model.
        DownloadUtils.enforceOffline = true
        defer { DownloadUtils.enforceOffline = false }
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let available = await manager.isAvailable
        XCTAssertTrue(available, "model should be loaded and available")
    }
}
