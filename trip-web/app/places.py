"""Place search for the website, instead of Apple Maps (which only the phone can use): Photon, a public search over OpenStreetMap
that the iOS app itself uses as its fallback (TripPlanner/Services/PlaceFinder.swift). Photon asks for fair use, so answers are cached
and requests are spaced out."""
import asyncio
import time
from typing import Any

import httpx

PHOTON_URL = "https://photon.komoot.io/api/"
USER_AGENT = "trip-web/1.0 (family trip planner; contact: see site owner)"
CACHE_SECONDS = 3600
MAX_CACHE = 500
MIN_INTERVAL = 1.0  # seconds between two requests to Photon

_cache: dict[tuple, tuple[float, list[dict[str, Any]]]] = {}
_lock = asyncio.Lock()
_last_request = 0.0

FOOD = {"restaurant", "fast_food", "food_court", "biergarten", "ice_cream"}
NIGHTLIFE = {"bar", "pub", "nightclub", "casino", "stripclub"}
HOTEL = {"hotel", "hostel", "guest_house", "apartment", "motel", "chalet", "camp_site"}
SIGHT_TOURISM = {"museum", "attraction", "gallery", "viewpoint", "zoo", "theme_park", "artwork", "aquarium", "information"}
SIGHT_LEISURE = {"park", "garden", "nature_reserve", "playground", "stadium", "water_park", "beach_resort"}


def category(key: str, value: str) -> str:
    """OSM tag to the app's StopCategory raw values (sight, food, cafe, hotel, transport, nightlife, other), like StopCategory.init(poi:)."""
    if key == "amenity":
        if value in FOOD: return "food"
        if value == "cafe": return "cafe"
        if value in NIGHTLIFE: return "nightlife"
        if value in {"theatre", "cinema", "arts_centre", "library", "place_of_worship", "fountain"}: return "sight"
        if value in {"bus_station", "ferry_terminal", "taxi", "parking", "charging_station"}: return "transport"
    if key == "tourism":
        if value in HOTEL: return "hotel"
        if value in SIGHT_TOURISM: return "sight"
    if key in {"historic", "natural"}: return "sight"
    if key == "leisure" and value in SIGHT_LEISURE: return "sight"
    if key == "railway" or key == "aeroway" or key == "public_transport": return "transport"
    if key == "highway" and value == "bus_stop": return "transport"
    if key == "shop" and value in {"bakery", "pastry", "coffee", "tea", "confectionery"}: return "cafe"
    if key == "place": return "sight" if value in {"square", "neighbourhood", "quarter", "suburb"} else "other"
    return "other"


def address(props: dict[str, Any]) -> str:
    street = " ".join(p for p in (props.get("street"), props.get("housenumber")) if p)
    town = " ".join(p for p in (props.get("postcode"), props.get("city") or props.get("district")) if p)
    return ", ".join(p for p in (street, town, props.get("country")) if p)


def _features_to_results(payload: dict[str, Any]) -> list[dict[str, Any]]:
    out = []
    for feature in payload.get("features", []):
        props = feature.get("properties", {})
        coordinates = feature.get("geometry", {}).get("coordinates") or []
        name = props.get("name") or props.get("street")
        if not name or len(coordinates) < 2:
            continue
        out.append({
            "name": name, "address": address(props), "latitude": float(coordinates[1]), "longitude": float(coordinates[0]),
            "category_raw": category(props.get("osm_key", ""), props.get("osm_value", "")),
            "kind": props.get("osm_value", ""),
        })
    return out


async def _fetch(params: dict[str, Any]) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=10, headers={"User-Agent": USER_AGENT}) as client:
        reply = await client.get(PHOTON_URL, params=params)
        reply.raise_for_status()
        return reply.json()


async def search(query: str, near: tuple[float, float] | None = None, lang: str = "de", limit: int = 8) -> list[dict[str, Any]]:
    """Places matching the text, near a point if given. Photon speaks de, en, fr and it; anything else falls back to the local name."""
    global _last_request
    query = " ".join(query.split())[:120]
    if len(query) < 2:
        return []
    key = (query.lower(), None if near is None else (round(near[0], 1), round(near[1], 1)), lang, limit)
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    params: dict[str, Any] = {"q": query, "limit": limit, "lang": lang if lang in {"de", "en", "fr", "it"} else "en"}
    if near:
        params.update({"lat": near[0], "lon": near[1]})
    async with _lock:  # one request at a time, spaced out
        wait = MIN_INTERVAL - (time.monotonic() - _last_request)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            payload = await _fetch(params)
        finally:
            _last_request = time.monotonic()
    results = _features_to_results(payload)
    if len(_cache) >= MAX_CACHE:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (time.monotonic(), results)
    return results


def duplicate(existing: list[dict[str, Any]], name: str, latitude: float, longitude: float, metres: float = 100.0) -> bool:
    """Same name (ignoring case) within 100 m on one day: the app's rule against adding a place twice."""
    from math import asin, cos, radians, sin, sqrt
    for stop in existing:
        if stop.get("name", "").strip().lower() != name.strip().lower():
            continue
        if not (stop.get("latitude") or stop.get("longitude")):
            return True
        a1, a2 = radians(stop["latitude"]), radians(latitude)
        d = 2 * 6371000 * asin(sqrt(sin((a2 - a1) / 2) ** 2 + cos(a1) * cos(a2) * sin(radians(longitude - stop["longitude"]) / 2) ** 2))
        if d < metres:
            return True
    return False
