import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .config import settings

# Dates and times are the local wall-clock time of the place ("2027-07-20T09:30", no time zone), as in the iOS app.
SCHEMA = """
CREATE TABLE IF NOT EXISTS trips (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  destination TEXT NOT NULL DEFAULT '',
  start_date TEXT NOT NULL,
  end_date TEXT NOT NULL,
  currency_code TEXT NOT NULL DEFAULT 'CHF',
  time_zone TEXT NOT NULL DEFAULT '',
  country_code TEXT NOT NULL DEFAULT '',
  budget REAL NOT NULL DEFAULT 0,
  description TEXT NOT NULL DEFAULT '',
  destination_latitude REAL NOT NULL DEFAULT 0,
  destination_longitude REAL NOT NULL DEFAULT 0,
  has_destination_coordinate INTEGER NOT NULL DEFAULT 0,
  transport_raw TEXT NOT NULL DEFAULT 'walking',
  travelers INTEGER NOT NULL DEFAULT 1,
  phase TEXT NOT NULL DEFAULT 'building' CHECK (phase IN ('planning','building')),
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS places (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  nr TEXT NOT NULL DEFAULT '',
  name TEXT NOT NULL,
  region TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  duration TEXT NOT NULL DEFAULT '',
  heat TEXT NOT NULL DEFAULT '',
  for_whom TEXT NOT NULL DEFAULT '',
  prio TEXT NOT NULL DEFAULT 'Falls Zeit' CHECK (prio IN ('Muss','Gerne','Falls Zeit','Flughafen')),
  decision TEXT NOT NULL DEFAULT 'Offen' CHECK (decision IN ('Offen','Ja','Nein')),
  wished_by TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  website TEXT NOT NULL DEFAULT '',
  latitude REAL NOT NULL DEFAULT 0,
  longitude REAL NOT NULL DEFAULT 0,
  has_coordinate INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS decisions (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('decided','open')),
  title TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

-- The route between places (Tokyo -> Osaka -> ...). A `hop` is one move; it can have several options, at most one of them chosen.
CREATE TABLE IF NOT EXISTS route_legs (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  hop INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'option' CHECK (status IN ('option','chosen','booked')),
  from_name TEXT NOT NULL,
  from_latitude REAL NOT NULL DEFAULT 0,
  from_longitude REAL NOT NULL DEFAULT 0,
  to_name TEXT NOT NULL,
  to_latitude REAL NOT NULL DEFAULT 0,
  to_longitude REAL NOT NULL DEFAULT 0,
  mode TEXT NOT NULL DEFAULT 'train',
  line TEXT NOT NULL DEFAULT '',
  departure TEXT,
  arrival TEXT,
  duration_minutes INTEGER NOT NULL DEFAULT 0,
  price REAL NOT NULL DEFAULT 0,
  currency_code TEXT NOT NULL DEFAULT 'JPY',
  reference TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  source_url TEXT NOT NULL DEFAULT '',
  pass_ok INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS route_legs_trip ON route_legs(trip_id, hop);

CREATE TABLE IF NOT EXISTS days (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS stops (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  day_id TEXT NOT NULL REFERENCES days(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  address TEXT NOT NULL DEFAULT '',
  category_raw TEXT NOT NULL DEFAULT 'other',
  planned_time TEXT,
  duration_minutes INTEGER NOT NULL DEFAULT 60,
  notes TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_done INTEGER NOT NULL DEFAULT 0,
  estimated_cost REAL NOT NULL DEFAULT 0,
  phone TEXT NOT NULL DEFAULT '',
  website TEXT NOT NULL DEFAULT '',
  opening_hours TEXT NOT NULL DEFAULT '',
  latitude REAL NOT NULL DEFAULT 0,
  longitude REAL NOT NULL DEFAULT 0,
  place_id TEXT REFERENCES places(id) ON DELETE SET NULL,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS bookings (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  kind_raw TEXT NOT NULL,
  title TEXT NOT NULL,
  start_date TEXT NOT NULL,
  end_date TEXT NOT NULL,
  place_name TEXT NOT NULL DEFAULT '',
  other_end TEXT NOT NULL DEFAULT '',
  address TEXT NOT NULL DEFAULT '',
  reference TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  buffer_minutes INTEGER NOT NULL DEFAULT 0,
  remind INTEGER NOT NULL DEFAULT 0,
  phone TEXT NOT NULL DEFAULT '',
  website TEXT NOT NULL DEFAULT '',
  latitude REAL NOT NULL DEFAULT 0,
  longitude REAL NOT NULL DEFAULT 0,
  has_coordinate INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS expenses (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  amount REAL NOT NULL DEFAULT 0,
  currency_code TEXT NOT NULL DEFAULT 'CHF',
  category_raw TEXT NOT NULL DEFAULT 'other',
  date TEXT NOT NULL,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS checklist_items (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  section TEXT NOT NULL DEFAULT '',
  is_done INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS change_log (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  table_name TEXT NOT NULL,
  row_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('insert','update','delete')),
  actor TEXT NOT NULL DEFAULT '',
  via TEXT NOT NULL CHECK (via IN ('web','claude','import','app')),
  summary TEXT NOT NULL DEFAULT '',
  before_json TEXT,
  after_json TEXT,
  undone_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS change_log_trip ON change_log(trip_id, created_at DESC);

-- Everyone who has signed in through Authentik. Used to suggest names for "who is writing with Claude".
CREATE TABLE IF NOT EXISTS people (
  sub TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL DEFAULT '',
  username TEXT NOT NULL DEFAULT '',
  last_seen TEXT NOT NULL
);

-- Who may see and edit which trip. `sub` is the Authentik user id (the same for the website and Claude's connector).
CREATE TABLE IF NOT EXISTS trip_members (
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  sub TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  added_at TEXT NOT NULL,
  PRIMARY KEY (trip_id, sub)
);
CREATE INDEX IF NOT EXISTS trip_members_sub ON trip_members(sub);

-- Where the family stays and for how many nights (the timeline of the trip). The order is `sort_order`.
CREATE TABLE IF NOT EXISTS stays (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  nights INTEGER NOT NULL DEFAULT 1,
  latitude REAL NOT NULL DEFAULT 0,
  longitude REAL NOT NULL DEFAULT 0,
  notes TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS stays_trip ON stays(trip_id, sort_order);

-- Who likes which idea: +1, -1 or no row. `voter` is the Authentik user (sub) or "name:<name>" when Claude writes down what a family member said.
CREATE TABLE IF NOT EXISTS votes (
  place_id TEXT NOT NULL REFERENCES places(id) ON DELETE CASCADE,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  voter TEXT NOT NULL,
  name TEXT NOT NULL,
  value INTEGER NOT NULL CHECK (value IN (-1, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (place_id, voter)
);

-- Real rail and road paths for the map (a picture only; not part of the trip data, not in the history).
CREATE TABLE IF NOT EXISTS route_paths (key TEXT PRIMARY KEY, points_json TEXT NOT NULL, source TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);

-- One counter, bumped on every change, that the website polls to know when to reload.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT OR IGNORE INTO meta (key, value) VALUES ('revision', 0);
"""


