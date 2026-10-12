"""What can be edited, and how a value is checked. The website and Claude's connector both go through this."""
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

LOCAL_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LOCAL_DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$")


class ValidationError(ValueError):
    """The message is written for the person (or Claude) who sent the value."""


Check = Callable[[Any], Any]


def text(limit: int = 4000) -> Check:
    def check(value: Any) -> str:
        if not isinstance(value, str):
            raise ValidationError("muss Text sein")
        if len(value) > limit:
            raise ValidationError(f"zu lang (höchstens {limit} Zeichen)")
        return value
    check.doc = "Text"  # type: ignore[attr-defined]
    check.limit = limit  # type: ignore[attr-defined]
    return check


def url() -> Check:
    def check(value: Any) -> str:
        value = text(2000)(value)
        if value and not re.match(r"^https?://", value, re.IGNORECASE):
            raise ValidationError("nur http(s)-Links sind erlaubt")
        return value
    check.doc = "Link (http/https) oder leer"  # type: ignore[attr-defined]
    check.limit = 2000  # type: ignore[attr-defined]
    return check


def choice(*options: str) -> Check:
    def check(value: Any) -> str:
        if value not in options:
            raise ValidationError(f"muss eines von {', '.join(options)} sein")
        return value
    check.doc = " | ".join(options)  # type: ignore[attr-defined]
    return check


def number(low: float | None = None, high: float | None = None, integer: bool = False) -> Check:
    def check(value: Any) -> float | int:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValidationError("muss eine Zahl sein")
        if integer and int(value) != value:
            raise ValidationError("muss eine ganze Zahl sein")
        if (low is not None and value < low) or (high is not None and value > high):
            raise ValidationError(f"muss zwischen {low} und {high} liegen")
        return int(value) if integer else float(value)
    check.doc = "ganze Zahl" if integer else "Zahl"  # type: ignore[attr-defined]
    return check


def boolean() -> Check:
    def check(value: Any) -> int:
        if not isinstance(value, bool):
            raise ValidationError("muss true oder false sein")
        return int(value)
    check.doc = "true | false"  # type: ignore[attr-defined]
    return check


def local_date() -> Check:
    def check(value: Any) -> str:
        if not isinstance(value, str) or not LOCAL_DATE.match(value):
            raise ValidationError("muss ein Datum wie 2027-07-20 sein")
        return value
    check.doc = "Datum JJJJ-MM-TT"  # type: ignore[attr-defined]
    return check


def local_datetime(nullable: bool = False) -> Check:
    def check(value: Any) -> str | None:
        if value is None and nullable:
            return None
        if not isinstance(value, str) or not LOCAL_DATETIME.match(value):
            raise ValidationError("muss Ortszeit ohne Zeitzone sein, z. B. 2027-07-20T09:30")
        return value[:16] if len(value) == 19 else value
    check.doc = "Ortszeit JJJJ-MM-TTThh:mm (ohne Zeitzone)"  # type: ignore[attr-defined]
    return check


def uuid_ref() -> Check:
    def check(value: Any) -> str:
        try:
            return str(uuid.UUID(str(value)))
        except ValueError:
            raise ValidationError("muss eine ID sein") from None
    check.doc = "ID"  # type: ignore[attr-defined]
    return check


@dataclass(frozen=True)
class Entity:
    table: str
    label: str
    name_field: str
    required: tuple[str, ...]
    fields: dict[str, Check] = field(default_factory=dict)
    order_by: str = "created_at"
    name_template: str | None = None  # for entries that have no single name column, e.g. "{from_name} → {to_name}"

    def name_of(self, row: Any) -> str:
        values = dict(row)
        return self.name_template.format_map({k: values.get(k, "") for k in values}) if self.name_template else str(values.get(self.name_field, ""))

    def describe(self) -> str:
        parts = [f"{name} ({getattr(check, 'doc', '')})" for name, check in self.fields.items()]
        return f"{', '.join(parts)}. Pflicht beim Anlegen: {', '.join(self.required)}."


from .categories import IDS as _CATEGORY_IDS  # noqa: E402

STOP_CATEGORIES = ("sight", "food", "cafe", "hotel", "transport", "nightlife", "other")


LEG_MODES = ("shinkansen", "train", "bus", "flight", "ferry", "car", "taxi", "walk", "other")

