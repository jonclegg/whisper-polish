#if DEBUG
import Foundation
import SwiftData

@MainActor
enum AppStoreScreenshotFixtures {
    static let launchArgument = "-appStoreScreenshots"

    @discardableResult
    static func seedIfNeeded(
        in context: ModelContext,
        isEnabled: Bool? = nil
    ) throws -> Bool {
        let enabled = isEnabled ?? ProcessInfo.processInfo.arguments.contains(launchArgument)
        guard enabled, try context.fetchCount(FetchDescriptor<Note>()) == 0 else {
            return false
        }

        let now = Date()

        let launch = Note(
            source: .voice,
            originalText: "okay quick launch update the final build is ready and support docs are reviewed let's hold the release until nine friday morning so everybody is online and if anything changes overnight just text me directly",
            duration: 42
        )
        launch.createdAt = now.addingTimeInterval(-12 * 60)
        launch.applyPolish(PolishResult(
            text: "Hi team,\n\nQuick launch update: the final build is ready and the support docs are reviewed. Let's hold the release until Friday at 9:00 a.m. so everyone is online.\n\nIf anything changes overnight, text me directly.\n\nThanks!",
            style: .email,
            model: "Whisper Polish Cloud"
        ))

        let errands = Note(
            source: .voice,
            originalText: "remind me before the cabin trip we need coffee filters firewood batteries for the lantern and i should call the hardware store about that screen door",
            duration: 28
        )
        errands.createdAt = now.addingTimeInterval(-2 * 60 * 60)
        errands.applyPolish(PolishResult(
            text: "Cabin trip:\n• Coffee filters\n• Firewood\n• Lantern batteries\n• Call the hardware store about the screen door",
            style: .bullets,
            model: "Whisper Polish Cloud"
        ))

        let idea = Note(
            source: .text,
            originalText: "The best notes app should get out of the way: tap, talk, and leave with words you can actually send."
        )
        idea.createdAt = now.addingTimeInterval(-24 * 60 * 60)

        context.insert(launch)
        context.insert(errands)
        context.insert(idea)
        try context.save()
        return true
    }
}
#endif
