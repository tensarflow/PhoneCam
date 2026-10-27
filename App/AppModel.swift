import AppKit
import Combine
import ServiceManagement

enum CameraFacing: String, CaseIterable {
    case back, front
}

enum Quality: String, CaseIterable {
    case p1080, p720
    var maxSize: Int { self == .p1080 ? 1920 : 1280 }
}

/// Watches for the phone over adb and keeps a camera session running while it's plugged in.
/// All state changes happen on the main thread.
final class AppModel: ObservableObject {
    enum Status: Equatable {
        case approvingExtension
        case extensionNeedsApproval
        case extensionFailed(String)
        case adbMissing
        case noPhone
        case unauthorized
        case paused
        case connecting(String)
        case streaming(String)
        case retrying(String, String)

        enum Severity { case live, working, attention, idle }

        /// Short line for the panel header.
        var message: String {
            switch self {
            case .approvingExtension: return "Setting up…"
            case .extensionNeedsApproval: return "Needs your approval"
            case .extensionFailed: return "Camera couldn't be installed"
            case .adbMissing: return "Android tools missing"
            case .noPhone: return "No phone connected"
            case .unauthorized: return "Waiting for the phone"
            case .paused: return "Off"
            case .connecting(let model): return "Connecting to \(model)…"
            case .streaming(let model): return "Live from \(model)"
            case .retrying(let model, _): return "Reconnecting to \(model)…"
            }
        }

        /// What the user should do, shown where the preview would be.
        var guidance: String {
            switch self {
            case .approvingExtension:
                return "Setting up the PhoneCam camera."
            case .extensionNeedsApproval:
                return "macOS needs your OK to add the PhoneCam camera. Turn on PhoneCam under Camera Extensions."
            case .extensionFailed(let error):
                return error
            case .adbMissing:
                return "Install Android platform-tools, then reopen PhoneCam:\nbrew install android-platform-tools"
            case .noPhone:
                return "Plug your phone in with a USB cable.\nUSB debugging must be on."
            case .unauthorized:
                return "Unlock the phone and tap Allow on the USB debugging prompt."
            case .paused:
                return "The camera is off. Turn it on with the switch above."
            case .connecting:
                return "Starting the phone's camera…"
            case .streaming:
                return ""
            case .retrying(_, let reason):
                return reason.isEmpty ? "Trying again…" : "\(reason).\nTrying again…"
            }
        }

        var severity: Severity {
            switch self {
            case .streaming: return .live
            case .connecting, .retrying, .approvingExtension: return .working
            case .extensionNeedsApproval, .extensionFailed, .adbMissing, .unauthorized: return .attention
            case .noPhone, .paused: return .idle
            }
        }

        var isStreaming: Bool { severity == .live }

        var symbolName: String {
            switch self {
            case .streaming: return "video.fill"
            case .connecting, .retrying, .approvingExtension: return "video.badge.ellipsis"
            case .extensionNeedsApproval, .extensionFailed, .adbMissing, .unauthorized: return "exclamationmark.triangle"
            case .noPhone, .paused: return "video.slash"
            }
        }
    }

    @Published private(set) var status: Status = .approvingExtension

    @Published var isEnabled: Bool { didSet { settingChanged(isEnabled, "enabled") } }
    @Published var facing: CameraFacing { didSet { settingChanged(facing.rawValue, "facing") } }
    @Published var quality: Quality { didSet { settingChanged(quality.rawValue, "quality") } }
    @Published var keepAwake: Bool { didSet { settingChanged(keepAwake, "keepAwake") } }
    @Published var openAtLogin: Bool { didSet { updateLoginItem() } }
    /// Clockwise degrees: 0, 90, 180 or 270.
    @Published var rotation: Int { didSet { rotationChanged(from: oldValue) } }
    @Published var fillFrame: Bool {
        didSet {
            defaults.set(fillFrame, forKey: "fillFrame")
            transformer.configure(rotation: rotation, fill: fillFrame)
        }
    }

    private let defaults = UserDefaults.standard
    private let installer = ExtensionInstaller()
    private let sink = VirtualCameraSink()
    private let transformer = FrameTransformer()
    /// The latest frame sent to the camera, for the panel's preview.
    let preview = PreviewStore()
    private let adbURL = ADB.locate()
    private var extensionState: ExtensionInstaller.State = .activating
    private var phone: PhoneState = .none
    private var session: PhoneSession?
    private var sessionIsStreaming = false
    private var lastEndReason = ""
    private var retryAfter = Date.distantPast
    private var pollTimer: Timer?
    private var polling = false

