import AudioToolbox
import Foundation

/// Decodes 20 ms, 48 kHz mono Opus packets (from the PhoneCam Mic app) with AudioToolbox's Opus decoder.
final class OpusDecoder {
    static let frameSize = 960

    private var converter: AudioConverterRef?
    private let packet = UnsafeMutableRawPointer.allocate(byteCount: 4000, alignment: 16)
    private var packetSize = 0
    private var consumed = false
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init?() {
        var input = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSize),
                                                mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr else {
            Log.write("bluetooth: no Opus decoder (\(status))")
            return nil
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packet.deallocate()
        description.deallocate()
    }

    func decode(_ data: Data) -> [Float]? {
        guard let converter, data.count <= 4000 else { return nil }
        data.copyBytes(to: packet.assumingMemoryBound(to: UInt8.self), count: data.count)
        packetSize = data.count
        consumed = false

        var samples = [Float](repeating: 0, count: Self.frameSize)
        var frames = UInt32(Self.frameSize)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count),
                                                             mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, packets, data, descriptions, user in
                let decoder = Unmanaged<OpusDecoder>.fromOpaque(user!).takeUnretainedValue()
                guard !decoder.consumed else {
                    packets.pointee = 0
                    return 1 // no more input for this call
                }
                decoder.consumed = true
                packets.pointee = 1
                data.pointee.mNumberBuffers = 1
                data.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(decoder.packetSize),
                                                    mData: decoder.packet)
                decoder.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                           mDataByteSize: UInt32(decoder.packetSize))
                descriptions?.pointee = decoder.description
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == 1, frames > 0 else { return nil }
        return Array(samples.prefix(Int(frames)))
    }
}
