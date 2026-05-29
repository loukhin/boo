# ADR 0009: Boo bell aggregation and dock badge count

Date: 2026-05-28

## Status

Accepted

## Context

Boo now reimplements Ghostty's restoration, undo/redo, and command palette flows
around Boo windows, workspaces, and Bonsplit tabs. Bell aggregation is the next
remaining app-level behavior that needs an explicit Boo mapping because Boo's UI
hierarchy is different from Ghostty's native macOS tab hierarchy.

Ghostty's dock badge is a count of ringing terminal tabs. Boo should preserve
that user-facing meaning even though Boo tabs live inside workspaces and Boo
windows instead of AppKit native tab groups.

## What Ghostty does today

1. libghostty requests a bell for a target surface.
2. `Ghostty.App.ringBell` posts `.ghosttyBellDidRing` with that
   `Ghostty.SurfaceView` as the notification object.
3. The target `SurfaceView` observes that notification and sets its own
   `bell = true`.
4. `SurfaceView.focusDidChange(true)` clears that surface's bell.
5. Each `BaseTerminalController` observes all `SurfaceView.$bell` publishers in
   its `SplitTree` and computes a window/tab-level aggregate:

   ```swift
   surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
       .map { $0.values.contains(true) }
       .removeDuplicates()
   ```

6. The controller stores that aggregate in `bell` and posts
   `.terminalWindowBellDidChangeNotification`.
7. `AppDelegate` syncs the dock badge by counting `BaseTerminalController`
   instances whose aggregate `bell` is true.

A Ghostty `TerminalController` corresponds to one native macOS terminal tab. It
may contain many splits, but multiple ringing splits inside the same native tab
still count as one badge unit.

## What Boo did before this change

Boo already reused Ghostty `SurfaceView`, so individual Boo terminal surfaces
could ring and clear their own bell state correctly. The global side effects from
`.ghosttyBellDidRing` also already worked:

- system beep
- configured bell audio
- dock attention request

But Boo did not provide the missing aggregate layer:

- no Boo tab/workspace/window aggregate bell count
- no Boo notification when aggregate bell state changed
- dock badge counting only considered `BaseTerminalController`
- closing a ringing Boo window did not emit an aggregate clear event

## Decision

Boo's dock badge count should count ringing Boo tabs globally across all
workspaces and all Boo windows.

This matches Ghostty's user-visible semantics better than counting windows or
workspaces:

- Ghostty badge unit: one native terminal tab whose split tree has any bell.
- Boo badge unit: one Bonsplit terminal tab whose `SurfaceView.bell` is true.

Ghostty's default `bell-features` includes `attention` and `title`; users only
lose dock-badge/attention behavior if they explicitly disable attention.

Examples:

- 1 ringing Boo tab = badge `1`
- 3 ringing Boo tabs in one workspace = badge `3`
- 3 ringing Boo tabs across multiple workspaces = badge `3`
- 3 ringing Boo tabs across multiple Boo windows = badge `3`

Boo should not count workspaces because a workspace can contain many active
terminal tabs. Boo should not count windows because a Boo window can contain many
workspaces. Boo should not count panes separately because a Bonsplit tab maps
1:1 to a Ghostty `SurfaceView`.

## Implementation plan

1. Add `BooState.bellTabCount` as a published, read-only aggregate count.
2. Recompute `bellTabCount` from `surfaces.values` whenever:
   - a surface is registered
   - a surface is removed
   - a tracked surface's `$bell` changes
3. Mark each ringing Boo tab by prefixing the tab title with Ghostty's bell
   emoji (`🔔 `), and clear the prefix when that tab's surface bell clears.
   Strip this transient prefix from Boo restoration/undo snapshots so a stale
   bell marker cannot survive quit/reopen.
4. Aggregate each Boo workspace across every tab in its Bonsplit tree. Show the
   ringing-tab count as a circular badge in the workspace row's subtitle, before
   the path. Keep title bell prefixes tied to the selected tab: workspace and
   window titles mirror the current tab title and only include the bell emoji
   when that current tab is ringing.
5. Post `.terminalWindowBellDidChangeNotification` from `BooState` whenever the
   aggregate count changes. Reuse Ghostty's notification because `AppDelegate`
   already uses it as the app-level badge invalidation signal.
6. On Boo window close, force-clear the aggregate count and post a final false
   transition so the dock badge cannot retain stale Boo bell state.
7. Update `AppDelegate.setDockBadge()` to count:
   - Ghostty native tabs via `BaseTerminalController.bell`
   - Boo tabs by counting owned `SurfaceView.bell` values across all
     `BooController` instances
8. Keep Ghostty's notification-permission handling before writing the dock
   badge: query `UNUserNotificationCenter` settings, request badge
   authorization when needed, and write `NSApp.dockTile.badgeLabel` only when
   badge use is authorized/enabled or not supported by the current environment.
9. Keep Ghostty's existing `bell-features` gate: the badge is shown when the
   `attention` bell feature is enabled, which is Ghostty's default behavior.

## Non-goals

This change does not repurpose Bonsplit's dirty indicator for bells. Bells are
shown with Ghostty's title emoji prefix, while the dirty indicator remains
available for future modified-state semantics.
