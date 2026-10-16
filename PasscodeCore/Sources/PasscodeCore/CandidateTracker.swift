import CoreGraphics
import Foundation

/// One passcode-shaped OCR result from a single frame.
public struct TextRead: Sendable, Equatable {
    /// Normalized text (see `Passcode.normalize`), expected to satisfy `Passcode.isCandidate`.
    public let text: String
    public let confidence: Float
    /// The text's corners in the frame, so crops can be straightened to its exact angle.
    public let quad: TextQuad
    /// Clockwise quarter turn that brings the text closest to reading left to right.
    public let rotation: QuarterTurn

    /// Vision normalized coordinates (origin bottom-left) of the frame.
    public var boundingBox: CGRect { quad.boundingBox }

    public init(text: String, confidence: Float, quad: TextQuad, rotation: QuarterTurn = .none) {
        self.text = text
        self.confidence = confidence
        self.quad = quad
        self.rotation = rotation
    }

    public init(text: String, confidence: Float, boundingBox: CGRect, rotation: QuarterTurn = .none) {
        self.init(text: text, confidence: confidence, quad: TextQuad(box: boundingBox), rotation: rotation)
    }
}

/// A passcode the tracker is confident about, emitted once per sighting.
public struct ConfirmedCode: Sendable, Equatable {
    public let code: String
    public let canonicalKey: String
    public let confidence: Float
    public let readCount: Int
    /// Positions where a different character also received a notable share of votes
    /// (typically O/Q, 6/G, S/5). A person should check these against the image.
    public let uncertainPositions: [Int]
    /// Corners of the read that triggered confirmation, so they belong to the current frame.
    public let quad: TextQuad
    /// Text orientation of that same read.
    public let rotation: QuarterTurn

    public var boundingBox: CGRect { quad.boundingBox }
}

public struct TrackSnapshot: Sendable, Equatable, Codable {
    public let bestRead: String
    public let readCount: Int
    public let confirmed: Bool
}

public struct TrackerConfig: Sendable {
    /// Reads within this many canonical edits join the same track, absorbing OCR confusions
    /// such as O/Q, S/5 and B/3 as well as reads shifted by a spurious or missing character.
    public var maxDistance = Passcode.sameCardDistance
    public var minReads = 3
    /// Every position's winning character must lead the runner-up by this much
    /// confidence-weighted vote before the code is confirmed.
    public var decisionMargin: Float = 2
    /// Confirm with the current vote leader after this many reads, or this long after the
    /// first read, even without a clear margin, so an ambiguous card is still recorded
    /// (flagged uncertain) before it leaves the frame. Losing a card is worse than a
    /// flagged guess the reviewer corrects.
    public var forceAfterReads = 5
    public var forceAfterSeconds: TimeInterval = 1.0
    /// A runner-up holding at least this share of a position's votes marks it uncertain.
    public var uncertainShare: Float = 0.2
    /// A track with no reads for this long is dropped; seeing the card again later
    /// counts as a new sighting.
    public var expiry: TimeInterval = 3
    public var maxReadsPerTrack = 30

    public init() {}
}

/// Groups OCR reads across frames into per-card tracks and decides each character
/// by a confidence-weighted vote. Not thread-safe; drive it from one queue.
public final class CandidateTracker {
    private struct Track {
        var reads: [(text: String, confidence: Float)] = []
        var consensus = ""
        var firstSeen: TimeInterval = 0
        var lastSeen: TimeInterval = 0
        var confirmed = false
    }

    private let config: TrackerConfig
    private var tracks: [Track] = []

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    public var activeTracks: [TrackSnapshot] {
        tracks.map { TrackSnapshot(bestRead: $0.consensus, readCount: $0.reads.count, confirmed: $0.confirmed) }
    }

    public func reset() {
        tracks.removeAll()
    }

