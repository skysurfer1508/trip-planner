# Liquid Glass API reference (iOS 26)

Fetched from Apple's documentation JSON (developer.apple.com/tutorials/data/documentation/swiftui/...) on 2026-10-08.
Everything below is iOS 26.0+. The app's deployment target is iOS 17, so **every use must be wrapped in
`if #available(iOS 26, *)` with a `.thinMaterial` / `.bar` fallback.** Do not call these APIs from code that is
compiled for iOS 17 without that guard.

## Rules for this app
- Glass is only for the floating navigation layer: tab bar, toolbars, floating action buttons, sheets.
- Never on content cards, lists or text over photos. Never glass on glass.
- Tint only primary actions.

## View.glassEffect
```swift
nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
```
- Default shape is a capsule. The material is anchored to the view's bounds *including padding*.
- Example: `.glassEffect(.regular.interactive(true), in: .rect(cornerRadius: 16))`

## Glass
| Member | Signature |
|---|---|
| `regular` | `static var regular: Glass` (default) |
| `clear` | `static var clear: Glass` |
| `identity` | `static var identity: Glass` (no effect; useful to switch glass off conditionally) |
| `interactive(_:)` | `func interactive(_ : Bool) -> Glass` |
| `tint(_:)` | `func tint(_ : Color?) -> Glass` |

Conforms to `Equatable`, `Sendable`.

## GlassEffectContainer
```swift
@MainActor struct GlassEffectContainer<Content: View>: View
init(spacing: CGFloat? = nil, content: () -> Content)   // spacing default not documented
```
- Group several glass views in one container; they render together (cheaper) and can blend/morph.
- Larger `spacing` makes shapes start blending sooner.
- Related: `glassEffectID(_:in:)` (Hashable & Sendable?, Namespace.ID), `glassEffectUnion(id:namespace:)`,
  `glassEffectTransition(_:)`. Only one-line docs were retrieved, so verify behaviour on device before relying on them.

## Button styles
```swift
PrimitiveButtonStyle.glass            // GlassButtonStyle
PrimitiveButtonStyle.glassProminent   // GlassProminentButtonStyle (availability not confirmed, assume iOS 26)
```

## Tab bar
```swift
nonisolated func tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View
```
`TabBarMinimizeBehavior`: `.automatic`, `.never`, `.onScrollDown`, `.onScrollUp`. The scroll cases are iPhone-only.

```swift
nonisolated func tabViewBottomAccessory<Content: View>(@ViewBuilder content: () -> Content) -> some View
func tabViewBottomAccessory<Content: View>(isEnabled: Bool, content: () -> Content) -> some View
```
- The `content:` form is documented as iOS 26.0+. The `isEnabled:` form was seen only in the See Also list, so
  its attributes and exact availability are **not confirmed**. Check in Xcode before using it.
- Accessory sits above the tab bar when it is full size and inline when the bar is minimised.
- `@Environment(\.tabViewBottomAccessoryPlacement)` is `TabViewBottomAccessoryPlacement?` (optional). The cases
  were not retrieved, so handle `nil` and check the type in Xcode.

## Not confirmed (check in Xcode before use)
- `Glass` initializers, member-level availability.
- `TabViewBottomAccessoryPlacement` cases.
- `glassProminent` availability.
- Whether the iOS 26 SDK is required in CI (`macos-latest` must select an Xcode 26 SDK, or these calls will not
  compile at all, even behind `#available`). Check this in Phase 1 before writing any glass code.

## Note on `Tab` vs `.tabItem`
`Tab(...)` is iOS 18+. With an iOS 17 deployment target keep the existing `.tabItem` labels and apply
`.tabBarMinimizeBehavior` / `.tabViewBottomAccessory` behind `#available(iOS 26, *)` (for example through a
`ViewModifier` that returns `self` otherwise).
