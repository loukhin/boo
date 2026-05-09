# ADR 0003: Boo focus coordinator

Date: 2026-05-09

## Status

Accepted

## Context

Boo embeds Ghostty `SurfaceView` instances inside Bonsplit panes and workspaces.
Correct focus requires keeping several layers synchronized:

- AppKit first responder
- Ghostty surface focus visuals (`focusDidChange`)
- Boo's `focusedOwnedSurface`
- Bonsplit focused pane / selected tab
- window key/app active state
- workspace activation and warm mounting

Focus behavior is currently spread across workspace activation, tab close, pane
focus, surface focus notifications, window delegate callbacks, app activation,
and split/tab creation paths. This made sense while fixing individual focus
bugs, but it makes future changes risky because each call site has to remember
which parts of the focus handoff are needed.

## Decision

Introduce a Boo-specific focus coordinator, likely as a focused section/helper in
`BooState` first rather than a separate type. The coordinator should become the
single policy boundary for terminal focus handoff.

It should own operations such as:

- focusing a specific tab/surface
- focusing the current selected surface
- unfocusing all owned surfaces
- restoring focus after window/app activation
- synchronously handing focus from a closing surface to a replacement
- deciding when to call `Ghostty.moveFocus` vs direct `makeFirstResponder`
- updating `focusedOwnedSurface`
- restoring cursor visuals when AppKit first responder is already correct

Call sites should express intent, for example:

```swift
focusCoordinator.focusCurrentSurface(reason: .workspaceActivated)
focusCoordinator.focusTab(tabId, reason: .tabSelected)
focusCoordinator.handoffFromClosingSurface(surface, replacementPane: pane)
focusCoordinator.windowBecameKey()
focusCoordinator.windowResignedKey()
```

The first implementation can remain inside `BooState` to avoid introducing a
reference-heavy helper too early. The important change is to centralize policy
and reduce ad-hoc direct calls to `Ghostty.moveFocus`, `focusDidChange`, and
`makeFirstResponder` outside the coordinator boundary.

## Consequences

- Focus behavior becomes easier to audit and test manually.
- Future focus bugs should be fixed in one place instead of by adding more local
  patches.
- Call sites become clearer because they state focus intent instead of AppKit
  mechanics.
- The refactor should preserve behavior and be done incrementally because focus
  is fragile.
