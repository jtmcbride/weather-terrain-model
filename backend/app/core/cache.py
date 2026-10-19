"""A small TTL cache with single-flight, for upstream weather responses.

Open-Meteo and the Aviation Weather Center are free and unauthenticated, which
means they are also rate limited. The fog client scrubs a 168-hour timeline and
animates it, so without a cache a single drag of the hour slider is dozens of
identical upstream requests and the answer comes back ``429 Too Many Requests``
-- the live data stops being *available* long before it stops being *correct*.

Two properties matter here beyond plain memoisation:

* **Single flight.** The client fires overlapping requests (the play button
  ticks every 1.8 s, faster than a cold render). Without a per-key lock, N
  concurrent misses become N upstream calls, which is exactly the burst that
  triggers the rate limiter.
* **Stale-on-error.** A cached payload that has just expired is still a far
  better answer than a 502, so an expired entry is retained until it is
  successfully replaced and served if the refresh fails.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Awaitable, Callable, Generic, Hashable, TypeVar
import asyncio
import time

T = TypeVar("T")

Clock = Callable[[], float]


@dataclass
class _Entry(Generic[T]):
    value: T
    stored_at: float


class TtlCache(Generic[T]):
    """Async cache with a time-to-live, an entry cap, and single-flight misses."""

    def __init__(
        self,
        ttl_seconds: float,
        max_entries: int = 8,
        clock: Clock = time.monotonic,
    ) -> None:
        self.ttl_seconds = ttl_seconds
        self.max_entries = max(1, max_entries)
        self._clock = clock
        self._entries: dict[Hashable, _Entry[T]] = {}
        self._locks: dict[Hashable, asyncio.Lock] = {}
        self.hits = 0
        self.misses = 0
        self.stale_serves = 0

    # ------------------------------------------------------------------

    def _fresh(self, key: Hashable) -> _Entry[T] | None:
        entry = self._entries.get(key)
        if entry is None:
            return None
        if self._clock() - entry.stored_at > self.ttl_seconds:
            return None
        return entry

    def _store(self, key: Hashable, value: T) -> None:
        # Insertion-ordered dicts make the oldest key the first one.
        while len(self._entries) >= self.max_entries and key not in self._entries:
            self._entries.pop(next(iter(self._entries)))
        self._entries[key] = _Entry(value=value, stored_at=self._clock())

    def peek(self, key: Hashable) -> T | None:
        """Return a fresh value without fetching, or ``None``."""
        entry = self._fresh(key)
        return entry.value if entry is not None else None

    def age_seconds(self, key: Hashable) -> float | None:
        """How long ago this key was last successfully stored, fresh or not."""
        entry = self._entries.get(key)
        return None if entry is None else self._clock() - entry.stored_at

    def clear(self) -> None:
        self._entries.clear()

    async def get_or_fetch(
        self, key: Hashable, factory: Callable[[], Awaitable[T]]
    ) -> T:
        """Return the cached value, or await ``factory`` once across callers."""
        entry = self._fresh(key)
        if entry is not None:
            self.hits += 1
            return entry.value

        lock = self._locks.setdefault(key, asyncio.Lock())
        async with lock:
            # A concurrent caller may have filled it while we waited.
            entry = self._fresh(key)
            if entry is not None:
                self.hits += 1
                return entry.value
            self.misses += 1
            try:
                value = await factory()
            except Exception:
                expired = self._entries.get(key)
                if expired is None:
                    raise
                # An hour-old forecast beats a 502.
                self.stale_serves += 1
                return expired.value
            self._store(key, value)
            return value

    def stats(self) -> dict[str, float | int]:
        return {
            "entries": len(self._entries),
            "hits": self.hits,
            "misses": self.misses,
            "stale_serves": self.stale_serves,
            "ttl_seconds": self.ttl_seconds,
        }
