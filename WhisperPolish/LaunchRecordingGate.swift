struct LaunchRecordingGate {
    private var didStartRecordingInCurrentActivation = false

    mutating func didEnterBackground() {
        didStartRecordingInCurrentActivation = false
    }

    mutating func shouldStartRecording(
        hasCompletedSetup: Bool,
        recordOnLaunch: Bool,
        recorderIsPresented: Bool,
        blockingModalIsPresented: Bool
    ) -> Bool {
        guard hasCompletedSetup,
              recordOnLaunch,
              !didStartRecordingInCurrentActivation,
              !recorderIsPresented,
              !blockingModalIsPresented else {
            return false
        }

        didStartRecordingInCurrentActivation = true
        return true
    }
}
