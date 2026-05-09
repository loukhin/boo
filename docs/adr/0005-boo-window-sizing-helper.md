# ADR 0005: Boo window sizing helper

Date: 2026-05-09

## Status

Accepted

## Context

Boo window sizing has several Ghostty-specific and Boo-specific concerns:

- Ghostty config defines terminal surface size, not total Boo window chrome size
- Boo adds fixed Bonsplit tab bar height
- Boo intentionally does not add workspace sidebar width because the sidebar is
  toggleable UI
- initial surface size can arrive after window creation
- first-window frame restoration must not override explicit config size
- drag-out windows should size from the dragged surface where possible
- windows must be cascaded and constrained to visible screen bounds

This logic currently lives in `BooController` alongside window construction,
titlebar setup, menu validation, notification handling, and key handling. It is
working, but it is a distinct policy area and likely to grow as sizing edge cases
are found.

## Decision

Move Boo-specific sizing policy into a small helper, either as a dedicated
`BooWindowSizing` type or a clearly separated extension on `BooController`.

The helper should own:

- converting terminal surface size to Boo content size
- applying Bonsplit chrome height
- intentionally excluding workspace sidebar width
- choosing between config-derived size, current surface size, and fallback size
- deciding when to restore position only vs size + position
- applying cascade
- constraining windows to the visible screen
- retrying initial size application when `initialSize` is not ready yet

Suggested shape:

```swift
enum BooInitialSizeSource {
    case configSurfaceSize
    case currentSurfaceSize
    case fallback
}

struct BooWindowSizing {
    static func contentSize(
        for surfaceSize: NSSize,
        chrome: BooChromeMetrics
    ) -> NSSize

    static func applyInitialSize(
        to window: NSWindow,
        state: BooState,
        source: BooInitialSizeSource
    )
}
```

This does not need to be over-abstracted. The goal is to move sizing policy out
of general window-controller code and make future sizing fixes easier to review.

## Consequences

- Boo's sizing semantics become explicit and easier to maintain.
- Future regressions around config size, drag-out size, or frame restoration can
  be fixed in one area.
- `BooController` becomes smaller and more focused on window lifecycle and event
  routing.
- The helper should preserve current behavior; this is a maintainability refactor.