LATEST_VERSION = 7
REV_TABLES = ("trips", "places", "decisions", "days", "stops", "bookings", "expenses", "checklist_items", "route_legs", "stays")


def connect(path: str | None = None) -> sqlite3.Connection:
    target = path or settings.db_path
    if target != ":memory:":
        Path(target).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(target, isolation_level=None, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    if target != ":memory:":
        conn.execute("PRAGMA journal_mode = WAL")
    return conn


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}


def _add_column(conn: sqlite3.Connection, table: str, column: str, ddl: str) -> None:
    if column not in _columns(conn, table):
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")


def _backup(conn: sqlite3.Connection, version: int) -> Path | None:
    """A consistent copy of the database file before it is changed. Only for databases that hold data."""
    target = settings.db_path
    if target == ":memory:" or not Path(target).exists():
        return None
    path = Path(target).with_name(f"{Path(target).name}.bak-v{version}-{datetime.now():%Y%m%d-%H%M%S}")
    copy = sqlite3.connect(path)
    try:
        conn.backup(copy)
    finally:
        copy.close()
    path.chmod(0o600)
    return path


def _migrate_to_1(conn: sqlite3.Connection) -> None:
    """Adds what version 1 needs to a database made by the first release (idempotent, so fresh databases pass through too)."""
    for table in REV_TABLES:
        _add_column(conn, table, "rev", "INTEGER NOT NULL DEFAULT 0")
        conn.execute(f"UPDATE {table} SET rev = (SELECT MAX(value, 1) FROM meta WHERE key = 'revision') WHERE rev = 0")
    _add_column(conn, "trips", "destination_latitude", "REAL NOT NULL DEFAULT 0")
    _add_column(conn, "trips", "destination_longitude", "REAL NOT NULL DEFAULT 0")
    _add_column(conn, "trips", "has_destination_coordinate", "INTEGER NOT NULL DEFAULT 0")
    _add_column(conn, "trips", "transport_raw", "TEXT NOT NULL DEFAULT 'walking'")
    _add_column(conn, "people", "username", "TEXT NOT NULL DEFAULT ''")


