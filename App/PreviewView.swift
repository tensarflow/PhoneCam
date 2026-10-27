import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Holds the most recent frame sent to the camera. Written from the decode thread.
final class PreviewStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?

    var latest: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func update(_ newFrame: CVPixelBuffer) {
        lock.lock(); frame = newFrame; lock.unlock()
    }

    func clear() {
        lock.lock(); frame = nil; lock.unlock()
    }
}

/// Shows the camera output by handing frames' IOSurfaces straight to a layer, so the
/// preview costs no copies. Refreshes at 15 fps only while `isActive`.
struct PreviewLayerView: NSViewRepresentable {
    let store: PreviewStore
    let isActive: Bool

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(store: store) }

    func updateNSView(_ view: PreviewNSView, context: Context) { view.isActive = isActive }
}

final class PreviewNSView: NSView {
    private let store: PreviewStore
    private var timer: Timer?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? startTimer() : stopTimer()
        }
    }

    init(store: PreviewStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    private func startTimer() {
        let newTimer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        refresh()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let buffer = store.latest, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Reassigning the same pooled surface wouldn't redraw, so clear it first.
        layer?.contents = nil
        layer?.contents = surface
        CATransaction.commit()
    }
}
