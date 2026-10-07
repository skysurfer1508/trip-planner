# Trip Planner

A SwiftUI trip planner with a live "tour guide" mode. iOS 17+, iPhone, no backend.
Everything works without accounts; optional API keys unlock popularity data and cloud AI.

## Run it (on your Mac)

```bash
brew install xcodegen
git pull
xcodegen            # generates TripPlanner.xcodeproj from project.yml
open TripPlanner.xcodeproj
```

In Xcode: select the **TripPlanner** target, then under *Signing & Capabilities* choose your Apple ID
team (a free personal team works). If the bundle ID `com.skysurfer.TripPlanner` is taken, change
`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and re-run `xcodegen`.

Free Apple accounts allow only 3 apps installed per device and 10 new App IDs per 7 days, so the
lock screen countdown (Live Activity, needs a second App ID for its widget) is off by default. To turn
it on later, follow the comment in `project.yml` and set `AppFeatures.liveActivities = true`.

Run tests with Cmd+U.

## How the app is organised

**Trips list**: hero-photo cards. **New trip** is a 3-step wizard (where, when, how to start: empty,
import a program, or Auto plan). Destination autocomplete sets the trip's location; *Browse
destination ideas* shows curated cities with Wikipedia photos.

Each trip has five tabs:

| Tab | What it does |
|---|---|
| **Overview** | Countdown or today's plan, weather, stats, a "Get ready" checklist (destination, stops, bookings, budget, packing) and quick actions. |
| **Plan** | Every day starts from your hotel (first row and pin, route and travel time begin there). Each stop has a photo and a short description from Wikipedia (stored on the stop, so it works offline; add your own photo anywhere Wikipedia has nothing). Days, map, place search, reorder, move/duplicate stops, copy a day, **Set times** (auto schedule from a start time), **Optimize route**, sort by time, travel time between stops, saved places, share/export, **full-screen map** with a drop-pin mode. |
| **Discover** | Top sights, culture, nature, food and fun ranked by OpenTripMap + Tripadvisor popularity; bookmark places for later. |
| **Budget** | Budget, expenses in any currency (converted with free rates), totals and charts. |
| **More** | Packing & to-do, Documents (offline), Saved places, Share & export, edit trip, Settings. |

**Flights & hotel** (Overview → Get ready, or More): add your arrival flight, hotel and flight home. For a flight, type the flight number and date (e.g. LH 1234): the app looks it up and fills in both airports,
the airport location and the scheduled local times by itself (needs the free AeroDataBox key from Settings; the airline
name shows even without it). For a hotel, search by name or by the address from your booking (hotels, hostels, apartments and private
rentals work); results are ranked by name match, can be sorted by distance from the centre, and show phone, website
and, with a Tripadvisor key, ratings. It only identifies the place so days can start from it: nothing is booked or
priced in the app. Enter the check-in and check-out times from your booking. The app then knows: the first day starts after you land
(plus a buffer you set for the airport and the way to the hotel), the last day ends in time to get to the airport,
the hotel is where every day starts from (Auto plan and Optimize route), stops outside those limits get a warning, and
Trip Mode shows landing, check-in/out and when to leave for the airport. One tap adds landing, check-in/out, leaving
for the airport and take-off to the plan, and you get reminders (evening before a flight, time to leave, check-out).

**Trip Mode** (location arrow in the toolbar): today's plan with progress, next stop with walk/transit/drive ETA
and a "Leave by" countdown, Navigate in Apple Maps, quick lookups (coffee, ATM, pharmacy, restrooms),
**I'm hungry** (cuisine/takeaway/vegetarian filters, Tripadvisor "Top rated"), **What now?** (AI ranks real
nearby places and your remaining stops for the time and weather), departure reminders, re-flow when you run late.

## Auto plan

Overview → Auto plan (also in the Plan menu and the new-trip wizard). It asks a few questions: who's going
(solo, couple, friends, family with kids, group), days and pace, what you like (sights, museums, food, cafés,
nature, beaches, shopping, nightlife, family activities, adventure, hidden gems), food and cuisines, nightlife style,
how you get around, budget and must-see places. It then builds the days from real, popular places
(OpenTripMap, Tripadvisor, Apple Maps): compact areas per day, lunch and dinner at normal hours, nightlife only
when it fits, times that include travel. You review the result like an import, can tap **Create again** for
another version, and choose whether to add it or replace the current stops. No AI is needed; if an AI engine is
available it only writes the day titles. Your answers are remembered per trip.

## AI (free)

Settings → AI engine:

- **Automatic** (default): Apple Intelligence on the phone when available (iOS 26 + supported iPhone). Free,
  private, works offline. Otherwise Gemini if you added a key. Otherwise AI features are off and import uses
  basic on-device reading.
- **Gemini**: free key from [Google AI Studio](https://aistudio.google.com/apikey), no card. The free tier may
  use your prompts to improve Google's products, so documents are only sent to Gemini when it is the engine in use.
- AI is used for: reading imported programs, naming Auto plan days, ranking "What now?" picks, and short place tips.
  AI never invents places: names are matched to real map results and unmatched ones can't be added.

## Import a program

Plan → ⊕ → Import program: PDF, Word (.docx), a photo/screenshot or a text file. Scanned pages are read with
on-device OCR. Stops are found with AI or basic reading, matched to places in Apple Maps and shown for review
(untick, rename, re-pick a place, choose the day) before anything is added. A copy can be kept in Documents.

## Backup and sharing

Trips only live on your iPhone. **Settings → Backup → Back up all trips** saves a `.tripplanner` file (Files,
iCloud Drive, AirDrop). **Plan → Share & export → Send the trip file** shares one trip; a friend who opens it
with the app gets their own copy. Restoring always adds copies and never overwrites. Itineraries can also be
shared as text or exported to Calendar (.ics).

## Optional API keys (Settings, gear icon)

Keys are stored in the iOS Keychain on the device. Nothing is in the repo.

| Service | Needed for | Cost |
|---|---|---|
| [OpenTripMap](https://opentripmap.io/product) | Popularity ranking of sights | Free |
| [Tripadvisor Content API](https://www.tripadvisor.com/developers) | Ratings, reviews, rankings | Free monthly allowance, key required |
| [AeroDataBox on RapidAPI](https://rapidapi.com/aedbx-aedbx/api/aerodatabox) | Flight lookup by flight number and date | Free Basic plan (a few hundred lookups a month); RapidAPI may ask for a card to sign up |
| [Gemini](https://aistudio.google.com/apikey) | AI when Apple Intelligence isn't available | Free tier, no card |

Tripadvisor terms: results show "Ratings by Tripadvisor" with a link back, and are only cached in memory for the
session. Each Discover load uses about 11 Tripadvisor calls.

## Good to know

- Apple Maps search has no ratings, prices or opening hours; Tripadvisor fills that gap for ratings.
- Weather: [Open-Meteo](https://open-meteo.com) (free, no key), about 16 days ahead.
- Exchange rates: open.er-api.com (free); the last rates are kept for offline use.
- MapKit has no offline-maps API. Use Apple Maps' own *Download Map* (iOS 17+) for offline maps; stops, notes,
  budget, packing list and documents are stored on the device and work offline.
- Transit ETAs aren't available in every city; the app falls back to an estimate.
- On-device import works best with day headings ("Day 2", "Monday, June 5"), times ("10:00") and one place per
  line. For anything messier, use an AI engine.
- The on-device AI has a small context window, so long documents are processed in chunks.

## Testing in the simulator

Set a location with *Features → Location → Custom Location*. Give a stop a planned time a few minutes ahead to
see reminders and the re-flow banner. Apple Intelligence and notifications are most reliable on a real iPhone.
