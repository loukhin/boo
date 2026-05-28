# ADR 0008: Boo command palette parity

Date: 2026-05-28

## Status

Accepted

## Context

Boo now has Boo-native window restoration and undo/redo for its workspace,
Bonsplit, tab, and surface hierarchy. The next missing Ghostty window-shell
feature is the command palette.

The command palette is not just a visual overlay. It is an action launcher that
surfaces Ghostty keybinding actions, update actions, and terminal jump targets.
If Boo wires the palette before its action surface is complete, the palette will
make missing Boo behavior more visible. In particular, Boo still has split
commands that are no-ops or unsupported compared with Ghostty.

## What Ghostty does today

Ghostty's normal macOS terminal windows use this stack:

- `Ghostty.App` receives a `toggle_command_palette` binding action from
  libghostty.
- For surface-scoped targets, it posts
  `.ghosttyCommandPaletteDidToggle` with the target `Ghostty.SurfaceView`.
- `BaseTerminalController` observes that notification, checks whether the
  surface belongs to its `surfaceTree`, and toggles
  `commandPaletteIsShowing`.
- `TerminalView` overlays `TerminalCommandPaletteView` above the split tree
  whenever `commandPaletteIsShowing` is true.
- `TerminalCommandPaletteView` builds command options from:
  - install/cancel update actions from `UpdateViewModel`
  - configured `command-palette-entry` values from `Ghostty.Config`
  - `Focus: ...` jump targets for every surface in `TerminalController.all`
- When a command option is selected, `TerminalView` calls back into
  `BaseTerminalController.performAction(_:on:)`.
- `BaseTerminalController.performAction(_:on:)` forwards the action string to
  libghostty with `ghostty_surface_binding_action(...)`.
- When the palette closes, `TerminalCommandPaletteView` restores first-responder
  focus to the surface it was opened for.

Ghostty also has focus guards around the palette:

- opening the palette resigns the focused surface first responder so paste and
  key equivalents are handled by the palette text field, not the terminal
- `SurfaceView_AppKit` avoids focus-follows-mouse while the palette is visible
- closing the palette pushes focus back to the represented surface

## What Boo currently does

Boo replaced `TerminalView` with `BooRootView` and Bonsplit-hosted
`Ghostty.SurfaceWrapper` instances. That means Boo does not inherit the command
palette host path from `TerminalView`.

Current Boo gaps:

- `BooRootView` does not overlay `TerminalCommandPaletteView`.
- `BooState` does not track command-palette presentation state.
- `BooController` does not implement `toggleCommandPalette(_:)`.
- Boo does not observe `.ghosttyCommandPaletteDidToggle`.
- Boo has no `performAction(_:on:)` equivalent that forwards selected palette
  actions to libghostty.
- `TerminalCommandPaletteView` only builds jump targets from
  `TerminalController.all`, so Boo surfaces do not appear in `Focus: ...`
  results.
- Several Ghostty action handlers still cast to `BaseTerminalController` or
  `TerminalWindow`, so palette actions that rely on those handlers may silently
  miss Boo windows.

Boo already has partial command/action parity through other paths:

- `ghosttyNewSplit` creates Bonsplit panes and surfaces.
- `ghosttyCloseSurface` closes the Boo tab through Boo's confirmation and
  undo-aware close path.
- `ghosttyFocusSplit` navigates Bonsplit panes.
- `ghosttyGotoTab` selects tabs in the focused Bonsplit pane.
- `toggle_background_opacity` already has Boo-specific handling in
  `Ghostty.App`.

But Boo currently disables or no-ops these split operations:

- `toggle_split_zoom`
- `equalize_splits`
- `resize_split:*`

## Decision

Implement missing split command parity before wiring the command palette.

The palette should primarily expose existing actions, not become the first place
where those actions are implemented. If Boo wires the palette first, users will
see split commands in search results that still do nothing. Implementing split
parity first also exercises the same Ghostty notification/action path used by
menu items and keybindings, so the later palette integration can be a thin UI
host.

After split parity is complete, Boo should reuse Ghostty's existing command
palette UI instead of forking it. The desired architecture is:

