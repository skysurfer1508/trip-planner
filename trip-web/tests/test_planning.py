"""The expected values are the ones in the iOS app's own unit tests (RouteOptimizerTests, ScheduleServiceTests, TripLogisticsTests,
PlanningTests), so the website lays out a day the same way the app does."""
from datetime import datetime

import pytest

from app import planning as p


def at(hour, minute=0, day="2026-06-01"):
    return datetime.fromisoformat(f"{day}T{hour:02d}:{minute:02d}")


# MARK: RouteOptimizerTests

def line(*latitudes):
    return [(lat, 0.0) for lat in latitudes]


def test_orders_along_a_line():
    assert p.optimize_order(line(0.0, 0.3, 0.1, 0.2)) == [0, 2, 3, 1]


def test_keeps_the_first_stop_first_and_loses_none():
    order = p.optimize_order(line(0.5, 0.0, 0.2, 0.4, 0.1))
    assert order[0] == 0 and set(order) == set(range(5))


def test_never_longer_than_the_original():
    original = line(0.0, 0.9, 0.1, 0.8, 0.2, 0.7)
    order = p.optimize_order(original)
    assert p.route_length([original[i] for i in order]) <= p.route_length(original)


def test_tiny_routes_are_unchanged():
    assert p.optimize_order(line(0.0, 1.0)) == [0, 1]
    assert p.optimize_order([]) == []


# MARK: ScheduleServiceTests

def test_round_up_to_five_minutes():
    assert p.round_up(at(10, 41)) == at(10, 45)
    assert p.round_up(at(10, 45)) == at(10, 45)
    assert p.round_up(at(10, 45).replace(second=1)) == at(10, 50)


def test_auto_schedule_adds_travel_and_slack():
    times = p.auto_schedule([(60, 0), (30, 12), (45, 20)], at(9, 0))
    # 9:00 + 60 = 10:00; + 12 travel + 5 slack = 10:17 -> 10:20; + 30 = 10:50; + 25 = 11:15.
    assert times == [at(9, 0), at(10, 20), at(11, 15)]


def test_auto_schedule_empty_and_short_stays_take_at_least_five_minutes():
    assert p.auto_schedule([], at(9, 0)) == []
    assert p.auto_schedule([(0, 0), (30, 0)], at(9, 0)) == [at(9, 0), at(9, 10)]


# MARK: Travel and a whole day (TimeAdjuster)

def test_travel_minutes_use_the_apps_speeds_and_detour():
    # about 1 km east at the equator: 1000 m * 1.25 / 1.3 m/s = 16.03 min -> 17
    one_km = (0.0, 0.0089932)
    assert p.travel_minutes((0.0, 0.0), one_km, "walking") == 17
    assert p.travel_minutes((0.0, 0.0), one_km, "transit") == 4
    assert p.travel_minutes((0.0, 0.0), one_km, "car") == 3


def test_day_times_start_from_the_hotel():
    stops = [{"latitude": 0.0, "longitude": 0.0089932, "duration_minutes": 60}, {"latitude": 0.0, "longitude": 0.0089932, "duration_minutes": 30}]
    # hotel 1 km before the first stop: the walk comes first, then the stops follow without travel (same place) plus 5 minutes slack
    times = p.day_times(stops, at(9, 0), (0.0, 0.0), "walking")
    assert times == [at(9, 20), at(10, 25)]


def test_suggested_start_defaults_to_nine_and_respects_landing():
    window = p.DayWindow()
    assert p.suggested_start("2026-06-05", [], window, "walking") == at(9, 0, "2026-06-05")
    stops = [{"planned_time": "2026-06-05T11:30"}, {"planned_time": "2026-06-05T10:15"}]
    assert p.suggested_start("2026-06-05", stops, window, "walking") == at(10, 15, "2026-06-05")  # the earliest time, wherever it sits in the list
    landed = p.DayWindow(start_minute=16 * 60 + 30)
    assert p.suggested_start("2026-06-05", stops, landed, "walking") == at(16, 30, "2026-06-05")


# MARK: TripLogisticsTests (June 2026, hotel Sol at 38.72, -9.14)

def bookings():
    return [
        {"kind_raw": "arrivalFlight", "title": "LH 1234", "place_name": "LIS", "start_date": "2026-06-05T12:00", "end_date": "2026-06-05T14:30", "buffer_minutes": 120},
        {"kind_raw": "hotel", "title": "Hotel Sol", "place_name": "Hotel Sol", "start_date": "2026-06-05T15:00", "end_date": "2026-06-08T11:00", "buffer_minutes": 0,
         "has_coordinate": True, "latitude": 38.72, "longitude": -9.14},
        {"kind_raw": "departureFlight", "title": "LH 1235", "place_name": "LIS", "start_date": "2026-06-08T18:20", "end_date": "2026-06-08T22:00", "buffer_minutes": 180},
    ]


