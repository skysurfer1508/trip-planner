"""Sync with the iPhone app.

The app keeps its own copy of a trip. Each sync it sends what it changed since the last sync (per field: the value it had, and the new one) and
asks for everything that changed on the server since the revision it last saw. A field is taken over when the server still has the value the
app started from; if someone else changed it meanwhile, the server's value stays (and the answer says so). That is a field-by-field three-way
merge without any timestamps on the phone.

Only trips in the building phase are synced: trip fields, the notes of a day, stops, bookings, expenses and the packing list.
Times are local wall-clock strings, exactly as everywhere else on the website.
"""
import sqlite3
from typing import Any

from . import service
from .db import transaction
from .entities import BY_TABLE, ENTITIES, ValidationError, entity_of, validate
from .planning import wanted_dates
from .service import ServiceError, User, new_id, now

KINDS = {"stop": "stops", "booking": "bookings", "expense": "expenses", "checklist_item": "checklist_items"}
TRIP_FIELDS = ("name", "destination", "start_date", "end_date", "currency_code", "budget", "transport_raw", "time_zone", "country_code",
               "destination_latitude", "destination_longitude")
DAY_FIELDS = ("notes",)
VIA = "app"
NULLABLE = ("planned_time",)


def _same(a: Any, b: Any) -> bool:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return abs(float(a) - float(b)) < 1e-9
    if isinstance(a, (bool, int)) and isinstance(b, (bool, int)):
        return bool(a) == bool(b) if isinstance(a, bool) or isinstance(b, bool) else a == b
    return (a or None) == (b or None) if (a in ("", None) or b in ("", None)) else a == b


def _value(entity_name: str, row: sqlite3.Row, key: str) -> Any:
    entity = entity_of(entity_name)
    value = row[key]
    return bool(value) if service._is_bool(entity, key) else value


def _day_id(conn: sqlite3.Connection, trip_id: str, date: str, rev: int) -> str:
    found = conn.execute("SELECT id FROM days WHERE trip_id = ? AND date = ? AND deleted_at IS NULL", (trip_id, date)).fetchone()
    if found:
        return found["id"]
    stamp, day_id = now(), new_id()
    conn.execute("INSERT INTO days (id, trip_id, date, rev, created_at, updated_at) VALUES (?,?,?,?,?,?)", (day_id, trip_id, date, rev, stamp, stamp))
    return day_id


# MARK: What the server has

def _row_out(conn: sqlite3.Connection, kind: str, row: sqlite3.Row) -> dict[str, Any]:
    entity = entity_of(kind)
    if row["deleted_at"]:
        return {"kind": kind, "id": row["id"], "deleted": True}
    fields = {k: _value(kind, row, k) for k in entity.fields if k in row.keys() and k not in ("day_id", "place_id", "has_coordinate")}
    out: dict[str, Any] = {"kind": kind, "id": row["id"], "deleted": False, "fields": fields}
    if kind == "stop":
        day = conn.execute("SELECT date FROM days WHERE id = ?", (row["day_id"],)).fetchone()
        out["fields"]["day"] = day["date"] if day else None
    return out


def changes_since(conn: sqlite3.Connection, trip_id: str, since: int) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    trip = conn.execute("SELECT * FROM trips WHERE id = ?", (trip_id,)).fetchone()
    if trip["rev"] > since:
        out.append({"kind": "trip", "id": trip_id, "deleted": False, "fields": {k: trip[k] for k in TRIP_FIELDS}})
    for day in conn.execute("SELECT * FROM days WHERE trip_id = ? AND rev > ? AND deleted_at IS NULL ORDER BY date", (trip_id, since)):
        out.append({"kind": "day", "id": day["date"], "deleted": False, "fields": {"notes": day["notes"]}})
    for kind, table in KINDS.items():
        for row in conn.execute(f"SELECT * FROM {table} WHERE trip_id = ? AND rev > ? ORDER BY created_at", (trip_id, since)):
            if row["deleted_at"] and since == 0:
                continue                      # a first download has no use for things that are already gone
            out.append(_row_out(conn, kind, row))
    return out


# MARK: What the app sends

def _apply_fields(conn: sqlite3.Connection, kind: str, row: sqlite3.Row | None, fields: dict[str, Any], current_of, conflicts: list[dict[str, Any]],
                  label: str) -> dict[str, Any]:
    """The values that may be written: those where the server still has the app's starting value (or already has the new one)."""
    accepted: dict[str, Any] = {}
    for key, change in fields.items():
        if not isinstance(change, dict) or "new" not in change:
            continue
        if row is None:
            accepted[key] = change["new"]
            continue
        current = current_of(key)
        if _same(current, change.get("base")) or _same(current, change["new"]):
            accepted[key] = change["new"]
        else:
            conflicts.append({"kind": kind, "id": row["id"] if "id" in row.keys() else "", "label": label, "field": key, "server": current, "app": change["new"]})
    return accepted


