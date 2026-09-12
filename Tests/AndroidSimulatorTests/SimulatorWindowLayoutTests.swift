import XCTest
@testable import AndroidSimulator

final class SimulatorWindowLayoutTests: XCTestCase {
    func testPortraitRotationProducesCompactLandscapeWindowAndKeepsToolbarPosition() throws {
        let current = CGRect(x: 100, y: 120, width: 440, height: 900)
        let rotated = try XCTUnwrap(SimulatorWindowLayout.rotatedFrame(current: current,
            previousDisplay: CGSize(width: 1280, height: 2856), visible: CGRect(x: 0, y: 0, width: 1600, height: 1200), developerPanelVisible: false))
        XCTAssertGreaterThan(rotated.width, 800)
        XCTAssertLessThan(rotated.height, 500)
        XCTAssertEqual(rotated.minX, current.minX, accuracy: 0.01)
        XCTAssertEqual(rotated.maxY, current.maxY, accuracy: 0.01)
    }

    func testReverseRotationRestoresSavedPortraitSizeWithoutPositionDrift() throws {
        let portrait = CGRect(x: 80, y: 150, width: 440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let landscape = try XCTUnwrap(SimulatorWindowLayout.rotatedFrame(current: portrait,
            previousDisplay: CGSize(width: 1280, height: 2856), visible: visible, developerPanelVisible: false))
        let restored = try XCTUnwrap(SimulatorWindowLayout.rotatedFrame(current: landscape,
            previousDisplay: CGSize(width: 2856, height: 1280), visible: visible, developerPanelVisible: false, restoredSize: portrait.size))
        XCTAssertEqual(restored, portrait)
    }

    func testWindowFitsSmallerAndOffsetDisplaysWithDeveloperPanel() throws {
        let visible = CGRect(x: -850, y: 30, width: 850, height: 700)
        let rotated = try XCTUnwrap(SimulatorWindowLayout.rotatedFrame(current: CGRect(x: -300, y: 100, width: 440, height: 900),
            previousDisplay: CGSize(width: 1280, height: 2856), visible: visible, developerPanelVisible: true))
        XCTAssertTrue(visible.contains(rotated))
        XCTAssertGreaterThan(rotated.height, SimulatorWindowLayout.panelHeight + 100)
        XCTAssertGreaterThan(rotated.width, rotated.height - SimulatorWindowLayout.panelHeight)
        let tiny = CGRect(x: 0, y: 0, width: 320, height: 240)
        let tinyWindow = try XCTUnwrap(SimulatorWindowLayout.rotatedFrame(current: rotated,
            previousDisplay: CGSize(width: 2856, height: 1280), visible: tiny, developerPanelVisible: false, restoredSize: CGSize(width: 440, height: 900)))
        XCTAssertTrue(tiny.contains(tinyWindow), "Visible bounds take priority when even the usual minimum cannot fit")
    }

    func testInvalidDisplayAndWindowGeometryCannotProduceANonfiniteFrame() {
        let window = CGRect(x: 0, y: 0, width: 440, height: 900)
        XCTAssertNil(SimulatorWindowLayout.Orientation(display: .zero))
        XCTAssertNil(SimulatorWindowLayout.rotatedFrame(current: window, previousDisplay: CGSize(width: CGFloat.nan, height: 100), visible: window, developerPanelVisible: false))
        XCTAssertNil(SimulatorWindowLayout.rotatedFrame(current: window, previousDisplay: CGSize(width: 100, height: 200), visible: .zero, developerPanelVisible: false))
        XCTAssertNil(SimulatorWindowLayout.rotatedFrame(current: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), previousDisplay: CGSize(width: 100, height: 200), visible: window, developerPanelVisible: false))
    }
}
