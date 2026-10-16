/// The set of passcodes already scanned, with near-match de-duplication.
///
/// Two genuine 16-character passcodes are astronomically unlikely to be within a few edits
/// of each other, while OCR slips (O/Q, 6/G, a card edge read as `I`) produce exactly that.
/// So a code within `fuzzyDistance` edits of a known one counts as the same card seen again.
/// Mirrors `_find_match` in `server/rbbscan/db.py`, which is the source of truth.
public struct PasscodeRegistry: Sendable {
    public struct Entry: Sendable, Equatable {
        public let canonicalKey: String
        public var seenCount: Int
    }

    public enum Outcome: Sendable, Equatable {
        case new
        case duplicate(canonicalKey: String, seenCount: Int)
    }

    public let fuzzyDistance: Int
    private var entries: [String: Entry] = [:]

    public init(fuzzyDistance: Int = Passcode.sameCardDistance) {
        self.fuzzyDistance = fuzzyDistance
    }

    public var uniqueCount: Int { entries.count }

    /// Canonical key of the known passcode `code` matches, exactly or within `fuzzyDistance`.
    public func match(_ code: String) -> String? {
        let key = Passcode.canonicalKey(code)
        if entries[key] != nil { return key }
        var best: (key: String, distance: Int)?
        for known in entries.keys {
            let distance = Passcode.canonicalDistance(known, key)
            guard distance <= fuzzyDistance else { continue }
            if let current = best, (current.distance, current.key) <= (distance, known) { continue }
            best = (known, distance)
        }
        return best?.key
    }

    /// Records a sighting and reports whether the card was new.
    @discardableResult
    public mutating func record(_ code: String) -> Outcome {
        if let key = match(code), var entry = entries[key] {
            entry.seenCount += 1
            entries[key] = entry
            return .duplicate(canonicalKey: key, seenCount: entry.seenCount)
        }
        let key = Passcode.canonicalKey(code)
        entries[key] = Entry(canonicalKey: key, seenCount: 1)
        return .new
    }

    /// Adds the server's passcodes (canonical key → seen count). Local entries the server
    /// does not know yet (scans still waiting to upload) are kept.
    public mutating func merge(serverKeys known: [String: Int]) {
        for (key, count) in known {
            let local = entries[key]?.seenCount ?? 0
            entries[key] = Entry(canonicalKey: key, seenCount: max(local, count))
        }
    }

    public func seenCount(of canonicalKey: String) -> Int {
        entries[canonicalKey]?.seenCount ?? 0
    }
}