ENTITIES: dict[str, Entity] = {
    "place": Entity(
        "places", "Ort", "name", ("name",),
        {
            "nr": text(20), "name": text(200), "region": text(100), "category": choice(*_CATEGORY_IDS), "description": text(), "duration": text(100),
            "heat": text(200), "for_whom": text(100),
            "prio": choice("Muss", "Gerne", "Falls Zeit", "Flughafen"), "decision": choice("Offen", "Ja", "Nein"),
            "wished_by": text(100), "source": text(100), "notes": text(), "website": url(),
            "latitude": number(-90, 90), "longitude": number(-180, 180), "sort_order": number(integer=True),
        },
        order_by="sort_order",
    ),
    "decision": Entity(
        "decisions", "Entscheid", "title", ("kind", "title"),
        {"kind": choice("decided", "open"), "title": text(200), "detail": text(), "sort_order": number(integer=True)},
        order_by="sort_order",
    ),
    "day": Entity("days", "Tag", "date", ("date",), {"date": local_date(), "notes": text()}, order_by="date"),
    "stop": Entity(
        "stops", "Stopp", "name", ("day_id", "name"),
        {
            "day_id": uuid_ref(), "place_id": uuid_ref(), "name": text(200), "address": text(300),
            "category_raw": choice(*STOP_CATEGORIES), "planned_time": local_datetime(nullable=True),
            "duration_minutes": number(0, 1440, integer=True), "notes": text(), "sort_order": number(integer=True),
            "is_done": boolean(), "estimated_cost": number(0), "phone": text(60), "website": url(),
            "opening_hours": text(500), "latitude": number(-90, 90), "longitude": number(-180, 180),
        },
        order_by="sort_order",
    ),
    "booking": Entity(
        "bookings", "Buchung", "title", ("kind_raw", "title", "start_date", "end_date"),
        {
            "kind_raw": choice("arrivalFlight", "departureFlight", "hotel"), "title": text(200),
            "start_date": local_datetime(), "end_date": local_datetime(), "place_name": text(200),
            "other_end": text(200), "address": text(300), "reference": text(100), "notes": text(),
            "buffer_minutes": number(0, 1440, integer=True), "remind": boolean(), "phone": text(60), "website": url(),
            "latitude": number(-90, 90), "longitude": number(-180, 180),
        },
        order_by="start_date",
    ),
    "expense": Entity(
        "expenses", "Ausgabe", "title", ("title", "amount"),
        {
            "title": text(200), "amount": number(), "currency_code": text(3),
            "category_raw": choice("food", "transport", "lodging", "activities", "shopping", "other"),
            "date": local_date(),
        },
        order_by="date",
    ),
    "leg": Entity(
        "route_legs", "Etappe", "to_name", ("from_name", "to_name", "mode"),
        {
            "hop": number(1, 200, integer=True), "status": choice("option", "chosen", "booked"),
            "from_name": text(200), "from_latitude": number(-90, 90), "from_longitude": number(-180, 180),
            "to_name": text(200), "to_latitude": number(-90, 90), "to_longitude": number(-180, 180),
            "mode": choice(*LEG_MODES), "line": text(200), "departure": local_datetime(nullable=True), "arrival": local_datetime(nullable=True),
            "duration_minutes": number(0, 4320, integer=True), "price": number(0), "currency_code": text(3), "reference": text(100),
            "notes": text(), "source": text(300), "source_url": url(), "pass_ok": boolean(), "sort_order": number(integer=True),
        },
        order_by="hop", name_template="{from_name} → {to_name}",
    ),
    "stay": Entity(
        "stays", "Aufenthalt", "name", ("name",),
        {"name": text(200), "nights": number(0, 60, integer=True), "latitude": number(-90, 90), "longitude": number(-180, 180),
         "notes": text(), "sort_order": number(integer=True)},
        order_by="sort_order",
    ),
    "checklist_item": Entity(
        "checklist_items", "Packlisten-Eintrag", "title", ("title",),
        {"title": text(200), "section": text(100), "is_done": boolean(), "sort_order": number(integer=True)},
        order_by="sort_order",
    ),
}

BY_TABLE = {e.table: e for e in ENTITIES.values()}

# Trips are validated like the entities but handled by their own functions (a trip has no trip_id, and no undo).
TRIP = Entity(
    "trips", "Reise", "name", ("name", "start_date", "end_date"),
    {
        "name": text(100), "destination": text(100), "start_date": local_date(), "end_date": local_date(),
        "currency_code": text(3), "time_zone": text(60), "country_code": text(2), "budget": number(0),
        "description": text(), "transport_raw": choice("walking", "transit", "car"),
        "phase": choice("planning", "building"), "travelers": number(1, 50, integer=True),
        "destination_latitude": number(-90, 90), "destination_longitude": number(-180, 180),
    },
)


def entity_of(name: str) -> Entity:
    try:
        return ENTITIES[name]
    except KeyError:
        raise ValidationError(f"Unbekannte Art \"{name}\". Erlaubt: {', '.join(ENTITIES)}") from None


def validate(entity: Entity, data: dict[str, Any]) -> dict[str, Any]:
    """Checks every field and returns the database values. Unknown fields are an error, so typos never go unnoticed."""
    if not isinstance(data, dict):
        raise ValidationError("data muss ein Objekt mit Feldern sein")
    unknown = [k for k in data if k not in entity.fields]
    if unknown:
        raise ValidationError(f"Unbekannte Felder: {', '.join(unknown)}. Erlaubt: {', '.join(entity.fields)}")
    row: dict[str, Any] = {}
    problems: list[str] = []
    for key, value in data.items():
        try:
            row[key] = entity.fields[key](value)
        except ValidationError as error:
            problems.append(f"{key}: {error}")
    if problems:
        raise ValidationError("Ungültige Werte: " + "; ".join(problems))
    if "latitude" in row and "longitude" in row and entity.table in ("places", "bookings"):
        row["has_coordinate"] = 1
    return row
