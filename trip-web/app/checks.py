"""Smart checks on a trip: things that look fine on the plan but will not work on the day. Pure functions on the plain data that
`service.trip_data` returns (no database, no network), so they are easy to test and the website and Claude get the same answers.

What it can know, and what not: opening hours are only checked for stops that have them (OpenStreetMap format, parsed like the iOS app does),
walking and transit times are estimates (straight line plus detour, as in planning.py), and there are no timetables, so "last train" is a
reminder for very late or very early rides, not a verdict."""
import hashlib
from datetime import date, datetime, timedelta
from functools import lru_cache
from typing import Any

from . import openinghours, planning

TIGHT_CONNECTION_MINUTES = 15
FULL_DAY_MINUTES = 10 * 60
LATE_MINUTE = 23 * 60
VERY_EARLY_MINUTE = 5 * 60 + 30
RIDES = {"train", "shinkansen", "bus"}


@lru_cache(maxsize=512)
def _hours(text: str):
    return openinghours.parse(text)


def _item(kind: str, severity: str, title: str, text: str, *, day: str | None = None, stop_id: str | None = None, leg_id: str | None = None) -> dict[str, Any]:
    subject = stop_id or leg_id or day or ""
    return {"key": f"{kind}:{subject}", "kind": kind, "severity": severity, "day": day, "stop_id": stop_id, "leg_id": leg_id, "title": title, "text": text}


def _start(day: str, stop: dict[str, Any]) -> datetime | None:
    return datetime.fromisoformat(planning.with_date(stop["planned_time"], day)) if stop.get("planned_time") else None


def _minutes(clock: str | None) -> int | None:
    return None if not clock else int(clock[:2]) * 60 + int(clock[3:5])


def _hhmm(moment: datetime) -> str:
    return moment.strftime("%H:%M")


def _point(stop: dict[str, Any]):
    lat, lon = stop.get("latitude") or 0.0, stop.get("longitude") or 0.0
    return (lat, lon) if lat or lon else None


