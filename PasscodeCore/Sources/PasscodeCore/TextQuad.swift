import CoreGraphics

/// The four corners of a line of text as Vision reports them, in the frame's normalized
/// coordinates (origin bottom-left). `topLeft` → `topRight` runs along the reading direction,
/// so the quad also tells how far the card is turned, not just in 90° steps.
public struct TextQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Upright, unrotated text filling `box`.
    public init(box: CGRect) {
        self.init(
            topLeft: CGPoint(x: box.minX, y: box.maxY), topRight: CGPoint(x: box.maxX, y: box.maxY),
            bottomRight: CGPoint(x: box.maxX, y: box.minY), bottomLeft: CGPoint(x: box.minX, y: box.minY)
        )
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public var boundingBox: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    public func map(_ transform: (CGPoint) -> CGPoint) -> TextQuad {
        TextQuad(topLeft: transform(topLeft), topRight: transform(topRight),
                 bottomRight: transform(bottomRight), bottomLeft: transform(bottomLeft))
    }

    /// Angle of the reading direction in radians, counter-clockwise from the x axis, measured in
    /// pixels of a `width` × `height` frame (normalized coordinates would distort it).
    public func readingAngle(width: CGFloat, height: CGFloat) -> CGFloat {
        atan2((topRight.y - topLeft.y) * height, (topRight.x - topLeft.x) * width)
    }
}
