import pytest

from app import budget, packing, rates, service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"
TABLE = {"EUR": 1.05, "PLN": 4.5, "JPY": 170.0}   # per 1 CHF, as open.er-api.com answers for base CHF


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    return service.create_trip(conn, U, "Reise", "", "2026-11-01", "2026-11-03", currency_code="CHF", budget=300, phase="building")


# MARK: Exchange rates

def test_convert_follows_the_apps_rule():
    assert rates.convert(10, "CHF", "CHF", None) == 10
    assert rates.convert(105, "EUR", "CHF", TABLE) == pytest.approx(100)
    assert rates.convert(10, "XYZ", "CHF", TABLE) is None
    assert rates.convert(10, "EUR", "CHF", None) is None


async def test_rates_are_cached_and_the_last_answer_survives_an_outage(monkeypatch):
    rates._cache.clear()
    calls = []

    async def ok(base):
        calls.append(base)
        return {"result": "success", "rates": {"EUR": 1.05, "bad": "x"}}

    monkeypatch.setattr(rates, "_fetch", ok)
    assert await rates.rates("chf") == {"EUR": 1.05}
    await rates.rates("CHF")
    assert calls == ["CHF"]                                        # second call came from the cache

    async def down(base):
        raise RuntimeError("offline")

    monkeypatch.setattr(rates, "_fetch", down)
    rates._cache["CHF"] = (0.0, {"EUR": 1.05})                     # expired entry: still better than nothing
    assert await rates.rates("CHF") == {"EUR": 1.05}
    assert await rates.rates("USD") is None


# MARK: Budget

def expense(i, amount, code, category, date="2026-11-01"):
    return {"id": i, "title": f"Ausgabe {i}", "amount": amount, "currency_code": code, "category_raw": category, "date": date}


def test_summary_is_in_the_trip_currency_per_category_and_day():
    trip = {"currency_code": "CHF", "budget": 300}
    items = [expense("a", 100, "CHF", "food"), expense("b", 105, "EUR", "food", "2026-11-02"), expense("c", 45, "PLN", "transport")]
    stops = [{"estimated_cost": 20}, {"estimated_cost": 5.5}, {}]
    s = budget.summarize(trip, items, stops, TABLE)
    assert s["spent"] == pytest.approx(210)                       # 100 + 100 + 10
    assert s["left"] == pytest.approx(90) and s["percent"] == 70.0 and s["over"] is False
    assert s["planned"] == 25.5
    assert s["by_category"] == [{"category": "food", "total": 200.0}, {"category": "transport", "total": 10.0}]
    assert s["by_day"] == [{"date": "2026-11-01", "total": 110.0}, {"date": "2026-11-02", "total": 100.0}]
    assert s["unconverted"] == [] and s["rates_known"] is True


def test_unknown_currencies_are_listed_not_guessed_and_over_budget_is_flagged():
    trip = {"currency_code": "CHF", "budget": 100}
    s = budget.summarize(trip, [expense("a", 150, "CHF", "food"), expense("b", 9, "XYZ", "other")], [], TABLE)
    assert s["over"] is True and s["left"] == -50
    assert s["unconverted"] == [{"id": "b", "title": "Ausgabe b", "currency": "XYZ"}]
    offline = budget.summarize(trip, [expense("a", 10, "EUR", "food")], [], None)
    assert offline["rates_known"] is False and offline["unconverted"][0]["id"] == "a" and offline["spent"] == 0


def test_no_budget_means_no_percentage():
    s = budget.summarize({"currency_code": "CHF", "budget": 0}, [expense("a", 10, "CHF", "food")], [], TABLE)
    assert s["percent"] is None and s["over"] is False


# MARK: Packing

def titles(conn):
    return [i["title"] for i in service.list_items(conn, U, "checklist_item")["items"]]


def test_the_template_follows_the_options(conn):
    base = [t for _, t in packing.template(packing.Options())]
    assert "Leichte Jacke" in base and "Regenjacke" not in base and "Badesachen" not in base
    cold_rain = [t for _, t in packing.template(packing.Options(climate="cold", rain=True, beach=True, kids=True))]
    assert {"Warme Jacke", "Regenjacke", "Badesachen", "Sonnencreme", "Snacks"} <= set(cold_rain) and "Leichte Jacke" not in cold_rain
    assert "Unterwäsche (4)" in base and "Unterwäsche (8)" in [t for _, t in packing.template(packing.Options(nights=30))]


def test_adding_the_template_skips_what_is_there_and_can_be_undone(conn, trip):
    service.create_item(conn, U, "checklist_item", {"title": "PASS / ausweis", "section": "Eigene"}, "a", "web", trip)
    done = packing.add_template(conn, U, trip, {"climate": "warm", "beach": True}, "Aaron", "web")
    assert "Pass / Ausweis" not in titles(conn) and "PASS / ausweis" in titles(conn) and "Badesachen" in titles(conn)
    assert done["added"] == len(titles(conn)) - 1
    again = packing.add_template(conn, U, trip, {"climate": "warm", "beach": True}, "Aaron", "web")
    assert again["added"] == 0 and again["change_id"] is None
    service.undo_change(conn, U, done["change_id"], "Aaron", "web")
    assert titles(conn) == ["PASS / ausweis"]


def test_bad_template_options_are_explained(conn, trip):
    with pytest.raises(ServiceError, match="climate"):
        packing.add_template(conn, U, trip, {"climate": "tropisch"}, "a", "web")
    with pytest.raises(ServiceError, match="nights"):
        packing.add_template(conn, U, trip, {"nights": -2}, "a", "web")


def test_uncheck_all_and_clear_with_undo(conn, trip):
    for title, done in (("A", True), ("B", True), ("C", False)):
        service.create_item(conn, U, "checklist_item", {"title": title, "is_done": done}, "a", "web", trip)
    reset = packing.uncheck_all(conn, U, trip, "a", "web")
    assert all(not i["is_done"] for i in service.list_items(conn, U, "checklist_item")["items"])
    service.undo_change(conn, U, reset["change_id"], "a", "web")
    assert [i["is_done"] for i in service.list_items(conn, U, "checklist_item")["items"]] == [True, True, False]
    cleared = packing.clear_list(conn, U, trip, "a", "web")
    assert titles(conn) == []
    service.undo_change(conn, U, cleared["change_id"], "a", "web")
    assert titles(conn) == ["A", "B", "C"]


def test_viewers_cannot_change_the_list(conn, trip):
    conn.execute("INSERT INTO people (sub, name, last_seen) VALUES ('v','V','x')")
    service.set_member(conn, U, trip, "v", "viewer")
    with pytest.raises(ServiceError, match="nur ansehen"):
        packing.add_template(conn, "v", trip, {}, "V", "web")
