"""HTTP API, review page and live dashboard for RBBScan.

Run with ../run_server.sh, which binds to this Mac's Tailscale address.
Event publishing (`hub.publish`) touches asyncio queues and must only be called
from `async def` endpoints running on the event loop.
"""

from __future__ import annotations

import asyncio
import contextlib
import csv
import io
import json
import os
import re
import uuid
from collections.abc import AsyncIterator
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel, Field, ValidationError, field_validator

from . import passcode
from .db import ROTATIONS, AIOutcome, ConflictError, Database, NotFoundError, ScanInput
from .live import EventHub, HeartbeatStatus, ScannerMonitor
from .verifier import DEFAULT_MODEL, CodexReader, OpenAIReader, PasscodeReader, Verifier, rotated_jpeg

TARGET_TOTAL = 1050
GROUP_SIZE = 20
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_PREVIEW_BYTES = 1024 * 1024
KEEPALIVE_SECONDS = 15.0
_IMAGE_NAME = re.compile(r"^[0-9a-f-]{36}_(label|card|frame)\.jpg$")
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
DEFAULT_DATA_DIR = Path(__file__).resolve().parents[2] / "data"


class ScanMeta(BaseModel):
    scan_id: uuid.UUID
    code: str = Field(max_length=64)
    confidence: float = Field(ge=0, le=1)
    read_count: int = Field(ge=1, le=10_000)
    uncertain_positions: list[int] = Field(default_factory=list, max_length=passcode.LENGTH)
    device: str = Field(default="iPhone", max_length=64)
    captured_at: datetime

    @field_validator("code")
    @classmethod
    def must_be_passcode(cls, value: str) -> str:
        code = passcode.normalize(value)
        if not passcode.is_candidate(code):
            raise ValueError(f"must be {passcode.LENGTH} characters of A-Z/0-9")
        return code

    @field_validator("uncertain_positions")
    @classmethod
    def positions_in_range(cls, value: list[int]) -> list[int]:
        if any(not 0 <= p < passcode.LENGTH for p in value):
            raise ValueError(f"positions must be within 0..{passcode.LENGTH - 1}")
        return value


class PasscodeUpdate(BaseModel):
    display_code: str | None = Field(default=None, max_length=64)
    verified: bool | None = None
    note: str | None = Field(default=None, max_length=500)
    rotation: int | None = None

    @field_validator("rotation")
    @classmethod
    def quarter_turn(cls, value: int | None) -> int | None:
        if value is not None and value not in ROTATIONS:
            raise ValueError(f"must be one of {ROTATIONS}")
        return value


def _parse_json_form(model: type[BaseModel], raw: str) -> Any:
    try:
        return model.model_validate(json.loads(raw))
    except (json.JSONDecodeError, ValidationError) as error:
        detail = error.errors(include_url=False, include_context=False) if isinstance(error, ValidationError) else str(error)
        raise HTTPException(status_code=422, detail=detail) from error


async def _read_jpeg(upload: UploadFile | None, field_name: str, limit: int) -> bytes | None:
    if upload is None:
        return None
    data = await upload.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(status_code=413, detail=f"{field_name} is larger than {limit} bytes")
    if not data.startswith(b"\xff\xd8\xff"):
        raise HTTPException(status_code=415, detail=f"{field_name} must be a JPEG")
    return data


