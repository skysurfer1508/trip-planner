import base64
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from starlette.testclient import TestClient

from app import service
from app.db import db
from app.main import app
from app.mcp_server import AuthentikTokenVerifier

MCP_HEADERS = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}


@pytest.fixture(scope="module")
def client():
    with TestClient(app, base_url="https://trip.example.org", client=("127.0.0.1", 5000)) as c:
        yield c


@pytest.fixture(scope="module")
def trip_id(client):
    with db() as conn:
        return service.create_trip(conn, "dev", "Japan 2027", "Japan", "2027-07-19", "2027-08-08")


def logged_in(client):
    assert client.get("/login?next=/", follow_redirects=False).status_code == 303


def rpc(client, path, method, params=None, headers=None, id_=1):
    body = {"jsonrpc": "2.0", "id": id_, "method": method, "params": params or {}}
    return client.post(path, json=body, headers={**MCP_HEADERS, **(headers or {})})


# MARK: Website API

def test_api_needs_login(client):
    assert client.get("/api/me").status_code == 401
    assert client.get("/", follow_redirects=False).status_code == 303


def test_login_and_read(client, trip_id):
    logged_in(client)
    assert client.get("/api/me").json()["name"] == "Dev"
    assert client.get("/api/trips").json()[0]["name"] == "Japan 2027"
    data = client.get(f"/api/trips/{trip_id}/data").json()
    assert data["trip"]["id"] == trip_id and data["places"] == []


def test_changes_need_the_client_header(client, trip_id):
    logged_in(client)
    with db() as conn:
        item = service.create_item(conn, "dev", "checklist_item", {"title": "Pass"}, "Dev", "web", trip_id)["id"]
    url = f"/api/items/checklist_item/{item}"
    assert client.patch(url, json={"data": {"is_done": True}}).status_code == 403
    done = client.patch(url, json={"data": {"is_done": True}}, headers={"X-Trip-Client": "1"})
    assert done.status_code == 200 and done.json()["item"]["is_done"] is True
    log = client.get(f"/api/trips/{trip_id}/data").json()["log"][0]
    assert log["via"] == "web" and log["actor"] == "Dev"
    undone = client.post(f"/api/changes/{done.json()['change_id']}/undo", headers={"X-Trip-Client": "1"})
    assert undone.status_code == 200


def test_bad_patch_is_a_400_with_a_reason(client, trip_id):
    logged_in(client)
    with db() as conn:
        item = service.create_item(conn, "dev", "place", {"name": "X"}, "Dev", "web", trip_id)["id"]
    reply = client.patch(f"/api/items/place/{item}", json={"data": {"prio": "Vielleicht"}}, headers={"X-Trip-Client": "1"})
    assert reply.status_code == 400 and "prio" in reply.json()["detail"]


def test_revision_moves_with_changes(client, trip_id):
    logged_in(client)
    first = client.get("/api/revision").json()["revision"]
    with db() as conn:
        service.create_item(conn, "dev", "place", {"name": "Y"}, "Dev", "web", trip_id)
    assert client.get("/api/revision").json()["revision"] > first


# MARK: Connector

def test_oauth_door_answers_401_with_pointer_to_metadata(client):
    reply = rpc(client, "/mcp", "tools/list")
    assert reply.status_code == 401
    header = reply.headers["www-authenticate"]
    assert "resource_metadata" in header and "/.well-known/oauth-protected-resource" in header


def test_protected_resource_metadata_names_authentik(client):
    meta = client.get("/.well-known/oauth-protected-resource/mcp").json()
    assert meta["resource"].rstrip("/") == "https://trip.example.org/mcp"
    assert meta["authorization_servers"][0].startswith("https://auth.example.org/application/o/trip-claude")


def test_wrong_secret_path_is_not_found(client):
    assert rpc(client, "/mcp-secret/wrong", "tools/list").status_code == 404


