import CoreMediaIO
import CoreText
import Foundation
import IOKit.audio
import os.log

private let log = Logger(subsystem: PhoneCamConstants.extensionBundleID, category: "camera")

/// Host time in nanoseconds, the clock CMIO streams are stamped with.
private func hostTimeNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

// MARK: - Provider

final class PhoneCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: PhoneCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = PhoneCamDeviceSource(localizedName: PhoneCamConstants.cameraName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "ARTEQ"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

/// One camera with two streams: a source that video apps read, and a sink the
/// PhoneCam menu bar app writes decoded phone frames into. Frames arriving on
/// the sink are forwarded to the source; with no phone, a placeholder is shown.
final class PhoneCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: PhoneCamStreamSource!
    private var sinkStream: PhoneCamSinkSource!

    private let queue = DispatchQueue(label: "PhoneCam.frames", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    private var consumePending = false
    private var lastPhoneFrameTime: UInt64 = 0
    private var lastPlaceholderTime: UInt64 = 0
    private var placeholder: CVPixelBuffer?
    private var placeholderText = PhoneCamConstants.defaultPlaceholderText
    private var stats = (consumed: 0, empty: 0, lastError: "", lastReport: UInt64(0))

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: PhoneCamConstants.deviceUUID,
                                     legacyDeviceID: nil, source: self)

        var description: CMFormatDescription!
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: PhoneCamConstants.width, height: PhoneCamConstants.height,
                                       extensions: nil, formatDescriptionOut: &description)
        let frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration, validFrameDurations: nil)

        sourceStream = PhoneCamStreamSource(localizedName: "PhoneCam Video", streamID: UUID(),
                                            streamFormat: format, deviceSource: self)
        sinkStream = PhoneCamSinkSource(localizedName: "PhoneCam Input", streamID: UUID(),
                                        streamFormat: format, deviceSource: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
        placeholder = makePlaceholder(text: placeholderText)
    }

    private static let appsUsingCameraProperty =
        CMIOExtensionProperty(rawValue: "4cc_\(PhoneCamConstants.appsUsingCameraCode)_glob_0000")
    private static let placeholderTextProperty =
        CMIOExtensionProperty(rawValue: "4cc_\(PhoneCamConstants.placeholderTextCode)_glob_0000")

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, Self.appsUsingCameraProperty, Self.placeholderTextProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "PhoneCam"
        }
        if properties.contains(Self.appsUsingCameraProperty) {
            let count = queue.sync { sourceClients }
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: "\(count)" as NSString),
                                              forProperty: Self.appsUsingCameraProperty)
        }
        if properties.contains(Self.placeholderTextProperty) {
            let text = queue.sync { placeholderText }
            let writable = CMIOExtensionPropertyAttributes<AnyObject>(minValue: nil, maxValue: nil, validValues: nil,
                                                                     readOnly: false)
            deviceProperties.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: text as NSString, attributes: writable),
                                              forProperty: Self.placeholderTextProperty)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        guard let text = deviceProperties.propertiesDictionary[Self.placeholderTextProperty]?.value as? String else { return }
        queue.async {
            guard text != self.placeholderText else { return }
            self.placeholderText = text
            self.placeholder = self.makePlaceholder(text: text)
        }
    }

    // MARK: Stream lifecycle

    func sourceStarted() {
        queue.async { self.sourceClients += 1; self.sourceClientsChanged() }
    }

    func sourceStopped() {
        queue.async { self.sourceClients = max(0, self.sourceClients - 1); self.sourceClientsChanged() }
    }

    private func sourceClientsChanged() {
        updateTimer()
        // Clients cache property values, so the app only sees a new count when it's announced.
        device.notifyPropertiesChanged([
            Self.appsUsingCameraProperty: CMIOExtensionPropertyState<AnyObject>(value: "\(sourceClients)" as NSString),
        ])
    }

    func sinkStarted(_ client: CMIOExtensionClient) {
        queue.async { self.sinkClient = client; self.updateTimer() }
    }

    func sinkStopped() {
        queue.async { self.sinkClient = nil; self.updateTimer() }
    }

    private func updateTimer() {
        let needed = sourceClients > 0 || sinkClient != nil
        if needed, timer == nil {
            // Poll the sink at twice the frame rate so a new phone frame waits at most ~16 ms.
            let newTimer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            newTimer.schedule(deadline: .now(), repeating: 1.0 / Double(PhoneCamConstants.frameRate * 2),
                              leeway: .milliseconds(1))
            newTimer.setEventHandler { [weak self] in self?.tick() }
            newTimer.resume()
            timer = newTimer
        } else if !needed, let runningTimer = timer {
            runningTimer.cancel()
            timer = nil
        }
    }

    private func tick() {
        let now = hostTimeNanoseconds()
        if let client = sinkClient, !consumePending {
            consumePending = true
            sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, error in
                guard let self else { return }
                self.queue.async {
                    self.consumePending = false
                    if let buffer {
                        self.stats.consumed += 1
                        self.forwardPhoneFrame(buffer, sequence: sequence)
                    } else {
                        self.stats.empty += 1
                        if let error { self.stats.lastError = error.localizedDescription }
                    }
                }
            }
        }
        if now &- stats.lastReport > 5 * UInt64(NSEC_PER_SEC) {
            log.debug("""
                sources=\(self.sourceClients, privacy: .public) sink=\(self.sinkClient != nil, privacy: .public) \
                pending=\(self.consumePending, privacy: .public) consumed=\(self.stats.consumed, privacy: .public) \
                empty=\(self.stats.empty, privacy: .public) error=\(self.stats.lastError, privacy: .public)
                """)
            stats = (0, 0, "", now)
        }

        // Keep apps fed with a placeholder while no phone frames arrive.
        let frameInterval = UInt64(NSEC_PER_SEC) / UInt64(PhoneCamConstants.frameRate)
        if sourceClients > 0, now &- lastPhoneFrameTime > UInt64(NSEC_PER_SEC),
           now &- lastPlaceholderTime >= frameInterval, let placeholder {
            lastPlaceholderTime = now
            send(placeholder, at: now)
        }
    }

    private func forwardPhoneFrame(_ buffer: CMSampleBuffer, sequence: UInt64) {
        let now = hostTimeNanoseconds()
        sinkStream.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
        guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        lastPhoneFrameTime = now
        if sourceClients > 0 { send(image, at: now) }
    }

    private func send(_ image: CVPixelBuffer, at hostTime: UInt64) {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: PhoneCamConstants.frameRate),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostTime),
                                                                      timescale: CMTimeScale(NSEC_PER_SEC)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                              formatDescription: format, sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            log.error("Could not wrap frame: \(status)")
            return
        }
        sourceStream.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }

    private func makePlaceholder(text message: String) -> CVPixelBuffer? {
        let width = Int(PhoneCamConstants.width), height = Int(PhoneCamConstants.height)
        let attributes: NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return buffer }

        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: message, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica Neue" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.75, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
                                       y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return buffer
    }
}

// MARK: - Streams

/// The stream video apps read from.
final class PhoneCamStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private unowned let deviceSource: PhoneCamDeviceSource

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
         deviceSource: PhoneCamDeviceSource) {
        self.streamFormat = streamFormat
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource.sourceStarted() }

    func stopStream() throws { deviceSource.sourceStopped() }
}

/// The stream the PhoneCam app writes decoded phone frames into.
final class PhoneCamSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private unowned let deviceSource: PhoneCamDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
         deviceSource: PhoneCamDeviceSource) {
        self.streamFormat = streamFormat
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: PhoneCamConstants.frameRate)
        }
        // A one-frame queue keeps latency minimal; the app drops frames when it's full.
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { deviceSource.sinkStarted(client) }
    }

    func stopStream() throws { deviceSource.sinkStopped() }
}
