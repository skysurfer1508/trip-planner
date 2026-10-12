"""The itinerary as text and as a calendar file, like ItineraryExporter.swift and CalendarExport.swift (the .ics rules are the same:
escaping, 75-byte folding, UTC times, an id made from the event's key so importing again updates instead of duplicating)."""
import hashlib
from datetime import datetime, timedelta, timezone
from typing import Any

from .archive import zone_of
from .service import ServiceError

WEEKDAYS = ("Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag")
MONTHS = ("Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember")


def long_date(day: str) -> str:
    d = datetime.fromisoformat(day)
    return f"{WEEKDAYS[d.weekday()]}, {d.day}. {MONTHS[d.month - 1]} {d.year}"


def date_range(start: str, end: str) -> str:
    a, b = datetime.fromisoformat(start), datetime.fromisoformat(end)
    return f"{a.day}. {MONTHS[a.month - 1]} {a.year} bis {b.day}. {MONTHS[b.month - 1]} {b.year}"


def plan_text(data: dict[str, Any]) -> str:
    """ItineraryExporter.text: name, destination, dates, then each day with its stops."""
    trip = data["trip"]
    lines = [trip["name"]]
    if trip.get("destination"):
        lines.append(trip["destination"])
    lines += [date_range(trip["start_date"], trip["end_date"]), ""]
    stops_by_day: dict[str, list[dict[str, Any]]] = {}
    for stop in data["stops"]:
        stops_by_day.setdefault(stop["day_id"], []).append(stop)
    for number, day in enumerate(data["days"], start=1):
        lines.append(f"Tag {number} · {long_date(day['date'])}")
        window = data.get("windows", {}).get(day["date"])
        if window and window.get("hotel"):
            lines.append(f"   Start im Hotel: {window['hotel']}")
        stops = sorted(stops_by_day.get(day["id"], []), key=lambda s: s.get("sort_order") or 0)
        if not stops:
            lines.append("   (nichts geplant)")
        for stop in stops:
            line = "• " + (f"{stop['planned_time'][11:16]} " if stop.get("planned_time") else "") + stop["name"]
            if stop.get("address"):
                line += f" ({stop['address']})"
            lines.append(line)
            if stop.get("notes"):
                lines.append(f"   {stop['notes']}")
        lines.append("")
    return "\n".join(lines)


# MARK: Calendar file

def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\r\n", "\\n").replace("\n", "\\n")


def fold(line: str) -> list[str]:
    """Lines longer than 75 bytes continue on the next line, which starts with a space."""
    result: list[str] = []
    current, size = "", 0
    for char in line:
        width = len(char.encode())
        if size + width > (75 if not result else 74):
            result.append(current)
            current, size = "", 0
        current += char
        size += width
    result.append(current)
    return [part if i == 0 else " " + part for i, part in enumerate(result)]


def uid(key: str) -> str:
    return hashlib.sha256(key.encode()).digest()[:16].hex() + "@tripplanner"


def _utc(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def events(data: dict[str, Any], zone_name: str) -> list[dict[str, Any]]:
    """Stops with a time and the day's flights and hotel items. Times are the clock at the destination, turned into real moments."""
    zone = zone_of(zone_name)
    trip = data["trip"]
    stops_by_day: dict[str, list[dict[str, Any]]] = {}
    for stop in data["stops"]:
        stops_by_day.setdefault(stop["day_id"], []).append(stop)
    out: list[dict[str, Any]] = []
    for index, day in enumerate(data["days"]):
        for stop in sorted(stops_by_day.get(day["id"], []), key=lambda s: s.get("sort_order") or 0):
            if not stop.get("planned_time"):
                continue
            start = datetime.fromisoformat(stop["planned_time"]).replace(tzinfo=zone)
            out.append({
                "key": f"{trip['name']}|{index}|{stop['name']}|{int(start.timestamp())}", "title": stop["name"], "start": start,
                "end": start + timedelta(minutes=max(stop.get("duration_minutes") or 60, 15)),
                "location": stop.get("address") or stop["name"],
                "geo": (stop["latitude"], stop["longitude"]) if stop.get("latitude") or stop.get("longitude") else None,
                "notes": stop.get("notes", ""), "url": stop.get("website", ""), "alarm": 30,
            })
        for item in (data.get("windows", {}).get(day["date"]) or {}).get("items", []):
            start = datetime.fromisoformat(f"{day['date']}T{item['time']}").replace(tzinfo=zone)
            out.append({"key": f"{trip['name']}|logistics|{index}|{item['text']}", "title": item["text"], "start": start,
                        "end": start + timedelta(minutes=30), "location": "", "geo": None, "notes": "", "url": "", "alarm": 60})
    return sorted(out, key=lambda e: e["start"])


def ics(data: dict[str, Any], zone_name: str, now: datetime | None = None) -> str:
    items = events(data, zone_name)
    if not items:
        raise ServiceError("Es gibt noch nichts mit Uhrzeit, das sich in einen Kalender legen liesse.")
    stamp = _utc(now or datetime.now(timezone.utc))
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TripPlanner//EN", "CALSCALE:GREGORIAN", f"X-WR-CALNAME:{escape(data['trip']['name'])}"]
    for e in items:
        lines += ["BEGIN:VEVENT", f"UID:{uid(e['key'])}", f"DTSTAMP:{stamp}", f"DTSTART:{_utc(e['start'])}", f"DTEND:{_utc(e['end'])}",
                  f"SUMMARY:{escape(e['title'])}"]
        if e["location"]:
            lines.append(f"LOCATION:{escape(e['location'])}")
        if e["geo"]:
            lines.append(f"GEO:{e['geo'][0]};{e['geo'][1]}")
        if e["notes"]:
            lines.append(f"DESCRIPTION:{escape(e['notes'])}")
        if e["url"]:
            lines.append(f"URL:{e['url']}")
        lines += ["BEGIN:VALARM", f"TRIGGER:-PT{e['alarm']}M", "ACTION:DISPLAY", f"DESCRIPTION:{escape(e['title'])}", "END:VALARM", "END:VEVENT"]
    lines.append("END:VCALENDAR")
    return "\r\n".join(part for line in lines for part in fold(line)) + "\r\n"