```text
BooRootView
└── ZStack
    ├── Bonsplit workspace content
    └── TerminalCommandPaletteView(surface: BooState.commandPaletteSurface)
```

Boo should provide the missing host behavior around that shared UI:

- presentation state
- target surface selection
- action forwarding
- focus handoff
- Boo-aware jump targets

## Phase 1: split command parity

### Bonsplit API additions

Add public Bonsplit operations that correspond to Ghostty's split actions:

- `var isSplit: Bool`
- `func toggleZoomedPane(_ paneId: PaneID?)`
- `func equalizeSplits()`
- `func resizeSplit(containing paneId: PaneID, direction: NavigationDirection, amount: UInt16)`
- optional performability helpers such as:
  - `canToggleZoomedPane(_:)`
  - `canResizeSplit(containing:direction:)`
  - `canNavigateFocus(direction:)`

Implementation notes:

- Split zoom should be a Bonsplit rendering concern, not a Boo surface concern.
  Store the zoomed pane ID in Bonsplit state and render only that pane while
  preserving the underlying tree.
- Equalize should follow Ghostty semantics as closely as practical: recursively
  rebalance divider ratios based on leaf counts, not merely set every divider to
  `0.5` in a way that can produce unequal leaves in unbalanced trees.
- Keyboard resize should mutate the nearest split boundary that controls the
  focused pane in the requested direction, clamp ratios to the same safe range
  used by mouse dragging, and notify geometry changes.
- All operations should preserve selected tabs and focused pane identity where
  possible.

### Boo action routing

In `BooState`, observe and route the same notifications Ghostty uses:

- `.didToggleSplitZoom`
- `.didEqualizeSplits`
- `.didResizeSplit`

Each handler should:

1. verify the notification's `SurfaceView` is owned by this Boo window
2. activate the workspace containing the source surface if needed
3. call the corresponding Bonsplit API
4. restore focus to the relevant Boo surface
5. wrap structural mutations in Boo's snapshot undo/redo path

`BooController.validateMenuItem(_:)` should stop globally disabling these menu
items once Bonsplit can perform them. If a command is not currently performable
(for example no split exists), validation should disable it based on Boo state
instead of returning a hardcoded false.

Ghostty's shared surface context menu should also expose the split actions that
Boo implements, because Boo still hosts real `Ghostty.SurfaceView` instances and
inherits that context menu. Context-menu items should send the same binding
action strings as keybindings/menu-bar items, so Boo and Ghostty continue to
share one action path.

### Ghostty action performability

Some Ghostty action handlers only perform split checks for
`BaseTerminalController`. Boo should eventually expose equivalent performability
checks so keybindings do not consume terminal input when the split operation
cannot be performed.

Initial acceptable behavior:

- route Boo split notifications correctly
- keep no-op commands from appearing enabled in menus

Follow-up polish:

- add Boo-aware performability checks in `Ghostty.App` or through a small shared
  host protocol so `resize_split`, `toggle_split_zoom`, and navigation actions
  can return false when impossible.

## Phase 2: Boo command palette host

### State model

Add ephemeral palette state to `BooState`:

```swift
@Published var commandPaletteIsShowing: Bool
@Published private(set) var commandPaletteSurface: Ghostty.SurfaceView?
```

Suggested operations:

- `toggleCommandPalette(for surface: Ghostty.SurfaceView?)`
- `showCommandPalette(for surface: Ghostty.SurfaceView)`
- `dismissCommandPalette()`
- `performCommandPaletteAction(_ action: String, on surface: Ghostty.SurfaceView)`

This state is not restorable and not undoable.

When no explicit surface is supplied, use Boo's focused surface. If there is no
focused surface, use the selected tab in the active workspace.

### Presentation

Change `BooRootView` from a plain workspace layout to a `ZStack` that overlays
`TerminalCommandPaletteView` when Boo has a palette surface.

Reuse the existing UI:

```swift
TerminalCommandPaletteView(
    surfaceView: surface,
    isPresented: $state.commandPaletteIsShowing,
    ghosttyConfig: state.ghostty.config,
    updateViewModel: appDelegate.updateViewModel
) { action in
    state.performCommandPaletteAction(action, on: surface)
}
```

