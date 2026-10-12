"""A picture for each idea: the lead image of the Wikipedia article about the place, found by name and position.

Pictures are fetched once, stored next to the database (data/photos/) and served from our own address, so the browser
never talks to Wikipedia and a place without a picture is not searched for again on every page view."""
import asyncio
import hashlib
import json
import re
import time
import unicodedata
from pathlib import Path
from typing import Any

import httpx

from .config import settings

API = "https://en.wikipedia.org/w/api.php"
USER_AGENT = f"trip-web/1.0 ({settings.public_base_url}; family trip planner)"
THUMB_WIDTH = 640
RETRY_AFTER = 7 * 24 * 3600  # a place without a picture is looked up again after a week
GEO_RADIUS = 2000  # metres around the place
MAX_DISTANCE_KM = 150  # a name search result must be somewhere near the place, if both have a position
STOP_WORDS = {"the", "and", "mit", "und", "von", "der", "die", "das", "im", "in", "am", "an", "zum", "zur", "bei", "ein", "eine", "of", "at", "to", "by", "oder", "flughafen"}

MIN_INTERVAL = 0.4  # seconds between two requests to Wikipedia
COOLDOWN = 30  # seconds to leave Wikipedia alone after it said "too many requests"

_lock = asyncio.Lock()
_last_request = 0.0
_cooldown_until = 0.0


class PhotoBusy(Exception):
    """Wikipedia is rate-limiting or unreachable right now. The page tries again a little later; nothing is remembered as "no picture"."""

    def __init__(self, retry_after: int = COOLDOWN):
        super().__init__("busy")
        self.retry_after = retry_after


async def _get(client: httpx.AsyncClient, url: str, **params: Any) -> httpx.Response:
    """One polite request: one at a time, spaced out, and a pause when Wikipedia asks for one."""
    global _last_request, _cooldown_until
    async with _lock:
        now = time.monotonic()
        if now < _cooldown_until:
            raise PhotoBusy(int(_cooldown_until - now) + 1)
        wait = MIN_INTERVAL - (now - _last_request)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            reply = await client.get(url, params=params or None)
        except httpx.HTTPError:
            raise PhotoBusy(10) from None
        finally:
            _last_request = time.monotonic()
        if reply.status_code in (429, 503):
            pause = min(max(int(reply.headers.get("retry-after", COOLDOWN) or COOLDOWN), 5), 120)
            _cooldown_until = time.monotonic() + pause
            raise PhotoBusy(pause)
        if reply.status_code >= 400:
            raise PhotoBusy(30)
        return reply


def cache_dir() -> Path:
    path = Path(settings.db_path).resolve().parent / "photos"
    path.mkdir(parents=True, exist_ok=True)
    return path


def key(name: str, region: str, latitude: float | None, longitude: float | None) -> str:
    position = "" if latitude is None or longitude is None else f"{latitude:.3f},{longitude:.3f}"
    return hashlib.sha1(f"{name.strip().lower()}|{region.strip().lower()}|{position}".encode()).hexdigest()[:20]


def words(text: str) -> set[str]:
    """Lower-case words without accents ("Sensō-ji" and "Senso-ji" match), without filler words."""
    plain = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return {w for w in re.split(r"[^a-z0-9]+", plain) if len(w) > 1 and w not in STOP_WORDS}


# Articles about something else that merely contains the place's name ("Battle of Miyajima", "Higashi-Narita Station").
OFF_TOPIC = {"battle", "station", "railway", "disambiguation", "list", "history", "incident", "siege", "line"}


def score(name: str, title: str) -> float:
    """How much of the idea's name shows up in the article title (0 to 1), with a bonus for a whole-name match."""
    wanted, found = words(name), words(title)
    if not wanted or not found:
        return 0.0
    share = len(wanted & found) / len(wanted)
    off_topic = 1.0 if (found & OFF_TOPIC) - wanted else 0.0
    return share + (0.5 if wanted == found else 0.0) + 0.1 * len(wanted & found) / len(found) - off_topic