def test_secret_path_lists_tools(client, trip_id):
    reply = rpc(client, "/mcp-secret/s3cret-value-for-tests", "tools/list")
    assert reply.status_code == 200
    names = {t["name"] for t in reply.json()["result"]["tools"]}
    assert {"list_trips", "list_items", "create_item", "update_item", "remove_item", "undo_change", "get_plan"} <= names


def call(client, tool, arguments):
    reply = rpc(client, "/mcp-secret/s3cret-value-for-tests", "tools/call", {"name": tool, "arguments": arguments})
    assert reply.status_code == 200, reply.text
    return reply.json()["result"]


def test_claude_creates_a_place_the_website_then_shows(client, trip_id):
    logged_in(client)
    result = call(client, "create_item", {"entity": "place", "acting_member": "dev",
                                          "data": {"name": "Himeji-Burg", "region": "Kansai", "prio": "Gerne"}})
    assert not result.get("isError"), result
    shown = client.get(f"/api/trips/{trip_id}/data").json()
    assert any(p["name"] == "Himeji-Burg" for p in shown["places"])
    last = shown["log"][0]
    assert last["via"] == "claude" and last["actor"] == "Dev"  # "dev" matched the known person case-insensitively


def test_tool_errors_are_readable(client, trip_id):
    result = call(client, "create_item", {"entity": "place", "acting_member": "Dev", "data": {"name": "Z", "prioritaet": "Muss"}})
    assert result["isError"] is True
    assert "prioritaet" in result["content"][0]["text"]


def test_missing_actor_is_refused(client, trip_id):
    result = call(client, "create_item", {"entity": "place", "acting_member": "  ", "data": {"name": "Z"}})
    assert result["isError"] is True and "acting_member" in result["content"][0]["text"]


# MARK: Token check (a key pair made here stands in for Authentik's)

class FakeKey:
    def __init__(self, key):
        self.key = key


class FakeJwks:
    def __init__(self, public):
        self.public = public

    def get_signing_key_from_jwt(self, _token):
        return FakeKey(self.public)


@pytest.fixture(scope="module")
def keys():
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return private, private.public_key()


def verifier(public):
    v = AuthentikTokenVerifier("https://auth.example.org/application/o/trip-claude/", "claude-client")
    v._jwks, v._expected_issuer, v._loaded_at = FakeJwks(public), "https://auth.example.org/application/o/trip-claude/", time.time()
    return v


def token(private, **overrides):
    claims = {"iss": "https://auth.example.org/application/o/trip-claude/", "aud": "claude-client", "sub": "u1",
              "exp": int(time.time()) + 600, "scope": "openid email"}
    claims.update(overrides)
    return jwt.encode(claims, private, algorithm="RS256")


@pytest.mark.asyncio
async def test_good_token_is_accepted(keys):
    private, public = keys
    access = await verifier(public).verify_token(token(private))
    assert access and access.subject == "u1" and "email" in access.scopes


@pytest.mark.asyncio
@pytest.mark.parametrize("override", [{"aud": "someone-else"}, {"iss": "https://evil.example/"}, {"exp": 1}])
async def test_bad_tokens_are_rejected(keys, override):
    private, public = keys
    assert await verifier(public).verify_token(token(private, **override)) is None


@pytest.mark.asyncio
async def test_token_signed_by_another_key_is_rejected(keys):
    _, public = keys
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    assert await verifier(public).verify_token(token(other)) is None


def test_key_download_sends_our_own_user_agent(monkeypatch):
    """Cloudflare answers urllib's default User-Agent with 403, which once made every Claude sign-in fail."""
    seen = {}

    class Reply:
        def raise_for_status(self):
            return self

        def json(self):
            return {"issuer": "https://auth.example.org/application/o/trip-claude/", "jwks_uri": "https://auth.example.org/jwks/"}

    monkeypatch.setattr("app.mcp_server.httpx.get", lambda url, **kw: seen.update(discovery=kw.get("headers")) or Reply())

    class FakeClient:
        def __init__(self, uri, **kw):
            seen["jwks"] = kw.get("headers")

    monkeypatch.setattr("app.mcp_server.jwt.PyJWKClient", FakeClient)
    AuthentikTokenVerifier("https://auth.example.org/application/o/trip-claude/", "claude-client")._client()
    assert "trip-web" in seen["discovery"]["User-Agent"] and "trip-web" in seen["jwks"]["User-Agent"]


