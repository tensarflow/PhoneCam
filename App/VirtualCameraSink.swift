import CoreMedia
import CoreMediaIO
import Foundation

/// Feeds frames into the PhoneCam camera extension through its sink stream.
final class VirtualCameraSink: @unchecked Sendable {
    private let lock = NSLock()
    private var deviceID = CMIOObjectID(0)
    private var streamID = CMIOStreamID(0)
    private var queue: CMSimpleQueue?
    private var accepting = false
    private var lastConnectAttempt = Date.distantPast
    private var stats = (sent: 0, full: 0, failed: 0, lastReport: Date())

    /// Lets frames through until `disconnect()`, so a frame still in flight from a stopped
    /// session can't reconnect the camera.
    func activate() {
        lock.lock()
        accepting = true
        lock.unlock()
    }

    /// Whether this app is currently streaming into the camera.
    var isFeeding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return queue != nil
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
        if queue == nil {
            // The extension may still be loading; don't hammer CMIO on every frame.
            guard Date().timeIntervalSince(lastConnectAttempt) > 1 else { return }
            lastConnectAttempt = Date()
            connectLocked()
        }
        guard let queue else { return }
        if Date().timeIntervalSince(stats.lastReport) > 5 {
            if stats.full > 0 || stats.failed > 0 {
                Log.write("sink: sent=\(stats.sent) dropped=\(stats.full) failed=\(stats.failed)")
            }
            stats = (0, 0, 0, Date())
        }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            stats.full += 1
            return
        }

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: PhoneCamConstants.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        // The queue takes ownership; the extension's consumer releases it.
        let element = Unmanaged.passRetained(sample).toOpaque()
        if CMSimpleQueueEnqueue(queue, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            stats.failed += 1
        } else {
            stats.sent += 1
        }
    }

    /// How many apps are reading the PhoneCam camera, or nil if the camera isn't available.
    func appsUsingCamera() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let device = findDevice() else { return nil }
        var address = propertyAddress(fourCC(PhoneCamConstants.appsUsingCameraCode))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                        &used, &value) == noErr,
              let text = value?.takeRetainedValue() as String? else { return nil }
        return Int(text)
    }

    /// Whether any process is streaming from the PhoneCam camera. Maintained by macOS itself, so it
    /// can't go stale, but it also counts this app's own sink stream while frames are being sent.
    func isRunningSomewhere() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let device = findDevice() else { return false }
        var address = propertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var running: UInt32 = 0
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return running != 0
    }

    /// Sets the text the camera shows while there's no phone picture.
    func setPlaceholderText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let device = findDevice() else { return }
        var address = propertyAddress(fourCC(PhoneCamConstants.placeholderTextCode))
        var value = text as CFString
        let status = CMIOObjectSetPropertyData(device, &address, 0, nil,
                                               UInt32(MemoryLayout<CFString>.size), &value)
        if status != noErr { Log.write("camera: couldn't set placeholder text (\(status))") }
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        if queue != nil { CMIODeviceStopStream(deviceID, streamID) }
        queue = nil
        lastConnectAttempt = .distantPast
    }

    private func connectLocked() {
        guard let device = findDevice() else {
            Log.write("sink: PhoneCam camera device not found")
            return
        }
        guard let sink = findSinkStream(of: device) else {
            Log.write("sink: no sink stream on device \(device)")
            return
        }
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let queueStatus = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard queueStatus == noErr, let newQueue = unmanagedQueue?.takeRetainedValue() else {
            Log.write("sink: CMIOStreamCopyBufferQueue failed (\(queueStatus))")
            return
        }
        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            Log.write("sink: CMIODeviceStartStream failed (\(startStatus))")
            return
        }
        Log.write("sink: connected to device \(device) stream \(sink)")
        deviceID = device
        streamID = sink
        queue = newQueue
    }

    private func findDevice() -> CMIOObjectID? {
        let devices: [CMIOObjectID] = objectList(CMIOObjectID(kCMIOObjectSystemObject),
                                                 selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let wanted = PhoneCamConstants.deviceUUID.uuidString
        return devices.first { stringProperty($0, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == wanted }
    }

    /// The sink is the stream data flows out of the Mac into (direction 0); fall back to the last stream.
    private func findSinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        let streams: [CMIOStreamID] = objectList(device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        let sink = streams.first { stream in
            var address = propertyAddress(CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            var direction: UInt32 = 1
            var used: UInt32 = 0
            CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &direction)
            return direction == 0
        }
        return sink ?? (streams.count > 1 ? streams.last : nil)
    }

    private func fourCC(_ code: String) -> CMIOObjectPropertySelector {
        code.utf8.reduce(0) { $0 << 8 | CMIOObjectPropertySelector($1) }
    }

    private func propertyAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func objectList(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private func stringProperty(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                        &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
