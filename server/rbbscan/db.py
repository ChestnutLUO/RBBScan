"""SQLite storage for passcodes and the individual scans that produced them."""

from __future__ import annotations

import json
import sqlite3
import threading
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from . import passcode

# Two genuine passcodes are astronomically unlikely to be within a few edits of each other,
# while OCR slips (O/Q, 6/G, a card edge read as I) produce exactly that. Mirrors PasscodeRegistry.swift.
FUZZY_DISTANCE = passcode.SAME_CARD_DISTANCE
# The vision model and the OCR looked at the same label when their codes are this close; a
# reading further away is most likely of a neighbouring card's label (random codes differ by
# about 11 edits).
SAME_LABEL_DISTANCE = 2 * passcode.SAME_CARD_DISTANCE

_SCHEMA = """
CREATE TABLE IF NOT EXISTS passcodes (
    id INTEGER PRIMARY KEY,
    canonical_key TEXT NOT NULL UNIQUE,
    display_code TEXT NOT NULL,
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 0,
    verified INTEGER NOT NULL DEFAULT 0,
    needs_review INTEGER NOT NULL DEFAULT 0,
    uncertain_positions TEXT NOT NULL DEFAULT '[]',
    note TEXT NOT NULL DEFAULT '',
    ai_status TEXT NOT NULL DEFAULT 'pending',
    ai_read TEXT NOT NULL DEFAULT '',
    rotation INTEGER NOT NULL DEFAULT 0,
    group_id INTEGER REFERENCES groups(id)
);
CREATE TABLE IF NOT EXISTS groups (
    id INTEGER PRIMARY KEY,
    started_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY,
    scan_uuid TEXT NOT NULL UNIQUE,
    passcode_id INTEGER NOT NULL REFERENCES passcodes(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    confidence REAL NOT NULL,
    read_count INTEGER NOT NULL,
    uncertain_positions TEXT NOT NULL,
    device TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    was_new INTEGER NOT NULL,
    label_img TEXT,
    card_img TEXT,
    frame_img TEXT
);
CREATE INDEX IF NOT EXISTS scans_passcode ON scans(passcode_id);
CREATE TABLE IF NOT EXISTS removed (
    id INTEGER PRIMARY KEY,
    display_code TEXT NOT NULL,
    seen_count INTEGER NOT NULL,
    reason TEXT NOT NULL,
    ai_read TEXT NOT NULL,
    merged_into INTEGER REFERENCES passcodes(id) ON DELETE SET NULL,
    label_img TEXT,
    removed_at TEXT NOT NULL
);
"""

# Columns added after the first release; ALTER TABLE brings older databases up to date.
_ADDED_COLUMNS = {
    "passcodes": [
        ("ai_status", "TEXT NOT NULL DEFAULT 'pending'"),
        ("ai_read", "TEXT NOT NULL DEFAULT ''"),
        ("rotation", "INTEGER NOT NULL DEFAULT 0"),
        ("group_id", "INTEGER REFERENCES groups(id)"),
    ],
}

ROTATIONS = (0, 90, 180, 270)

_LOW_CONFIDENCE = "(needs_review = 1 OR uncertain_positions != '[]')"


class AIStatus:
    """Outcome of the vision-model check of a passcode's label image."""

    PENDING = "pending"
    CONFIRMED = "confirmed"
    CORRECTED = "corrected"
    UNREADABLE = "unreadable"
    MISMATCH = "mismatch"
    ERROR = "error"


class AIVerdict:
    """What the vision model saw in the label image."""

    PASSCODE = "passcode"
    NOT_A_PASSCODE = "not_a_passcode"
    UNREADABLE = "unreadable"


class ConflictError(Exception):
    """An edit would make two rows represent the same passcode."""


class NotFoundError(Exception):
    pass


@dataclass(frozen=True)
class ScanInput:
    scan_uuid: str
    code: str
    confidence: float
    read_count: int
    uncertain_positions: list[int]
    device: str
    captured_at: str
    label_img: str | None
    card_img: str | None
    frame_img: str | None


@dataclass(frozen=True)
class AISubject:
    """What the vision model is asked to check: the code as stored and its label image."""

    passcode_id: int
    display_code: str
    label_img: str
    rotation: int


