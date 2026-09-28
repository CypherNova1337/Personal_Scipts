"""
engine — the async HTTP core every check builds on.

Design goals:
  * One shared connection pool (httpx.AsyncClient, HTTP/2 when available).
  * Bounded concurrency via a semaphore, independent of the pool size.
  * A token-bucket rate limiter so you can cap requests/sec politely.
  * Automatic retries with exponential backoff + jitter on transport errors,
    429s, and 5xx responses (honoring Retry-After when present).
  * Manual redirect handling so the full redirect chain is captured as data
    (essential for open-redirect / SSRF detection) instead of being followed
    silently.
  * A normalized Response object with case-insensitive headers.

Nothing here is check-specific; the vulnerability logic lives in the modules
that import this.
"""

from __future__ import annotations

import asyncio
import dataclasses
import random
import time
from typing import Awaitable, Callable, Iterable, Optional, TypeVar

import httpx

T = TypeVar("T")
R = TypeVar("R")

DEFAULT_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)


@dataclasses.dataclass(slots=True)
class EngineConfig:
    concurrency: int = 50
    rate: float = 0.0            # requests/sec across all workers; 0 = unlimited
    timeout: float = 15.0
    retries: int = 2             # additional attempts after the first
    backoff_base: float = 0.5    # seconds; grows as base * 2**attempt
    backoff_cap: float = 8.0
    max_redirects: int = 10
    verify_tls: bool = True
    http2: bool = False          # needs the 'h2' package; opt in with --http2
    user_agent: str = DEFAULT_UA
    proxy: Optional[str] = None
    default_headers: dict[str, str] = dataclasses.field(default_factory=dict)


@dataclasses.dataclass(slots=True)
class Response:
    """A normalized, framework-agnostic view of an HTTP response."""
    url: str                       # final URL actually fetched
    status: int
    headers: httpx.Headers         # case-insensitive
    text: str
    elapsed: float
    request_url: str               # URL originally requested
    redirects: list[str] = dataclasses.field(default_factory=list)  # Location chain
    error: Optional[str] = None    # set when the request ultimately failed

    @property
    def ok(self) -> bool:
        return self.error is None

    def header(self, name: str, default: str = "") -> str:
        return self.headers.get(name, default)


class _TokenBucket:
    """Simple async token-bucket rate limiter. rate<=0 disables limiting."""

    def __init__(self, rate: float):
        self._rate = rate
        self._capacity = max(1.0, rate)
        self._tokens = self._capacity
        self._updated = time.monotonic()
        self._lock = asyncio.Lock()

    async def take(self) -> None:
        if self._rate <= 0:
            return
        async with self._lock:
            while True:
                now = time.monotonic()
                self._tokens = min(
                    self._capacity, self._tokens + (now - self._updated) * self._rate
                )
                self._updated = now
                if self._tokens >= 1:
                    self._tokens -= 1
                    return
                await asyncio.sleep((1 - self._tokens) / self._rate)