def test_arrival_day_starts_after_landing_plus_buffer():
    window = p.day_window("2026-06-05", bookings())
    assert window.start_minute == 14 * 60 + 30 + 120 and window.end_minute is None
    assert any(i["text"].startswith("Landung") for i in window.items) and any(i["text"].startswith("Check-in") for i in window.items)


def test_departure_day_ends_before_the_airport_trip():
    window = p.day_window("2026-06-08", bookings())
    assert window.end_minute == 18 * 60 + 20 - 180 and window.start_minute is None
    assert any(i["text"].startswith("Check-out") for i in window.items) and any(i["text"] == "Weg zum Flughafen" for i in window.items)


def test_the_hotel_is_the_anchor_only_while_you_stay():
    for day in range(5, 9):
        assert p.day_window(f"2026-06-{day:02d}", bookings()).anchor == (38.72, -9.14), day
    assert p.day_window("2026-06-04", bookings()).anchor is None
    assert p.day_window("2026-06-09", bookings()).anchor is None


def test_a_middle_day_is_open_and_no_bookings_means_no_limits():
    window = p.day_window("2026-06-06", bookings())
    assert window.start_minute is None and window.end_minute is None and window.items == []
    assert p.day_window("2026-06-05", []).is_empty


def test_the_latest_hotel_wins_when_two_overlap():
    two = bookings() + [{"kind_raw": "hotel", "title": "Zweites", "start_date": "2026-06-07T15:00", "end_date": "2026-06-08T10:00",
                         "has_coordinate": True, "latitude": 1.0, "longitude": 2.0}]
    assert p.day_window("2026-06-07", two).anchor_name == "Zweites"


# MARK: BookingPlanner

def test_booking_stops_put_flights_and_hotel_on_the_plan():
    stops, skipped = p.booking_stops(bookings(), {f"2026-06-{d:02d}" for d in range(5, 9)})
    by_name = {s["name"]: s for s in stops}
    assert set(by_name) == {"Check-in · Hotel Sol", "Check-out · Hotel Sol", "Weg zum Flughafen"}
    assert by_name["Weg zum Flughafen"]["planned_time"] == "2026-06-08T15:20"            # 18:20 minus the 180 minute buffer
    assert (by_name["Weg zum Flughafen"]["latitude"], by_name["Weg zum Flughafen"]["longitude"]) == (38.72, -9.14)  # starts at the hotel
    assert skipped == 2                                                                      # the landing and the flight itself have no position


def test_booking_stops_outside_the_trip_days_are_ignored():
    stops, _ = p.booking_stops(bookings(), {"2026-06-06"})
    assert stops == []


# MARK: PlanningTests (Day.swift)

def test_move_within_puts_a_stop_at_an_index():
    assert p.move_within(["a", "b", "c", "d"], "a", 2) == ["b", "c", "a", "d"]
    assert p.move_within(["a", "b", "c"], "c", 0) == ["c", "a", "b"]
    assert p.move_within(["a", "b"], "a", 99) == ["b", "a"]


def test_duplicate_puts_the_copy_right_after_the_original():
    assert p.insert_copy_after(["a", "b", "c"], "b", "b2") == ["a", "b", "b2", "c"]


def test_renumber_is_dense_from_zero():
    assert p.renumber_ids(["x", "y", "z"]) == {"x": 0, "y": 1, "z": 2}


def test_sort_by_time_is_stable_and_keeps_untimed_stops_after():
    stops = [{"id": "no1"}, {"id": "late", "planned_time": "2026-06-01T15:00"}, {"id": "tie1", "planned_time": "2026-06-01T09:00"},
             {"id": "no2"}, {"id": "tie2", "planned_time": "2026-06-01T09:00"}]
    assert p.sort_by_time(stops) == ["tie1", "tie2", "late", "no1", "no2"]


def test_with_date_keeps_the_time_of_day():
    assert p.with_date("2026-11-01T09:30", "2026-11-05") == "2026-11-05T09:30"


def test_stops_without_a_position_take_no_travel_time():
    """A stop added by hand has no position. Counting the way to (0, 0) would push every later stop into the next day."""
    stops = [{"latitude": 35.7, "longitude": 139.8, "duration_minutes": 60}, {"duration_minutes": 30}, {"latitude": 35.7, "longitude": 139.8, "duration_minutes": 30}]
    times = p.day_times(stops, at(9, 0), (35.7, 139.8), "walking")
    assert times == [at(9, 0), at(10, 5), at(10, 40)]          # 60 + 5 slack, then 30 + 5 slack; no walks
    assert p.day_times([{"duration_minutes": 30}], at(9, 0), (35.7, 139.8), "walking") == [at(9, 0)]   # nor from the hotel


def test_the_suggested_start_ignores_a_hotel_when_the_first_stop_has_no_position():
    stops = [{"planned_time": "2026-06-05T11:00"}]
    assert p.suggested_start("2026-06-05", stops, p.DayWindow(anchor=(35.7, 139.8)), "walking") == at(11, 0, "2026-06-05")
