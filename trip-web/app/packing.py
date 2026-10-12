"""Starter packing lists (PackingTemplates.swift) in German, and the list-wide actions of ChecklistView."""
import sqlite3
from dataclasses import dataclass
from typing import Any

from . import service
from .entities import entity_of
from .service import ServiceError, User, apply_batch

ITEM = entity_of("checklist_item")
BEFORE_YOU_GO = "Vor der Abreise"
CLIMATES = ("warm", "mild", "cold")


@dataclass
class Options:
    climate: str = "mild"
    nights: int = 3
    rain: bool = False
    beach: bool = False
    hiking: bool = False
    business: bool = False
    nightlife: bool = False
    kids: bool = False

    @staticmethod
    def parse(raw: dict[str, Any]) -> "Options":
        climate = raw.get("climate", "mild")
        if climate not in CLIMATES:
            raise ServiceError(f"climate muss eines von {', '.join(CLIMATES)} sein.")
        nights = raw.get("nights", 3)
        if isinstance(nights, bool) or not isinstance(nights, int) or not 0 <= nights <= 365:
            raise ServiceError("nights muss eine ganze Zahl von 0 bis 365 sein.")
        flags = {k: bool(raw.get(k, False)) for k in ("rain", "beach", "hiking", "business", "nightlife", "kids")}
        return Options(climate=climate, nights=nights, **flags)


def template(o: Options) -> list[tuple[str, str]]:
    """(section, title) pairs in the order the app lists them."""
    items: list[tuple[str, str]] = []

    def add(section: str, titles: list[str]) -> None:
        items.extend((section, t) for t in titles)

    add("Dokumente und Geld", ["Pass / Ausweis", "Einreisedokumente oder Visum", "Angaben zur Reiseversicherung",
                               "Tickets und Buchungen (offline gespeichert)", "Debit- / Kreditkarten", "Etwas Bargeld in der Landeswährung"])
    days = min(max(o.nights + 1, 2), 8)
    clothes = [f"Unterwäsche ({days})", f"Socken ({days})", f"T-Shirts / Oberteile ({days})", "Hosen oder Röcke", "Bequeme Schuhe zum Laufen", "Schlafanzug"]
    if o.climate == "warm":
        clothes += ["Shorts", "Leichtes Kleid oder Hemden", "Sonnenbrille", "Sonnenhut"]
    elif o.climate == "mild":
        clothes += ["Leichte Jacke", "Pullover"]
    else:
        clothes += ["Warme Jacke", "Pullover", "Thermounterwäsche", "Handschuhe", "Schal und Mütze"]
    if o.rain:
        clothes += ["Regenjacke", "Regenschirm"]
    add("Kleidung", clothes)
    toiletries = ["Zahnbürste und Zahnpasta", "Deodorant", "Shampoo und Seife", "Persönliche Medikamente", "Pflaster / Erste Hilfe", "Desinfektionsmittel"]
    if o.climate == "warm" or o.beach:
        toiletries.append("Sonnencreme")
    add("Pflege und Gesundheit", toiletries)
    add("Elektronik", ["Handy-Ladegerät", "Powerbank", "Reisestecker", "Kopfhörer"])
    gear: list[str] = []
    if o.beach: gear += ["Badesachen", "Strandtuch", "Flip-Flops"]
    if o.hiking: gear += ["Wanderschuhe", "Tagesrucksack", "Trinkflasche", "Regenschutz"]
    if o.business: gear += ["Business-Outfit", "Laptop und Ladegerät"]
    if o.nightlife: gear += ["Schickes Outfit für den Abend"]
    if o.kids: gear += ["Snacks", "Spiele oder Bücher für die Reise", "Alles Wichtige für die Kinder"]
    if gear:
        add("Aktivitäten", gear)
    add(BEFORE_YOU_GO, ["Gültigkeit des Passes prüfen", "Unterkunft buchen", "Transport buchen", "Einreisebestimmungen prüfen",
                        "Bank über die Reise informieren", "Offline-Karten laden", "Online einchecken", "Pflanzen- oder Tierbetreuung organisieren"])
    return items


def add_template(conn: sqlite3.Connection, user: User, trip_id: str, raw: dict[str, Any], actor: str, via: str) -> dict[str, Any]:
    """Adds the suggested items that are not on the list yet (same title, ignoring case). Sections keep their order after the existing items."""
    service.resolve_trip(conn, user, trip_id, need="editor")
    options = Options.parse(raw)
    have = {r["title"].lower() for r in conn.execute("SELECT title FROM checklist_items WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,))}
    last = conn.execute("SELECT MAX(sort_order) FROM checklist_items WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,)).fetchone()[0]
    order = -1 if last is None else last
    inserts = []
    for section, title in template(options):
        if title.lower() in have:
            continue
        order += 1
        inserts.append((ITEM, {"title": title, "section": section, "is_done": 0, "sort_order": order}))
    change = apply_batch(conn, trip_id, actor, via, f"Packlisten-Vorschläge hinzugefügt ({len(inserts)})", [], inserts)
    return {"change_id": change, "added": len(inserts)}


def uncheck_all(conn: sqlite3.Connection, user: User, trip_id: str, actor: str, via: str) -> dict[str, Any]:
    service.resolve_trip(conn, user, trip_id, need="editor")
    rows = conn.execute("SELECT id FROM checklist_items WHERE trip_id = ? AND deleted_at IS NULL AND is_done = 1", (trip_id,)).fetchall()
    change = apply_batch(conn, trip_id, actor, via, f"Alle Haken entfernt ({len(rows)})", [(ITEM, r["id"], {"is_done": 0}) for r in rows])
    return {"change_id": change}


def clear_list(conn: sqlite3.Connection, user: User, trip_id: str, actor: str, via: str) -> dict[str, Any]:
    service.resolve_trip(conn, user, trip_id, need="editor")
    rows = conn.execute("SELECT id FROM checklist_items WHERE trip_id = ? AND deleted_at IS NULL", (trip_id,)).fetchall()
    stamp = service.now()
    change = apply_batch(conn, trip_id, actor, via, f"Packliste geleert ({len(rows)})", [(ITEM, r["id"], {"deleted_at": stamp}) for r in rows])
    return {"change_id": change}
