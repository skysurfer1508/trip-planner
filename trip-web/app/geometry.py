"""The real way a train, bus or car takes: rails from OpenStreetMap (Overpass), roads from OSRM.

The result is a list of [lat, lon] points that the map draws instead of a straight line. It is only a picture:
nothing here changes durations or prices. Everything is cached (table `route_paths`), because the public services are slow and shared.
"""
import heapq
import json
import math
import sqlite3
import time
import urllib.parse
import urllib.request
from typing import Iterable

USER_AGENT = "trip-web/1.0 (family trip planner; self-hosted)"
OVERPASS = ("https://overpass.private.coffee/api/interpreter", "https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
OSRM = "https://router.project-osrm.org/route/v1/driving/{coords}?overview=full&geometries=geojson"
RAIL_MODES = ("shinkansen", "train")
ROAD_MODES = ("bus", "car", "taxi")
MAX_POINTS = 400

Point = tuple[float, float]


def haversine(a: Point, b: Point) -> float:
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(b[1] - a[1]) / 2) ** 2
    return 12742000 * math.asin(math.sqrt(h))


def thin(points: list[Point], limit: int = MAX_POINTS) -> list[Point]:
    """Keeps at most `limit` points by dropping the ones that matter least (Douglas-Peucker with a growing tolerance)."""
    if len(points) <= limit:
        return points
    tolerance = 0.00005
    while len(points) > limit:
        points = _simplify(points, tolerance)
        tolerance *= 1.6
    return points


def _simplify(points: list[Point], tol: float) -> list[Point]:
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        best, index = 0.0, -1
        (ay, ax), (by, bx) = points[lo], points[hi]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        for i in range(lo + 1, hi):
            py, px = points[i]
            t = 0 if length == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
            d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, index = d, i
        if best > tol and index > 0:
            keep[index] = True
            stack += [(lo, index), (index, hi)]
    return [p for p, k in zip(points, keep) if k]


def shortest_path(ways: Iterable[list[Point]], start: Point, end: Point) -> list[Point] | None:
    """The shortest way along the given lines (each way is a list of points) from the point nearest to `start` to the one nearest to `end`."""
    nodes: dict[Point, list[tuple[Point, float]]] = {}
    snap = lambda p: (round(p[0], 4), round(p[1], 4))  # points about 10 m apart count as one: OSM tracks often meet without sharing a node
    for way in ways:
        for a, b in zip(map(snap, way), map(snap, way[1:])):
            if a == b:
                continue
            d = haversine(a, b)
            nodes.setdefault(a, []).append((b, d))
            nodes.setdefault(b, []).append((a, d))
    if not nodes:
        return None
    nearest = lambda target: min(nodes, key=lambda n: (n[0] - target[0]) ** 2 + ((n[1] - target[1]) * math.cos(math.radians(target[0]))) ** 2)
    source, goal = nearest(start), nearest(end)
    if haversine(source, start) > 5000 or haversine(goal, end) > 5000:
        return None  # no track near the station: better no line than a wrong one
    best = {source: 0.0}
    came: dict[Point, Point] = {}
    queue = [(0.0, source)]
    while queue:
        cost, here = heapq.heappop(queue)
        if here == goal:
            break
        if cost > best.get(here, math.inf):
            continue
        for there, d in nodes[here]:
            new = cost + d
            if new < best.get(there, math.inf):
                best[there] = new
                came[there] = here
                heapq.heappush(queue, (new, there))
    if goal not in best:
        return None
    path = [goal]
    while path[-1] != source:
        path.append(came[path[-1]])
    path.reverse()
    return path


