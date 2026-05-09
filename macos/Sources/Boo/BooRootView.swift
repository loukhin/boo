import AppKit
import SwiftUI
import GhosttyKit

// Bonsplit is vendored in macos/Sources/Bonsplit — same target, no import.

/// Top-level SwiftUI content of a Boo window.
///
/// Each Bonsplit tab hosts a ghostty surface via `Ghostty.SurfaceWrapper`,
/// which is the same wrapper used by upstream ghostty's `TerminalView`. Using
/// the upstream wrapper gives us correct sizing (its `GeometryReader`-driven
/// Metal surface plumbing is battle-tested) while Boo keeps pane focus in sync
/// from the underlying AppKit surface focus callback (`SurfaceView.focusDidChange`).
struct BooRootView: View {
    @ObservedObject var state: BooState

    var body: some View {
        // Debug build warning now lives in the titlebar as a pill
        // (see `BooDebugPill` / `BooController.configureWindow`). The old
        // inline banner used to sit above the Bonsplit view here.
        HStack(spacing: 0) {
            if state.isWorkspaceSidebarVisible {
                BooWorkspaceSidebar(state: state)
            }

            ZStack {
                ForEach(state.workspaces.filter { state.isWorkspaceMounted($0.id) }) { workspace in
                    workspaceView(workspace)
                        .opacity(workspace.id == state.activeWorkspaceId ? 1 : 0)
                        .allowsHitTesting(workspace.id == state.activeWorkspaceId)
                        .accessibilityHidden(workspace.id != state.activeWorkspaceId)
                        .zIndex(workspace.id == state.activeWorkspaceId ? 1 : 0)
                }
            }
        // No outer click-to-focus gesture here. Surface clicks are handled
        // by AppKit at the real terminal NSView level, and Boo syncs Bonsplit
        // focus from that source-of-truth callback. Bonsplit's own delegate
        // chain (`didSplitPane`, `didClosePane`, `didSelectTab`) handles the
        // explicit restore paths after structural changes.
        }
        // SurfaceWrapper needs the ghostty app as an @EnvironmentObject
        // for config access (split dimming, resize overlay, etc.).
        .environmentObject(state.ghostty)
        .environment(\.terminalBackgroundColor, state.terminalBackgroundColor)
        .environment(\.isWindowKey, state.isWindowKey)
        .frame(minWidth: 600, minHeight: 400)
    }

    private func workspaceView(_ workspace: BooWorkspace) -> some View {
        BonsplitView(
            controller: workspace.controller,
            // During a divider drag the SwiftUI gesture steals first-responder
            // from whichever ghostty surface currently had it (the surface's
            // tracking areas see the drag as a mouse event in a different
            // view). We can't keep focus *through* the drag without deeper
            // surface-level surgery, so we just push it back when the drag
            // ends — same net result from the user's perspective.
            onDividerDragEnd: { [weak state] in
                guard state?.activeWorkspaceId == workspace.id else { return }
                state?.focusCurrentTabSurface()
            },
            content: { tab, paneId in
                // Computed here so the body re-evaluates when Bonsplit's
                // PaneState (@Published selectedTabId) changes — that's our
                // hook for "user clicked a tab in the tab bar", since
                // Bonsplit's didSelectTab delegate does NOT fire for tab-bar
                // clicks (it only fires for programmatic selection).
                let isSelected = workspace.controller.selectedTab(inPane: paneId)?.id == tab.id

                if let surface = state.surfaces[tab.id] {
                    BooSurfaceContainer(
                        surface: surface,
                        isSelected: isSelected
                    )
                    // NOTE: we intentionally do NOT use `.id(surface)` here.
                    // With `keepAllAlive` mode, tabs live in ForEach inside
                    // different pane ZStacks. When a tab moves between panes,
                    // SwiftUI's view identity reconciliation with `.id()` gets
                    // confused and can leave views unmounted. Without `.id()`,
                    // SwiftUI recreates the wrapper on reparent, but the
                    // underlying SurfaceView NSView reattaches correctly since
                    // it's passed by reference.
                } else {
                    BooTabPlaceholder(title: tab.title)
                }
            }
        )
    }
}

private struct BooWorkspaceSidebar: View {
    @ObservedObject var state: BooState
    @State private var hoveredWorkspaceId: WorkspaceID?
    @State private var hoveredCloseWorkspaceId: WorkspaceID?
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var canScrollUp: Bool {
        scrollOffset > 1
    }

