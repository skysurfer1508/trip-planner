from app import checks, holidays

DAY = "2027-07-20"  # a Tuesday


def stop(id_, name, time, minutes=60, lat=35.0, lon=139.0, hours="", order=0):
    return {"id": id_, "day_id": "d1", "name": name, "planned_time": f"{DAY}T{time}" if time else None, "duration_minutes": minutes,
            "latitude": lat, "longitude": lon, "opening_hours": hours, "sort_order": order}


def data(stops, windows=None, legs=None, transport="walking"):
    return {"trip": {"transport_raw": transport}, "days": [{"id": "d1", "date": DAY}], "stops": stops, "windows": windows or {}, "legs": legs or []}


def kinds(items):
    return [i["kind"] for i in items]


def test_a_plain_day_has_no_warnings():
    assert checks.check_trip(data([stop("a", "Tempel", "09:00", order=0), stop("b", "Park", "11:00", lat=35.001, order=1)])) == []


def test_closed_on_that_weekday_and_opening_time_warnings():
    found = checks.check_trip(data([stop("a", "Museum", "10:00", hours="Mo,We-Su 10:00-17:00")]))
    assert kinds(found) == ["opening_hours"] and "Dienstags geschlossen" in found[0]["text"]
    early = checks.check_trip(data([stop("a", "Museum", "08:00", hours="Tu 10:00-17:00")]))
    assert "Öffnet um 10:00" in early[0]["text"]
    assert checks.check_trip(data([stop("a", "Museum", "11:00", hours="Tu 10:00-17:00")])) == []
    assert checks.check_trip(data([stop("a", "Museum", "08:00", hours="Mo-Fr 09:00-17:00 || on appointment")])) == []   # not understood: no claim


def test_a_public_holiday_closes_places_and_is_noted_for_the_day():
    found = checks.check_trip(data([stop("a", "Museum", "10:00", hours="Tu 10:00-17:00; PH off")]), {DAY: "Marine Day"})
    assert sorted(kinds(found)) == ["holiday", "opening_hours"]
    assert any("Feiertagen" in i["text"] for i in found) and any("Marine Day" in i["text"] for i in found)


def test_stops_before_landing_and_after_the_way_to_the_airport():
    window = {DAY: {"start": "14:30", "end": "18:00", "hotel": None, "items": []}}
    found = checks.check_trip(data([stop("a", "Frühstück", "09:00"), stop("b", "Abendessen", "17:30", lat=35.0001, order=1)], window))
    assert sorted(kinds(found)) == ["after_departure", "before_arrival"]


def test_overlap_and_a_way_that_is_too_tight():
    overlap = checks.check_trip(data([stop("a", "Tempel", "09:00", 120), stop("b", "Markt", "10:00", order=1)]))
    assert kinds(overlap) == ["overlap"]
    far = stop("b", "Burg", "10:10", lat=35.2, order=1)          # about 22 km away, ten minutes after the first ends
    tight = checks.check_trip(data([stop("a", "Tempel", "09:00"), far]))
    assert kinds(tight) == ["tight_way"] and "10 Min" in tight[0]["text"]


def test_a_day_that_is_too_full_and_a_late_evening_on_transit():
    busy = [stop(str(i), f"Ort {i}", None, 150, lat=35.0 + i * 0.001, order=i) for i in range(5)]
    assert "full_day" in kinds(checks.check_trip(data(busy)))
    late = checks.check_trip(data([stop("a", "Izakaya", "22:00", 90)], transport="transit"))
    assert kinds(late) == ["late_evening"]
    assert checks.check_trip(data([stop("a", "Izakaya", "22:00", 90)], transport="walking")) == []


def leg(id_, hop, dep, arr, mode="shinkansen"):
    return {"id": id_, "hop": hop, "status": "chosen", "mode": mode, "from_name": "A", "to_name": "B", "departure": dep, "arrival": arr}


def test_connections_between_chosen_legs():
    tight = checks.check_trip(data([], legs=[leg("l1", 1, "2027-07-20T09:00", "2027-07-20T11:00"), leg("l2", 2, "2027-07-20T11:08", "2027-07-20T13:00")]))
    assert kinds(tight) == ["tight_connection"] and "8 Min" in tight[0]["text"]
    impossible = checks.check_trip(data([], legs=[leg("l1", 1, "2027-07-20T09:00", "2027-07-20T11:00"), leg("l2", 2, "2027-07-20T10:30", "2027-07-20T13:00")]))
    assert kinds(impossible) == ["impossible_connection"]
    roomy = checks.check_trip(data([], legs=[leg("l1", 1, "2027-07-20T09:00", "2027-07-20T11:00"), leg("l2", 2, "2027-07-20T12:00", "2027-07-20T14:00")]))
    assert roomy == []


def test_very_early_and_very_late_rides_are_only_a_reminder():
    found = checks.check_trip(data([], legs=[leg("l1", 1, "2027-07-20T05:00", "2027-07-20T07:00", "train"), leg("l2", 2, "2027-07-20T21:00", "2027-07-20T23:45", "bus")]))
    assert sorted(kinds(found)) == ["early_ride", "late_ride"] and {i["severity"] for i in found} == {"info"}
    assert checks.check_trip(data([], legs=[leg("l1", 1, "2027-07-20T05:00", "2027-07-20T07:00", "flight")])) == []


def test_warnings_are_sorted_serious_first_and_keys_are_stable():
    found = checks.check_trip(data([stop("a", "Museum", "10:00", hours="Mo 10:00-17:00")]), {DAY: "Feiertag"})
    assert [i["severity"] for i in found] == ["warn", "info"]
    assert found[0]["key"] == "opening_hours:a"


def test_holiday_list_keeps_public_and_marks_regional_ones():
    rows = [{"date": "2027-07-19", "name": "Marine Day", "global": True, "types": ["Public"]},
            {"date": "2027-02-17", "name": "Carnival", "global": True, "types": ["Optional"]},
            {"date": "2027-06-13", "name": "St Anthony", "global": False, "types": ["Public"]}]
    assert holidays.parse(rows) == {"2027-07-19": "Marine Day", "2027-06-13": "St Anthony (nur in einigen Regionen)"}
