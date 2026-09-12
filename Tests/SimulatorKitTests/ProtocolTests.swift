import XCTest
@testable import SimulatorKit

final class ProtocolTests: XCTestCase {
    func testTouchUsesGenericFingerAndExactWireOffsets() {
        let down = ScrcpyControlEncoder.encode(.touch(action: 0, x: 120, y: 300, width: 1080, height: 1920))
        XCTAssertEqual(Array(down), [
            2, 0, 255, 255, 255, 255, 255, 255, 255, 254,
            0, 0, 0, 120, 0, 0, 1, 44, 4, 56, 7, 128,
            255, 255, 0, 0, 0, 0, 0, 0, 0, 0
        ])
        let up = ScrcpyControlEncoder.encode(.touch(action: 1, x: 120, y: 300, width: 1080, height: 1920))
        XCTAssertEqual(up[1], 1)
        XCTAssertEqual(up[22], 0)
        XCTAssertEqual(up[23], 0)
    }

    func testPositionsClampToCurrentFrameAndDoNotOverflow() {
        let data = ScrcpyControlEncoder.encode(.touch(action: 2, x: -20, y: Int.max, width: 1080, height: 1920))
        XCTAssertEqual(data.integerBE(at: 10, as: UInt32.self), 0)
        XCTAssertEqual(data.integerBE(at: 14, as: UInt32.self), 1919)
        let extreme = ScrcpyControlEncoder.encode(.touch(action: 2, x: Int.max, y: Int.min, width: Int.max, height: 0))
        XCTAssertEqual(extreme.integerBE(at: 10, as: UInt32.self), 65534)
        XCTAssertEqual(extreme.integerBE(at: 18, as: UInt16.self), 65535)
        XCTAssertEqual(extreme.integerBE(at: 20, as: UInt16.self), 1)
    }

    func testKeycodeWireLayout() {
        XCTAssertEqual(Array(ScrcpyControlEncoder.encode(.key(code: 3, down: true))),
                       [0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ScrcpyControlEncoder.encode(.key(code: 4, down: false))[1], 1)
        XCTAssertEqual(Array(ScrcpyControlEncoder.encode(.rotate)), [11])
    }

    func testScrollUsesSixteenUnitSignedFixedPoint() {
        let data = ScrcpyControlEncoder.encode(.scroll(x: 0, y: 0, width: 100, height: 100, horizontal: -16, vertical: 16))
        XCTAssertEqual(data.count, 21)
        XCTAssertEqual(data.integerBE(at: 13, as: UInt16.self), 0x8000)
        XCTAssertEqual(data.integerBE(at: 15, as: UInt16.self), 0x7fff)
        let fractional = ScrcpyControlEncoder.encode(.scroll(x: 0, y: 0, width: 1, height: 1, horizontal: 1, vertical: .nan))
        XCTAssertEqual(fractional.integerBE(at: 13, as: UInt16.self), 2048)
        XCTAssertEqual(fractional.integerBE(at: 15, as: UInt16.self), 0)
    }

    func testTextLengthIsUTF8AndTruncationPreservesScalars() {
        let text = String(repeating: "a", count: 299) + "😀"
        let data = ScrcpyControlEncoder.encode(.text(text))
        XCTAssertEqual(data.integerBE(at: 1, as: UInt32.self), 299)
        XCTAssertEqual(String(data: data.dropFirst(5), encoding: .utf8), String(repeating: "a", count: 299))
        let unicode = ScrcpyControlEncoder.encode(.text("é😀"))
        XCTAssertEqual(unicode.integerBE(at: 1, as: UInt32.self), 6)
    }

    func testClipboardHasPasteFlagAndBoundedPayload() {
        let data = ScrcpyControlEncoder.encode(.clipboard("Hello"))
        XCTAssertEqual(Array(data), [9, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 72, 101, 108, 108, 111])
        let huge = ScrcpyControlEncoder.encode(.clipboard(String(repeating: "😀", count: 100_000)))
        XCTAssertLessThanOrEqual(huge.count, 1 << 18)
        XCTAssertNotNil(String(data: huge.dropFirst(14), encoding: .utf8))
        XCTAssertEqual(Int(huge.integerBE(at: 10, as: UInt32.self)), huge.count - 14)
    }

    func testPacketFlagsAndPresentationClock() throws {
        let configuration = try ScrcpyPacketHeader(data: Data([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 27]))
        XCTAssertTrue(configuration.isConfiguration)
        XCTAssertFalse(configuration.isKeyFrame)
        XCTAssertEqual(configuration.size, 27)
        let key = try ScrcpyPacketHeader(data: Data([0x40, 0, 0, 0, 0, 1, 0xe2, 0x40, 0, 0, 1, 0]))
        XCTAssertFalse(key.isConfiguration)
        XCTAssertTrue(key.isKeyFrame)
        XCTAssertEqual(key.presentationMicroseconds, 123456)
        XCTAssertEqual(key.size, 256)
    }

    func testRejectsMalformedOrUnboundedPacketLengths() {
        XCTAssertThrowsError(try ScrcpyPacketHeader(data: Data(repeating: 0, count: 11)))
        XCTAssertThrowsError(try ScrcpyPacketHeader(data: Data(repeating: 0, count: 12)))
        XCTAssertThrowsError(try ScrcpyPacketHeader(data: Data([0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255])))
    }

    func testAnnexBHandlesBothPrefixesAndEmulationPrevention() {
        let bytes = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 4, 0, 0, 0, 1, 0x65, 0, 0, 3, 1, 9])
        XCTAssertEqual(H264AnnexB.nalUnits(in: bytes), [Data([0x67, 1, 2]), Data([0x68, 3, 4]), Data([0x65, 0, 0, 3, 1, 9])])
        XCTAssertTrue(H264AnnexB.nalUnits(in: Data([0, 0, 1])).isEmpty)
        XCTAssertTrue(H264AnnexB.nalUnits(in: Data([0x67, 1, 2])).isEmpty)
    }
}
