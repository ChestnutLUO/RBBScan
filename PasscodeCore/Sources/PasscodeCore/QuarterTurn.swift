import CoreGraphics
import ImageIO

/// A clockwise rotation in steps of 90°.
public enum QuarterTurn: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case clockwise = 90
    case half = 180
    case counterClockwise = 270

    /// The turn that makes text upright, given its reading direction (from the start of the
    /// line to its end) in Vision's coordinate space, where y points up.
    public init(readingDirection dx: CGFloat, _ dy: CGFloat) {
        let degrees = atan2(dy, dx) * 180 / .pi
        let steps = Int((degrees / 90).rounded())
        self = QuarterTurn(rawValue: ((steps % 4 + 4) % 4) * 90) ?? .none
    }

    /// The orientation that, applied with `CIImage.oriented(_:)`, performs this turn.
    public var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: .up
        case .clockwise: .right
        case .half: .down
        case .counterClockwise: .left
        }
    }

    public static func + (lhs: QuarterTurn, rhs: QuarterTurn) -> QuarterTurn {
        QuarterTurn(rawValue: (lhs.rawValue + rhs.rawValue) % 360) ?? .none
    }

    /// Maps a normalized point (origin bottom-left) of the turned image back to the
    /// image before this turn was applied.
    public func sourcePoint(of point: CGPoint) -> CGPoint {
        switch self {
        case .none: point
        case .clockwise: CGPoint(x: 1 - point.y, y: point.x)
        case .half: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .counterClockwise: CGPoint(x: point.y, y: 1 - point.x)
        }
    }
}
