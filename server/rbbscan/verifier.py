"""Second opinion on the scanned passcodes from an OpenAI vision model.

The iPhone's OCR occasionally confirms text that is not a passcode (the sleeve's
"FOR INVENTORY TRACKING ONLY"), a misread of a card it already has, or a code whose
characters it was unsure of. Once every card is scanned, the reviewer starts a check of
the low-confidence passcodes (or all of them). The label images go to the model as a
numbered matrix, several passcodes per request; the model reads each cell independently
and `Database.apply_ai_reading` removes, merges, corrects or confirms the row.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import tempfile
from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from typing import Literal, Protocol, get_args

from fastapi.concurrency import run_in_threadpool
from openai import AsyncOpenAI, OpenAIError
from PIL import Image, ImageDraw, ImageFont
from pydantic import BaseModel, Field, ValidationError

from .db import AIOutcome, AISubject, Database

log = logging.getLogger(__name__)

DEFAULT_MODEL = "gpt-6.1-sol"
SHEET_SIZE = 6

# Matrix layout: one column of cells, each a number tab beside a label crop scaled to a
# common width. A single column keeps each label near its stored resolution, and six cells
# keep a typical matrix under the 2048 px the model's image pipeline fits images to.
LABEL_WIDTH = 640
LABEL_MAX_HEIGHT = 300
TAB_WIDTH = 96
CELL_PADDING = 10
RULE_HEIGHT = 8

INSTRUCTIONS = """\
You double-check passcodes that an OCR app read from Ingress "RARE Battle Beacon" cards.

The image is a matrix of numbered cells stacked top to bottom and separated by thick red
rules. Each cell has its number in a black tab on the left and, to the right, a photo
crop around one card's passcode label: a white strip with a castle-battlement top edge,
printed with exactly 16 dark characters from A-Z and 0-9. Parts of other cards, including
their labels, may be visible in a crop; read only the label nearest the centre of that
cell's photo. The text may be rotated or slanted. The cells are unrelated cards, so read
each one on its own.

Return one entry per cell, with `cell` set to the number in its tab, and decide:
- "passcode": you can read all 16 characters of that label. Put them in `passcode`, left to
  right, uppercase, without spaces.
- "not_a_passcode": the centred text is not a passcode label at all, for example the card's
  description text, packaging or sleeve print, or other printed words.
- "unreadable": it is a passcode label, but blur, glare or cropping keeps you from reading
  every character with confidence.

Leave `passcode` empty unless the verdict is "passcode". Read each character on its own, as
the codes are random. O/0/Q, I/1/L and S/5 count as the same character, but B/8, G/6, D/O,
Z/2, U/V, M/N, K/X and E/F do not, so look closely at those.
"""


Verdict = Literal["passcode", "not_a_passcode", "unreadable"]


class Reading(BaseModel):
    """The model's verdict on one label."""

    verdict: Verdict
    passcode: str = Field(description="The 16 characters when verdict is passcode, else empty")


class CellReading(Reading):
    cell: int = Field(description="The number in the cell's tab")


class SheetReading(BaseModel):
    """Structured output the model must return for a matrix."""

    cells: list[CellReading]


class PasscodeReader(Protocol):
    async def read(self, labels: Sequence[bytes]) -> list[Reading]:
        """One reading per label JPEG, in the same order."""
        ...


class ReaderError(Exception):
    """The model answered without a usable structured reading (for example a refusal, or
    a matrix answer that skips or repeats a cell)."""


class RateLimitedError(ReaderError):
    """The plan's rate limit refused the request even after waiting."""


def ordered_readings(sheet: SheetReading, count: int) -> list[Reading]:
    """The sheet's readings in cell order, provided every cell 1..count is answered once."""
    numbers = sorted(cell.cell for cell in sheet.cells)
    if numbers != list(range(1, count + 1)):
        raise ReaderError(f"expected cells 1..{count}, got {numbers}")
    by_number = {cell.cell: cell for cell in sheet.cells}
    return [Reading(verdict=by_number[n].verdict, passcode=by_number[n].passcode) for n in range(1, count + 1)]


