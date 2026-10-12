import pytest

from app import service, sync
from app.db import connect, init_db
from app.service import ServiceError

U, V = "u1", "u2"


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    service.touch_person(c, V, "Mia")
    yield c
    c.close()


def f(**values):
    """Fields as the app sends them for a new item: no starting value."""
    return {k: {"base": None, "new": v} for k, v in values.items()}


def change(**values):
    """Fields the app changed: (base, new) pairs."""
    return {k: {"base": b, "new": n} for k, (b, n) in values.items()}


@pytest.fixture()
def trip(conn):
    trip_id = service.create_trip(conn, U, "Warschau", "Polen", "2026-11-05", "2026-11-08", phase="building", currency_code="PLN")
    return trip_id


def by_kind(result, kind):
    return [c for c in result["changes"] if c["kind"] == kind]


def test_a_trip_made_in_the_app_is_uploaded_with_the_apps_own_ids(conn):
    snapshot = {
        "trip": {"name": "Wien", "destination": "Österreich", "start_date": "2026-12-01", "end_date": "2026-12-03", "currency_code": "EUR"},
        "days": [{"date": "2026-12-01", "notes": "Anreise"}],
        "stops": [{"id": "A-1", "fields": dict(name="Stephansdom", day="2026-12-01", planned_time="2026-12-01T10:00", sort_order=0, latitude=48.2, longitude=16.37)}],
        "expenses": [{"id": "A-2", "fields": dict(title="Kaffee", amount=4.5, currency_code="EUR", date="2026-12-01", category_raw="food")}],
        "checklist": [{"id": "A-3", "fields": dict(title="Pass", is_done=True, sort_order=0)}],
        "bookings": [{"id": "A-4", "fields": dict(kind_raw="hotel", title="Hotel", start_date="2026-12-01T15:00", end_date="2026-12-03T11:00")}],
    }
    result = sync.create_from_app(conn, U, snapshot, "Aaron")
    data = service.trip_data(conn, U, result["trip_id"])
    assert data["trip"]["phase"] == "building"
    assert [s["id"] for s in data["stops"]] == ["A-1"] and data["stops"][0]["planned_time"] == "2026-12-01T10:00"
    assert data["days"][0]["notes"] == "Anreise" or any(d["notes"] == "Anreise" for d in data["days"])
    assert data["expenses"][0]["id"] == "A-2" and data["checklist"][0]["is_done"] is True and data["bookings"][0]["id"] == "A-4"
    assert result["counts"]["created"] == 4


def test_a_new_stop_from_the_app_arrives_and_the_server_sends_its_changes_back(conn, trip):
    first = sync.push(conn, U, trip, 0, [], "Aaron")
    assert by_kind(first, "trip")[0]["fields"]["name"] == "Warschau" and len(by_kind(first, "day")) == 4
    result = sync.push(conn, U, trip, first["revision"], [{"kind": "stop", "id": "S1", "op": "upsert", "fields": f(name="Altstadt", day="2026-11-06", sort_order=0)}], "Aaron")
    assert result["counts"]["created"] == 1 and result["conflicts"] == []
    # the website adds another stop; the app learns about it on the next round
    day = next(d for d in service.trip_data(conn, U, trip)["days"] if d["date"] == "2026-11-06")
    service.create_item(conn, U, "stop", {"day_id": day["id"], "name": "Schloss"}, "Aaron", "web", trip)
    later = sync.push(conn, U, trip, result["revision"], [], "Aaron")
    assert [c["fields"]["name"] for c in by_kind(later, "stop")] == ["Schloss"]
    assert by_kind(later, "stop")[0]["fields"]["day"] == "2026-11-06"


def test_the_same_field_changed_on_both_sides_keeps_the_servers_value(conn, trip):
    created = sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S1", "op": "upsert", "fields": f(name="Altstadt", day="2026-11-06", sort_order=0, notes="alt")}], "Aaron")
    service.update_item(conn, U, "stop", "S1", {"notes": "von der Website"}, "Aaron", "web")
    result = sync.push(conn, U, trip, created["revision"] - 1, [
        {"kind": "stop", "id": "S1", "op": "upsert", "fields": change(notes=("alt", "vom Handy"), name=("Altstadt", "Alte Stadt"))}], "Aaron")
    assert [c["field"] for c in result["conflicts"]] == ["notes"]
    row = conn.execute("SELECT name, notes FROM stops WHERE id = 'S1'").fetchone()
    assert row["notes"] == "von der Website" and row["name"] == "Alte Stadt"      # the other field still goes through


