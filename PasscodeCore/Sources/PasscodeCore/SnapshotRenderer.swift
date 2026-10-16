import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

/// JPEG crops a reviewer needs to check a passcode against the physical card.
public struct ScanImages: Sendable {
    public let label: Data
    public let card: Data
    public let frame: Data

    public init(label: Data, card: Data, frame: Data) {
        self.label = label
        self.card = card
        self.frame = frame
    }
}

public final class SnapshotRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init() {}

    /// Crops for the passcode whose corners are `quad` (normalized, in `buffer`). The label and
    /// card crops are turned by the text's exact angle, so the code reads straight left to right
    /// however the card lay; the whole frame is turned by the nearest quarter turn.
    public func images(from buffer: CVPixelBuffer, quad: TextQuad, frameMaxDimension: CGFloat = 1280) -> ScanImages? {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        let pixels = quad.map { CGPoint(x: extent.minX + $0.x * extent.width, y: extent.minY + $0.y * extent.height) }
        let angle = atan2(pixels.topRight.y - pixels.topLeft.y, pixels.topRight.x - pixels.topLeft.x)
        let straighten = CGAffineTransform(rotationAngle: -angle)
        let straight = source.transformed(by: straighten)
        let box = pixels.map { $0.applying(straighten) }.boundingBox
        let textHeight = box.height

        // Extra room above the text keeps the label's castle-battlement edge in view.
        let label = CGRect(
            x: box.minX - textHeight * 0.6,
            y: box.minY - textHeight * 0.6,
            width: box.width + textHeight * 1.2,
            height: box.height + textHeight * 1.6
        )
        // The code strip sits near the bottom of the card, roughly 60% of the card's width.
        let card = CGRect(
            x: box.midX - box.width * 0.9,
            y: box.minY - textHeight * 1.5,
            width: box.width * 1.8,
            height: box.width * 2.6
        )
        let frameTurn = QuarterTurn(readingDirection: cos(angle), sin(angle))
        guard let labelJPEG = jpeg(straight.cropped(to: label.intersection(straight.extent)), maxDimension: 900),
              let cardJPEG = jpeg(straight.cropped(to: card.intersection(straight.extent)), maxDimension: 1000),
              let frameJPEG = jpeg(source.oriented(frameTurn.imageOrientation), maxDimension: frameMaxDimension)
        else { return nil }
        return ScanImages(label: labelJPEG, card: cardJPEG, frame: frameJPEG)
    }

    public func preview(from buffer: CVPixelBuffer, maxDimension: CGFloat = 480, quality: CGFloat = 0.5) -> Data? {
        jpeg(CIImage(cvPixelBuffer: buffer), maxDimension: maxDimension, quality: quality)
    }

    private func jpeg(_ image: CIImage, maxDimension: CGFloat, quality: CGFloat = 0.8) -> Data? {
        let extent = image.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return context.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options)
    }
}
