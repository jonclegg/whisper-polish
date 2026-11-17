import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import DogballWhisper

final class FixShortcutRecordingTests: XCTestCase {
    private func outcome(_ keyCode: UInt16, _ flags: CGEventFlags) -> ShortcutRecording.Outcome {
        ShortcutRecording.outcome(keyCode: keyCode, flags: flags, rule: .fixShortcut)
    }

    func testCommandShiftOneIsRecorded() {
        XCTAssertEqual(outcome(18, [.maskCommand, .maskShift]), .recorded(.defaultFixShortcut))
    }

    func testControlOrOptionAloneIsEnough() {
        XCTAssertEqual(
            outcome(17, [.maskControl]),
            .recorded(HotkeyBinding(comboKeyCode: 17, modifiers: [.maskControl])))
        XCTAssertEqual(
            outcome(17, [.maskAlternate]),
            .recorded(HotkeyBinding(comboKeyCode: 17, modifiers: [.maskAlternate])))
    }

    func testShiftAloneOrNoModifierIsRejected() {
        XCTAssertEqual(outcome(18, [.maskShift]), .rejected(ShortcutRecording.Rule.fixShortcut.requirement))
        XCTAssertEqual(outcome(18, []), .rejected(ShortcutRecording.Rule.fixShortcut.requirement))
    }

    // fn rides along on arrows and F-keys, and caps lock on anything; a
    // Carbon hot key can carry neither.
    func testFnAndCapsLockAreDropped() {
        XCTAssertEqual(
            outcome(123, [.maskCommand, .maskSecondaryFn, .maskAlphaShift, .maskNonCoalesced]),
            .recorded(HotkeyBinding(comboKeyCode: 123, modifiers: [.maskCommand])))
        XCTAssertEqual(outcome(123, [.maskSecondaryFn]), .rejected(ShortcutRecording.Rule.fixShortcut.requirement))
    }

    func testModifierKeyOnItsOwnIsRejected() {
        guard case .rejected = outcome(ModifierKeyCode.leftCommand, [.maskCommand]) else {
            return XCTFail("a bare ⌘ is not a shortcut")
        }
    }

    func testEscapeCancelsWithOrWithoutModifiers() {
        XCTAssertEqual(outcome(53, []), .cancelled)
        XCTAssertEqual(outcome(53, [.maskCommand]), .cancelled)
    }

    // The hold-to-talk combo keeps its old rule: any modifier, fn included.
    func testDictationRuleAcceptsShiftAndFn() {
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: 49, flags: [.maskShift], rule: .dictation),
            .recorded(HotkeyBinding(comboKeyCode: 49, modifiers: [.maskShift])))
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: 49, flags: [.maskSecondaryFn], rule: .dictation),
            .recorded(HotkeyBinding(comboKeyCode: 49, modifiers: [.maskSecondaryFn])))
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: 49, flags: [], rule: .dictation),
            .rejected(ShortcutRecording.Rule.dictation.requirement))
    }
}

final class FixShortcutDisplayTests: XCTestCase {
    func testDefaultIsCommandShiftOne() {
        XCTAssertEqual(HotkeyBinding.defaultFixShortcut.keyCode, 18)
        XCTAssertEqual(HotkeyBinding.defaultFixShortcut.modifiers, [.maskCommand, .maskShift])
        // macOS's own order for modifier symbols, as menus draw them.
        XCTAssertEqual(HotkeyBinding.defaultFixShortcut.displayName, "⇧⌘1")
    }

    func testModifiersAreDrawnInMenuOrder() {
        let all = HotkeyBinding(
            comboKeyCode: 2, modifiers: [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        XCTAssertEqual(all.displayName, "⌃⌥⇧⌘D")
    }

    func testSpecialKeysHaveNames() {
        let cases: [(UInt16, String)] = [
            (49, "⌘Space"), (36, "⌘Return"), (122, "⌘F1"), (111, "⌘F12"),
            (123, "⌘←"), (124, "⌘→"), (125, "⌘↓"), (126, "⌘↑"),
            (29, "⌘0"), (44, "⌘/"), (42, "⌘\\"), (50, "⌘`"), (83, "⌘Keypad 1"),
        ]
        for (keyCode, expected) in cases {
            XCTAssertEqual(
                HotkeyBinding(comboKeyCode: keyCode, modifiers: [.maskCommand]).displayName, expected)
        }
    }

    func testUnknownKeyFallsBackToItsCode() {
        XCTAssertEqual(KeyCodeNames.name(for: 200), "Key 200")
    }
}

final class FixShortcutCarbonModifierTests: XCTestCase {
    func testEachModifierMapsToItsCarbonBit() {
        XCTAssertEqual(FixShortcutRegistration.carbonModifiers(for: [.maskCommand]), UInt32(cmdKey))
        XCTAssertEqual(FixShortcutRegistration.carbonModifiers(for: [.maskShift]), UInt32(shiftKey))
        XCTAssertEqual(FixShortcutRegistration.carbonModifiers(for: [.maskAlternate]), UInt32(optionKey))
        XCTAssertEqual(FixShortcutRegistration.carbonModifiers(for: [.maskControl]), UInt32(controlKey))
    }

    func testCommandShiftCombines() {
        XCTAssertEqual(
            FixShortcutRegistration.carbonModifiers(for: HotkeyBinding.defaultFixShortcut.modifiers),
            UInt32(cmdKey | shiftKey))
    }
}