Do not fork `CommandPaletteView` unless a later Boo-specific design requires it.

### Entry points

Wire all existing Ghostty entry points:

- libghostty action: observe `.ghosttyCommandPaletteDidToggle`
- app/menu action: `BooController.toggleCommandPalette(_:)`
- configured keybinding: continue to flow through `Ghostty.App`

Opening should resign the represented surface's first responder, matching
`BaseTerminalController.toggleCommandPalette(_:)`, so text input belongs to the
palette query field. Closing should restore focus through Boo's focus path rather
than directly calling only `makeFirstResponder`.

### Action forwarding

Add the Boo equivalent of `BaseTerminalController.performAction(_:on:)`:

```swift
func performCommandPaletteAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
    guard let surface = surfaceView.surface else { return }
    let len = action.utf8CString.count
    guard len > 0 else { return }
    _ = action.withCString { cString in
        ghostty_surface_binding_action(surface, cString, UInt(len - 1))
    }
}
```

Do not special-case actions in the palette layer. Special cases belong in the
same Ghostty/Boo notification handlers used by keybindings and menus.

## Phase 3: Boo-aware jump targets

`TerminalCommandPaletteView.jumpOptions` must stop hardcoding
`TerminalController.all` as the only terminal source.

Introduce a small shared model or provider for command-palette terminal targets,
for example:

```swift
struct CommandPaletteTerminalTarget {
    let surface: Ghostty.SurfaceView
    let title: String
    let subtitle: String?
    let color: Color?
    let sortKey: AnySortKey?
    let present: () -> Void
}
```

Then collect targets from both hosts:

- Ghostty native terminals: `TerminalController.all`
- Boo terminals: `BooController.all`

For Boo targets, `present` must:

1. bring the owning Boo window forward
2. activate the workspace containing the surface
3. focus the Bonsplit pane containing the tab
4. select the tab
5. move AppKit/Ghostty focus to the surface
6. call `surface.highlight()`

This should also be used for the `present_terminal` action if possible, so the
command palette and keybinding/action path agree.

## Phase 4: action-audit cleanup

Audit `Ghostty.App.swift` action handlers that still assume normal Ghostty
terminal windows:

- casts to `BaseTerminalController`
- casts to `TerminalController`
- casts to `TerminalWindow`

Known actions to check for Boo support:

- `prompt_tab_title` / `set_tab_title` (Boo maps these to workspace titles)
- `toggle_window_float_on_top`
- `goto_window`
- `resize_split`
- `equalize_splits`
- `toggle_split_zoom`
- `present_terminal`

For each action, choose one of:

1. support Boo directly
2. route through a shared host protocol
3. deliberately document it as unsupported in Boo

Prefer shared host protocols only when they remove repeated type checks without
forcing `BooController` into `BaseTerminalController`'s split-tree model.

## Acceptance criteria

Split parity is complete when:

- menu, keybinding, and surface context-menu `toggle_split_zoom` work in Boo
- zoomed Boo panes show a reset-zoom affordance on the active tab, matching
  Ghostty's visible zoom indicator / quick unzoom behavior
- menu, keybinding, and surface context-menu `equalize_splits` work in Boo
- menu, keybinding, and surface context-menu `resize_split:*` work in Boo
- undo/redo works for structural split changes where appropriate
- unsupported split actions are disabled based on real Boo state, not hardcoded
  no-ops

Command palette parity is complete when:

- the menu item opens the palette in a Boo window
- configured `toggle_command_palette` keybinding opens it for the focused Boo
  surface
- Escape, focus loss, and command submission close it
- terminal focus returns to the original Boo surface after close
- configured command-palette entries execute against the correct Boo surface
- update install/cancel options still appear
- `Focus: ...` targets include Boo surfaces across all Boo windows/workspaces
- focusing a Boo target in a different workspace activates that workspace and
  highlights the surface
- palette actions use the same Boo undo/redo-aware action paths as menus and
  keybindings

## Non-goals

- Restoring the command palette across app relaunch.
- Making palette open/close an undoable action.
- Forking the visual command palette for Boo-specific design changes.
- Replacing Ghostty's action parser or `command-palette-entry` configuration.
