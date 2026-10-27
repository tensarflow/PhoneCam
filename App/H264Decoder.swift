import CoreMedia
import Foundation
import VideoToolbox

/// Hardware-decodes an Annex B H.264 stream into IOSurface-backed BGRA frames.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    deinit { invalidate() }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    func decode(_ packet: Data) {
        var frameNALs: [Data] = []
        var parameterSetsChanged = false
        for nal in Self.splitAnnexB(packet) {
            switch nal.first.map({ $0 & 0x1F }) {
            case 7?:
                if nal != sps { sps = nal; parameterSetsChanged = true }
            case 8?:
                if nal != pps { pps = nal; parameterSetsChanged = true }
            default:
                frameNALs.append(nal)
            }
        }
        if parameterSetsChanged || session == nil { rebuildSession() }
        guard !frameNALs.isEmpty, let session, let formatDescription else { return }

        // VideoToolbox wants length-prefixed (AVCC) NAL units instead of start codes.
        var avcc = Data()
        for nal in frameNALs {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                                                 flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                Log.write("decoder: frame failed (\(status))")
                return
            }
            self?.onFrame?(imageBuffer)
        }
    }

    private func rebuildSession() {
        guard let sps, let pps else { return }
        invalidate()

        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            Log.write("decoder: bad SPS/PPS (\(status))")
            return
        }
        formatDescription = description

        // Decode at the stream's own size; FrameTransformer rotates and scales afterwards.
        let outputAttributes: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                                        decoderSpecification: nil, imageBufferAttributes: outputAttributes,
                                                        outputCallback: nil, decompressionSessionOut: &newSession)
        Log.write("decoder: session created (\(createStatus)), \(CMVideoFormatDescriptionGetDimensions(description))")
        if let newSession {
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        session = newSession
    }

    /// Splits an Annex B byte stream on 3- or 4-byte start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let codeStart = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                starts.append((codeStart, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].codeStart : bytes.count
            return end > start.nalStart ? Data(bytes[start.nalStart..<end]) : nil
        }
    }
}