# MARK: Who sees which trip

def test_trips_of_other_people_are_invisible_on_the_web_and_to_claude(client, trip_id):
    with db() as conn:
        service.touch_person(conn, "u9", "Fremd")
        hidden = service.create_trip(conn, "u9", "Geheim", "", "2030-01-01", "2030-01-02")
        service.create_item(conn, "u9", "place", {"name": "Versteck"}, "Fremd", "web", hidden)
    logged_in(client)
    assert all(t["id"] != hidden for t in client.get("/api/trips").json())
    assert client.get(f"/api/trips/{hidden}/data").status_code == 404
    listing = call(client, "list_trips", {})
    assert "Geheim" not in listing["content"][0]["text"]
    peek = call(client, "list_items", {"entity": "place", "trip_id": hidden})
    assert peek["isError"] is True and "nicht gefunden" in peek["content"][0]["text"]
    write = call(client, "create_item", {"entity": "place", "trip_id": hidden, "acting_member": "Dev", "data": {"name": "Einbruch"}})
    assert write["isError"] is True


def test_sharing_through_the_api(client, trip_id):
    with db() as conn:
        service.touch_person(conn, "u2", "Papa", "papa@example.org", "papa")
    logged_in(client)
    header = {"X-Trip-Client": "1"}
    assert client.put(f"/api/trips/{trip_id}/members/u2", json={"role": "editor"}).status_code == 403  # header missing
    added = client.put(f"/api/trips/{trip_id}/members/u2", json={"role": "editor"}, headers=header)
    assert added.status_code == 200 and {m["name"] for m in added.json()["members"]} >= {"Dev", "Papa"}
    assert [p["name"] for p in client.get("/api/people?q=pap").json()] == ["Papa"]
    assert client.put(f"/api/trips/{trip_id}/members/u2", json={"role": "chef"}, headers=header).status_code == 400
    assert client.delete(f"/api/trips/{trip_id}/members/u2", headers=header).status_code == 200
    assert client.delete(f"/api/trips/{trip_id}/members/dev", headers=header).status_code == 400  # last owner


# MARK: Trips, import and export through the API

HEADER = {"X-Trip-Client": "1"}


def test_trip_lifecycle_through_the_api(client):
    logged_in(client)
    assert client.post("/api/trips", json={"name": "X"}).status_code == 403  # header missing
    bad = client.post("/api/trips", json={"name": "Nebenan", "start_date": "2027-01-01", "end_date": "2026-01-01"}, headers=HEADER)
    assert bad.status_code == 400 and "Ende" in bad.json()["detail"]
    made = client.post("/api/trips", json={"name": "Wien", "destination": "Wien", "start_date": "2027-03-01", "end_date": "2027-03-03",
                                           "currency_code": "EUR"}, headers=HEADER)
    trip = made.json()["trip_id"]
    data = client.get(f"/api/trips/{trip}/data").json()
    assert [d["date"] for d in data["days"]] == ["2027-03-01", "2027-03-02", "2027-03-03"] and data["role"] == "owner"
    changed = client.patch(f"/api/trips/{trip}", json={"data": {"end_date": "2027-03-04", "budget": 500}}, headers=HEADER)
    assert changed.status_code == 200 and changed.json()["budget"] == 500
    assert len(client.get(f"/api/trips/{trip}/data").json()["days"]) == 4
    assert client.delete(f"/api/trips/{trip}", headers=HEADER).status_code == 200
    assert client.get(f"/api/trips/{trip}/data").status_code == 404


