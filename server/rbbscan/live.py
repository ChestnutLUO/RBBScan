"""In-memory live state: the scanner's latest heartbeat and the SSE broadcast hub."""

from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from pydantic import BaseModel, Field

STALE_AFTER_SECONDS = 3.0


class TrackedRead(BaseModel):
    best_read: str = Field(max_length=32)
    read_count: int = Field(ge=0)
    confirmed: bool


class HeartbeatStatus(BaseModel):
    device: str = Field(default="iPhone", max_length=64)
    camera_running: bool
    paused: bool = False
    torch: bool = False
    tracking: list[TrackedRead] = Field(default_factory=list, max_length=20)
    pending_uploads: int = Field(default=0, ge=0)
    battery: float = Field(default=-1, ge=-1, le=1)
    local_unique: int = Field(default=0, ge=0)


@dataclass
class ScannerMonitor:
    """Latest heartbeat from the scanning iPhone; nothing is persisted."""

    clock: Callable[[], float] = time.monotonic
    status: HeartbeatStatus | None = None
    received_at: float | None = None
    preview: bytes | None = None
    preview_seq: int = 0

    def update(self, status: HeartbeatStatus, preview: bytes | None) -> None:
        self.status = status
        self.received_at = self.clock()
        if preview is not None:
            self.preview = preview
            self.preview_seq += 1

    def online(self) -> bool:
        return self.received_at is not None and self.clock() - self.received_at <= STALE_AFTER_SECONDS

    def snapshot(self) -> dict[str, Any]:
        age = None if self.received_at is None else round(self.clock() - self.received_at, 1)
        base: dict[str, Any] = {"online": self.online(), "age_seconds": age, "preview_seq": self.preview_seq}
        if self.status is not None:
            base.update(self.status.model_dump())
        return base


@dataclass
class EventHub:
    """Fan-out of server-sent events. Each client gets a bounded queue; a client too
    slow to drain it misses events rather than growing memory without bound."""

    queue_size: int = 64
    _subscribers: set[asyncio.Queue[str]] = field(default_factory=set)

    def subscribe(self) -> asyncio.Queue[str]:
        queue: asyncio.Queue[str] = asyncio.Queue(maxsize=self.queue_size)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[str]) -> None:
        self._subscribers.discard(queue)

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    def publish(self, event: str, data: dict[str, Any]) -> None:
        message = format_sse(event, data)
        for queue in list(self._subscribers):
            try:
                queue.put_nowait(message)
            except asyncio.QueueFull:
                pass


def format_sse(event: str, data: dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
