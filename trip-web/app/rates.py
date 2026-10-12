"""Exchange rates from open.er-api.com (free, no key), like the app's CurrencyService. The last answer is kept, so the budget keeps
working when the service is down."""
import time
from typing import Any

import httpx

URL = "https://open.er-api.com/v6/latest/{base}"
USER_AGENT = "trip-web/1.0 (family trip planner)"
TTL = 6 * 3600

_cache: dict[str, tuple[float, dict[str, float]]] = {}


async def _fetch(base: str) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=10, headers={"User-Agent": USER_AGENT}) as client:
        reply = await client.get(URL.format(base=base))
        reply.raise_for_status()
        return reply.json()


async def rates(base: str) -> dict[str, float] | None:
    """`rates[X]` is how many X one unit of `base` buys. Newest answer within 6 hours, else a fresh one, else the last known one."""
    base = base.upper()
    hit = _cache.get(base)
    if hit and time.monotonic() - hit[0] < TTL:
        return hit[1]
    try:
        payload = await _fetch(base)
        if payload.get("result") == "success" and isinstance(payload.get("rates"), dict):
            fresh = {k: float(v) for k, v in payload["rates"].items() if isinstance(v, (int, float))}
            _cache[base] = (time.monotonic(), fresh)
            return fresh
    except Exception:  # offline, service down, bad answer: fall through to what we already know
        pass
    return hit[1] if hit else None


def convert(amount: float, code: str, base: str, table: dict[str, float] | None) -> float | None:
    """`amount` in `code` expressed in `base`; None when the currency is unknown. CurrencyService.convert."""
    if code == base:
        return amount
    rate = (table or {}).get(code)
    return amount / rate if rate and rate > 0 else None
