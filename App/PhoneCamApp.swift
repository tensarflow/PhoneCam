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