class Engine:
    """
    Async request executor. Use as an async context manager:

        cfg = EngineConfig(concurrency=100, rate=200)
        async with Engine(cfg) as eng:
            resp = await eng.request("GET", url)
            results = await eng.map(worker_coro, targets)
    """

    def __init__(self, config: Optional[EngineConfig] = None):
        self.cfg = config or EngineConfig()
        self._sem = asyncio.Semaphore(self.cfg.concurrency)
        self._bucket = _TokenBucket(self.cfg.rate)
        limits = httpx.Limits(
            max_connections=self.cfg.concurrency,
            max_keepalive_connections=max(10, self.cfg.concurrency // 2),
        )
        headers = {"User-Agent": self.cfg.user_agent, **self.cfg.default_headers}
        http2 = self.cfg.http2
        if http2:
            try:
                import h2  # noqa: F401
            except ImportError:
                http2 = False  # silently fall back rather than crash
        self._client = httpx.AsyncClient(
            headers=headers,
            timeout=httpx.Timeout(self.cfg.timeout),
            limits=limits,
            verify=self.cfg.verify_tls,
            http2=http2,
            follow_redirects=False,       # we capture the chain ourselves
            proxy=self.cfg.proxy,
            trust_env=True,
        )

    # --- lifecycle ---------------------------------------------------------

    async def __aenter__(self) -> "Engine":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    # --- core request ------------------------------------------------------

    async def request(
        self,
        method: str,
        url: str,
        *,
        headers: Optional[dict[str, str]] = None,
        follow_redirects: bool = False,
        **kwargs,
    ) -> Response:
        """
        Perform one request (with retries), optionally following redirects while
        recording every Location hop. Never raises for HTTP/transport errors —
        failures come back as a Response with `.error` set.
        """
        chain: list[str] = []
        current = url
        seen: set[str] = set()

        for _ in range(self.cfg.max_redirects + 1):
            resp = await self._single(method, current, headers=headers, **kwargs)
            if not resp.ok:
                resp.request_url = url
                resp.redirects = chain
                return resp

            if follow_redirects and resp.status in (301, 302, 303, 307, 308):
                loc = resp.header("location")
                if not loc:
                    break
                nxt = str(httpx.URL(current).join(loc))
                chain.append(loc)
                if nxt in seen:            # redirect loop
                    break
                seen.add(nxt)
                # 303 and most 302 downgrade to GET in practice.
                if resp.status in (302, 303) and method.upper() not in ("GET", "HEAD"):
                    method = "GET"
                current = nxt
                continue
            resp.request_url = url
            resp.redirects = chain
            return resp

        resp.request_url = url
        resp.redirects = chain
        return resp

    async def _single(
        self,
        method: str,
        url: str,
        *,
        headers: Optional[dict[str, str]] = None,
        **kwargs,
    ) -> Response:
        attempt = 0
        while True:
            await self._bucket.take()
            start = time.monotonic()
            try:
                async with self._sem:
                    r = await self._client.request(method, url, headers=headers, **kwargs)
                elapsed = time.monotonic() - start

                if r.status_code == 429 or r.status_code >= 500:
                    if attempt < self.cfg.retries:
                        await self._sleep_backoff(attempt, r)
                        attempt += 1
                        continue
                # Reading text can itself raise on bad encodings; guard it.
                try:
                    text = r.text
                except Exception:
                    text = r.content.decode("utf-8", "replace")
                return Response(
                    url=str(r.url), status=r.status_code, headers=r.headers,
                    text=text, elapsed=elapsed, request_url=url,
                )
            except (httpx.TransportError, httpx.ProtocolError) as exc:
                if attempt < self.cfg.retries:
                    await self._sleep_backoff(attempt, None)
                    attempt += 1
                    continue
                return Response(
                    url=url, status=0, headers=httpx.Headers(), text="",
                    elapsed=time.monotonic() - start, request_url=url,
                    error=f"{type(exc).__name__}: {exc}",
                )

    async def _sleep_backoff(self, attempt: int, resp: Optional[httpx.Response]) -> None:
        # Honor Retry-After if the server sent a sane numeric value.
        if resp is not None:
            ra = resp.headers.get("retry-after")
            if ra and ra.isdigit():
                await asyncio.sleep(min(float(ra), self.cfg.backoff_cap))
                return
        delay = min(self.cfg.backoff_base * (2 ** attempt), self.cfg.backoff_cap)
        delay += random.uniform(0, delay * 0.25)   # jitter to avoid thundering herd
        await asyncio.sleep(delay)

    # --- fan-out helper ----------------------------------------------------

    async def map(
        self,
        worker: Callable[[T], Awaitable[R]],
        items: Iterable[T],
    ) -> list[R]:
        """
        Run `worker` over every item concurrently (bounded by the same
        semaphore the requests use) and return results in completion order,
        dropping any that raised.
        """
        async def guarded(it: T) -> Optional[R]:
            try:
                return await worker(it)
            except Exception:
                return None

        tasks = [asyncio.create_task(guarded(it)) for it in items]
        out: list[R] = []
        for coro in asyncio.as_completed(tasks):
            res = await coro
            if res is not None:
                out.append(res)
        return out
