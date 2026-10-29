// Bluetooth mic spike, Mac side: advertises over BLE, accepts an L2CAP channel from the phone,
// decodes its Opus packets and plays them into "PhoneCam Microphone". Logs link stats to CSV and
// taps Right Option (FluidVoice's shortcut) when the phone's Talk button is used.
// See Docs/bluetooth-mic-spec.md.

import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreBluetooth

let serviceUUID = CBUUID(string: "7A3F0001-5C1E-4B7E-9B1A-2F6D8C4E0A11")
let psmCharacteristicUUID = CBUUID(string: "7A3F0002-5C1E-4B7E-9B1A-2F6D8C4E0A11")

enum Message: UInt8 {
    case hello = 0x01, audio = 0x10, talkDown = 0x20, talkUp = 0x21, ping = 0x40, pong = 0x41
}

let sampleRate = 48000.0
let frameSize = 960 // 20 ms

func now() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Log

enum Log {
    static let directory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BTMicSpike")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let stamp: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }()
    private static let handle: FileHandle? = {
        let url = directory.appendingPathComponent("spike.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func write(_ text: String) {
        let line = "\(Date()) \(text)\n"
        handle?.write(Data(line.utf8))
        print(line, terminator: "")
    }
}

// MARK: - Opus decoding

/// Decodes one 20 ms Opus packet at a time with AudioToolbox's built-in Opus decoder.
final class OpusDecoder {
    private var converter: AudioConverterRef?
    private let packet = UnsafeMutableRawPointer.allocate(byteCount: 4000, alignment: 16)
    private var packetSize = 0
    private var consumed = false
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init?() {
        var input = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0,
                                                mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr else {
            Log.write("opus: AudioConverterNew failed \(status)")
            return nil
        }
    }

    func decode(_ data: Data) -> [Float]? {
        guard let converter, data.count <= 4000 else { return nil }
        data.copyBytes(to: packet.assumingMemoryBound(to: UInt8.self), count: data.count)
        packetSize = data.count
        consumed = false

        var samples = [Float](repeating: 0, count: frameSize)
        var frames = UInt32(frameSize)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count),
                                                             mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, packets, data, descriptions, user in
                let decoder = Unmanaged<OpusDecoder>.fromOpaque(user!).takeUnretainedValue()
                if decoder.consumed {
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

// MARK: - Playback

/// Jitter buffer + output unit. Plays mono audio as stereo into a Core Audio output device
/// (PhoneCam's hidden feed device, which loops into "PhoneCam Microphone", or the speakers).
final class Player: @unchecked Sendable {
    static let feedDeviceUID = "PhoneCamMicFeed_UID"

    var targetFrames = 4800  // 100 ms cushion
    var maxFrames = 12000    // drop the oldest audio beyond 250 ms

    private var unit: AudioUnit?
    private var lock = os_unfair_lock()
    private var ring = [Float](repeating: 0, count: 48000 * 2)
    private var readIndex = 0
    private var available = 0
    private var primed = false
    private(set) var underruns = 0
    private(set) var trimmed = 0

    var bufferedMilliseconds: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Double(available) / sampleRate * 1000
    }

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

    static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device != kAudioObjectUnknown ? device : nil
    }

    /// Returns a description of the device it plays into, or nil.
    func start(toPhoneCam: Bool) -> String? {
        stop()
        let target = toPhoneCam ? Self.deviceID(uid: Self.feedDeviceUID) : Self.defaultOutput()
        guard var device = target else {
            Log.write("player: \(toPhoneCam ? "PhoneCam microphone driver" : "default output") not found")
            return nil
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let newUnit else { return nil }
        AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioObjectID>.size))
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData in
            Unmanaged<Player>.fromOpaque(refCon).takeUnretainedValue().render(frames: Int(frames), into: ioData)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(newUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        reset()
        guard AudioUnitInitialize(newUnit) == noErr, AudioOutputUnitStart(newUnit) == noErr else {
            AudioComponentInstanceDispose(newUnit)
            Log.write("player: couldn't start output unit")
            return nil
        }
        unit = newUnit
        return toPhoneCam ? "PhoneCam Microphone" : "Mac speakers"
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        available = 0
        primed = false
        os_unfair_lock_unlock(&lock)
    }

