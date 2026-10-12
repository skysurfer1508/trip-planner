"""Editing a day's plan the way the iOS app does (Day.swift, PlannerView, BookingPlanner): move, copy, sort, optimise, re-time.
Every operation is one entry in the history and can be undone as a whole. The rules themselves are in planning.py."""
import sqlite3
from datetime import datetime
from typing import Any

from . import planning, places
from .entities import entity_of
from .service import ServiceError, User, _need, apply_batch

STOP = entity_of("stop")
COPY_FIELDS = ("name", "address", "category_raw", "planned_time", "duration_minutes", "notes", "estimated_cost", "phone", "website",
               "opening_hours", "latitude", "longitude", "place_id")


def _stop(conn: sqlite3.Connection, user: User, stop_id: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM stops WHERE id = ? AND deleted_at IS NULL", (stop_id,)).fetchone()
    if not row:
        raise ServiceError("Stopp nicht gefunden.")
    _need(conn, user, row["trip_id"], "editor")
    return row


def _day(conn: sqlite3.Connection, user: User, day_id: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM days WHERE id = ? AND deleted_at IS NULL", (day_id,)).fetchone()
    if not row:
        raise ServiceError("Tag nicht gefunden.")
    _need(conn, user, row["trip_id"], "editor")
    return row


def _ordered(conn: sqlite3.Connection, day_id: str) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM stops WHERE day_id = ? AND deleted_at IS NULL ORDER BY sort_order, created_at", (day_id,)).fetchall()


def _renumber(ids: list[str]) -> list[tuple[Any, str, dict[str, Any]]]:
    return [(STOP, stop_id, {"sort_order": index}) for stop_id, index in planning.renumber_ids(ids).items()]


def _copy(row: sqlite3.Row | dict[str, Any], day_id: str, order: int, target_date: str | None = None) -> dict[str, Any]:
    clone = {k: row[k] for k in COPY_FIELDS}
    if clone["planned_time"] and target_date:
        clone["planned_time"] = planning.with_date(clone["planned_time"], target_date)
    return {**clone, "day_id": day_id, "sort_order": order, "is_done": 0}


def _label(day: sqlite3.Row) -> str:
    return day["date"]


def move_stop(conn: sqlite3.Connection, user: User, stop_id: str, actor: str, via: str, index: int | None = None,
              day_id: str | None = None) -> dict[str, Any]:
    """Moves a stop inside its day to a new position, or to another day (at the end, or at `index`), keeping its time of day."""
    stop = _stop(conn, user, stop_id)
    source = _day(conn, user, stop["day_id"])
    if day_id is None or day_id == stop["day_id"]:
        if index is None:
            raise ServiceError("index fehlt.")
        ids = [r["id"] for r in _ordered(conn, source["id"])]
        order = planning.move_within(ids, stop_id, index)
        change = apply_batch(conn, stop["trip_id"], actor, via, f"Stopp verschoben: {stop['name']} ({_label(source)})", _renumber(order))
        return {"change_id": change}
    target = _day(conn, user, day_id)
    if target["trip_id"] != stop["trip_id"]:
        raise ServiceError("Der Tag gehört zu einer anderen Reise.")
    left = [r["id"] for r in _ordered(conn, source["id"]) if r["id"] != stop_id]
    there = [r["id"] for r in _ordered(conn, target["id"])]
    new_order = planning.move_within(there + [stop_id], stop_id, len(there) if index is None else index)
    fields: dict[str, Any] = {"day_id": target["id"], "sort_order": new_order.index(stop_id)}
    if stop["planned_time"]:
        fields["planned_time"] = planning.with_date(stop["planned_time"], target["date"])
    updates = [(STOP, stop_id, fields), *_renumber(left), *[u for u in _renumber(new_order) if u[1] != stop_id]]
    change = apply_batch(conn, stop["trip_id"], actor, via, f"Stopp verschoben: {stop['name']} ({_label(source)} → {_label(target)})", updates)
    return {"change_id": change}


def duplicate_stop(conn: sqlite3.Connection, user: User, stop_id: str, actor: str, via: str) -> dict[str, Any]:
    """Day.duplicate: a copy right after the original."""
    stop = _stop(conn, user, stop_id)
    ids = [r["id"] for r in _ordered(conn, stop["day_id"])]
    order = planning.insert_copy_after(ids, stop_id, "__copy__")
    clone = _copy(stop, stop["day_id"], order.index("__copy__"))
    updates = [u for u in _renumber(order) if u[1] != "__copy__"]
    change = apply_batch(conn, stop["trip_id"], actor, via, f"Stopp kopiert: {stop['name']}", updates, [(STOP, clone)])
    return {"change_id": change}


def copy_day(conn: sqlite3.Connection, user: User, day_id: str, to_day_id: str, actor: str, via: str) -> dict[str, Any]:
    """Day.copyStops: copies of all stops are appended to another day, times moved to that day, nothing marked done."""
    source, target = _day(conn, user, day_id), _day(conn, user, to_day_id)
    if source["id"] == target["id"] or source["trip_id"] != target["trip_id"]:
        raise ServiceError("Wähle einen anderen Tag derselben Reise.")
    start = len(_ordered(conn, target["id"]))
    stops = _ordered(conn, source["id"])
    if not stops:
        raise ServiceError("Dieser Tag hat keine Stopps zum Kopieren.")
    inserts = [(STOP, _copy(s, target["id"], start + i, target["date"])) for i, s in enumerate(stops)]
    change = apply_batch(conn, source["trip_id"], actor, via, f"Tag kopiert: {_label(source)} → {_label(target)} ({len(stops)} Stopps)", [], inserts)
    return {"change_id": change, "copied": len(stops)}


def sort_day_by_time(conn: sqlite3.Connection, user: User, day_id: str, actor: str, via: str) -> dict[str, Any]:
    day = _day(conn, user, day_id)
    stops = [dict(r) for r in _ordered(conn, day["id"])]
    change = apply_batch(conn, day["trip_id"], actor, via, f"Nach Zeit sortiert ({_label(day)})", _renumber(planning.sort_by_time(stops)))
    return {"change_id": change}


def _trip_bookings(conn: sqlite3.Connection, trip_id: str) -> list[dict[str, Any]]:
    return [dict(r) for r in conn.execute("SELECT * FROM bookings WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,))]


def optimize_day(conn: sqlite3.Connection, user: User, day_id: str, actor: str, via: str) -> dict[str, Any]:
    """RouteOptimizer: a shorter walk through the day's stops. The hotel you sleep in is the starting point and not a stop."""
    day = _day(conn, user, day_id)
    stops = _ordered(conn, day["id"])
    missing = [s["name"] for s in stops if not (s["latitude"] or s["longitude"])]
    if missing:
        raise ServiceError("Für die Route braucht jeder Stopp eine Position. Es fehlt bei: " + ", ".join(missing[:5]))
    anchor = planning.day_window(day["date"], _trip_bookings(conn, day["trip_id"])).anchor
    points = ([anchor] if anchor else []) + [(s["latitude"], s["longitude"]) for s in stops]
    if len(points) <= 2:
        return {"change_id": None, "changed": False}
    order = [i - (1 if anchor else 0) for i in planning.optimize_order(points) if not (anchor and i == 0)]
    change = apply_batch(conn, day["trip_id"], actor, via, f"Route optimiert ({_label(day)})", _renumber([stops[i]["id"] for i in order]))
    return {"change_id": change, "changed": change is not None}


def retime_day(conn: sqlite3.Connection, user: User, day_id: str, actor: str, via: str, start: str | None = None) -> dict[str, Any]:
    """TimeAdjuster: lays the stops out again, one after the other with the way between them. Starts at `start` (HH:MM) or at the
    time the day is meant to begin (earliest time already in it, else 9:00, not before landing)."""
    day = _day(conn, user, day_id)
    trip = conn.execute("SELECT transport_raw FROM trips WHERE id = ?", (day["trip_id"],)).fetchone()
    stops = [dict(r) for r in _ordered(conn, day["id"])]
    if not stops:
        raise ServiceError("Dieser Tag hat keine Stopps.")
    window = planning.day_window(day["date"], _trip_bookings(conn, day["trip_id"]))
    if start:
        try:
            first = datetime.fromisoformat(f"{day['date']}T{start}")
        except ValueError:
            raise ServiceError("Die Startzeit muss wie 09:30 aussehen.") from None
    else:
        first = planning.suggested_start(day["date"], stops, window, trip["transport_raw"])
    times = planning.day_times(stops, first, window.anchor, trip["transport_raw"])
    updates = [(STOP, s["id"], {"planned_time": t.strftime("%Y-%m-%dT%H:%M")}) for s, t in zip(stops, times)]
    change = apply_batch(conn, day["trip_id"], actor, via, f"Zeiten angepasst ({_label(day)})", updates)
    return {"change_id": change, "start": first.strftime("%H:%M")}


def add_booking_stops(conn: sqlite3.Connection, user: User, trip_id: str, actor: str, via: str) -> dict[str, Any]:
    """BookingPlanner: flights and hotel check-in/out as stops on the right day and time, then each touched day sorted by time."""
    _need(conn, user, trip_id, "editor")
    days = {r["date"]: r["id"] for r in conn.execute("SELECT id, date FROM days WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,))}
    wanted, skipped = planning.booking_stops(_trip_bookings(conn, trip_id), set(days))
    updates: list[tuple[Any, str, dict[str, Any]]] = []
    inserts: list[tuple[Any, dict[str, Any]]] = []
    added = 0
    for date in sorted({w["planned_time"][:10] for w in wanted}):
        day_id = days[date]
        existing = [dict(r) for r in _ordered(conn, day_id)]
        names = {s["name"] for s in existing}
        fresh = [w for w in wanted if w["planned_time"][:10] == date and w["name"] not in names]
        if not fresh:
            continue
        merged = existing + [{**w, "id": f"__new{i}"} for i, w in enumerate(fresh)]
        order = planning.sort_by_time(merged)
        updates += [(STOP, i, {"sort_order": n}) for n, i in enumerate(order) if not i.startswith("__new")]
        for i, w in enumerate(fresh):
            inserts.append((STOP, {**w, "day_id": day_id, "sort_order": order.index(f"__new{i}"), "address": w.get("address", "")}))
            added += 1
    change = apply_batch(conn, trip_id, actor, via, f"Flüge und Hotels in den Plan gelegt ({added} Stopps)", updates, inserts)
    return {"change_id": change, "added": added, "skipped_without_position": skipped}


def stop_from_place(conn: sqlite3.Connection, user: User, place_id: str, day_id: str, actor: str, via: str) -> dict[str, Any]:
    """An idea becomes a stop at the end of a day (the app's "Move to Day N" on a saved place)."""
    place = conn.execute("SELECT * FROM places WHERE id = ? AND deleted_at IS NULL", (place_id,)).fetchone()
    if not place:
        raise ServiceError("Ort nicht gefunden.")
    day = _day(conn, user, day_id)
    if day["trip_id"] != place["trip_id"]:
        raise ServiceError("Der Tag gehört zu einer anderen Reise.")
    existing = [dict(r) for r in _ordered(conn, day["id"])]
    if places.duplicate(existing, place["name"], place["latitude"], place["longitude"]):
        raise ServiceError(f"„{place['name']}“ steht an diesem Tag schon im Plan.")
    row: dict[str, Any] = {
        "day_id": day["id"], "name": place["name"], "notes": place["notes"], "website": place["website"], "category_raw": "sight",
        "duration_minutes": 60, "sort_order": len(existing), "place_id": place["id"],
        **({"latitude": place["latitude"], "longitude": place["longitude"]} if place["has_coordinate"] else {}),
    }
    change = apply_batch(conn, place["trip_id"], actor, via, f"Auf Tag gelegt: {place['name']} ({_label(day)})", [], [(STOP, row)])
    return {"change_id": change}