def test_import_preview_then_import_then_export(client):
    from tests.test_archive import WARSAW
    logged_in(client)
    shown = client.post("/api/import", json={"archive": WARSAW, "time_zone": "Europe/Zurich", "preview": True}, headers=HEADER)
    assert shown.status_code == 200 and shown.json()["trips"][0]["sample"][0]["time"] == "09:30"
    done = client.post("/api/import", json={"archive": WARSAW, "time_zone": "Europe/Zurich"}, headers=HEADER)
    trip = done.json()["trips"][0]["trip_id"]
    assert client.get(f"/api/trips/{trip}/data").json()["trip"]["name"] == "Warschau"
    file = client.get(f"/api/trips/{trip}/export.tripplanner?tz=Europe/Zurich")
    assert file.status_code == 200 and 'filename="Warschau.tripplanner"' in file.headers["content-disposition"]
    assert file.json()["version"] == 1 and file.json()["trips"][0]["name"] == "Warschau"


def test_import_errors_are_readable(client):
    logged_in(client)
    bad = client.post("/api/import", json={"archive": {"hallo": 1}, "time_zone": "Europe/Zurich"}, headers=HEADER)
    assert bad.status_code == 400 and "keine Trip-Planner-Datei" in bad.json()["detail"]
    zone = client.post("/api/import", json={"archive": {"version": 1, "trips": []}, "time_zone": "Nirgendwo/Stadt"}, headers=HEADER)
    assert zone.status_code == 400 and "Zeitzone" in zone.json()["detail"]
    assert client.get("/api/trips/unbekannt/export.tripplanner").status_code == 404


def test_place_search_needs_login_and_passes_the_bias(client, monkeypatch):
    from app import places
    seen = {}

    async def fake(params):
        seen.update(params)
        return {"features": [{"geometry": {"coordinates": [139.8, 35.7]}, "properties": {"name": "Senso-ji", "osm_key": "amenity", "osm_value": "place_of_worship"}}]}

    monkeypatch.setattr(places, "_fetch", fake)
    monkeypatch.setattr(places, "MIN_INTERVAL", 0.0)
    places._cache.clear()
    anonymous = TestClient(app, base_url="https://trip.example.org")
    assert anonymous.get("/api/search/places?q=Senso-ji").status_code == 401
    logged_in(client)
    found = client.get("/api/search/places?q=Senso-ji&near=35.7,139.8").json()
    assert found[0]["name"] == "Senso-ji" and found[0]["category_raw"] == "sight" and seen["lat"] == 35.7
    seen.clear()
    client.get("/api/search/places?q=Zweiter&near=quatsch")           # a bad bias is ignored, not an error
    assert "lat" not in seen


def test_place_search_reports_an_unreachable_service(client, monkeypatch):
    from app import places

    async def broken(params):
        raise RuntimeError("down")

    monkeypatch.setattr(places, "_fetch", broken)
    places._cache.clear()
    logged_in(client)
    assert client.get("/api/search/places?q=Irgendwo").status_code == 502


def test_items_can_be_created_changed_and_removed_through_the_api(client):
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Items", "start_date": "2027-05-01", "end_date": "2027-05-02"}, headers=HEADER).json()["trip_id"]
    url = f"/api/trips/{trip}/items/place"
    assert client.post(url, json={"data": {"name": "X"}}).status_code == 403                         # header missing
    made = client.post(url, json={"data": {"name": "Schloss", "prio": "Muss", "latitude": 52.2, "longitude": 21.0}}, headers=HEADER)
    assert made.status_code == 200 and made.json()["item"]["has_coordinate"] is True
    place = made.json()["id"]
    assert client.post(url, json={"data": {"name": "Y", "prio": "Vielleicht"}}, headers=HEADER).status_code == 400
    assert client.patch(f"/api/items/place/{place}", json={"data": {"decision": "Ja"}}, headers=HEADER).status_code == 200
    assert client.delete(f"/api/items/place/{place}").status_code == 403
    assert client.delete(f"/api/items/place/{place}", headers=HEADER).status_code == 200
    assert client.get(f"/api/trips/{trip}/data").json()["places"] == []
    assert client.post("/api/trips/unbekannt/items/place", json={"data": {"name": "Z"}}, headers=HEADER).status_code == 400


