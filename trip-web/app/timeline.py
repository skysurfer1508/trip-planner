"""The trip as a sequence of stays: where the family sleeps, from which day to which, how they get there, and whether the nights add up."""
from datetime import date, timedelta
from typing import Any


def _date(value: str) -> date:
    return date.fromisoformat(value[:10])


def _same(a: str, b: str) -> bool:
    a, b = a.strip().lower(), b.strip().lower()
    return bool(a and b) and (a == b or a in b or b in a)


def build(trip: dict[str, Any], stays: list[dict[str, Any]], hops: list[dict[str, Any]], places: list[dict[str, Any]], tally: dict[str, dict[str, Any]] | None = None) -> dict[str, Any]:
    """`hops` as from route.summarize. A stay is reached by the hop that ends in a place with the same name."""
    tally = tally or {}
    start, end = _date(trip["start_date"]), _date(trip["end_date"])
    available = max(0, (end - start).days)
    stays = sorted((s for s in stays if not s.get("deleted_at")), key=lambda s: (s.get("sort_order") or 0, s.get("created_at") or ""))
    cursor = start
    items: list[dict[str, Any]] = []
    used_hops: set[int] = set()
    warnings: list[str] = []
    for index, stay in enumerate(stays):
        nights = int(stay.get("nights") or 0)
        arrive, leave = cursor, cursor + timedelta(days=nights)
        hop = next((h for h in hops if h["hop"] not in used_hops and _same(h["to_name"], stay["name"])), None) if index > 0 else None
        if hop:
            used_hops.add(hop["hop"])
        leg = (hop["chosen"] or (hop["options"][0] if hop["options"] else None)) if hop else None
        here = [p for p in places if p.get("decision") != "Nein" and not p.get("deleted_at") and (_same(p.get("region", ""), stay["name"]) or stay["name"].lower() in p["name"].lower())]
        liked = sum(len((tally.get(p["id"]) or {}).get("for", [])) for p in here)
        items.append({
            "id": stay["id"], "name": stay["name"], "nights": nights, "arrive": arrive.isoformat(), "leave": leave.isoformat(),
            "latitude": stay.get("latitude") or 0, "longitude": stay.get("longitude") or 0, "notes": stay.get("notes") or "",
            "arrival": None if not leg else {"hop": hop["hop"], "mode": leg["mode"], "mode_label": leg["mode_label"], "line": leg["line"],
                                              "duration_minutes": leg["duration_minutes"], "price_in_trip_currency": leg.get("price_in_trip_currency"),
                                              "chosen": hop["chosen"] is not None},
            "ideas": len(here), "must": sum(1 for p in here if p.get("prio") == "Muss"), "likes": liked,
        })
        if index > 0 and not leg:
            warnings.append(f"Für die Anreise nach {stay['name']} gibt es noch keinen Abschnitt in der Route.")
        elif leg and not hop["chosen"]:
            warnings.append(f"Für die Anreise nach {stay['name']} ist noch keine Fahrt gewählt.")
        if nights == 0 and index < len(stays) - 1:
            warnings.append(f"{stay['name']} hat 0 Nächte (nur Durchreise).")
        cursor = leave
    planned = sum(i["nights"] for i in items)
    if items and planned < available:
        warnings.append(f"Es fehlen noch {available - planned} {'Nacht' if available - planned == 1 else 'Nächte'} (verplant: {planned} von {available}).")
    elif planned > available:
        warnings.append(f"Es sind {planned - available} {'Nacht' if planned - available == 1 else 'Nächte'} zu viel verplant ({planned} von {available}).")
    route_order = [h["to_name"] for h in sorted(hops, key=lambda h: h["hop"])]
    stay_order = [i["name"] for i in items[1:]]
    matched = [r for r in route_order if any(_same(r, s) for s in stay_order)]
    if len(matched) > 1 and [next(s for s in stay_order if _same(r, s)) for r in matched] != [s for s in stay_order if any(_same(s, r) for r in matched)]:
        warnings.append("Die Reihenfolge der Aufenthalte weicht von der Reihenfolge in der Route ab.")
    return {"start": start.isoformat(), "end": end.isoformat(), "available_nights": available, "planned_nights": planned,
            "stays": items, "warnings": warnings, "travel_days": [i["arrive"] for i in items[1:]]}