def create_app(
    data_dir: Path,
    target_total: int = TARGET_TOTAL,
    reader: PasscodeReader | None = None,
    ai_model: str = "",
    group_size: int = GROUP_SIZE,
    ai_concurrency: int = 3,
) -> FastAPI:
    """`reader` enables the vision-model check, which runs when the reviewer starts it, with up
    to `ai_concurrency` requests at a time."""
    image_dir = data_dir / "images"
    image_dir.mkdir(parents=True, exist_ok=True)
    db = Database(data_dir / "rbbscan.db")
    hub = EventHub()
    monitor = ScannerMonitor()

    async def publish_ai_outcome(outcome: AIOutcome) -> None:
        if outcome.action == "stale":
            return
        hub.publish("ai", {
            "action": outcome.action,
            "code": outcome.code,
            "ai_read": outcome.ai_read,
            "passcode": outcome.passcode,
            "merged_into": outcome.merged_into,
            "stats": await run_in_threadpool(stats),
        })

    verifier = Verifier(db, reader, image_dir, publish_ai_outcome, ai_concurrency) if reader is not None else None

    def stats() -> dict[str, Any]:
        return {
            **db.stats(),
            "target_total": target_total,
            "ai_enabled": verifier is not None,
            "ai_model": ai_model if verifier is not None else "",
            "ai_backlog": verifier.backlog if verifier is not None else 0,
            "ai": db.ai_summary(),
            "group": {**db.current_group(), "size": group_size},
        }

    def groups() -> dict[str, Any]:
        rows = db.groups()
        current = rows[-1]["id"]
        for row in rows:
            if row["count"] > group_size:
                row["status"] = "over"
            elif row["count"] == group_size:
                row["status"] = "full"
            else:
                row["status"] = "open" if row["id"] == current else "short"
        return {"size": group_size, "current": current, "groups": rows}

    async def watch_scanner() -> None:
        """Tells dashboards when the scanner goes quiet, since a dead phone sends nothing."""
        was_online = monitor.online()
        while True:
            await asyncio.sleep(1)
            online = monitor.online()
            if online != was_online:
                hub.publish("status", monitor.snapshot())
                was_online = online

    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        tasks = [asyncio.create_task(watch_scanner())]
        if verifier is not None:
            tasks.append(asyncio.create_task(verifier.run()))
        try:
            yield
        finally:
            for task in tasks:
                task.cancel()
            for task in tasks:
                with contextlib.suppress(asyncio.CancelledError):
                    await task
            close = getattr(reader, "close", None)
            if close is not None:
                await close()
            db.close()

    app = FastAPI(title="RBBScan", lifespan=lifespan)
    app.state.db = db
    app.state.hub = hub
    app.state.monitor = monitor
    app.state.verifier = verifier

    # -- pages -------------------------------------------------------------------

    @app.get("/", include_in_schema=False)
    def review_page() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-store"})

    @app.get("/live", include_in_schema=False)
    def live_page() -> FileResponse:
        return FileResponse(STATIC_DIR / "live.html", headers={"Cache-Control": "no-store"})

    @app.get("/images/{name}", include_in_schema=False)
    def image(name: str, rotate: int = 0) -> Response:
        """`rotate` turns the image clockwise; the URL differs per angle, so caching stays correct."""
        if not _IMAGE_NAME.fullmatch(name) or rotate not in ROTATIONS:
            raise HTTPException(status_code=404)
        path = image_dir / name
        if not path.is_file():
            raise HTTPException(status_code=404)
        cache = {"Cache-Control": "max-age=86400, immutable"}
        if rotate == 0:
            return FileResponse(path, media_type="image/jpeg", headers=cache)
        return Response(rotated_jpeg(path.read_bytes(), rotate), media_type="image/jpeg", headers=cache)

    # -- scanning ----------------------------------------------------------------

    @app.post("/api/scans")
    async def create_scan(
        meta: Annotated[str, Form()],
        label: Annotated[UploadFile, File()],
        card: Annotated[UploadFile | None, File()] = None,
        frame: Annotated[UploadFile | None, File()] = None,
    ) -> dict[str, Any]:
        scan_meta: ScanMeta = _parse_json_form(ScanMeta, meta)
        scan_id = str(scan_meta.scan_id)
        images = {
            "label": await _read_jpeg(label, "label", MAX_IMAGE_BYTES),
            "card": await _read_jpeg(card, "card", MAX_IMAGE_BYTES),
            "frame": await _read_jpeg(frame, "frame", MAX_IMAGE_BYTES),
        }

        # A retried upload must not store its images twice or count the card again.
        retry = await run_in_threadpool(db.scan_exists, scan_id)
        written: list[Path] = []
        names: dict[str, str | None] = {kind: None for kind in images}
        if not retry:
            for kind, data in images.items():
                if data is None:
                    continue
                path = image_dir / f"{scan_id}_{kind}.jpg"
                await run_in_threadpool(path.write_bytes, data)
                written.append(path)
                names[kind] = path.name
        try:
            result = await run_in_threadpool(
                db.record_scan,
                ScanInput(
                    scan_uuid=scan_id,
                    code=scan_meta.code,
                    confidence=scan_meta.confidence,
                    read_count=scan_meta.read_count,
                    uncertain_positions=scan_meta.uncertain_positions,
                    device=scan_meta.device,
                    captured_at=scan_meta.captured_at.isoformat(),
                    label_img=names["label"],
                    card_img=names["card"],
                    frame_img=names["frame"],
                ),
            )
        except Exception:
            for path in written:
                path.unlink(missing_ok=True)
            raise

        response = {
            "is_new": result.is_new,
            "already_recorded": result.already_recorded,
            "seen_count": result.passcode["seen_count"],
            "unique_total": result.unique_total,
            "target_total": target_total,
            "passcode": result.passcode,
        }
        if not result.already_recorded:
            hub.publish("scan", {**response, "code": scan_meta.code, "stats": await run_in_threadpool(stats)})
        return response

    @app.post("/api/heartbeat")
    async def heartbeat(
        status: Annotated[str, Form()],
        preview: Annotated[UploadFile | None, File()] = None,
    ) -> dict[str, Any]:
        heartbeat_status: HeartbeatStatus = _parse_json_form(HeartbeatStatus, status)
        monitor.update(heartbeat_status, await _read_jpeg(preview, "preview", MAX_PREVIEW_BYTES))
        hub.publish("status", monitor.snapshot())
        return await run_in_threadpool(stats)

    @app.get("/api/scanner")
    def scanner() -> dict[str, Any]:
        return monitor.snapshot()

    @app.get("/api/latest-preview.jpg", include_in_schema=False)
    def latest_preview() -> Response:
        if monitor.preview is None:
            raise HTTPException(status_code=404)
        return Response(monitor.preview, media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @app.get("/api/events")
    async def events(request: Request) -> StreamingResponse:
        queue = hub.subscribe()
        hello = {
            "stats": await run_in_threadpool(stats),
            "scanner": monitor.snapshot(),
            "recent": await run_in_threadpool(db.recent_scans, 10),
        }

        async def stream() -> AsyncIterator[str]:
            try:
                yield f"event: hello\ndata: {json.dumps(hello, separators=(',', ':'))}\n\n"
                while not await request.is_disconnected():
                    try:
                        yield await asyncio.wait_for(queue.get(), timeout=KEEPALIVE_SECONDS)
                    except TimeoutError:
                        yield ": keepalive\n\n"
            finally:
                hub.unsubscribe(queue)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    # -- review ------------------------------------------------------------------

    @app.get("/api/stats")
    def get_stats() -> dict[str, Any]:
        return stats()

    @app.get("/api/keys")
    def keys() -> dict[str, int]:
        """Canonical key -> seen count, so the phone knows which cards are already scanned."""
        return db.known_keys()

    @app.get("/api/passcodes")
    def list_passcodes(
        q: Annotated[str, Query(max_length=64)] = "",
        unverified: bool = False,
        review: bool = False,
        group: Annotated[int | None, Query(ge=1)] = None,
    ) -> list[dict[str, Any]]:
        return db.list_passcodes(q.strip(), unverified_only=unverified, review_only=review, group_id=group)

    @app.get("/api/groups")
    def list_groups() -> dict[str, Any]:
        """Every group with its passcode count: "over" the stack size means misreads to remove,
        "short" means cards still to scan."""
        return groups()

    @app.post("/api/groups/next")
    async def next_group() -> dict[str, Any]:
        """Starts the next stack of cards; new passcodes from now on belong to the new group."""
        group = await run_in_threadpool(db.next_group)
        hub.publish("stats", await run_in_threadpool(stats))
        return {**group, "size": group_size}

    @app.patch("/api/passcodes/{passcode_id}")
    def update_passcode(passcode_id: int, update: PasscodeUpdate) -> dict[str, Any]:
        try:
            return db.update_passcode(passcode_id, update.display_code, update.verified, update.note, update.rotation)
        except NotFoundError as error:
            raise HTTPException(status_code=404, detail="no such passcode") from error
        except ConflictError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        except ValueError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    @app.delete("/api/passcodes/{passcode_id}")
    async def delete_passcode(passcode_id: int) -> dict[str, Any]:
        try:
            images = await run_in_threadpool(db.delete_passcode, passcode_id)
        except NotFoundError as error:
            raise HTTPException(status_code=404, detail="no such passcode") from error
        for name in images:
            if _IMAGE_NAME.fullmatch(name):
                (image_dir / name).unlink(missing_ok=True)
        # Publishing touches asyncio queues, so it must happen on the event loop thread.
        hub.publish("stats", await run_in_threadpool(stats))
        return {"deleted": passcode_id}

    @app.post("/api/ai-check")
    async def check_passcodes(scope: Literal["all", "low_confidence"] = "all") -> dict[str, Any]:
        """Queues the unverified passcodes the model has not checked yet (or failed to check):
        all of them, or only those flagged for review or with unsure characters."""
        if verifier is None:
            raise HTTPException(status_code=503, detail="AI check is off: start the server with OPENAI_API_KEY set")
        queued = await run_in_threadpool(db.ai_queue, scope == "low_confidence")
        for passcode_id in queued:
            verifier.enqueue(passcode_id)
        hub.publish("stats", await run_in_threadpool(stats))
        return {"queued": len(queued)}

    @app.post("/api/passcodes/{passcode_id}/ai-check")
    async def recheck_passcode(passcode_id: int) -> dict[str, Any]:
        """Asks the vision model again, for example after the image was rotated upright."""
        if verifier is None:
            raise HTTPException(status_code=503, detail="AI check is off: start the server with OPENAI_API_KEY set")
        try:
            row = await run_in_threadpool(db.reset_ai, passcode_id)
        except NotFoundError as error:
            raise HTTPException(status_code=404, detail="no such passcode") from error
        verifier.enqueue(passcode_id)
        return row

    @app.get("/api/removed")
    def removed() -> list[dict[str, Any]]:
        """Passcodes the vision model removed or merged into another card, newest first."""
        return db.removed()

    @app.get("/api/export.csv")
    def export_csv() -> Response:
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(["id", "group", "passcode", "canonical_key", "seen_count", "verified", "needs_review",
                         "first_seen", "last_seen", "note"])
        for row in reversed(db.list_passcodes()):
            writer.writerow([row["id"], row["group_id"], row["display_code"], row["canonical_key"], row["seen_count"],
                             int(row["verified"]), int(row["needs_review"]), row["first_seen"],
                             row["last_seen"], row["note"]])
        return Response(
            buffer.getvalue(),
            media_type="text/csv",
            headers={"Content-Disposition": 'attachment; filename="rbb_passcodes.csv"'},
        )

    return app


def create_default_app() -> FastAPI:
    """Uvicorn factory (`--factory`), so importing this module never opens the real database.

    The vision-model check runs through the Codex CLI (on the ChatGPT plan it is logged in
    with) when RBB_AI_READER=codex, otherwise through the API when OPENAI_API_KEY is set.
    RBB_AI_MODEL picks the model; Codex otherwise uses the model in its own config.
    """
    data_dir = Path(os.environ.get("RBB_DATA_DIR", DEFAULT_DATA_DIR))
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    model = os.environ.get("RBB_AI_MODEL", "").strip()
    backend = os.environ.get("RBB_AI_READER", "").strip().lower()
    reader: PasscodeReader | None
    concurrency = 3
    if backend == "codex":
        reader = CodexReader(model)
        model = f"codex {model}" if model else "codex"
        # A ChatGPT plan answers 429 to a few requests at once.
        concurrency = 1
    elif backend not in ("", "openai"):
        raise RuntimeError(f"RBB_AI_READER must be codex or openai, not {backend!r}")
    else:
        model = model or DEFAULT_MODEL
        reader = OpenAIReader(api_key, model) if api_key else None
    return create_app(
        data_dir,
        int(os.environ.get("RBB_TARGET_TOTAL", TARGET_TOTAL)),
        reader,
        model,
        int(os.environ.get("RBB_GROUP_SIZE", GROUP_SIZE)),
        concurrency,
    )