@dataclass(frozen=True)
class AIOutcome:
    """`action` is an AIStatus value, or "merged" / "removed" when the row is gone, or
    "stale" when the row changed while the model was reading it."""

    action: str
    code: str
    ai_read: str
    passcode: dict[str, Any] | None = None
    merged_into: dict[str, Any] | None = None
    unused_images: tuple[str, ...] = ()


@dataclass(frozen=True)
class ScanResult:
    is_new: bool
    already_recorded: bool
    passcode: dict[str, Any]
    unique_total: int


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class Database:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA journal_mode = WAL")
        self._conn.executescript(_SCHEMA)
        for table, columns in _ADDED_COLUMNS.items():
            existing = {row["name"] for row in self._conn.execute(f"PRAGMA table_info({table})")}
            for name, definition in columns:
                if name not in existing:
                    self._conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")
        if self._conn.execute("SELECT 1 FROM groups").fetchone() is None:
            self._conn.execute("INSERT INTO groups (started_at) VALUES (?)", (_now(),))
        self._conn.execute("UPDATE passcodes SET group_id = (SELECT MIN(id) FROM groups) WHERE group_id IS NULL")
        self._conn.commit()
        self._lock = threading.Lock()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # -- scans -----------------------------------------------------------------

    def _find_match(self, code: str, excluding: int | None = None) -> sqlite3.Row | None:
        """Existing passcode equal to `code` under canonical keys, else the nearest within FUZZY_DISTANCE."""
        key = passcode.canonical_key(code)
        row = self._conn.execute(
            "SELECT * FROM passcodes WHERE canonical_key = ? AND id IS NOT ?", (key, excluding)
        ).fetchone()
        if row is not None:
            return row
        best: tuple[int, str, sqlite3.Row] | None = None
        for candidate in self._conn.execute("SELECT * FROM passcodes WHERE id IS NOT ?", (excluding,)):
            distance = passcode.canonical_distance(candidate["canonical_key"], key)
            if distance > FUZZY_DISTANCE:
                continue
            rank = (distance, candidate["canonical_key"])
            if best is None or rank < best[:2]:
                best = (distance, candidate["canonical_key"], candidate)
        return best[2] if best else None

    def scan_exists(self, scan_uuid: str) -> bool:
        with self._lock:
            return self._conn.execute("SELECT 1 FROM scans WHERE scan_uuid = ?", (scan_uuid,)).fetchone() is not None

    def record_scan(self, scan: ScanInput) -> ScanResult:
        code = passcode.normalize(scan.code)
        if not passcode.is_candidate(code):
            raise ValueError(f"not a passcode: {scan.code!r}")
        now = _now()
        with self._lock, self._conn:
            existing_scan = self._conn.execute(
                "SELECT passcode_id, was_new FROM scans WHERE scan_uuid = ?", (scan.scan_uuid,)
            ).fetchone()
            if existing_scan is not None:
                return ScanResult(
                    is_new=bool(existing_scan["was_new"]),
                    already_recorded=True,
                    passcode=self._passcode_dict(existing_scan["passcode_id"]),
                    unique_total=self._unique_total(),
                )

            match = self._find_match(code)
            uncertain = json.dumps(sorted(set(scan.uncertain_positions)))
            if match is None:
                cursor = self._conn.execute(
                    """INSERT INTO passcodes (canonical_key, display_code, first_seen, last_seen,
                           seen_count, needs_review, uncertain_positions, group_id)
                       VALUES (?, ?, ?, ?, 1, ?, ?, ?)""",
                    (passcode.canonical_key(code), code, now, now, int(bool(scan.uncertain_positions)), uncertain,
                     self._current_group_id()),
                )
                passcode_id = cursor.lastrowid
                is_new = True
            else:
                passcode_id = match["id"]
                is_new = False
                # A differing reading of a known card means at least one OCR result is wrong.
                variant = passcode.canonical_key(code) != match["canonical_key"]
                self._conn.execute(
                    """UPDATE passcodes SET seen_count = seen_count + 1, last_seen = ?,
                           needs_review = CASE WHEN verified = 0 AND ? THEN 1 ELSE needs_review END
                       WHERE id = ?""",
                    (now, int(variant), passcode_id),
                )
            self._conn.execute(
                """INSERT INTO scans (scan_uuid, passcode_id, code, confidence, read_count,
                       uncertain_positions, device, captured_at, received_at, was_new,
                       label_img, card_img, frame_img)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    scan.scan_uuid, passcode_id, code, scan.confidence, scan.read_count, uncertain,
                    scan.device, scan.captured_at, now, int(is_new),
                    scan.label_img, scan.card_img, scan.frame_img,
                ),
            )
            return ScanResult(
                is_new=is_new,
                already_recorded=False,
                passcode=self._passcode_dict(passcode_id),
                unique_total=self._unique_total(),
            )

    # -- passcodes -------------------------------------------------------------

    def list_passcodes(
        self,
        query: str = "",
        unverified_only: bool = False,
        review_only: bool = False,
        group_id: int | None = None,
    ) -> list[dict[str, Any]]:
        clauses, params = [], []
        if group_id is not None:
            clauses.append("group_id = ?")
            params.append(group_id)
        if query:
            clauses.append("(canonical_key LIKE ? OR display_code LIKE ? OR note LIKE ?)")
            key = f"%{passcode.canonical_key(query) or query.upper()}%"
            params += [key, f"%{query.upper()}%", f"%{query}%"]
        if unverified_only:
            clauses.append("verified = 0")
        if review_only:
            clauses.append("needs_review = 1")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._lock:
            ids = [r["id"] for r in self._conn.execute(f"SELECT id FROM passcodes {where} ORDER BY id DESC", params)]
            return [self._passcode_dict(i) for i in ids]

    def get_passcode(self, passcode_id: int) -> dict[str, Any]:
        with self._lock:
            return self._passcode_dict(passcode_id)

    def update_passcode(
        self,
        passcode_id: int,
        display_code: str | None = None,
        verified: bool | None = None,
        note: str | None = None,
        rotation: int | None = None,
    ) -> dict[str, Any]:
        if rotation is not None and rotation not in ROTATIONS:
            raise ValueError(f"rotation must be one of {ROTATIONS}")
        with self._lock, self._conn:
            self._require(passcode_id)
            if rotation is not None:
                self._conn.execute("UPDATE passcodes SET rotation = ? WHERE id = ?", (rotation, passcode_id))
            if display_code is not None:
                code = passcode.normalize(display_code)
                if not passcode.is_candidate(code):
                    raise ValueError(f"not a passcode: {display_code!r}")
                key = passcode.canonical_key(code)
                clash = self._conn.execute(
                    "SELECT id FROM passcodes WHERE canonical_key = ? AND id != ?", (key, passcode_id)
                ).fetchone()
                if clash is not None:
                    raise ConflictError(f"passcode #{clash['id']} already has this code")
                self._conn.execute(
                    "UPDATE passcodes SET display_code = ?, canonical_key = ? WHERE id = ?", (code, key, passcode_id)
                )
            if verified is not None:
                self._conn.execute(
                    "UPDATE passcodes SET verified = ?, needs_review = CASE WHEN ? THEN 0 ELSE needs_review END WHERE id = ?",
                    (int(verified), int(verified), passcode_id),
                )
            if note is not None:
                self._conn.execute("UPDATE passcodes SET note = ? WHERE id = ?", (note, passcode_id))
            return self._passcode_dict(passcode_id)

    def delete_passcode(self, passcode_id: int) -> list[str]:
        """Deletes a passcode and its scans; returns the image file names that are no longer referenced."""
        with self._lock, self._conn:
            self._require(passcode_id)
            images = [
                name
                for row in self._conn.execute(
                    "SELECT label_img, card_img, frame_img FROM scans WHERE passcode_id = ?", (passcode_id,)
                )
                for name in row
                if name
            ]
            self._conn.execute("DELETE FROM scans WHERE passcode_id = ?", (passcode_id,))
            self._conn.execute("DELETE FROM passcodes WHERE id = ?", (passcode_id,))
            if self._unique_total() == 0:
                # An emptied database is a fresh start, so numbering begins again at group 1.
                self._conn.execute("DELETE FROM groups")
                self._conn.execute("INSERT INTO groups (id, started_at) VALUES (1, ?)", (_now(),))
            return images

    # -- groups ------------------------------------------------------------------
    # Cards are scanned in stacks; the reviewer starts a new group before each stack, and every
    # passcode first seen afterwards belongs to it. A group whose count differs from the stack
    # size shows where cards were missed or misread.

    def groups(self) -> list[dict[str, Any]]:
        with self._lock:
            return [
                dict(r)
                for r in self._conn.execute(
                    """SELECT g.id, g.started_at, COUNT(p.id) AS count,
                              COALESCE(SUM(p.needs_review), 0) AS needs_review
                       FROM groups g LEFT JOIN passcodes p ON p.group_id = g.id
                       GROUP BY g.id ORDER BY g.id"""
                )
            ]

    def current_group(self) -> dict[str, Any]:
        with self._lock:
            return self._group_dict(self._current_group_id())

    def next_group(self) -> dict[str, Any]:
        """Starts a new group, unless the current one is still empty (a double click)."""
        with self._lock, self._conn:
            current = self._current_group_id()
            if self._group_count(current) == 0:
                return self._group_dict(current)
            cursor = self._conn.execute("INSERT INTO groups (started_at) VALUES (?)", (_now(),))
            return self._group_dict(cursor.lastrowid)

    # -- vision-model check ------------------------------------------------------

    def ai_queue(self, low_confidence_only: bool = False) -> list[int]:
        """Unverified passcodes the model has not checked yet, or failed to check, oldest first.

        Low confidence means flagged for review (a near-duplicate reading or an earlier check)
        or with characters the scanner's vote could not settle.
        """
        sql = "SELECT id FROM passcodes WHERE verified = 0 AND ai_status IN (?, ?)"
        if low_confidence_only:
            sql += f" AND {_LOW_CONFIDENCE}"
        with self._lock:
            return [r["id"] for r in self._conn.execute(sql + " ORDER BY id", (AIStatus.PENDING, AIStatus.ERROR))]

    def ai_summary(self) -> dict[str, Any]:
        """Passcodes still to check, how many have each AI status, and removed rows by reason."""
        with self._lock:
            row = self._conn.execute(
                f"""SELECT COALESCE(SUM(verified = 0 AND ai_status IN (?, ?)), 0) AS unchecked,
                           COALESCE(SUM(verified = 0 AND ai_status IN (?, ?) AND {_LOW_CONFIDENCE}), 0)
                               AS unchecked_low_confidence
                    FROM passcodes""",
                (AIStatus.PENDING, AIStatus.ERROR, AIStatus.PENDING, AIStatus.ERROR),
            ).fetchone()
            statuses = dict(self._conn.execute("SELECT ai_status, COUNT(*) FROM passcodes GROUP BY ai_status").fetchall())
            removed = dict(self._conn.execute("SELECT reason, COUNT(*) FROM removed GROUP BY reason").fetchall())
            return {**dict(row), "statuses": statuses, "removed": removed}

    def ai_subject(self, passcode_id: int) -> AISubject | None:
        with self._lock:
            row = self._conn.execute(
                """SELECT p.id, p.display_code, p.rotation, s.label_img FROM passcodes p
                   JOIN scans s ON s.passcode_id = p.id AND s.label_img IS NOT NULL
                   WHERE p.id = ? ORDER BY s.id LIMIT 1""",
                (passcode_id,),
            ).fetchone()
            if row is None:
                return None
            return AISubject(row["id"], row["display_code"], row["label_img"], row["rotation"])

    def reset_ai(self, passcode_id: int) -> dict[str, Any]:
        with self._lock, self._conn:
            self._require(passcode_id)
            self._conn.execute(
                "UPDATE passcodes SET ai_status = ?, ai_read = '' WHERE id = ?", (AIStatus.PENDING, passcode_id)
            )
            return self._passcode_dict(passcode_id)

    def mark_ai_error(self, passcode_id: int, checked_code: str, message: str) -> AIOutcome:
        with self._lock, self._conn:
            row = self._conn.execute("SELECT * FROM passcodes WHERE id = ?", (passcode_id,)).fetchone()
            if row is None or row["display_code"] != checked_code:
                return AIOutcome("stale", checked_code, "")
            self._conn.execute(
                "UPDATE passcodes SET ai_status = ?, ai_read = ? WHERE id = ?",
                (AIStatus.ERROR, message[:200], passcode_id),
            )
            return AIOutcome(AIStatus.ERROR, checked_code, "", passcode=self._passcode_dict(passcode_id))

    def apply_ai_reading(self, passcode_id: int, checked_code: str, verdict: str, ai_code: str) -> AIOutcome:
        """Acts on the model's reading of `checked_code`'s label image.

        * Not a passcode (sleeve or description text the OCR mistook for one): the row is removed.
        * The model's code is another row's passcode: this row was a misread of that card, so its
          sightings move there and this row is removed.
        * Same canonical key: confirmed. Within SAME_LABEL_DISTANCE: the OCR misread characters
          and the row takes the model's code, flagged for review. Further away: the model probably
          read a neighbouring card's label, so nothing changes and the row is flagged.
        * Unreadable: flagged for review.
        A row a person has verified or edited meanwhile is left alone.
        """
        code = passcode.normalize(ai_code)
        with self._lock, self._conn:
            row = self._conn.execute("SELECT * FROM passcodes WHERE id = ?", (passcode_id,)).fetchone()
            if row is None or row["display_code"] != checked_code or row["verified"]:
                return AIOutcome("stale", checked_code, code)

            if verdict == AIVerdict.NOT_A_PASSCODE:
                return self._remove(row, "not a passcode", code, merged_into=None)
            if verdict != AIVerdict.PASSCODE or not passcode.is_candidate(code):
                return self._set_ai(row, AIStatus.UNREADABLE, code, needs_review=True)

            key = passcode.canonical_key(code)
            if key == row["canonical_key"]:
                return self._set_ai(row, AIStatus.CONFIRMED, code, needs_review=False)
            if passcode.canonical_distance(key, row["canonical_key"]) > SAME_LABEL_DISTANCE:
                return self._set_ai(row, AIStatus.MISMATCH, code, needs_review=True)
            other = self._find_match(code, excluding=passcode_id)
            if other is not None:
                return self._remove(row, "misread of another card", code, merged_into=other)
            self._conn.execute(
                """UPDATE passcodes SET display_code = ?, canonical_key = ?, ai_status = ?, ai_read = ?,
                       needs_review = 1 WHERE id = ?""",
                (code, key, AIStatus.CORRECTED, code, passcode_id),
            )
            return AIOutcome(AIStatus.CORRECTED, checked_code, code, passcode=self._passcode_dict(passcode_id))

    def removed(self, limit: int = 100) -> list[dict[str, Any]]:
        with self._lock:
            return [
                dict(r)
                for r in self._conn.execute("SELECT * FROM removed ORDER BY id DESC LIMIT ?", (limit,))
            ]

    def _set_ai(self, row: sqlite3.Row, status: str, ai_code: str, needs_review: bool) -> AIOutcome:
        self._conn.execute(
            "UPDATE passcodes SET ai_status = ?, ai_read = ?, needs_review = ? WHERE id = ?",
            (status, ai_code, int(needs_review), row["id"]),
        )
        return AIOutcome(status, row["display_code"], ai_code, passcode=self._passcode_dict(row["id"]))

    def _remove(self, row: sqlite3.Row, reason: str, ai_code: str, merged_into: sqlite3.Row | None) -> AIOutcome:
        """Deletes `row`, logging it in `removed`. A merge moves its sightings to `merged_into`;
        otherwise its images go, except the first label, which the log keeps as evidence."""
        scans = self._conn.execute(
            "SELECT label_img, card_img, frame_img FROM scans WHERE passcode_id = ? ORDER BY id", (row["id"],)
        ).fetchall()
        kept_label = next((s["label_img"] for s in scans if s["label_img"]), None)
        unused: tuple[str, ...] = ()
        if merged_into is None:
            unused = tuple(name for s in scans for name in s if name and name != kept_label)
            self._conn.execute("DELETE FROM scans WHERE passcode_id = ?", (row["id"],))
        else:
            self._conn.execute("UPDATE scans SET passcode_id = ? WHERE passcode_id = ?", (merged_into["id"], row["id"]))
            self._conn.execute(
                "UPDATE passcodes SET seen_count = seen_count + ?, last_seen = MAX(last_seen, ?) WHERE id = ?",
                (row["seen_count"], row["last_seen"], merged_into["id"]),
            )
        self._conn.execute(
            """INSERT INTO removed (display_code, seen_count, reason, ai_read, merged_into, label_img, removed_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (row["display_code"], row["seen_count"], reason, ai_code,
             merged_into["id"] if merged_into is not None else None, kept_label, _now()),
        )
        self._conn.execute("DELETE FROM passcodes WHERE id = ?", (row["id"],))
        action = "merged" if merged_into is not None else "removed"
        target = self._passcode_dict(merged_into["id"]) if merged_into is not None else None
        return AIOutcome(action, row["display_code"], ai_code, merged_into=target, unused_images=unused)

    def known_keys(self) -> dict[str, int]:
        with self._lock:
            return {r["canonical_key"]: r["seen_count"] for r in self._conn.execute("SELECT canonical_key, seen_count FROM passcodes")}

    def recent_scans(self, limit: int = 10) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT s.*, p.display_code, p.seen_count, p.rotation, p.ai_status, p.ai_read
                   FROM scans s JOIN passcodes p ON p.id = s.passcode_id
                   ORDER BY s.id DESC LIMIT ?""",
                (limit,),
            ).fetchall()
            return [self._scan_dict(r) for r in rows]

    def stats(self) -> dict[str, Any]:
        with self._lock:
            row = self._conn.execute(
                """SELECT COUNT(*) AS unique_total, COALESCE(SUM(verified), 0) AS verified,
                          COALESCE(SUM(needs_review), 0) AS needs_review,
                          COALESCE(SUM(seen_count), 0) AS total_sightings
                   FROM passcodes"""
            ).fetchone()
            return dict(row)

    # -- helpers (caller holds the lock) ------------------------------------------

    def _require(self, passcode_id: int) -> None:
        if self._conn.execute("SELECT 1 FROM passcodes WHERE id = ?", (passcode_id,)).fetchone() is None:
            raise NotFoundError(passcode_id)

    def _current_group_id(self) -> int:
        return self._conn.execute("SELECT MAX(id) FROM groups").fetchone()[0]

    def _group_count(self, group_id: int) -> int:
        return self._conn.execute("SELECT COUNT(*) FROM passcodes WHERE group_id = ?", (group_id,)).fetchone()[0]

    def _group_dict(self, group_id: int) -> dict[str, Any]:
        row = self._conn.execute("SELECT id, started_at FROM groups WHERE id = ?", (group_id,)).fetchone()
        return {"id": row["id"], "started_at": row["started_at"], "count": self._group_count(group_id)}

    def _unique_total(self) -> int:
        return self._conn.execute("SELECT COUNT(*) FROM passcodes").fetchone()[0]

    def _passcode_dict(self, passcode_id: int) -> dict[str, Any]:
        row = self._conn.execute("SELECT * FROM passcodes WHERE id = ?", (passcode_id,)).fetchone()
        if row is None:
            raise NotFoundError(passcode_id)
        scans = self._conn.execute(
            "SELECT code, label_img, card_img, frame_img FROM scans WHERE passcode_id = ? ORDER BY id", (passcode_id,)
        ).fetchall()
        variants: dict[str, int] = {}
        for s in scans:
            variants[s["code"]] = variants.get(s["code"], 0) + 1
        first = scans[0] if scans else None
        return {
            "id": row["id"],
            "display_code": row["display_code"],
            "canonical_key": row["canonical_key"],
            "seen_count": row["seen_count"],
            "verified": bool(row["verified"]),
            "needs_review": bool(row["needs_review"]),
            "uncertain_positions": json.loads(row["uncertain_positions"]),
            "note": row["note"],
            "ai_status": row["ai_status"],
            "ai_read": row["ai_read"],
            "rotation": row["rotation"],
            "group_id": row["group_id"],
            "first_seen": row["first_seen"],
            "last_seen": row["last_seen"],
            "variants": [{"code": c, "count": n} for c, n in sorted(variants.items(), key=lambda kv: -kv[1])],
            "label_img": first["label_img"] if first else None,
            "card_img": first["card_img"] if first else None,
            "frame_img": first["frame_img"] if first else None,
        }

    @staticmethod
    def _scan_dict(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "scan_uuid": row["scan_uuid"],
            "passcode_id": row["passcode_id"],
            "code": row["code"],
            "display_code": row["display_code"],
            "seen_count": row["seen_count"],
            "was_new": bool(row["was_new"]),
            "uncertain_positions": json.loads(row["uncertain_positions"]),
            "received_at": row["received_at"],
            "label_img": row["label_img"],
            "card_img": row["card_img"],
            "rotation": row["rotation"],
            "ai_status": row["ai_status"],
            "ai_read": row["ai_read"],
        }
