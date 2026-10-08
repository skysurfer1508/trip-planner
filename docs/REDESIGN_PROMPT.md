You are redesigning the UI of TripPlanner, an iPhone-only SwiftUI/SwiftData travel
planner (iOS 17+ deployment target, XcodeGen via project.yml, no backend). The
features are solid; the look is stock iOS. Goal: make it feel like a hand-crafted,
award-quality native iOS app, comparable to the best indie travel apps, WITHOUT
changing behaviour, data models or Services/.

## Ground rules
- Native first. SwiftUI only, SF Symbols, system fonts with deliberate design
  variants (e.g. `.rounded` for numerals/badges, one serif display face only if the
  chosen direction calls for it). No third-party UI packages.
- Keep iOS 17 as the deployment target. Adopt iOS 26 Liquid Glass behind
  `if #available(iOS 26, *)` and fall back to `.thinMaterial`/`.bar` on iOS 17-25.
  Your training data may predate iOS 26: read Apple's documentation (or
  docs/LiquidGlassReference.md if it exists) before using `glassEffect`,
  `GlassEffectContainer`, `.buttonStyle(.glass)`, `.tabBarMinimizeBehavior`.
  Do not guess API signatures.
- Glass is for the floating navigation layer only (tab bar, toolbars, floating
  action buttons, sheets). Never on content cards, lists or text over photos.
  Never glass-on-glass. Tint only primary actions.
- Do not touch Services/ or Models/ except adding purely presentational helpers.
  All existing unit tests in TripPlannerTests (260+) must still pass.
- Banned "AI slop": purple/blue gradients, emoji as icons, a rounded-square badge
  behind every icon, coloured left-border cards, drop shadows on everything,
  decorative blobs, the same card style repeated ten times in a row.
- Accessibility is a requirement, not polish: Dynamic Type up to AX3 without
  clipping, @ScaledMetric for icon/thumbnail/pin sizes, 44x44pt minimum tap
  targets, WCAG AA contrast (4.5:1 text) in light AND dark, never colour-only
  status (add icon or text), honour Reduce Motion / Reduce Transparency /
  Increase Contrast, VoiceOver labels on every icon button.

## Current state (from a code audit - verify before relying on it)
- No design system: no theme/tokens, 10 different corner radii, ~129 ad-hoc
  `.padding()` values, colours picked per screen (.orange/.red/.green literals),
  one teal-blue AccentColor with no dark variant, placeholder-style app icon.
- `List`/`Form` dominate (Plan tab stops, MoreView, StopDetailView, Budget, Settings).
- Plan tab stacks nav title + custom TabHeader + day picker + 220pt map + weather
  + alerts before the first stop. Overview is ~10 equal-weight cards. Trip Mode
  (the signature feature) is a tiny toolbar icon. Core tools hide under "More".
- `sparkles` is used for both the Discover tab and the AI chat button.
- Five different map pin styles (StopPin, HotelPin, EndPin, EntrancePin, StationDot).
- Stop category colours and day colours (DayPalette in DayMapView.swift) overlap.
- Almost no motion/haptics; bare ProgressView spinners instead of skeletons.
- Keep: consistent ContentUnavailableView empty states, the wizard pattern
  (NewTripWizard, AutoPlanFlowView, OptionCard), hero-photo trip cards, the
  information architecture and feature depth.
- Key files: Features/TripList/TripListView.swift, Features/Trip/OverviewView.swift,
  Features/Trip/MoreView.swift, Features/Planner/PlannerView.swift,
  Features/Planner/DayStopListView.swift, Features/TripMode/TodayView.swift,
  Features/Rain/DayAlertsView.swift, Features/Hungry/FilterChip.swift,
  Shared/TripHeroImage.swift (contains `.card()`), Shared/TabHeader.swift.

## Phase 0 - Direction (stop and ask me before continuing)
Propose THREE distinct design directions for this app, each with: one-line
concept, accent colour + neutral palette (light and dark hex), type pairing,
corner/elevation language, and how Overview, Plan and Today would look. Render
each as a quick SwiftUI #Preview of the Overview hero + one stop row, screenshot
them in the simulator, and recommend one. Suggested starting points:
  A. "Warm editorial": magazine feel, large photography, warm off-white / deep ink,
     one terracotta or saffron accent, serif display titles, generous whitespace.
  B. "Calm modern": soft neutrals, rounded design font, one fresh accent
     (e.g. sea-green), Liquid Glass chrome, airy cards.
  C. "Expressive": bold per-trip colour taken from the hero photo, big type,
     strong motion; the trip's colour themes the whole trip hub.
Also decide what the colour of each STOP CATEGORY and each DAY is, so they no
longer collide (today both use blue/orange/purple).

## Phase 1 - Design system (new folder TripPlanner/DesignSystem/)
Create and document (header comments, plus docs/DESIGN_SYSTEM.md):
- `Theme.swift`: semantic colour roles (background, surface, surfaceRaised, ink,
  inkSecondary, accent, success, warning, danger, info) as Asset Catalog colour
  sets with light + dark + high-contrast variants; replace AccentColor.
