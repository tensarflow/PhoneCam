import CoreBluetooth
import Foundation

/// Receives the "PhoneCam Mic" Android app's microphone over Bluetooth LE.
///
/// The Mac is the peripheral: it advertises a service whose one characteristic holds the PSM of an
/// encrypted L2CAP channel. The phone connects when the user turns its mic on, reads the PSM (pairing
/// the first time) and opens the channel. Messages on the channel are `u8 type | u16 length | payload`;
/// see Docs/bluetooth-mic-spec.md. All callbacks run on the main thread.
final class BluetoothMic: NSObject, CBPeripheralManagerDelegate, StreamDelegate {
    enum State: Equatable {
        case off
        case unavailable(String)
        case waiting
        case connected(String)
    }

    private enum Message: UInt8 {
        case hello = 0x01, welcome = 0x02, audio = 0x10, talkDown = 0x20, talkUp = 0x21
        case status = 0x30, disarm = 0x31, ack = 0x32, ping = 0x40, pong = 0x41
    }

    enum DisarmReason: UInt8 {
        case idle = 1, turnedOff = 2
    }

    static let serviceUUID = CBUUID(string: "7A3F0001-5C1E-4B7E-9B1A-2F6D8C4E0A11")
    static let psmCharacteristicUUID = CBUUID(string: "7A3F0002-5C1E-4B7E-9B1A-2F6D8C4E0A11")
    static let protocolVersion: UInt8 = 2

    var onStateChange: ((State) -> Void)?
    /// One 20 ms Opus packet, or nil for a lost one (play silence in its place).
    var onAudio: ((Data?) -> Void)?
    var onTalk: ((Bool) -> Void)?

    private(set) var state: State = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var stats = Stats()

    struct Stats {
        var packets = 0
        var lost = 0
        var rtt: Double?
    }

    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var channel: CBL2CAPChannel?
    private var inbox = Data()
    private var lastSequence: Int?
    private var timer: Timer?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    private func start() {
        if let manager {
            peripheralManagerDidUpdateState(manager)
        } else {
            // Creating the manager is what asks for Bluetooth permission, so only do it once wanted.
            manager = CBPeripheralManager(delegate: self, queue: .main)
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        disarm(.turnedOff)
        closeChannel()
        if let manager {
            manager.stopAdvertising()
            manager.removeAllServices()
            if let psm { manager.unpublishL2CAPChannel(psm) }
        }
        psm = nil
        state = .off
    }

    // MARK: - Sending

    /// Tells the phone whether an app is recording from PhoneCam Microphone.
    func sendStatus(micInUse: Bool) {
        send(.status, Data([micInUse ? 1 : 0]))
    }

    /// Asks the phone to turn its mic off.
    func disarm(_ reason: DisarmReason) {
        send(.disarm, Data([reason.rawValue]))
    }

    private func send(_ type: Message, _ payload: Data) {
        guard channel != nil else { return }
        // A stalled link shouldn't grow this forever; acks and pings are only useful while fresh.
        if outbox.count > 4096 { outbox.removeAll() }
        outbox.append(contentsOf: [type.rawValue, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        outbox.append(payload)
        flush()
    }

    /// Writes what the stream takes now; the rest goes when it reports space again.
    private func flush() {
        guard let output = channel?.outputStream else { return }
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: outbox.count) }
            guard written > 0 else { break }
            outbox.removeFirst(written)
        }
    }
    private var outbox = Data()

    /// Acknowledges the newest packet five times a second, so the phone can drop audio instead of
    /// letting a backlog build up when the link falls behind; pings once a second for the RTT.
    private func tick() {
        guard channel != nil else { return }
        if let lastSequence { send(.ack, Data([UInt8(lastSequence >> 8), UInt8(lastSequence & 0xff)])) }
        pingCountdown -= 1
        if pingCountdown <= 0 {
            pingCountdown = 5
            send(.ping, withUnsafeBytes(of: ProcessInfo.processInfo.systemUptime.bitPattern.bigEndian) { Data($0) })
        }
    }
    private var pingCountdown = 0

