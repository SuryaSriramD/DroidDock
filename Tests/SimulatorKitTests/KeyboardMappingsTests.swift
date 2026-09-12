import Foundation
import XCTest
@testable import SimulatorKit

final class KeyboardMappingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "AndroidSimulator.KeyboardMappingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFunctionKeysDefaultToNoneAndPersistIndependently() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(KeyboardMappings.functionKeys.map(\.keyCode), [122, 120, 99, 118, 96, 97, 98, 100])
        XCTAssertEqual(KeyboardMappings.functionKeys.map(\.title), (1...8).map { "F\($0)" })
        XCTAssertTrue(KeyboardMappings.functionKeys.allSatisfy { KeyboardMappings.action(for: $0.keyCode, defaults: defaults) == .none })
        KeyboardMappings.setAction(.home, for: 122, defaults: defaults)
        KeyboardMappings.setAction(.volumeDown, for: 120, defaults: defaults)
        XCTAssertEqual(KeyboardMappings.action(for: 122, defaults: defaults), .home)
        XCTAssertEqual(KeyboardMappings.action(for: 120, defaults: defaults), .volumeDown)
        KeyboardMappings.setAction(.none, for: 122, defaults: defaults)
        XCTAssertEqual(KeyboardMappings.action(for: 122, defaults: defaults), .none)
        XCTAssertEqual(KeyboardMappings.action(for: 120, defaults: defaults), .volumeDown)
        XCTAssertNil(defaults.object(forKey: KeyboardMappings.preferenceKey(122)))
    }

    func testUnsupportedKeysAndCorruptPreferencesNeverMap() {
        let defaults = isolatedDefaults()
        KeyboardMappings.setAction(.power, for: 53, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: KeyboardMappings.preferenceKey(53)))
        defaults.set("power", forKey: KeyboardMappings.preferenceKey(53))
        XCTAssertEqual(KeyboardMappings.action(for: 53, defaults: defaults), .none)
        defaults.set("unknown-action", forKey: KeyboardMappings.preferenceKey(122))
        XCTAssertEqual(KeyboardMappings.action(for: 122, defaults: defaults), .none)
        XCTAssertEqual(KeyboardMappings.Action.allCases.map(\.androidKeyCode), [nil, 3, 4, 187, 26, 24, 25, 82])
    }

    func testPreferenceChangeDuringPressKeepsRepeatAndReleaseOnOriginalKey() {
        let defaults = isolatedDefaults()
        var held = KeyboardPressState()
        KeyboardMappings.setAction(.home, for: 122, defaults: defaults)
        XCTAssertEqual(held.keyDown(122, mapping: KeyboardMappings.action(for: 122, defaults: defaults).androidKeyCode), 3)
        KeyboardMappings.setAction(.back, for: 122, defaults: defaults)
        XCTAssertEqual(held.keyDown(122, mapping: KeyboardMappings.action(for: 122, defaults: defaults).androidKeyCode), 3)
        XCTAssertEqual(held.keyUp(122), 3)
        XCTAssertEqual(held.keyDown(122, mapping: KeyboardMappings.action(for: 122, defaults: defaults).androidKeyCode), 4)
        XCTAssertEqual(held.keyUp(122), 4)
    }

    func testUnmappedOrIMEPressCannotBecomeMappedOnRepeat() {
        var held = KeyboardPressState()
        XCTAssertNil(held.keyDown(122, mapping: nil))
        XCTAssertNil(held.keyDown(122, mapping: 26))
        XCTAssertNil(held.keyUp(122))
        XCTAssertEqual(held.keyDown(122, mapping: 26), 26)
        XCTAssertEqual(held.releaseAll(), [26])
    }

    func testSharedAndroidKeyRemainsPressedUntilAllPhysicalKeysRelease() {
        var held = KeyboardPressState()
        XCTAssertEqual(held.keyDown(53, mapping: 4), 4) // Escape
        XCTAssertEqual(held.keyDown(122, mapping: 4), 4) // Custom F1
        XCTAssertNil(held.keyUp(53))
        XCTAssertEqual(held.keyUp(122), 4)
        XCTAssertNil(held.keyUp(122))
        XCTAssertTrue(held.releaseAll().isEmpty)
    }

    func testFocusLossReleasesEveryCapturedAndroidKeyOnceAndClearsUnmappedKeys() {
        var held = KeyboardPressState()
        _ = held.keyDown(53, mapping: 4)
        _ = held.keyDown(122, mapping: 4)
        _ = held.keyDown(120, mapping: 24)
        _ = held.keyDown(99, mapping: nil)
        XCTAssertEqual(held.releaseAll(), [4, 24])
        XCTAssertNil(held.keyUp(53))
        XCTAssertNil(held.keyUp(122))
        XCTAssertNil(held.keyUp(120))
        XCTAssertEqual(held.keyDown(99, mapping: 187), 187)
    }
}
