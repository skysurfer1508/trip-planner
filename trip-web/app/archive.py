"""The `.tripplanner` file of the iOS app (TripPlanner/Services/TripArchive.swift, version 1): a JSON backup of trips.

The app stores moments in time (ISO 8601, UTC) that it built as wall-clock times in the phone's time zone. The file does not say
which zone that was, so the person picks it (default Europe/Zurich) and every time is turned back into local wall-clock time.
Photos, documents and the app's caches (tips, opening hours, transit guide) are left out."""
import sqlite3
from datetime import datetime, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import service
from .categories import FROM_STOP_CATEGORY
from .entities import STOP_CATEGORIES
from .service import ServiceError, User

FORMAT_VERSION = 1
DEFAULT_ZONE = "Europe/Zurich"
EXPENSE_CATEGORIES = ("food", "transport", "lodging", "activities", "shopping", "other")
BOOKING_KINDS = ("arrivalFlight", "departureFlight", "hotel")
TRANSPORTS = ("walking", "transit", "car")


def zone_of(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name or DEFAULT_ZONE)
    except (ZoneInfoNotFoundError, ValueError):
        raise ServiceError(f"Unbekannte Zeitzone \"{name}\". Beispiel: Europe/Zurich") from None


def _instant(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("kein Zeitpunkt")
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def local_date(value: Any, zone: ZoneInfo) -> str:
    return _instant(value).astimezone(zone).strftime("%Y-%m-%d")


def local_time(value: Any, zone: ZoneInfo) -> str:
    return _instant(value).astimezone(zone).strftime("%Y-%m-%dT%H:%M")


def to_instant(local: str, zone: ZoneInfo) -> str:
    """Local wall-clock `YYYY-MM-DD[THH:MM]` back to the app's ISO 8601 moment."""
    text = local if "T" in local else f"{local}T00:00"
    return datetime.strptime(text[:16], "%Y-%m-%dT%H:%M").replace(tzinfo=zone).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# MARK: Reading a file

def _number(value: Any, low: float, high: float, default: float) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and low <= value <= high else default


def _coordinates(source: dict[str, Any], flag: str | None = None) -> dict[str, float]:
    lat, lon = source.get("latitude"), source.get("longitude")
    if flag and not source.get(flag):
        return {}
    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)) and -90 <= lat <= 90 and -180 <= lon <= 180 and (lat or lon):
        return {"latitude": float(lat), "longitude": float(lon)}
    return {}


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _link(value: Any) -> str:
    return value if isinstance(value, str) and value.lower().startswith(("http://", "https://")) else ""


def check(archive: Any) -> list[dict[str, Any]]:
    if not isinstance(archive, dict) or not isinstance(archive.get("trips"), list):
        raise ServiceError("Das ist keine Trip-Planner-Datei, oder sie ist beschädigt.")
    version = archive.get("version")
    if not isinstance(version, int) or version < 1:
        raise ServiceError("Das ist keine Trip-Planner-Datei, oder sie ist beschädigt.")
    if version > FORMAT_VERSION:
        raise ServiceError("Diese Datei stammt aus einer neueren Version der App. Bitte die Website aktualisieren.")
    return archive["trips"]


