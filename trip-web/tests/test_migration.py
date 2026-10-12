import sqlite3
from pathlib import Path

import pytest

from app.config import settings
from app.db import LATEST_VERSION, connect, init_db

OLD_SCHEMA = (Path(__file__).parent / "fixtures" / "schema_v0.sql").read_text()


def old_database(path: Path) -> None:
    """A database as the first release made it: no rev columns, no trip_members, no username."""
    raw = sqlite3.connect(path)
    raw.executescript(OLD_SCHEMA)
    raw.execute("INSERT INTO trips (id, name, start_date, end_date, created_at, updated_at) VALUES ('t1','Japan 2027','2027-07-19','2027-08-08','x','x')")
    raw.execute("INSERT INTO places (id, trip_id, name, created_at, updated_at) VALUES ('p1','t1','Asakusa','x','x')")
    raw.execute("INSERT INTO days (id, trip_id, date, created_at, updated_at) VALUES ('d1','t1','2027-07-20','x','x')")
    raw.execute("INSERT INTO people (sub, name, last_seen) VALUES ('s1','Aaron','x')")
    raw.execute("UPDATE meta SET value = 41 WHERE key = 'revision'")
    raw.commit()
    raw.close()


@pytest.fixture()
def path(tmp_path, monkeypatch):
    target = tmp_path / "trip.db"
    monkeypatch.setattr(settings, "db_path", str(target))
    return target


def test_old_database_is_backed_up_and_migrated_without_losing_data(path):
    old_database(path)
    conn = connect()
    init_db(conn)
    assert [p.name for p in path.parent.glob("trip.db.bak-v0-*")], "a backup copy must exist"
    columns = {r["name"] for r in conn.execute("PRAGMA table_info(places)")}
    assert "rev" in columns
    assert conn.execute("SELECT rev FROM places WHERE id = 'p1'").fetchone()["rev"] == 41
    assert conn.execute("SELECT name FROM trips").fetchone()["name"] == "Japan 2027"
    assert conn.execute("SELECT COUNT(*) FROM trip_members").fetchone()[0] == 0
    assert "username" in {r["name"] for r in conn.execute("PRAGMA table_info(people)")}
    assert {"destination_latitude", "transport_raw"} <= {r["name"] for r in conn.execute("PRAGMA table_info(trips)")}
    assert conn.execute("PRAGMA user_version").fetchone()[0] == LATEST_VERSION
    conn.close()


def test_the_backup_holds_the_old_data(path):
    old_database(path)
    conn = connect()
    init_db(conn)
    conn.close()
    backup = next(path.parent.glob("trip.db.bak-v0-*"))
    copy = sqlite3.connect(backup)
    assert copy.execute("SELECT name FROM places").fetchone()[0] == "Asakusa"
    assert "rev" not in {r[1] for r in copy.execute("PRAGMA table_info(places)")}
    copy.close()


def test_running_twice_changes_nothing_and_makes_no_second_backup(path):
    old_database(path)
    for _ in range(2):
        conn = connect()
        init_db(conn)
        conn.close()
    assert len(list(path.parent.glob("trip.db.bak-*"))) == 1


def test_a_fresh_database_needs_no_backup(path):
    conn = connect()
    init_db(conn)
    conn.close()
    assert not list(path.parent.glob("*.bak-*"))


def test_duplicate_days_are_reported_instead_of_silently_kept(path):
    old_database(path)
    raw = sqlite3.connect(path)
    raw.execute("INSERT INTO days (id, trip_id, date, created_at, updated_at) VALUES ('d2','t1','2027-07-20','x','x')")
    raw.commit()
    raw.close()
    conn = connect()
    with pytest.raises(RuntimeError, match="doppelte Tage"):
        init_db(conn)
    conn.close()
