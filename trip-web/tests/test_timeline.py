import pytest

from app import route, service, timeline
from app.db import connect, init_db
from app.service import ServiceError

U, V = "u1", "u2"
TABLE = {"JPY": 150.0}


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    return service.create_trip(conn, U, "Japan", "Japan", "2027-07-19", "2027-08-08", currency_code="CHF", travelers=4)


def stay(conn, trip, name, nights, **kw):
    return service.create_item(conn, U, "stay", {"name": name, "nights": nights, **kw}, "Claude", "claude", trip)["item"]


def build(conn, trip):
    data = service.trip_data(conn, U, trip)
    summary = route.summarize(data["trip"], data["legs"], TABLE)
    return timeline.build(data["trip"], data["stays"], summary["hops"], data["places"], service.tally(data["votes"]))


def test_stays_follow_each_other_and_come_out_in_dates(conn, trip):
    stay(conn, trip, "Tokyo", 5)
    stay(conn, trip, "Kyoto", 4)
    stay(conn, trip, "Osaka", 3)
    result = build(conn, trip)
    assert [(s["name"], s["arrive"], s["leave"]) for s in result["stays"]] == [
        ("Tokyo", "2027-07-19", "2027-07-24"), ("Kyoto", "2027-07-24", "2027-07-28"), ("Osaka", "2027-07-28", "2027-07-31")]
    assert result["available_nights"] == 20 and result["planned_nights"] == 12
    assert any("fehlen noch 8 Nächte" in w for w in result["warnings"])


def test_too_many_nights_are_reported(conn, trip):
    stay(conn, trip, "Tokyo", 25)
    assert any("zu viel" in w for w in build(conn, trip)["warnings"])


def test_a_stay_knows_how_it_is_reached(conn, trip):
    stay(conn, trip, "Tokyo", 5)
    stay(conn, trip, "Kyoto", 15)
    service.create_item(conn, U, "leg", {"from_name": "Tokyo", "to_name": "Kyoto", "mode": "shinkansen", "line": "Nozomi", "duration_minutes": 135,
                                          "price": 14000, "currency_code": "JPY"}, "Claude", "claude", trip)
    kyoto = build(conn, trip)["stays"][1]
    assert kyoto["arrival"]["mode"] == "shinkansen" and kyoto["arrival"]["duration_minutes"] == 135 and kyoto["arrival"]["chosen"]
    assert build(conn, trip)["warnings"] == []


def test_missing_route_for_a_stay_is_a_warning(conn, trip):
    stay(conn, trip, "Tokyo", 10)
    stay(conn, trip, "Hiroshima", 10)
    assert any("Hiroshima" in w and "Route" in w for w in build(conn, trip)["warnings"])


def test_new_stays_are_appended_in_order(conn, trip):
    stay(conn, trip, "A", 1)
    stay(conn, trip, "B", 1)
    stay(conn, trip, "C", 1)
    assert [s["name"] for s in build(conn, trip)["stays"]] == ["A", "B", "C"]


def test_ideas_are_counted_per_stay(conn, trip):
    stay(conn, trip, "Kyoto", 3)
    service.create_item(conn, U, "place", {"name": "Fushimi Inari", "region": "Kyoto", "prio": "Muss"}, "Claude", "claude", trip)
    service.create_item(conn, U, "place", {"name": "Nijo", "region": "Kyoto", "decision": "Nein"}, "Claude", "claude", trip)
    service.create_item(conn, U, "place", {"name": "Skytree", "region": "Tokyo"}, "Claude", "claude", trip)
    first = build(conn, trip)["stays"][0]
    assert first["ideas"] == 1 and first["must"] == 1


# MARK: Votes

def idea(conn, trip, name="Hakone"):
    return service.create_item(conn, U, "place", {"name": name}, "Claude", "claude", trip)["id"]


def test_a_vote_is_kept_per_person_and_can_be_changed_or_withdrawn(conn, trip):
    place = idea(conn, trip)
    service.vote(conn, U, place, 1)
    assert service.tally(service.list_votes(conn, trip))[place]["for"]
    service.vote(conn, U, place, -1)
    t = service.tally(service.list_votes(conn, trip))[place]
    assert t["against"] and not t["for"]
    service.vote(conn, U, place, 0)
    assert service.list_votes(conn, trip) == []


def test_viewers_may_vote_but_strangers_may_not(conn, trip):
    place = idea(conn, trip)
    service.touch_person(conn, V, "Mia")
    service.set_member(conn, U, trip, V, "viewer")
    service.vote(conn, V, place, 1)
    with pytest.raises(ServiceError):
        service.vote(conn, "stranger", place, 1)
    with pytest.raises(ServiceError):
        service.vote(conn, U, place, 5)


def test_claude_can_note_what_a_named_member_said_but_the_website_vote_wins(conn, trip):
    place = idea(conn, trip)
    service.vote(conn, U, place, 1, member="Mia")
    service.vote(conn, U, place, -1, member="Mia")
    assert len(service.list_votes(conn, trip)) == 1                       # the same name is one vote, the last one counts
    t = service.tally(service.list_votes(conn, trip))[place]
    assert t["against"] == ["Mia"]


def test_viewers_cannot_vote_in_the_name_of_others(conn, trip):
    place = idea(conn, trip)
    service.touch_person(conn, V, "Mia")
    service.set_member(conn, U, trip, V, "viewer")
    with pytest.raises(ServiceError):
        service.vote(conn, V, place, 1, member="Mia")


def test_trip_data_carries_stays_votes_and_me(conn, trip):
    place = idea(conn, trip)
    stay(conn, trip, "Tokyo", 3)
    service.vote(conn, U, place, 1)
    data = service.trip_data(conn, U, trip)
    assert data["stays"][0]["name"] == "Tokyo" and data["votes"][0]["value"] == 1 and data["me"] == U
