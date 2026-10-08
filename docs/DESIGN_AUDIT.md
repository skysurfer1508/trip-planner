# Design audit

Written after the redesign pass. It lists what was checked and how, and what could not be checked.

## How it was checked
- **Build and tests:** every push to `main` runs the full unit test suite on a macOS runner (see
  `.github/workflows/ci.yml`). The commits up to "Wizard and option cards" passed.
- **Contrast:** all colour tokens were checked with `docs/tools/generate_color_sets.py`, which fails on any
  text pair below 4.5:1 in light, dark, light + Increase Contrast and dark + Increase Contrast.
- **Code scans:** the numbers below come from `grep` over `TripPlanner/`.

## What could NOT be checked (needs a Mac, a simulator and eyes)
- How any screen actually looks, in light, dark and at Dynamic Type AX3. No screenshots were taken.
- Clipping at AX3. The layouts switch to stacked arrangements at accessibility sizes (timeline time column,
  action bars, summary lines) but this is untested.
- Text on photos. The scrims were designed for the worst case (a white photo gives about 12:1 for white
  text at the bottom) but not tried on real photos.
- VoiceOver order, Reduce Motion and Reduce Transparency behaviour on a device.
- Liquid Glass on iOS 26: the code path compiles in CI only if the runner's Xcode has the iOS 26 SDK.
- Drag-to-reorder on the Plan timeline, the map detents, and the zoom transition.

## Leftover hard-coded values (outside `DesignSystem/`)
| Kind | Count | Notes |
|---|---|---|
| `RoundedRectangle(cornerRadius:)` | 1 | `Services/PlacePreviewStore.swift` (Services untouched) |
| `.cornerRadius(` | 0 | |
| `.padding(<number>)` | 14 | 1-2 pt text nudges and indents (36, 40, 48) tied to row layouts |
| Stack `spacing:` other than 0 | about 37 | almost all `2` or `3` between text lines |
| Named colours (`.red` etc.) | 0 in features | transit agency colours come from data |
| `Color.white` / `Color.black` | 5 | text and scrims over photos and maps (intentional) |
| `.font(.system(size:))` | 11 plus the PDF | glyphs scaled from a `@ScaledMetric` size (pins, thumbnails), decorative onboarding and hero glyphs, and the printed PDF |

## Tap targets under 44 pt
Interactive controls were raised to 44 pt (chips, day pills, rows, toolbar and menu buttons, send buttons, call
buttons, checkboxes). Decorative or non-interactive frames under 44 pt remain on purpose (rails, dots, notches,
progress bars). Not verified by measuring on a device.

## Text contrast
- Tokens: verified (see above).
- Text over photos or maps uses white on a dark scrim, or a fixed dark pill.
- `.tertiary` text styles were removed from text. They remain on a few decorative chevrons and photo glyphs.

## Glass
`glassEffect` is only called in `DesignSystem/Components/FloatingChrome.swift` (floating buttons, the Today
button, the map hint, map controls). No glass is used on cards, lists or text over photos, and glass is never
nested.

## Self review (1-10), provisional
Scored from the code only. None of the screens has been looked at, so treat every score as unconfirmed until
screenshots exist.

| Axis | Score | Why |
|---|---|---|
| Philosophy consistency | 7 | Tokens and components are used everywhere; Import review and Auto plan are only themed |
| Visual hierarchy | 7 | Overview and Today have a clear primary element; unverified on a device |
| Detail execution | 7 | Few literals left; spacing and type are from tokens |
| Functionality | 7 | Behaviour kept; reorder and map detents are new interaction code that has only been compiled |
| Signature detail | 7 | The day-coloured timeline with numbered pins that matches the map route |
