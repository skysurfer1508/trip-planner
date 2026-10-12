"""All reads and writes of trip data. The website and Claude's connector call the same functions, so both get the same
access rules, the same checks, the same change log and the same undo.

Every function takes the signed-in user first (the Authentik `sub`). A trip is only visible to its members; writing needs the
role owner or editor, managing members needs owner. `SYSTEM` is for the command line and tests, never for a web request."""
import json
import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Any

from .db import transaction
from .categories import classify
from .entities import BY_TABLE, TRIP, Entity, ValidationError, entity_of, validate
from .planning import day_window, wanted_dates


class ServiceError(Exception):
    """A problem the caller can fix; the message is shown to the person or to Claude."""


class _System:
    def __repr__(self) -> str:
        return "SYSTEM"


SYSTEM = _System()
User = str | _System

ROLES = ("viewer", "editor", "owner")
LEVEL = {role: index for index, role in enumerate(ROLES)}
HIDDEN = {"trip_id", "created_at", "updated_at", "deleted_at", "rev"}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_id() -> str:
    return str(uuid.uuid4())


def _is_bool(entity: Entity, key: str) -> bool:
    return getattr(entity.fields.get(key), "doc", "") == "true | false"


def present(entity: Entity, row: sqlite3.Row | dict[str, Any], keep_empty: bool = False) -> dict[str, Any]:
    """A row as it is shown: no bookkeeping columns, no empty values, real booleans."""
    out: dict[str, Any] = {}
    for key, value in dict(row).items():
        if key in HIDDEN:
            continue
        if _is_bool(entity, key) or key == "has_coordinate":
            value = bool(value)
        if not keep_empty and (value is None or value == ""):
            continue
        out[key] = value
    return out


# MARK: Access

def _role(conn: sqlite3.Connection, user: User, trip_id: str) -> str | None:
    if user is SYSTEM:
        return "owner"
    row = conn.execute("SELECT role FROM trip_members WHERE trip_id = ? AND sub = ?", (trip_id, user)).fetchone()
    return row["role"] if row else None


def _need(conn: sqlite3.Connection, user: User, trip_id: str, level: str = "viewer") -> str:
    """Returns the user's role, or refuses. A trip the user is not in looks the same as one that does not exist."""
    role = _role(conn, user, trip_id)
    exists = conn.execute("SELECT 1 FROM trips WHERE id = ? AND deleted_at IS NULL", (trip_id,)).fetchone()
    if role is None or not exists:
        raise ServiceError("Reise nicht gefunden.")
    if LEVEL[role] < LEVEL[level]:
        raise ServiceError("Dafür fehlt dir die Berechtigung (du kannst diese Reise nur ansehen)."
                           if level == "editor" else "Das darf nur ein Besitzer dieser Reise.")
    return role


def _check(conn: sqlite3.Connection, trip: str, row: dict[str, Any]) -> None:
    """References must stay inside the same trip."""
    if "day_id" in row:
        found = conn.execute("SELECT trip_id FROM days WHERE id = ? AND deleted_at IS NULL", (row["day_id"],)).fetchone()
        if not found or found["trip_id"] != trip:
            raise ServiceError("day_id gehört zu keinem Tag dieser Reise")
    if row.get("place_id"):
        found = conn.execute("SELECT trip_id FROM places WHERE id = ? AND deleted_at IS NULL", (row["place_id"],)).fetchone()
        if not found or found["trip_id"] != trip:
            raise ServiceError("place_id gehört zu keinem Ort dieser Reise")


def _one_day_per_date(conn: sqlite3.Connection, trip: str, date: str, except_id: str | None = None) -> None:
    found = conn.execute("SELECT id FROM days WHERE trip_id = ? AND date = ? AND deleted_at IS NULL", (trip, date)).fetchone()
    if found and found["id"] != except_id:
        raise ServiceError(f"Für den {date} gibt es schon einen Tag.")


# MARK: People and members

def touch_person(conn: sqlite3.Connection, sub: str, name: str, email: str = "", username: str = "") -> None:
    conn.execute(
        "INSERT INTO people (sub, name, email, username, last_seen) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(sub) DO UPDATE SET name = excluded.name, email = excluded.email, username = excluded.username, "
        "last_seen = excluded.last_seen",
        (sub, name, email, username, now()),
    )


def list_people(conn: sqlite3.Connection, user: User) -> list[str]:
    """Names of the people the user shares a trip with (and the user), to suggest who is writing."""
    if user is SYSTEM:
        return [r["name"] for r in conn.execute("SELECT name FROM people ORDER BY name")]
    rows = conn.execute(
        "SELECT DISTINCT p.name FROM people p WHERE p.sub = ? OR p.sub IN ("
        "  SELECT m2.sub FROM trip_members m1 JOIN trip_members m2 ON m1.trip_id = m2.trip_id WHERE m1.sub = ?"
        ") ORDER BY p.name", (user, user)).fetchall()
    return [r["name"] for r in rows]


