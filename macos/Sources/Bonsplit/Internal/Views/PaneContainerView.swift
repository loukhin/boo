import SwiftUI
import UniformTypeIdentifiers

/// Drop zone positions for creating splits
enum DropZone: Equatable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }

    var insertsFirst: Bool {
        switch self {
        case .left, .top: return true
        default: return false
        }
    }
}

/// Container for a single pane with its tab bar and content area
struct PaneContainerView<Content: View>: View {
    @Environment(BonsplitController.self) private var bonsplitController

    @Bindable var pane: PaneState
    let contentBuilder: (TabItem, PaneID) -> Content
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    @State private var activeDropZone: DropZone?

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TabBarView(
                pane: pane,
                showSplitButtons: showSplitButtons
            )

            // Content area with drop zones
            contentAreaWithDropZones
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content Area with Drop Zones

    @ViewBuilder
    private var contentAreaWithDropZones: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                // Main content
                contentArea

                // Drop zones layer (above content, receives drops and taps)
                dropZonesLayer(size: size)

                // Visual placeholder (non-interactive)
                dropPlaceholder(for: activeDropZone, in: size)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            // Clear the placeholder whenever a drag session ends, even if
            // `dropExited` never fired on this pane (e.g. when the drop was
            // handled by a sibling tab bar, or when the overlay unmounted
            // because the drag session ended before AppKit delivered the
            // exit event). Without this, the blue zone overlay can get stuck
            // on screen after a tab drag.
            .onChange(of: TabDragSession.shared.tab == nil) { _, noDrag in
                if noDrag { activeDropZone = nil }
            }
        }
        .clipped()
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        // Empty panes are destroyed, so we always have at least one tab here.
        switch contentViewLifecycle {
        case .recreateOnSwitch:
            // Original behavior: only render selected tab
            if let selectedTab = pane.selectedTab {
                contentBuilder(selectedTab, pane.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .keepAllAlive:
            // macOS-like behavior: keep all tab views in hierarchy
            ZStack {
                ForEach(pane.tabs) { tab in
                    let isSelected = tab.id == pane.selectedTabId
                    contentBuilder(tab, pane.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Instant show/hide — no fade animation on tab switch.
                        .opacity(isSelected ? 1 : 0)
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(isSelected)
                        // AppKit drag-destination routing is independent of
                        // SwiftUI hit-testing; without disabling drops on
                        // inactive tabs, file drops would always land on the
                        // topmost SurfaceView in the ZStack instead of the
                        // selected one.
                        .environment(\.ghosttySurfaceAcceptsDrops, isSelected)
                }
            }
        }
    }

    // MARK: - Drop Zones Layer

    @ViewBuilder
    private func dropZonesLayer(size: CGSize) -> some View {
        // Single unified drop zone that determines zone based on position.
        //
        // Important: do NOT attach a tap handler here. This layer sits above
        // the pane content, and for AppKit-backed terminal surfaces that can
        // create confusing click-routing where the transparent overlay, the
        // terminal NSView, and any per-surface SwiftUI gesture all compete for
        // the same click. Keep this layer drop-only so surface clicks are owned
        // by the surface host instead of by an invisible full-pane overlay.
        // Only mount the drop-zone overlay while a Bonsplit tab drag is in
        // progress. When the overlay is present it registers an AppKit drag
        // destination on the pane, which (even when it only accepts
        // `.bonsplitTab`) shadows the terminal surface's own drag destination
        // below it — breaking Finder file drops into the terminal. So we
        // conditionally render it: no overlay = no registration.
        //
        // The session is process-wide, so during a drag every window mounts
        // its pane drop zones — that's what makes dropping a tab into
        // another window's splits possible.
        if TabDragSession.shared.tab != nil {
            Color.clear
                .onDrop(of: [.bonsplitTab], delegate: UnifiedPaneDropDelegate(
                    size: size,
                    pane: pane,
                    bonsplitController: bonsplitController,
                    activeDropZone: $activeDropZone
                ))
        }
    }

    // MARK: - Drop Placeholder

    @ViewBuilder
    private func dropPlaceholder(for zone: DropZone?, in size: CGSize) -> some View {
        let placeholderColor = Color.accentColor.opacity(0.25)
        let borderColor = Color.accentColor
        let padding: CGFloat = 4

        // Calculate frame based on zone
        let frame: CGRect = {
            switch zone {
            case .center, .none:
                return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
            case .left:
                return CGRect(x: padding, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
            case .right:
                return CGRect(x: size.width / 2, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
            case .top:
                return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height / 2 - padding)
            case .bottom:
                return CGRect(x: padding, y: size.height / 2, width: size.width - padding * 2, height: size.height / 2 - padding)
            }
        }()

        RoundedRectangle(cornerRadius: 8)
            .fill(placeholderColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 2)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .opacity(zone != nil ? 1 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: zone)
    }

}

// MARK: - Unified Pane Drop Delegate

struct UnifiedPaneDropDelegate: DropDelegate {
    let size: CGSize
    let pane: PaneState
    let bonsplitController: BonsplitController
    @Binding var activeDropZone: DropZone?

    // Calculate zone based on position within the view
    private func zoneForLocation(_ location: CGPoint) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        // Check edges first (left/right take priority at corners)
        if location.x < horizontalEdge {
            return .left
        } else if location.x > size.width - horizontalEdge {
            return .right
        } else if location.y < verticalEdge {
            return .top
        } else if location.y > size.height - verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zoneForLocation(info.location)
        activeDropZone = nil

        // Use the shared drag session directly (faster than async
        // NSItemProvider, and it works across windows).
        let session = TabDragSession.shared
        guard let draggedTab = session.tab,
              let sourceId = session.sourcePaneId,
              let sourceController = session.sourceController else {
            return false
        }
        session.end()

        // Tab came from a different controller (typically another window's
        // Bonsplit). Content is host-owned, so hand the transfer to the host.
        guard sourceController === bonsplitController else {
            let destination: TabTransferDestination
            if let orientation = zone.orientation {
                destination = .split(
                    pane: pane.id,
                    orientation: orientation,
                    insertFirst: zone.insertsFirst
                )
            } else {
                destination = .insert(pane: pane.id, index: nil)
            }
            return bonsplitController.requestTabTransfer(
                Tab(from: draggedTab),
                from: sourceController,
                sourcePane: sourceId,
                to: destination
            )
        }

        if zone == .center {
            // Drop in center - move tab to this pane
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                bonsplitController.moveTab(
                    Tab(from: draggedTab),
                    from: sourceId,
                    to: pane.id,
                    atIndex: nil
                )
            }
        } else if let orientation = zone.orientation {
            // Drop on edge - create a split with the moved tab.
            // Routes through public API so proper delegate callbacks
            // fire (didSplitPane, didClosePane if source empties, etc).
            let tabToMove = Tab(from: draggedTab)
            let targetPaneId = pane.id
            let insertFirst = zone.insertsFirst
            _ = bonsplitController.splitPaneWithMovedTab(
                tabToMove,
                from: sourceId,
                targetPaneId: targetPaneId,
                orientation: orientation,
                insertFirst: insertFirst
            )
        }

        return true
    }

    func dropEntered(info: DropInfo) {
        activeDropZone = zoneForLocation(info.location)
    }

    func dropExited(info: DropInfo) {
        activeDropZone = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Only update drop zone if there's an active drag. After performDrop
        // ends the drag session, we ignore further updates to prevent the
        // overlay from appearing on newly created panes during view
        // restructuring.
        if TabDragSession.shared.tab != nil {
            activeDropZone = zoneForLocation(info.location)
        }
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.bonsplitTab])
    }
}