- `Spacing` (4-pt scale: xs 4, s 8, m 12, l 16, xl 24, xxl 32), `Radius` (exactly
  three: small 10, card 20, hero 28 - or the direction's equivalents),
  `Elevation` (none / raised / floating; at most two shadow recipes).
- `Typography`: a small set of text roles (display, title, headline, body,
  label, eyebrow, numeric) built on Dynamic-Type-scaling fonts. Replace the
  hand-copied `.caption.bold().secondary` eyebrows with `.eyebrow()`.
- Components: `Card` (replaces `.card()` and all inline `.thinMaterial` cards),
  `Banner(kind:)` (info/warning/danger/success; replaces every inline
  orange/blue tinted banner in TodayView, DayStopListView, DayAlertsView),
  `InfoRow` (icon + title + detail; replaces MoreView.row, logisticsCard,
  logisticsToday), `Chip`/`SelectableChip` (merge FilterChip, day chip, SelectTile),
  `PrimaryButtonStyle`/`SecondaryButtonStyle`, `SectionHeader`, `Pin(kind:)`
  (one pin component for stop, hotel, end, entrance, station), `SkeletonView`
  (shimmer placeholder), `EmptyState` wrapper over ContentUnavailableView.
- Haptics helper (`Haptics.select/impact/success/warning`) and a motion spec:
  one spring (`.smooth(duration: 0.35)` / `.snappy`) for state changes, 150ms
  fades for content, nothing that loops.
- Add an app icon (1024 + dark + tinted variants) matching the chosen direction.
Then do a mechanical migration pass: grep every `.cornerRadius(`, `.padding(`
literal, `Color.orange/.red/.green/.blue`, `.font(.system(size:` and replace with
tokens. Report remaining stragglers.

## Phase 2 - Navigation shell and hero screens (screenshot each, light + dark)
1. **Trip list** (TripListView): bigger, more editorial cards; photo-first with a
   readable scrim (verify text contrast over bright photos); LIVE pill; a
   "happening now / next trip" featured card on top; smooth matched-geometry
   transition from card to TripHub; 44pt menu target.
2. **TripHub tab bar**: Overview, Plan, Discover, Budget, More. On iOS 26 use the
   system glass tab bar with `.tabBarMinimizeBehavior(.onScrollDown)`; on older
   iOS the standard bar. Give AI and Discover DIFFERENT icons. Promote Trip Mode:
   when the trip is live, show a floating "Today" button/bottom accessory;
   otherwise a clear entry card on Overview. Move Flights & hotel, Packing and
   Documents out of "More" into Overview shortcuts so More only holds
   settings-like items.
3. **Overview**: replace the 10-equal-card stack with a clear hierarchy:
   parallax hero with trip title, dates, countdown; ONE primary "Today / Next up"
   card; a compact horizontal strip for flights/hotel; a 2x2 grid of secondary
   tools; a collapsible "Get ready" checklist with progress ring. Everything else
   (transit guide, offline pack, practical info, weather) becomes a tidy
   secondary section. Max three visual weights on screen at once.
4. **Plan tab**: remove the duplicate trip title/TabHeader; single large nav
   title. Replace the `List` with a custom vertical TIMELINE: a continuous line
   with numbered category pins (the single Pin component), time on the left,
   stop card on the right with photo, name, duration, opening-hours state and
   travel leg (walk/transit/drive) as a connector between stops. Day picker
   becomes a sticky pill strip with date + weekday + stop count and the day's
   colour. The map becomes a draggable bottom-sheet/inline pair (collapsed strip
   -> half -> full) with synced selection: tapping a stop highlights its pin and
   vice versa. Drag-to-reorder with haptic pickup/drop and animated re-numbering.
   Show an elegant empty-day state with one clear "Add place" action.
5. **Today / Trip Mode**: make it the showpiece. Large "Next up" card with photo,
   live "Leave by" countdown, travel-mode segmented control, Navigate / Done
   buttons; a compact day progress rail; floating "I'm hungry" button as a proper
   glass/FAB component; weather and reflow banners via `Banner`.

## Phase 3 - Remaining screens
Stop detail (photo header with parallax, sticky action bar, opening hours as a
week strip with today highlighted, replace the stock Form), Discover (visual
cards with photo + rating + distance, filter chips, skeleton loading), Budget
(progress ring vs. budget, category bars, grouped list with day headers),
Bookings (boarding-pass style flight card, hotel card with check-in/out), New
trip wizard + Auto plan (reuse OptionCard visuals, add subtle step transitions
and a progress bar), Import/review, Packing (satisfying check animation +
haptic), Documents, Practical info, Settings (grouped, still a Form but themed),
Transit sheets (unify line badges), PDF export and Live Activity (re-theme with
the same tokens).

## Phase 4 - Polish
- Motion: tab/day-change transitions, card -> detail matched geometry,
  `symbolEffect` on state changes (check, bookmark), number-flow style countdown,
  haptics on add/reorder/complete/delete. All gated by Reduce Motion.
- Loading: skeletons instead of bare ProgressView; photo placeholders with a
  category glyph instead of an empty gradient.
- Maps: one pin style, selected-stop callout, route in the day colour, optional
  clustering for Discover.
- Onboarding: a 3-screen first-run (value prop, location/notification
  permissions explained in context), skippable.

## Working method (follow exactly)
1. After each phase and each screen, build and run in the iPhone simulator,
   take screenshots in light, dark, and Dynamic Type AX3, and LOOK at them
   (read the image). Fix visible problems before moving on. Do not claim a screen
   is done without having seen it.
2. Commit per screen/component with a message describing the design change.
   Never batch the whole redesign into one commit.
3. After each phase run the full test suite and the XcodeGen build; fix
   regressions immediately.
4. After each phase run a self-review against five axes, scoring 1-10 with fixes
   for anything below 7: philosophy consistency (matches the chosen direction),
   visual hierarchy, detail execution (spacing/type/colour from tokens only),
   functionality, and one memorable signature detail.
5. Finish with an audit pass over the whole project: list any remaining
   hardcoded colours/sizes/radii, any tap target < 44pt, any text < 4.5:1
   contrast, any view that clips at AX3, any glass used on content.
6. If a decision is subjective (colour, icon, copy tone), show me 2-3 options
   instead of picking silently.

Start with Phase 0 only. Do not write production code until I pick a direction.
