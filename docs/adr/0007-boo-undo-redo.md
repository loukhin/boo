# ADR 0007: Boo undo and redo

Date: 2026-05-28

## Status

Accepted

## Context

Boo now has a real AppKit restoration model for Boo windows:

- `BooRestorableState`
- `BooWorkspaceRestorableState`
- `BonsplitRestorableState`
- `BooWindowRestoration`
- `BooState(ghostty:restorableState:)`

That model restores Boo workspaces, Bonsplit pane/tab structure, selected tabs,
focused surface identity, sidebar visibility, and Ghostty `SurfaceView` state.
It is intentionally a session/layout restoration mechanism, not a live process
checkpoint.

Undo/redo has a different lifetime requirement. When a user closes a tab, split,
workspace, or window and then immediately presses Undo, they expect the same live
terminal process to come back if possible. Ghostty already supports this by
keeping live `SurfaceView` objects reachable from short-lived undo closures.
Boo should match that behavior without inventing a second snapshot shape.

## What Ghostty does today

Ghostty separates app restoration from undo/redo:

### App restoration

Ghostty uses `TerminalRestorableState` and `NSWindowRestoration` for relaunch
state. It encodes `Ghostty.SurfaceView` values, and decoding creates fresh
surfaces using restored metadata such as UUID, title, and pwd. It does not
restore live PTYs/processes.

### Undo/redo

Ghostty uses the app-level `ExpiringUndoManager`. Its undo operations expire
after `ghostty.config.undoTimeout` so closed live terminals are not retained
forever.

For live undo, Ghostty stores in-memory references rather than encoded data. For
example, `TerminalController.UndoState` contains:

- window frame
- live `SplitTree<Ghostty.SurfaceView>`
- focused surface UUID
- native tab index/group metadata
- tab color

Because the split tree contains live `SurfaceView` instances, undo can reattach
the same running terminals while the undo action is still valid. If the undo
action expires, those surfaces can be released normally.

Ghostty registers undo/redo for user-visible structural actions such as:

- new window
- new tab
- new split
- close terminal/split
- close tab
- close window
- close all windows
- close other tabs / tabs to the right
- move split

It generally does not treat plain focus/navigation changes as undoable edits.

## What Boo did before this change

Boo had app restoration but did not contribute any undo actions to the global
Undo/Redo menu.

Consequences:

- closing a Boo tab/workspace/window could not be undone
- creating a Boo tab/workspace/split could not be undone
- workspace rename/reorder could not be undone
- `Close All Windows` only routed through `TerminalController.closeAllWindows()`
- Boo had no equivalent to Ghostty's short-lived live-surface undo retention

## Decision

Use Boo's restoration shape as the undo snapshot shape, but keep undo snapshots
in memory.

That gives us one conceptual state model:

```text
Boo window
└── BooState
    ├── active workspace id
    ├── focused surface id
    ├── sidebar visibility
    └── workspaces[]
        ├── workspace id/title
        ├── Bonsplit split tree
        └── tab id -> Ghostty.SurfaceView
```

The same `BooRestorableState` has two lifetimes:

- AppKit restoration encodes/decodes it, creating fresh restored surfaces.
- Undo/redo captures it in closures, preserving live `SurfaceView` references
  until `undo-timeout` expires.

For whole-window undo, wrap the Boo state with window metadata:

```swift
struct BooWindowUndoState {
    let frame: NSRect
    let state: BooRestorableState
}
```

## Undoable actions

Boo should register undo/redo for structural user actions:

- new Boo window
- close Boo window
- close all Boo windows
- new workspace
- close workspace
- rename workspace
- reorder workspace
- new tab
- close tab
- new split
- close split/pane

Where possible, an undo should restore the same live surfaces. Redo should then
restore the post-action snapshot and keep the pre-action snapshot alive so the
operation remains reversible until expiration.

## Non-undoable actions

These are intentionally not undoable:

- focusing a pane or tab
- switching workspaces
- toggling sidebar visibility
- terminal title/pwd changes emitted by the shell
- hover, drag, and drop transient state
- AppKit first-responder state as an object reference
- window frame changes from manual resize/move

These are either navigation, derived state, or AppKit-managed state rather than
semantic Boo document edits.

## Implementation notes

### In-window state mutations

For mutations that keep the same Boo window alive, capture a before/after
snapshot around the mutation:

1. capture `before = BooRestorableState(from: state)`
2. perform the mutation
3. capture `after = BooRestorableState(from: state)`
4. register undo restoring `before`
5. while undoing, register redo restoring `after`

Restoring a snapshot into an existing `BooState` should:

- detach current surfaces from stale cached scroll views
- clear current subscriptions and workspace arrays
- rebuild workspaces/controllers from `BooRestorableState`
- re-register surface title/pwd observers
- restore active workspace/sidebar visibility/focused surface
- refresh warm-mounted workspaces
- update window chrome
- retry AppKit focus restoration once views have reattached

### Whole-window mutations

For closing a Boo window, capture `BooWindowUndoState`, close the window, and
register undo that creates a new `BooController` from that state. Redo closes the
restored controller again.

The last-tab close path should be treated as a window close, not as an in-window
empty-state restore.

### Close confirmations

Close confirmation should happen before registering the final structural undo.
Boo should route tab/pane close attempts through Boo-owned helpers so Bonsplit
close buttons, menu actions, and Ghostty action notifications all share the same
confirmation and undo behavior.

### Expiration

All undo registrations involving live surfaces must use `ExpiringUndoManager` and
`ghostty.config.undoTimeout`, matching Ghostty. If the timeout is zero, no undo
is registered.

## Deferred work

Cross-window tab drag-out should become a grouped undo operation that snapshots
both source and destination windows. The initial implementation may preserve the
existing drag-out behavior and add this once the single-window snapshot restore
path is proven stable.
