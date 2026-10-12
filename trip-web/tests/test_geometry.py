import pytest

from app import geometry
from app.db import connect, init_db


def test_the_shortest_way_follows_the_given_lines_not_the_straight_line():
    # A track that bends: A -> corner -> B. Another, longer detour exists too.
    ways = [[(35.0, 135.0), (35.0, 135.5), (35.5, 135.5)], [(35.0, 135.0), (34.0, 135.0), (34.0, 136.0), (35.5, 136.0), (35.5, 135.5)]]
    path = geometry.shortest_path(ways, (35.001, 135.001), (35.499, 135.499))
    assert path == [(35.0, 135.0), (35.0, 135.5), (35.5, 135.5)]


def test_no_track_near_the_station_means_no_line():
    assert geometry.shortest_path([[(35.0, 135.0), (35.0, 135.5)]], (40.0, 140.0), (35.0, 135.4)) is None


def test_unconnected_tracks_give_no_line():
    assert geometry.shortest_path([[(35.0, 135.0), (35.0, 135.1)], [(36.0, 136.0), (36.0, 136.1)]], (35.0, 135.0), (36.0, 136.1)) is None


def test_thinning_keeps_the_ends_and_the_limit():
    points = [(35 + i * 0.0001, 135 + (i % 7) * 0.00007) for i in range(3000)]
    out = geometry.thin(points, 400)
    assert len(out) <= 400 and out[0] == points[0] and out[-1] == points[-1]


def test_a_path_is_looked_up_once_and_failures_are_remembered(monkeypatch):
    conn = connect(":memory:")
    init_db(conn)
    calls = []

    def fake(mode, a, b):
        calls.append(mode)
        return ([a, b], "Test")

    monkeypatch.setattr(geometry, "compute", fake)
    a, b = (35.68, 139.77), (35.0, 135.76)
    assert geometry.ensure_path(conn, "shinkansen", a, b)["points"] == [[35.68, 139.77], [35.0, 135.76]]
    assert geometry.ensure_path(conn, "shinkansen", a, b) and calls == ["shinkansen"]
    assert geometry.cached_path(conn, "shinkansen", a, b)["source"] == "Test"
    assert geometry.ensure_path(conn, "flight", a, b) is None          # flights have no rails or roads

    monkeypatch.setattr(geometry, "compute", lambda *args: (_ for _ in ()).throw(RuntimeError("busy")))
    assert geometry.ensure_path(conn, "bus", a, b) is None
    monkeypatch.setattr(geometry, "compute", fake)
    assert geometry.ensure_path(conn, "bus", a, b) is None             # the failure is remembered for 15 minutes
    assert calls == ["shinkansen"]
