# Trip Web

The family's trip planner for the Japan 2027 trip, as a website, with a connector so Claude can read and write the same data.
Whatever Claude enters appears on the website within a few seconds. Runs on the home server like the other apps:
FastAPI + SQLite, login through Authentik, reached through the existing Cloudflare tunnel.

```
Claude (claude.ai, one shared account) --MCP/OAuth--> /mcp ----+
Family (browser, Authentik login) ----------------------------+--> app/service.py --> SQLite (data/trip.db)
```

* `app/service.py` is the only place that changes data. The website and the connector both use it, so both get the same
  checks, the same change log (who, via website or Claude) and the same undo.
* `app/entities.py` says which fields exist and what values are allowed. Unknown fields and bad values are refused with a
  message Claude can act on.
* Times are the local time of the place (`2027-07-20T09:30`, no time zone), like in the iOS app.
* Claude's account is shared by the family, so every write carries `acting_member` (who is writing); it shows in the history.
* Every trip has members with a role (owner, editor, viewer); a trip is invisible to everyone else, on the website and for
  Claude. Claude acts as the Authentik user who connected it. The Authentik group `trip-family` only decides who may sign in at
  all; sharing a trip is done per trip (`python -m app.cli share`, or on the website once the sharing screen exists).

## What the website does

Ideas have a **category** (temple, shopping, nature and mountains …; guessed from the name, changeable) and a **region**, and the ideas
view has a full filter: search, region, category, priority, decision, duration, who it is for, who wished it, only places on the map; with
counts that say what a tap would give, sorting, and grouping by region. The map zooms with the mouse wheel, can be enlarged to the full
screen, and can be coloured by priority or by category.

The **route** (tab Route, in both phases) is the chain of places: Tokyo → Osaka → Hiroshima. Each move is a *hop* with one or more ways of
doing it (Nozomi, Hikari, night bus, flight), each with line, duration, price per person (any currency, converted), times, notes and the
source with its date. The family chooses one per hop; the chosen ways are drawn on the map and added up for everyone (the trip's number of
travelers). There is no open source of timetables and fares for Japan, so Claude proposes the numbers from what it knows or finds, with the
source, and the website stores, compares and draws them.

Every trip has a **phase**. In the **planning phase** the family collects ideas on a map (Muss / Gerne / Falls Zeit, Ja / Nein / Offen),
adds places by search and keeps a list of decisions and open questions. When flights and dates are known the trip moves to the
**building phase**, where it is built day by day like in the iOS app:

* **Plan**: add stops (place search, from the ideas, or by hand), edit, reorder, move to another day, duplicate, copy a day, sort by time,
  optimise the route, lay the times out again (with the way between stops), put flights and hotels on the plan. Flights and the hotel
  show what they mean for each day (earliest start after landing, latest end before the airport trip, start from the hotel).
* **Buchungen**, **Budget** (expenses in any currency, converted with open.er-api.com, per category and day, planned in stops),
  **Packliste** (with starter lists).
* **Export**: `.tripplanner` file for the app, calendar (`.ics`), text. **Import** of a `.tripplanner` file asks for the phone's time
  zone, because the file does not contain one, and shows the first converted times before anything is created.
* Everything is one entry in the history and can be undone; Claude can do the same things through the connector.

The planning rules are ported from the iOS app (`app/planning.py`); their tests use the expected values of the app's own unit tests.

## Run it locally

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
(cd web && npm install && npm run build)          # builds the site into static/
DEV_LOGIN=true .venv/bin/python -m app.cli seed   # starting data (only into an empty database)
DEV_LOGIN=true .venv/bin/uvicorn app.main:app --port 8095
```

`DEV_LOGIN=true` lets `/login` sign you in as a fake user, but only for requests from the machine itself. Never set it on the server.
Tests: `.venv/bin/python -m pytest -q`.

## Deploy on the server

1. `cp .env.example .env` and fill it in (see the comments there).
2. Authentik: create two OAuth2/OpenID providers and applications, `trip-web` and `trip-claude` (see `.env.example`).
3. `sudo cp deploy/trip-web.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now trip-web`
4. `.venv/bin/python -m app.cli seed` once.
5. Cloudflare Zero Trust > Networks > Tunnels > the existing tunnel > Public Hostname: `trip.skyserver1508.org` -> HTTP
   `192.168.0.123:8095`. If an Access policy sits in front of the hostname it must let `/mcp`, `/.well-known/*` and
   `/mcp-secret/*` through, because Claude's servers cannot sign in to Cloudflare Access.
6. claude.ai > Settings > Connectors > Add custom connector: URL `https://trip.skyserver1508.org/mcp`, and under Advanced settings
   the client id and secret of the `trip-claude` provider.

Who sees what (run from `~/trip-web` after `set -a; . ./.env; set +a`):

```bash
.venv/bin/python -m app.cli claim <name|username|e-mail>      # owner of all trips that have no member yet
.venv/bin/python -m app.cli share <trip> <person> <role>      # viewer, editor or owner
.venv/bin/python -m app.cli members
```

An update that changes the database makes a copy first (`data/trip.db.bak-v<old>-<time>`) and then migrates it by itself at start.

Backup: `.venv/bin/python -m app.cli export > backup.json`, or copy `data/trip.db` while the service is stopped.
