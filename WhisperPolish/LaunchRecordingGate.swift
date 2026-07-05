struct LaunchRecordingGate {
    private var didConsumeLaunchOpportunity = false

    mutating func shouldStartRecording(
        hasCompletedSetup: Bool,
        recordOnLaunch: Bool,
        recorderIsPresented: Bool,
        blockingModalIsPresented: Bool
    ) -> Bool {
        guard hasCompletedSetup,
              !didConsumeLaunchOpportunity,
              !recorderIsPresented,
              !blockingModalIsPresented else {
            return false
        }

        didConsumeLaunchOpportunity = true
        return recordOnLaunch
    }
}
