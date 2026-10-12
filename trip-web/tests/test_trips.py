import pytest

from app import planning, service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


def dates(conn, trip):
    return [d["date"] for d in service.get_plan(conn, U, trip)]


def test_wanted_dates_follow_the_app_rules():
    assert planning.wanted_dates("2026-11-01", "2026-11-03") == ["2026-11-01", "2026-11-02", "2026-11-03"]
    assert planning.wanted_dates("2026-11-05", "2026-11-01") == ["2026-11-05"]        # end before start: just the start
    assert len(planning.wanted_dates("2026-01-01", "2030-01-01")) == 120               # capped like the app


def test_a_new_trip_has_a_day_for_every_date_and_its_creator_as_owner(conn):
    trip = service.create_trip(conn, U, "Warschau", "Warschau", "2026-11-01", "2026-11-04", currency_code="PLN", time_zone="Europe/Warsaw")
    assert dates(conn, trip) == ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"]
    assert service.list_trips(conn, U)[0]["currency_code"] == "PLN"
    assert service.list_members(conn, U, trip) == [{"name": "", "role": "owner", "sub": U, "username": ""}]


def test_bad_trip_values_are_explained(conn):
    with pytest.raises(ServiceError, match="Ende liegt vor dem Start"):
        service.create_trip(conn, U, "X", "", "2026-11-05", "2026-11-01")
    with pytest.raises(ServiceError, match="start_date"):
        service.create_trip(conn, U, "X", "", "morgen", "2026-11-01")
    with pytest.raises(ServiceError, match="name"):
        service.create_trip(conn, U, "   ", "", "2026-11-01", "2026-11-02")
    with pytest.raises(ServiceError, match="transport_raw"):
        service.create_trip(conn, U, "X", "", "2026-11-01", "2026-11-02", transport_raw="rakete")


def test_changing_the_dates_adds_days_and_removes_only_empty_ones(conn):
    trip = service.create_trip(conn, U, "Reise", "", "2026-11-01", "2026-11-04")
    day = service.list_items(conn, U, "day", where={"date": "2026-11-04"})["items"][0]["id"]
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Museum"}, "Aaron", "web")
    service.update_trip(conn, U, trip, {"start_date": "2026-11-02", "end_date": "2026-11-03"}, "Aaron", "web")
    # 11-01 was empty and goes; 11-04 still has a stop and stays, even though it is now outside the trip
    assert dates(conn, trip) == ["2026-11-02", "2026-11-03", "2026-11-04"]
    service.update_trip(conn, U, trip, {"end_date": "2026-11-06"}, "Aaron", "web")
    assert dates(conn, trip) == ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]


def test_update_checks_the_combined_dates_and_logs(conn):
    trip = service.create_trip(conn, U, "Reise", "", "2026-11-01", "2026-11-04")
    with pytest.raises(ServiceError, match="Ende liegt vor dem Start"):
        service.update_trip(conn, U, trip, {"start_date": "2026-12-01"}, "Aaron", "web")
    updated = service.update_trip(conn, U, trip, {"name": "Warschau", "budget": 800}, "Aaron", "web")
    assert updated["name"] == "Warschau" and updated["budget"] == 800
    assert service.list_changes(conn, U, trip)[0]["summary"].startswith("Reise geändert: Warschau")


def test_only_owners_delete_and_a_deleted_trip_disappears(conn):
    trip = service.create_trip(conn, U, "Weg", "", "2026-11-01", "2026-11-02")
    conn.execute("INSERT INTO people (sub, name, last_seen) VALUES ('u2','Mama','x')")
    service.set_member(conn, U, trip, "u2", "editor")
    with pytest.raises(ServiceError, match="Besitzer"):
        service.delete_trip(conn, "u2", trip, "Mama", "web")
    service.delete_trip(conn, U, trip, "Aaron", "web")
    assert service.list_trips(conn, U) == []
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.trip_data(conn, U, trip)


def test_an_older_trip_without_days_gets_them_on_migration(tmp_path, monkeypatch):
    from app.config import settings
    path = tmp_path / "trip.db"
    monkeypatch.setattr(settings, "db_path", str(path))
    import sqlite3
    from pathlib import Path
    raw = sqlite3.connect(path)
    raw.executescript((Path(__file__).parent / "fixtures" / "schema_v0.sql").read_text())
    raw.execute("INSERT INTO trips (id, name, start_date, end_date, created_at, updated_at) VALUES ('t1','Japan','2027-07-19','2027-07-22','x','x')")
    raw.commit(); raw.close()
    c = connect()
    init_db(c)
    assert [r["date"] for r in c.execute("SELECT date FROM days ORDER BY date")] == ["2027-07-19", "2027-07-20", "2027-07-21", "2027-07-22"]
    c.close()


