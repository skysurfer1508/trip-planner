# TripPlanner design system ("Calm modern")

Code lives in `TripPlanner/DesignSystem/`. Views use these tokens and components. They do not use colour
literals, numeric corner radii, or ad-hoc paddings. `DesignSystemGallery.swift` (debug builds) shows all of it
on one screen, with previews for light, dark and AX3.

## Principles
1. Quiet surfaces, one accent. Photos and the map carry the colour.
2. Colour is never the only signal: status has an icon, selection has a checkmark, pins differ in shape.
3. Glass (iOS 26) is only for the floating navigation layer. See `LiquidGlassReference.md`.
4. Motion is short and optional: it all goes through `Motion` and respects Reduce Motion.

## Colour (`Theme`)
Asset Catalog sets, each with light, dark, light + Increase Contrast, dark + Increase Contrast. Regenerate them
from the table in the colour script if you change a value, and re-check contrast.

| Role | Light | Dark | Use |
|---|---|---|---|
| `background` | #F3F6F5 | #0D1513 | Screen background |
| `surface` | #FFFFFF | #162320 | Cards, rows, chips |
| `surfaceRaised` | #FFFFFF | #1E2E2A | Floating content |
| `separator` | #D3DDDA | #2A3A36 | Hairlines (not text) |
| `ink` | #12201D | #EAF1EF | Primary text |
| `inkSecondary` | #55655F | #9DB0AA | Secondary text |
| `accent` (AccentColor) | #0F7B6C | #4CC3A8 | Primary actions, selection |
| `onAccent` | #FFFFFF | #06201A | Text on accent and on day fills |
| `success` / `warning` / `danger` / `info` | #1B7A3E / #8F4F00 / #B3261E / #1F5FA8 | #6FD48F / #FFB454 / #FF8F85 / #8FBBF2 | Status, always with an icon |

All text colours are at least 4.5:1 against `background`, `surface` and `surfaceRaised` in all four variants.

### Days and categories (they no longer collide)
- **Day = a solid fill** (pill, route line, map pin): `Theme.day(index)`, 8 colours then cycle.
  Blue, vermilion, violet, magenta, ochre, cyan, brick, slate.
- **Category = a glyph tint on a neutral surface** (list rows, chips): `Theme.category(_:)`.
  Sight olive, food tomato, café umber, hotel slate, transport graphite, nightlife aubergine, other stone.
- Category colour is never a pin or route fill. `StopCategory.color` returns the tint.

## Spacing, radius, elevation (`Tokens.swift`)
- `Spacing`: xs 4, s 8, m 12, l 16, xl 24, xxl 32.
- `Radius`: small 10 (chips, thumbnails), card 20, hero 28. Use `Radius.shape(_:)` for continuous corners.
- `Elevation`: `.none`, `.raised` (cards, one soft shadow, none in dark), `.floating` (FAB, selected pin).

## Typography (`Typography.swift`)
Roles: `display`, `title`, `headline`, `body`, `label`, `caption`, `eyebrow`, `numeric`. Apply with
`.textRole(.title)`. `.eyebrow()` replaces the hand-written `.caption.bold().secondary` labels.
SF Rounded for titles, numbers and pins, SF Pro for running text. All are Dynamic Type styles.
`@ScaledMetric` is used for icon columns, pins and FAB sizes.

## Components (`DesignSystem/Components/`)
| Component | Replaces |
|---|---|
| `Card` / `.card()` | Old `.thinMaterial` `.card()` and inline material cards |
| `Banner(kind:title:message:)` | Inline orange/blue tinted banners in TodayView, DayStopListView, DayAlertsView |
| `InfoRow` | `MoreView.row`, `logisticsCard`, `logisticsToday` |
| `Chip`, `SelectableChip` | `FilterChip`, day chip, `SelectTile` |
| `.primary`, `.secondary` button styles | Ad-hoc `.borderedProminent` buttons |
| `SectionHeader` | Hand-made section titles |
| `Pin(kind:)` | StopPin, HotelPin (done). EndPin, EntrancePin, StationDot (Transit, pending) |
| `SkeletonView` | Bare `ProgressView` while loading |
| `EmptyState` | Direct `ContentUnavailableView` use |
| `.floatingChrome()`, `FloatingActionButton` | Inline materials on floating controls. The only place that uses `glassEffect` |

## Motion and haptics (`Motion.swift`)
- `Motion.state` (`.smooth(duration: 0.35)`) for state changes, `Motion.snappy` for presses and chips,
  `Motion.fade` (150 ms) for content.
- Use `.motion(_:value:)` or `Motion.perform` so Reduce Motion makes it instant.
- Nothing loops, except the skeleton shimmer, which runs only while loading and is static under Reduce Motion.
- `Haptics.select / impact / success / warning`.

## Accessibility rules
- Tap targets are at least 44x44 pt (chips and section actions pad their hit area).
- Every icon-only control has an `accessibilityLabel`.
- Reduce Transparency: `FloatingChrome` swaps glass/material for a solid surface.
- Increase Contrast: cards get a stronger hairline, and every colour has a high-contrast variant.

## Migration status
Done: colour sets, tokens, components, pins, `StopCategory.color`, `DayPalette`.
Pending (see commits): the `.padding`, `.cornerRadius`, colour-literal and `.font(.system(size:))` sweep;
FilterChip and other chips; banners; the screens in Phases 2 and 3.
