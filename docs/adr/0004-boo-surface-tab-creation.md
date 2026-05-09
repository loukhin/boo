# ADR 0004: Boo surface and tab creation pipeline

Date: 2026-05-09

## Status

Accepted

## Context

Boo creates or adopts Ghostty surfaces into Bonsplit tabs from several paths:

- new workspace initial tab
- user-created tab
- split creation
- drag-out/adopted surface
- Bonsplit delegate-created tab
- Ghostty notification-created tab

The current helpers mix multiple responsibilities:

- creating a Bonsplit tab
- creating or adopting a `Ghostty.SurfaceView`
- storing the surface in `surfaces`
- observing title/pwd publishers
- updating window chrome
- optionally focusing the new surface

This overlap has caused subtle coupling with workspace activation. For example,
workspace creation should create surfaces without focusing, while tab creation
inside an already-active workspace usually should focus. When these mechanics are
controlled by boolean options, call sites become harder to reason about.

## Decision

Separate Boo tab/surface creation into an explicit pipeline with small, focused
steps:

1. create/select the Bonsplit tab
2. create or adopt the Ghostty surface
3. register the surface in Boo state
4. observe surface metadata
5. update chrome if the created/adopted tab is currently chrome-relevant
6. let the caller/coordinator decide focus separately

Creation helpers should avoid moving focus by default. Focus should be requested
through the focus coordinator or workspace activation pipeline with semantic
intent.

Suggested shape:

```swift
enum SurfaceSource {
    case create(config: Ghostty.SurfaceConfiguration?)
    case adopt(Ghostty.SurfaceView)
}

struct CreatedSurfaceTab {
    let tabId: TabID
    let surface: Ghostty.SurfaceView
    let controller: BonsplitController
}

private func createSurfaceTab(
    in controller: BonsplitController,
    paneId: PaneID?,
    source: SurfaceSource
) -> CreatedSurfaceTab?
```

Higher-level operations can then be clear:

```swift
let created = createSurfaceTab(in: workspace.controller, source: .create(config))
activateWorkspace(.init(id: workspace.id, reason: .createNew))

let created = createSurfaceTab(in: controller, source: .create(config))
focusCoordinator.focusTab(created.tabId, reason: .tabCreated)
```

## Consequences

- Workspace creation can create content without accidentally focusing.
- Tab creation can still focus when appropriate, but focus is no longer hidden in
  creation helpers.
- Surface registration and observation become consistent for created and adopted
  surfaces.
- Some existing callers will become slightly more verbose, but intent should be
  clearer.
