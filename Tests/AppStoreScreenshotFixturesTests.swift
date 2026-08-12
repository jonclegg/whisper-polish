import SwiftData
import XCTest
@testable import WhisperPolish

@MainActor
final class AppStoreScreenshotFixturesTests: XCTestCase {
    func testSeedCreatesThreeRepresentativeNotesOnlyOnce() throws {
        let container = try ModelContainer(
            for: Note.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        XCTAssertTrue(try AppStoreScreenshotFixtures.seedIfNeeded(in: context, isEnabled: true))
        XCTAssertFalse(try AppStoreScreenshotFixtures.seedIfNeeded(in: context, isEnabled: true))

        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 3)
        let polished = try XCTUnwrap(notes.first(where: { $0.polishStyleLabel == "Email" }))
        XCTAssertEqual(polished.polishStyleLabel, "Email")
        XCTAssertEqual(polished.polishModel, "Whisper Polish Cloud")
        XCTAssertTrue(polished.polishedText?.contains("Friday at 9:00 a.m.") == true)
    }

    func testSeedDoesNothingWithoutScreenshotMode() throws {
        let container = try ModelContainer(
            for: Note.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        XCTAssertFalse(try AppStoreScreenshotFixtures.seedIfNeeded(
            in: container.mainContext,
            isEnabled: false
        ))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Note>()), 0)
    }
}