def push(conn: sqlite3.Connection, user: User, trip_id: str, since: int, changes: list[dict[str, Any]], actor: str) -> dict[str, Any]:
    role = service._need(conn, user, trip_id, "viewer")
    if conn.execute("SELECT phase FROM trips WHERE id = ?", (trip_id,)).fetchone()["phase"] != "building":
        raise ServiceError("Diese Reise ist noch in der Planungsphase und wird nicht mit der App abgeglichen. Starte zuerst die Aufbauphase auf der Website.")
    if changes and role == "viewer":
        raise ServiceError("Du darfst diese Reise nur ansehen, nicht ändern.")
    conflicts: list[dict[str, Any]] = []
    counts = {"changed": 0, "created": 0, "deleted": 0}
    with transaction(conn) as rev:
        touched_days: set[str] = set()
        trip = conn.execute("SELECT * FROM trips WHERE id = ?", (trip_id,)).fetchone()
        ordered = sorted(changes, key=lambda c: {"trip": 0, "day": 1}.get(c.get("kind"), 2))
        for change in ordered:
            kind, item_id = change.get("kind"), str(change.get("id", ""))
            if kind == "trip":
                fields = {k: v for k, v in (change.get("fields") or {}).items() if k in TRIP_FIELDS}
                current = conn.execute("SELECT * FROM trips WHERE id = ?", (trip_id,)).fetchone()
                accepted = _apply_fields(conn, "trip", current, fields, lambda k: current[k], conflicts, current["name"])
                if accepted:
                    values = service._trip_values(accepted)
                    start, end = values.get("start_date", current["start_date"]), values.get("end_date", current["end_date"])
                    if end < start:
                        raise ServiceError("Das Ende der Reise liegt vor dem Start.")
                    conn.execute(f"UPDATE trips SET {', '.join(f'{k} = ?' for k in values)}, rev = ?, updated_at = ? WHERE id = ?",
                                 [*values.values(), rev, now(), trip_id])
                    if "start_date" in values or "end_date" in values:
                        service._sync_days(conn, trip_id, start, end, rev)
                    counts["changed"] += 1
            elif kind == "day":
                date = item_id
                row = conn.execute("SELECT * FROM days WHERE trip_id = ? AND date = ? AND deleted_at IS NULL", (trip_id, date)).fetchone()
                fields = {k: v for k, v in (change.get("fields") or {}).items() if k in DAY_FIELDS}
                if row is None:
                    if date in set(wanted_dates(trip["start_date"], trip["end_date"])) or fields:
                        day_id = _day_id(conn, trip_id, date, rev)
                        row = conn.execute("SELECT * FROM days WHERE id = ?", (day_id,)).fetchone()
                    else:
                        continue
                accepted = _apply_fields(conn, "day", row, fields, lambda k: row[k], conflicts, date)
                if accepted:
                    conn.execute("UPDATE days SET notes = ?, rev = ?, updated_at = ? WHERE id = ?", (accepted.get("notes", row["notes"]), rev, now(), row["id"]))
                    counts["changed"] += 1
            elif kind in KINDS:
                _item(conn, trip_id, since, kind, item_id, change, rev, conflicts, counts, touched_days)
            else:
                raise ServiceError(f"Unbekannte Art im Abgleich: {kind}")
        for day_id in touched_days:
            _renumber(conn, day_id, rev)
        if sum(counts.values()):
            service._log(conn, trip_id, "trips", trip_id, "update", actor, VIA,
                         f"Abgleich mit der App: {counts['created']} neu, {counts['changed']} geändert, {counts['deleted']} entfernt"
                         + (f", {len(conflicts)} Konflikte (Server behält seinen Wert)" if conflicts else ""))
    return {"trip_id": trip_id, "revision": service.revision(conn), "conflicts": conflicts, "counts": counts, "changes": changes_since(conn, trip_id, since)}


