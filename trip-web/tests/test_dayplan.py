import pytest

from app import dayplan, service
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
def trip(conn):
    return service.create_trip(conn, U, "Warschau", "Warschau", "2026-11-01", "2026-11-03", phase="building", transport_raw="walking")


def day_id(conn, date):
    return service.list_items(conn, U, "day", where={"date": date})["items"][0]["id"]


def add(conn, date, name, **fields):
    return service.create_item(conn, U, "stop", {"day_id": day_id(conn, date), "name": name, **fields}, "Aaron", "web")["id"]


def names(conn, date):
    plan = {d["date"]: d for d in service.get_plan(conn, U)}
    return [s["name"] for s in plan[date]["stops"]]


def stop(conn, stop_id):
    return service.list_items(conn, U, "stop", where={"id": stop_id})["items"][0]


def test_new_stops_go_to_the_end_of_the_day(conn, trip):
    add(conn, "2026-11-01", "A"); add(conn, "2026-11-01", "B"); add(conn, "2026-11-01", "C")
    assert names(conn, "2026-11-01") == ["A", "B", "C"]


def test_move_within_a_day_and_undo(conn, trip):
    a, b, c = (add(conn, "2026-11-01", n) for n in "ABC")
    result = dayplan.move_stop(conn, U, a, "Aaron", "web", index=2)
    assert names(conn, "2026-11-01") == ["B", "C", "A"]
    service.undo_change(conn, U, result["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-01") == ["A", "B", "C"]


def test_move_to_another_day_keeps_the_time_of_day_and_closes_the_gap(conn, trip):
    a = add(conn, "2026-11-01", "A", planned_time="2026-11-01T09:30")
    add(conn, "2026-11-01", "B"); add(conn, "2026-11-02", "X")
    result = dayplan.move_stop(conn, U, a, "Aaron", "web", day_id=day_id(conn, "2026-11-02"))
    assert names(conn, "2026-11-01") == ["B"] and names(conn, "2026-11-02") == ["X", "A"]
    assert stop(conn, a)["planned_time"] == "2026-11-02T09:30"
    assert [s["sort_order"] for d in service.get_plan(conn, U) for s in d["stops"]] == [0, 0, 1]
    service.undo_change(conn, U, result["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-01") == ["A", "B"] and stop(conn, a)["planned_time"] == "2026-11-01T09:30"


def test_move_to_a_position_on_another_day(conn, trip):
    a = add(conn, "2026-11-01", "A")
    add(conn, "2026-11-02", "X"); add(conn, "2026-11-02", "Y")
    dayplan.move_stop(conn, U, a, "Aaron", "web", index=1, day_id=day_id(conn, "2026-11-02"))
    assert names(conn, "2026-11-02") == ["X", "A", "Y"]


def test_duplicate_puts_the_copy_right_after_and_is_not_done(conn, trip):
    a = add(conn, "2026-11-01", "A", is_done=True, estimated_cost=12)
    add(conn, "2026-11-01", "B")
    result = dayplan.duplicate_stop(conn, U, a, "Aaron", "web")
    assert names(conn, "2026-11-01") == ["A", "A", "B"]
    copy = service.get_plan(conn, U)[0]["stops"][1]
    assert copy["estimated_cost"] == 12 and copy["is_done"] is False and copy["id"] != a
    service.undo_change(conn, U, result["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-01") == ["A", "B"]


def test_copy_day_appends_copies_moves_times_and_resets_done(conn, trip):
    add(conn, "2026-11-01", "A", planned_time="2026-11-01T10:00", is_done=True)
    add(conn, "2026-11-01", "B")
    add(conn, "2026-11-03", "Schon da")
    result = dayplan.copy_day(conn, U, day_id(conn, "2026-11-01"), day_id(conn, "2026-11-03"), "Aaron", "web")
    assert result["copied"] == 2 and names(conn, "2026-11-03") == ["Schon da", "A", "B"]
    copied = service.get_plan(conn, U)[2]["stops"][1]
    assert copied["planned_time"] == "2026-11-03T10:00" and copied["is_done"] is False
    assert names(conn, "2026-11-01") == ["A", "B"]                        # the source is untouched
    service.undo_change(conn, U, result["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-03") == ["Schon da"]
    with pytest.raises(ServiceError, match="anderen Tag"):
        dayplan.copy_day(conn, U, day_id(conn, "2026-11-01"), day_id(conn, "2026-11-01"), "Aaron", "web")


def test_sort_by_time(conn, trip):
    add(conn, "2026-11-01", "Spät", planned_time="2026-11-01T15:00")
    add(conn, "2026-11-01", "Ohne")
    add(conn, "2026-11-01", "Früh", planned_time="2026-11-01T09:00")
    dayplan.sort_day_by_time(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")
    assert names(conn, "2026-11-01") == ["Früh", "Spät", "Ohne"]


def test_optimize_orders_stops_along_a_line_and_undo_restores(conn, trip):
    for name, lat in (("Start", 0.0), ("Nord", 0.3), ("Mitte", 0.1), ("Oben", 0.2)):
        add(conn, "2026-11-01", name, latitude=lat, longitude=10.0)
    result = dayplan.optimize_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")
    assert result["changed"] and names(conn, "2026-11-01") == ["Start", "Mitte", "Oben", "Nord"]
    service.undo_change(conn, U, result["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-01") == ["Start", "Nord", "Mitte", "Oben"]


def test_optimize_starts_from_the_hotel_without_making_it_a_stop(conn, trip):
    service.create_item(conn, U, "booking", {"kind_raw": "hotel", "title": "Hotel", "start_date": "2026-11-01T15:00",
                                              "end_date": "2026-11-03T11:00", "latitude": 0.0, "longitude": 10.0}, "Aaron", "web")
    for name, lat in (("Weit", 0.3), ("Nah", 0.1), ("Mittel", 0.2)):
        add(conn, "2026-11-01", name, latitude=lat, longitude=10.0)
    dayplan.optimize_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")
    assert names(conn, "2026-11-01") == ["Nah", "Mittel", "Weit"]


def test_optimize_needs_positions_and_leaves_tiny_days_alone(conn, trip):
    add(conn, "2026-11-01", "Ohne Position"); add(conn, "2026-11-01", "Auch ohne"); add(conn, "2026-11-01", "Mit", latitude=1.0, longitude=1.0)
    with pytest.raises(ServiceError, match="Ohne Position"):
        dayplan.optimize_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")
    add(conn, "2026-11-02", "Nur einer", latitude=1.0, longitude=1.0)
    assert dayplan.optimize_day(conn, U, day_id(conn, "2026-11-02"), "Aaron", "web")["changed"] is False


def test_retime_lays_stops_out_from_nine_with_travel_and_slack(conn, trip):
    add(conn, "2026-11-01", "A", duration_minutes=60, latitude=0.0, longitude=0.0)
    add(conn, "2026-11-01", "B", duration_minutes=30, latitude=0.0, longitude=0.0)   # same place: no travel, 5 minutes slack
    result = dayplan.retime_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")
    assert result["start"] == "09:00"
    assert [s["planned_time"] for s in service.get_plan(conn, U)[0]["stops"]] == ["2026-11-01T09:00", "2026-11-01T10:05"]
    dayplan.retime_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web", start="14:00")
    assert service.get_plan(conn, U)[0]["stops"][0]["planned_time"] == "2026-11-01T14:00"
    with pytest.raises(ServiceError, match="09:30"):
        dayplan.retime_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web", start="früh")


def test_retime_does_not_start_before_landing(conn, trip):
    service.create_item(conn, U, "booking", {"kind_raw": "arrivalFlight", "title": "LX 1", "start_date": "2026-11-01T10:00",
                                              "end_date": "2026-11-01T14:00", "buffer_minutes": 120}, "Aaron", "web")
    add(conn, "2026-11-01", "A", latitude=0.0, longitude=0.0)
    assert dayplan.retime_day(conn, U, day_id(conn, "2026-11-01"), "Aaron", "web")["start"] == "16:00"


def test_booking_stops_are_added_sorted_and_not_twice(conn, trip):
    service.create_item(conn, U, "booking", {"kind_raw": "hotel", "title": "Bristol", "start_date": "2026-11-01T15:00",
                                              "end_date": "2026-11-03T11:00", "latitude": 52.24, "longitude": 21.01}, "Aaron", "web")
    add(conn, "2026-11-01", "Spaziergang", planned_time="2026-11-01T17:00")
    first = dayplan.add_booking_stops(conn, U, trip, "Aaron", "web")
    assert first["added"] == 2 and names(conn, "2026-11-01") == ["Check-in · Bristol", "Spaziergang"]
    assert names(conn, "2026-11-03") == ["Check-out · Bristol"]
    assert dayplan.add_booking_stops(conn, U, trip, "Aaron", "web")["added"] == 0
    service.undo_change(conn, U, first["change_id"], "Aaron", "web")
    assert names(conn, "2026-11-01") == ["Spaziergang"] and names(conn, "2026-11-03") == []


def test_an_idea_becomes_a_stop_once_per_day(conn, trip):
    place = service.create_item(conn, U, "place", {"name": "Schloss", "notes": "früh hin", "latitude": 52.2479, "longitude": 21.0153}, "Aaron", "web")["id"]
    add(conn, "2026-11-01", "Davor")
    dayplan.stop_from_place(conn, U, place, day_id(conn, "2026-11-01"), "Aaron", "web")
    assert names(conn, "2026-11-01") == ["Davor", "Schloss"]
    made = service.get_plan(conn, U)[0]["stops"][1]
    assert made["place_id"] == place and made["latitude"] == 52.2479 and made["notes"] == "früh hin"
    with pytest.raises(ServiceError, match="schon im Plan"):
        dayplan.stop_from_place(conn, U, place, day_id(conn, "2026-11-01"), "Aaron", "web")
    dayplan.stop_from_place(conn, U, place, day_id(conn, "2026-11-02"), "Aaron", "web")      # another day is fine


def test_only_editors_may_change_the_plan_and_strangers_see_nothing(conn, trip):
    a = add(conn, "2026-11-01", "A")
    conn.execute("INSERT INTO people (sub, name, last_seen) VALUES ('v','Viewer','x'), ('s','Fremd','x')")
    service.set_member(conn, U, trip, "v", "viewer")
    with pytest.raises(ServiceError, match="nur ansehen"):
        dayplan.move_stop(conn, "v", a, "Viewer", "web", index=0)
    with pytest.raises(ServiceError, match="nicht gefunden"):
        dayplan.duplicate_stop(conn, "s", a, "Fremd", "web")
    with pytest.raises(ServiceError, match="nicht gefunden"):
        dayplan.copy_day(conn, "s", day_id(conn, "2026-11-01"), day_id(conn, "2026-11-02"), "Fremd", "web")


def test_a_batch_is_one_history_entry_and_a_no_op_leaves_none(conn, trip):
    a = add(conn, "2026-11-01", "A"); add(conn, "2026-11-01", "B")
    before = len(service.list_changes(conn, U))
    assert dayplan.move_stop(conn, U, a, "Aaron", "web", index=0)["change_id"] is None      # already first
    assert len(service.list_changes(conn, U)) == before
    dayplan.move_stop(conn, U, a, "Aaron", "web", index=1)
    log = service.list_changes(conn, U)
    assert len(log) == before + 1 and log[0]["summary"].startswith("Stopp verschoben: A")
