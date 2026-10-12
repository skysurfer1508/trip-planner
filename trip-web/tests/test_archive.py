import json

import pytest

from app import archive, service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"

# A file in the format the Swift app writes (TripArchive v1, ISO 8601 UTC). The phone was in Europe/Zurich: CET = UTC+1 in November.
WARSAW = {
    "version": 1, "exportedAt": "2026-10-11T16:20:00Z",
    "trips": [{
        "name": "Warschau", "destination": "Warschau", "startDate": "2026-10-31T23:00:00Z", "endDate": "2026-11-02T23:00:00Z",
        "destinationLatitude": 52.2297, "destinationLongitude": 21.0122, "hasDestinationCoordinate": True,
        "budget": 600, "currencyCode": "PLN", "transportRaw": "transit", "countryCode": "PL",
        "days": [
            {"date": "2026-10-31T23:00:00Z", "notes": "Ankunft", "stops": [
                {"name": "Altstadt", "latitude": 52.2497, "longitude": 21.0122, "address": "Rynek", "categoryRaw": "sight",
                 "plannedTime": "2026-11-01T08:30:00Z", "durationMinutes": 90, "notes": "Marktplatz", "order": 0, "isDone": False,
                 "estimatedCost": 0, "phone": "", "website": "https://example.org/altstadt", "aiTips": "cache", "openingHours": "Mo-Su 00:00-24:00",
                 "summary": "x", "wikiURL": "y"},
                {"name": "Pierogi", "latitude": 52.24, "longitude": 21.02, "address": "", "categoryRaw": "food",
                 "plannedTime": "2026-11-01T11:00:00Z", "durationMinutes": 60, "notes": "", "order": 1, "isDone": True,
                 "estimatedCost": 20, "phone": "", "website": "javascript:alert(1)", "aiTips": ""},
            ]},
            {"date": "2026-11-01T23:00:00Z", "notes": "", "stops": [
                {"name": "Unbekannte Art", "latitude": 0, "longitude": 0, "address": "", "categoryRaw": "ufo", "plannedTime": None,
                 "durationMinutes": 60, "notes": "", "order": 0, "isDone": False, "estimatedCost": 0, "phone": "", "website": "", "aiTips": ""},
            ]},
        ],
        "expenses": [{"title": "Taxi", "amount": 35.5, "currencyCode": "PLN", "categoryRaw": "transport", "date": "2026-11-01T09:00:00Z"}],
        "checklist": [{"title": "Reisepass", "section": "Dokumente", "isDone": True, "order": 0}],
        "savedPlaces": [{"name": "Schloss", "latitude": 52.2479, "longitude": 21.0153, "address": "Plac Zamkowy", "categoryRaw": "sight",
                         "savedAt": "2026-10-01T10:00:00Z"}],
        "documents": [{"title": "Ticket", "fileName": "t.pdf", "kindRaw": "ticket", "note": "", "addedAt": "2026-10-01T10:00:00Z", "data": "AAAA"}],
        "bookings": [{"kindRaw": "hotel", "title": "Hotel Bristol", "startDate": "2026-11-01T13:00:00Z", "endDate": "2026-11-04T10:00:00Z",
                      "placeName": "Bristol", "otherEnd": "", "address": "Krakowskie", "latitude": 52.24, "longitude": 21.01,
                      "hasCoordinate": True, "reference": "ABC123", "notes": "", "bufferMinutes": 0, "remind": False}],
    }],
}


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


def test_times_become_local_wall_clock_in_the_chosen_zone(conn):
    result = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]
    assert (result["stops"], result["expenses"], result["bookings"], result["checklist"], result["places"]) == (3, 1, 1, 1, 1)
    plan = service.get_plan(conn, U, result["trip_id"])
    assert [d["date"] for d in plan] == ["2026-11-01", "2026-11-02", "2026-11-03"]
    assert [(s["name"], s["planned_time"]) for s in plan[0]["stops"]] == [("Altstadt", "2026-11-01T09:30"), ("Pierogi", "2026-11-01T12:00")]
    assert plan[0]["notes"] == "Ankunft"
    booking = service.list_items(conn, U, "booking", result["trip_id"])["items"][0]
    assert booking["start_date"] == "2026-11-01T14:00" and booking["has_coordinate"] is True


def test_another_zone_gives_other_times(conn):
    result = archive.import_archive(conn, U, WARSAW, "Asia/Tokyo", "Aaron")[0]  # +9: the same moments, different wall clock
    plan = service.get_plan(conn, U, result["trip_id"])
    assert plan[0]["date"] == "2026-11-01" and plan[0]["stops"][0]["planned_time"] == "2026-11-01T17:30"


def test_the_importer_becomes_owner_and_the_history_has_one_entry(conn):
    result = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]
    assert service.list_members(conn, U, result["trip_id"])[0]["role"] == "owner"
    log = service.list_changes(conn, U, result["trip_id"])
    assert len(log) == 1 and log[0]["via"] == "import" and "3 Stopps" in log[0]["summary"]


