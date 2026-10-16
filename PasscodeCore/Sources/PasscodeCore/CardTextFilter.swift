/// Every card carries the same description text (and the sleeve its own), and any 16-letter run of it
/// looks exactly like a passcode to OCR. A random passcode is astronomically unlikely to land within a
/// few substitutions of any 16-character window of this text, so such reads are rejected.
public struct CardTextFilter: Sendable {
    public static let battleBeaconText = """
    RARE BATTLE BEACON VERY RARE BATTLE BEACON
    A Battle Beacon creates a mini-Anomaly over the Portal to which it's deployed,
    allowing Agents in range to practice and test their battle skills against one
    another. Once a battle begins, a Scoreboard will appear over the target Portal
    indicating points scored by each Faction across a timed battle period. At the end
    of the battle period, the target Portal will be boosted and the Hack output of the
    Battle Beacon will transform into Enlightened, Resistance, or Neutral beacon to
    indicate the winning Faction.
    """

    /// Printed on the plastic sleeve the cards ship in, dark on white like a real label.
    public static let packagingText = "FOR INVENTORY TRACKING ONLY"

    /// Maximum edits (substitutions, insertions, deletions) for a read to count as card text.
    public let maxDistance: Int
    private let text: [UInt8]

    public init(text: String = CardTextFilter.battleBeaconText + " " + CardTextFilter.packagingText, maxDistance: Int = 4) {
        self.maxDistance = maxDistance
        self.text = Array(Passcode.canonicalKey(text).utf8)
    }

    public func isCardText(_ code: String) -> Bool {
        let key = Array(Passcode.canonicalKey(code).utf8)
        guard key.count == Passcode.length else { return false }
        return Self.bestSubstringDistance(of: key, in: text) <= maxDistance
    }

    /// Smallest edit distance between `pattern` and any substring of `text`
    /// (Sellers' algorithm: the match may start anywhere in `text` at no cost).
    static func bestSubstringDistance(of pattern: [UInt8], in text: [UInt8]) -> Int {
        guard !pattern.isEmpty else { return 0 }
        var previous = Array(0...pattern.count)
        var best = previous[pattern.count]
        var current = previous
        for character in text {
            current[0] = 0
            for row in 1...pattern.count {
                let substitution = previous[row - 1] + (pattern[row - 1] == character ? 0 : 1)
                current[row] = min(substitution, previous[row] + 1, current[row - 1] + 1)
            }
            best = min(best, current[pattern.count])
            swap(&previous, &current)
        }
        return best
    }
}
