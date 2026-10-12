"""Claude's connector: the same operations as the website, offered as MCP tools.

Two doors lead here (see main.py): `/mcp`, which needs an Authentik access token, and, only if MCP_SECRET_PATH is set,
`/mcp-secret/<value>` as a fallback while OAuth is not working."""
import asyncio
import functools
import inspect
import logging
import time
from typing import Any, Callable, Literal
from urllib.parse import urlparse

import httpx
import jwt
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations

from . import dayplan, packing, rates, route, service, timeline
from .config import settings
from .db import db
from .entities import ENTITIES, ValidationError
from .service import ServiceError

log = logging.getLogger("trip.mcp")
USER_AGENT = {"User-Agent": "trip-web/1.0 (+family trip planner)"}

EntityName = Literal["place", "decision", "day", "stop", "booking", "expense", "checklist_item", "leg", "stay"]

ENTITY_HELP = "\n".join(f"- {name} ({e.label}): {e.describe()}" for name, e in ENTITIES.items())

INSTRUCTIONS = """Reiseplaner der Familie. Alles, was du hier einträgst, erscheint sofort auf der Website der Familie.
Ablauf: Starte mit list_trips. Das Claude-Konto wird von der ganzen Familie geteilt: Frage vor dem ersten Schreiben, wer gerade
schreibt, und gib den Namen bei jeder Änderung als acting_member mit. Lies vor Änderungen mit list_items nach, was schon da ist,
und erfinde keine Orte oder Koordinaten. Orte, die die Familie nicht will, bekommen decision "Nein" statt entfernt zu werden.
Zeiten sind Ortszeit ohne Zeitzone (2027-07-20T09:30). Jede Änderung steht im Verlauf und lässt sich mit undo_change zurücknehmen.
Reiseroute (Entität "leg", Etappe): Ein Abschnitt (hop) ist eine Fahrt von A nach B, zum Beispiel Tokyo nach Osaka. Pro Abschnitt legst du 2 bis 3
Optionen an (mode shinkansen, train, bus, flight ...), jede mit from_name/to_name, ihrer Position (from_/to_latitude/longitude, sonst erscheint sie
nicht auf der Karte), line (z. B. "Tokaido Shinkansen Nozomi"), duration_minutes, price pro Person in currency_code (JPY), dazu source und source_url
(woher Preis und Zeit stammen, mit Stand) und notes (Reservierung, JR Pass, Umstiege). Die erste Etappe eines Abschnitts ist gewählt, die weiteren sind
Optionen. Frage die Familie, welche sie nimmt, und setze die Wahl mit choose_leg. Preise und Fahrzeiten sind Richtwerte aus deinem Wissen oder
einer Recherche, es gibt dafür keine Live-Quelle: nenne die Quelle und weise auf den Stand hin. Setze bei Zügen pass_ok=true, wenn der JR Pass gilt
(Nozomi und Mizuho gelten nicht), und gib departure an: Die Website vergleicht damit JR Pass und Einzeltickets. Zu jedem Abschnitt zeigt sie Ideen, die
nahe an der Strecke liegen (route_summary, Feld nearby); schlage der Familie solche Zwischenstopps vor. Reisende (travelers) stehen an der Reise.
Zeitplan: Aufenthalte (Entität "stay": name, nights, notes) in Reihenfolge ergeben die Tage pro Stadt; schreibe in notes eine kurze Beschreibung, was die Familie dort macht (Tagesausflüge, Highlights); timeline_summary zeigt Daten und Warnungen, die Nächte
sollen zur Reisedauer passen. Die Familie stimmt auf der Website über Ideen ab (votes_summary); frage nach ihren Stimmen, bevor du Orte einplanst.
Eine Reise hat eine Phase: "planning" (Ideen sammeln und entscheiden; places, decisions) oder "building" (Tag für Tag aufbauen: days, stops,
bookings, expenses, checklist_item). Ändere die Phase mit update_trip nur auf ausdrücklichen Wunsch der Familie."""


# MARK: Sign-in with Authentik

