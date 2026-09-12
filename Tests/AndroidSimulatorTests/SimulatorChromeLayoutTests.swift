import XCTest
import CoreGraphics
@testable import AndroidSimulator

final class SimulatorChromeLayoutTests: XCTestCase {
    func testLiveLandscapeFrameOverridesPortraitAVDWithoutChangingAspectRatio() {
        let layout = SimulatorChromeLayout(available: CGSize(width: 700, height: 500), frame: CGSize(width: 1920, height: 864), resolution: "1280 × 2856", scale: 1)
        XCTAssertEqual(layout.screenSize.width / layout.screenSize.height, 1920.0 / 864, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(layout.bodySize.width, 700)
        XCTAssertLessThanOrEqual(layout.bodySize.height, 500)
        XCTAssertGreaterThan(layout.screenCornerRadius, 0)
    }

    func testMissingVideoUsesConfiguredResolutionAndScaleFitsWholeBezel() {
        let available = CGSize(width: 400, height: 720)
        let fit = SimulatorChromeLayout(available: available, frame: .zero, resolution: "1280 × 2856", scale: 1)
        let reduced = SimulatorChromeLayout(available: available, frame: .zero, resolution: "1280 × 2856", scale: 0.5)
        XCTAssertEqual(fit.screenSize.width / fit.screenSize.height, 1280.0 / 2856, accuracy: 0.0001)
        XCTAssertEqual(reduced.bodySize.width, fit.bodySize.width * 0.5, accuracy: 0.0001)
        XCTAssertEqual(reduced.bodySize.height, fit.bodySize.height * 0.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(fit.bodySize.height, available.height)
    }

    func testMalformedGeometryRemainsFiniteAndFallsBackToPhoneAspectRatio() {
        let layout = SimulatorChromeLayout(available: CGSize(width: CGFloat.infinity, height: -1), frame: CGSize(width: CGFloat.nan, height: 5), resolution: "NaN × Infinity", scale: .nan)
        XCTAssertTrue(layout.screenSize.width.isFinite)
        XCTAssertTrue(layout.screenSize.height.isFinite)
        XCTAssertGreaterThan(layout.screenSize.width, 0)
        XCTAssertGreaterThan(layout.screenSize.height, 0)
        XCTAssertEqual(layout.screenSize.width / layout.screenSize.height, 1080.0 / 2400, accuracy: 0.0001)
    }
}