def check_days(data: dict[str, Any], holidays: dict[str, str]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    transport = data["trip"].get("transport_raw") or "walking"
    stops_by_day: dict[str, list[dict[str, Any]]] = {}
    for stop in sorted(data["stops"], key=lambda s: s.get("sort_order", 0)):
        stops_by_day.setdefault(stop["day_id"], []).append(stop)

    for day in data["days"]:
        when = day["date"]
        stops = stops_by_day.get(day["id"], [])
        window = data.get("windows", {}).get(when) or {}
        if when in holidays:
            out.append(_item("holiday", "info", "Feiertag", f"{holidays[when]}: manche Orte haben geschlossen oder sind überfüllt.", day=when))

        def is_holiday(d: date) -> bool:
            return d.isoformat() in holidays

        timed = [(s, _start(when, s)) for s in stops]
        for stop, start in timed:
            if start is None:
                continue
            if stop.get("opening_hours") and (hours := _hours(stop["opening_hours"])):
                text = openinghours.warning(hours.verdict(start, stop.get("duration_minutes") or 60, is_holiday))
                if text:
                    out.append(_item("opening_hours", "warn", f"{stop['name']}: Öffnungszeiten", f"{text} (geplant {_hhmm(start)}).", day=when, stop_id=stop["id"]))
            minute = start.hour * 60 + start.minute
            if (ready := _minutes(window.get("start"))) is not None and minute < ready:
                out.append(_item("before_arrival", "warn", f"{stop['name']}: zu früh", f"Geplant {_hhmm(start)}, du bist erst ab {window['start']} bereit (Landung und Puffer).", day=when, stop_id=stop["id"]))
            finish = start + timedelta(minutes=stop.get("duration_minutes") or 60)
            if (leave := _minutes(window.get("end"))) is not None and finish.hour * 60 + finish.minute > leave and finish.date() == start.date():
                out.append(_item("after_departure", "warn", f"{stop['name']}: zu spät", f"Endet um {_hhmm(finish)}, aber um {window['end']} musst du zum Flughafen.", day=when, stop_id=stop["id"]))

        # Between two stops: is there enough time for the way?
        total = sum(s.get("duration_minutes") or 60 for s in stops)
        for (a, start_a), (b, start_b) in zip(timed, timed[1:]):
            way = planning._way(_point(a), _point(b), transport)
            total += way
            if start_a is None or start_b is None:
                continue
            gap = int((start_b - (start_a + timedelta(minutes=a.get("duration_minutes") or 60))).total_seconds() // 60)
            if gap < 0:
                out.append(_item("overlap", "warn", f"{b['name']}: Überschneidung", f"Beginnt um {_hhmm(start_b)}, «{a['name']}» dauert noch bis {_hhmm(start_b - timedelta(minutes=gap))}.", day=when, stop_id=b["id"]))
            elif way and gap < way:
                out.append(_item("tight_way", "warn", f"{b['name']}: Weg zu knapp", f"Von «{a['name']}» sind es etwa {way} Min, aber nur {gap} Min Zeit.", day=when, stop_id=b["id"]))
        if len(stops) >= 2 and total >= FULL_DAY_MINUTES:
            out.append(_item("full_day", "info", "Voller Tag", f"Etwa {total // 60} Std {total % 60} Min Programm und Wege auf einem Tag.", day=when))
        finishes = [s + timedelta(minutes=st.get("duration_minutes") or 60) for st, s in timed if s]
        if transport == "transit" and finishes and (last := max(finishes)).date() == date.fromisoformat(when) and last.hour * 60 + last.minute >= LATE_MINUTE:
            out.append(_item("late_evening", "info", "Spät unterwegs", f"Der letzte Stopp endet um {_hhmm(last)}. Prüfe, ob der letzte Zug oder Bus zurück noch fährt.", day=when))
    return out


def check_route(data: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    chosen = sorted((leg for leg in data.get("legs", []) if leg.get("status") in ("chosen", "booked")), key=lambda leg: leg.get("hop", 0))
    for leg in chosen:
        label = f"{leg['from_name']} → {leg['to_name']}"
        if leg.get("mode") not in RIDES:
            continue
        dep, arr = leg.get("departure"), leg.get("arrival")
        if dep and (minute := _minutes(dep[11:16])) is not None and minute < VERY_EARLY_MINUTE:
            out.append(_item("early_ride", "info", f"{label}: sehr früh", f"Abfahrt um {dep[11:16]}. Prüfe, ob der erste Zug oder Bus schon fährt.", day=dep[:10], leg_id=leg["id"]))
        if arr and (minute := _minutes(arr[11:16])) is not None and minute >= LATE_MINUTE:
            out.append(_item("late_ride", "info", f"{label}: sehr spät", f"Ankunft um {arr[11:16]}. Prüfe, ob diese Verbindung wirklich noch fährt.", day=arr[:10], leg_id=leg["id"]))
    for before, after in zip(chosen, chosen[1:]):
        if not before.get("arrival") or not after.get("departure"):
            continue
        gap = int((datetime.fromisoformat(after["departure"]) - datetime.fromisoformat(before["arrival"])).total_seconds() // 60)
        label = f"Anschluss in {before['to_name']}"
        if gap < 0:
            out.append(_item("impossible_connection", "warn", label, f"Ankunft {before['arrival'][11:16]}, aber die nächste Abfahrt ist schon um {after['departure'][11:16]}.", day=after["departure"][:10], leg_id=after["id"]))
        elif gap < TIGHT_CONNECTION_MINUTES:
            out.append(_item("tight_connection", "warn", label, f"Nur {gap} Min zum Umsteigen (Ankunft {before['arrival'][11:16]}, Abfahrt {after['departure'][11:16]}).", day=after["departure"][:10], leg_id=after["id"]))
    return out


def check_trip(data: dict[str, Any], holidays: dict[str, str] | None = None) -> list[dict[str, Any]]:
    """All warnings, the serious ones first, then by day."""
    found = check_days(data, holidays or {}) + check_route(data)
    return sorted(found, key=lambda w: (w["severity"] != "warn", w["day"] or "9999", w["key"]))


def digest(items: list[dict[str, Any]]) -> str:
    """A short fingerprint, so a page can tell whether the list changed."""
    return hashlib.sha1("|".join(i["key"] for i in items).encode()).hexdigest()[:8]
