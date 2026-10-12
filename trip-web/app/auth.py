from authlib.integrations.starlette_client import OAuth
from fastapi import HTTPException, Request

from .config import settings

oauth = OAuth()
if settings.oidc_client_id and settings.oidc_server_metadata_url:
    oauth.register(
        name="authentik",
        client_id=settings.oidc_client_id,
        client_secret=settings.oidc_client_secret,
        server_metadata_url=settings.oidc_server_metadata_url,
        client_kwargs={"scope": "openid email profile"},
    )


class NotAuthenticated(Exception):
    """Raised by require_login; caught by a handler that redirects to /login."""


def require_login(request: Request) -> None:
    if not request.session.get("user"):
        raise NotAuthenticated()


def require_api_login(request: Request) -> None:
    """For the JSON API: a plain 401, because the page's script cannot follow a redirect to an HTML login page."""
    if not request.session.get("user"):
        raise HTTPException(status_code=401, detail="not_authenticated")


def require_api_client(request: Request) -> None:
    """Changing calls must come from our own script (it sets this header; a form on another site cannot),
    on top of the session cookie's SameSite=Lax."""
    if request.headers.get("x-trip-client") != "1":
        raise HTTPException(status_code=403, detail="client_header_required")


def current_name(request: Request) -> str:
    return request.session["user"]["name"]


def current_sub(request: Request) -> str:
    """The Authentik user id: the key for who may see which trip."""
    return request.session["user"]["sub"]


def safe_next(url: str | None) -> str:
    """Only allow same-site relative redirects after login (no open redirect)."""
    if url and url.startswith("/") and not url.startswith("//") and "\\" not in url:
        return url
    return "/"
