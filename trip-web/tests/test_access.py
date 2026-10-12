import pytest

from app import service
from app.db import connect, init_db
from app.service import ServiceError

OWNER, OTHER, THIRD = "owner-sub", "other-sub", "third-sub"


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    for sub, name in ((OWNER, "Aaron"), (OTHER, "Mama"), (THIRD, "Fremder")):
        service.touch_person(c, sub, name, f"{name.lower()}@example.org", name.lower())
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    trip_id = service.create_trip(conn, OWNER, "Warschau", "Polen", "2026-11-01", "2026-11-04")
    service.create_item(conn, OWNER, "place", {"name": "Altstadt"}, "Aaron", "web", trip_id)
    return trip_id


def test_creator_becomes_owner(conn, trip):
    assert [t["role"] for t in service.list_trips(conn, OWNER)] == ["owner"]


def test_a_stranger_sees_nothing_and_cannot_tell_the_trip_exists(conn, trip):
    assert service.list_trips(conn, OTHER) == []
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.trip_data(conn, OTHER, trip)
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.list_items(conn, OTHER, "place", trip_id=trip)
    with pytest.raises(ServiceError, match="Es gibt noch keine Reise"):
        service.list_items(conn, OTHER, "place")


def test_a_stranger_cannot_touch_single_items_or_the_log(conn, trip):
    item = service.list_items(conn, OWNER, "place")["items"][0]["id"]
    change = service.list_changes(conn, OWNER)[0]["id"]
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.update_item(conn, OTHER, "place", item, {"notes": "x"}, "Mama", "web")
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.remove_item(conn, OTHER, "place", item, "Mama", "web")
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.undo_change(conn, OTHER, change, "Mama", "web")
    with pytest.raises(ServiceError, match="nicht gefunden"):
        service.create_item(conn, OTHER, "place", {"name": "Y"}, "Mama", "web", trip)


def test_viewer_reads_but_cannot_write(conn, trip):
    service.set_member(conn, OWNER, trip, OTHER, "viewer")
    assert service.trip_data(conn, OTHER, trip)["role"] == "viewer"
    item = service.list_items(conn, OTHER, "place")["items"][0]["id"]
    with pytest.raises(ServiceError, match="nur ansehen"):
        service.update_item(conn, OTHER, "place", item, {"notes": "x"}, "Mama", "web")
    with pytest.raises(ServiceError, match="nur ansehen"):
        service.create_item(conn, OTHER, "place", {"name": "Y"}, "Mama", "web")


def test_editor_writes_but_cannot_manage_members(conn, trip):
    service.set_member(conn, OWNER, trip, OTHER, "editor")
    made = service.create_item(conn, OTHER, "place", {"name": "Schloss"}, "Mama", "web")
    assert made["item"]["name"] == "Schloss"
    with pytest.raises(ServiceError, match="Besitzer"):
        service.set_member(conn, OTHER, trip, THIRD, "viewer")
    with pytest.raises(ServiceError, match="Besitzer"):
        service.remove_member(conn, OTHER, trip, OWNER)


def test_members_list_shows_subs_only_to_owners(conn, trip):
    service.set_member(conn, OWNER, trip, OTHER, "editor")
    as_owner = service.list_members(conn, OWNER, trip)
    as_editor = service.list_members(conn, OTHER, trip)
    assert {m["name"] for m in as_owner} == {"Aaron", "Mama"} and all("sub" in m for m in as_owner)
    assert all("sub" not in m for m in as_editor)


def test_the_last_owner_cannot_be_removed_or_demoted(conn, trip):
    with pytest.raises(ServiceError, match="mindestens einen Besitzer"):
        service.set_member(conn, OWNER, trip, OWNER, "editor")
    with pytest.raises(ServiceError, match="mindestens einen Besitzer"):
        service.remove_member(conn, OWNER, trip, OWNER)
    service.set_member(conn, OWNER, trip, OTHER, "owner")
    service.set_member(conn, OWNER, trip, OWNER, "editor")  # fine now: Mama is also an owner


def test_anyone_may_leave_a_trip(conn, trip):
    service.set_member(conn, OWNER, trip, OTHER, "viewer")
    service.remove_member(conn, OTHER, trip, OTHER)
    assert service.list_trips(conn, OTHER) == []


def test_sharing_needs_a_person_who_has_signed_in(conn, trip):
    with pytest.raises(ServiceError, match="noch nie"):
        service.set_member(conn, OWNER, trip, "never-seen", "viewer")


def test_claim_only_takes_trips_without_members(conn, trip):
    orphan = service.create_trip(conn, service.SYSTEM, "Japan 2027", "Japan", "2027-07-19", "2027-08-08")
    assert service.list_trips(conn, OTHER) == []
    assert service.claim_trips(conn, OTHER) == 1
    assert [t["name"] for t in service.list_trips(conn, OTHER)] == ["Japan 2027"]
    assert service.list_members(conn, OTHER, orphan)[0]["role"] == "owner"
    assert [t["name"] for t in service.list_trips(conn, OWNER)] == ["Warschau"]  # not touched


def test_people_suggestions_are_limited_to_people_you_share_a_trip_with(conn, trip):
    service.set_member(conn, OWNER, trip, OTHER, "editor")
    assert service.list_people(conn, OWNER) == ["Aaron", "Mama"]
    assert service.list_people(conn, THIRD) == ["Fremder"]


def test_finding_people_to_share_with_needs_a_trip_of_your_own(conn, trip):
    assert [p["name"] for p in service.find_people(conn, OWNER, "mam")] == ["Mama"]
    with pytest.raises(ServiceError, match="Besitzer"):
        service.find_people(conn, OTHER, "aar")


def test_one_day_per_date(conn, trip):
    with pytest.raises(ServiceError, match="schon einen Tag"):  # 2026-11-01 was made from the trip dates
        service.create_item(conn, OWNER, "day", {"date": "2026-11-01"}, "Aaron", "web")
    service.create_item(conn, OWNER, "day", {"date": "2026-12-01"}, "Aaron", "web")
    second = service.create_item(conn, OWNER, "day", {"date": "2026-12-02"}, "Aaron", "web")["id"]
    with pytest.raises(ServiceError, match="schon einen Tag"):
        service.update_item(conn, OWNER, "day", second, {"date": "2026-12-01"}, "Aaron", "web")


def test_rev_is_stamped_on_writes_and_grows(conn, trip):
    first = conn.execute("SELECT rev FROM places").fetchone()["rev"]
    item = service.list_items(conn, OWNER, "place")["items"][0]["id"]
    service.update_item(conn, OWNER, "place", item, {"notes": "n"}, "Aaron", "web")
    assert conn.execute("SELECT rev FROM places WHERE id = ?", (item,)).fetchone()["rev"] > first
    assert service.revision(conn) >= conn.execute("SELECT MAX(rev) FROM places").fetchone()[0]
