import CoreGraphics
import CoreVideo

/// Luminance statistics of the pixels under a text box, each in 0...1.
public struct LabelMeasurement: Sendable, Equatable {
    public let mean: Float
    public let p10: Float
    public let median: Float
    public let p90: Float

    /// Where the median sits between the darkest and brightest pixels. Text strokes cover
    /// a minority of the box, so the median is the background: above 0.5 means a light
    /// background with dark text (a passcode label), below means light text on dark.
    /// Independent of exposure, unlike the mean.
    public var polarity: Float {
        let range = p90 - p10
        guard range > 0.0001 else { return 0.5 }
        return (median - p10) / range
    }
}

/// Passcodes are printed dark-on-white, while the card's description text is
/// white-on-dark. Polarity is a coarse separator: glare and motion blur push real
/// labels as low as ~0.2 in the sample video, so it only rejects clearly inverted
/// text and `CardTextFilter` handles the description text itself.
public enum LabelFilter {
    public static let defaultMinimumPolarity: Float = 0.1

    /// Luminance statistics of `visionBox` (Vision normalized coordinates, origin
    /// bottom-left) in an upright pixel buffer. Supports bi-planar YCbCr and 32BGRA.
    /// Returns `nil` for unsupported formats or an empty box.
    public static func measure(in buffer: CVPixelBuffer, visionBox: CGRect) -> LabelMeasurement? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isBiPlanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isBiPlanar || format == kCVPixelFormatType_32BGRA else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let plane = 0
        let width = isBiPlanar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = isBiPlanar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        let rowBytes = isBiPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
        guard let base = isBiPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer)
        else { return nil }

        let rect = pixelRect(visionBox: visionBox, width: width, height: height)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let samplesPerAxis = 48
        let stepX = max(1, rect.width / samplesPerAxis)
        let stepY = max(1, rect.height / samplesPerAxis)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var samples: [Float] = []
        samples.reserveCapacity(samplesPerAxis * samplesPerAxis)
        for y in stride(from: rect.minY, to: rect.maxY, by: stepY) {
            let row = pixels + y * rowBytes
            for x in stride(from: rect.minX, to: rect.maxX, by: stepX) {
                if isBiPlanar {
                    samples.append(Float(row[x]))
                } else {
                    let p = row + x * 4
                    samples.append(0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2]))
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let unit: (Float) -> Float = { value in
            videoRange ? min(max((value - 16) / 219, 0), 1) : value / 255
        }
        samples.sort()
        let percentile: (Float) -> Float = { fraction in
            unit(samples[min(samples.count - 1, Int(Float(samples.count - 1) * fraction))])
        }
        return LabelMeasurement(
            mean: unit(samples.reduce(0, +) / Float(samples.count)),
            p10: percentile(0.1),
            median: percentile(0.5),
            p90: percentile(0.9)
        )
    }

    /// Converts a bottom-left normalized box into top-left integer pixel bounds, clamped to the image.
    static func pixelRect(visionBox: CGRect, width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int) {
        let minX = clamp(Int((visionBox.minX * CGFloat(width)).rounded(.down)), 0, width)
        let maxX = clamp(Int((visionBox.maxX * CGFloat(width)).rounded(.up)), 0, width)
        let minY = clamp(Int(((1 - visionBox.maxY) * CGFloat(height)).rounded(.down)), 0, height)
        let maxY = clamp(Int(((1 - visionBox.minY) * CGFloat(height)).rounded(.up)), 0, height)
        return (minX, minY, maxX, maxY, maxX - minX, maxY - minY)
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}
