# ADR 0006: Boo window restoration

Date: 2026-05-28

## Status

Accepted

## Context

Boo replaces Ghostty's macOS window/tab/split UI with a Boo-specific window
controller, workspace model, and Bonsplit split/tab layout. Ghostty already has
macOS state restoration for terminal windows, but before this ADR Boo did not
restore its workspace or Bonsplit state. Boo only persisted a coarse window frame
through AppKit frame autosave.

Restoration needs a design before implementation because Boo's hierarchy is not a
1:1 mapping of Ghostty's:

- Ghostty: one `TerminalController` per AppKit terminal window/tab, containing a
  `SplitTree<Ghostty.SurfaceView>`.
- Boo: one `BooController` per AppKit window, containing a `BooState` with many
  workspaces. Each workspace owns one `BonsplitController`, and each Bonsplit tab
  maps to one `Ghostty.SurfaceView`.

The goal is to restore Boo's window/workspace/layout metadata across app relaunch
while continuing to rely on Ghostty's surface construction. This is not intended
to restore live PTYs/processes.

## What Ghostty does today

Ghostty uses macOS `NSWindowRestoration` for normal terminal windows.

### App-level restoration

`AppDelegate` supports secure restorable state:

```swift
func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
}
```

At the app level it encodes/decodes quick terminal state only. Normal terminal
window state is encoded by each window controller via the window delegate.

### Window opt-in

`TerminalController.windowDidLoad()` opts each restorable terminal window into
AppKit restoration:

- `window.isRestorable = restorable`
- `window.restorationClass = TerminalWindowRestoration.self`
- `window.identifier = TerminalWindowRestoration`

Ghostty marks windows launched with an explicit command as non-restorable because
restoring them would only create a fresh shell, not the original command/process.

### Encoded terminal state

`TerminalController.window(_:willEncodeRestorableState:)` encodes a
`TerminalRestorableState`.

`TerminalRestorableState` currently stores:

- focused surface UUID
- `SplitTree<Ghostty.SurfaceView>`
- effective fullscreen mode
- tab color
- tab/window title override

`Ghostty.SurfaceView` is already `Codable`. Its encoded state includes:

- pwd
- UUID
- title
- whether the title was user-set

On decode, `SurfaceView` creates a new Ghostty surface using the restored pwd as
its working directory and restores metadata such as UUID/title. It does not
restore the original live PTY/process.

### Restore flow

`TerminalWindowRestoration.restoreWindow(...)`:

1. validates the restoration identifier
2. gets `AppDelegate` and checks `window-save-state != never`
3. decodes `TerminalRestorableState`
4. creates a `TerminalController` with the restored split tree
5. reapplies tab color and title override
6. finds the focused surface by UUID
7. returns the restored `NSWindow` to AppKit
8. reapplies non-native fullscreen mode if needed
9. retries focus until SwiftUI/AppKit has attached the restored `SurfaceView`

Native fullscreen/window frame restoration is mostly handled by AppKit. Ghostty
manually reapplies non-native fullscreen modes after returning the window.

## What Boo did before this change

Boo did not implement equivalent session/layout restoration.

### Window state

`BooController` creates a plain `NSWindow` and sets:

- title/titlebar behavior
- `BooRootView` as content
- `window.setFrameAutosaveName("BooWindow")`

It did not set:

- `window.isRestorable`
- `window.restorationClass`
- a restoration `window.identifier`

It also did not implement:

- `window(_:willEncodeRestorableState:)`
- a Boo-specific `NSWindowRestoration` type

### Frame persistence

`BooWindowSizing` uses AppKit frame autosave to restore/cascade the first Boo
window's frame. This preserves only approximate window placement/size. It does
not restore:

- workspaces
- active workspace
- Bonsplit pane tree
- tabs per pane
- selected tab per pane
- focused pane/surface
- tab-to-surface mapping
- workspace sidebar visibility

### Runtime state that needs restoration

The meaningful Boo state currently lives in `BooState`:

- `workspaces`
- `activeWorkspaceId`
- one `BonsplitController` per workspace
- `surfaces: [TabID: Ghostty.SurfaceView]`
- surface title/pwd subscriptions
- active/focused surface tracking
- workspace sidebar visibility
- window chrome derived from the selected/focused tab
- warm-mounted workspace view bookkeeping

Bonsplit could export layout/tree snapshots, but it did not expose a stable
restore/import API for rebuilding an identical controller tree.

## Decision

Implement Boo restoration as a Boo-specific restoration stack rather than trying
to force Boo into Ghostty's `TerminalRestorableState`.

Boo should reuse Ghostty's existing `SurfaceView Codable` support, but encode the
Boo-specific hierarchy around those surfaces:

```text
Boo window
└── BooState
    ├── active workspace id
    ├── focused surface id
    ├── sidebar visibility
    └── workspaces[]
        ├── workspace id/title
        ├── focused pane id
        ├── Bonsplit split tree
        └── tabs[]
            ├── tab id/title/metadata
            └── Ghostty.SurfaceView codable state
```

Boo restoration should preserve user-visible layout and metadata, not live
processes.

## Proposed restored data model

### `BooRestorableState`

Create a Boo equivalent to `TerminalRestorableState`, using the same
`TerminalRestorable`/`CodableBridge` pattern if possible:

```swift
final class BooRestorableState: TerminalRestorable {
    static var version: Int { 1 }

    let activeWorkspaceId: String?
    let focusedSurfaceId: String?
    let isWorkspaceSidebarVisible: Bool
    let workspaces: [BooWorkspaceRestorableState]
}
```

