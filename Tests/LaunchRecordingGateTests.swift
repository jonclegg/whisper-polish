import XCTest
@testable import WhisperPolish

final class LaunchRecordingGateTests: XCTestCase {

    func testStartsOnceWhenRecordOnLaunchIsEnabled() {
        var gate = LaunchRecordingGate()

        XCTAssertTrue(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
    }

    func testStartsAfterSetupCompletes() {
        var gate = LaunchRecordingGate()

        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: false,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
        XCTAssertTrue(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
    }

    func testDoesNotStartAgainAfterReturningToForegroundInSameLaunch() {
        var gate = LaunchRecordingGate()

        XCTAssertTrue(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))

        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
    }

    func testBlockingModalDoesNotConsumeTheLaunchTrigger() {
        var gate = LaunchRecordingGate()

        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: true
        ))
        XCTAssertTrue(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
    }

    func testDisabledSettingDoesNotStartRecording() {
        var gate = LaunchRecordingGate()

        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: false,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
        XCTAssertFalse(gate.shouldStartRecording(
            hasCompletedSetup: true,
            recordOnLaunch: true,
            recorderIsPresented: false,
            blockingModalIsPresented: false
        ))
    }
}
