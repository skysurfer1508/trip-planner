import pytest

from app import route, service
from app.db import connect, init_db
from app.service import ServiceError

U = "u1"
TABLE = {"JPY": 150.0, "EUR": 1.05}      # per 1 CHF


@pytest.fixture()
def conn():
    c = connect(":memory:")
    init_db(c)
    yield c
    c.close()


@pytest.fixture()
def trip(conn):
    return service.create_trip(conn, U, "Japan", "Japan", "2027-07-19", "2027-08-08", currency_code="CHF", travelers=4)


def leg(conn, trip, **fields):
    base = {"from_name": "Tokyo", "from_latitude": 35.68, "from_longitude": 139.77, "to_name": "Osaka", "to_latitude": 34.73,
            "to_longitude": 135.50, "mode": "shinkansen", "currency_code": "JPY"}
    return service.create_item(conn, U, "leg", {**base, **fields}, "Claude", "claude", trip)


def legs(conn, trip):
    return service.list_items(conn, U, "leg", trip)["items"]


def test_the_first_leg_of_a_hop_is_chosen_and_the_others_are_options(conn, trip):
    first = leg(conn, trip, line="Nozomi", price=14720, duration_minutes=150)
    second = leg(conn, trip, hop=1, line="Hikari", price=14720, duration_minutes=170)
    third = leg(conn, trip, hop=1, mode="bus", line="Nachtbus", price=4500, duration_minutes=480)
    assert first["item"]["hop"] == 1 and first["item"]["status"] == "chosen"
    assert second["item"]["status"] == "option" and third["item"]["status"] == "option"


def test_a_leg_without_a_hop_starts_the_next_one(conn, trip):
    leg(conn, trip)
    nxt = leg(conn, trip, from_name="Osaka", to_name="Hiroshima")
    assert nxt["item"]["hop"] == 2 and nxt["item"]["status"] == "chosen"


def test_the_log_says_where_from_and_to(conn, trip):
    leg(conn, trip)
    assert service.list_changes(conn, U, trip)[0]["summary"] == "Etappe hinzugefügt: Tokyo → Osaka"


def test_only_one_leg_per_hop_can_be_chosen_through_the_generic_edits(conn, trip):
    leg(conn, trip, line="Nozomi")
    other = leg(conn, trip, hop=1, line="Hikari")["id"]
    with pytest.raises(ServiceError, match="schon eine Etappe gewählt"):
        service.update_item(conn, U, "leg", other, {"status": "chosen"}, "a", "web")
    with pytest.raises(ServiceError, match="schon eine Etappe gewählt"):
        leg(conn, trip, hop=1, status="booked")
    with pytest.raises(ServiceError, match="status"):
        service.update_item(conn, U, "leg", other, {"status": "vielleicht"}, "a", "web")


def test_choose_leg_swaps_the_choice_and_undo_restores_it(conn, trip):
    nozomi = leg(conn, trip, line="Nozomi")["id"]
    hikari = leg(conn, trip, hop=1, line="Hikari")["id"]
    done = route.choose_leg(conn, U, hikari, "Mama", "web")
    status = {l["line"]: l["status"] for l in legs(conn, trip)}
    assert status == {"Nozomi": "option", "Hikari": "chosen"}
    service.undo_change(conn, U, done["change_id"], "Mama", "web")
    assert {l["line"]: l["status"] for l in legs(conn, trip)} == {"Nozomi": "chosen", "Hikari": "option"}
    assert nozomi != hikari


def test_a_booked_leg_stays_booked_when_chosen_again(conn, trip):
    first = leg(conn, trip, line="Nozomi")["id"]
    service.update_item(conn, U, "leg", first, {"status": "booked"}, "a", "web")
    route.choose_leg(conn, U, first, "a", "web")
    assert legs(conn, trip)[0]["status"] == "booked"


