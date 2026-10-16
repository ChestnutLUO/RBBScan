"""Passcode text rules, mirroring PasscodeCore/Sources/PasscodeCore/Passcode.swift.

Both implementations are tested against fixtures/passcode_cases.json.
"""

LENGTH = 16
_ALLOWED = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
# Ingress accepts look-alike characters as the same: O/0/Q -> O, I/1/L -> I, S/5 -> S.
_CANONICAL = str.maketrans({"0": "O", "Q": "O", "1": "I", "L": "I", "5": "S"})


def normalize(raw: str) -> str:
    """Uppercase and drop everything that is not an ASCII letter or digit."""
    return "".join(ch for ch in raw.upper() if ch in _ALLOWED)


def is_candidate(code: str) -> bool:
    return len(code) == LENGTH and all(ch in _ALLOWED for ch in code)


def canonical_key(code: str) -> str:
    return normalize(code).translate(_CANONICAL)


# Reads within this many edits of each other are the same card. OCR slips (O/Q, 6/G, a card
# edge read as I, a dropped character) stay within it, while genuine passcodes differ by
# about 11 edits. Mirrors Passcode.sameCardDistance.
SAME_CARD_DISTANCE = 4


def canonical_distance(a: str, b: str) -> int:
    """Edit distance (substitutions, insertions, deletions) between the canonical keys."""
    ka, kb = canonical_key(a), canonical_key(b)
    previous = list(range(len(kb) + 1))
    for i, ca in enumerate(ka, start=1):
        current = [i]
        for j, cb in enumerate(kb, start=1):
            current.append(min(previous[j - 1] + (ca != cb), previous[j] + 1, current[j - 1] + 1))
        previous = current
    return previous[-1]