class AuthentikTokenVerifier(TokenVerifier):
    """Checks an Authentik access token (a signed JWT): signature, issuer, audience and expiry."""

    def __init__(self, issuer: str, audience: str) -> None:
        self.issuer = issuer
        self.audience = audience
        self._jwks: jwt.PyJWKClient | None = None
        self._expected_issuer = ""
        self._loaded_at = 0.0

    def _client(self) -> jwt.PyJWKClient:
        if self._jwks is None or time.time() - self._loaded_at > 3600:
            meta = httpx.get(self.issuer.rstrip("/") + "/.well-known/openid-configuration", timeout=10,
                             headers=USER_AGENT).raise_for_status().json()
            self._expected_issuer = meta["issuer"]
            # Cloudflare in front of Authentik answers urllib's default User-Agent with 403, so send our own.
            self._jwks = jwt.PyJWKClient(meta["jwks_uri"], cache_keys=True, headers=USER_AGENT, timeout=10)
            self._loaded_at = time.time()
        return self._jwks

    def _decode(self, token: str) -> dict[str, Any]:
        key = self._client().get_signing_key_from_jwt(token)
        return jwt.decode(token, key.key, algorithms=["RS256", "ES256"], audience=self.audience,
                          issuer=self._expected_issuer, options={"require": ["exp", "iss", "aud", "sub"]})

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            claims = await asyncio.to_thread(self._decode, token)
        except Exception as error:  # bad signature, expired, wrong audience, Authentik unreachable ...
            log.info("token rejected: %s", error.__class__.__name__)
            return None
        return AccessToken(token=token, client_id=self.audience, scopes=str(claims.get("scope", "")).split(),
                           expires_at=int(claims["exp"]), subject=str(claims["sub"]), claims=claims)


# MARK: Tools

def guarded(fn: Callable[..., Any]) -> Callable[..., Any]:
    """Turns problems the caller can fix into a clean tool error. Works for normal and async tools."""
    if inspect.iscoroutinefunction(fn):
        @functools.wraps(fn)
        async def async_wrapper(*args: Any, **kwargs: Any) -> Any:
            try:
                return await fn(*args, **kwargs)
            except (ServiceError, ValidationError) as error:
                raise ToolError(str(error)) from None
        return async_wrapper

    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            return fn(*args, **kwargs)
        except (ServiceError, ValidationError) as error:
            raise ToolError(str(error)) from None
    return wrapper


def current_user() -> str:
    """Who Claude acts as: the Authentik user who connected it. Only the fallback door has no token and uses MCP_SECRET_SUB."""
    token = get_access_token()
    if token and token.subject:
        return token.subject
    if settings.mcp_secret_sub:
        return settings.mcp_secret_sub
    raise ToolError("Nicht angemeldet.")


READ = ToolAnnotations(readOnlyHint=True, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
REMOVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False)


