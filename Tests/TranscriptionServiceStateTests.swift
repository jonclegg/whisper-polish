import XCTest
@testable import WhisperPolish

final class TranscriptionServiceStateTests: XCTestCase {

    func testTranscribingStatusMessageShowsDownloadProgress() {
        XCTAssertEqual(
            TranscriptionService.State.downloading(0.42).transcribingStatusMessage,
            "Downloading transcription model... 42%"
        )
    }

    func testTranscribingStatusMessageShowsModelLoading() {
        XCTAssertEqual(
            TranscriptionService.State.loading.transcribingStatusMessage,
            "Loading transcription model..."
        )
    }

    func testTranscribingStatusMessageFallsBackToTranscribingWhenReady() {
        XCTAssertEqual(
            TranscriptionService.State.ready.transcribingStatusMessage,
            "Transcribing..."
        )
    }
}