def resolve_actor(conn: sqlite3.Connection, user: User, name: str | None) -> str:
    clean = (name or "").strip()[:40]
    if not clean:
        raise ServiceError("acting_member fehlt. Frage, wer gerade mit Claude schreibt.")
    for known in list_people(conn, user):
        if known.lower() == clean.lower():
            return known
    return clean


def list_members(conn: sqlite3.Connection, user: User, trip_id: str) -> list[dict[str, Any]]:
    role = _need(conn, user, trip_id)
    rows = conn.execute(
        "SELECT m.sub, m.role, COALESCE(p.name, '') AS name, COALESCE(p.username, '') AS username FROM trip_members m "
        "LEFT JOIN people p ON p.sub = m.sub WHERE m.trip_id = ? ORDER BY m.added_at", (trip_id,)).fetchall()
    return [{"name": r["name"], "role": r["role"], **({"sub": r["sub"], "username": r["username"]} if LEVEL[role] == 2 else {})}
            for r in rows]


def find_people(conn: sqlite3.Connection, user: User, query: str) -> list[dict[str, str]]:
    """People who have signed in once, to pick from when sharing a trip. Only someone who owns a trip needs this list."""
    if user is not SYSTEM and not conn.execute("SELECT 1 FROM trip_members WHERE sub = ? AND role = 'owner'", (user,)).fetchone():
        raise ServiceError("Das Teilen einer Reise ist nur für Besitzer einer Reise möglich.")
    like = f"%{query.strip().lower()}%"
    rows = conn.execute(
        "SELECT sub, name, username FROM people WHERE lower(name) LIKE ? OR lower(username) LIKE ? OR lower(email) LIKE ? "
        "ORDER BY name LIMIT 20", (like, like, like)).fetchall()
    return [dict(r) for r in rows]


def set_member(conn: sqlite3.Connection, user: User, trip_id: str, sub: str, role: str) -> None:
    _need(conn, user, trip_id, "owner")
    if role not in ROLES:
        raise ServiceError(f"Rolle muss eine von {', '.join(ROLES)} sein.")
    if not conn.execute("SELECT 1 FROM people WHERE sub = ?", (sub,)).fetchone():
        raise ServiceError("Diese Person hat sich noch nie auf der Website angemeldet.")
    current = conn.execute("SELECT role FROM trip_members WHERE trip_id = ? AND sub = ?", (trip_id, sub)).fetchone()
    if current and current["role"] == "owner" and role != "owner" and _owner_count(conn, trip_id) == 1:
        raise ServiceError("Jede Reise braucht mindestens einen Besitzer.")
    with transaction(conn):
        conn.execute(
            "INSERT INTO trip_members (trip_id, sub, role, added_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(trip_id, sub) DO UPDATE SET role = excluded.role", (trip_id, sub, role, now()))


def remove_member(conn: sqlite3.Connection, user: User, trip_id: str, sub: str) -> None:
    """Owners remove anyone; everyone may leave a trip themselves."""
    if user != sub:
        _need(conn, user, trip_id, "owner")
    else:
        _need(conn, user, trip_id)
    current = conn.execute("SELECT role FROM trip_members WHERE trip_id = ? AND sub = ?", (trip_id, sub)).fetchone()
    if not current:
        raise ServiceError("Diese Person ist nicht Mitglied.")
    if current["role"] == "owner" and _owner_count(conn, trip_id) == 1:
        raise ServiceError("Jede Reise braucht mindestens einen Besitzer.")
    with transaction(conn):
        conn.execute("DELETE FROM trip_members WHERE trip_id = ? AND sub = ?", (trip_id, sub))


def _owner_count(conn: sqlite3.Connection, trip_id: str) -> int:
    return conn.execute("SELECT COUNT(*) FROM trip_members WHERE trip_id = ? AND role = 'owner'", (trip_id,)).fetchone()[0]


def claim_trips(conn: sqlite3.Connection, sub: str) -> int:
    """Makes `sub` the owner of every trip that has no member yet (trips made before access control existed)."""
    ids = [r["id"] for r in conn.execute(
        "SELECT t.id FROM trips t WHERE t.deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM trip_members m WHERE m.trip_id = t.id)")]
    with transaction(conn):
        for trip_id in ids:
            conn.execute("INSERT INTO trip_members (trip_id, sub, role, added_at) VALUES (?, ?, 'owner', ?)", (trip_id, sub, now()))
    return len(ids)


# MARK: Trips

def list_trips(conn: sqlite3.Connection, user: User) -> list[dict[str, Any]]:
    if user is SYSTEM:
        rows = conn.execute("SELECT t.*, 'owner' AS role FROM trips t WHERE t.deleted_at IS NULL ORDER BY t.start_date").fetchall()
    else:
        rows = conn.execute(
            "SELECT t.*, m.role AS role FROM trips t JOIN trip_members m ON m.trip_id = t.id "
            "WHERE m.sub = ? AND t.deleted_at IS NULL ORDER BY t.start_date", (user,)).fetchall()
    return [{k: v for k, v in dict(r).items() if k not in HIDDEN and v not in (None, "")} for r in rows]


