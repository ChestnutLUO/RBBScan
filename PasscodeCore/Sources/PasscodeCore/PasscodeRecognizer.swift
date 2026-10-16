import CoreVideo
import Vision

/// A passcode-shaped string found in one frame, with the luminance of its background.
public struct CandidateObservation: Sendable {
    public let read: TextRead
    /// `nil` when the pixel format could not be sampled.
    public let label: LabelMeasurement?
}

/// Runs Vision text recognition on a frame and keeps only passcode-shaped strings.
/// Shared by the iOS app and the `videoscan` regression tool so both behave identically.
///
/// Vision reads sideways text far less reliably, so the recognizer remembers which way the
/// cards lie and hands Vision the frame already turned upright. Not thread-safe; drive it
/// from one queue.
public final class PasscodeRecognizer {
    public var minimumPolarity: Float
    /// The turn applied to frames before recognition, learned from the accepted reads.
    public private(set) var orientation: QuarterTurn = .none
    private var pendingOrientation: QuarterTurn?
    private let minimumTextHeight: Float
    private let cardText = CardTextFilter()

    public init(minimumPolarity: Float = LabelFilter.defaultMinimumPolarity, minimumTextHeight: Float = 0.008) {
        self.minimumPolarity = minimumPolarity
        self.minimumTextHeight = minimumTextHeight
    }

    /// All passcode-shaped observations, including ones the label filter would reject.
    /// Boxes are in `buffer`'s own normalized coordinates whatever the orientation.
    public func observe(_ buffer: CVPixelBuffer) throws -> [CandidateObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = minimumTextHeight

        let turn = orientation
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: turn.imageOrientation).perform([request])

        let sideways = turn == .clockwise || turn == .counterClockwise
        let width = CGFloat(sideways ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetWidth(buffer))
        let height = CGFloat(sideways ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetHeight(buffer))
        var observations: [CandidateObservation] = []
        for result in request.results ?? [] {
            guard let top = result.topCandidates(1).first,
                  let text = Self.passcodeText(in: top.string) else { continue }
            let residual = QuarterTurn(
                readingDirection: (result.topRight.x - result.topLeft.x) * width,
                (result.topRight.y - result.topLeft.y) * height
            )
            let quad = TextQuad(
                topLeft: result.topLeft, topRight: result.topRight,
                bottomRight: result.bottomRight, bottomLeft: result.bottomLeft
            ).map(turn.sourcePoint(of:))
            let box = quad.boundingBox
            let read = TextRead(text: text, confidence: top.confidence, quad: quad, rotation: turn + residual)
            observations.append(CandidateObservation(
                read: read,
                label: LabelFilter.measure(in: buffer, visionBox: box)
            ))
        }
        return observations
    }

    /// Observes one frame, keeps the accepted reads and adapts the orientation to them.
    public func analyze(_ buffer: CVPixelBuffer) throws -> (observations: [CandidateObservation], accepted: [TextRead]) {
        let observations = try observe(buffer)
        let accepted = observations.filter(accepts).map(\.read)
        adaptOrientation(to: accepted)
        return (observations, accepted)
    }

    /// Passcode reads that are not card description text and do not sit on a dark background.
    public func recognize(_ buffer: CVPixelBuffer) throws -> [TextRead] {
        try analyze(buffer).accepted
    }

    /// Follows the cards once most of a frame's passcodes need a different turn, two frames
    /// in a row, so a single misjudged read does not turn the next frame the wrong way.
    func adaptOrientation(to reads: [TextRead]) {
        var counts: [QuarterTurn: Int] = [:]
        reads.forEach { counts[$0.rotation, default: 0] += 1 }
        guard let (dominant, count) = counts.max(by: { $0.value < $1.value }),
              dominant != orientation, count * 2 > reads.count else {
            if !reads.isEmpty { pendingOrientation = nil }
            return
        }
        if pendingOrientation == dominant {
            orientation = dominant
            pendingOrientation = nil
        } else {
            pendingOrientation = dominant
        }
    }

    public func accepts(_ observation: CandidateObservation) -> Bool {
        if cardText.isCardText(observation.read.text) { return false }
        guard let label = observation.label else { return true }
        return label.polarity >= minimumPolarity
    }

    /// The whole line if it normalizes to a passcode, otherwise the first whitespace-separated token that does.
    static func passcodeText(in line: String) -> String? {
        let joined = Passcode.normalize(line)
        if Passcode.isCandidate(joined) { return joined }
        return line.split(whereSeparator: \.isWhitespace)
            .map { Passcode.normalize(String($0)) }
            .first(where: Passcode.isCandidate)
    }
}