    /// Feeds all candidate reads of one frame and returns codes confirmed by this frame.
    public func ingest(_ reads: [TextRead], at time: TimeInterval) -> [ConfirmedCode] {
        tracks.removeAll { time - $0.lastSeen > config.expiry }

        var touched: [Int: TextRead] = [:]
        for read in reads where Passcode.isCandidate(read.text) {
            let index = bestTrack(for: read.text, excluding: Set(touched.keys)) ?? {
                tracks.append(Track(firstSeen: time))
                return tracks.count - 1
            }()
            tracks[index].reads.append((read.text, read.confidence))
            if tracks[index].reads.count > config.maxReadsPerTrack {
                tracks[index].reads.removeFirst()
            }
            tracks[index].lastSeen = time
            tracks[index].consensus = Self.consensus(of: Self.alignedReads(tracks[index].reads, maxSubstitutions: config.maxDistance))
            touched[index] = read
        }

        var confirmed: [ConfirmedCode] = []
        for (index, read) in touched.sorted(by: { $0.key < $1.key }) where !tracks[index].confirmed {
            let track = tracks[index]
            guard track.reads.count >= config.minReads else { continue }
            let votes = Self.positionVotes(of: Self.alignedReads(track.reads, maxSubstitutions: config.maxDistance))
            let decided = votes.allSatisfy { $0.top - $0.runnerUp >= config.decisionMargin }
            let forced = track.reads.count >= config.forceAfterReads || time - track.firstSeen >= config.forceAfterSeconds
            guard decided || forced else { continue }

            tracks[index].confirmed = true
            let key = Passcode.canonicalKey(track.consensus)
            let meanConfidence = track.reads.map(\.confidence).reduce(0, +) / Float(track.reads.count)
            let uncertain = votes.indices.filter { votes[$0].runnerUp >= config.uncertainShare * (votes[$0].top + votes[$0].runnerUp) }
            confirmed.append(ConfirmedCode(
                code: track.consensus,
                canonicalKey: key,
                confidence: meanConfidence,
                readCount: track.reads.count,
                uncertainPositions: uncertain,
                quad: read.quad,
                rotation: read.rotation
            ))
        }
        return confirmed
    }

    /// Confidence-weighted votes of the top two canonical classes at each position.
    static func positionVotes(of reads: [(text: String, confidence: Float)]) -> [(top: Float, runnerUp: Float)] {
        guard let length = reads.first?.text.count else { return [] }
        let keys = reads.map { Array(Passcode.canonicalKey($0.text)) }
        return (0..<length).map { position in
            var weights: [Character: Float] = [:]
            for (key, read) in zip(keys, reads) where key.count == length {
                weights[key[position], default: 0] += read.confidence
            }
            let sorted = weights.values.sorted(by: >)
            return (sorted.first ?? 0, sorted.dropFirst().first ?? 0)
        }
    }

    /// The reads that line up character by character with the track's dominant reading.
    /// A shifted read (card edge read as an extra `I`) belongs to the card but would put
    /// every later character in the wrong column, so it is kept out of the vote. The anchor
    /// is the read with the most aligned neighbours; ties go to the most recent read.
    static func alignedReads(_ reads: [(text: String, confidence: Float)], maxSubstitutions: Int) -> [(text: String, confidence: Float)] {
        let keys = reads.map { Passcode.canonicalKey($0.text) }
        func aligned(_ a: String, _ b: String) -> Bool {
            (Passcode.canonicalSubstitutions(a, b) ?? .max) <= maxSubstitutions
        }
        var anchor = 0
        var bestNeighbours = -1
        for (index, key) in keys.enumerated() {
            let neighbours = keys.reduce(0) { $0 + (aligned(key, $1) ? 1 : 0) }
            if neighbours >= bestNeighbours {
                anchor = index
                bestNeighbours = neighbours
            }
        }
        return zip(reads, keys).filter { aligned(keys[anchor], $0.1) }.map(\.0)
    }

    /// Two reads in the same frame are different cards, so a track takes at most one read per frame.
    private func bestTrack(for text: String, excluding used: Set<Int>) -> Int? {
        var best: (index: Int, distance: Int)?
        for (index, track) in tracks.enumerated() where !used.contains(index) {
            let distance = Passcode.canonicalDistance(text, track.consensus)
            guard distance <= config.maxDistance else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Per position, votes first on the canonical class (so O and 0 support each other),
    /// then picks the most-voted raw character inside the winning class.
    static func consensus(of reads: [(text: String, confidence: Float)]) -> String {
        guard let length = reads.first?.text.count else { return "" }
        let columns = reads.map { Array($0.text) }
        var result: [Character] = []
        for position in 0..<length {
            var classWeights: [Character: Float] = [:]
            var rawWeights: [Character: Float] = [:]
            var order: [Character] = []
            for (row, read) in zip(columns, reads) where row.count == length {
                let raw = row[position]
                let cls = Character(Passcode.canonicalKey(String(raw)))
                classWeights[cls, default: 0] += read.confidence
                if rawWeights[raw] == nil { order.append(raw) }
                rawWeights[raw, default: 0] += read.confidence
            }
            guard let winningClass = classWeights.max(by: { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            })?.key,
                let raw = order
                    .filter({ Character(Passcode.canonicalKey(String($0))) == winningClass })
                    .max(by: { rawWeights[$0, default: 0] < rawWeights[$1, default: 0] })
            else { return "" }
            result.append(raw)
        }
        return String(result)
    }
}
