# Trip Planner

A SwiftUI trip planner with a live "tour guide" mode. iOS 17+, iPhone, no backend.
Everything works without accounts; optional API keys unlock popularity data and smarter import.

## Run it (on your Mac)

```bash
brew install xcodegen
git pull
xcodegen            # generates TripPlanner.xcodeproj from project.yml
open TripPlanner.xcodeproj
```

In Xcode: select the **TripPlanner** target, then under *Signing & Capabilities* choose your Apple ID
team (a free personal team works).

The lock screen countdown (Live Activity) needs a second App ID for its widget extension. Free Apple
accounts can only create 10 App IDs per 7 days, so it is off by default. To turn it on later, follow the
comment in `project.yml` and set `AppFeatures.liveActivities = true`. If the bundle ID
`com.skysurfer.TripPlanner` is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`
(keep the widget's ID prefixed with the app's) and re-run `xcodegen`.

Run tests with Cmd+U (`ScheduleServiceTests`, `ItineraryParserTests`, `RouteOptimizerTests`).

## Features

**Trips**
- Destination autocomplete (Apple Maps) that sets the trip's location, plus *Browse destination ideas*
  (curated list with Wikipedia photos and descriptions). The location drives place search, weather,
  Discover and Trip Mode.

**Plan tab**
- Days, map with numbered pins and route, place search, reorder, time/stay/notes/estimated cost,
  phone and website of a place.
- Travel time between consecutive stops and a day summary (stops, time, distance, cost).
- **Optimize route** (shortest walk, first stop stays first) and **Sort by time**.
- **Saved places**: bookmark ideas from Discover and move them to a day later.
- **Share & export**: itinerary as text, or timed stops as calendar events (.ics).
- **Import program**: PDF, Word (.docx), a photo/screenshot, or text. Scanned pages are read with
  on-device OCR. Stops are found either on the device (free) or with Claude (optional key), matched to
  real places in Apple Maps, and shown for review before anything is added. A copy of the file can be
  kept in Documents.

**Discover tab**
- Top sights, culture, nature, food and fun around the destination, ranked by popularity:
  OpenTripMap rating + Tripadvisor rating/review count, merged into one list. Falls back to plain Apple
  Maps results when no keys are set.

**Budget tab**: budget, expenses in any currency (converted with free exchange rates), totals by
category and day, planned costs from stops.

**Packing tab**: suggested packing list (uses the forecast for climate and rain) plus a "before you go"
to-do list.

**Documents tab**: tickets, bookings and ID scans stored on the device and viewable offline.

**Trip Mode** (location arrow in the trip toolbar)
- Today's plan with progress, next stop with walk/transit/drive ETA and a "Leave by" countdown,
  Navigate in Apple Maps, tick stops off.
- Quick lookups: coffee, ATM, pharmacy, restrooms.
- **I'm hungry**: nearby food with cuisine, takeaway, vegetarian and distance filters; *Top rated*
  (Tripadvisor) when a key is set.
- Departure reminders, "you're behind schedule" re-flow, weather and rain warnings, lock screen countdown.
- If you aren't at the destination yet, it uses the trip's destination instead of your location.

## API keys (Settings, gear icon on the trip list)

Keys are stored in the iOS Keychain on the device. Nothing is in the repo.

| Service | Needed for | Cost |
|---|---|---|
| [OpenTripMap](https://opentripmap.io/product) | Popularity ranking of sights | Free |
| [Tripadvisor Content API](https://www.tripadvisor.com/developers) | Ratings, reviews, rankings | Free monthly allowance, key required |
| [Anthropic](https://console.anthropic.com/settings/keys) | "Claude" option in Import program | Pay per use, cents per document |

Tripadvisor terms: results show "Ratings by Tripadvisor" with a link back, and are only cached in
memory for the session. Each Discover load uses about 11 Tripadvisor calls (1 search + up to 10 details).

## Good to know

- Apple Maps search has no ratings, prices or opening hours; Tripadvisor fills that gap for ratings.
- Weather comes from [Open-Meteo](https://open-meteo.com) (free, no key), about 16 days ahead.
- Exchange rates from open.er-api.com (free); the last rates are kept for offline use.
- MapKit has no offline-maps API. For offline maps, use Apple Maps' own *Download Map* (iOS 17+); stops,
  notes, budget, packing list and documents are stored on the device and work offline.
- Transit ETAs aren't available in every city; the app falls back to an estimate.
- On-device import works best with day headings ("Day 2", "Monday, June 5"), times ("10:00") and one
  place per line. For anything messier, use the Claude option.

## Testing in the simulator

Set a location with *Features → Location → Custom Location*. Give a stop a planned time a few minutes
ahead to see reminders and the re-flow banner. Live Activities and notifications are most reliable on a
real iPhone.
