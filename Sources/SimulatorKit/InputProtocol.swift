import Foundation

/// Input messages for the pinned scrcpy 3.3.3 control protocol.
public enum BridgeInput: Sendable {
    case touch(action: UInt8, x: Int, y: Int, width: Int, height: Int)
    case key(code: UInt32, down: Bool)
    case text(String)
    case scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double)
    case rotate
    /// Copy text to Android and invoke Android's paste action.
    case clipboard(String)
    /// Request the current Android text clipboard without sending Copy/Cut keys.
    case getClipboard

    var isMove: Bool {
        if case .touch(let action, _, _, _, _) = self { return action == 2 }
        return false
    }
    public var isRelease: Bool {
        switch self {
        case .key(_, let down): return !down
        case .touch(let action, _, _, _, _): return action == 1 || action == 3
        default: return false
        }
    }
}

/// Wire fields are big endian. Layout is pinned to Genymobile/scrcpy v3.3.3,
/// app/src/control_msg.c and server/.../control/ControlMessageReader.java.
public enum ScrcpyControlEncoder {
    public static func encode(_ input: BridgeInput) -> Data {
        var data = Data()
        switch input {
        case let .key(code, down):
            data.append(contentsOf: [0, down ? 0 : 1])
            data.appendBE(code)
            data.appendBE(UInt32(0)) // Repeat count
            data.appendBE(UInt32(0)) // Android meta state
        case let .touch(action, x, y, width, height):
            data.append(contentsOf: [2, action])
            data.appendBE(UInt64.max - 1) // Generic finger, not a mouse pointer.
            appendPosition(to: &data, x: x, y: y, width: width, height: height)
            let pressure: UInt16 = action == 1 || action == 3 ? 0 : .max
            data.appendBE(pressure)
            data.appendBE(UInt32(0)) // actionButton and buttons are zero for touch.
            data.appendBE(UInt32(0))
        case let .text(text):
            data.append(1)
            appendString(text, maximumBytes: 300, to: &data)
        case let .scroll(x, y, width, height, horizontal, vertical):
            data.append(3)
            appendPosition(to: &data, x: x, y: y, width: width, height: height)
            data.appendBE(UInt16(bitPattern: scrollFixedPoint(horizontal)))
            data.appendBE(UInt16(bitPattern: scrollFixedPoint(vertical)))
            data.appendBE(UInt32(0))
        case .rotate:
            data.append(11)
        case let .clipboard(text):
            data.append(9)
            data.appendBE(UInt64(0)) // No clipboard acknowledgement requested.
            data.append(1) // Paste after setting the clipboard.
            appendString(text, maximumBytes: (1 << 18) - 14, to: &data)
        case .getClipboard:
            data.append(contentsOf: [8, 0])
        }
        return data
    }

    private static func appendPosition(to data: inout Data, x: Int, y: Int, width: Int, height: Int) {
        let w = max(1, min(Int(UInt16.max), width))
        let h = max(1, min(Int(UInt16.max), height))
        data.appendBE(UInt32(max(0, min(w - 1, x))))
        data.appendBE(UInt32(max(0, min(h - 1, y))))
        data.appendBE(UInt16(w))
        data.appendBE(UInt16(h))
    }

    private static func scrollFixedPoint(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-32768, min(32767, (value / 16 * 32768).rounded(.towardZero))))
    }

    private static func appendString(_ string: String, maximumBytes: Int, to data: inout Data) {
        var utf8 = Data(string.utf8.prefix(maximumBytes))
        // The protocol limits bytes, not characters; never split a UTF-8 scalar.
        while !utf8.isEmpty && String(data: utf8, encoding: .utf8) == nil { utf8.removeLast() }
        data.appendBE(UInt32(utf8.count))
        data.append(utf8)
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func integerBE<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        // Byte assembly supports unaligned Data and slices without unsafe loads.
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value = (value << 8) | T(self[startIndex + offset + i]) }
        return value
    }
}

public struct ScrcpyPacketHeader: Sendable {
    public static let maximumPacketSize = 8 * 1024 * 1024
    public let isConfiguration: Bool
    public let isKeyFrame: Bool
    public let presentationMicroseconds: Int64
    public let size: Int

    public init(data: Data) throws {
        guard data.count == 12 else { throw ScrcpyError.protocolViolation("Video packet header must be 12 bytes.") }
        let flags: UInt64 = data.integerBE(at: 0)
        let length: UInt32 = data.integerBE(at: 8)
        guard length > 0 && length <= Self.maximumPacketSize else {
            throw ScrcpyError.protocolViolation("Invalid video packet length: \(length).")
        }
        isConfiguration = flags & (1 << 63) != 0
        isKeyFrame = flags & (1 << 62) != 0
        presentationMicroseconds = Int64(flags & ((1 << 62) - 1))
        size = Int(length)
    }
}