def test_hops_can_swap_places(conn, trip):
    leg(conn, trip, to_name="Kyoto")
    leg(conn, trip, from_name="Kyoto", to_name="Osaka")
    leg(conn, trip, hop=2, mode="bus", from_name="Kyoto", to_name="Osaka", line="Bus")
    done = route.shift_hop(conn, U, trip, 1, +1, "a", "web")
    assert {(l["to_name"], l["hop"]) for l in legs(conn, trip)} == {("Kyoto", 2), ("Osaka", 1)}
    service.undo_change(conn, U, done["change_id"], "a", "web")
    assert {(l["to_name"], l["hop"]) for l in legs(conn, trip)} == {("Kyoto", 1), ("Osaka", 2)}
    assert route.shift_hop(conn, U, trip, 1, -1, "a", "web")["change_id"] is None        # already first
    with pytest.raises(ServiceError, match="nicht gefunden"):
        route.shift_hop(conn, U, trip, 9, +1, "a", "web")


def data(conn, trip):
    return service.trip_data(conn, U, trip)


def test_summary_adds_up_the_chosen_ways_only(conn, trip):
    leg(conn, trip, line="Nozomi", price=15000, duration_minutes=150)
    leg(conn, trip, hop=1, line="Nachtbus", mode="bus", price=3000, duration_minutes=480)
    leg(conn, trip, from_name="Osaka", to_name="Hiroshima", to_latitude=34.4, to_longitude=132.5, line="Sakura", price=9000, duration_minutes=90)
    d = data(conn, trip)
    s = route.summarize(d["trip"], d["legs"], TABLE)
    assert s["total_minutes"] == 240 and s["decided"] == 2 and s["travelers"] == 4
    assert s["price_per_person"] == pytest.approx(160.0)          # (15000 + 9000) / 150
    assert s["price_for_group"] == pytest.approx(640.0)
    assert [h["to_name"] for h in s["hops"]] == ["Osaka", "Hiroshima"]
    assert [o["line"] for o in s["hops"][0]["options"]] == ["Nachtbus"] and s["hops"][0]["chosen"]["group_price"] == pytest.approx(400.0)
    assert [p["name"] for p in s["places"]] == ["Tokyo", "Osaka", "Hiroshima"] and s["warnings"] == []


def test_summary_warns_about_broken_chains_open_choices_and_unknown_prices(conn, trip):
    leg(conn, trip, to_name="Kyoto", price=100, currency_code="XYZ")                  # a currency nobody knows
    leg(conn, trip, from_name="Osaka", to_name="Hiroshima")                           # starts where the last one did not end
    leg(conn, trip, hop=3, from_name="Hiroshima", to_name="Fukuoka", status="option")  # nothing chosen for this hop
    d = data(conn, trip)
    warnings = route.summarize(d["trip"], d["legs"], TABLE)["warnings"]
    assert any("beginnt in Osaka, der vorige endet in Kyoto" in w for w in warnings)
    assert any("Noch keine Wahl für Abschnitt 3" in w for w in warnings)
    assert any("nicht umrechnen" in w for w in warnings)


def test_summary_of_an_empty_route(conn, trip):
    d = data(conn, trip)
    s = route.summarize(d["trip"], d["legs"], TABLE)
    assert s["hops"] == [] and s["total_minutes"] == 0 and s["places"] == [] and s["warnings"] == []


def test_the_number_of_travelers_is_a_trip_setting(conn, trip):
    assert service.trip_data(conn, U, trip)["trip"]["travelers"] == 4
    service.update_trip(conn, U, trip, {"travelers": 2}, "a", "web")
    assert service.trip_data(conn, U, trip)["trip"]["travelers"] == 2
    with pytest.raises(ServiceError, match="travelers"):
        service.update_trip(conn, U, trip, {"travelers": 0}, "a", "web")


def test_viewers_cannot_change_the_route_and_strangers_see_nothing(conn, trip):
    first = leg(conn, trip)["id"]
    conn.execute("INSERT INTO people (sub, name, last_seen) VALUES ('v','V','x'), ('s','S','x')")
    service.set_member(conn, U, trip, "v", "viewer")
    with pytest.raises(ServiceError, match="nur ansehen"):
        route.choose_leg(conn, "v", first, "V", "web")
    with pytest.raises(ServiceError, match="nicht gefunden"):
        route.shift_hop(conn, "s", trip, 1, 1, "S", "web")


