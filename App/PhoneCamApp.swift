import SwiftUI

@main
struct PhoneCamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.status.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

private extension AppModel.Status {
    var tint: Color {
        switch severity {
        case .live: return .green
        case .ready: return .blue
        case .working: return .orange
        case .attention: return .red
        case .idle: return .secondary
        }
    }
}

private struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var isVisible = false

    private static let width: CGFloat = 340
    private static let padding: CGFloat = 16
    private static let previewWidth = width - 2 * padding

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            preview
            controls
            Divider()
            footer
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        // Menu bar panels are see-through by default; a solid window color keeps the text readable.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { isVisible = true; model.setPanelOpen(true) }
        .onDisappear { isVisible = false; model.setPanelOpen(false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.status.tint)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("PhoneCam").font(.headline)
                Text(model.status.message + usage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Camera", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.isEnabled ? "Turn the camera off" : "Turn the camera on")
        }
    }

    private var usage: String {
        let apps: String
        switch model.appsUsingCamera {
        case 0: apps = ""
        case 1: apps = " · 1 app"
        case let count: apps = " · \(count) apps"
        }
        return apps + (model.micInUse ? " · mic" : "")
    }

    private var hint: String {
        model.micEnabled && model.micDriverState == .installed
            ? "In Teams, Zoom or FaceTime, choose “PhoneCam” as the camera and “PhoneCam Microphone” as the mic."
            : "In Teams, Zoom or FaceTime, choose “PhoneCam” as the camera."
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Use the phone's microphone", isOn: $model.micEnabled)
                Spacer()
                if model.installingMicDriver {
                    ProgressView().controlSize(.small)
                } else if model.micEnabled && model.micDriverState != .installed {
                    Button(model.micDriverState == .notInstalled ? "Install…" : "Update…") { model.installMicDriver() }
                        .controlSize(.small)
                        .help("Installs the PhoneCam Microphone driver. macOS asks for your password, and Mac audio pauses for a moment.")
                }
            }
            if let error = model.micDriverError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.micEnabled && model.micDriverState == .notInstalled {
                Text("Needs a one-time install so apps can pick “PhoneCam Microphone”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.status.isStreaming {
                PreviewLayerView(store: model.preview, isActive: isVisible)
                rotateButtons
            } else {
                emptyState
            }
        }
        // A fixed size: the panel doesn't propose a height, so an aspect-ratio fit would shrink it.
        .frame(width: Self.previewWidth, height: (Self.previewWidth * 9 / 16).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rotateButtons: some View {
        HStack(spacing: 0) {
            Button { model.rotate(by: -90) } label: {
                Image(systemName: "rotate.left").frame(width: 30, height: 26)
            }
            .help("Rotate left")
            Divider().frame(height: 16)
            Button { model.rotate(by: 90) } label: {
                Image(systemName: "rotate.right").frame(width: 30, height: 26)
            }
            .help("Rotate right")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.status.symbolName)
                .font(.system(size: 26))
                .foregroundStyle(model.status.tint == .secondary ? .white.opacity(0.6) : model.status.tint)
            Text(model.status.guidance)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
            if model.status == .extensionNeedsApproval {
                Button("Open System Settings…") { model.openExtensionSettings() }
                    .controlSize(.small)
            }
            switch model.status {
            case .noPhone, .unauthorized:
                Button("Phone setup help…") { model.openHelp("3-set-up-the-phone") }
                    .controlSize(.small)
            case .adbMissing:
                Button("How to install adb…") { model.openHelp("1-install-phonecam") }
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(18)
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("Phone camera")
                Picker("Phone camera", selection: $model.streamMode) {
                    Text("When used").tag(StreamMode.whenUsed)
                    Text("Always on").tag(StreamMode.always)
                }
                .frame(maxWidth: .infinity)
                .help("When used: the phone's camera runs only while an app uses PhoneCam (or this panel is open). Always on: it runs whenever the phone is plugged in, so the picture is there instantly.")
            }
            GridRow {
                label("Camera")
                Picker("Camera", selection: $model.facing) {
                    Text("Back").tag(CameraFacing.back)
                    Text("Front").tag(CameraFacing.front)
                }
                .frame(maxWidth: .infinity)
            }
            GridRow {
                label("Rotation")
                Picker("Rotation", selection: $model.rotation) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
                .frame(maxWidth: .infinity)
            }
            GridRow {
                label("Framing")
                Picker("Framing", selection: $model.fillFrame) {
                    Text("Fill").tag(true)
                    Text("Fit").tag(false)
                }
                .frame(maxWidth: .infinity)
                .help("Fill crops the picture to fill the frame; Fit shows all of it with black bars")
            }
            GridRow {
                label("Quality")
                Picker("Quality", selection: $model.quality) {
                    Text("720p").tag(Quality.p720)
                    Text("1080p").tag(Quality.p1080)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            microphone
            Toggle("Keep phone screen on while streaming", isOn: $model.keepAwake)
                .help("Phones release the camera when their screen sleeps")
            Toggle("Open PhoneCam at login", isOn: $model.openAtLogin)
            HStack(alignment: .firstTextBaseline) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Quit") { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
    }
}
