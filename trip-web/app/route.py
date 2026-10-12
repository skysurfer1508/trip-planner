"""The route between places: Tokyo -> Osaka -> Hiroshima ... One move is a `hop`; a hop has one or more legs (ways to do it: Nozomi,
Hikari, a night bus, a flight), at most one of them chosen. The family picks, Claude proposes with duration, price per person and source.

There is no open source of timetables and fares for Japan (Transitous knows nothing there), so every number comes from whoever enters it
(usually Claude, with a source and the date it was true), and the website stores, compares and draws it."""
import sqlite3
from typing import Any

from . import service
from .entities import entity_of
from .rates import convert
from .service import ServiceError, User, apply_batch

LEG = entity_of("leg")
MODE_LABEL = {"shinkansen": "Shinkansen", "train": "Zug", "bus": "Bus", "flight": "Flug", "ferry": "Fähre", "car": "Auto", "taxi": "Taxi", "walk": "zu Fuss", "other": "Sonstiges"}
DECIDED = ("chosen", "booked")


def check_leg(conn: sqlite3.Connection, trip_id: str, row: dict[str, Any], leg_id: str | None = None) -> None:
    """At most one leg per hop is chosen. Changing the choice goes through `choose_leg`, which is one undoable step."""
    if row.get("status") in DECIDED:
        hop = row["hop"]
        clash = conn.execute(
            "SELECT id FROM route_legs WHERE trip_id = ? AND hop = ? AND status IN ('chosen','booked') AND deleted_at IS NULL AND id != ?",
            (trip_id, hop, leg_id or ""),
        ).fetchone()
        if clash:
            raise ServiceError(f"Für Abschnitt {hop} ist schon eine Etappe gewählt. Wähle die neue mit choose_leg (in der App: \"Wählen\").")


