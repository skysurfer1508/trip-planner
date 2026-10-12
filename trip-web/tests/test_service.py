import pytest

from app import service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"


def day_of(conn, date):
    """The day row that exists for a date of the trip (days are made from the trip dates)."""
    return service.list_items(conn, U, "day", where={"date": date})["items"][0]["id"]


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    return service.create_trip(conn, U, "Japan 2027", "Japan", "2027-07-19", "2027-08-08", time_zone="Asia/Tokyo")


def test_create_and_list_place(conn, trip):
    made = service.create_item(conn, U, "place", {"name": "Asakusa", "region": "Tokyo", "prio": "Muss",
                                               "latitude": 35.7148, "longitude": 139.7967}, "Mama", "claude")
    assert made["item"]["name"] == "Asakusa"
    assert made["item"]["has_coordinate"] is True
    listed = service.list_items(conn, U, "place")
    assert listed["count"] == 1
    assert listed["items"][0]["decision"] == "Offen"


def test_unknown_field_is_rejected_with_the_allowed_fields(conn, trip):
    with pytest.raises(ServiceError) as error:
        service.create_item(conn, U, "place", {"name": "X", "prioritaet": "Muss"}, "Mama", "claude")
    assert "prioritaet" in str(error.value) and "prio" in str(error.value)


def test_bad_values_are_explained(conn, trip):
    with pytest.raises(ServiceError) as error:
        service.create_item(conn, U, "place", {"name": "X", "prio": "Vielleicht", "website": "javascript:alert(1)"}, "Mama", "claude")
    message = str(error.value)
    assert "prio" in message and "website" in message


def test_required_fields(conn, trip):
    with pytest.raises(ServiceError, match="Pflichtfelder"):
        service.create_item(conn, U, "decision", {"title": "Route"}, "Mama", "claude")


def test_times_must_be_local_without_zone(conn, trip):
    day = day_of(conn, "2027-07-20")
    with pytest.raises(ServiceError, match="Ortszeit"):
        service.create_item(conn, U, "stop", {"day_id": day, "name": "Senso-ji", "planned_time": "2027-07-20T09:30:00+09:00"}, "Mama", "claude")
    stop = service.create_item(conn, U, "stop", {"day_id": day, "name": "Senso-ji", "planned_time": "2027-07-20T09:30:00"}, "Mama", "claude")
    assert stop["item"]["planned_time"] == "2027-07-20T09:30"


def test_stop_must_reference_a_day_of_the_same_trip(conn, trip):
    other = service.create_trip(conn, U, "Andere", "", "2028-01-01", "2028-01-05")
    foreign_day = service.list_items(conn, U, "day", trip_id=other, where={"date": "2028-01-02"})["items"][0]["id"]
    with pytest.raises(ServiceError, match="day_id"):
        service.create_item(conn, U, "stop", {"day_id": foreign_day, "name": "Y"}, "x", "web", trip_id=trip)


def test_update_logs_and_undo_restores(conn, trip):
    place = service.create_item(conn, U, "place", {"name": "Kamakura", "decision": "Offen"}, "Mama", "claude")["id"]
    changed = service.update_item(conn, U, "place", place, {"decision": "Ja", "notes": "Zug ab Tokyo"}, "Papa", "claude")
    assert changed["item"]["decision"] == "Ja"
    log = service.list_changes(conn, U)
    assert log[0]["actor"] == "Papa" and log[0]["via"] == "claude" and "decision" in log[0]["summary"]

    service.undo_change(conn, U, changed["change_id"], "Papa", "claude")
    restored = service.list_items(conn, U, "place", where={"id": place})["items"][0]
    assert restored["decision"] == "Offen"
    assert "notes" not in restored
    with pytest.raises(ServiceError, match="schon rückgängig"):
        service.undo_change(conn, U, changed["change_id"], "Papa", "claude")


def test_remove_hides_and_undo_brings_back(conn, trip):
    place = service.create_item(conn, U, "place", {"name": "Okinawa"}, "Mama", "claude")["id"]
    removed = service.remove_item(conn, U, "place", place, "Mama", "claude")
    assert service.list_items(conn, U, "place")["count"] == 0
    service.undo_change(conn, U, removed["change_id"], "Mama", "claude")
    assert service.list_items(conn, U, "place")["count"] == 1


def test_undo_of_an_insert_hides_the_item(conn, trip):
    made = service.create_item(conn, U, "place", {"name": "Versehen"}, "Mama", "claude")
    service.undo_change(conn, U, made["change_id"], "Mama", "claude")
    assert service.list_items(conn, U, "place")["count"] == 0


def test_booleans_round_trip_through_undo(conn, trip):
    item = service.create_item(conn, U, "checklist_item", {"title": "Reisepass", "is_done": False}, "Mama", "web")["id"]
    ticked = service.update_item(conn, U, "checklist_item", item, {"is_done": True}, "Mama", "web")
    assert ticked["item"]["is_done"] is True
    service.undo_change(conn, U, ticked["change_id"], "Mama", "web")
    assert service.list_items(conn, U, "checklist_item")["items"][0]["is_done"] is False


def test_where_filter_only_allows_known_columns(conn, trip):
    with pytest.raises(ServiceError, match="Filter"):
        service.list_items(conn, U, "place", where={"sqlite_master; --": "x"})


def test_several_trips_need_an_id(conn, trip):
    service.create_trip(conn, U, "Zweite", "", "2028-01-01", "2028-01-05")
    with pytest.raises(ServiceError, match="trip_id"):
        service.list_items(conn, U, "place")
    assert service.list_items(conn, U, "place", trip_id=trip)["count"] == 0


def test_plan_orders_stops_inside_days(conn, trip):
    day = day_of(conn, "2027-07-20")
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Zweiter", "sort_order": 2}, "x", "web")
    service.create_item(conn, U, "stop", {"day_id": day, "name": "Erster", "sort_order": 1}, "x", "web")
    plan = service.get_plan(conn, U)
    assert [s["name"] for s in next(d for d in plan if d["date"] == "2027-07-20")["stops"]] == ["Erster", "Zweiter"]


def test_revision_grows_on_every_change(conn, trip):
    before = service.revision(conn)
    service.create_item(conn, U, "place", {"name": "A"}, "x", "web")
    assert service.revision(conn) == before + 1


def test_actor_matches_known_person_case_insensitively(conn, trip):
    service.touch_person(conn, U, "Mama", "mama@example.org")
    assert service.resolve_actor(conn, U, " mama ") == "Mama"
    assert service.resolve_actor(conn, U, "Onkel Tom") == "Onkel Tom"
    with pytest.raises(ServiceError, match="acting_member"):
        service.resolve_actor(conn, U, "  ")


def test_trip_data_has_everything_for_the_website(conn, trip):
    service.create_item(conn, U, "place", {"name": "A", "prio": "Muss"}, "x", "web")
    service.create_item(conn, U, "decision", {"kind": "open", "title": "Route"}, "x", "web")
    data = service.trip_data(conn, U, trip)
    assert data["trip"]["name"] == "Japan 2027"
    assert len(data["places"]) == 1 and len(data["decisions"]) == 1
    assert data["places"][0]["id"] and data["revision"] > 0
