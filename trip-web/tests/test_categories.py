import json
import sqlite3
from pathlib import Path

import pytest

from app import archive, categories, service
from app.categories import classify
from app.config import settings
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"
SEED = json.loads((Path(__file__).parent.parent / "seed" / "japan2027.json").read_text())
PLACES = [dict(zip(SEED["place_columns"], row)) for row in SEED["places"]]


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    return service.create_trip(conn, U, "Japan", "", "2027-07-19", "2027-08-08")


def test_every_japan_idea_gets_a_category_from_the_list():
    for place in PLACES:
        assert classify(place["name"], place["description"], place["region"]) in categories.IDS, place["name"]


def test_the_japan_ideas_are_sorted_as_chosen_by_hand():
    expected = {"Asakusa mit Senso-ji": "temple", "Akihabara": "shopping", "Nishiki-Markt": "food", "Kamikochi": "nature", "Gion Matsuri": "event",
                "Universal Studios Japan": "activity", "Ghibli-Museum, Mitaka": "museum", "Shinjuku": "nightlife", "Burg Osaka": "sight"}
    for name, category in expected.items():
        place = next(p for p in PLACES if p["name"] == name)
        assert classify(place["name"], place["description"], place["region"]) == category, name
    assert {classify(p["name"], p["description"], p["region"]) for p in PLACES if p["region"] == "Flughafen"} == {"transport"}


@pytest.mark.parametrize("name,description,expected", [
    ("Meiji-Schrein", "", "temple"), ("Ramen Street", "", "food"), ("Outlet Gotemba", "Shopping", "shopping"), ("Mount Fuji", "Berg", "nature"),
    ("Karaoke Kan", "", "activity"), ("Sommerfest am Fluss", "Konzert", "event"), ("Noch nie gehört", "", "other"),
    ("Fischhalle", "Kleiner Hafen und Fischmarkt", "food"),   # a port is not a transport place; the market is the point
])
def test_unknown_places_get_a_sensible_guess(name, description, expected):
    assert classify(name, description) == expected


def test_a_new_place_is_sorted_automatically_and_can_be_changed(conn, trip):
    made = service.create_item(conn, U, "place", {"name": "Kinkaku-ji Tempel"}, "Claude", "claude", trip)
    assert made["item"]["category"] == "temple"
    set_by_hand = service.create_item(conn, U, "place", {"name": "Kinkaku-ji", "category": "sight"}, "a", "web", trip)
    assert set_by_hand["item"]["category"] == "sight"
    service.update_item(conn, U, "place", made["id"], {"category": "nature"}, "a", "web")
    assert service.list_items(conn, U, "place", where={"id": made["id"]})["items"][0]["category"] == "nature"
    with pytest.raises(ServiceError, match="category"):
        service.update_item(conn, U, "place", made["id"], {"category": "tempel"}, "a", "web")


def test_the_migration_sorts_the_ideas_that_are_already_there(tmp_path, monkeypatch):
    path = tmp_path / "trip.db"
    monkeypatch.setattr(settings, "db_path", str(path))
    raw = sqlite3.connect(path)
    raw.executescript((Path(__file__).parent / "fixtures" / "schema_v0.sql").read_text())
    raw.execute("INSERT INTO trips (id, name, start_date, end_date, created_at, updated_at) VALUES ('t','Japan','2027-07-19','2027-07-20','x','x')")
    for pid, name, region in (("p1", "Fushimi Inari", "Kyoto"), ("p2", "Flughafen Haneda (HND)", "Flughafen"), ("p3", "Etwas Neues", "")):
        raw.execute("INSERT INTO places (id, trip_id, name, region, created_at, updated_at) VALUES (?, 't', ?, ?, 'x', 'x')", (pid, name, region))
    raw.commit(); raw.close()
    c = connect()
    init_db(c)
    assert {r["name"]: r["category"] for r in c.execute("SELECT name, category FROM places")} == {
        "Fushimi Inari": "temple", "Flughafen Haneda (HND)": "transport", "Etwas Neues": "other"}
    c.close()


def test_places_from_the_app_keep_a_matching_category(conn):
    data = {"version": 1, "trips": [{
        "name": "Warschau", "destination": "Warschau", "startDate": "2026-10-31T23:00:00Z", "endDate": "2026-11-01T23:00:00Z", "destinationLatitude": 0,
        "destinationLongitude": 0, "hasDestinationCoordinate": False, "budget": 0, "currencyCode": "PLN", "days": [], "expenses": [], "checklist": [],
        "documents": [], "savedPlaces": [
            {"name": "Milchbar", "latitude": 1, "longitude": 1, "address": "", "categoryRaw": "cafe", "savedAt": "2026-10-01T10:00:00Z"},
            {"name": "Club", "latitude": 1, "longitude": 1, "address": "", "categoryRaw": "nightlife", "savedAt": "2026-10-01T10:00:00Z"}]}]}
    done = archive.import_archive(conn, U, data, "Europe/Zurich", "a")[0]["trip_id"]
    assert {p["name"]: p["category"] for p in service.list_items(conn, U, "place", done)["items"]} == {"Milchbar": "food", "Club": "nightlife"}


def test_the_website_has_the_same_categories_in_the_same_order():
    source = (Path(__file__).parent.parent / "web" / "src" / "categories.ts").read_text()
    import re
    in_site = re.findall(r"id: '(\w+)', label: '([^']+)'", source)
    assert in_site == [(i, label) for i, label in categories.CATEGORIES]


def test_the_website_has_the_same_transport_modes():
    import re
    from app.entities import LEG_MODES
    source = (Path(__file__).parent.parent / "web" / "src" / "modes.ts").read_text()
    assert tuple(re.findall(r"id: '(\w+)', label", source)) == LEG_MODES