def _item(conn: sqlite3.Connection, trip_id: str, since: int, kind: str, item_id: str, change: dict[str, Any], rev: int,
          conflicts: list[dict[str, Any]], counts: dict[str, int], touched_days: set[str]) -> None:
    entity = entity_of(kind)
    table = entity.table
    row = conn.execute(f"SELECT * FROM {table} WHERE id = ? AND trip_id = ?", (item_id, trip_id)).fetchone()
    if conn.execute(f"SELECT 1 FROM {table} WHERE id = ? AND trip_id != ?", (item_id, trip_id)).fetchone():
        raise ServiceError("Diese Kennung gehört zu einer anderen Reise.")
    if not item_id or len(item_id) > 64:
        raise ServiceError("Ungültige Kennung im Abgleich.")
    if change.get("op") == "delete":
        if row is None or row["deleted_at"]:
            return
        if row["rev"] > since:
            conflicts.append({"kind": kind, "id": item_id, "label": entity.name_of(row), "field": "deleted", "server": "geändert", "app": "entfernt"})
            return
        conn.execute(f"UPDATE {table} SET deleted_at = ?, rev = ?, updated_at = ? WHERE id = ?", (now(), rev, now(), item_id))
        if kind == "stop":
            touched_days.add(row["day_id"])
        counts["deleted"] += 1
        return
    fields = dict(change.get("fields") or {})
    day_change = fields.pop("day", None)
    if row is not None and row["deleted_at"]:
        conflicts.append({"kind": kind, "id": item_id, "label": entity.name_of(row), "field": "deleted", "server": "entfernt", "app": "geändert"})
        return
    if row is None:
        values = {k: v["new"] for k, v in fields.items() if isinstance(v, dict) and "new" in v and k in entity.fields}
        if kind == "stop":
            date = (day_change or {}).get("new")
            if not date:
                raise ServiceError("Ein neuer Stopp braucht einen Tag.")
            values["day_id"] = _day_id(conn, trip_id, date, rev)
            touched_days.add(values["day_id"])
        clean = service._clean(entity, values)
        missing = [k for k in entity.required if k not in clean]
        if missing:
            raise ServiceError(f"Pflichtfelder fehlen ({kind}): {', '.join(missing)}")
        stamp = now()
        columns = ["id", "trip_id", "rev", "created_at", "updated_at", *clean]
        conn.execute(f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})", [item_id, trip_id, rev, stamp, stamp, *clean.values()])
        counts["created"] += 1
        return
    accepted = _apply_fields(conn, kind, row, {k: v for k, v in fields.items() if k in entity.fields}, lambda k: _value(kind, row, k), conflicts, entity.name_of(row))
    clean = service._clean(entity, accepted) if accepted else {}
    for key in NULLABLE:                      # the app clears a planned time by sending null; _clean drops nulls
        if key in accepted and accepted[key] is None and key in entity.fields:
            clean[key] = None
    if day_change is not None:
        current_day = conn.execute("SELECT date FROM days WHERE id = ?", (row["day_id"],)).fetchone()["date"]
        if _same(current_day, day_change.get("base")) or _same(current_day, day_change.get("new")):
            new_day = _day_id(conn, trip_id, day_change["new"], rev)
            if new_day != row["day_id"]:
                touched_days.update((row["day_id"], new_day))
                clean["day_id"] = new_day
        else:
            conflicts.append({"kind": kind, "id": item_id, "label": entity.name_of(row), "field": "day", "server": current_day, "app": day_change.get("new")})
    if clean:
        conn.execute(f"UPDATE {table} SET {', '.join(f'{k} = ?' for k in clean)}, rev = ?, updated_at = ? WHERE id = ?", [*clean.values(), rev, now(), item_id])
        counts["changed"] += 1
        if kind == "stop" and "sort_order" in clean:
            touched_days.add(row["day_id"])


def _renumber(conn: sqlite3.Connection, day_id: str, rev: int) -> None:
    """Stops of a day are numbered 0..n-1 without gaps or doubles (both sides may have moved things)."""
    rows = conn.execute("SELECT id, sort_order FROM stops WHERE day_id = ? AND deleted_at IS NULL ORDER BY sort_order, created_at", (day_id,)).fetchall()
    for index, row in enumerate(rows):
        if row["sort_order"] != index:
            conn.execute("UPDATE stops SET sort_order = ?, rev = ?, updated_at = ? WHERE id = ?", (index, rev, now(), row["id"]))


# MARK: Creating a trip from the app

def create_from_app(conn: sqlite3.Connection, user: User, snapshot: dict[str, Any], actor: str) -> dict[str, Any]:
    """The app uploads a whole trip it has never synced. The items keep the ids the app chose, so the next sync recognises them."""
    trip_values = {k: v for k, v in (snapshot.get("trip") or {}).items() if k in TRIP_FIELDS}
    try:
        trip_id = service.create_trip(conn, user, trip_values.get("name", ""), trip_values.get("destination", ""), trip_values.get("start_date", ""),
                                      trip_values.get("end_date", ""), **{k: v for k, v in trip_values.items() if k not in ("name", "destination", "start_date", "end_date")},
                                      phase="building")
    except TypeError as error:
        raise ServiceError(str(error)) from None
    changes = []
    for day in snapshot.get("days", []):
        changes.append({"kind": "day", "id": day["date"], "fields": {"notes": {"base": "", "new": day.get("notes", "")}}})
    for kind in KINDS:
        for item in snapshot.get({"stop": "stops", "booking": "bookings", "expense": "expenses", "checklist_item": "checklist"}[kind], []):
            fields = {k: {"base": None, "new": v} for k, v in item["fields"].items()}
            changes.append({"kind": kind, "id": item["id"], "op": "upsert", "fields": fields})
    result = push(conn, user, trip_id, 0, changes, actor)
    return result