def resolve_trip(conn: sqlite3.Connection, user: User, trip_id: str | None = None, need: str = "viewer") -> str:
    if trip_id:
        _need(conn, user, trip_id, need)
        return trip_id
    trips = list_trips(conn, user)
    if not trips:
        raise ServiceError("Es gibt noch keine Reise. Lege eine mit create_trip an.")
    if len(trips) > 1:
        raise ServiceError("Mehrere Reisen, gib trip_id an: " + "; ".join(f"{t['name']} = {t['id']}" for t in trips))
    _need(conn, user, trips[0]["id"], need)
    return trips[0]["id"]


def _sync_days(conn: sqlite3.Connection, trip_id: str, start: str, end: str, rev: int) -> None:
    """Makes the day rows match the trip dates (Trip.syncDays in the iOS app). A day that still has stops is never removed."""
    wanted = set(wanted_dates(start, end))
    existing = conn.execute("SELECT id, date FROM days WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,)).fetchall()
    stamp = now()
    for day in existing:
        if day["date"] not in wanted and not conn.execute(
                "SELECT 1 FROM stops WHERE day_id = ? AND deleted_at IS NULL", (day["id"],)).fetchone():
            conn.execute("UPDATE days SET deleted_at = ?, rev = ?, updated_at = ? WHERE id = ?", (stamp, rev, stamp, day["id"]))
    have = {d["date"] for d in existing}
    for date in sorted(wanted - have):
        conn.execute("INSERT INTO days (id, trip_id, date, rev, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                     (new_id(), trip_id, date, rev, stamp, stamp))


def _trip_values(data: dict[str, Any]) -> dict[str, Any]:
    try:
        row = validate(TRIP, data)
    except ValidationError as error:
        raise ServiceError(str(error)) from None
    if "name" in row:
        row["name"] = row["name"].strip()
        if not row["name"]:
            raise ServiceError("Ungültige Werte: name: darf nicht leer sein")
    if "country_code" in row:
        row["country_code"] = row["country_code"].upper()
    if "destination_latitude" in row and "destination_longitude" in row:
        row["has_destination_coordinate"] = 1
    return row


def create_trip(conn: sqlite3.Connection, user: User, name: str, destination: str, start_date: str, end_date: str,
                currency_code: str = "CHF", time_zone: str = "", country_code: str = "", description: str = "",
                **more: Any) -> str:
    row = _trip_values({"name": name, "destination": destination, "start_date": start_date, "end_date": end_date,
                        "currency_code": currency_code, "time_zone": time_zone, "country_code": country_code,
                        "description": description, "phase": "planning", **more})
    if row["end_date"] < row["start_date"]:
        raise ServiceError("Das Ende liegt vor dem Start.")
    trip_id, stamp = new_id(), now()
    with transaction(conn) as rev:
        columns = ["id", "rev", "created_at", "updated_at", *row]
        conn.execute(f"INSERT INTO trips ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                     [trip_id, rev, stamp, stamp, *row.values()])
        _sync_days(conn, trip_id, row["start_date"], row["end_date"], rev)
        if user is not SYSTEM:
            conn.execute("INSERT INTO trip_members (trip_id, sub, role, added_at) VALUES (?, ?, 'owner', ?)", (trip_id, user, stamp))
    return trip_id


def update_trip(conn: sqlite3.Connection, user: User, trip_id: str, data: dict[str, Any], actor: str, via: str) -> dict[str, Any]:
    _need(conn, user, trip_id, "editor")
    changes = _trip_values(data)
    if not changes:
        raise ServiceError("Keine Felder zum Ändern angegeben.")
    current = conn.execute("SELECT * FROM trips WHERE id = ?", (trip_id,)).fetchone()
    start, end = changes.get("start_date", current["start_date"]), changes.get("end_date", current["end_date"])
    if end < start:
        raise ServiceError("Das Ende liegt vor dem Start.")
    before = {k: current[k] for k in changes if k in TRIP.fields}
    with transaction(conn) as rev:
        assignments = ", ".join(f"{k} = ?" for k in changes)
        conn.execute(f"UPDATE trips SET {assignments}, rev = ?, updated_at = ? WHERE id = ?", [*changes.values(), rev, now(), trip_id])
        if "start_date" in changes or "end_date" in changes:
            _sync_days(conn, trip_id, start, end, rev)
        name = changes.get("name", current["name"])
        _log(conn, trip_id, "trips", trip_id, "update", actor, via,
             f"Reise geändert: {name} ({', '.join(k for k in changes if k in TRIP.fields)})", before=before,
             after={k: v for k, v in changes.items() if k in TRIP.fields})
    return trip_data(conn, user, trip_id)["trip"]


def delete_trip(conn: sqlite3.Connection, user: User, trip_id: str, actor: str, via: str) -> None:
    """Hides the trip for everyone. The rows stay in the database."""
    _need(conn, user, trip_id, "owner")
    name = conn.execute("SELECT name FROM trips WHERE id = ?", (trip_id,)).fetchone()["name"]
    with transaction(conn) as rev:
        conn.execute("UPDATE trips SET deleted_at = ?, rev = ?, updated_at = ? WHERE id = ?", (now(), rev, now(), trip_id))
        _log(conn, trip_id, "trips", trip_id, "delete", actor, via, f"Reise gelöscht: {name}")


# MARK: Reading

def list_items(conn: sqlite3.Connection, user: User, entity_name: str, trip_id: str | None = None,
               where: dict[str, Any] | None = None, limit: int = 200) -> dict[str, Any]:
    entity = entity_of(entity_name)
    trip = resolve_trip(conn, user, trip_id)
    clauses, params = ["trip_id = ?", "deleted_at IS NULL"], [trip]
    allowed = {"id", *entity.fields}
    for column, value in (where or {}).items():
        if column not in allowed:
            raise ServiceError(f"Filter auf \"{column}\" nicht möglich. Erlaubt: {', '.join(sorted(allowed))}")
        clauses.append(f"{column} = ?")
        params.append(int(value) if isinstance(value, bool) else value)
    rows = conn.execute(
        f"SELECT * FROM {entity.table} WHERE {' AND '.join(clauses)} ORDER BY {entity.order_by}, created_at LIMIT ?",
        (*params, max(1, min(limit, 300))),
    ).fetchall()
    return {"count": len(rows), "items": [present(entity, r) for r in rows]}


def get_plan(conn: sqlite3.Connection, user: User, trip_id: str | None = None) -> list[dict[str, Any]]:
    trip = resolve_trip(conn, user, trip_id)
    days = conn.execute("SELECT * FROM days WHERE trip_id = ? AND deleted_at IS NULL ORDER BY date", (trip,)).fetchall()
    stops = conn.execute(
        "SELECT * FROM stops WHERE trip_id = ? AND deleted_at IS NULL ORDER BY sort_order, planned_time, created_at", (trip,)
    ).fetchall()
    stop_entity, day_entity = entity_of("stop"), entity_of("day")
    return [
        {**present(day_entity, d), "stops": [present(stop_entity, s) for s in stops if s["day_id"] == d["id"]]}
        for d in days
    ]


def list_changes(conn: sqlite3.Connection, user: User, trip_id: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    trip = resolve_trip(conn, user, trip_id)
    rows = conn.execute(
        "SELECT id, summary, actor, via, created_at, undone_at FROM change_log WHERE trip_id = ? "
        "ORDER BY created_at DESC, rowid DESC LIMIT ?", (trip, max(1, min(limit, 100)))
    ).fetchall()
    return [{k: v for k, v in dict(r).items() if v is not None} for r in rows]


def trip_data(conn: sqlite3.Connection, user: User, trip_id: str) -> dict[str, Any]:
    """Everything the website shows for one trip, in one answer."""
    role = _need(conn, user, trip_id)
    trip = conn.execute("SELECT * FROM trips WHERE id = ?", (trip_id,)).fetchone()
    out: dict[str, Any] = {
        "trip": {k: v for k, v in dict(trip).items() if k not in ("created_at", "updated_at", "deleted_at", "rev")},
        "role": role,
    }
    for name, entity in {
        "places": entity_of("place"), "decisions": entity_of("decision"), "days": entity_of("day"),
        "stops": entity_of("stop"), "bookings": entity_of("booking"), "expenses": entity_of("expense"),
        "checklist": entity_of("checklist_item"), "legs": entity_of("leg"), "stays": entity_of("stay"),
    }.items():
        rows = conn.execute(
            f"SELECT * FROM {entity.table} WHERE trip_id = ? AND deleted_at IS NULL ORDER BY {entity.order_by}, created_at", (trip_id,)
        ).fetchall()
        out[name] = [{"id": r["id"], **present(entity, r, keep_empty=True)} for r in rows]
    out["windows"] = _windows(out["days"], out["bookings"])
    out["votes"] = list_votes(conn, trip_id)
    out["me"] = user if isinstance(user, str) else ""
    out["log"] = list_changes(conn, user, trip_id, 50)
    out["members"] = list_members(conn, user, trip_id)
    out["revision"] = revision(conn)
    return out


def _windows(days: list[dict[str, Any]], bookings: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """For days touched by a flight or a hotel: when the day may start or has to end, the hotel it starts from, and the bookings."""
    def clock(minute: int | None) -> str | None:
        return None if minute is None else f"{minute // 60:02d}:{minute % 60:02d}"

    out: dict[str, dict[str, Any]] = {}
    for day in days:
        window = day_window(day["date"], bookings)
        if not window.is_empty:
            out[day["date"]] = {"start": clock(window.start_minute), "end": clock(window.end_minute), "hotel": window.anchor_name,
                                "items": [{"time": clock(i["minute"]), "text": i["text"]} for i in window.items]}
    return out


def revision(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT value FROM meta WHERE key = 'revision'").fetchone()["value"]


# MARK: Writing

def _log(conn: sqlite3.Connection, trip: str, table: str, row_id: str, action: str, actor: str, via: str,
         summary: str, before: Any = None, after: Any = None) -> str:
    log_id = new_id()
    conn.execute(
        "INSERT INTO change_log (id, trip_id, table_name, row_id, action, actor, via, summary, before_json, after_json, created_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (log_id, trip, table, row_id, action, actor, via, summary,
         json.dumps(before, ensure_ascii=False) if before is not None else None,
         json.dumps(after, ensure_ascii=False) if after is not None else None, now()),
    )
    return log_id


def _api_values(entity: Entity, row: dict[str, Any]) -> dict[str, Any]:
    return {k: (bool(v) if _is_bool(entity, k) else v) for k, v in row.items() if k != "has_coordinate"}


def _insert(conn: sqlite3.Connection, entity: Entity, trip_id: str, row: dict[str, Any], rev: int) -> str:
    item_id, stamp = new_id(), now()
    columns = ["id", "trip_id", "rev", "created_at", "updated_at", *row]
    conn.execute(f"INSERT INTO {entity.table} ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                 [item_id, trip_id, rev, stamp, stamp, *row.values()])
    return item_id


def _clean(entity: Entity, data: dict[str, Any]) -> dict[str, Any]:
    """For imports: long text is shortened instead of refused, and unknown or empty values are dropped."""
    out: dict[str, Any] = {}
    for key, value in data.items():
        if key not in entity.fields or value is None:
            continue
        limit = getattr(entity.fields[key], "limit", None)
        out[key] = value[:limit] if isinstance(value, str) and limit else value
    return validate(entity, out)


def import_bundle(conn: sqlite3.Connection, user: User, bundle: dict[str, Any], actor: str, source: str) -> dict[str, Any]:
    """Creates a whole trip (days, stops, expenses, packing list, ideas, bookings) from already converted values, in one
    transaction and with one entry in the history. The user becomes the owner."""
    trip = _trip_values(bundle["trip"])
    if trip["end_date"] < trip["start_date"]:
        trip["end_date"] = trip["start_date"]
    counts = {"days": 0, "stops": 0, "expenses": 0, "checklist": 0, "places": 0, "bookings": 0}
    with transaction(conn) as rev:
        trip_id, stamp = new_id(), now()
        columns = ["id", "rev", "created_at", "updated_at", *trip]
        conn.execute(f"INSERT INTO trips ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                     [trip_id, rev, stamp, stamp, *trip.values()])
        _sync_days(conn, trip_id, trip["start_date"], trip["end_date"], rev)
        if user is not SYSTEM:
            conn.execute("INSERT INTO trip_members (trip_id, sub, role, added_at) VALUES (?, ?, 'owner', ?)", (trip_id, user, stamp))
        day_ids = {r["date"]: r["id"] for r in conn.execute("SELECT id, date FROM days WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,))}
        for day in bundle.get("days", []):
            row = _clean(entity_of("day"), {"date": day["date"], "notes": day.get("notes", "")})
            if row["date"] not in day_ids:
                day_ids[row["date"]] = _insert(conn, entity_of("day"), trip_id, row, rev)
            elif row.get("notes"):
                conn.execute("UPDATE days SET notes = ? WHERE id = ?", (row["notes"], day_ids[row["date"]]))
            counts["days"] += 1
            for stop in day.get("stops", []):
                _insert(conn, entity_of("stop"), trip_id, {**_clean(entity_of("stop"), stop), "day_id": day_ids[row["date"]]}, rev)
                counts["stops"] += 1
        for key, entity_name, label in (("expenses", "expense", "expenses"), ("checklist", "checklist_item", "checklist"),
                                        ("places", "place", "places"), ("bookings", "booking", "bookings")):
            for item in bundle.get(key, []):
                row = _clean(entity_of(entity_name), item)
                if entity_name == "place" and "category" not in row:
                    row["category"] = classify(row.get("name", ""), row.get("description", ""), row.get("region", ""))
                _insert(conn, entity_of(entity_name), trip_id, row, rev)
                counts[label] += 1
        summary = (f"Import aus {source}: {trip['name']} ({counts['stops']} Stopps, {counts['expenses']} Ausgaben, "
                   f"{counts['bookings']} Buchungen, {counts['checklist']} Packlisten-Einträge, {counts['places']} gespeicherte Orte)")
        _log(conn, trip_id, "trips", trip_id, "insert", actor, "import", summary)
    return {"trip_id": trip_id, "counts": counts}


def apply_batch(conn: sqlite3.Connection, trip_id: str, actor: str, via: str, summary: str,
                updates: list[tuple[Entity, str, dict[str, Any]]], inserts: list[tuple[Entity, dict[str, Any]]] = ()) -> str | None:
    """Several rows changed together (a move, a copy, a re-ordering): one entry in the history, undone as a whole. The entry
    keeps the inverse of every step, newest first. Rows that would not change are left out; nothing changed means no entry."""
    with transaction(conn) as rev:
        inverse: list[dict[str, Any]] = []
        for entity, item_id, fields in updates:
            current = conn.execute(f"SELECT * FROM {entity.table} WHERE id = ?", (item_id,)).fetchone()
            changed = {k: v for k, v in fields.items() if current[k] != v}
            if not changed:
                continue
            conn.execute(f"UPDATE {entity.table} SET {', '.join(f'{k} = ?' for k in changed)}, rev = ?, updated_at = ? WHERE id = ?",
                         [*changed.values(), rev, now(), item_id])
            inverse.append({"table": entity.table, "id": item_id, "set": {k: current[k] for k in changed}})
        for entity, row in inserts:
            item_id = _insert(conn, entity, trip_id, row, rev)
            inverse.append({"table": entity.table, "id": item_id, "set": {"deleted_at": now()}})
        if not inverse:
            return None
        return _log(conn, trip_id, inverse[0]["table"], inverse[0]["id"], "update", actor, via, summary, before={"_batch": inverse[::-1]})


def _undo_batch(conn: sqlite3.Connection, entry: sqlite3.Row, patches: list[dict[str, Any]], actor: str, via: str) -> dict[str, Any]:
    with transaction(conn) as rev:
        for patch in patches:
            entity = BY_TABLE.get(patch.get("table"))
            if not entity or not set(patch["set"]) <= {*entity.fields, "deleted_at"}:
                raise ServiceError("Diese Änderung lässt sich nicht rückgängig machen.")
            row = conn.execute(f"SELECT trip_id FROM {entity.table} WHERE id = ?", (patch["id"],)).fetchone()
            if not row or row["trip_id"] != entry["trip_id"]:
                raise ServiceError("Diese Änderung lässt sich nicht rückgängig machen.")
            conn.execute(f"UPDATE {entity.table} SET {', '.join(f'{k} = ?' for k in patch['set'])}, rev = ?, updated_at = ? WHERE id = ?",
                         [*patch["set"].values(), rev, now(), patch["id"]])
        conn.execute("UPDATE change_log SET undone_at = ? WHERE id = ?", (now(), entry["id"]))
        new_change = _log(conn, entry["trip_id"], entry["table_name"], entry["row_id"], "update", actor, via, f"Rückgängig: {entry['summary']}")
    return {"change_id": new_change}


def create_item(conn: sqlite3.Connection, user: User, entity_name: str, data: dict[str, Any], actor: str, via: str,
                trip_id: str | None = None) -> dict[str, Any]:
    entity = entity_of(entity_name)
    trip = resolve_trip(conn, user, trip_id, need="editor")
    try:
        row = validate(entity, data)
    except ValidationError as error:
        raise ServiceError(str(error)) from None
    missing = [k for k in entity.required if k not in row]
    if missing:
        raise ServiceError(f"Pflichtfelder fehlen: {', '.join(missing)}")
    _check(conn, trip, row)
    if entity.table == "days":
        _one_day_per_date(conn, trip, row["date"])
    if entity.table == "route_legs":
        from . import route
        route.defaults_for_new(conn, trip, row)
        route.check_leg(conn, trip, row)
    if entity.table == "places" and "category" not in row:  # a guess from the name and description; changeable
        row["category"] = classify(row.get("name", ""), row.get("description", ""), row.get("region", ""))
    if entity.table == "stays" and "sort_order" not in row:
        last = conn.execute("SELECT MAX(sort_order) FROM stays WHERE trip_id = ? AND deleted_at IS NULL", (trip,)).fetchone()[0]
        row["sort_order"] = 0 if last is None else last + 1
        row.setdefault("nights", 1)
    if entity.table == "stops" and "sort_order" not in row:  # like Day.append: at the end of the day
        last = conn.execute("SELECT MAX(sort_order) FROM stops WHERE day_id = ? AND deleted_at IS NULL", (row["day_id"],)).fetchone()[0]
        row["sort_order"] = 0 if last is None else last + 1
    with transaction(conn) as rev:
        item_id = _insert(conn, entity, trip, row, rev)
        change_id = _log(conn, trip, entity.table, item_id, "insert", actor, via,
                         f"{entity.label} hinzugefügt: {entity.name_of(row)}", after=_api_values(entity, row))
    created = conn.execute(f"SELECT * FROM {entity.table} WHERE id = ?", (item_id,)).fetchone()
    return {"id": item_id, "change_id": change_id, "item": present(entity, created)}


def _load(conn: sqlite3.Connection, user: User, entity: Entity, item_id: str, level: str = "editor") -> sqlite3.Row:
    row = conn.execute(f"SELECT * FROM {entity.table} WHERE id = ? AND deleted_at IS NULL", (item_id,)).fetchone()
    if not row:
        raise ServiceError("Eintrag nicht gefunden.")
    _need(conn, user, row["trip_id"], level)  # a trip the user is not in answers "not found" as well
    return row


def update_item(conn: sqlite3.Connection, user: User, entity_name: str, item_id: str, data: dict[str, Any],
                actor: str, via: str) -> dict[str, Any]:
    entity = entity_of(entity_name)
    current = _load(conn, user, entity, item_id)
    try:
        changes = validate(entity, data)
    except ValidationError as error:
        raise ServiceError(str(error)) from None
    if not changes:
        raise ServiceError("Keine Felder zum Ändern angegeben.")
    _check(conn, current["trip_id"], changes)
    if entity.table == "days" and "date" in changes:
        _one_day_per_date(conn, current["trip_id"], changes["date"], except_id=item_id)
    if entity.table == "route_legs":
        from . import route
        route.check_leg(conn, current["trip_id"], {**dict(current), **changes}, item_id)
    before = _api_values(entity, {k: current[k] for k in changes})
    assignments = ", ".join(f"{k} = ?" for k in changes)
    with transaction(conn) as rev:
        conn.execute(f"UPDATE {entity.table} SET {assignments}, rev = ?, updated_at = ? WHERE id = ?",
                     [*changes.values(), rev, now(), item_id])
        updated = conn.execute(f"SELECT * FROM {entity.table} WHERE id = ?", (item_id,)).fetchone()
        fields = ", ".join(k for k in changes if k != "has_coordinate")
        change_id = _log(conn, current["trip_id"], entity.table, item_id, "update", actor, via,
                         f"{entity.label} geändert: {entity.name_of(updated)} ({fields})",
                         before=before, after=_api_values(entity, changes))
    return {"change_id": change_id, "item": present(entity, updated)}


def remove_item(conn: sqlite3.Connection, user: User, entity_name: str, item_id: str, actor: str, via: str) -> dict[str, Any]:
    entity = entity_of(entity_name)
    current = _load(conn, user, entity, item_id)
    with transaction(conn) as rev:
        conn.execute(f"UPDATE {entity.table} SET deleted_at = ?, rev = ?, updated_at = ? WHERE id = ?", (now(), rev, now(), item_id))
        change_id = _log(conn, current["trip_id"], entity.table, item_id, "delete", actor, via,
                         f"{entity.label} entfernt: {entity.name_of(current)}")
    return {"change_id": change_id}


def undo_change(conn: sqlite3.Connection, user: User, change_id: str, actor: str, via: str) -> dict[str, Any]:
    entry = conn.execute("SELECT * FROM change_log WHERE id = ?", (change_id,)).fetchone()
    if not entry:
        raise ServiceError("Änderung nicht gefunden.")
    _need(conn, user, entry["trip_id"], "editor")
    if entry["undone_at"]:
        raise ServiceError("Diese Änderung wurde schon rückgängig gemacht.")
    if entry["via"] == "app":
        raise ServiceError("Ein Abgleich mit der App lässt sich nicht im Ganzen rückgängig machen. Ändere die einzelnen Einträge zurück.")
    entity = BY_TABLE.get(entry["table_name"])
    if not entity:
        raise ServiceError("Diese Änderung lässt sich nicht rückgängig machen.")
    saved = json.loads(entry["before_json"]) if entry["before_json"] else None
    if isinstance(saved, dict) and "_batch" in saved:
        return _undo_batch(conn, entry, saved["_batch"], actor, via)
    if entry["action"] == "insert":
        patch, sql_extra, params = {}, "deleted_at = ?", [now()]
    elif entry["action"] == "delete":
        patch, sql_extra, params = {}, "deleted_at = NULL", []
        if entity.table == "days":
            day = conn.execute("SELECT date FROM days WHERE id = ?", (entry["row_id"],)).fetchone()
            if day:
                _one_day_per_date(conn, entry["trip_id"], day["date"], except_id=entry["row_id"])
    else:
        try:
            patch = validate(entity, json.loads(entry["before_json"] or "{}"))
        except ValidationError as error:
            raise ServiceError(f"Rückgängig nicht möglich: {error}") from None
        sql_extra, params = "", []
        if entity.table == "days" and "date" in patch:
            _one_day_per_date(conn, entry["trip_id"], patch["date"], except_id=entry["row_id"])
    with transaction(conn) as rev:
        sets = [f"{k} = ?" for k in patch] + ([sql_extra] if sql_extra else []) + ["rev = ?", "updated_at = ?"]
        conn.execute(f"UPDATE {entity.table} SET {', '.join(sets)} WHERE id = ?", [*patch.values(), *params, rev, now(), entry["row_id"]])
        conn.execute("UPDATE change_log SET undone_at = ? WHERE id = ?", (now(), change_id))
        new_change = _log(conn, entry["trip_id"], entry["table_name"], entry["row_id"], "update", actor, via,
                          f"Rückgängig: {entry['summary']}")
    return {"change_id": new_change}


# MARK: Votes (who likes which idea)

def list_votes(conn: sqlite3.Connection, trip_id: str) -> list[dict[str, Any]]:
    rows = conn.execute("SELECT place_id, voter, name, value FROM votes WHERE trip_id = ? ORDER BY updated_at", (trip_id,)).fetchall()
    return [{"place_id": r["place_id"], "voter": r["voter"], "name": r["name"], "value": r["value"]} for r in rows]


async def trip_checks(conn: sqlite3.Connection, user: User, trip_id: str) -> dict[str, Any]:
    """The smart checks for one trip, split into open warnings and the ones the family chose to ignore."""
    from . import checks, holidays
    data = trip_data(conn, user, trip_id)
    trip = data["trip"]
    years = sorted({int(trip["start_date"][:4]), int(trip["end_date"][:4])})
    found = checks.check_trip(data, await holidays.for_years(trip.get("country_code", ""), years))
    ignored = {r["key"] for r in conn.execute("SELECT key FROM check_dismissals WHERE trip_id = ?", (trip_id,)).fetchall()}
    return {"checks": [c for c in found if c["key"] not in ignored], "ignored": [c for c in found if c["key"] in ignored],
            "holidays_checked": bool(trip.get("country_code"))}


def dismiss_check(conn: sqlite3.Connection, user: User, trip_id: str, key: str, ignore: bool = True) -> dict[str, Any]:
    """Ignore a warning for good (or take that back). Editors only, since the whole family sees the same list."""
    _need(conn, user, trip_id, "editor")
    key = key.strip()[:200]
    if not key:
        raise ServiceError("Es fehlt der Schlüssel der Warnung.")
    with transaction(conn):
        if ignore:
            conn.execute("INSERT OR IGNORE INTO check_dismissals (trip_id, key, created_at) VALUES (?,?,?)", (trip_id, key, now()))
        else:
            conn.execute("DELETE FROM check_dismissals WHERE trip_id = ? AND key = ?", (trip_id, key))
    return {"ok": True}


def photo_target(conn: sqlite3.Connection, user: User, place_id: str) -> dict[str, Any]:
    """What the picture lookup needs about an idea; anyone who can see the trip may ask."""
    place = conn.execute("SELECT trip_id, name, region, latitude, longitude, has_coordinate FROM places WHERE id = ? AND deleted_at IS NULL", (place_id,)).fetchone()
    if not place:
        raise ServiceError("Eintrag nicht gefunden.")
    _need(conn, user, place["trip_id"], "viewer")
    located = bool(place["has_coordinate"])
    return {"name": place["name"], "region": place["region"],
            "latitude": place["latitude"] if located else None, "longitude": place["longitude"] if located else None}


def vote(conn: sqlite3.Connection, user: User, place_id: str, value: int, member: str | None = None) -> dict[str, Any]:
    """+1, -1 or 0 (take back). Everyone who can see the trip may vote, also viewers. `member` is for Claude writing down what a named family member said."""
    if value not in (-1, 0, 1):
        raise ServiceError("Die Stimme muss 1, 0 oder -1 sein.")
    place = conn.execute("SELECT trip_id FROM places WHERE id = ? AND deleted_at IS NULL", (place_id,)).fetchone()
    if not place:
        raise ServiceError("Eintrag nicht gefunden.")
    _need(conn, user, place["trip_id"], "viewer")
    if member:
        voter, name = f"name:{member.strip().lower()[:40]}", member.strip()[:40]
        _need(conn, user, place["trip_id"], "editor")
    else:
        person = conn.execute("SELECT name FROM people WHERE sub = ?", (user,)).fetchone()
        voter, name = str(user), (person["name"] if person else str(user))
    with transaction(conn):
        if value == 0:
            conn.execute("DELETE FROM votes WHERE place_id = ? AND voter = ?", (place_id, voter))
        else:
            conn.execute("INSERT INTO votes (place_id, trip_id, voter, name, value, updated_at) VALUES (?,?,?,?,?,?) "
                         "ON CONFLICT(place_id, voter) DO UPDATE SET value = excluded.value, name = excluded.name, updated_at = excluded.updated_at",
                         (place_id, place["trip_id"], voter, name, value, now()))
    return {"ok": True, "votes": [v for v in list_votes(conn, place["trip_id"]) if v["place_id"] == place_id]}


def tally(votes: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Per idea: who is for, who is against. The same name counts once (a person who voted on the website wins over a note Claude took)."""
    out: dict[str, dict[str, Any]] = {}
    seen: dict[tuple[str, str], dict[str, Any]] = {}
    for v in votes:
        key = (v["place_id"], v["name"].lower())
        if key in seen and v["voter"].startswith("name:"):
            continue
        seen[key] = v
    for (place_id, _), v in seen.items():
        entry = out.setdefault(place_id, {"for": [], "against": []})
        entry["for" if v["value"] > 0 else "against"].append(v["name"])
    return out
