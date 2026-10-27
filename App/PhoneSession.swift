import CoreVideo
import Darwin
import Foundation

/// Runs scrcpy's server on the phone in camera mode, decodes its H.264 stream and, optionally,
/// relays the phone's microphone as raw PCM. The protocol matches the bundled scrcpy-server
/// (forward tunnel, frame headers on; one socket for video, then one for audio).
final class PhoneSession: @unchecked Sendable {
    struct Options {
        var facing: String      // "back" or "front"
        var maxSize: Int        // longest side of the captured picture
        var aspectRatio: String // "16:9", or "4:3" when the picture is rotated to portrait
        var keepAwake: Bool
        var audio: Bool         // also stream the phone's microphone
    }

    /// Must match the version of Resources/scrcpy-server.
    static let serverVersion = "3.3.4"
    private static let remoteJarPath = "/data/local/tmp/phonecam-server.jar"

    /// Decoded frames, delivered on a VideoToolbox thread.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// First frame decoded, on a VideoToolbox thread.
    var onStreaming: (() -> Void)?
    /// Microphone audio: interleaved 16-bit stereo PCM at 48 kHz, on the audio reader thread.
    var onAudio: ((Data) -> Void)?
    /// The session ended on its own; carries a user-facing reason. Called once, on a background thread.
    var onEnd: ((String) -> Void)?

    private let adb: URL
    private let serial: String
    private let serverJar: URL
    private let options: Options
    private let decoder = H264Decoder()

    private let lock = NSLock()
    private var stopped = false
    private var socketFD: Int32 = -1
    private var audioFD: Int32 = -1
    private var serverProcess: Process?
    private var serverOutput = ""
    private var sawFirstFrame = false

    init(adb: URL, serial: String, serverJar: URL, options: Options) {
        self.adb = adb
        self.serial = serial
        self.serverJar = serverJar
        self.options = options
        decoder.onFrame = { [weak self] buffer in
            guard let self else { return }
            self.lock.lock()
            let first = !self.sawFirstFrame
            self.sawFirstFrame = true
            self.lock.unlock()
            if first { self.onStreaming?() }
            self.onFrame?(buffer)
        }
    }

    func start() {
        Thread.detachNewThread { [self] in
            let reason: String
            do {
                try run()
                reason = isStopped ? "" : explainEnd(default: "The phone stopped sending video")
            } catch {
                reason = explainEnd(default: error.localizedDescription)
            }
            cleanUp()
            if !isStopped { onEnd?(reason) }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fds = [socketFD, audioFD]
        let process = serverProcess
        lock.unlock()
        for fd in fds where fd >= 0 { shutdown(fd, SHUT_RDWR) }
        process?.terminate()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: - Session

    private func run() throws {
        try adbRun(["push", serverJar.path, Self.remoteJarPath])
        if options.keepAwake {
            // Phones release the camera when the screen sleeps.
            try? adbRun(["shell", "svc", "power", "stayon", "usb"])
        }

        let scid = UInt32.random(in: 1..<0x7FFF_FFFF)
        let port = UInt16.random(in: 27200...27299)
        try adbRun(["forward", "tcp:\(port)", "localabstract:scrcpy_" + String(format: "%08x", scid)])
        defer { try? adbRun(["forward", "--remove", "tcp:\(port)"]) }

        try startServer(scid: scid)
        let fd = try connect(port: port)
        // The server accepts the audio socket right after the video one and only starts
        // streaming once both are connected.
        if options.audio, let audio = openSocket(port: port) {
            lock.lock()
            audioFD = audio
            lock.unlock()
            Thread.detachNewThread { [self] in readAudio(audio) }
        }

        // Codec meta: codec id, width, height (4 bytes each).
        guard readExactly(fd, 12) != nil else { throw ADBError(message: "No video header from the phone") }

        while !isStopped {
            // Frame header: 8-byte PTS with flags, then 4-byte payload size.
            guard let header = readExactly(fd, 12) else { return }
            let size = header.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard size > 0, size < 64 << 20, let payload = readExactly(fd, Int(size)) else { return }
            decoder.decode(payload)
        }
    }

    private func startServer(scid: UInt32) throws {
        let arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(Self.remoteJarPath)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
            "scid=" + String(format: "%08x", scid),
            "log_level=info",
            "video_source=camera",
            "camera_facing=\(options.facing)",
            "camera_ar=\(options.aspectRatio)",
            "max_size=\(options.maxSize)",
            "camera_fps=\(PhoneCamConstants.frameRate)",
            "video_codec=h264",
            "video_bit_rate=16000000",
            "audio=\(options.audio)",
            "audio_source=mic",
            "audio_codec=raw",
            "control=false",
            "tunnel_forward=true",
            "send_device_meta=false",
            "cleanup=true",
        ]
        let process = Process()
        process.executableURL = adb
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            self.lock.lock()
            self.serverOutput = String((self.serverOutput + text).suffix(8000))
            self.lock.unlock()
        }
        try process.run()
        lock.lock()
        serverProcess = process
        lock.unlock()
    }

    /// adb accepts the forwarded connection before the server listens, so retry until
    /// the server's dummy byte arrives.
    private func connect(port: UInt16) throws -> Int32 {
        for _ in 0..<100 {
            if isStopped { throw ADBError(message: "Stopped") }
            if let process = serverProcess, !process.isRunning {
                throw ADBError(message: "The camera server on the phone exited")
            }
            if let fd = openSocket(port: port) {
                if readExactly(fd, 1) != nil {
                    lock.lock()
                    socketFD = fd
                    lock.unlock()
                    return fd
                }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ADBError(message: "Couldn't connect to the camera server on the phone")
    }

    private func readAudio(_ fd: Int32) {
        // Codec id: 0 means the phone can't capture audio (Android 10 or older), 1 an error.
        guard let codec = readExactly(fd, 4) else { return }
        let codecID = codec.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard codecID > 1 else {
            Log.write("mic: the phone didn't provide microphone audio (\(codecID))")
            return
        }
        while !isStopped {
            guard let header = readExactly(fd, 12) else { return }
            let size = header.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard size > 0, size < 1 << 20, let payload = readExactly(fd, Int(size)) else { return }
            onAudio?(payload)
        }
    }

    private func cleanUp() {
        lock.lock()
        let fds = [socketFD, audioFD]
        socketFD = -1
        audioFD = -1
        let process = serverProcess
        serverProcess = nil
        lock.unlock()
        for fd in fds where fd >= 0 { close(fd) }
        if let process, process.isRunning { process.terminate() }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        decoder.invalidate()
    }

    private func explainEnd(default message: String) -> String {
        lock.lock()
        let output = serverOutput
        lock.unlock()
        if output.contains("open cameras") || output.contains("Camera disconnected")
            || output.contains("CAMERA_IN_USE") || output.contains("CAMERA_DISABLED") {
            return "The phone's camera is busy (face unlock or the camera app)"
        }
        if let errorLine = output.split(separator: "\n").last(where: { $0.contains("ERROR") }) {
            return errorLine.replacingOccurrences(of: "[server] ERROR: ", with: "")
        }
        return message
    }

    // MARK: - Plumbing

    private func adbRun(_ arguments: [String]) throws {
        try ADB.run(adb, ["-s", serial] + arguments)
    }

    private func openSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + received, count - received) }
            if n <= 0 { return nil }
            received += n
        }
        return data
    }
}
