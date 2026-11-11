import XCTest
@testable import DogballWhisper

@MainActor
final class SkeletonTests: XCTestCase {
    func testMenuBarControllerCreatesAStatusItemWithAMenu() {
        let controller = MenuBarController(onOpenSettings: {}, onFinishSetup: {})
        XCTAssertNotNil(controller.statusItem.button)
        XCTAssertEqual(controller.statusItem.menu?.items.count, 9)
    }

    // The only way to tell from the app itself which build is installed.
    func testTheMenuNamesTheInstalledVersionAboveQuit() throws {
        let controller = MenuBarController(onOpenSettings: {}, onFinishSetup: {})
        let items = try XCTUnwrap(controller.statusItem.menu?.items)
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertEqual(items[items.count - 2].title, "Version \(version) (\(build))")
        XCTAssertFalse(items[items.count - 2].isEnabled)
        XCTAssertEqual(items.last?.title, "Quit Dogball Whisper")
    }

    func testFinishSetupItemOnlyShowsWhileSetupIsIncomplete() {
        let controller = MenuBarController(onOpenSettings: {}, onFinishSetup: {})
        guard let items = controller.statusItem.menu?.items, items.count >= 2 else {
            return XCTFail("expected the finish-setup item and its separator")
        }
        // Hidden by default: most launches finish setup before the menu is ever opened.
        XCTAssertTrue(items[0].isHidden)
        XCTAssertTrue(items[1].isHidden)

        controller.setSetupIncomplete(true)
        XCTAssertFalse(items[0].isHidden)
        XCTAssertFalse(items[1].isHidden)

        controller.setSetupIncomplete(false)
        XCTAssertTrue(items[0].isHidden)
        XCTAssertTrue(items[1].isHidden)
    }
}