# MARK: Day plan operations through the API

def test_the_day_plan_operations_work_through_the_api_and_undo(client):
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Plan", "start_date": "2027-04-01", "end_date": "2027-04-02", "phase": "building"}, headers=HEADER).json()["trip_id"]
    days = {d["date"]: d["id"] for d in client.get(f"/api/trips/{trip}/data").json()["days"]}
    ids = []
    for name in ("A", "B", "C"):
        made = client.post(f"/api/trips/{trip}/items/stop", json={"data": {"day_id": days["2027-04-01"], "name": name, "planned_time": "2027-04-01T09:00"}}, headers=HEADER)
        assert made.status_code == 200
        ids.append(made.json()["id"])

    def order():
        data = client.get(f"/api/trips/{trip}/data").json()
        return {d["date"]: [s["name"] for s in data["stops"] if s["day_id"] == d["id"]] for d in data["days"]}

    assert client.post(f"/api/stops/{ids[0]}/move", json={"index": 2}).status_code == 403                     # header missing
    moved = client.post(f"/api/stops/{ids[0]}/move", json={"index": 2}, headers=HEADER)
    assert moved.status_code == 200 and order()["2027-04-01"] == ["B", "C", "A"]
    assert client.post(f"/api/changes/{moved.json()['change_id']}/undo", headers=HEADER).status_code == 200
    assert order()["2027-04-01"] == ["A", "B", "C"]

    assert client.post(f"/api/stops/{ids[1]}/move", json={"day_id": days["2027-04-02"]}, headers=HEADER).status_code == 200
    assert order() == {"2027-04-01": ["A", "C"], "2027-04-02": ["B"]}
    assert client.post(f"/api/stops/{ids[2]}/duplicate", headers=HEADER).status_code == 200
    assert order()["2027-04-01"] == ["A", "C", "C"]
    assert client.post(f"/api/days/{days['2027-04-01']}/copy", json={"to_day_id": days["2027-04-02"]}, headers=HEADER).json()["copied"] == 3
    assert client.post(f"/api/days/{days['2027-04-02']}/sort", headers=HEADER).status_code == 200
    assert client.post(f"/api/days/{days['2027-04-01']}/retime", json={"start": "10:30"}, headers=HEADER).json()["start"] == "10:30"
    bad = client.post(f"/api/days/{days['2027-04-01']}/retime", json={"start": "bald"}, headers=HEADER)
    assert bad.status_code == 400 and "09:30" in bad.json()["detail"]
    no_position = client.post(f"/api/days/{days['2027-04-01']}/optimize", headers=HEADER)
    assert no_position.status_code == 400 and "Position" in no_position.json()["detail"]
    assert client.post(f"/api/trips/{trip}/booking-stops", headers=HEADER).json()["added"] == 0
    place = client.post(f"/api/trips/{trip}/items/place", json={"data": {"name": "Schloss"}}, headers=HEADER).json()["id"]
    assert client.post(f"/api/places/{place}/to-day", json={"day_id": days["2027-04-02"]}, headers=HEADER).status_code == 200
    assert order()["2027-04-02"][-1] == "Schloss"
    assert client.post(f"/api/places/{place}/to-day", json={"day_id": days["2027-04-02"]}, headers=HEADER).status_code == 400   # already there
    assert client.post("/api/stops/unbekannt/move", json={"index": 0}, headers=HEADER).status_code == 400