def _bundle(dto: dict[str, Any], zone: ZoneInfo) -> dict[str, Any]:
    try:
        trip: dict[str, Any] = {
            "name": _text(dto.get("name")) or "Importierte Reise",
            "destination": _text(dto.get("destination")),
            "start_date": local_date(dto["startDate"], zone),
            "end_date": local_date(dto["endDate"], zone),
            "currency_code": _text(dto.get("currencyCode"))[:3] or "CHF",
            "budget": _number(dto.get("budget"), 0, 1e12, 0),
            "description": "Aus der iPhone-App importiert.",
            "phase": "building",
        }
        if dto.get("transportRaw") in TRANSPORTS:
            trip["transport_raw"] = dto["transportRaw"]
        if len(_text(dto.get("countryCode"))) == 2:
            trip["country_code"] = dto["countryCode"]
        if dto.get("hasDestinationCoordinate"):
            c = _coordinates({"latitude": dto.get("destinationLatitude"), "longitude": dto.get("destinationLongitude")})
            trip.update({"destination_latitude": c["latitude"], "destination_longitude": c["longitude"]} if c else {})

        days = []
        for day in dto.get("days", []):
            stops = []
            for stop in day.get("stops", []):
                row: dict[str, Any] = {
                    "name": _text(stop.get("name")) or "Ohne Namen",
                    "address": _text(stop.get("address")),
                    "category_raw": stop.get("categoryRaw") if stop.get("categoryRaw") in STOP_CATEGORIES else "other",
                    "duration_minutes": int(_number(stop.get("durationMinutes"), 0, 1440, 60)),
                    "notes": _text(stop.get("notes")),
                    "sort_order": int(_number(stop.get("order"), -10_000, 10_000, 0)),
                    "is_done": bool(stop.get("isDone")),
                    "estimated_cost": _number(stop.get("estimatedCost"), 0, 1e9, 0),
                    "phone": _text(stop.get("phone")),
                    "website": _link(stop.get("website")),
                    "opening_hours": _text(stop.get("openingHours")),
                    **_coordinates(stop),
                }
                if stop.get("plannedTime"):
                    row["planned_time"] = local_time(stop["plannedTime"], zone)
                stops.append(row)
            days.append({"date": local_date(day["date"], zone), "notes": _text(day.get("notes")), "stops": stops})

        expenses = [{
            "title": _text(e.get("title")) or "Ausgabe", "amount": _number(e.get("amount"), -1e12, 1e12, 0),
            "currency_code": _text(e.get("currencyCode"))[:3] or trip["currency_code"],
            "category_raw": e.get("categoryRaw") if e.get("categoryRaw") in EXPENSE_CATEGORIES else "other",
            "date": local_date(e["date"], zone),
        } for e in dto.get("expenses", [])]

        checklist = [{
            "title": _text(c.get("title")) or "Eintrag", "section": _text(c.get("section")),
            "is_done": bool(c.get("isDone")), "sort_order": int(_number(c.get("order"), -10_000, 10_000, 0)),
        } for c in dto.get("checklist", [])]

        places = [{
            "name": _text(p.get("name")) or "Ort", "description": _text(p.get("address")), "prio": "Gerne",
            "category": FROM_STOP_CATEGORY.get(p.get("categoryRaw"), "other"), "source": "App", **_coordinates(p),
        } for p in dto.get("savedPlaces", [])]

        bookings = [{
            "kind_raw": b.get("kindRaw") if b.get("kindRaw") in BOOKING_KINDS else "hotel",
            "title": _text(b.get("title")) or "Buchung",
            "start_date": local_time(b["startDate"], zone), "end_date": local_time(b["endDate"], zone),
            "place_name": _text(b.get("placeName")), "other_end": _text(b.get("otherEnd")), "address": _text(b.get("address")),
            "reference": _text(b.get("reference")), "notes": _text(b.get("notes")),
            "buffer_minutes": int(_number(b.get("bufferMinutes"), 0, 1440, 0)), "remind": bool(b.get("remind")),
            "phone": _text(b.get("phone")), "website": _link(b.get("website")), **_coordinates(b, "hasCoordinate"),
        } for b in dto.get("bookings") or []]
    except (KeyError, ValueError, TypeError, AttributeError) as error:
        raise ServiceError(f"Die Datei enthält Daten, die ich nicht lesen kann ({error.__class__.__name__}: {error}).") from None
    return {"trip": trip, "days": days, "expenses": expenses, "checklist": checklist, "places": places, "bookings": bookings,
            "documents_skipped": len(dto.get("documents", []))}


def preview(archive: Any, zone_name: str) -> dict[str, Any]:
    """What an import would create, with the first stops' converted times so the person can check the time zone."""
    zone = zone_of(zone_name)
    out = []
    for dto in check(archive):
        b = _bundle(dto, zone)
        sample = [{"date": d["date"], "time": s.get("planned_time", "")[11:], "name": s["name"]}
                  for d in b["days"] for s in d["stops"] if s.get("planned_time")][:6]
        out.append({
            "name": b["trip"]["name"], "start_date": b["trip"]["start_date"], "end_date": b["trip"]["end_date"],
            "stops": sum(len(d["stops"]) for d in b["days"]), "days_with_stops": sum(1 for d in b["days"] if d["stops"]),
            "expenses": len(b["expenses"]), "checklist": len(b["checklist"]), "places": len(b["places"]),
            "bookings": len(b["bookings"]), "documents_skipped": b["documents_skipped"], "sample": sample,
        })
    return {"time_zone": zone.key, "trips": out}