    // MARK: - Peripheral

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard isEnabled else { return }
        switch peripheral.state {
        case .poweredOn:
            if psm == nil { peripheral.publishL2CAPChannel(withEncryption: true) }
        case .unauthorized:
            state = .unavailable("Allow PhoneCam under Privacy & Security → Bluetooth")
        case .poweredOff:
            state = .unavailable("Bluetooth is off")
        case .unsupported:
            state = .unavailable("This Mac doesn't support Bluetooth LE")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            Log.write("bluetooth: couldn't publish the audio channel: \(error.localizedDescription)")
            state = .unavailable("Bluetooth error: \(error.localizedDescription)")
            return
        }
        psm = PSM
        let characteristic = CBMutableCharacteristic(type: Self.psmCharacteristicUUID, properties: [.read], value: nil,
                                                     permissions: [.readEncryptionRequired])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            state = .unavailable("Bluetooth error: \(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                     CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "PhoneCam"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            state = .unavailable("Bluetooth error: \(error.localizedDescription)")
        } else if channel == nil {
            Log.write("bluetooth: waiting for the phone (PSM \(psm ?? 0))")
            state = .waiting
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let psm else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        request.value = Data([UInt8(psm & 0xff), UInt8(psm >> 8)])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard isEnabled, let channel else {
            if let error { Log.write("bluetooth: channel failed: \(error.localizedDescription)") }
            return
        }
        // One phone at a time: a new connection replaces the old one.
        closeChannel()
        self.channel = channel
        inbox.removeAll()
        outbox.removeAll()
        lastSequence = nil
        stats = Stats()
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        if let central = channel.peer as? CBCentral { peripheral.setDesiredConnectionLatency(.low, for: central) }
        state = .connected("phone")
        Log.write("bluetooth: phone connected")
    }

    private func closeChannel() {
        guard let channel else { return }
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        self.channel = nil
        Log.write("bluetooth: phone disconnected (\(stats.packets) packets, \(stats.lost) lost)")
        if isEnabled, manager?.state == .poweredOn { state = .waiting }
    }

    // MARK: - Receiving

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
        case .hasSpaceAvailable:
            flush()
        case .endEncountered, .errorOccurred:
            if channel?.inputStream === stream || channel?.outputStream === stream { closeChannel() }
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
            handle(type, payload)
        }
        // Keep indices starting at 0 after many removals.
        inbox = Data(inbox)
    }

    private func handle(_ type: UInt8, _ payload: Data) {
        switch Message(rawValue: type) {
        case .hello:
            let name = String(decoding: payload.dropFirst(), as: UTF8.self)
            Log.write("bluetooth: hello from \(name), protocol \(payload.first ?? 0)")
            state = .connected(name.isEmpty ? "phone" : name)
            send(.welcome, Data([Self.protocolVersion]) + Data((Host.current().localizedName ?? "Mac").utf8))
        case .audio:
            receiveAudio(payload)
        case .talkDown:
            onTalk?(true)
        case .talkUp:
            onTalk?(false)
        case .ping:
            send(.pong, payload)
        case .pong:
            guard payload.count == 8 else { return }
            let sent = payload.withUnsafeBytes { Double(bitPattern: UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))) }
            stats.rtt = (ProcessInfo.processInfo.systemUptime - sent) * 1000
        default:
            break
        }
    }

    /// Audio payload: u16 sequence, u32 capture time (phone clock, ms), one Opus packet.
    private func receiveAudio(_ payload: Data) {
        guard payload.count > 6 else { return }
        let start = payload.startIndex
        let sequence = Int(payload[start]) << 8 | Int(payload[start + 1])
        if let last = lastSequence {
            let delta = (sequence - last + 65536) % 65536
            if delta == 0 || delta > 32768 { return } // duplicate or late
            if delta > 1 {
                stats.lost += delta - 1
                // Keep the timing with silence; longer gaps are a reconnect, not something to fill.
                if delta - 1 <= 10 { for _ in 0..<(delta - 1) { onAudio?(nil) } }
            }
        }
        lastSequence = sequence
        stats.packets += 1
        onAudio?(payload.subdata(in: (start + 6)..<payload.endIndex))
    }
}