def test_different_fields_changed_on_both_sides_are_both_kept(conn, trip):
    sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S1", "op": "upsert", "fields": f(name="Altstadt", day="2026-11-06", sort_order=0)}], "Aaron")
    service.update_item(conn, U, "stop", "S1", {"address": "Rynek"}, "Aaron", "web")
    result = sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S1", "op": "upsert", "fields": change(duration_minutes=(60, 90))}], "Aaron")
    assert result["conflicts"] == []
    row = conn.execute("SELECT address, duration_minutes FROM stops WHERE id = 'S1'").fetchone()
    assert row["address"] == "Rynek" and row["duration_minutes"] == 90


def test_a_stop_moved_to_another_day_and_stops_are_renumbered(conn, trip):
    sync.push(conn, U, trip, 0, [
        {"kind": "stop", "id": "A", "op": "upsert", "fields": f(name="A", day="2026-11-06", sort_order=0)},
        {"kind": "stop", "id": "B", "op": "upsert", "fields": f(name="B", day="2026-11-06", sort_order=1)},
        {"kind": "stop", "id": "C", "op": "upsert", "fields": f(name="C", day="2026-11-06", sort_order=2)}], "Aaron")
    sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "B", "op": "upsert", "fields": change(day=("2026-11-06", "2026-11-07"), sort_order=(1, 0))}], "Aaron")
    rows = conn.execute("SELECT s.id, s.sort_order, d.date FROM stops s JOIN days d ON d.id = s.day_id WHERE s.deleted_at IS NULL ORDER BY d.date, s.sort_order").fetchall()
    assert [(r["id"], r["date"], r["sort_order"]) for r in rows] == [("A", "2026-11-06", 0), ("C", "2026-11-06", 1), ("B", "2026-11-07", 0)]


def test_deleting_works_but_not_over_a_newer_change_on_the_server(conn, trip):
    first = sync.push(conn, U, trip, 0, [
        {"kind": "stop", "id": "A", "op": "upsert", "fields": f(name="A", day="2026-11-06", sort_order=0)},
        {"kind": "stop", "id": "B", "op": "upsert", "fields": f(name="B", day="2026-11-06", sort_order=1)}], "Aaron")
    service.update_item(conn, U, "stop", "B", {"notes": "wichtig"}, "Aaron", "web")
    result = sync.push(conn, U, trip, first["revision"], [{"kind": "stop", "id": "A", "op": "delete"}, {"kind": "stop", "id": "B", "op": "delete"}], "Aaron")
    assert result["counts"]["deleted"] == 1 and [c["id"] for c in result["conflicts"]] == ["B"]
    assert conn.execute("SELECT deleted_at FROM stops WHERE id = 'B'").fetchone()["deleted_at"] is None


def test_deletions_on_the_server_reach_the_app_but_not_a_first_download(conn, trip):
    first = sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "A", "op": "upsert", "fields": f(name="A", day="2026-11-06", sort_order=0)}], "Aaron")
    service.remove_item(conn, U, "stop", "A", "Aaron", "web")
    later = sync.push(conn, U, trip, first["revision"], [], "Aaron")
    assert by_kind(later, "stop") == [{"kind": "stop", "id": "A", "deleted": True}]
    assert by_kind(sync.push(conn, U, trip, 0, [], "Aaron"), "stop") == []


def test_trip_fields_and_day_notes_sync_and_dates_add_days(conn, trip):
    result = sync.push(conn, U, trip, 0, [
        {"kind": "trip", "id": trip, "fields": change(budget=(0, 800), end_date=("2026-11-08", "2026-11-10"))},
        {"kind": "day", "id": "2026-11-09", "fields": change(notes=("", "Rückreise vorbereiten"))}], "Aaron")
    data = service.trip_data(conn, U, trip)
    assert data["trip"]["budget"] == 800 and data["trip"]["end_date"] == "2026-11-10"
    assert next(d for d in data["days"] if d["date"] == "2026-11-09")["notes"] == "Rückreise vorbereiten"
    assert result["conflicts"] == []


