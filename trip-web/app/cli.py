"""Maintenance commands (run in ~/trip-web with the project's .env loaded):

  python -m app.cli seed [file]              load the starting trip into an EMPTY database (no members yet, see claim)
  python -m app.cli claim <who>              make <who> the owner of every trip that has no member yet
  python -m app.cli share <trip> <who> <role>  add or change a member (role: viewer, editor or owner)
  python -m app.cli members                  list trips with their members
  python -m app.cli export > backup.json     everything that is not deleted, as JSON

<who> is an Authentik user id (sub), username, e-mail address or name of someone who has signed in to the website once."""
import json
import sys
from pathlib import Path

from . import service
from .db import db, init_db
from .service import SYSTEM, ServiceError

DEFAULT_SEED = Path(__file__).resolve().parent.parent / "seed" / "japan2027.json"


def person(conn, who: str) -> dict:
    """Finds exactly one person who has signed in; names the candidates if it is not clear."""
    rows = [dict(r) for r in conn.execute("SELECT sub, name, username, email FROM people")]
    key = who.strip().lower()
    hits = [r for r in rows if key in (r["sub"].lower(), r["username"].lower(), r["email"].lower(), r["name"].lower())]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        known = ", ".join(f"{r['name']} ({r['username'] or r['email'] or r['sub'][:8]})" for r in rows) or "niemand"
        raise SystemExit(f"Niemand passt zu \"{who}\". Angemeldet waren bisher: {known}. Bitte erst auf der Website anmelden.")
    raise SystemExit(f"\"{who}\" ist nicht eindeutig: " + ", ".join(f"{r['name']} ({r['sub']})" for r in hits))


def seed(path: Path) -> None:
    """Loads a starting trip, but only into an empty database, so it can never overwrite what the family has entered."""
    data = json.loads(path.read_text(encoding="utf-8"))
    with db() as conn:
        init_db(conn)
        if conn.execute("SELECT COUNT(*) FROM trips").fetchone()[0]:
            print("Die Datenbank enthält schon eine Reise. Nichts geändert.")
            return
        trip = service.create_trip(conn, SYSTEM, **data["trip"])
        for row in data["places"]:
            fields = {k: v for k, v in dict(zip(data["place_columns"], row)).items() if v != ""}
            service.create_item(conn, SYSTEM, "place", fields, "Import", "import", trip)
        for row in data["decisions"]:
            service.create_item(conn, SYSTEM, "decision", dict(zip(data["decision_columns"], row)), "Import", "import", trip)
        print(f"Reise {data['trip']['name']} angelegt: {len(data['places'])} Orte, {len(data['decisions'])} Entscheide. "
              "Noch ohne Besitzer: python -m app.cli claim <du>")


def claim(who: str) -> None:
    with db() as conn:
        init_db(conn)
        found = person(conn, who)
        count = service.claim_trips(conn, found["sub"])
        print(f"{found['name']} ist jetzt Besitzer von {count} Reise(n) ohne Mitglieder.")


def share(trip: str, who: str, role: str) -> None:
    with db() as conn:
        init_db(conn)
        found = person(conn, who)
        trip_id = next((t["id"] for t in service.list_trips(conn, SYSTEM) if trip in (t["id"], t["name"])), None)
        if not trip_id:
            raise SystemExit(f"Keine Reise \"{trip}\".")
        try:
            service.set_member(conn, SYSTEM, trip_id, found["sub"], role)
        except ServiceError as error:
            raise SystemExit(str(error)) from None
        print(f"{found['name']} ist jetzt {role} bei {trip}.")


def members() -> None:
    with db() as conn:
        init_db(conn)
        for trip in service.list_trips(conn, SYSTEM):
            print(f"{trip['name']} ({trip['id']})")
            who = service.list_members(conn, SYSTEM, trip["id"])
            for m in who or []:
                print(f"   {m['role']:7} {m['name'] or '?'}  {m.get('username', '')}")
            if not who:
                print("   (kein Mitglied: python -m app.cli claim <du>)")


def export() -> None:
    """Everything that is not deleted, as JSON on stdout (a simple backup)."""
    out: dict[str, object] = {}
    with db() as conn:
        init_db(conn)
        out["trips"] = service.list_trips(conn, SYSTEM)
        for trip in out["trips"]:  # type: ignore[union-attr]
            out[f"trip:{trip['id']}"] = service.trip_data(conn, SYSTEM, trip["id"])
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command == "seed":
        seed(Path(args[1]) if len(args) > 1 else DEFAULT_SEED)
    elif command == "claim" and len(args) == 2:
        claim(args[1])
    elif command == "share" and len(args) == 4:
        share(args[1], args[2], args[3])
    elif command == "members":
        members()
    elif command == "export":
        export()
    else:
        print(__doc__)
        sys.exit(2)