    init() {
        defaults.register(defaults: ["enabled": true, "facing": "back", "quality": "p1080", "keepAwake": true,
                                     "rotation": 0, "fillFrame": true])
        isEnabled = defaults.bool(forKey: "enabled")
        facing = CameraFacing(rawValue: defaults.string(forKey: "facing") ?? "") ?? .back
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .p1080
        keepAwake = defaults.bool(forKey: "keepAwake")
        openAtLogin = SMAppService.mainApp.status == .enabled
        rotation = defaults.integer(forKey: "rotation")
        fillFrame = defaults.bool(forKey: "fillFrame")
        transformer.configure(rotation: rotation, fill: fillFrame)

        installer.onStateChange = { [weak self] state in
            self?.extensionState = state
            self?.refreshStatus()
        }
        installer.activate()

        // .common so polling continues while the menu is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    func rotate(by degrees: Int) {
        rotation = ((rotation + degrees) % 360 + 360) % 360
    }

    func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    func quit() {
        stopSession()
        NSApp.terminate(nil)
    }

    // MARK: - Phone tracking

    private func poll() {
        guard let adbURL else { refreshStatus(); return }
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let state = ADB.deviceState(adb: adbURL)
            DispatchQueue.main.async {
                self.polling = false
                self.handle(state)
            }
        }
    }

    private func handle(_ state: PhoneState) {
        if state != phone { retryAfter = .distantPast }
        phone = state
        if case .ready(let serial, let model) = state, isEnabled {
            if session == nil, Date() >= retryAfter { startSession(serial: serial, model: model) }
        } else {
            stopSession()
        }
        refreshStatus()
    }

    private func startSession(serial: String, model: String) {
        guard let adbURL, let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else { return }
        // A portrait result gets cropped to landscape, so capture 4:3 at a larger size to keep detail.
        let options = PhoneSession.Options(facing: facing.rawValue,
                                           maxSize: isPortrait ? quality.maxSize * 4 / 3 : quality.maxSize,
                                           aspectRatio: isPortrait ? "4:3" : "16:9",
                                           keepAwake: keepAwake)
        let newSession = PhoneSession(adb: adbURL, serial: serial, serverJar: jar, options: options)
        newSession.onFrame = { [transformer, sink, preview] buffer in
            guard let frame = transformer.transform(buffer) else { return }
            sink.send(frame)
            preview.update(frame)
        }
        Log.write("session: starting on \(model) (\(facing.rawValue), \(quality.rawValue), \(rotation)°)")
        newSession.onStreaming = { [weak self, weak newSession] in
            Log.write("session: first frame decoded")
            DispatchQueue.main.async {
                guard let self, self.session === newSession else { return }
                self.sessionIsStreaming = true
                self.lastEndReason = ""
                self.refreshStatus()
            }
        }
        newSession.onEnd = { [weak self, weak newSession] reason in
            Log.write("session: ended: \(reason)")
            DispatchQueue.main.async {
                guard let self, self.session === newSession else { return }
                self.session = nil
                self.sessionIsStreaming = false
                self.lastEndReason = reason
                self.sink.disconnect()
                self.preview.clear()
                // Give face unlock or the camera app a moment to let go of the camera.
                self.retryAfter = Date().addingTimeInterval(3)
                self.refreshStatus()
            }
        }
        session = newSession
        sessionIsStreaming = false
        newSession.start()
    }

    private func stopSession() {
        guard let running = session else { return }
        session = nil
        sessionIsStreaming = false
        running.stop()
        sink.disconnect()
        preview.clear()
    }

    private var isPortrait: Bool { rotation == 90 || rotation == 270 }

    private func rotationChanged(from oldRotation: Int) {
        transformer.configure(rotation: rotation, fill: fillFrame)
        // Rotation itself applies live; only switching between portrait and landscape
        // needs the phone to capture a different aspect ratio.
        if (oldRotation == 90 || oldRotation == 270) != isPortrait {
            settingChanged(rotation, "rotation")
        } else {
            defaults.set(rotation, forKey: "rotation")
        }
    }

    private func settingChanged(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        // Restart with the new settings on the next poll.
        stopSession()
        retryAfter = .distantPast
        lastEndReason = ""
        poll()
        refreshStatus()
    }

    private func updateLoginItem() {
        do {
            if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PhoneCam: login item update failed: \(error.localizedDescription)")
        }
    }

    private func refreshStatus() {
        let newStatus: Status
        switch extensionState {
        case .needsApproval:
            newStatus = .extensionNeedsApproval
        case .failed(let error):
            newStatus = .extensionFailed(error)
        case .activating, .activated:
            if adbURL == nil {
                newStatus = .adbMissing
            } else if !isEnabled {
                newStatus = .paused
            } else {
                switch phone {
                case .none: newStatus = .noPhone
                case .unauthorized: newStatus = .unauthorized
                case .ready(_, let model):
                    if sessionIsStreaming {
                        newStatus = .streaming(model)
                    } else if !lastEndReason.isEmpty {
                        newStatus = .retrying(model, lastEndReason)
                    } else {
                        newStatus = .connecting(model)
                    }
                }
            }
        }
        if newStatus != status { status = newStatus }
    }
}
