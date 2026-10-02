# Trip Planner

A SwiftUI trip planner with a live "tour guide" mode. iOS 17+, iPhone, no backend, no API keys.

## Run it (on your Mac)

```bash
brew install xcodegen
cd trip-planner
xcodegen            # generates TripPlanner.xcodeproj from project.yml
open TripPlanner.xcodeproj
```

In Xcode: select the **TripPlanner** target and the **TripPlannerWidgets** target, then under
*Signing & Capabilities* choose your Apple ID team (a free personal team works). If the bundle ID
`com.skysurfer.TripPlanner` is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`
(keep the widget's ID prefixed with the app's) and re-run `xcodegen`.

Run tests with Cmd+U (`ScheduleServiceTests`).

## What's in it

- **Trips and days**: create a trip with dates, days are generated automatically.
- **Planner**: day tabs, map with numbered pins and route line, add places via Apple Maps search,
  reorder with *Edit*, set time, stay length, notes.
- **Trip Mode** (location arrow in the planner): today's plan, next stop with ETA by walk/transit/car,
  *Navigate* opens Apple Maps, tick stops off.
- **I'm hungry**: nearby restaurants with cuisine, takeaway, vegetarian and distance filters.
  Add to today's plan or navigate.
- **Smart layer** (menu in Trip Mode): departure reminders, "you're behind schedule" re-flow,
  weather with a rain warning for outdoor stops, lock screen countdown (Live Activity).

## Testing Trip Mode in the simulator

Set a location with *Features → Location → Custom Location* (or *City Run*). Give a stop a planned
time a few minutes ahead to see reminders and the re-flow banner.

## Limits of the free data

- Apple Maps search has **no ratings, prices or opening hours**, so "hungry" filters by cuisine, distance
  and category only.
- Weather comes from [Open-Meteo](https://open-meteo.com) (free, no key) and covers about 16 days ahead.
- Transit ETAs are not available in every city; the app falls back to an estimate.