def test_budget_packing_endpoints(client, monkeypatch):
    from app import rates
    rates._cache.clear()

    async def fake(base):
        return {"result": "success", "rates": {"CHF": 1.0, "EUR": 1.05}}

    monkeypatch.setattr(rates, "_fetch", fake)
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Geld", "start_date": "2027-06-01", "end_date": "2027-06-02", "currency_code": "CHF", "budget": 200}, headers=HEADER).json()["trip_id"]
    client.post(f"/api/trips/{trip}/items/expense", json={"data": {"title": "Essen", "amount": 105, "currency_code": "EUR", "category_raw": "food", "date": "2027-06-01"}}, headers=HEADER)
    summary = client.get(f"/api/trips/{trip}/budget").json()
    assert summary["spent"] == 100.0 and summary["left"] == 100.0 and summary["by_category"] == [{"category": "food", "total": 100.0}]
    assert client.get("/api/trips/unbekannt/budget").status_code == 404

    added = client.post(f"/api/trips/{trip}/packing-template", json={"climate": "cold"}, headers=HEADER)
    assert added.status_code == 200 and added.json()["added"] > 20
    assert client.post(f"/api/trips/{trip}/packing-template", json={"climate": "tropisch"}, headers=HEADER).status_code == 400
    assert client.post(f"/api/trips/{trip}/packing/reset", headers=HEADER).status_code == 200
    assert client.post(f"/api/trips/{trip}/packing/clear", headers=HEADER).status_code == 200
    assert client.get(f"/api/trips/{trip}/data").json()["checklist"] == []


def test_text_and_calendar_downloads(client):
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Wien Städtereise", "start_date": "2027-03-01", "end_date": "2027-03-01", "time_zone": "Europe/Vienna"}, headers=HEADER).json()["trip_id"]
    empty = client.get(f"/api/trips/{trip}/export.ics")
    assert empty.status_code == 400 and "Uhrzeit" in empty.json()["detail"]
    day = client.get(f"/api/trips/{trip}/data").json()["days"][0]["id"]
    client.post(f"/api/trips/{trip}/items/stop", json={"data": {"day_id": day, "name": "Prater", "planned_time": "2027-03-01T10:00"}}, headers=HEADER)
    text = client.get(f"/api/trips/{trip}/export.txt")
    assert text.status_code == 200 and "• 10:00 Prater" in text.text and 'filename="Wien Stadtereise.txt"' in text.headers["content-disposition"]
    ics = client.get(f"/api/trips/{trip}/export.ics")
    assert ics.status_code == 200 and ics.headers["content-type"].startswith("text/calendar")
    assert "DTSTART:20270301T090000Z" in ics.text                           # 10:00 in Vienna (UTC+1 in March)
    assert client.get(f"/api/trips/{trip}/export.ics?tz=Mars/Base").status_code == 400
    assert client.get("/api/trips/unbekannt/export.txt").status_code == 404


def test_claude_can_plan_days_like_the_website(client):
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Claude plant", "start_date": "2027-09-01", "end_date": "2027-09-02"}, headers=HEADER).json()["trip_id"]
    days = {d["date"]: d["id"] for d in client.get(f"/api/trips/{trip}/data").json()["days"]}
    names = {r["name"] for r in rpc(client, "/mcp-secret/s3cret-value-for-tests", "tools/list").json()["result"]["tools"]}
    assert {"update_trip", "move_stop", "arrange_day", "put_place_on_day", "add_booking_stops", "suggest_packing_list"} <= names

    swap = call(client, "update_trip", {"trip_id": trip, "acting_member": "Dev", "data": {"phase": "building", "budget": 500}})
    assert not swap.get("isError"), swap
    assert client.get(f"/api/trips/{trip}/data").json()["trip"]["phase"] == "building"
    ids = [call(client, "create_item", {"entity": "stop", "trip_id": trip, "acting_member": "Dev", "data": {"day_id": days["2027-09-01"], "name": n}})["structuredContent"]["id"] for n in "AB"]
    assert not call(client, "move_stop", {"stop_id": ids[0], "index": 1, "acting_member": "Dev"}).get("isError")
    data = client.get(f"/api/trips/{trip}/data").json()
    assert [s["name"] for s in sorted(data["stops"], key=lambda s: s["sort_order"])] == ["B", "A"]
    copied = call(client, "arrange_day", {"day_id": days["2027-09-01"], "action": "copy_to", "to_day_id": days["2027-09-02"], "acting_member": "Dev"})
    assert copied["structuredContent"]["copied"] == 2
    bad = call(client, "arrange_day", {"day_id": days["2027-09-01"], "action": "copy_to", "acting_member": "Dev"})
    assert bad["isError"] is True and "to_day_id" in bad["content"][0]["text"]
    packed = call(client, "suggest_packing_list", {"trip_id": trip, "acting_member": "Dev", "climate": "cold"})
    assert packed["structuredContent"]["added"] > 20