Store only stable IDs and codable values. Avoid storing object references except
through codable `SurfaceView` state.

### `BooWorkspaceRestorableState`

Each workspace should store:

- workspace ID
- workspace title/custom title state
- Bonsplit tree state
- focused pane ID

The active workspace should be restored from `activeWorkspaceId`, not inferred
from array order.

### Bonsplit restorable state

Add an explicit Bonsplit codable state model. Do not rely on pixel layout
snapshots as the primary persisted format; they are useful for external geometry
but too derived for restoration.

Persist structural state:

```swift
struct BonsplitRestorableState: Codable {
    let root: BonsplitRestorableNode?
    let focusedPaneId: String?
}

indirect enum BonsplitRestorableNode: Codable {
    case pane(BonsplitRestorablePane)
    case split(BonsplitRestorableSplit)
}

struct BonsplitRestorablePane: Codable {
    let id: String
    let tabs: [BonsplitRestorableTab]
    let selectedTabId: String?
}

struct BonsplitRestorableSplit: Codable {
    let id: String
    let orientation: SplitOrientation
    let dividerPosition: Double
    let first: BonsplitRestorableNode
    let second: BonsplitRestorableNode
}
```

Each tab should include Bonsplit metadata plus its associated surface state:

```swift
struct BooTabRestorableState: Codable {
    let id: String
    let title: String
    let icon: String?
    let isDirty: Bool
    let surface: Ghostty.SurfaceView
}
```

Implementation may choose to keep surface state in a separate `[String:
Ghostty.SurfaceView]` map keyed by tab ID if that is cleaner.

## Restore algorithm

Add a `BooWindowRestoration: NSObject, NSWindowRestoration` type.

`restoreWindow(...)` should:

1. validate the identifier
2. get `AppDelegate`
3. skip if `ghostty.config.windowSaveState == "never"`
4. decode `BooRestorableState`
5. create `BooController(ghostty:restorableState:)`
6. return the restored `NSWindow` to AppKit
7. restore non-native/fullscreen state later if Boo adds support for it
8. schedule focus restoration for the saved focused surface

`BooController.configureWindow()` should opt in Boo windows:

- `window.isRestorable = true`
- `window.restorationClass = BooWindowRestoration.self`
- `window.identifier = BooWindowRestoration`

`BooController` should encode state from its window delegate method:

```swift
func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    BooRestorableState(from: self.state).encode(with: state)
}
```

## BooState restore algorithm

Add a restore initializer or factory for `BooState`.

It should:

1. create each restored `BooWorkspace`
2. create a `BonsplitController` from the restored Bonsplit state
3. rebuild the `surfaces` map from restored tab IDs to decoded
   `Ghostty.SurfaceView` instances
4. re-register every surface so title/pwd subscriptions are installed
5. restore selected tabs/focused panes in each workspace
6. restore `activeWorkspaceId`
7. restore sidebar visibility
8. derive window chrome from the restored active/focused tab
9. seed workspace mounting so the active workspace is mounted immediately
10. defer AppKit first-responder focus until the target surface has attached to
    the restored window

Focus restoration should follow Ghostty's pattern: retry for a bounded period
until the `SurfaceView.window` is the restored Boo window, then call the Boo focus
path rather than directly poking unrelated state.

## Non-goals

Do not attempt to restore:

- live PTYs/processes
- scrollback contents beyond what Ghostty already supports
- transient hover/drag/drop state
- open alerts/sheets
- warm-mounted workspace LRU internals
- cached window chrome values that can be derived from surfaces
- current first responder as an encoded object reference

## Related parity fixes

These are not strictly part of restoration, but should be audited while adding
Boo restoration:

- `AppDelegate.findSurface(forUUID:)` currently only searches
  `TerminalController` surfaces. It should include Boo surfaces.
- `AppDelegate.closeAllWindows(_:)` currently only closes Ghostty
  `TerminalController` windows. It should include Boo windows.
- Dock badge/bell aggregation currently counts `BaseTerminalController` windows.
  Boo surfaces should be included if Boo wants Ghostty bell parity.
- First-launch initial window creation should not create an extra Boo window when
  AppKit is restoring Boo windows.
- Restored Boo windows should not fight `BooWindowSizing` frame autosave/cascade;
  AppKit restoration should own restored window frames.

## Implementation order

1. Add codable Bonsplit structural state.
2. Add Bonsplit restore/import API and unit round-trip tests.
3. Add `BooRestorableState` and encode tests if practical.
4. Add `BooState` restore initializer/factory.
5. Add `BooWindowRestoration`.
6. Wire Boo windows into AppKit restoration.
7. Add focus retry after restore.
8. Audit app-level helpers that currently only search `TerminalController`.
9. Manually test relaunch with multiple windows, multiple workspaces, splits,
   tabs, renamed workspaces, sidebar visible/hidden, and focused surface restore.

## Open questions

- Should Boo preserve workspace IDs exactly, or is stable ordering enough?
- Should workspace rename state be explicit, or should the stored display title be
  enough?
- Should restored tabs keep their last displayed title until the shell emits a new
  one, matching Ghostty surface title restoration?
- Should Boo support restoring non-native fullscreen modes before or after adding
  full Ghostty fullscreen parity?
- Should frame autosave be disabled for restorable Boo windows to avoid conflicts
  with AppKit restoration?