def label_matrix(labels: Sequence[bytes]) -> bytes:
    """Stacks the label JPEGs into one numbered matrix image (cells numbered from 1)."""
    font = ImageFont.load_default(size=56)
    cells: list[Image.Image] = []
    for number, data in enumerate(labels, start=1):
        with Image.open(io.BytesIO(data)) as source:
            label = source.convert("RGB")
        scale = min(LABEL_WIDTH / label.width, LABEL_MAX_HEIGHT / label.height)
        label = label.resize((max(1, round(label.width * scale)), max(1, round(label.height * scale))), Image.Resampling.LANCZOS)
        height = max(label.height, TAB_WIDTH) + 2 * CELL_PADDING
        cell = Image.new("RGB", (TAB_WIDTH + LABEL_WIDTH + 2 * CELL_PADDING, height), "white")
        draw = ImageDraw.Draw(cell)
        draw.rectangle((0, 0, TAB_WIDTH - 1, height - 1), fill="black")
        draw.text((TAB_WIDTH / 2, height / 2), str(number), fill="white", font=font, anchor="mm")
        cell.paste(label, (TAB_WIDTH + CELL_PADDING, (height - label.height) // 2))
        cells.append(cell)

    width = cells[0].width
    sheet = Image.new("RGB", (width, sum(c.height for c in cells) + RULE_HEIGHT * (len(cells) - 1)), (200, 0, 0))
    top = 0
    for cell in cells:
        sheet.paste(cell, (0, top))
        top += cell.height + RULE_HEIGHT
    buffer = io.BytesIO()
    sheet.save(buffer, format="JPEG", quality=92)
    return buffer.getvalue()


# SheetReading as a strict JSON Schema (every property required, no extras), which is what
# structured output accepts.
SHEET_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["cells"],
    "properties": {
        "cells": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["cell", "verdict", "passcode"],
                "properties": {
                    "cell": {"type": "integer"},
                    "verdict": {"type": "string", "enum": list(get_args(Verdict))},
                    "passcode": {"type": "string"},
                },
            },
        },
    },
}


class CodexReader:
    """Reads matrices through the Codex CLI, so the check runs on the ChatGPT plan that
    `codex login` signed in with rather than on an API key.

    Each matrix is one ephemeral, read-only `codex exec` run in a scratch directory holding
    only the image and the answer schema. A ChatGPT plan allows only a few requests a minute,
    so a 429 answer waits out `rate_limit_waits` (seconds) before the matrix counts as failed.
    """

    def __init__(
        self,
        model: str = "",
        executable: str = "codex",
        timeout: float = 600.0,
        rate_limit_waits: Sequence[float] = (60, 120, 240, 480),
    ) -> None:
        self.model = model
        self._executable = executable
        self._timeout = timeout
        self._rate_limit_waits = tuple(rate_limit_waits)

    async def read(self, labels: Sequence[bytes]) -> list[Reading]:
        matrix = await run_in_threadpool(label_matrix, labels)
        for wait in self._rate_limit_waits:
            try:
                return await self._read_matrix(matrix, len(labels))
            except RateLimitedError:
                log.warning("codex is rate limited; retrying in %.0f s", wait)
                await asyncio.sleep(wait)
        return await self._read_matrix(matrix, len(labels))

    async def _read_matrix(self, matrix: bytes, count: int) -> list[Reading]:
        with tempfile.TemporaryDirectory(prefix="rbbscan-codex-") as scratch:
            folder = Path(scratch)
            (folder / "matrix.jpg").write_bytes(matrix)
            (folder / "schema.json").write_text(json.dumps(SHEET_SCHEMA))
            answer = folder / "answer.json"
            command = [
                self._executable, "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                "--color", "never", "-C", scratch, "-i", "matrix.jpg",
                "--output-schema", "schema.json", "-o", str(answer),
            ]
            if self.model:
                command += ["-m", self.model]
            prompt = (
                f"{INSTRUCTIONS}\nThe attached image is the matrix. It has {count} cells, numbered 1 to "
                f"{count}. Answer from the image alone; do not run any commands."
            )
            process = await asyncio.create_subprocess_exec(
                *command, "-", cwd=scratch,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
            )
            try:
                _, stderr = await asyncio.wait_for(process.communicate(prompt.encode()), self._timeout)
            except TimeoutError as error:
                process.kill()
                await process.wait()
                raise ReaderError(f"codex gave no answer within {self._timeout:.0f} s") from error
            if process.returncode != 0:
                raise _codex_error(process.returncode, stderr.decode(errors="replace"))
            try:
                sheet = SheetReading.model_validate_json(answer.read_text())
            except (OSError, ValidationError) as error:
                raise ReaderError(f"codex answer is not a matrix reading: {error}") from error
        return ordered_readings(sheet, count)


def _codex_error(returncode: int, stderr: str) -> ReaderError:
    """Codex prints config warnings before the real failure; keep its ERROR lines when there are any."""
    errors = [line for line in stderr.splitlines() if line.startswith("ERROR")]
    message = f"codex exited with {returncode}: {' '.join(errors) or stderr[-300:]}"
    if "429" in message or "Too Many Requests" in message:
        return RateLimitedError(message)
    return ReaderError(message)


class OpenAIReader:
    def __init__(self, api_key: str, model: str = DEFAULT_MODEL, timeout: float = 180.0) -> None:
        self.model = model
        self._client = AsyncOpenAI(api_key=api_key, timeout=timeout, max_retries=3)

    async def read(self, labels: Sequence[bytes]) -> list[Reading]:
        matrix = await run_in_threadpool(label_matrix, labels)
        image_url = "data:image/jpeg;base64," + base64.b64encode(matrix).decode("ascii")
        response = await self._client.responses.parse(
            model=self.model,
            instructions=INSTRUCTIONS,
            input=[{"role": "user", "content": [
                {"type": "input_text", "text": f"This matrix has {len(labels)} cells, numbered 1 to {len(labels)}."},
                {"type": "input_image", "image_url": image_url, "detail": "high"},
            ]}],
            text_format=SheetReading,
            store=False,
        )
        if response.output_parsed is None:
            raise ReaderError(f"no structured reading: {response.output_text[:200]!r}")
        return ordered_readings(response.output_parsed, len(labels))

    async def close(self) -> None:
        await self._client.close()