def build_mcp(secured: bool) -> FastMCP:
    if not secured and not settings.mcp_secret_sub:
        raise RuntimeError("Die Notfall-Adresse braucht MCP_SECRET_SUB (wessen Reisen Claude damit sieht).")
    host = urlparse(settings.public_base_url).netloc
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[host, f"{host}:*", "localhost:*", "127.0.0.1:*"],
        allowed_origins=[settings.public_base_url, "http://localhost:*", "http://127.0.0.1:*"],
    )
    extra: dict[str, Any] = {}
    if secured:
        extra = {
            "token_verifier": AuthentikTokenVerifier(settings.mcp_issuer, settings.mcp_client_id),
            "auth": AuthSettings(
                issuer_url=settings.mcp_issuer,
                resource_server_url=settings.public_base_url.rstrip("/") + "/mcp",
                required_scopes=[],
                # Authentik puts the client id in `aud`, not our URL; AuthentikTokenVerifier checks it.
                validate_token_resource=False,
            ),
        }
    mcp = FastMCP(
        "Reiseplaner", instructions=INSTRUCTIONS, stateless_http=True, json_response=True,
        streamable_http_path="/mcp", transport_security=security, **extra,
    )

    @mcp.tool(title="Reisen und Mitglieder", annotations=READ)
    @guarded
    def list_trips() -> dict[str, Any]:
        """Listet die Reisen mit Daten und Beschreibung und die Namen der Familienmitglieder. Starte hier."""
        with db() as conn:
            user = current_user()
            return {"trips": service.list_trips(conn, user), "people": service.list_people(conn, user)}

    @mcp.tool(title="Reise anlegen", annotations=WRITE)
    @guarded
    def create_trip(name: str, start_date: str, end_date: str, destination: str = "", currency_code: str = "CHF",
                    time_zone: str = "", description: str = "", phase: Literal["planning", "building"] = "planning") -> dict[str, str]:
        """Legt eine neue Reise an. Daten als JJJJ-MM-TT, time_zone als IANA-Name (z. B. Asia/Tokyo). phase: "planning" (Ideen
        sammeln, noch nichts fix) oder "building" (Tag für Tag aufbauen)."""
        with db() as conn:
            return {"trip_id": service.create_trip(conn, current_user(), name, destination, start_date, end_date, currency_code,
                                                   time_zone, description=description, phase=phase)}

    @mcp.tool(title="Einträge auflisten", annotations=READ,
              description=f"Listet Einträge einer Art. Arten und Felder:\n{ENTITY_HELP}\n"
                          "Mit where nach gleichen Werten filtern, z. B. {\"region\": \"Kyoto\", \"decision\": \"Offen\"}.")
    @guarded
    def list_items(entity: EntityName, trip_id: str | None = None, where: dict[str, str | int | float | bool] | None = None,
                   limit: int = 200) -> dict[str, Any]:
        with db() as conn:
            return service.list_items(conn, current_user(), entity, trip_id, where, limit)

    @mcp.tool(title="Tagesplan", annotations=READ)
    @guarded
    def get_plan(trip_id: str | None = None) -> list[dict[str, Any]]:
        """Alle Tage mit ihren Stopps in der richtigen Reihenfolge."""
        with db() as conn:
            return service.get_plan(conn, current_user(), trip_id)

    @mcp.tool(title="Eintrag anlegen", annotations=WRITE,
              description=f"Legt einen Eintrag an; er erscheint sofort auf der Website. Arten und Felder:\n{ENTITY_HELP}")
    @guarded
    def create_item(entity: EntityName, data: dict[str, Any], acting_member: str, trip_id: str | None = None) -> dict[str, Any]:
        with db() as conn:
            user = current_user()
            return service.create_item(conn, user, entity, data, service.resolve_actor(conn, user, acting_member), "claude", trip_id)

    @mcp.tool(title="Eintrag ändern", annotations=WRITE,
              description=f"Ändert einzelne Felder (nur die mitgegebenen). Arten und Felder:\n{ENTITY_HELP}")
    @guarded
    def update_item(entity: EntityName, id: str, data: dict[str, Any], acting_member: str) -> dict[str, Any]:
        with db() as conn:
            user = current_user()
            return service.update_item(conn, user, entity, id, data, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Eintrag entfernen", annotations=REMOVE)
    @guarded
    def remove_item(entity: EntityName, id: str, acting_member: str) -> dict[str, Any]:
        """Blendet einen Eintrag aus (mit undo_change zurückholbar). Bei Orten besser decision auf "Nein" setzen."""
        with db() as conn:
            user = current_user()
            return service.remove_item(conn, user, entity, id, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Reiseroute", annotations=READ)
    @guarded
    async def route_summary(trip_id: str | None = None) -> dict[str, Any]:
        """Die Route in der Reihenfolge der Abschnitte (hop): pro Abschnitt der gewählte Weg und die Optionen, dazu Gesamtdauer und
        Gesamtpreis (pro Person und für alle, umgerechnet in die Reisewährung), und Warnungen (Lücken, offene Wahl)."""
        with db() as conn:
            user = current_user()
            data = service.trip_data(conn, user, service.resolve_trip(conn, user, trip_id))
            return route.full_summary(conn, data, await rates.rates(data["trip"]["currency_code"]), with_paths=False)

    @mcp.tool(title="Zeitplan der Reise", annotations=READ)
    @guarded
    async def timeline_summary(trip_id: str | None = None) -> dict[str, Any]:
        """Die Aufenthalte (Entität "stay") in Reihenfolge mit Von-bis-Datum, Nächten und Anreise, dazu Warnungen, wenn die Nächte nicht zur Reisedauer
        passen oder eine Anreise fehlt. Aufenthalte legst du mit create_item (entity "stay", name, nights) an; die Reihenfolge ist sort_order."""
        with db() as conn:
            user = current_user()
            data = service.trip_data(conn, user, service.resolve_trip(conn, user, trip_id))
            summary = route.summarize(data["trip"], data["legs"], await rates.rates(data["trip"]["currency_code"]))
            return timeline.build(data["trip"], data["stays"], summary["hops"], data["places"], service.tally(data["votes"]))

    @mcp.tool(title="Stimmen zu Ideen", annotations=READ)
    @guarded
    def votes_summary(trip_id: str | None = None) -> dict[str, Any]:
        """Wer welche Idee gut (for) oder schlecht (against) findet. Nur Ideen mit Stimmen erscheinen."""
        with db() as conn:
            user = current_user()
            data = service.trip_data(conn, user, service.resolve_trip(conn, user, trip_id))
        names = {p["id"]: p["name"] for p in data["places"]}
        return {"ideas": [{"id": pid, "name": names.get(pid, ""), **t} for pid, t in service.tally(data["votes"]).items() if pid in names]}

    @mcp.tool(title="Stimme eintragen", annotations=WRITE)
    @guarded
    def vote_for(place_id: str, member: str, value: Literal[-1, 0, 1], acting_member: str) -> dict[str, Any]:
        """Hält fest, was ein Familienmitglied (member) zu einer Idee gesagt hat: 1 = gefällt, -1 = gefällt nicht, 0 = Stimme zurücknehmen.
        Nur auf ausdrückliche Aussage der Person, nie raten."""
        with db() as conn:
            user = current_user()
            service.resolve_actor(conn, user, acting_member)
            return service.vote(conn, user, place_id, value, member=member)

    @mcp.tool(title="Etappe wählen", annotations=WRITE)
    @guarded
    def choose_leg(leg_id: str, acting_member: str) -> dict[str, Any]:
        """Macht diese Etappe zum gewählten Weg ihres Abschnitts; die bisher gewählte wird wieder zur Option. Nur auf Wunsch der Familie."""
        with db() as conn:
            user = current_user()
            return route.choose_leg(conn, user, leg_id, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Abschnitt verschieben", annotations=WRITE)
    @guarded
    def move_hop(hop: int, direction: Literal["up", "down"], acting_member: str, trip_id: str | None = None) -> dict[str, Any]:
        """Verschiebt einen ganzen Abschnitt (mit allen Optionen) in der Route nach oben (früher) oder unten (später)."""
        with db() as conn:
            user = current_user()
            return route.shift_hop(conn, user, service.resolve_trip(conn, user, trip_id, need="editor"), hop, -1 if direction == "up" else 1,
                                   service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Reise ändern", annotations=WRITE)
    @guarded
    def update_trip(data: dict[str, Any], acting_member: str, trip_id: str | None = None) -> dict[str, Any]:
        """Ändert Felder der Reise: name, destination, start_date, end_date (JJJJ-MM-TT), currency_code, budget, time_zone, description,
        transport_raw (walking|transit|car), phase (planning|building). Tage entstehen und fallen mit den Daten weg, Tage mit Stopps bleiben."""
        with db() as conn:
            user = current_user()
            trip = service.resolve_trip(conn, user, trip_id, need="editor")
            return service.update_trip(conn, user, trip, data, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Stopp verschieben", annotations=WRITE)
    @guarded
    def move_stop(stop_id: str, acting_member: str, index: int | None = None, day_id: str | None = None) -> dict[str, Any]:
        """Verschiebt einen Stopp innerhalb seines Tages an die Stelle index (0 = ganz oben) oder auf einen anderen Tag (day_id,
        ans Ende oder an index). Die Uhrzeit bleibt, das Datum passt sich an."""
        with db() as conn:
            user = current_user()
            return dayplan.move_stop(conn, user, stop_id, service.resolve_actor(conn, user, acting_member), "claude", index, day_id)

    @mcp.tool(title="Tag bearbeiten", annotations=WRITE)
    @guarded
    def arrange_day(day_id: str, action: Literal["sort_by_time", "optimize_route", "retime", "copy_to", "duplicate_stop"], acting_member: str,
                    start: str | None = None, to_day_id: str | None = None, stop_id: str | None = None) -> dict[str, Any]:
        """Wie die Tag-Aktionen der Website. sort_by_time: nach Uhrzeit sortieren. optimize_route: kürzeste Reihenfolge (alle Stopps
        brauchen eine Position; das Hotel ist der Startpunkt). retime: Zeiten neu hintereinander legen, optional ab start (HH:MM).
        copy_to: alle Stopps ans Ende von to_day_id kopieren. duplicate_stop: den Stopp stop_id direkt danach nochmal einfügen."""
        with db() as conn:
            user = current_user()
            actor = service.resolve_actor(conn, user, acting_member)
            if action == "sort_by_time":
                return dayplan.sort_day_by_time(conn, user, day_id, actor, "claude")
            if action == "optimize_route":
                return dayplan.optimize_day(conn, user, day_id, actor, "claude")
            if action == "retime":
                return dayplan.retime_day(conn, user, day_id, actor, "claude", start)
            if action == "copy_to":
                if not to_day_id:
                    raise ServiceError("to_day_id fehlt.")
                return dayplan.copy_day(conn, user, day_id, to_day_id, actor, "claude")
            if not stop_id:
                raise ServiceError("stop_id fehlt.")
            return dayplan.duplicate_stop(conn, user, stop_id, actor, "claude")

    @mcp.tool(title="Ort auf einen Tag legen", annotations=WRITE)
    @guarded
    def put_place_on_day(place_id: str, day_id: str, acting_member: str) -> dict[str, Any]:
        """Macht aus einer Idee (place) einen Stopp am Ende des Tages. Position, Notizen und Webseite werden übernommen."""
        with db() as conn:
            user = current_user()
            return dayplan.stop_from_place(conn, user, place_id, day_id, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Flüge und Hotels in den Plan legen", annotations=WRITE)
    @guarded
    def add_booking_stops(acting_member: str, trip_id: str | None = None) -> dict[str, Any]:
        """Legt Anreise, Abreise, Check-in und Check-out der Buchungen als Stopps auf die richtigen Tage (nur mit Position)."""
        with db() as conn:
            user = current_user()
            return dayplan.add_booking_stops(conn, user, service.resolve_trip(conn, user, trip_id, need="editor"),
                                             service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Packliste vorschlagen", annotations=WRITE)
    @guarded
    def suggest_packing_list(acting_member: str, climate: Literal["warm", "mild", "cold"] = "mild", nights: int = 3, rain: bool = False,
                             beach: bool = False, hiking: bool = False, business: bool = False, nightlife: bool = False, kids: bool = False,
                             trip_id: str | None = None) -> dict[str, Any]:
        """Fügt die Standard-Packliste hinzu (nur, was noch nicht darauf steht)."""
        with db() as conn:
            user = current_user()
            trip = service.resolve_trip(conn, user, trip_id, need="editor")
            options = {"climate": climate, "nights": nights, "rain": rain, "beach": beach, "hiking": hiking, "business": business,
                       "nightlife": nightlife, "kids": kids}
            return packing.add_template(conn, user, trip, options, service.resolve_actor(conn, user, acting_member), "claude")

    @mcp.tool(title="Letzte Änderungen", annotations=READ)
    @guarded
    def list_changes(trip_id: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
        """Der Verlauf: wer hat was über Website oder Claude geändert, mit change_id für undo_change."""
        with db() as conn:
            return service.list_changes(conn, current_user(), trip_id, limit)

    @mcp.tool(title="Änderung rückgängig machen", annotations=WRITE)
    @guarded
    def undo_change(change_id: str, acting_member: str) -> dict[str, Any]:
        """Nimmt eine Änderung zurück: Hinzugefügtes wird ausgeblendet, Geändertes zurückgesetzt, Entferntes zurückgeholt."""
        with db() as conn:
            user = current_user()
            return service.undo_change(conn, user, change_id, service.resolve_actor(conn, user, acting_member), "claude")

    return mcp
