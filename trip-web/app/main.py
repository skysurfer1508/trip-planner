import hmac
import re
import unicodedata
import logging
from contextlib import AsyncExitStack, asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

from . import archive, budget, native_auth, sync, dayplan, exports, geometry, packing, photos, timeline, places, rates, route, service
from .auth import (NotAuthenticated, current_name, current_sub, oauth, require_api_client, require_api_login, require_login, safe_next)
from .config import settings
from .db import db, init_db
from .mcp_server import build_mcp
from .service import ServiceError

log = logging.getLogger("trip")
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

mcp_secured = build_mcp(secured=True) if settings.mcp_issuer and settings.mcp_client_id else None
mcp_open = build_mcp(secured=False) if settings.mcp_secret_path and settings.mcp_secret_sub else None
mcp_secured_app = mcp_secured.streamable_http_app() if mcp_secured else None
mcp_open_app = mcp_open.streamable_http_app() if mcp_open else None


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    async with AsyncExitStack() as stack:
        for server in (mcp_secured, mcp_open):
            if server:
                await stack.enter_async_context(server.session_manager.run())
        yield


api = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
api.add_middleware(
    SessionMiddleware, secret_key=settings.session_secret, https_only=settings.session_https_only,
    same_site="lax", max_age=60 * 60 * 24 * 30,
)


@api.exception_handler(NotAuthenticated)
async def not_authenticated(request: Request, exc: NotAuthenticated):
    return RedirectResponse(url=f"/login?next={request.url.path}", status_code=303)


def get_conn():
    with db() as conn:
        yield conn


@api.get("/healthz")
def healthz():
    return {"ok": True}


# MARK: Sign-in (Authentik, same pattern as the other apps)

def _is_local(request: Request) -> bool:
    forwarded = any(h in request.headers for h in ("x-forwarded-for", "cf-connecting-ip", "x-real-ip"))
    return bool(request.client) and request.client.host in ("127.0.0.1", "::1") and not forwarded


@api.get("/login")
async def login(request: Request, next: str | None = None):
    if settings.dev_login and _is_local(request):
        request.session["user"] = {"sub": "dev", "name": "Dev", "email": "dev@localhost"}
        with db() as conn:
            service.touch_person(conn, "dev", "Dev")
        return RedirectResponse(safe_next(next), status_code=303)
    if "authentik" not in oauth._clients:
        raise HTTPException(status_code=503, detail="Login ist nicht eingerichtet (OIDC_* fehlt in .env).")
    request.session["next"] = safe_next(next)
    return await oauth.authentik.authorize_redirect(request, settings.oidc_redirect_uri)


@api.get("/auth/callback")
async def auth_callback(request: Request):
    token = await oauth.authentik.authorize_access_token(request)
    info: dict[str, Any] = token.get("userinfo") or {}
    sub = info.get("sub")
    if not sub:
        raise HTTPException(status_code=400, detail="Authentik hat keine Nutzer-ID geliefert.")
    name = info.get("given_name") or info.get("name") or info.get("preferred_username") or info.get("email") or "Unbekannt"
    username = info.get("preferred_username", "")
    request.session["user"] = {"sub": sub, "name": name, "email": info.get("email", "")}
    with db() as conn:
        service.touch_person(conn, sub, name, info.get("email", ""), username)
    return RedirectResponse(safe_next(request.session.pop("next", "/")), status_code=303)


@api.get("/logout")
async def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/", status_code=303)


# MARK: JSON API for the website

def _fail(error: Exception, status: int = 400) -> HTTPException:
    return HTTPException(status_code=status, detail=str(error))


@api.get("/api/me", dependencies=[Depends(require_api_login)])
def me(request: Request, conn=Depends(get_conn)):
    return {"name": current_name(request), "sub": current_sub(request), "people": service.list_people(conn, current_sub(request))}


@api.get("/api/trips", dependencies=[Depends(require_api_login)])
def trips(request: Request, conn=Depends(get_conn)):
    return service.list_trips(conn, current_sub(request))


@api.get("/api/trips/{trip_id}/data", dependencies=[Depends(require_api_login)])
def trip_data(trip_id: str, request: Request, conn=Depends(get_conn)):
    try:
        return service.trip_data(conn, current_sub(request), trip_id)
    except ServiceError as error:
        raise _fail(error, 404) from None


@api.get("/api/revision", dependencies=[Depends(require_api_login)])
def revision(conn=Depends(get_conn)):
    return {"revision": service.revision(conn)}


