import hashlib

import pytest

from app import exports, service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def data(conn):
    trip = service.create_trip(conn, U, "Warschau", "Polen", "2026-11-01", "2026-11-02", phase="building")
    day = service.get_plan(conn, U, trip)[0]["id"]
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Altstadt, Rynek", "address": "Rynek 1; Warschau", "planned_time": "2026-11-01T09:30",
                                          "duration_minutes": 90, "notes": "Marktplatz\nfrüh hin", "latitude": 52.2497, "longitude": 21.0122,
                                          "website": "https://example.org"}, "a", "web", trip)
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Ohne Zeit"}, "a", "web", trip)
    service.create_item(conn, U, "booking", {"kind_raw": "hotel", "title": "Bristol", "start_date": "2026-11-01T15:00", "end_date": "2026-11-02T11:00",
                                              "latitude": 52.24, "longitude": 21.01}, "a", "web", trip)
    return service.trip_data(conn, U, trip)


def test_the_text_lists_days_stops_and_the_hotel(data):
    text = exports.plan_text(data)
    assert text.splitlines()[:3] == ["Warschau", "Polen", "1. November 2026 bis 2. November 2026"]
    assert "Tag 1 · Sonntag, 1. November 2026" in text and "   Start im Hotel: Bristol" in text
    assert "• 09:30 Altstadt, Rynek (Rynek 1; Warschau)" in text and "   Marktplatz\nfrüh hin" in text.replace("\n   ", "\n   ")
    assert "• Ohne Zeit" in text and "Tag 2 · Montag, 2. November 2026" in text and "   (nichts geplant)" in text


def test_ics_escapes_folds_and_uses_the_destination_clock(data):
    body = exports.ics(data, "Europe/Warsaw", now=__import__("datetime").datetime(2026, 10, 1, 12, 0, tzinfo=__import__("datetime").timezone.utc))
    assert body.startswith("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n") and body.endswith("END:VCALENDAR\r\n")
    assert "DTSTART:20261101T083000Z" in body and "DTEND:20261101T100000Z" in body        # 09:30 in Warsaw (UTC+1) is 08:30 UTC
    assert "SUMMARY:Altstadt\\, Rynek" in body and "LOCATION:Rynek 1\\; Warschau" in body
    assert "GEO:52.2497;21.0122" in body and "URL:https://example.org" in body
    assert "TRIGGER:-PT30M" in body and "TRIGGER:-PT60M" in body                          # stops 30 minutes ahead, flights and hotel an hour
    assert "SUMMARY:Check-in · Bristol" in body and "DTSTART:20261101T140000Z" in body
    assert "Ohne Zeit" not in body                                                        # no time, no event
    assert all(len(line.encode()) <= 75 for line in body.split("\r\n"))


def test_event_ids_are_stable_so_a_second_import_updates():
    assert exports.uid("a") == hashlib.sha256(b"a").digest()[:16].hex() + "@tripplanner"
    assert exports.uid("a") == exports.uid("a") != exports.uid("b")


def test_long_lines_fold_at_75_bytes_without_splitting_characters():
    parts = exports.fold("DESCRIPTION:" + "ä" * 100)
    assert all(len(p.encode()) <= 75 for p in parts) and parts[1].startswith(" ")
    assert "".join([parts[0]] + [p[1:] for p in parts[1:]]) == "DESCRIPTION:" + "ä" * 100


def test_nothing_to_export_is_said_plainly(conn):
    trip = service.create_trip(conn, U, "Leer", "", "2026-11-01", "2026-11-01")
    with pytest.raises(ServiceError, match="nichts mit Uhrzeit"):
        exports.ics(service.trip_data(conn, U, trip), "Europe/Zurich")
    with pytest.raises(ServiceError, match="Zeitzone"):
        exports.ics(service.trip_data(conn, U, trip), "Mars/Base")
