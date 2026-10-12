"""Planning rules taken over from the iOS app, as pure functions on plain values (no database).

Sources: Models/Day.swift, Models/Trip.swift, Services/RouteOptimizer.swift, ScheduleService.swift, TimeAdjuster.swift,
TripLogistics.swift, BookingPlanner.swift. Dates are local `YYYY-MM-DD`, times local `YYYY-MM-DDTHH:MM`; there are no time zones here,
exactly like the app's wall-clock times. The expected values in tests/test_planning.py are the ones in the app's own unit tests."""
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from math import asin, ceil, cos, radians, sin, sqrt
from typing import Any

MAX_DAYS = 120  # the app never makes more than 120 day rows for one trip
SLACK_MINUTES = 5
SPEED = {"walking": 1.3, "transit": 6.0, "car": 9.0}  # metres per second, used when no real routing time is known
DETOUR = 1.25  # streets are about 25% longer than the straight line

Point = tuple[float, float]  # latitude, longitude


# MARK: Days

def wanted_dates(start: str, end: str, cap: int = MAX_DAYS) -> list[str]:
    """Every date from start to end (end is at least start), at most `cap` of them. Trip.syncDays()."""
    first = date.fromisoformat(start)
    last = max(date.fromisoformat(end), first)
    out: list[str] = []
    cursor = first
    while cursor <= last and len(out) < cap:
        out.append(cursor.isoformat())
        cursor += timedelta(days=1)
    return out


def with_date(planned: str, day: str) -> str:
    """The same time of day on another date (Day.combine): `2026-11-01T09:30` on `2026-11-05` is `2026-11-05T09:30`."""
    return f"{day}{planned[10:16]}"


# MARK: Order of stops (Day.swift)

def renumber_ids(ids: list[str]) -> dict[str, int]:
    """Day.renumber: the order of a day is 0..n-1 in the given sequence."""
    return {stop_id: index for index, stop_id in enumerate(ids)}


def move_within(ids: list[str], stop_id: str, to_index: int) -> list[str]:
    """Takes the stop out and puts it at `to_index` of the remaining list (the app's drag and drop and its up/down buttons)."""
    rest = [i for i in ids if i != stop_id]
    index = max(0, min(to_index, len(rest)))
    return rest[:index] + [stop_id] + rest[index:]


def insert_copy_after(ids: list[str], original: str, copy: str) -> list[str]:
    """Day.duplicate: the copy sits right after the original."""
    at = ids.index(original) + 1 if original in ids else len(ids)
    return ids[:at] + [copy] + ids[at:]


def sort_by_time(stops: list[dict[str, Any]]) -> list[str]:
    """Day.sortByTime: stops with a time first (earliest first), the others keep their relative order after them. Stable."""
    indexed = list(enumerate(stops))
    timed = sorted((p for p in indexed if p[1].get("planned_time")), key=lambda p: (p[1]["planned_time"], p[0]))
    untimed = [p for p in indexed if not p[1].get("planned_time")]
    return [stop["id"] for _, stop in timed + untimed]


# MARK: Distances and routes (RoutingService.swift, RouteOptimizer.swift)

def straight_line(a: Point, b: Point) -> float:
    """Metres between two points (great circle; the app uses CLLocation, which differs by well under 1%)."""
    lat1, lat2 = radians(a[0]), radians(b[0])
    h = sin((lat2 - lat1) / 2) ** 2 + cos(lat1) * cos(lat2) * sin(radians(b[1] - a[1]) / 2) ** 2
    return 2 * 6371008.8 * asin(sqrt(h))


def route_length(points: list[Point]) -> float:
    return sum(straight_line(a, b) for a, b in zip(points, points[1:]))


