import Foundation
import CoreGraphics

/// The shared aspect-fit geometry for presentation and pointer hit-testing.
///
/// View points use the top-left origin of a flipped AppKit view. `viewSize` is
/// expressed in logical points, while `frameSize` is the guest image's pixel
/// size. Backing scale is intentionally absent: AppKit pointer coordinates and
/// the view bounds already use the same logical coordinate system.
public struct DisplayGeometry: Sendable, Equatable {
    public let viewSize: CGSize
    public let frameSize: CGSize
    public let contentRect: CGRect

    public init(viewSize: CGSize, frameSize: CGSize) {
        self.viewSize = viewSize
        self.frameSize = frameSize

        guard Self.isValid(viewSize), Self.isValid(frameSize) else {
            contentRect = .zero
            return
        }

        let scale = min(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let fittedSize = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        guard Self.isValid(fittedSize) else {
            contentRect = .zero
            return
        }
        contentRect = CGRect(
            x: (viewSize.width - fittedSize.width) / 2,
            y: (viewSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// Returns guest pixel coordinates, or nil for letterboxing/invalid geometry.
    ///
    /// Both content edges are accepted. The outermost edge is clamped to the
    /// final addressable pixel instead of producing the out-of-bounds size.
    /// Fractional coordinates are retained so the input protocol can choose its
    /// required integer representation. Use the current decoded frame size for
    /// `frameSize`; orientation changes need no independent rotation transform.
    public func devicePoint(from point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              contentRect.width > 0, contentRect.height > 0,
              point.x >= contentRect.minX, point.x <= contentRect.maxX,
              point.y >= contentRect.minY, point.y <= contentRect.maxY else {
            return nil
        }

        let x = (point.x - contentRect.minX) / contentRect.width * frameSize.width
        let y = (point.y - contentRect.minY) / contentRect.height * frameSize.height
        return CGPoint(
            x: min(max(0, x), max(0, frameSize.width - 1)),
            y: min(max(0, y), max(0, frameSize.height - 1))
        )
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
