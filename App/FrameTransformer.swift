import CoreImage
import CoreVideo
import Foundation

/// Rotates decoded frames in 90° steps and fits them into the camera's fixed
/// 1920×1080 output, either cropping to fill or adding black bars. Runs on the GPU.
final class FrameTransformer: @unchecked Sendable {
    private let lock = NSLock()
    private var rotation = 0
    private var fill = true

    // No working color space: pass pixel values through untouched.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private let outputRect = CGRect(x: 0, y: 0, width: CGFloat(PhoneCamConstants.width),
                                    height: CGFloat(PhoneCamConstants.height))

    init() {
        let attributes: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: PhoneCamConstants.width,
            kCVPixelBufferHeightKey: PhoneCamConstants.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
    }

    /// `rotation` is clockwise degrees: 0, 90, 180 or 270.
    func configure(rotation: Int, fill: Bool) {
        lock.lock()
        self.rotation = rotation
        self.fill = fill
        lock.unlock()
    }

    func transform(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let rotation = self.rotation, fill = self.fill
        lock.unlock()

        let orientation: CGImagePropertyOrientation
        switch rotation {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: orientation = .up
        }
        var image = CIImage(cvPixelBuffer: input).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let scaleX = outputRect.width / image.extent.width
        let scaleY = outputRect.height / image.extent.height
        let scale = fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (outputRect.width - image.extent.width) / 2,
                                                        y: (outputRect.height - image.extent.height) / 2))
        image = image.composited(over: CIImage(color: .black).cropped(to: outputRect)).cropped(to: outputRect)

        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        context.render(image, to: output, bounds: outputRect, colorSpace: nil)
        return output
    }
}