def kilometres(a: tuple[float, float], b: tuple[float, float]) -> float:
    from math import asin, cos, radians, sin, sqrt
    h = sin(radians(b[0] - a[0]) / 2) ** 2 + cos(radians(a[0])) * cos(radians(b[0])) * sin(radians(b[1] - a[1]) / 2) ** 2
    return 2 * 6371.0088 * asin(sqrt(h))


async def _query(client: httpx.AsyncClient, **params: Any) -> list[dict[str, Any]]:
    base = {"action": "query", "format": "json", "formatversion": 2, "prop": "pageimages|coordinates", "piprop": "thumbnail",
            "pithumbsize": THUMB_WIDTH, "pilimit": 20, "coprimary": "primary"}
    reply = await _get(client, API, **base, **params)
    return reply.json().get("query", {}).get("pages", [])


def _thumb(page: dict[str, Any]) -> str | None:
    return (page.get("thumbnail") or {}).get("source")


def candidates(name: str) -> list[str]:
    """The whole name first, then its parts: "Harajuku und Meiji-Schrein" is two places, "teamLab (Planets oder Borderless)" is one with a note."""
    parts = [part.strip(" -,") for part in re.split(r"\s+(?:und|oder)\s+|\(|\)|/|,", name)]
    out = [name.strip()]
    for part in parts:
        if len(part) >= 4 and part.lower() not in {c.lower() for c in out} and words(part):
            out.append(part)
    return out[:3]


async def find(name: str, region: str, latitude: float | None, longitude: float | None) -> dict[str, str] | None:
    """The best article with a picture: first near the position (matching the name), then by searching the name."""
    names = candidates(name)
    async with httpx.AsyncClient(timeout=12, headers={"User-Agent": USER_AGENT}) as client:
        if latitude is not None and longitude is not None:
            around = await _query(client, generator="geosearch", ggscoord=f"{latitude}|{longitude}", ggsradius=GEO_RADIUS, ggslimit=20)
            with_picture = [p for p in around if _thumb(p)]
            for candidate in names:
                ranked = sorted(with_picture, key=lambda p: -score(candidate, p.get("title", "")))
                if ranked and score(candidate, ranked[0].get("title", "")) >= 0.5:
                    return {"url": _thumb(ranked[0]) or "", "title": ranked[0]["title"]}
        for candidate in names:
            located = latitude is not None and longitude is not None
            query = candidate if located else " ".join(part for part in (candidate, region) if part)
            found = await _query(client, generator="search", gsrsearch=query, gsrlimit=8, gsrnamespace=0)
            for page in sorted(found, key=lambda p: p.get("index", 99)):
                if not _thumb(page) or score(candidate, page.get("title", "")) < 0.34:
                    continue
                where = (page.get("coordinates") or [None])[0]
                if where and latitude is not None and longitude is not None \
                        and kilometres((latitude, longitude), (where["lat"], where["lon"])) > MAX_DISTANCE_KM:
                    continue
                return {"url": _thumb(page) or "", "title": page["title"]}
    return None


async def photo(name: str, region: str, latitude: float | None, longitude: float | None) -> tuple[Path, dict[str, str]] | None:
    """The cached picture file and its source, fetching it the first time. None when there is no picture."""
    folder = cache_dir()
    stem = folder / key(name, region, latitude, longitude)
    image, meta, none = stem.with_suffix(".jpg"), stem.with_suffix(".json"), stem.with_suffix(".none")
    if image.exists() and meta.exists():
        return image, json.loads(meta.read_text())
    if none.exists() and time.time() - none.stat().st_mtime < RETRY_AFTER:
        return None
    hit = await find(name, region, latitude, longitude)  # may raise PhotoBusy: not remembered, tried again later
    if hit:
        async with httpx.AsyncClient(timeout=15, headers={"User-Agent": USER_AGENT}) as client:
            reply = await _get(client, hit["url"])
        if reply.headers.get("content-type", "").startswith("image/") and len(reply.content) < 3_000_000:
            source = {"title": hit["title"], "page": "https://en.wikipedia.org/wiki/" + hit["title"].replace(" ", "_"),
                      "type": reply.headers["content-type"].split(";")[0]}
            image.write_bytes(reply.content)
            meta.write_text(json.dumps(source))
            none.unlink(missing_ok=True)
            return image, source
    none.write_text("")
    return None
