"""Creates the two Authentik applications for Trip Web, in the same style as the existing ones (hevy-analytics, ride-logger):

  trip-web     website login          redirect https://<host>/auth/callback
  trip-claude  Claude's connector     redirect https://claude.ai/api/mcp/auth_callback

and a group `trip-family` that is bound to both, so only its members can sign in (the other apps have no binding, which
means every Authentik user may use them).

Run it inside the Authentik container, see deploy/AUTHENTIK.md:
  docker exec -i -e FAMILY_USERS="name1,name2" authentik-server-1 ak shell < deploy/authentik_setup.py

Environment (all optional):
  TRIP_HOST      public host name, default trip.skyserver1508.org
  FAMILY_USERS   comma-separated Authentik usernames to put into the group trip-family
  DRY_RUN=1      does everything, prints what would happen, then rolls the database change back

Safe to run again: existing providers are kept as they are (their secrets are never changed or printed again).
Lines starting with TRIP| are for you to read, lines starting with TRIPENV| are secrets and belong in a file, not on screen."""
import os

from django.db import transaction

from authentik.core.models import Application, Group, User
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow
from authentik.policies.models import PolicyBinding
from authentik.providers.oauth2.models import OAuth2Provider, RedirectURI, RedirectURIMatchingMode, ScopeMapping

HOST = os.environ.get("TRIP_HOST", "trip.skyserver1508.org").strip()
FAMILY = [u.strip() for u in os.environ.get("FAMILY_USERS", "").split(",") if u.strip()]
DRY_RUN = os.environ.get("DRY_RUN") == "1"
GROUP = "trip-family"


def say(text):
    print(f"TRIP|{text}")


def secret(line):
    print(f"TRIPENV|{line}")


class DryRun(Exception):
    pass


def scopes(*names):
    found = {m.scope_name: m for m in ScopeMapping.objects.filter(managed__startswith="goauthentik.io/providers/oauth2/scope-")}
    missing = [n for n in names if n not in found]
    if missing:
        raise SystemExit(f"TRIP|FEHLER: Scope-Zuordnung fehlt in Authentik: {missing}")
    return [found[n] for n in names]


def make_app(slug, title, redirect_uris, flow_slug, scope_names, access_validity, launch_url, hide, env_prefix):
    existing = Application.objects.filter(slug=slug).first()
    if existing:
        say(f"{slug}: gibt es schon, nichts geändert (Client-ID {existing.provider.client_id if existing.provider else '?'})")
        return existing
    provider = OAuth2Provider(
        name=f"{slug}-provider",
        authorization_flow=Flow.objects.get(slug=flow_slug),
        invalidation_flow=Flow.objects.get(slug="default-provider-invalidation-flow"),
        client_type="confidential",
        grant_types=["authorization_code", "refresh_token"],
        sub_mode="hashed_user_id",
        issuer_mode="per_provider",
        include_claims_in_id_token=True,
        # Signed with the certificate, like the other apps: the access tokens are then JWTs that Trip Web can check.
        signing_key=CertificateKeyPair.objects.get(name="authentik Self-signed Certificate"),
        access_token_validity=access_validity,
        refresh_token_validity="days=30",
    )
    provider.redirect_uris = [RedirectURI(RedirectURIMatchingMode.STRICT, url) for url in redirect_uris]
    provider.save()
    provider.property_mappings.set(scopes(*scope_names))
    app = Application.objects.create(
        name=title, slug=slug, provider=provider, meta_launch_url=launch_url, meta_hide=hide,
    )
    say(f"{slug}: angelegt. Client-ID: {provider.client_id}")
    say(f"{slug}: Issuer: https://auth.{HOST.split('.', 1)[-1]}/application/o/{slug}/")
    if not DRY_RUN:
        secret(f"{env_prefix}CLIENT_ID={provider.client_id}")
        secret(f"{env_prefix}CLIENT_SECRET={provider.client_secret}")
    return app


def bind(app, group):
    _, created = PolicyBinding.objects.get_or_create(target=app, group=group, defaults={"order": 0, "enabled": True})
    say(f"{app.slug}: Zugriff nur für Gruppe {GROUP} ({'neu gebunden' if created else 'war schon gebunden'})")


try:
    with transaction.atomic():
        web = make_app(
            "trip-web", "Trip Planner", [f"https://{HOST}/auth/callback"],
            "default-provider-authorization-implicit-consent", ["openid", "email", "profile"],
            "hours=1", f"https://{HOST}/", False, "OIDC_",
        )
        claude = make_app(
            "trip-claude", "Trip Planner (Claude)",
            ["https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback"],
            "default-provider-authorization-explicit-consent", ["openid", "email", "profile", "offline_access"],
            "hours=8", "", True, "MCP_",
        )

        group, created = Group.objects.get_or_create(name=GROUP)
        say(f"Gruppe {GROUP}: {'angelegt' if created else 'gab es schon'}")
        bind(web, group)
        bind(claude, group)

        for name in FAMILY:
            user = User.objects.filter(username=name).first()
            if user:
                group.users.add(user)
                say(f"  {name}: in Gruppe {GROUP}")
            else:
                say(f"  WARNUNG: Nutzer {name} gibt es nicht (Gruppe nicht geändert)")
        if not group.users.exists():
            say(f"WARNUNG: Die Gruppe {GROUP} ist leer. Niemand kann sich anmelden, bis du Nutzer hinzufügst "
                f"(Directory > Groups > {GROUP} > Users).")

        if DRY_RUN:
            raise DryRun()
except DryRun:
    say("Probelauf: alles wieder zurückgerollt, nichts wurde gespeichert.")
else:
    say("Fertig.")
