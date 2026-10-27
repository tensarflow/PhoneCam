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
        case .working: return .orange
        case .attention: return .red
        case .idle: return .secondary
        }
    }
}

private struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            preview
            controls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.status.tint)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("PhoneCam").font(.headline)
                Text(model.status.message)
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
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rotateButtons: some View {
        VStack {
            Spacer()
            HStack(spacing: 2) {
                Spacer()
                Button { model.rotate(by: -90) } label: {
                    Image(systemName: "rotate.left").frame(width: 28, height: 24)
                }
                .help("Rotate left")
                Button { model.rotate(by: 90) } label: {
                    Image(systemName: "rotate.right").frame(width: 28, height: 24)
                }
                .help("Rotate right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
        }
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
        }
        .padding(18)
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("Camera")
                Picker("Camera", selection: $model.facing) {
                    Text("Back").tag(CameraFacing.back)
                    Text("Front").tag(CameraFacing.front)
                }
            }
            GridRow {
                label("Rotation")
                Picker("Rotation", selection: $model.rotation) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }
            }
            GridRow {
                label("Framing")
                Picker("Framing", selection: $model.fillFrame) {
                    Text("Fill").tag(true)
                    Text("Fit").tag(false)
                }
                .help("Fill crops the picture to fill the frame; Fit shows all of it with black bars")
            }
            GridRow {
                label("Quality")
                Picker("Quality", selection: $model.quality) {
                    Text("720p").tag(Quality.p720)
                    Text("1080p").tag(Quality.p1080)
                }
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
            Toggle("Keep phone screen on while streaming", isOn: $model.keepAwake)
                .help("Phones release the camera when their screen sleeps")
            Toggle("Open PhoneCam at login", isOn: $model.openAtLogin)
            HStack(alignment: .firstTextBaseline) {
                Text("In Teams, Zoom or FaceTime, choose “PhoneCam” as the camera.")
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