def optimize_order(points: list[Point]) -> list[int]:
    """Nearest neighbour from the first point, then 2-opt clean-up. The first point stays first. Indices into `points`."""
    count = len(points)
    if count <= 2:
        return list(range(count))

    def d(i: int, j: int) -> float:
        return straight_line(points[i], points[j])

    route = [0]
    remaining = set(range(1, count))
    while remaining:
        last = route[-1]
        nearest = min(sorted(remaining), key=lambda candidate: d(last, candidate))  # ties: lowest index, like Set.min in practice
        route.append(nearest)
        remaining.discard(nearest)

    improved, rounds = True, 0
    while improved and rounds < 50:
        improved = False
        rounds += 1
        for i in range(1, count - 1):
            for j in range(i + 1, count):
                tail = j + 1 < count
                before = d(route[i - 1], route[i]) + (d(route[j], route[j + 1]) if tail else 0)
                after = d(route[i - 1], route[j]) + (d(route[i], route[j + 1]) if tail else 0)
                if after + 1e-6 < before:
                    route[i:j + 1] = reversed(route[i:j + 1])
                    improved = True
    return route


# MARK: Time (ScheduleService.swift, TimeAdjuster.swift)

def round_up(moment: datetime, minutes: int = SLACK_MINUTES) -> datetime:
    """Rounds up to the next 5 minutes."""
    step = minutes * 60
    seconds = moment.hour * 3600 + moment.minute * 60 + moment.second + moment.microsecond / 1e6
    rounded = ceil(seconds / step - 1e-9) * step
    return moment.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(seconds=rounded)


def auto_schedule(items: list[tuple[int, int]], start: datetime, slack: int = SLACK_MINUTES) -> list[datetime]:
    """ScheduleService.autoSchedule. Items are (stay minutes, travel minutes from the previous stop). Times are rounded up to 5 minutes."""
    times: list[datetime] = []
    cursor = round_up(start)
    for index, (duration, travel) in enumerate(items):
        if index > 0:
            cursor = round_up(cursor + timedelta(minutes=travel + slack))
        times.append(cursor)
        cursor += timedelta(minutes=max(duration, 5))
    return times


def travel_minutes(a: Point, b: Point, transport: str = "walking") -> int:
    """TimeAdjuster.travelMinutes without live transit times: straight line x 1.25 over the average speed, rounded up."""
    seconds = straight_line(a, b) * DETOUR / SPEED.get(transport, SPEED["walking"])
    return int(ceil(seconds / 60 - 1e-9))


def _point(stop: dict[str, Any]) -> Point | None:
    """A stop's position, or None when it has none (a stop added by hand: (0, 0) means unknown)."""
    lat, lon = stop.get("latitude") or 0.0, stop.get("longitude") or 0.0
    return (lat, lon) if lat or lon else None


def _way(a: Point | None, b: Point | None, transport: str) -> int:
    """Minutes between two places; unknown when either has no position, and then there is no way to count."""
    return travel_minutes(a, b, transport) if a and b else 0


def day_times(stops: list[dict[str, Any]], start: datetime, hotel: Point | None, transport: str) -> list[datetime]:
    """TimeAdjuster.times: each stop starts when the one before ends, plus the way between them."""
    items = [(stop.get("duration_minutes") or 60, _way(_point(stops[i - 1]), _point(stop), transport) if i > 0 else 0)
             for i, stop in enumerate(stops)]
    first = start + timedelta(minutes=_way(hotel, _point(stops[0]), transport)) if hotel and stops else start
    return auto_schedule(items, first)


# MARK: Flights and hotels (TripLogistics.swift)

@dataclass
class DayWindow:
    """What flights and the hotel mean for one day: when it can start, when it has to end, where it starts from."""
    start_minute: int | None = None
    end_minute: int | None = None
    anchor: Point | None = None
    anchor_name: str | None = None
    items: list[dict[str, Any]] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return self.start_minute is None and self.end_minute is None and self.anchor is None and not self.items


def _minute(local: str) -> int:
    return int(local[11:13]) * 60 + int(local[14:16])


