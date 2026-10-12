"""Public holidays from Nager.Date (free, no key), the same source as the iOS app (Services/Hours/PublicHolidays.swift). Best effort: when it
is unreachable, the checks simply leave holidays out."""
import time
from typing import Any

import httpx

URL = "https://date.nager.at/api/v3/PublicHolidays/{year}/{country}"
USER_AGENT = "trip-web/1.0 (family trip planner)"
CACHE_SECONDS = 24 * 3600

_cache: dict[tuple[int, str], tuple[float, dict[str, str]]] = {}


def parse(rows: list[dict[str, Any]]) -> dict[str, str]:
    """Date to name; only public holidays (not "Optional" ones), regional ones marked as such."""
    out: dict[str, str] = {}
    for row in rows:
        types = row.get("types") or []
        if types and "Public" not in types:
            continue
        name = row.get("name") or row.get("localName") or "Feiertag"
        out[row["date"]] = name if row.get("global", True) else f"{name} (nur in einigen Regionen)"
    return out


async def for_years(country: str, years: list[int]) -> dict[str, str]:
    """All holidays of the country in these years; {} when the country is unknown or the service is down."""
    country = country.strip().upper()
    if len(country) != 2 or not country.isalpha():
        return {}
    out: dict[str, str] = {}
    async with httpx.AsyncClient(timeout=8, headers={"User-Agent": USER_AGENT}) as client:
        for year in years:
            hit = _cache.get((year, country))
            if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
                out.update(hit[1])
                continue
            try:
                reply = await client.get(URL.format(year=year, country=country))
                reply.raise_for_status()
                found = parse(reply.json())
            except (httpx.HTTPError, ValueError):
                continue
            _cache[(year, country)] = (time.monotonic(), found)
            out.update(found)
    return out
