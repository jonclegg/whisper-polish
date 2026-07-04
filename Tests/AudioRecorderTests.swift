import XCTest
@testable import WhisperPolish

final class AudioRecorderTests: XCTestCase {

    // The meter reports full scale (0 dB) before it has processed real audio,
    // and the mic's auto-gain settles during the first fraction of a second.
    // Those readings must render as silence, not full-height bars.
    func testWarmUpReadingsAreSilencedEvenAtFullScale() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 0.05), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -10, at: 0.2), 0)
    }

    func testMappingAfterWarmUp() {
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: 0, at: 1.0), 1)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -25, at: 1.0), 0.5)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -50, at: 1.0), 0)
        XCTAssertEqual(AudioRecorder.normalizedLevel(fromDb: -160, at: 1.0), 0)
    }
}
