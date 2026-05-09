# ADR 0002: Boo workspace activation coordinator

Date: 2026-05-09

## Status

Accepted

## Context

Boo workspace behavior has accumulated several related concerns:

- creating a workspace and its initial tab/surface
- adopting an existing surface during drag-out
- switching to an existing workspace
- switching to a newly-created or otherwise cold workspace
- closing a workspace and focusing the fallback workspace
- maintaining the warm-mounted workspace set
- updating window chrome
- moving AppKit first-responder focus and Ghostty cursor focus visuals

These concerns currently leak into each other through boolean options such as
`focusAfterCreate` and `focusAfterSwitch`. That makes fixes approachable in the
moment, but over time the code becomes harder to read because call sites encode
mechanics instead of intent.

A recent example: deferring focus for newly-created workspaces fixed cursor
visual state when holding Command-N, but moving creation before activation also
exposed that lower-level tab/surface creation can indirectly assume an active
workspace exists.

## Decision

Refactor Boo workspace state around one explicit activation pipeline. Workspace
creation/adoption should create tabs and surfaces without focusing. A central
activation routine should own active-workspace changes and all follow-up effects.

Use semantic activation reasons instead of boolean option combinations, for
example:

```swift
enum WorkspaceActivationReason {
    case initialWindow
    case userSwitch
    case createNew
    case closeFallback
    case adoptDraggedSurface
}

struct WorkspaceActivation {
    let id: WorkspaceID
    let reason: WorkspaceActivationReason
}
```

The activation routine should be responsible for:

1. ensuring the target workspace is in the warm-mounted set
2. deciding whether activation must be delayed by one render pass
3. updating `activeWorkspaceId`
4. updating recency and mounted workspace state
5. updating window chrome
6. moving first-responder focus
7. restoring Ghostty cursor focus visuals

Higher-level operations should become small and intent-focused:

```swift
func newWorkspace(...) {
    let id = createWorkspaceAndInitialSurface(...)
    activateWorkspace(.init(id: id, reason: .createNew))
}

func switchToWorkspace(_ id: WorkspaceID) {
    activateWorkspace(.init(id: id, reason: .userSwitch))
}

func closeWorkspace(_ id: WorkspaceID) {
    let fallback = removeWorkspaceAndChooseFallback(id)
    activateWorkspace(.init(id: fallback, reason: .closeFallback))
}
```

## Consequences

- Call sites describe user/runtime intent rather than low-level focus timing.
- Workspace creation no longer needs to know when a surface should focus.
- Warm-mount behavior and AppKit focus handoff become easier to reason about.
- Future focus fixes should land in one activation pipeline instead of adding
  more boolean parameters.
- This is a refactor, not a behavior change, and should be done after the current
  focus fixes are stable.
