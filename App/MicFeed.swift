import AudioToolbox
import CoreAudio
import Foundation

/// Plays the phone's microphone into the PhoneCam driver's hidden "feed" device; the driver
/// loops that straight into the "PhoneCam Microphone" input that video apps record from.
final class MicFeed: @unchecked Sendable {
    // Keep in sync with Driver/PhoneCamMic.c.
    static let micDeviceUID = "PhoneCamMic_UID"
    static let feedDeviceUID = "PhoneCamMicFeed_UID"

    static let sampleRate = 48000.0
    private static let channels = 2
    /// Start playing once this much audio is buffered, and trim back to it when the phone's
    /// clock runs ahead of the Mac's, so the delay stays around 30 ms.
    private static let targetFrames = 1440
    private static let maxFrames = 4800

    private var unit: AudioUnit?
    // Heap-allocated so the lock never moves (Swift may copy a lock stored inline).
    private let lock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    private var ring = [Float](repeating: 0, count: 48000 * 2)
    private var readIndex = 0
    private var available = 0
    private var primed = false

    // MARK: - Devices

    static func deviceID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uidString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uidString) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Whether some app is recording from "PhoneCam Microphone".
    static func isMicInUse() -> Bool {
        guard let device = deviceID(uid: micDeviceUID) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return running != 0
    }

    // MARK: - Playback

    func start() {
        guard unit == nil else { return }
        guard let feed = Self.deviceID(uid: Self.feedDeviceUID) else {
            Log.write("mic: PhoneCam microphone driver not found")
            return
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let newUnit else { return }

        var device = feed
        AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioObjectID>.size))
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * Self.channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * Self.channels), mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            Unmanaged<MicFeed>.fromOpaque(refCon).takeUnretainedValue().render(frames: Int(frames), into: ioData)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(newUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        reset()
        guard AudioUnitInitialize(newUnit) == noErr, AudioOutputUnitStart(newUnit) == noErr else {
            Log.write("mic: couldn't start playback into the PhoneCam microphone")
            AudioComponentInstanceDispose(newUnit)
            return
        }
        unit = newUnit
        Log.write("mic: streaming the phone's microphone")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        reset()
    }

    /// Adds interleaved 16-bit stereo PCM from the phone.
    func push(pcm16 data: Data) {
        let frames = data.count / (2 * Self.channels)
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let capacity = ring.count / Self.channels
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var writeIndex = (readIndex + available) % capacity
            for frame in 0..<frames {
                for channel in 0..<Self.channels {
                    ring[writeIndex * Self.channels + channel] =
                        Float(Int16(littleEndian: samples[frame * Self.channels + channel])) / 32768
                }
                writeIndex = (writeIndex + 1) % capacity
            }
        }
        available += frames
        if available > Self.maxFrames {
            // Drop the oldest audio to stay close to real time.
            let drop = available - Self.targetFrames
            readIndex = (readIndex + drop) % capacity
            available -= drop
        }
    }

    private func reset() {
        os_unfair_lock_lock(lock)
        readIndex = 0
        available = 0
        primed = false
        os_unfair_lock_unlock(lock)
    }

    private func render(frames: Int, into ioData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let ioData, let output = UnsafeMutableAudioBufferListPointer(ioData).first?.mData?
            .assumingMemoryBound(to: Float.self) else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if !primed, available >= Self.targetFrames { primed = true }
        guard primed, available >= frames else {
            // Underrun: play silence and wait to rebuild the cushion.
            primed = false
            output.update(repeating: 0, count: frames * Self.channels)
            return
        }
        let capacity = ring.count / Self.channels
        for frame in 0..<frames {
            for channel in 0..<Self.channels {
                output[frame * Self.channels + channel] = ring[readIndex * Self.channels + channel]
            }
            readIndex = (readIndex + 1) % capacity
        }
        available -= frames
    }
}