    func push(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let capacity = ring.count
        var writeIndex = (readIndex + available) % capacity
        for sample in samples {
            ring[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        available += samples.count
        if available > maxFrames {
            let drop = available - targetFrames
            readIndex = (readIndex + drop) % capacity
            available -= drop
            trimmed += 1
        }
    }

    private func render(frames: Int, into ioData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let ioData, let output = UnsafeMutableAudioBufferListPointer(ioData).first?.mData?
            .assumingMemoryBound(to: Float.self) else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if !primed, available >= targetFrames { primed = true }
        guard primed, available >= frames else {
            if primed { underruns += 1 }
            primed = false
            output.update(repeating: 0, count: frames * 2)
            return
        }
        let capacity = ring.count
        for frame in 0..<frames {
            let sample = ring[readIndex]
            output[frame * 2] = sample
            output[frame * 2 + 1] = sample
            readIndex = (readIndex + 1) % capacity
        }
        available -= frames
    }
}

// MARK: - Right Option

enum Hotkey {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Posts Right Option as a real keyboard would: a flagsChanged event with keycode 61.
    static func rightOption(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 61, keyDown: down) else { return }
        event.type = .flagsChanged
        // Down: Alternate (0x80000) | right-alt device bit (0x40) | non-coalesced (0x100). Up: 0x100.
        event.flags = CGEventFlags(rawValue: down ? 0x80140 : 0x100)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Stats

struct Stats {
    var connectedAt: Double?
    var phone = ""
    var packets = 0
    var bytes = 0
    var lost = 0
    var outOfOrder = 0
    var decodeErrors = 0
    var jitter = 0.0       // RFC 3550 style, ms
    var lastSequence: Int?
    var lastTransit: Double?
    var lastArrival: Double?
    var maxGap = 0.0       // largest gap between packets this second, ms
    var rtt: Double?
    var talks = 0
    var disconnects = 0
}

// MARK: - Bluetooth link

final class Link: NSObject, CBPeripheralManagerDelegate, StreamDelegate {
    var onChange: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onTalk: ((Bool) -> Void)?
    var onConnected: ((Bool) -> Void)?

    private(set) var state = "Starting Bluetooth…"
    private(set) var psm: CBL2CAPPSM?
    var encrypted = true
    private var manager: CBPeripheralManager!
    private var channel: CBL2CAPChannel?
    private var inbox = Data()
    var stats = Stats()

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func republish() {
        manager.stopAdvertising()
        manager.removeAllServices()
        if let psm { manager.unpublishL2CAPChannel(psm) }
        psm = nil
        closeChannel()
        if manager.state == .poweredOn { manager.publishL2CAPChannel(withEncryption: encrypted) }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Log.write("bt: state \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn:
            peripheral.publishL2CAPChannel(withEncryption: encrypted)
            state = "Publishing L2CAP channel…"
        case .unauthorized:
            state = "Bluetooth not allowed: System Settings → Privacy & Security → Bluetooth"
        case .poweredOff:
            state = "Bluetooth is off"
        default:
            state = "Bluetooth state \(peripheral.state.rawValue)"
        }
        onChange?()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            state = "Publish failed: \(error.localizedDescription)"
            Log.write("bt: publish failed \(error)")
            onChange?()
            return
        }
        psm = PSM
        Log.write("bt: published L2CAP PSM \(PSM) (encrypted: \(encrypted))")
        let characteristic = CBMutableCharacteristic(type: psmCharacteristicUUID, properties: [.read], value: nil,
                                                     permissions: encrypted ? [.readEncryptionRequired] : [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            state = "Adding service failed: \(error.localizedDescription)"
            onChange?()
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                     CBAdvertisementDataLocalNameKey: "PhoneCam"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        state = error.map { "Advertising failed: \($0.localizedDescription)" } ?? "Waiting for the phone (PSM \(psm ?? 0))"
        Log.write("bt: \(state)")
        onChange?()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let psm else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        request.value = Data([UInt8(psm & 0xff), UInt8(psm >> 8)])
        peripheral.respond(to: request, withResult: .success)
        Log.write("bt: phone read the PSM")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            Log.write("bt: channel open failed \(error)")
            state = "Channel failed: \(error.localizedDescription)"
            onChange?()
            return
        }
        guard let channel else { return }
        closeChannel()
        self.channel = channel
        inbox.removeAll()
        stats = Stats(disconnects: stats.disconnects)
        stats.connectedAt = now()
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        state = "Connected"
        Log.write("bt: channel opened from \(channel.peer?.identifier.uuidString ?? "?")")
        // As a peripheral, macOS asks for a slow connection by default, which caps throughput
        // well below 32 kbit/s. Ask for the shortest interval.
        if let central = channel.peer as? CBCentral {
            manager.setDesiredConnectionLatency(.low, for: central)
            Log.write("bt: asked for low latency (central max update length \(central.maximumUpdateValueLength))")
        } else {
            Log.write("bt: peer isn't a CBCentral, can't set latency")
        }
        onConnected?(true)
        onChange?()
    }

    var isConnected: Bool { channel != nil }

    private func closeChannel() {
        guard let channel else { return }
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        self.channel = nil
        onConnected?(false)
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                inbox.append(buffer, count: count)
            }
            parse()
        case .endEncountered, .errorOccurred:
            Log.write("bt: channel closed (\(event == .endEncountered ? "end" : "error: \(stream.streamError?.localizedDescription ?? "?")"))")
            stats.disconnects += 1
            closeChannel()
            state = "Disconnected, waiting for the phone"
            onChange?()
        default:
            break
        }
    }

    private func parse() {
        while inbox.count >= 3 {
            let start = inbox.startIndex
            let length = Int(inbox[start + 1]) << 8 | Int(inbox[start + 2])
            guard inbox.count >= 3 + length else { return }
            let type = inbox[start]
            let payload = inbox.subdata(in: (start + 3)..<(start + 3 + length))
            inbox.removeSubrange(start..<(start + 3 + length))
            handle(type: type, payload: payload)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch Message(rawValue: type) {
        case .hello:
            stats.phone = String(decoding: payload.dropFirst(), as: UTF8.self)
            Log.write("bt: hello from \(stats.phone), protocol \(payload.first ?? 0)")
            onChange?()
        case .audio:
            guard payload.count > 6 else { return }
            let bytes = [UInt8](payload.prefix(6))
            let sequence = Int(bytes[0]) << 8 | Int(bytes[1])
            let phoneTime = Double(UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5]))
            let arrival = now() * 1000
            stats.packets += 1
            stats.bytes += payload.count + 3
            if let last = stats.lastSequence {
                let delta = (sequence - last + 65536) % 65536
                if delta == 0 || delta > 32768 {
                    stats.outOfOrder += 1
                    return
                }
                if delta > 1 {
                    stats.lost += delta - 1
                    // Keep timing: fill the gap with silence (no Opus PLC through AudioToolbox).
                    for _ in 0..<min(delta - 1, 10) { onAudio?(Data()) }
                }
            }
            stats.lastSequence = sequence
            let transit = arrival - phoneTime
            if let lastTransit = stats.lastTransit {
                // Phone clock wraps at 2^32 ms; ignore the jump when it does.
                let difference = abs(transit - lastTransit)
                if difference < 10_000 { stats.jitter += (difference - stats.jitter) / 16 }
            }
            stats.lastTransit = transit
            if let lastArrival = stats.lastArrival { stats.maxGap = max(stats.maxGap, arrival - lastArrival) }
            stats.lastArrival = arrival
            onAudio?(payload.subdata(in: (payload.startIndex + 6)..<payload.endIndex))
        case .talkDown:
            stats.talks += 1
            onTalk?(true)
        case .talkUp:
            onTalk?(false)
        case .pong:
            guard payload.count == 8 else { return }
            let sent = payload.withUnsafeBytes { Double(bitPattern: UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))) }
            stats.rtt = (now() - sent) * 1000
        default:
            break
        }
    }

    func ping() {
        guard let output = channel?.outputStream, output.hasSpaceAvailable else { return }
        var frame = [Message.ping.rawValue, 0, 8]
        withUnsafeBytes(of: now().bitPattern.bigEndian) { frame.append(contentsOf: $0) }
        output.write(frame, maxLength: frame.count)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let encryptedBox = NSButton(checkboxWithTitle: "Require encryption (pairing)", target: nil, action: nil)
    private let phoneCamBox = NSButton(checkboxWithTitle: "Play into PhoneCam Microphone (off: Mac speakers)", target: nil, action: nil)
    private let recordBox = NSButton(checkboxWithTitle: "Record received audio to WAV", target: nil, action: nil)
    private let hotkeyBox = NSButton(checkboxWithTitle: "Phone Talk button taps Right Option", target: nil, action: nil)
    private let bufferPopup = NSPopUpButton()

    private let link = Link()
    private let player = Player()
    private var decoder = OpusDecoder()
    private var output: String?
    private var wav: AVAudioFile?
    private var csv: FileHandle?
    private var lastPackets = 0
    private var lastBytes = 0
    private var lastUnderruns = 0
    private var lastLost = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("app: started")
        buildWindow()
        output = player.start(toPhoneCam: true)
        link.onChange = { [weak self] in self?.refresh() }
        link.onAudio = { [weak self] packet in self?.received(packet) }
        link.onTalk = { [weak self] down in self?.talk(down) }
        link.onConnected = { [weak self] connected in
            guard let self else { return }
            player.reset()
            decoder = OpusDecoder()
            if connected { openCSV() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if decoder == nil { Log.write("opus: no decoder available") }
        // `open BTMicSpike.app --args --record` records from launch, for scripted tests.
        if CommandLine.arguments.contains("--record") {
            recordBox.state = .on
            recordChanged()
        }
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        wav = nil // finalizes the WAV header
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bluetooth Mic Spike"
        statusLabel.font = .boldSystemFont(ofSize: 14)
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.maximumNumberOfLines = 0

        encryptedBox.state = .on
        encryptedBox.target = self
        encryptedBox.action = #selector(encryptionChanged)
        phoneCamBox.state = .on
        phoneCamBox.target = self
        phoneCamBox.action = #selector(outputChanged)
        recordBox.target = self
        recordBox.action = #selector(recordChanged)
        hotkeyBox.state = .on
        hotkeyBox.target = self
        hotkeyBox.action = #selector(hotkeyChanged)

        bufferPopup.addItems(withTitles: ["Buffer 60 ms", "Buffer 100 ms", "Buffer 150 ms", "Buffer 250 ms"])
        bufferPopup.selectItem(at: 1)
        bufferPopup.target = self
        bufferPopup.action = #selector(bufferChanged)

        let tapButton = NSButton(title: "Tap Right Option in 3 s", target: self, action: #selector(testTap))
        let logsButton = NSButton(title: "Show logs", target: self, action: #selector(showLogs))
        let buttons = NSStackView(views: [tapButton, logsButton, bufferPopup])
        let stack = NSStackView(views: [statusLabel, statsLabel, encryptedBox, phoneCamBox, recordBox, hotkeyBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func received(_ packet: Data) {
        guard !packet.isEmpty else {
            player.push([Float](repeating: 0, count: frameSize))
            return
        }
        guard let samples = decoder?.decode(packet) else {
            link.stats.decodeErrors += 1
            return
        }
        player.push(samples)
        if let wav, let buffer = AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try? wav.write(from: buffer)
        }
    }

    private func talk(_ down: Bool) {
        Log.write("talk: \(down ? "down" : "up")")
        guard hotkeyBox.state == .on else { return }
        if !Hotkey.isTrusted {
            Hotkey.requestTrust()
            return
        }
        Hotkey.rightOption(down: down)
    }

    private func openCSV() {
        let url = Log.directory.appendingPathComponent("stats-\(Log.stamp).csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(
                "time,connected_s,packets_per_s,kbps,lost_total,lost_per_s,jitter_ms,max_gap_ms,underruns_per_s,trims_total,buffer_ms,rtt_ms,decode_errors,disconnects\n".utf8))
        }
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
        lastPackets = 0
        lastBytes = 0
        lastLost = 0
        Log.write("stats: writing \(url.path)")
    }

    private func tick() {
        link.ping()
        refresh()
        guard link.isConnected, let connectedAt = link.stats.connectedAt else { return }
        let stats = link.stats
        let underruns = player.underruns
        let line = String(format: "%@,%.0f,%d,%.1f,%d,%d,%.1f,%.0f,%d,%d,%.0f,%@,%d,%d\n",
                          ISO8601DateFormatter().string(from: Date()), now() - connectedAt,
                          stats.packets - lastPackets, Double(stats.bytes - lastBytes) * 8 / 1000,
                          stats.lost, stats.lost - lastLost, stats.jitter, stats.maxGap,
                          underruns - lastUnderruns, player.trimmed, player.bufferedMilliseconds,
                          stats.rtt.map { String(format: "%.0f", $0) } ?? "", stats.decodeErrors, stats.disconnects)
        csv?.write(Data(line.utf8))
        lastPackets = stats.packets
        lastBytes = stats.bytes
        lastLost = stats.lost
        lastUnderruns = underruns
        link.stats.maxGap = 0
    }

    private func refresh() {
        statusLabel.stringValue = link.state + (link.stats.phone.isEmpty || !link.isConnected ? "" : " — \(link.stats.phone)")
        let stats = link.stats
        let connected = stats.connectedAt.map { Int(now() - $0) } ?? 0
        let expected = stats.packets + stats.lost
        statsLabel.stringValue = """
        Output:        \(output ?? "none (driver/device missing)")
        Decoder:       \(decoder == nil ? "unavailable" : "AudioToolbox Opus")
        Connected:     \(connected / 60)m \(connected % 60)s   disconnects: \(stats.disconnects)
        Packets:       \(stats.packets)   lost: \(stats.lost) (\(expected > 0 ? String(format: "%.2f", Double(stats.lost) * 100 / Double(expected)) : "0")%)   out of order: \(stats.outOfOrder)
        Jitter:        \(String(format: "%.1f", stats.jitter)) ms   RTT: \(stats.rtt.map { String(format: "%.0f ms", $0) } ?? "–")
        Buffer:        \(String(format: "%.0f", player.bufferedMilliseconds)) ms   underruns: \(player.underruns)   trims: \(player.trimmed)
        Decode errors: \(stats.decodeErrors)   Talk presses: \(stats.talks)
        Accessibility: \(Hotkey.isTrusted ? "allowed" : "not allowed (needed for Right Option)")
        """
    }

    @objc private func encryptionChanged() {
        link.encrypted = encryptedBox.state == .on
        link.republish()
    }

    @objc private func outputChanged() {
        output = player.start(toPhoneCam: phoneCamBox.state == .on)
        refresh()
    }

    @objc private func recordChanged() {
        if recordBox.state == .on {
            let url = Log.directory.appendingPathComponent("audio-\(Log.stamp)-\(Int(Date().timeIntervalSince1970)).wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            wav = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            Log.write("wav: recording to \(url.path)")
        } else {
            wav = nil
        }
    }

    @objc private func hotkeyChanged() {
        if hotkeyBox.state == .on, !Hotkey.isTrusted { Hotkey.requestTrust() }
    }

    @objc private func bufferChanged() {
        let target = [2880, 4800, 7200, 12000][bufferPopup.indexOfSelectedItem]
        player.targetFrames = target
        player.maxFrames = target * 5 / 2
        player.reset()
    }

    @objc private func testTap() {
        if !Hotkey.isTrusted {
            Hotkey.requestTrust()
            return
        }
        Log.write("talk: test tap in 3 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Hotkey.rightOption(down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Hotkey.rightOption(down: false) }
        }
    }

    @objc private func showLogs() {
        NSWorkspace.shared.open(Log.directory)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