# MARK: JR Pass and ideas along the way

def _hops(conn, trip, table=TABLE):
    return route.summarize(service.trip_data(conn, U, trip)["trip"], service.trip_data(conn, U, trip)["legs"], table)


def test_the_pass_comparison_adds_up_only_covered_chosen_legs(conn, trip):
    from app import passes
    leg(conn, trip, line="Hikari", price=14000, pass_ok=True, departure="2027-07-20T09:00")
    leg(conn, trip, hop=2, from_name="Osaka", to_name="Hiroshima", line="Sakura", price=10000, pass_ok=True, departure="2027-07-23T09:00")
    leg(conn, trip, hop=3, from_name="Hiroshima", to_name="Tokyo", line="Nozomi", price=19000, pass_ok=False, departure="2027-07-30T09:00")
    summary = _hops(conn, trip)
    result = passes.compare(service.trip_data(conn, U, trip)["trip"], summary["hops"], TABLE)
    assert result["covered"] == 2 and result["not_covered_paid"] == 1
    assert result["span_days"] == 4 and result["best_days"] == 7
    assert result["singles_per_person"] == round(24000 / 150, 2)
    assert result["verdict"] == "singles"              # 50 000 JPY for the pass is far more than 24 000 of tickets
    assert all(o["saves_for_group"] < 0 for o in result["options"])


def test_the_pass_wins_when_the_tickets_cost_more(conn, trip):
    from app import passes
    for i, price in enumerate((30000, 30000, 30000), start=1):
        leg(conn, trip, hop=i, from_name=f"A{i}", to_name=f"B{i}", price=price, pass_ok=True, departure=f"2027-07-2{i}T09:00")
    result = passes.compare(service.trip_data(conn, U, trip)["trip"], _hops(conn, trip)["hops"], TABLE)
    assert result["verdict"] == "pass" and result["best_days"] == 7


def test_the_pass_says_what_is_missing(conn, trip):
    from app import passes
    leg(conn, trip, price=14000)
    result = passes.compare(service.trip_data(conn, U, trip)["trip"], _hops(conn, trip)["hops"], TABLE)
    assert result["covered"] == 0 and result["verdict"] is None and result["notes"]


def test_ideas_along_the_way_skip_the_end_cities_and_the_rejected(conn, trip):
    # Tokyo (35.68, 139.77) to Osaka (34.73, 135.50); Hamamatsu lies about on the line, Kyoto-ish 1000 km off is not.
    leg(conn, trip)
    def idea(name, lat, lon, **kw):
        return service.create_item(conn, U, "place", {"name": name, "latitude": lat, "longitude": lon, **kw}, "Claude", "claude", trip)["item"]
    idea("Hamamatsu", 34.70, 137.73)
    idea("Nagoya Burg", 35.19, 136.90)
    idea("In Tokyo", 35.70, 139.75)
    idea("Hokkaido", 43.06, 141.35)
    idea("Abgelehnt", 34.80, 137.50, decision="Nein")
    data = service.trip_data(conn, U, trip)
    summary = route.summarize(data["trip"], data["legs"], TABLE)
    route.nearby(data["places"], summary["hops"], lambda l: None)
    names = [p["name"] for p in summary["hops"][0]["nearby"]]
    assert "Nagoya Burg" in names and "In Tokyo" not in names and "Hokkaido" not in names and "Abgelehnt" not in names
    assert names == sorted(names, key=lambda n: [p["along"] for p in summary["hops"][0]["nearby"] if p["name"] == n][0])


def test_distance_to_a_line():
    d, along = route.distance_to_line((35.0, 136.0), [(35.0, 135.0), (35.0, 137.0)])
    assert d < 0.01 and 0.45 < along < 0.55
    d, _ = route.distance_to_line((36.0, 136.0), [(35.0, 135.0), (35.0, 137.0)])
    assert 105 < d < 115