# MARK: Phases

def test_a_new_trip_starts_in_planning_and_can_move_to_building_and_back(conn):
    trip = service.create_trip(conn, U, "Japan", "", "2027-07-19", "2027-08-08")
    assert service.list_trips(conn, U)[0]["phase"] == "planning"
    service.update_trip(conn, U, trip, {"phase": "building"}, "Aaron", "web")
    assert service.trip_data(conn, U, trip)["trip"]["phase"] == "building"
    service.update_trip(conn, U, trip, {"phase": "planning"}, "Aaron", "web")
    assert service.trip_data(conn, U, trip)["trip"]["phase"] == "planning"
    with pytest.raises(ServiceError, match="phase"):
        service.update_trip(conn, U, trip, {"phase": "fertig"}, "Aaron", "web")


def test_switching_back_to_planning_keeps_the_stops(conn):
    trip = service.create_trip(conn, U, "Reise", "", "2026-11-01", "2026-11-02", phase="building")
    day = service.get_plan(conn, U, trip)[0]["id"]
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Museum"}, "a", "web", trip)
    service.update_trip(conn, U, trip, {"phase": "planning"}, "a", "web")
    assert service.get_plan(conn, U, trip)[0]["stops"][0]["name"] == "Museum"


def test_an_imported_trip_is_already_being_built(conn):
    from tests.test_archive import WARSAW
    from app import archive
    result = archive.import_archive(conn, U, WARSAW, "Europe/Zurich", "Aaron")[0]
    assert service.trip_data(conn, U, result["trip_id"])["trip"]["phase"] == "building"


def test_migration_puts_idea_only_trips_into_planning(tmp_path, monkeypatch):
    import sqlite3
    from pathlib import Path
    from app.config import settings
    path = tmp_path / "trip.db"
    monkeypatch.setattr(settings, "db_path", str(path))
    raw = sqlite3.connect(path)
    raw.executescript((Path(__file__).parent / "fixtures" / "schema_v0.sql").read_text())
    for tid, name in (("ideas", "Japan"), ("built", "Warschau"), ("empty", "Leer")):
        raw.execute("INSERT INTO trips (id, name, start_date, end_date, created_at, updated_at) VALUES (?,?,'2027-07-19','2027-07-20','x','x')", (tid, name))
    raw.execute("INSERT INTO places (id, trip_id, name, created_at, updated_at) VALUES ('p1','ideas','Asakusa','x','x')")
    raw.execute("INSERT INTO places (id, trip_id, name, created_at, updated_at) VALUES ('p2','built','Altstadt','x','x')")
    raw.execute("INSERT INTO days (id, trip_id, date, created_at, updated_at) VALUES ('d1','built','2027-07-19','x','x')")
    raw.execute("INSERT INTO stops (id, trip_id, day_id, name, created_at, updated_at) VALUES ('s1','built','d1','Markt','x','x')")
    raw.commit(); raw.close()
    c = connect()
    init_db(c)
    phases = {r["name"]: r["phase"] for r in c.execute("SELECT name, phase FROM trips")}
    assert phases == {"Japan": "planning", "Warschau": "building", "Leer": "building"}
    c.close()


def test_trip_data_tells_the_website_what_flights_and_the_hotel_mean_for_each_day(conn):
    trip = service.create_trip(conn, U, "Lissabon", "", "2026-06-05", "2026-06-08", phase="building")
    for kind, title, start, end, extra in (
        ("arrivalFlight", "LH 1234", "2026-06-05T12:00", "2026-06-05T14:30", {"buffer_minutes": 120}),
        ("hotel", "Hotel Sol", "2026-06-05T15:00", "2026-06-08T11:00", {"latitude": 38.72, "longitude": -9.14}),
        ("departureFlight", "LH 1235", "2026-06-08T18:20", "2026-06-08T22:00", {"buffer_minutes": 180}),
    ):
        service.create_item(conn, U, "booking", {"kind_raw": kind, "title": title, "start_date": start, "end_date": end, **extra}, "a", "web", trip)
    windows = service.trip_data(conn, U, trip)["windows"]
    assert windows["2026-06-05"]["start"] == "16:30" and windows["2026-06-05"]["hotel"] == "Hotel Sol"
    assert windows["2026-06-08"]["end"] == "15:20"
    assert [i["time"] for i in windows["2026-06-05"]["items"]] == ["14:30", "15:00"]
    assert windows["2026-06-06"] == {"start": None, "end": None, "hotel": "Hotel Sol", "items": []}