def next_hop(conn: sqlite3.Connection, trip_id: str) -> int:
    last = conn.execute("SELECT MAX(hop) FROM route_legs WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,)).fetchone()[0]
    return 1 if last is None else last + 1


def defaults_for_new(conn: sqlite3.Connection, trip_id: str, row: dict[str, Any]) -> None:
    """A new leg starts a new hop unless it says which one; the first leg of a hop is the chosen one, the others are options."""
    row.setdefault("hop", next_hop(conn, trip_id))
    if "status" not in row:
        taken = conn.execute("SELECT 1 FROM route_legs WHERE trip_id = ? AND hop = ? AND deleted_at IS NULL", (trip_id, row["hop"])).fetchone()
        row["status"] = "option" if taken else "chosen"
    if "currency_code" in row:
        row["currency_code"] = row["currency_code"].upper()


def choose_leg(conn: sqlite3.Connection, user: User, leg_id: str, actor: str, via: str) -> dict[str, Any]:
    """Makes this leg the way for its hop; whichever was chosen before becomes an option again. One entry in the history."""
    leg = conn.execute("SELECT * FROM route_legs WHERE id = ? AND deleted_at IS NULL", (leg_id,)).fetchone()
    if not leg:
        raise ServiceError("Etappe nicht gefunden.")
    service._need(conn, user, leg["trip_id"], "editor")
    siblings = conn.execute(
        "SELECT id FROM route_legs WHERE trip_id = ? AND hop = ? AND deleted_at IS NULL AND id != ? AND status IN ('chosen','booked')",
        (leg["trip_id"], leg["hop"], leg_id)).fetchall()
    updates = [(LEG, s["id"], {"status": "option"}) for s in siblings]
    updates.append((LEG, leg_id, {"status": "booked" if leg["status"] == "booked" else "chosen"}))
    change = apply_batch(conn, leg["trip_id"], actor, via, f"Gewählt: {LEG.name_of(leg)} ({MODE_LABEL.get(leg['mode'], leg['mode'])})", updates)
    return {"change_id": change}


def shift_hop(conn: sqlite3.Connection, user: User, trip_id: str, hop: int, delta: int, actor: str, via: str) -> dict[str, Any]:
    """Moves a whole hop (all its options) up or down in the route by swapping numbers with its neighbour."""
    service._need(conn, user, trip_id, "editor")
    hops = [r["hop"] for r in conn.execute("SELECT DISTINCT hop FROM route_legs WHERE trip_id = ? AND deleted_at IS NULL ORDER BY hop", (trip_id,))]
    if hop not in hops:
        raise ServiceError("Abschnitt nicht gefunden.")
    other_index = hops.index(hop) + (1 if delta > 0 else -1)
    if not 0 <= other_index < len(hops):
        return {"change_id": None}
    other = hops[other_index]
    legs = conn.execute("SELECT id, hop FROM route_legs WHERE trip_id = ? AND hop IN (?, ?) AND deleted_at IS NULL", (trip_id, hop, other)).fetchall()
    updates = [(LEG, r["id"], {"hop": other if r["hop"] == hop else hop}) for r in legs]
    change = apply_batch(conn, trip_id, actor, via, f"Abschnitt {hop} und {other} getauscht", updates)
    return {"change_id": change}


def _leg(row: dict[str, Any], trip: dict[str, Any], table: dict[str, float] | None) -> dict[str, Any]:
    price = convert(row.get("price") or 0, row.get("currency_code") or "JPY", trip["currency_code"], table)
    people = trip.get("travelers") or 1
    return {**row, "mode_label": MODE_LABEL.get(row["mode"], row["mode"]),
            "price_in_trip_currency": None if price is None else round(price, 2),
            "group_price": None if price is None else round(price * people, 2)}


def summarize(trip: dict[str, Any], legs: list[dict[str, Any]], table: dict[str, float] | None) -> dict[str, Any]:
    """The route as the family reads it: the hops in order with the chosen way and the options, the total time and cost, and what is missing."""
    legs = sorted((l for l in legs if not l.get("deleted_at")), key=lambda l: (l["hop"], l.get("sort_order") or 0))
    people = trip.get("travelers") or 1
    hops: list[dict[str, Any]] = []
    for number in sorted({l["hop"] for l in legs}):
        mine = [_leg(l, trip, table) for l in legs if l["hop"] == number]
        chosen = next((l for l in mine if l["status"] in DECIDED), None)
        first = chosen or mine[0]
        hops.append({"hop": number, "from_name": first["from_name"], "to_name": first["to_name"], "chosen": chosen,
                     "options": [l for l in mine if l is not chosen]})
    chosen_legs = [h["chosen"] for h in hops if h["chosen"]]
    warnings: list[str] = []
    for before, after in zip(hops, hops[1:]):
        if before["to_name"].strip().lower() != after["from_name"].strip().lower():
            warnings.append(f"Abschnitt {after['hop']} beginnt in {after['from_name']}, der vorige endet in {before['to_name']}.")
    undecided = [h["hop"] for h in hops if not h["chosen"]]
    if undecided:
        warnings.append("Noch keine Wahl für Abschnitt " + ", ".join(str(h) for h in undecided) + ".")
    unconverted = [l["id"] for l in chosen_legs if l["price_in_trip_currency"] is None and (l.get("price") or 0) > 0]
    if unconverted:
        warnings.append("Bei einigen gewählten Etappen lässt sich der Preis nicht umrechnen (Währung unbekannt oder Kurse nicht erreichbar).")
    per_person = sum(l["price_in_trip_currency"] or 0 for l in chosen_legs)
    return {
        "currency": trip["currency_code"], "travelers": people, "hops": hops,
        "places": _places(hops), "total_minutes": sum(l.get("duration_minutes") or 0 for l in chosen_legs),
        "price_per_person": round(per_person, 2), "price_for_group": round(per_person * people, 2),
        "decided": len(chosen_legs), "undecided": undecided, "warnings": warnings,
    }


def _places(hops: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The places along the chosen route, in order, with their positions (for the map)."""
    out: list[dict[str, Any]] = []
    for h in hops:
        leg = h["chosen"] or (h["options"][0] if h["options"] else None)
        if not leg:
            continue
        for name, lat, lon in ((leg["from_name"], leg["from_latitude"], leg["from_longitude"]), (leg["to_name"], leg["to_latitude"], leg["to_longitude"])):
            if not out or out[-1]["name"].lower() != name.lower():
                out.append({"name": name, "latitude": lat, "longitude": lon, "has_position": bool(lat or lon)})
    return out


# MARK: Ideas along the way

def _km(a: tuple[float, float], b: tuple[float, float]) -> float:
    from .geometry import haversine
    return haversine(a, b) / 1000


def distance_to_line(point: tuple[float, float], line: list[tuple[float, float]]) -> tuple[float, float]:
    """(kilometres from the line, how far along it from 0 to 1) for the closest point of a line (segments, flat-earth approximation is fine at these sizes)."""
    import math
    cos = math.cos(math.radians(point[0]))
    xy = lambda p: ((p[1]) * cos * 111.32, p[0] * 110.57)
    px, py = xy(point)
    best, where, total, run = math.inf, 0.0, 0.0, 0.0
    segments = []
    for a, b in zip(line, line[1:]):
        (ax, ay), (bx, by) = xy(a), xy(b)
        length = math.hypot(bx - ax, by - ay)
        segments.append((ax, ay, bx, by, length))
        total += length
    for ax, ay, bx, by, length in segments:
        dx, dy = bx - ax, by - ay
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (length * length)))
        d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
        if d < best:
            best, where = d, run + t * length
        run += length
    return best, (where / total if total else 0.0)


def nearby(places: list[dict[str, Any]], hops: list[dict[str, Any]], path_of, radius_km: float = 25, ends_km: float = 25) -> None:
    """Adds `nearby` to each hop: ideas (not rejected) that lie within `radius_km` of the way but not in the start or end city.
    `path_of(leg)` gives the real path if known; otherwise the straight line is used."""
    candidates = [p for p in places if p.get("has_coordinate") and p.get("decision") != "Nein" and not p.get("deleted_at") and p.get("prio") != "Flughafen"]
    for hop in hops:
        leg = hop["chosen"] or (hop["options"][0] if hop["options"] else None)
        hop["nearby"] = []
        if not leg or not (leg["from_latitude"] or leg["from_longitude"]) or not (leg["to_latitude"] or leg["to_longitude"]):
            continue
        start, end = (leg["from_latitude"], leg["from_longitude"]), (leg["to_latitude"], leg["to_longitude"])
        line = [tuple(p) for p in (path_of(leg) or [start, end])]
        found = []
        for p in candidates:
            spot = (p["latitude"], p["longitude"])
            if _km(spot, start) <= ends_km or _km(spot, end) <= ends_km:
                continue
            distance, along = distance_to_line(spot, line)
            if distance <= radius_km:
                found.append({"id": p["id"], "name": p["name"], "region": p.get("region", ""), "category": p.get("category", ""), "prio": p.get("prio", ""),
                              "decision": p.get("decision", ""), "distance_km": round(distance, 1), "along": round(along, 2)})
        hop["nearby"] = sorted(found, key=lambda f: f["along"])


def full_summary(conn: sqlite3.Connection, data: dict[str, Any], table: dict[str, float] | None, with_paths: bool = True) -> dict[str, Any]:
    """What the route page and Claude's route_summary both show: the summary plus the JR Pass comparison, ideas along each way and the looked-up real paths."""
    from . import geometry, passes
    summary = summarize(data["trip"], data["legs"], table)
    summary["pass"] = passes.compare(data["trip"], summary["hops"], table)
    point = lambda leg, which: (leg[f"{which}_latitude"], leg[f"{which}_longitude"])
    paths = lambda leg: (geometry.cached_path(conn, leg["mode"], point(leg, "from"), point(leg, "to")) or {}).get("points")
    nearby(data["places"], summary["hops"], paths)
    if with_paths:
        for hop in summary["hops"]:
            for leg in [hop["chosen"], *hop["options"]]:
                if leg and any(point(leg, "from")) and any(point(leg, "to")):
                    found = geometry.cached_path(conn, leg["mode"], point(leg, "from"), point(leg, "to"))
                    if found:
                        leg["path"] = found["points"]
    return summary