# MARK: The route

def test_the_route_through_the_api_and_the_connector(client, monkeypatch):
    from app import rates
    rates._cache.clear()

    async def fake(base):
        return {"result": "success", "rates": {"CHF": 1.0, "JPY": 150.0}}

    monkeypatch.setattr(rates, "_fetch", fake)
    logged_in(client)
    trip = client.post("/api/trips", json={"name": "Route", "start_date": "2027-07-19", "end_date": "2027-07-25", "currency_code": "CHF", "travelers": 4}, headers=HEADER).json()["trip_id"]
    base = {"from_name": "Tokyo", "from_latitude": 35.68, "from_longitude": 139.77, "to_name": "Osaka", "to_latitude": 34.73, "to_longitude": 135.5, "currency_code": "JPY"}
    nozomi = client.post(f"/api/trips/{trip}/items/leg", json={"data": {**base, "mode": "shinkansen", "line": "Nozomi", "price": 15000, "duration_minutes": 150}}, headers=HEADER).json()["id"]
    bus = client.post(f"/api/trips/{trip}/items/leg", json={"data": {**base, "hop": 1, "mode": "bus", "line": "Nachtbus", "price": 3000, "duration_minutes": 480}}, headers=HEADER).json()["id"]

    summary = client.get(f"/api/trips/{trip}/route").json()
    assert summary["hops"][0]["chosen"]["line"] == "Nozomi" and summary["price_per_person"] == 100.0 and summary["price_for_group"] == 400.0
    assert client.post(f"/api/legs/{bus}/choose").status_code == 403                       # header missing
    chosen = client.post(f"/api/legs/{bus}/choose", headers=HEADER)
    assert chosen.status_code == 200
    assert client.get(f"/api/trips/{trip}/route").json()["hops"][0]["chosen"]["line"] == "Nachtbus"
    assert client.post(f"/api/changes/{chosen.json()['change_id']}/undo", headers=HEADER).status_code == 200
    assert client.get(f"/api/trips/{trip}/route").json()["hops"][0]["chosen"]["line"] == "Nozomi"
    assert client.get(f"/api/trips/{trip}/budget").json()["planned_travel"] == 400.0
    assert client.post(f"/api/trips/{trip}/hops/1/move", json={"delta": 1}, headers=HEADER).json()["change_id"] is None
    assert client.get("/api/trips/unbekannt/route").status_code == 404

    names = {t["name"] for t in rpc(client, "/mcp-secret/s3cret-value-for-tests", "tools/list").json()["result"]["tools"]}
    assert {"route_summary", "choose_leg", "move_hop"} <= names
    said = call(client, "route_summary", {"trip_id": trip})
    assert said["structuredContent"]["price_for_group"] == 400.0
    picked = call(client, "choose_leg", {"leg_id": bus, "acting_member": "Dev"})
    assert not picked.get("isError") and nozomi != bus


# MARK: iPhone app (sign-in handshake and sync)

