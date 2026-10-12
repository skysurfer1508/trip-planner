import pytest

from app import places

PAYLOAD = {"features": [
    {"geometry": {"coordinates": [21.0122, 52.2497]}, "properties": {
        "name": "Altstadt", "street": "Rynek", "housenumber": "1", "postcode": "00-001", "city": "Warschau", "country": "Polen",
        "osm_key": "tourism", "osm_value": "attraction"}},
    {"geometry": {"coordinates": [21.02, 52.24]}, "properties": {"name": "Bar Mleczny", "osm_key": "amenity", "osm_value": "restaurant"}},
    {"geometry": {"coordinates": [21.0, 52.2]}, "properties": {"osm_key": "boundary", "osm_value": "administrative"}},  # no name: dropped
]}


@pytest.fixture(autouse=True)
def fresh(monkeypatch):
    places._cache.clear()
    monkeypatch.setattr(places, "MIN_INTERVAL", 0.0)
    calls = []

    async def fake(params):
        calls.append(params)
        return PAYLOAD

    monkeypatch.setattr(places, "_fetch", fake)
    return calls


async def test_results_have_name_address_coordinates_and_the_apps_category(fresh):
    results = await places.search("Altstadt Warschau")
    assert results[0] == {"name": "Altstadt", "address": "Rynek 1, 00-001 Warschau, Polen", "latitude": 52.2497, "longitude": 21.0122,
                          "category_raw": "sight", "kind": "attraction"}
    assert results[1]["category_raw"] == "food" and len(results) == 2


async def test_answers_are_cached_and_the_bias_is_sent(fresh):
    await places.search("Altstadt", near=(52.23, 21.01))
    await places.search("altstadt ", near=(52.23, 21.01))
    assert len(fresh) == 1 and fresh[0]["lat"] == 52.23 and fresh[0]["lon"] == 21.01


async def test_short_queries_ask_nobody(fresh):
    assert await places.search(" a ") == [] and fresh == []


async def test_unsupported_languages_fall_back_to_english(fresh):
    await places.search("Zamek", lang="pl")
    assert fresh[0]["lang"] == "en"


@pytest.mark.parametrize("key,value,expected", [
    ("amenity", "cafe", "cafe"), ("amenity", "pub", "nightlife"), ("tourism", "hotel", "hotel"), ("tourism", "museum", "sight"),
    ("historic", "castle", "sight"), ("railway", "station", "transport"), ("aeroway", "aerodrome", "transport"),
    ("shop", "bakery", "cafe"), ("shop", "clothes", "other"), ("leisure", "park", "sight"), ("building", "yes", "other"),
])
def test_osm_tags_map_to_categories(key, value, expected):
    assert places.category(key, value) == expected


def test_duplicate_rule_matches_the_app():
    day = [{"name": "Altstadt", "latitude": 52.2497, "longitude": 21.0122}]
    assert places.duplicate(day, " altstadt ", 52.2498, 21.0123)       # same name, ~13 m apart
    assert not places.duplicate(day, "Altstadt", 52.30, 21.0122)        # same name, far away: a different place
    assert not places.duplicate(day, "Schloss", 52.2497, 21.0122)