def day_window(day: str, bookings: list[dict[str, Any]]) -> DayWindow:
    window = DayWindow()
    for b in bookings:
        kind, start, end = b["kind_raw"], b["start_date"], b["end_date"]
        if kind == "arrivalFlight" and end[:10] == day:
            ready = min(_minute(end) + (b.get("buffer_minutes") or 0), 23 * 60 + 59)
            window.start_minute = max(window.start_minute or 0, ready)
            window.items.append({"text": f"Landung {b['title']} {b.get('place_name', '')}".strip(), "minute": _minute(end)})
        elif kind == "departureFlight" and start[:10] == day:
            leave = max(_minute(start) - (b.get("buffer_minutes") or 0), 0)
            window.end_minute = min(window.end_minute if window.end_minute is not None else 10**6, leave)
            window.items.append({"text": "Weg zum Flughafen", "minute": leave})
            window.items.append({"text": f"Abflug {b['title']}".strip(), "minute": _minute(start)})
        elif kind == "hotel":
            if start[:10] == day:
                window.items.append({"text": f"Check-in · {b['title']}", "minute": _minute(start)})
            if end[:10] == day:
                window.items.append({"text": f"Check-out · {b['title']}", "minute": _minute(end)})
    staying = sorted((b for b in bookings if b["kind_raw"] == "hotel" and b.get("has_coordinate")
                      and b["start_date"][:10] <= day <= b["end_date"][:10]), key=lambda b: b["start_date"], reverse=True)
    if staying:
        window.anchor = (staying[0]["latitude"], staying[0]["longitude"])
        window.anchor_name = staying[0]["title"]
    window.items.sort(key=lambda item: item["minute"])
    return window


def suggested_start(day: str, stops: list[dict[str, Any]], window: DayWindow, transport: str) -> datetime:
    """TimeAdjuster.suggestedStart: where the day is meant to begin. The earliest time already in the day (less the way from the
    hotel), else 9:00, and never before you are ready after landing."""
    start = datetime.fromisoformat(f"{day}T09:00")
    times = [with_date(s["planned_time"], day) for s in stops if s.get("planned_time")]
    if times:
        start = datetime.fromisoformat(min(times))
        if window.anchor and stops:
            start -= timedelta(minutes=_way(window.anchor, _point(stops[0]), transport))
    if window.start_minute is not None and start.hour * 60 + start.minute < window.start_minute:
        start = datetime.fromisoformat(f"{day}T00:00") + timedelta(minutes=window.start_minute)
    return start


# MARK: Bookings as stops (BookingPlanner.swift)

def booking_stops(bookings: list[dict[str, Any]], day_dates: set[str]) -> tuple[list[dict[str, Any]], int]:
    """Flights and hotel check-in/out as stops on the right day and time, and how many were skipped for lacking a position."""
    hotels = [b for b in bookings if b["kind_raw"] == "hotel" and b.get("has_coordinate")]
    out: list[dict[str, Any]] = []
    skipped = 0

    def add(name: str, at: str, source: dict[str, Any], category: str, minutes: int, position: Point | None = None) -> None:
        nonlocal skipped
        if at[:10] not in day_dates:
            return
        if not (source.get("has_coordinate") or position):
            skipped += 1
            return
        lat, lon = position or (source["latitude"], source["longitude"])
        out.append({"name": name, "planned_time": at[:16], "duration_minutes": minutes, "category_raw": category,
                    "address": source.get("address", ""), "latitude": lat, "longitude": lon})

    for b in bookings:
        title = b["title"]
        if b["kind_raw"] == "arrivalFlight":
            add(f"Landung · {title or 'Flug'}", b["end_date"], b, "transport", 30)
        elif b["kind_raw"] == "departureFlight":
            leave = (datetime.fromisoformat(b["start_date"]) - timedelta(minutes=b.get("buffer_minutes") or 0)).strftime("%Y-%m-%dT%H:%M")
            flight_day = b["start_date"][:10]
            stay = next((h for h in hotels if h["start_date"][:10] <= flight_day <= h["end_date"][:10]), None)
            add("Weg zum Flughafen", leave, b, "transport", 15, (stay["latitude"], stay["longitude"]) if stay else None)
            add(f"Flug {title}", b["start_date"], b, "transport", 30)
        elif b["kind_raw"] == "hotel":
            add(f"Check-in · {title}", b["start_date"], b, "hotel", 30)
            add(f"Check-out · {title}", b["end_date"], b, "hotel", 15)
    return out, skipped
