# Authentik für Trip Web einrichten

`deploy/authentik_setup.py` legt an, im gleichen Stil wie hevy-analytics und ride-logger (vertraulicher Client, Signaturzertifikat,
`hashed_user_id`, `per_provider`-Issuer):

| App | Zweck | Redirect-URI | Zustimmung |
|---|---|---|---|
| `trip-web` | Login der Website | `https://trip.skyserver1508.org/auth/callback` | automatisch |
| `trip-claude` | Claudes Connector | `https://claude.ai/api/mcp/auth_callback` (und die künftige `claude.com`-Adresse) | ausdrücklich |

Dazu die Gruppe `trip-family`, die an beide Apps gebunden wird. Eure anderen Apps haben keine Bindung, dort darf jeder
Authentik-Nutzer rein. Hier dürfen nur Mitglieder von `trip-family` rein.

## Ablauf (auf dem Server)

1. Probelauf, ändert nichts (alles wird zurückgerollt). Nutzernamen anpassen:

```bash
docker exec -i -e FAMILY_USERS="skysurfer1508" -e DRY_RUN=1 authentik-server-1 ak shell < ~/trip-web/deploy/authentik_setup.py 2>&1 | grep '^TRIP'
```

2. Echt anlegen. Die Secrets landen nur in einer Datei, die nur du lesen darfst:

```bash
(umask 077; docker exec -i -e FAMILY_USERS="skysurfer1508" authentik-server-1 ak shell < ~/trip-web/deploy/authentik_setup.py > ~/trip-web/.authentik-setup.out 2>&1)
```

3. Lesbare Meldungen anzeigen (ohne Secrets):

```bash
grep '^TRIP|' ~/trip-web/.authentik-setup.out
```

4. `.env` anlegen und mit den Werten für die Website füllen:

```bash
cd ~/trip-web && (umask 077; cp .env.example .env) && sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')|" .env && grep '^TRIPENV|' .authentik-setup.out | sed 's/^TRIPENV|//' | while IFS='=' read -r k v; do case "$k" in OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|MCP_CLIENT_ID) sed -i "s|^$k=.*|$k=$v|" .env;; esac; done
```

5. Client-ID und Secret für claude.ai anzeigen (nur im Terminal). Sie kommen in claude.ai unter Connector > Advanced settings:

```bash
grep '^TRIPENV|MCP_CLIENT_' ~/trip-web/.authentik-setup.out
```

6. Danach die Datei mit den Secrets löschen:

```bash
shred -u ~/trip-web/.authentik-setup.out
```

## Familie hinzufügen

Directory > Groups > `trip-family` > Users > Add existing user. Wer nicht in der Gruppe ist, bekommt von Authentik eine
Zugriff-verweigert-Seite.

## Hinweise

* Das Skript lässt vorhandene Apps unangetastet und druckt deren Secrets nie wieder. Zweiter Lauf ist ungefährlich.
* Authentik 2026.8 kennt auch Dynamic Client Registration (Scope `goauthentik.io/oidc/dcr`). Das Skript nutzt sie nicht;
  Claude bekommt feste Zugangsdaten.
* Rückgängig: Applications > `trip-web` / `trip-claude` löschen, dann die Providers `trip-web-provider` / `trip-claude-provider`,
  dann die Gruppe `trip-family`.
