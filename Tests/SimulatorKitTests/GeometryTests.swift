import Foundation
import CoreGraphics
import XCTest
@testable import SimulatorKit

final class GeometryTests: XCTestCase {
    func testPortraitFrameIsCenteredWithHorizontalLetterboxing() {
        let geometry = DisplayGeometry(viewSize: CGSize(width: 500, height: 800), frameSize: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(geometry.contentRect, CGRect(x: 25, y: 0, width: 450, height: 800))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 250, y: 400)), CGPoint(x: 540, y: 960))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 24.99, y: 400)))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 475.01, y: 400)))
    }

    func testLandscapeFrameIsCenteredWithVerticalLetterboxing() {
        let geometry = DisplayGeometry(viewSize: CGSize(width: 800, height: 600), frameSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(geometry.contentRect, CGRect(x: 0, y: 75, width: 800, height: 450))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 400, y: 300)), CGPoint(x: 960, y: 540))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 400, y: 74.99)))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 400, y: 525.01)))
    }

    func testResizePreservesTouchLocationWithoutBackingScale() throws {
        let frame = CGSize(width: 1080, height: 1920)
        let small = DisplayGeometry(viewSize: CGSize(width: 270, height: 480), frameSize: frame)
        let large = DisplayGeometry(viewSize: CGSize(width: 1000, height: 1000), frameSize: frame)
        let smallPoint = CGPoint(x: small.contentRect.minX + small.contentRect.width * 0.25,
                                 y: small.contentRect.minY + small.contentRect.height * 0.75)
        let largePoint = CGPoint(x: large.contentRect.minX + large.contentRect.width * 0.25,
                                 y: large.contentRect.minY + large.contentRect.height * 0.75)
        let smallGuestPoint = try XCTUnwrap(small.devicePoint(from: smallPoint))
        let largeGuestPoint = try XCTUnwrap(large.devicePoint(from: largePoint))
        XCTAssertEqual(smallGuestPoint.x, 270, accuracy: 0.000_001)
        XCTAssertEqual(smallGuestPoint.y, 1440, accuracy: 0.000_001)
        XCTAssertEqual(largeGuestPoint.x, smallGuestPoint.x, accuracy: 0.000_001)
        XCTAssertEqual(largeGuestPoint.y, smallGuestPoint.y, accuracy: 0.000_001)
    }

    func testOrientationUsesTheCurrentFrameDimensions() {
        let view = CGSize(width: 600, height: 600)
        let portrait = DisplayGeometry(viewSize: view, frameSize: CGSize(width: 1080, height: 1920))
        let landscape = DisplayGeometry(viewSize: view, frameSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(portrait.devicePoint(from: CGPoint(x: 300, y: 300)), CGPoint(x: 540, y: 960))
        XCTAssertEqual(landscape.devicePoint(from: CGPoint(x: 300, y: 300)), CGPoint(x: 960, y: 540))
        XCTAssertNil(portrait.devicePoint(from: CGPoint(x: 50, y: 300)))
        XCTAssertNotNil(landscape.devicePoint(from: CGPoint(x: 50, y: 300)))
    }

    func testContentEdgesClampToPixelBoundsAndPreserveTopLeftOrigin() {
        let geometry = DisplayGeometry(viewSize: CGSize(width: 300, height: 400), frameSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 50, y: 0)), .zero)
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 250, y: 400)), CGPoint(x: 99, y: 199))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 250, y: 0)), CGPoint(x: 99, y: 0))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 50, y: 400)), CGPoint(x: 0, y: 199))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 150, y: -0.01)))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 150, y: 400.01)))
    }

    func testSinglePixelFrameAlwaysMapsToItsOnlyPixel() {
        let geometry = DisplayGeometry(viewSize: CGSize(width: 400, height: 400), frameSize: CGSize(width: 1, height: 1))
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 200, y: 200)), .zero)
        XCTAssertEqual(geometry.devicePoint(from: CGPoint(x: 400, y: 400)), .zero)
    }

    func testInvalidDimensionsDisableGeometry() {
        let invalidSizes: [CGSize] = [
            .zero, CGSize(width: -1, height: 100), CGSize(width: 100, height: -1),
            CGSize(width: 0, height: 100), CGSize(width: 100, height: 0),
            CGSize(width: CGFloat.nan, height: 100), CGSize(width: 100, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.infinity)
        ]
        for invalid in invalidSizes {
            let invalidView = DisplayGeometry(viewSize: invalid, frameSize: CGSize(width: 1080, height: 1920))
            let invalidFrame = DisplayGeometry(viewSize: CGSize(width: 500, height: 800), frameSize: invalid)
            XCTAssertEqual(invalidView.contentRect, .zero)
            XCTAssertEqual(invalidFrame.contentRect, .zero)
            XCTAssertNil(invalidView.devicePoint(from: .zero))
            XCTAssertNil(invalidFrame.devicePoint(from: .zero))
        }
    }

    func testNonfinitePointsAreRejected() {
        let geometry = DisplayGeometry(viewSize: CGSize(width: 100, height: 100), frameSize: CGSize(width: 100, height: 100))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: CGFloat.nan, y: 50)))
        XCTAssertNil(geometry.devicePoint(from: CGPoint(x: 50, y: CGFloat.infinity)))
    }
}