def import_archive(conn: sqlite3.Connection, user: User, archive: Any, zone_name: str, actor: str) -> list[dict[str, Any]]:
    zone = zone_of(zone_name)
    bundles = [_bundle(dto, zone) for dto in check(archive)]  # convert everything first: a bad file creates nothing
    if not bundles:
        raise ServiceError("Die Datei enthält keine Reise.")
    results = []
    for b in bundles:
        done = service.import_bundle(conn, user, b, actor, ".tripplanner-Datei")
        results.append({"trip_id": done["trip_id"], "name": b["trip"]["name"], **done["counts"]})
    return results


# MARK: Writing a file

def export_archive(conn: sqlite3.Connection, user: User, trip_id: str, zone_name: str) -> dict[str, Any]:
    """The trip as a `.tripplanner` archive the app can open (it adds the trip as a new copy)."""
    zone = zone_of(zone_name)
    data = service.trip_data(conn, user, trip_id)
    trip = data["trip"]
    stops_by_day: dict[str, list[dict[str, Any]]] = {}
    for stop in data["stops"]:
        stops_by_day.setdefault(stop["day_id"], []).append(stop)

    def stop_dto(s: dict[str, Any]) -> dict[str, Any]:
        return {
            "name": s["name"], "latitude": s.get("latitude") or 0, "longitude": s.get("longitude") or 0,
            "address": s.get("address", ""), "categoryRaw": s.get("category_raw") or "other",
            "plannedTime": to_instant(s["planned_time"], zone) if s.get("planned_time") else None,
            "durationMinutes": s.get("duration_minutes") or 60, "notes": s.get("notes", ""), "order": s.get("sort_order") or 0,
            "isDone": bool(s.get("is_done")), "estimatedCost": s.get("estimated_cost") or 0, "phone": s.get("phone", ""),
            "website": s.get("website", ""), "aiTips": "", "openingHours": s.get("opening_hours") or None,
        }

    days = [{"date": to_instant(d["date"], zone), "notes": d.get("notes", ""),
             "stops": [stop_dto(s) for s in sorted(stops_by_day.get(d["id"], []), key=lambda x: x.get("sort_order") or 0)]}
            for d in data["days"]]
    wishes = [p for p in data["places"] if p.get("decision") != "Nein" and p.get("prio") != "Flughafen"]
    stamp = to_instant(trip["start_date"], zone)
    return {
        "version": FORMAT_VERSION,
        "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "trips": [{
            "name": trip["name"], "destination": trip.get("destination", ""),
            "startDate": to_instant(trip["start_date"], zone), "endDate": to_instant(trip["end_date"], zone),
            "destinationLatitude": trip.get("destination_latitude") or 0, "destinationLongitude": trip.get("destination_longitude") or 0,
            "hasDestinationCoordinate": bool(trip.get("has_destination_coordinate")), "budget": trip.get("budget") or 0,
            "currencyCode": trip.get("currency_code") or "CHF", "transportRaw": trip.get("transport_raw") or "walking",
            "countryCode": trip.get("country_code") or None,
            "days": days,
            "expenses": [{"title": e["title"], "amount": e["amount"], "currencyCode": e.get("currency_code") or "CHF",
                          "categoryRaw": e.get("category_raw") or "other", "date": to_instant(f"{e['date']}T12:00", zone)}
                         for e in data["expenses"]],
            "checklist": [{"title": c["title"], "section": c.get("section", ""), "isDone": bool(c.get("is_done")),
                           "order": c.get("sort_order") or 0} for c in data["checklist"]],
            "savedPlaces": [{"name": p["name"], "latitude": p.get("latitude") or 0, "longitude": p.get("longitude") or 0,
                             "address": p.get("description", ""), "categoryRaw": "other", "savedAt": stamp} for p in wishes],
            "documents": [],
            "bookings": [{"kindRaw": b["kind_raw"], "title": b["title"], "startDate": to_instant(b["start_date"], zone),
                          "endDate": to_instant(b["end_date"], zone), "placeName": b.get("place_name", ""),
                          "otherEnd": b.get("other_end", ""), "address": b.get("address", ""), "latitude": b.get("latitude") or 0,
                          "longitude": b.get("longitude") or 0, "hasCoordinate": bool(b.get("has_coordinate")),
                          "reference": b.get("reference", ""), "notes": b.get("notes", ""),
                          "bufferMinutes": b.get("buffer_minutes") or 0, "remind": bool(b.get("remind")),
                          "phone": b.get("phone") or None, "website": b.get("website") or None} for b in data["bookings"]],
        }],
    }