@api.patch("/api/items/{entity}/{item_id}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def patch_item(entity: str, item_id: str, request: Request, conn=Depends(get_conn)):
    body = await request.json()
    try:
        return service.update_item(conn, current_sub(request), entity, item_id, body.get("data", {}), current_name(request), "web")
    except (ServiceError, ValueError) as error:
        raise _fail(error) from None


@api.post("/api/trips/{trip_id}/items/{entity}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def create_item(trip_id: str, entity: str, request: Request, conn=Depends(get_conn)):
    body = await request.json()
    try:
        return service.create_item(conn, current_sub(request), entity, body.get("data", {}), current_name(request), "web", trip_id)
    except (ServiceError, ValueError) as error:
        raise _fail(error) from None


@api.delete("/api/items/{entity}/{item_id}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
def delete_item(entity: str, item_id: str, request: Request, conn=Depends(get_conn)):
    try:
        return service.remove_item(conn, current_sub(request), entity, item_id, current_name(request), "web")
    except (ServiceError, ValueError) as error:
        raise _fail(error) from None


@api.post("/api/changes/{change_id}/undo", dependencies=[Depends(require_api_login), Depends(require_api_client)])
def undo(change_id: str, request: Request, conn=Depends(get_conn)):
    try:
        return service.undo_change(conn, current_sub(request), change_id, current_name(request), "web")
    except ServiceError as error:
        raise _fail(error) from None


# Trips: create, change, delete, import and export.

MAX_IMPORT_BYTES = 60 * 1024 * 1024  # a backup with documents can be large; the documents are dropped after reading


@api.post("/api/trips", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def create_trip(request: Request, conn=Depends(get_conn)):
    body = await request.json()
    try:
        fields = {k: body[k] for k in ("name", "destination", "start_date", "end_date", "currency_code", "time_zone", "country_code",
                                       "description", "budget", "transport_raw", "phase", "travelers", "destination_latitude", "destination_longitude") if k in body}
        trip_id = service.create_trip(conn, current_sub(request), **{"name": "", "destination": "", "start_date": "", "end_date": "", **fields})
        return {"trip_id": trip_id}
    except ServiceError as error:
        raise _fail(error) from None


@api.patch("/api/trips/{trip_id}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def patch_trip(trip_id: str, request: Request, conn=Depends(get_conn)):
    body = await request.json()
    try:
        return service.update_trip(conn, current_sub(request), trip_id, body.get("data", {}), current_name(request), "web")
    except ServiceError as error:
        raise _fail(error) from None


@api.delete("/api/trips/{trip_id}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
def remove_trip(trip_id: str, request: Request, conn=Depends(get_conn)):
    try:
        service.delete_trip(conn, current_sub(request), trip_id, current_name(request), "web")
        return {"ok": True}
    except ServiceError as error:
        raise _fail(error) from None


@api.post("/api/import", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def import_trips(request: Request, conn=Depends(get_conn)):
    """Body: {archive: <contents of a .tripplanner file>, time_zone, preview}. With preview=true nothing is created."""
    if int(request.headers.get("content-length") or 0) > MAX_IMPORT_BYTES:
        raise _fail(ServiceError("Die Datei ist zu groß (höchstens 60 MB)."), 413)
    body = await request.json()
    try:
        if body.get("preview"):
            return archive.preview(body.get("archive"), body.get("time_zone") or archive.DEFAULT_ZONE)
        return {"trips": archive.import_archive(conn, current_sub(request), body.get("archive"),
                                                body.get("time_zone") or archive.DEFAULT_ZONE, current_name(request))}
    except ServiceError as error:
        raise _fail(error) from None


def _download(content: str, media_type: str, trip_name: str, extension: str) -> Response:
    name = unicodedata.normalize("NFKD", trip_name).encode("ascii", "ignore").decode()
    name = re.sub(r"[^A-Za-z0-9 -]", "", name).strip() or "trip"
    return Response(content, media_type=media_type, headers={"Content-Disposition": f'attachment; filename="{name}.{extension}"'})


@api.get("/api/trips/{trip_id}/export.txt", dependencies=[Depends(require_api_login)])
def export_text(trip_id: str, request: Request, conn=Depends(get_conn)):
    try:
        data = service.trip_data(conn, current_sub(request), trip_id)
    except ServiceError as error:
        raise _fail(error, 404) from None
    return _download(exports.plan_text(data), "text/plain; charset=utf-8", data["trip"]["name"], "txt")


@api.get("/api/trips/{trip_id}/export.ics", dependencies=[Depends(require_api_login)])
def export_calendar(trip_id: str, request: Request, tz: str = "", conn=Depends(get_conn)):
    """Times are the clock at the destination. `tz` is that time zone (default: the trip's own, else Europe/Zurich)."""
    try:
        data = service.trip_data(conn, current_sub(request), trip_id)
        body = exports.ics(data, tz or data["trip"].get("time_zone") or archive.DEFAULT_ZONE)
    except ServiceError as error:
        raise _fail(error, 404 if "nicht gefunden" in str(error) else 400) from None
    return _download(body, "text/calendar; charset=utf-8", data["trip"]["name"], "ics")


@api.get("/api/trips/{trip_id}/export.tripplanner", dependencies=[Depends(require_api_login)])
def export_trip(trip_id: str, request: Request, tz: str = archive.DEFAULT_ZONE, conn=Depends(get_conn)):
    try:
        data = archive.export_archive(conn, current_sub(request), trip_id, tz)
    except ServiceError as error:
        raise _fail(error, 404) from None
    name = unicodedata.normalize("NFKD", data["trips"][0]["name"]).encode("ascii", "ignore").decode()
    name = re.sub(r"[^A-Za-z0-9 -]", "", name).strip() or "trip"
    return JSONResponse(data, headers={"Content-Disposition": f'attachment; filename="{name}.tripplanner"'})


@api.get("/api/search/places", dependencies=[Depends(require_api_login)])
async def search_places(q: str = "", near: str = "", lang: str = "de"):
    """Place search for adding stops and ideas. `near` is `lat,lon` to prefer results around the trip."""
    point = None
    try:
        lat, lon = (float(part) for part in near.split(","))
        if -90 <= lat <= 90 and -180 <= lon <= 180:
            point = (lat, lon)
    except ValueError:
        pass
    try:
        return await places.search(q, point, lang)
    except Exception:  # Photon down or slow: say so instead of breaking the page
        raise HTTPException(status_code=502, detail="Die Ortssuche ist gerade nicht erreichbar. Bitte später noch einmal.") from None


async def _photo_of(place_id: str, request: Request, conn):
    try:
        target = service.photo_target(conn, current_sub(request), place_id)
    except ServiceError as error:
        raise HTTPException(status_code=404, detail=str(error)) from None
    found = await photos.photo(**target)
    if not found:
        raise HTTPException(status_code=404, detail="Kein Bild gefunden.")
    return found


@api.get("/api/places/{place_id}/photo", dependencies=[Depends(require_api_login)])
async def place_photo(place_id: str, request: Request, conn=Depends(get_conn)):
    """The picture for an idea (Wikipedia, cached on this server). 404 when there is none."""
    image, source = await _photo_of(place_id, request, conn)
    return FileResponse(image, media_type=source.get("type", "image/jpeg"), headers={"Cache-Control": "private, max-age=604800"})


@api.get("/api/places/{place_id}/photo/source", dependencies=[Depends(require_api_login)])
async def place_photo_source(place_id: str, request: Request, conn=Depends(get_conn)):
    """Where the picture comes from, for the credit line."""
    _, source = await _photo_of(place_id, request, conn)
    return {"title": source["title"], "page": source["page"]}


# The day plan: the app's operations on stops and days. Each one is a single entry in the history and can be undone.

async def _body(request: Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def _plan_call(request: Request, conn, function, *args, **kwargs):
    try:
        return function(conn, current_sub(request), *args, current_name(request), "web", **kwargs)
    except (ServiceError, ValueError) as error:
        raise _fail(error) from None


_WRITE = [Depends(require_api_login), Depends(require_api_client)]


@api.post("/api/stops/{stop_id}/move", dependencies=_WRITE)
async def move_stop(stop_id: str, request: Request, conn=Depends(get_conn)):
    body = await _body(request)
    return _plan_call(request, conn, dayplan.move_stop, stop_id, index=body.get("index"), day_id=body.get("day_id"))


@api.post("/api/stops/{stop_id}/duplicate", dependencies=_WRITE)
def duplicate_stop(stop_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, dayplan.duplicate_stop, stop_id)


@api.post("/api/days/{day_id}/copy", dependencies=_WRITE)
async def copy_day(day_id: str, request: Request, conn=Depends(get_conn)):
    body = await _body(request)
    return _plan_call(request, conn, dayplan.copy_day, day_id, str(body.get("to_day_id", "")))


@api.post("/api/days/{day_id}/sort", dependencies=_WRITE)
def sort_day(day_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, dayplan.sort_day_by_time, day_id)


@api.post("/api/days/{day_id}/optimize", dependencies=_WRITE)
def optimize_day(day_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, dayplan.optimize_day, day_id)


@api.post("/api/days/{day_id}/retime", dependencies=_WRITE)
async def retime_day(day_id: str, request: Request, conn=Depends(get_conn)):
    body = await _body(request)
    return _plan_call(request, conn, dayplan.retime_day, day_id, start=body.get("start") or None)


@api.post("/api/trips/{trip_id}/booking-stops", dependencies=_WRITE)
def booking_stops(trip_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, dayplan.add_booking_stops, trip_id)


@api.post("/api/places/{place_id}/to-day", dependencies=_WRITE)
async def place_to_day(place_id: str, request: Request, conn=Depends(get_conn)):
    body = await _body(request)
    return _plan_call(request, conn, dayplan.stop_from_place, place_id, str(body.get("day_id", "")))


@api.get("/api/trips/{trip_id}/budget", dependencies=[Depends(require_api_login)])
async def trip_budget(trip_id: str, request: Request, conn=Depends(get_conn)):
    """Budget numbers in the trip currency: spent, left, per category and per day, planned in stops, what could not be converted."""
    try:
        data = service.trip_data(conn, current_sub(request), trip_id)
    except ServiceError as error:
        raise _fail(error, 404) from None
    table = await rates.rates(data["trip"]["currency_code"])
    summary = budget.summarize(data["trip"], data["expenses"], data["stops"], table)
    summary["planned_travel"] = route.summarize(data["trip"], data["legs"], table)["price_for_group"]   # the chosen ways, for everyone
    return summary


@api.post("/api/trips/{trip_id}/packing-template", dependencies=_WRITE)
async def packing_template(trip_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, packing.add_template, trip_id, await _body(request))


@api.post("/api/trips/{trip_id}/packing/reset", dependencies=_WRITE)
def packing_reset(trip_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, packing.uncheck_all, trip_id)


@api.post("/api/trips/{trip_id}/packing/clear", dependencies=_WRITE)
def packing_clear(trip_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, packing.clear_list, trip_id)


@api.get("/api/trips/{trip_id}/route", dependencies=[Depends(require_api_login)])
async def trip_route(trip_id: str, request: Request, conn=Depends(get_conn)):
    """The route in order: hops with the chosen way and the options, total time and cost (per person and for everyone), warnings."""
    try:
        data = service.trip_data(conn, current_sub(request), trip_id)
    except ServiceError as error:
        raise _fail(error, 404) from None
    return route.full_summary(conn, data, await rates.rates(data["trip"]["currency_code"]))


@api.get("/api/legs/{leg_id}/path", dependencies=[Depends(require_api_login)])
def leg_path(leg_id: str, request: Request, conn=Depends(get_conn)):
    """The real way along rails or roads for one leg (looked up once, then cached). Slow the first time: a few seconds to a minute."""
    row = conn.execute("SELECT trip_id, mode, from_latitude, from_longitude, to_latitude, to_longitude FROM route_legs WHERE id = ? AND deleted_at IS NULL", (leg_id,)).fetchone()
    try:
        if row is None:
            raise ServiceError("nicht gefunden")
        service.trip_data(conn, current_sub(request), row["trip_id"])   # only members may ask (strangers get "nicht gefunden")
    except ServiceError as error:
        raise _fail(error, 404) from None
    a, b = (row["from_latitude"], row["from_longitude"]), (row["to_latitude"], row["to_longitude"])
    if not (any(a) and any(b)):
        return {"path": None}
    found = geometry.ensure_path(conn, row["mode"], a, b)
    return {"path": found["points"] if found else None, "source": found["source"] if found else ""}


@api.post("/api/legs/{leg_id}/choose", dependencies=_WRITE)
def choose_leg(leg_id: str, request: Request, conn=Depends(get_conn)):
    return _plan_call(request, conn, route.choose_leg, leg_id)


@api.post("/api/trips/{trip_id}/hops/{hop}/move", dependencies=_WRITE)
async def move_hop(trip_id: str, hop: int, request: Request, conn=Depends(get_conn)):
    body = await _body(request)
    return _plan_call(request, conn, route.shift_hop, trip_id, hop, 1 if body.get("delta", 1) > 0 else -1)


# Sharing a trip. Only owners may change who is in it.

@api.get("/api/people", dependencies=[Depends(require_api_login)])
def people(request: Request, q: str = "", conn=Depends(get_conn)):
    try:
        return service.find_people(conn, current_sub(request), q)
    except ServiceError as error:
        raise _fail(error, 403) from None


@api.put("/api/trips/{trip_id}/members/{sub}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
async def put_member(trip_id: str, sub: str, request: Request, conn=Depends(get_conn)):
    body = await request.json()
    try:
        service.set_member(conn, current_sub(request), trip_id, sub, str(body.get("role", "")))
        return {"members": service.list_members(conn, current_sub(request), trip_id)}
    except ServiceError as error:
        raise _fail(error) from None


@api.delete("/api/trips/{trip_id}/members/{sub}", dependencies=[Depends(require_api_login), Depends(require_api_client)])
def delete_member(trip_id: str, sub: str, request: Request, conn=Depends(get_conn)):
    try:
        service.remove_member(conn, current_sub(request), trip_id, sub)
        return {"ok": True}
    except ServiceError as error:
        raise _fail(error) from None


@api.get("/api/trips/{trip_id}/timeline", dependencies=[Depends(require_api_login)])
async def trip_timeline(trip_id: str, request: Request, conn=Depends(get_conn)):
    """The stays in order with dates and nights, how each is reached, and whether the nights add up to the trip."""
    try:
        data = service.trip_data(conn, current_sub(request), trip_id)
    except ServiceError as error:
        raise _fail(error, 404) from None
    summary = route.summarize(data["trip"], data["legs"], await rates.rates(data["trip"]["currency_code"]))
    return timeline.build(data["trip"], data["stays"], summary["hops"], data["places"], service.tally(data["votes"]))


@api.put("/api/places/{place_id}/vote", dependencies=_WRITE)
def vote_place(place_id: str, request: Request, body: dict[str, Any], conn=Depends(get_conn)):
    """Your own vote on an idea: 1 (for it), -1 (against), 0 (take it back)."""
    try:
        return service.vote(conn, current_sub(request), place_id, int(body.get("value", 0)))
    except (ServiceError, ValueError, TypeError) as error:
        raise _fail(error, 404) from None


# MARK: iPhone app

api.include_router(native_auth.router)


@api.post("/api/sync", dependencies=_WRITE)
def sync_trip(request: Request, body: dict[str, Any], conn=Depends(get_conn)):
    """One round of syncing with the app. Without `trip_id` the app uploads a trip it has never synced (`snapshot`); otherwise it sends its
    `changes` since the revision `since` and gets back everything that changed on the server."""
    user, actor = current_sub(request), current_name(request)
    try:
        if not body.get("trip_id"):
            if not isinstance(body.get("snapshot"), dict):
                raise ServiceError("snapshot fehlt.")
            return sync.create_from_app(conn, user, body["snapshot"], actor)
        changes = body.get("changes") or []
        since = body.get("since", 0)
        if not isinstance(changes, list) or isinstance(since, bool) or not isinstance(since, int) or since < 0:
            raise ServiceError("Ungültige Anfrage.")
        return sync.push(conn, user, str(body["trip_id"]), since, changes, actor)
    except ServiceError as error:
        raise _fail(error, 400) from None


# MARK: Pages

@api.get("/", dependencies=[Depends(require_login)])
def index():
    page = STATIC_DIR / "index.html"
    if not page.exists():
        raise HTTPException(status_code=503, detail="Die Website ist noch nicht gebaut (cd web && npm run build).")
    return FileResponse(page, headers={"Cache-Control": "no-store"})


if (STATIC_DIR / "assets").is_dir():
    api.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")


# MARK: Routing between the website and Claude's connector

class Root:
    """The MCP apps are their own ASGI apps with their own sign-in; this hands them their paths and gives everything else to the website."""

    def __init__(self, website: ASGIApp) -> None:
        self.website = website

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http":
            path: str = scope["path"]
            if path == "/mcp" or path.startswith("/mcp/") or path.startswith("/.well-known/oauth-protected-resource"):
                target = mcp_secured_app
                if target is None:
                    return await self._not_configured(scope, receive, send)
                return await target(scope, receive, send)
            if mcp_open_app and path.startswith("/mcp-secret/"):
                given = path.removeprefix("/mcp-secret/").rstrip("/")
                if hmac.compare_digest(given.encode(), settings.mcp_secret_path.encode()):
                    return await mcp_open_app(dict(scope, path="/mcp", raw_path=b"/mcp"), receive, send)
                return await self._not_configured(scope, receive, send)
        await self.website(scope, receive, send)

    @staticmethod
    async def _not_configured(scope: Scope, receive: Receive, send: Send) -> None:
        await JSONResponse({"error": "not_found"}, status_code=404)(scope, receive, send)


app = Root(api)