    private var canScrollDown: Bool {
        contentHeight > viewportHeight && scrollOffset < contentHeight - viewportHeight - 1
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        BooSidebarWindowDragZoneView()
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(state.workspaces) { workspace in
                                workspaceRow(workspace: workspace)
                                    .id(workspace.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .background(
                        GeometryReader { contentGeometry in
                            Color.clear
                                .onChange(
                                    of: contentGeometry.frame(in: .named("workspaceSidebarScroll"))
                                ) { _, newFrame in
                                    scrollOffset = -newFrame.minY
                                    contentHeight = newFrame.height
                                }
                                .onAppear {
                                    let frame = contentGeometry.frame(in: .named("workspaceSidebarScroll"))
                                    scrollOffset = -frame.minY
                                    contentHeight = frame.height
                                }
                        }
                    )
                }
                .coordinateSpace(name: "workspaceSidebarScroll")
                .mask(sidebarScrollMask)
                .scrollIndicators(.automatic)
                .scrollClipDisabled(false)
                .onAppear {
                    viewportHeight = geometry.size.height
                    scrollToActiveWorkspace(with: proxy, animated: false)
                }
                .onChange(of: geometry.size.height) { _, newHeight in
                    viewportHeight = newHeight
                }
                .onChange(of: state.activeWorkspaceId) { _, _ in
                    scrollToActiveWorkspace(with: proxy)
                }
            }
        }
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(state.terminalBackgroundColor)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: TabBarMetrics.dividerThickness)
        }
    }

    @ViewBuilder
    private var sidebarScrollMask: some View {
        let fadeHeight: CGFloat = 24

        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: canScrollUp ? fadeHeight : 0)

            Rectangle().fill(Color.black)

            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: canScrollDown ? fadeHeight : 0)
        }
    }

    private func workspaceRow(workspace: BooWorkspace) -> some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            Text(state.workspaceDisplayTitle(workspace))
                .font(.system(size: TabBarMetrics.titleFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(workspaceRowTextColor(for: workspace))

            Button {
                state.closeWorkspace(workspace.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                    .foregroundStyle(workspaceRowCloseIconColor(for: workspace))
                    .frame(
                        width: TabBarMetrics.closeButtonSize,
                        height: TabBarMetrics.closeButtonSize
                    )
                    .background(
                        Circle()
                            .fill(
                                hoveredCloseWorkspaceId == workspace.id ?
                                    TabBarColors.hoveredTabBackground :
                                    .clear
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                hoveredCloseWorkspaceId = isHovered ? workspace.id : nil
            }
            .help("Close Workspace")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, TabBarMetrics.tabHorizontalPadding)
        .padding(.trailing, TabBarMetrics.tabTrailingPadding)
        .padding(.vertical, 6)
        .background(
            workspaceRowBackground(for: workspace),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.switchToWorkspace(workspace.id)
        }
        .onHover { isHovered in
            hoveredWorkspaceId = isHovered ? workspace.id : nil
        }
        .animation(.easeInOut(duration: 0.08), value: hoveredWorkspaceId)
        .contextMenu {
            Button("Rename…") {
                state.renameWorkspace(workspace.id)
            }
        }
    }

    private func workspaceRowBackground(for workspace: BooWorkspace) -> Color {
        if workspace.id == state.activeWorkspaceId {
            return Color.accentColor
        }

        if hoveredWorkspaceId == workspace.id {
            return Color.primary.opacity(0.07)
        }

        return Color.clear
    }

    private func workspaceRowTextColor(for workspace: BooWorkspace) -> Color {
        if workspace.id == state.activeWorkspaceId {
            return Color(nsColor: .alternateSelectedControlTextColor)
        }

        return TabBarColors.inactiveText
    }

    private func workspaceRowCloseIconColor(for workspace: BooWorkspace) -> Color {
        if workspace.id == state.activeWorkspaceId {
            return Color(nsColor: .alternateSelectedControlTextColor)
        }

        if hoveredCloseWorkspaceId == workspace.id {
            return TabBarColors.activeText
        }

        return TabBarColors.inactiveText
    }

    private func scrollToActiveWorkspace(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let activeWorkspaceId = state.activeWorkspaceId else { return }

        let scroll = {
            proxy.scrollTo(activeWorkspaceId, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.2), scroll)
        } else {
            scroll()
        }
    }
}

@discardableResult
private func performBooSidebarWindowDragOrDoubleClick(window: NSWindow?, event: NSEvent) -> Bool {
    guard let window else { return false }

    if event.clickCount >= 2 {
        let action = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        default:
            window.zoom(nil)
        }
        return true
    }

    let wasMovable = window.isMovable
    window.isMovable = true
    window.performDrag(with: event)
    window.isMovable = wasMovable
    return true
}

private struct BooSidebarWindowDragZoneView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragZoneNSView {
        DragZoneNSView()
    }

    func updateNSView(_ nsView: DragZoneNSView, context: Context) {}

    final class DragZoneNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            if !performBooSidebarWindowDragOrDoubleClick(window: window, event: event) {
                super.mouseDown(with: event)
            }
        }
    }
}

/// Wraps a single ghostty surface for one tab. Uses upstream
/// `Ghostty.SurfaceWrapper` so we inherit its correct Metal-surface sizing
/// and SwiftUI focus machinery.
private struct BooSurfaceContainer: View {
    let surface: Ghostty.SurfaceView
    let isSelected: Bool

    var body: some View {
        // NOTE: We intentionally do NOT auto-focus when isSelected changes.
        // During tab drag operations, the source pane auto-selects a
        // remaining tab which would steal focus from the target pane.
        // Focus is managed explicitly via focusSurface() calls.
        //
        // Important: no SwiftUI TapGesture here. In nested split layouts
        // the wrapper gesture proved unreliable: the terminal under the
        // mouse could gain AppKit focus while a sibling wrapper received
        // the SwiftUI tap event. Boo now syncs Bonsplit pane focus from
        // `SurfaceView.focusDidChange(_:)`, i.e. from the actual NSView
        // that became first responder.
        Ghostty.SurfaceWrapper(
            surfaceView: surface,
            isSplit: true,
            showsGrabHandle: false
        )
    }
}

/// Fallback shown only if a tab has no surface yet (shouldn't happen in
/// normal flow, but useful while ghostty is still initializing).
private struct BooTabPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.monospaced())
            Text("waiting for ghostty runtime\u{2026}")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