def _migrate_to_2(conn: sqlite3.Connection) -> None:
    """Every trip gets a day row for each of its dates, like the iOS app (earlier trips were made without days)."""
    from .planning import wanted_dates  # local import: planning has no database code and db must stay importable first
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rev = conn.execute("SELECT MAX(value, 1) FROM meta WHERE key = 'revision'").fetchone()[0]
    for trip in conn.execute("SELECT id, start_date, end_date FROM trips WHERE deleted_at IS NULL").fetchall():
        have = {r["date"] for r in conn.execute("SELECT date FROM days WHERE trip_id = ? AND deleted_at IS NULL", (trip["id"],))}
        for day in wanted_dates(trip["start_date"][:10], trip["end_date"][:10]):
            if day not in have:
                conn.execute("INSERT INTO days (id, trip_id, date, rev, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                             (str(uuid.uuid4()), trip["id"], day, rev, stamp, stamp))


def _migrate_to_3(conn: sqlite3.Connection) -> None:
    """Trips have a phase: `planning` (collecting ideas, nothing fixed) or `building` (day by day, like the app).
    Trips that only hold ideas and have no stop yet are still in planning; every other trip is already being built."""
    _add_column(conn, "trips", "phase", "TEXT NOT NULL DEFAULT 'building' CHECK (phase IN ('planning','building'))")
    conn.execute(
        "UPDATE trips SET phase = 'planning' "
        "WHERE EXISTS (SELECT 1 FROM places p WHERE p.trip_id = trips.id AND p.deleted_at IS NULL) "
        "AND NOT EXISTS (SELECT 1 FROM stops s WHERE s.trip_id = trips.id AND s.deleted_at IS NULL)")


def _migrate_to_4(conn: sqlite3.Connection) -> None:
    """Ideas get a category (temple, shopping, mountains …). Existing ideas are sorted by name and description; the family can change it."""
    from .categories import classify
    _add_column(conn, "places", "category", "TEXT NOT NULL DEFAULT ''")
    for row in conn.execute("SELECT id, name, description, region FROM places WHERE category = ''").fetchall():
        conn.execute("UPDATE places SET category = ? WHERE id = ?", (classify(row["name"], row["description"], row["region"]), row["id"]))


def _migrate_to_5(conn: sqlite3.Connection) -> None:
    """The route between places, and how many people travel (fares are per person)."""
    _add_column(conn, "trips", "travelers", "INTEGER NOT NULL DEFAULT 1")


def _migrate_to_6(conn: sqlite3.Connection) -> None:
    """Whether a leg is covered by a rail pass (for the JR Pass comparison)."""
    _add_column(conn, "route_legs", "pass_ok", "INTEGER NOT NULL DEFAULT 0")


def _migrate_to_7(conn: sqlite3.Connection) -> None:
    """The history can say that a change came from the iPhone app. SQLite cannot change a CHECK, so the table is rebuilt."""
    sql = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'change_log'").fetchone()
    if not sql or "'app'" in sql["sql"]:
        return
    conn.execute("ALTER TABLE change_log RENAME TO change_log_old")
    conn.execute("DROP INDEX IF EXISTS change_log_trip")
    conn.executescript(SCHEMA)       # creates the new change_log (and its index); everything else already exists
    conn.execute("INSERT INTO change_log SELECT * FROM change_log_old")
    conn.execute("DROP TABLE change_log_old")


def init_db(conn: sqlite3.Connection | None = None) -> None:
    own = conn is None
    conn = conn or connect()
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    has_data = conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'trips'").fetchone() is not None
    if has_data and version < LATEST_VERSION:
        backup = _backup(conn, version)
        if backup:
            print(f"Datenbank gesichert: {backup}")
    conn.executescript(SCHEMA)
    if version < 1:
        _migrate_to_1(conn)
    if version < 2:
        _migrate_to_2(conn)
    if version < 3:
        _migrate_to_3(conn)
    if version < 4:
        _migrate_to_4(conn)
    if version < 5:
        _migrate_to_5(conn)
    if version < 6:
        _migrate_to_6(conn)
    if version < 7:
        _migrate_to_7(conn)
    try:
        # One day per date and trip, like in the iOS app (a day is identified by its date).
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS days_trip_date ON days(trip_id, date) WHERE deleted_at IS NULL")
    except sqlite3.IntegrityError:
        raise RuntimeError("In der Datenbank gibt es doppelte Tage (gleiche Reise und gleiches Datum). "
                           "Bitte zuerst bereinigen, dann erneut starten.") from None
    conn.execute(f"PRAGMA user_version = {LATEST_VERSION}")
    if own:
        conn.close()


@contextmanager
def db():
    """One connection per unit of work."""
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def transaction(conn: sqlite3.Connection):
    """One write. Counts the global revision up first and hands it out, so every row written here carries the same `rev`
    (the website polls it, and the later app sync asks for everything newer than the last one it saw)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("UPDATE meta SET value = value + 1 WHERE key = 'revision'")
        rev = conn.execute("SELECT value FROM meta WHERE key = 'revision'").fetchone()["value"]
        yield rev
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