def test_sign_in_handshake_gives_the_app_a_session(client):
    from app.native_auth import challenge_of
    verifier = base64.urlsafe_b64encode(b"v" * 32).rstrip(b"=").decode()
    challenge = challenge_of(verifier)
    assert client.get("/app/login?challenge=bad", follow_redirects=False).status_code == 400
    login = client.get(f"/app/login?challenge={challenge}", follow_redirects=False)
    assert login.status_code == 303 and login.headers["location"] == "/login?next=/app/done"
    assert client.get("/login?next=/app/done", follow_redirects=False).status_code == 303    # local dev login
    done = client.get("/app/done", follow_redirects=False)
    assert done.status_code == 303 and done.headers["location"].startswith("tripplanner://auth?code=")
    code = done.headers["location"].split("code=", 1)[1]
    assert client.get("/api/me").status_code == 401                          # the carrier session was cleared
    assert client.post("/app/exchange", data={"code": code, "verifier": "x" * 43}).status_code == 400      # wrong verifier
    ok = client.post("/app/exchange", data={"code": code, "verifier": verifier})
    assert ok.status_code == 204 and client.get("/api/me").status_code == 200
    assert client.post("/app/exchange", data={"code": code, "verifier": verifier}).status_code == 400      # single use


def test_the_sync_endpoint(client):
    assert client.get("/login?next=/", follow_redirects=False).status_code == 303
    H = {"X-Trip-Client": "1"}
    assert client.post("/api/sync", json={}).status_code == 403
    snapshot = {"trip": {"name": "HTTP", "destination": "", "start_date": "2026-05-01", "end_date": "2026-05-02"}, "days": [], "stops": [], "expenses": [], "checklist": [], "bookings": []}
    created = client.post("/api/sync", json={"snapshot": snapshot}, headers=H)
    assert created.status_code == 200
    trip_id = created.json()["trip_id"]
    again = client.post("/api/sync", json={"trip_id": trip_id, "since": 0, "changes": []}, headers=H)
    assert again.status_code == 200 and again.json()["changes"][0]["kind"] == "trip"
    assert client.post("/api/sync", json={"trip_id": trip_id, "since": -1, "changes": []}, headers=H).status_code == 400
    assert client.post("/api/sync", json={"trip_id": "nope", "since": 0, "changes": []}, headers=H).status_code == 400


def test_idea_pictures_need_login_and_trip_membership(client, trip_id, monkeypatch, tmp_path):
    from app import photos
    image = tmp_path / "x.jpg"
    image.write_bytes(b"\xff\xd8fake")
    looked_up = []

    async def fake(name, region, latitude, longitude):
        looked_up.append((name, region, latitude, longitude))
        return (image, {"title": "Sensō-ji", "page": "https://en.wikipedia.org/wiki/Sens%C5%8D-ji", "type": "image/jpeg"}) if name == "Senso-ji" else None

    monkeypatch.setattr(photos, "photo", fake)
    logged_in(client)
    with db() as conn:
        shown = service.create_item(conn, "dev", "place", {"name": "Senso-ji", "region": "Tokyo", "latitude": 35.7, "longitude": 139.8}, "Dev", "web", trip_id)
        plain = service.create_item(conn, "dev", "place", {"name": "Kein Bild"}, "Dev", "web", trip_id)
    place_id, other_id = shown["id"], plain["id"]
    assert TestClient(app, base_url="https://trip.example.org").get(f"/api/places/{place_id}/photo").status_code == 401
    reply = client.get(f"/api/places/{place_id}/photo")
    assert reply.status_code == 200 and reply.content == b"\xff\xd8fake" and reply.headers["content-type"] == "image/jpeg"
    assert looked_up[-1] == ("Senso-ji", "Tokyo", 35.7, 139.8)
    assert client.get(f"/api/places/{place_id}/photo/source").json()["title"] == "Sensō-ji"
    assert client.get(f"/api/places/{other_id}/photo").status_code == 404
    assert looked_up[-1] == ("Kein Bild", "", None, None)          # no position set: nothing to search around
    assert client.get("/api/places/gibtesnicht/photo").status_code == 404


def test_picture_matching_prefers_the_article_that_fits_the_name():
    from app import photos
    assert photos.score("Asakusa mit Senso-ji", "Sensō-ji") >= 0.5
    assert photos.score("Shibuya Crossing", "Shibuya Crossing") > photos.score("Shibuya Crossing", "Shibuya Station")
    assert photos.score("Fushimi Inari", "Tokyo Tower") == 0
