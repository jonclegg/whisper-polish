import Foundation

struct LaunchRecordingGate {
    private static let inactiveClosureInterval: TimeInterval = 60

    private var didConsumeOpenOpportunity = false
    private var movedAwayAt: Date?

    mutating func appMovedAway(at date: Date = .now) {
        guard movedAwayAt == nil else { return }
        movedAwayAt = date
    }

    mutating func appBecameActive(at date: Date = .now) {
        guard let movedAwayAt else { return }
        if date.timeIntervalSince(movedAwayAt) >= Self.inactiveClosureInterval {
            didConsumeOpenOpportunity = false
        }
        self.movedAwayAt = nil
    }

    mutating func shouldStartRecording(
        hasCompletedSetup: Bool,
        recordOnLaunch: Bool,
        recorderIsPresented: Bool,
        blockingModalIsPresented: Bool
    ) -> Bool {
        guard hasCompletedSetup,
              !didConsumeOpenOpportunity,
              !recorderIsPresented,
              !blockingModalIsPresented else {
            return false
        }

        didConsumeOpenOpportunity = true
        return recordOnLaunch
    }
}
