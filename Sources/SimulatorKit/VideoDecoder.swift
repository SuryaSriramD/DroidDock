import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    /// Monotonic host time. Android's presentation clock has a separate epoch.
    public let receivedAt: TimeInterval
    public let decodedAt: TimeInterval
    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, receivedAt: TimeInterval, decodedAt: TimeInterval) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.receivedAt = receivedAt
        self.decodedAt = decodedAt
    }
}

/// One decoder per bridge, used exclusively on its video receive queue.
/// Synchronous decompression bounds the decoder to one frame in flight; the view
/// must coalesce presentation to its latest frame instead of building a UI queue.
final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let onFrame: @Sendable (DecodedFrame) -> Void

    init(onFrame: @escaping @Sendable (DecodedFrame) -> Void) { self.onFrame = onFrame }

    deinit { invalidate() }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    func decode(_ data: Data, header: ScrcpyPacketHeader, receivedAt: TimeInterval) throws {
        let nals = H264AnnexB.nalUnits(in: data)
        guard !nals.isEmpty else { throw ScrcpyError.protocolViolation("H.264 packet has no Annex B NAL units.") }
        var parametersChanged = false
        for nal in nals {
            switch nal.first.map({ $0 & 0x1f }) {
            case 7: if sps != nal { sps = nal; parametersChanged = true }
            case 8: if pps != nal { pps = nal; parametersChanged = true }
            default: break
            }
        }
        // Rotation restarts Android's encoder and sends a new SPS/PPS. The new
        // CVPixelBuffer dimensions drive rendering and hit-testing atomically.
        if parametersChanged || session == nil, let sps, let pps { try configure(sps: sps, pps: pps) }
        if header.isConfiguration { return }
        guard let session, let format else { throw ScrcpyError.protocolViolation("Video frame arrived before H.264 configuration.") }
        var avcc = Data()
        for nal in nals where nal.first.map({ ($0 & 0x1f) != 7 && ($0 & 0x1f) != 8 }) == true {
            avcc.appendBE(UInt32(nal.count))
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block), "Allocate video buffer")
        guard let block else { throw ScrcpyError.decode("Could not allocate a compressed frame.") }
        try avcc.withUnsafeBytes { raw in
            try check(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                                   offsetIntoDestination: 0, dataLength: avcc.count), "Copy compressed packet")
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: header.presentationMicroseconds, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = avcc.count
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Create video sample")
        guard let sample else { throw ScrcpyError.decode("Could not create a video sample.") }
        var callbackError: OSStatus = noErr
        let callback = onFrame
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
                callbackError = status
                guard status == noErr, let image else { return }
                callback(DecodedFrame(pixelBuffer: image, presentationTime: pts, receivedAt: receivedAt,
                                      decodedAt: ProcessInfo.processInfo.systemUptime))
            }
        try check(status, "Decode H.264 frame")
        try check(callbackError, "Output H.264 frame")
    }

    private func configure(sps: Data, pps: Data) throws {
        invalidate()
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        try check(status, "Read H.264 parameter sets")
        guard let description else { throw ScrcpyError.decode("Missing H.264 video format.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 8192, dimensions.height <= 8192 else {
            throw ScrcpyError.protocolViolation("Unsupported video dimensions.")
        }
        let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session), "Create VideoToolbox decoder")
        format = description
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw ScrcpyError.decode("\(operation) failed (VideoToolbox \(status)).") }
    }
}

enum H264AnnexB {
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var nalStart: Int?
        var index = 0
        while index + 2 < bytes.count {
            var prefixLength = 0
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { prefixLength = 3 }
                else if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 { prefixLength = 4 }
            }
            if prefixLength > 0 {
                if let start = nalStart, index > start { units.append(Data(bytes[start..<index])) }
                nalStart = index + prefixLength
                index += prefixLength
            } else { index += 1 }
        }
        if let start = nalStart, start < bytes.count { units.append(Data(bytes[start..<bytes.count])) }
        return units
    }
}