def _post(url: str, data: dict[str, str], timeout: int) -> bytes:
    request = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def rail_ways(mode: str, a: Point, b: Point) -> list[list[Point]]:
    # The box around both stations plus a margin: real lines bend away from the straight line (the Tokaido line dips 60 km south of it).
    if haversine(a, b) > 700000:
        raise ValueError("Strecke zu lang für die Gleissuche")
    margin = max(0.3, 0.25 * max(abs(a[0] - b[0]), abs(a[1] - b[1])))
    area = f"({min(a[0], b[0]) - margin:.3f},{min(a[1], b[1]) - margin:.3f},{max(a[0], b[0]) + margin:.3f},{max(a[1], b[1]) + margin:.3f})"
    if mode == "shinkansen":
        query = f'[out:json][timeout:80];way["railway"="rail"]["highspeed"="yes"]{area};out geom;'
    else:
        query = f'[out:json][timeout:80];way["railway"="rail"]["usage"~"main|branch"][!"service"]{area};out geom;'
    last: Exception | None = None
    for attempt in range(3):
        for url in OVERPASS:
            try:
                body = json.loads(_post(url, {"data": query}, 100))
                return [[(p["lat"], p["lon"]) for p in el["geometry"]] for el in body.get("elements", []) if el.get("geometry")]
            except Exception as error:  # a busy or broken server: try the next one
                last = error
        time.sleep(3)
    raise RuntimeError(f"Overpass nicht erreichbar: {last}")


def road_path(a: Point, b: Point) -> list[Point] | None:
    url = OSRM.format(coords=f"{a[1]},{a[0]};{b[1]},{b[0]}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if body.get("code") != "Ok" or not body.get("routes"):
        return None
    return [(lat, lon) for lon, lat in body["routes"][0]["geometry"]["coordinates"]]


def compute(mode: str, a: Point, b: Point) -> tuple[list[Point], str] | None:
    """(points, source) or None when no real path is known (the map then falls back to an arc)."""
    if mode in RAIL_MODES:
        path = shortest_path(rail_ways(mode, a, b), a, b)
        return (thin([a, *path, b]), "OpenStreetMap-Gleise") if path else None
    if mode in ROAD_MODES:
        path = road_path(a, b)
        return (thin(path), "OpenStreetMap-Strassen (OSRM)") if path else None
    return None


# MARK: Cache

def _key(mode: str, a: Point, b: Point) -> str:
    kind = "rail-hs" if mode == "shinkansen" else "rail" if mode in RAIL_MODES else "road"
    return f"{kind}:{a[0]:.3f},{a[1]:.3f}:{b[0]:.3f},{b[1]:.3f}"


def cached_path(conn: sqlite3.Connection, mode: str, a: Point, b: Point) -> dict | None:
    if mode not in RAIL_MODES + ROAD_MODES:
        return None
    row = conn.execute("SELECT points_json, source FROM route_paths WHERE key = ?", (_key(mode, a, b),)).fetchone()
    return {"points": json.loads(row["points_json"]), "source": row["source"]} if row and row["points_json"] else None


def ensure_path(conn: sqlite3.Connection, mode: str, a: Point, b: Point) -> dict | None:
    """Returns the cached path, or fetches and stores it. A failed lookup is remembered for 15 minutes so the public servers are not hammered."""
    if mode not in RAIL_MODES + ROAD_MODES:
        return None
    key = _key(mode, a, b)
    row = conn.execute("SELECT points_json, source, created_at FROM route_paths WHERE key = ?", (key,)).fetchone()
    if row and (row["points_json"] or time.time() - row["created_at"] < 900):
        return {"points": json.loads(row["points_json"]), "source": row["source"]} if row["points_json"] else None
    try:
        found = compute(mode, a, b)
    except Exception:
        found = None
    conn.execute("INSERT OR REPLACE INTO route_paths (key, points_json, source, created_at) VALUES (?,?,?,?)",
                 (key, json.dumps([[round(p[0], 5), round(p[1], 5)] for p in found[0]]) if found else "", found[1] if found else "", time.time()))
    conn.commit()
    return {"points": [list(p) for p in found[0]], "source": found[1]} if found else None