def rotated_jpeg(data: bytes, rotation: int) -> bytes:
    """`data` turned clockwise by `rotation` degrees (0, 90, 180 or 270)."""
    if rotation == 0:
        return data
    transpose = {
        90: Image.Transpose.ROTATE_270,
        180: Image.Transpose.ROTATE_180,
        270: Image.Transpose.ROTATE_90,
    }[rotation]
    with Image.open(io.BytesIO(data)) as image:
        turned = image.transpose(transpose)
        buffer = io.BytesIO()
        turned.save(buffer, format="JPEG", quality=92)
        return buffer.getvalue()


def upright_label(path: Path, rotation: int) -> bytes:
    """The stored label image turned upright; raises OSError when it is missing or corrupt,
    so one bad file fails only its own passcode, not the whole matrix."""
    data = path.read_bytes()
    with Image.open(io.BytesIO(data)) as image:
        image.load()
    return rotated_jpeg(data, rotation)


class Verifier:
    """Checks queued passcodes in the background, up to `sheet_size` per model request and
    `concurrency` requests at a time.

    `on_outcome` runs on the event loop after each check, so it may publish events.
    """

    def __init__(
        self,
        db: Database,
        reader: PasscodeReader,
        image_dir: Path,
        on_outcome: Callable[[AIOutcome], Awaitable[None]],
        concurrency: int = 3,
        sheet_size: int = SHEET_SIZE,
    ) -> None:
        self._db = db
        self._reader = reader
        self._image_dir = image_dir
        self._on_outcome = on_outcome
        self._concurrency = concurrency
        self._sheet_size = sheet_size
        self._queue: asyncio.Queue[int] = asyncio.Queue()
        self._waiting: set[int] = set()
        self._busy = 0

    def enqueue(self, passcode_id: int) -> None:
        if passcode_id not in self._waiting:
            self._waiting.add(passcode_id)
            self._queue.put_nowait(passcode_id)

    @property
    def backlog(self) -> int:
        """Passcodes queued or being checked right now."""
        return len(self._waiting) + self._busy

    async def run(self) -> None:
        async with asyncio.TaskGroup() as group:
            for _ in range(self._concurrency):
                group.create_task(self._work())

    async def join(self) -> None:
        """Waits until everything queued so far has been checked."""
        await self._queue.join()

    async def _work(self) -> None:
        while True:
            batch = [await self._queue.get()]
            while len(batch) < self._sheet_size and not self._queue.empty():
                batch.append(self._queue.get_nowait())
            self._waiting.difference_update(batch)
            self._busy += len(batch)
            try:
                for outcome in await self.check(batch):
                    await self._on_outcome(outcome)
            except Exception:
                log.exception("vision check of passcodes %s failed", batch)
            finally:
                self._busy -= len(batch)
                for _ in batch:
                    self._queue.task_done()

    async def check(self, passcode_ids: Sequence[int]) -> list[AIOutcome]:
        """Reads the labels of `passcode_ids` in one matrix and applies each reading."""
        outcomes: list[AIOutcome] = []
        subjects: list[AISubject] = []
        labels: list[bytes] = []
        for passcode_id in passcode_ids:
            subject = await run_in_threadpool(self._db.ai_subject, passcode_id)
            if subject is None:
                continue
            try:
                labels.append(await run_in_threadpool(upright_label, self._image_dir / subject.label_img, subject.rotation))
            except OSError as error:
                outcomes.append(await self._failed(subject, error))
                continue
            subjects.append(subject)
        if not subjects:
            return outcomes

        try:
            readings = await self._reader.read(labels)
            if len(readings) != len(subjects):
                raise ReaderError(f"{len(readings)} readings for {len(subjects)} labels")
        except (OSError, OpenAIError, ReaderError) as error:
            for subject in subjects:
                outcomes.append(await self._failed(subject, error))
            return outcomes

        for subject, reading in zip(subjects, readings, strict=True):
            outcome = await run_in_threadpool(
                self._db.apply_ai_reading, subject.passcode_id, subject.display_code, reading.verdict, reading.passcode
            )
            for name in outcome.unused_images:
                (self._image_dir / name).unlink(missing_ok=True)
            log.info("vision check %s: %s (model read %r)", subject.display_code, outcome.action, outcome.ai_read)
            outcomes.append(outcome)
        return outcomes

    async def _failed(self, subject: AISubject, error: Exception) -> AIOutcome:
        log.warning("vision check of %s failed: %s", subject.display_code, error)
        return await run_in_threadpool(self._db.mark_ai_error, subject.passcode_id, subject.display_code, str(error))
