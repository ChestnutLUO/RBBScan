import Foundation

/// Text rules for RARE Battle Beacon passcodes: exactly 16 characters of `[A-Z0-9]`.
///
/// Must stay in sync with `server/rbbscan/passcode.py`; both are checked against
/// `fixtures/passcode_cases.json`.
public enum Passcode {
    public static let length = 16

    /// Uppercases and drops everything that is not an ASCII letter or digit
    /// (OCR often inserts spaces or stray punctuation inside a code).
    public static func normalize(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter(isAllowed).map(Character.init))
    }

    public static func isCandidate(_ code: String) -> Bool {
        code.unicodeScalars.count == length && code.unicodeScalars.allSatisfy(isAllowed)
    }

    /// Key used for de-duplication. Ingress accepts look-alike characters as the same,
    /// so O/0/Q collapse to `O`, I/1/L to `I` and S/5 to `S`.
    public static func canonicalKey(_ code: String) -> String {
        String(normalize(code).map { ch -> Character in
            switch ch {
            case "0", "Q": return "O"
            case "1", "L": return "I"
            case "5": return "S"
            default: return ch
            }
        })
    }

    /// Reads within this many edits of each other are the same card. OCR slips (O/Q, 6/G,
    /// a card edge read as `I`, a dropped character) stay within it, while genuine passcodes
    /// differ by about 11 edits, so a chance collision among 1050 random codes is ~1e-10.
    public static let sameCardDistance = 4

    /// Edit distance (substitutions, insertions, deletions) between the canonical keys, so a
    /// read shifted by a spurious or missing character still lands near the true code.
    public static func canonicalDistance(_ a: String, _ b: String) -> Int {
        let ka = Array(canonicalKey(a).utf8), kb = Array(canonicalKey(b).utf8)
        guard !ka.isEmpty else { return kb.count }
        guard !kb.isEmpty else { return ka.count }
        var previous = Array(0...kb.count)
        var current = previous
        for (i, ca) in ka.enumerated() {
            current[0] = i + 1
            for (j, cb) in kb.enumerated() {
                current[j + 1] = min(previous[j] + (ca == cb ? 0 : 1), previous[j + 1] + 1, current[j] + 1)
            }
            swap(&previous, &current)
        }
        return previous[kb.count]
    }

    /// Positions whose canonical characters differ; `nil` when lengths differ.
    public static func canonicalSubstitutions(_ a: String, _ b: String) -> Int? {
        let ka = Array(canonicalKey(a)), kb = Array(canonicalKey(b))
        guard ka.count == kb.count else { return nil }
        return zip(ka, kb).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