def test_caches_documents_and_bad_values_are_handled(conn):
    result = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]
    stops = {s["name"]: s for s in service.list_items(conn, U, "stop", result["trip_id"])["items"]}
    assert "website" not in stops["Pierogi"]                      # javascript: link dropped, not refused
    assert stops["Unbekannte Art"]["category_raw"] == "other"      # unknown category falls back
    assert not stops["Unbekannte Art"].get("latitude")             # 0/0 means "no coordinate"
    assert stops["Altstadt"]["opening_hours"] == "Mo-Su 00:00-24:00"
    assert archive.preview(WARSAW, "Europe/Zurich")["trips"][0]["documents_skipped"] == 1


def test_trip_details_and_wishes_come_across(conn):
    result = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]
    trip = service.list_trips(conn, U)[0]
    assert (trip["currency_code"], trip["budget"], trip["transport_raw"], trip["country_code"]) == ("PLN", 600, "transit", "PL")
    assert trip["has_destination_coordinate"] == 1
    place = service.list_items(conn, U, "place", result["trip_id"])["items"][0]
    assert place["name"] == "Schloss" and place["description"] == "Plac Zamkowy" and place["has_coordinate"] is True


def test_preview_shows_converted_times_without_creating_anything(conn):
    shown = archive.preview(WARSAW, "Europe/Zurich")
    assert shown["trips"][0]["sample"][0] == {"date": "2026-11-01", "time": "09:30", "name": "Altstadt"}
    assert service.list_trips(conn, U) == []


@pytest.mark.parametrize("bad", [None, [], {"trips": "x"}, {"version": 1}, {"version": 0, "trips": []}, {"version": "1", "trips": []}])
def test_files_that_are_not_archives_are_refused(conn, bad):
    with pytest.raises(ServiceError, match="keine Trip-Planner-Datei"):
        archive.import_archive(conn, U, bad, "Europe/Zurich", "Aaron")


def test_a_newer_file_version_and_an_unknown_zone_are_refused(conn):
    with pytest.raises(ServiceError, match="neueren Version"):
        archive.import_archive(conn, U, {"version": 2, "trips": []}, "Europe/Zurich", "Aaron")
    with pytest.raises(ServiceError, match="Zeitzone"):
        archive.import_archive(conn, U, WARSAW, "Mars/Olympus", "Aaron")


def test_a_broken_trip_creates_nothing(conn):
    broken = json.loads(json.dumps(WARSAW))
    broken["trips"].append({"name": "Kaputt", "startDate": "kein Datum", "endDate": "x"})
    with pytest.raises(ServiceError, match="nicht lesen"):
        archive.import_archive(conn, U, broken, "Europe/Zurich", "Aaron")
    assert service.list_trips(conn, U) == []


def test_export_and_import_again_gives_the_same_plan(conn):
    first = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]["trip_id"]
    exported = archive.export_archive(conn, U, first, "Europe/Zurich")
    assert exported["version"] == 1 and exported["trips"][0]["days"][0]["stops"][0]["plannedTime"] == "2026-11-01T08:30:00Z"
    again = archive.import_archive(conn, U, exported, "Europe/Zurich", "Aaron")[0]["trip_id"]
    def shape(trip):
        return [(d["date"], [(s["name"], s.get("planned_time")) for s in d["stops"]]) for d in service.get_plan(conn, U, trip)]
    assert shape(first) == shape(again)
    assert service.list_items(conn, U, "booking", again)["items"][0]["start_date"] == "2026-11-01T14:00"


def test_the_export_has_every_key_the_swift_decoder_requires(conn):
    """TripArchive.decode uses `try?`, so a missing non-optional key would make the app say the file is damaged."""
    trip_id = service.create_trip(conn, U, "Leer", "", "2026-12-01", "2026-12-01")
    dto = archive.export_archive(conn, U, trip_id, "Europe/Zurich")["trips"][0]
    for key in ("name", "destination", "startDate", "endDate", "destinationLatitude", "destinationLongitude", "hasDestinationCoordinate",
                "budget", "currencyCode", "days", "expenses", "checklist", "savedPlaces", "documents"):
        assert key in dto, key
    day = {"date": 1, "notes": 1, "stops": 1}
    assert set(day) <= set(dto["days"][0])
    service.create_item(conn, U, "stop", {"day_id": service.get_plan(conn, U, trip_id)[0]["id"], "name": "X"}, "a", "web", trip_id)
    stop = archive.export_archive(conn, U, trip_id, "Europe/Zurich")["trips"][0]["days"][0]["stops"][0]
    for key in ("name", "latitude", "longitude", "address", "categoryRaw", "durationMinutes", "notes", "order", "isDone",
                "estimatedCost", "phone", "website", "aiTips"):
        assert key in stop, key
