# ADR 0001: Boo workspace view lifetime

Date: 2026-05-09

## Status

Accepted

## Context

Boo workspaces own Ghostty terminal surfaces through `BooState`. Those surfaces
and their PTYs must stay alive even when a workspace is inactive. The question is
how long the SwiftUI/AppKit view tree for each workspace should stay mounted.

Unmounting inactive workspace views is cheaper, but it creates a focus handoff
race: when the active workspace closes, the replacement workspace may not have an
attached `SurfaceView` yet. During rapid key repeat, especially holding `Ctrl-D`,
a repeated key can reach the window before AppKit has a terminal first responder,
which produces a system beep.

Mounting every workspace avoids the focus race, but it can waste memory and
layout/compositing work if many workspaces exist, especially if inactive
terminals are producing output.

## Decision

Boo keeps terminal surfaces/PTYs alive for all workspaces, but only keeps a warm
set of workspace view trees mounted:

- the active workspace
- the previous and next workspace in workspace order
- a small LRU of recently active workspaces
- a pending cold workspace for one render pass before activation

Cold workspace view trees are unmounted. When switching to a cold workspace, Boo
first adds it to the warm mounted set while hidden, then activates it on the next
main-loop turn so its `SurfaceView` can attach before focus is moved.

## Consequences

- Closing the active workspace usually focuses a pre-mounted replacement
  synchronously, avoiding `Ctrl-D` repeat beeps.
- Common workspace switches are snappy because nearby/recent workspaces are
  already mounted.
- Memory and rendering overhead remains bounded instead of growing with every
  workspace.
- Switching to a cold workspace may be delayed by one main-loop turn, which is
  preferable to racing AppKit first-responder attachment.
