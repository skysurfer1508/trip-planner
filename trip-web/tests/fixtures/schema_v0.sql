
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
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS days (
  id TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
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
  via TEXT NOT NULL CHECK (via IN ('web','claude','import')),
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
  last_seen TEXT NOT NULL
);

-- One counter, bumped on every change, that the website polls to know when to reload.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT OR IGNORE INTO meta (key, value) VALUES ('revision', 0);