def test_strangers_and_viewers_and_planning_trips_are_refused(conn, trip):
    with pytest.raises(ServiceError):
        sync.push(conn, "stranger", trip, 0, [], "X")
    service.set_member(conn, U, trip, V, "viewer")
    sync.push(conn, V, trip, 0, [], "Mia")                       # reading is fine
    with pytest.raises(ServiceError):
        sync.push(conn, V, trip, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": f(name="x", day="2026-11-06")}], "Mia")
    planning = service.create_trip(conn, U, "Japan", "Japan", "2027-07-19", "2027-08-08")
    with pytest.raises(ServiceError, match="Planungsphase"):
        sync.push(conn, U, planning, 0, [], "Aaron")


def test_bad_input_is_refused_without_half_applying(conn, trip):
    with pytest.raises(ServiceError):
        sync.push(conn, U, trip, 0, [
            {"kind": "stop", "id": "OK", "op": "upsert", "fields": f(name="Gut", day="2026-11-06")},
            {"kind": "stop", "id": "BAD", "op": "upsert", "fields": f(name="Schlecht")}], "Aaron")      # no day
    assert conn.execute("SELECT COUNT(*) FROM stops").fetchone()[0] == 0
    with pytest.raises(ServiceError):
        sync.push(conn, U, trip, 0, [{"kind": "ufo", "id": "x"}], "Aaron")


def test_an_id_of_another_trip_is_not_taken_over(conn, trip):
    other = service.create_trip(conn, U, "Anders", "", "2026-01-01", "2026-01-02", phase="building")
    sync.push(conn, U, other, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": f(name="x", day="2026-01-01")}], "Aaron")
    with pytest.raises(ServiceError):
        sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": change(name=("x", "y"))}], "Aaron")


def test_the_history_says_the_app_did_it_and_cannot_undo_the_whole_sync(conn, trip):
    sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": f(name="x", day="2026-11-06")}], "Aaron")
    entry = service.list_changes(conn, U, trip, 5)[0]
    assert entry["via"] == "app" and "Abgleich mit der App" in entry["summary"]
    with pytest.raises(ServiceError):
        service.undo_change(conn, U, entry["id"], "Aaron", "web")


def test_an_old_database_gets_the_new_history_check(tmp_path, monkeypatch):
    import sqlite3
    from app.config import settings
    path = tmp_path / "t.db"
    monkeypatch.setattr(settings, "db_path", str(path))
    c = connect()
    init_db(c)
    tid = service.create_trip(c, U, "A", "", "2026-01-01", "2026-01-02")
    service.create_item(c, U, "place", {"name": "x"}, "Aaron", "web", tid)
    c.execute("PRAGMA user_version = 6")
    c.execute("ALTER TABLE change_log RENAME TO tmp")
    c.execute("CREATE TABLE change_log (id TEXT PRIMARY KEY, trip_id TEXT NOT NULL, table_name TEXT NOT NULL, row_id TEXT NOT NULL, action TEXT NOT NULL, actor TEXT NOT NULL DEFAULT '', via TEXT NOT NULL CHECK (via IN ('web','claude','import')), summary TEXT NOT NULL DEFAULT '', before_json TEXT, after_json TEXT, undone_at TEXT, created_at TEXT NOT NULL)")
    c.execute("INSERT INTO change_log SELECT * FROM tmp")
    c.execute("DROP TABLE tmp")
    before = c.execute("SELECT COUNT(*) FROM change_log").fetchone()[0]
    c.commit()
    c.close()
    c = connect()
    init_db(c)
    assert c.execute("SELECT COUNT(*) FROM change_log").fetchone()[0] == before > 0
    c.execute("INSERT INTO change_log (id, trip_id, table_name, row_id, action, via, created_at) SELECT 'x', id, 't', 'r', 'update', 'app', 'now' FROM trips")
    c.close()


def test_a_planned_time_can_be_cleared(conn, trip):
    sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": f(name="x", day="2026-11-06", planned_time="2026-11-06T10:00")}], "Aaron")
    assert conn.execute("SELECT planned_time FROM stops WHERE id = 'S'").fetchone()[0] == "2026-11-06T10:00"
    sync.push(conn, U, trip, 0, [{"kind": "stop", "id": "S", "op": "upsert", "fields": change(planned_time=("2026-11-06T10:00", None))}], "Aaron")
    assert conn.execute("SELECT planned_time FROM stops WHERE id = 'S'").fetchone()[0] is None
