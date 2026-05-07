import SwiftUI
import AppKit

/// Pure SwiftUI recursive split container.
///
/// Renders two children (pane or nested split) side-by-side (horizontal) or
/// stacked (vertical) with a draggable divider in between.
///
/// ## Why pure SwiftUI instead of NSSplitView
///
/// The previous implementation wrapped an `NSSplitView` in an
/// `NSViewRepresentable`. That worked, but had a nasty interaction with heavy
/// `NSView` leaves (in Boo's case, ghostty's `SurfaceView` with its live
/// Metal layer): when the split tree restructured (e.g., a nested split
/// collapsed into a single pane), SwiftUI's reconciler tore down the
/// `NSViewRepresentable` subtree and our surfaces lost their parent chain,
/// causing a visible blank flash while Metal reattached.
///
/// By recursing in pure SwiftUI and letting the `NSViewRepresentable` boundary
/// live only at the *leaf* (around `SurfaceView`), restructuring higher in the
/// tree no longer tears down those leaves — their `NSView`s stay parented and
/// Metal keeps drawing.
///
/// Layout is modeled after ghostty's `SplitView` (see
/// `macos/Sources/Features/Splits/SplitView.swift`): a `GeometryReader` reads
/// the container size, rect math converts the 0…1 `dividerPosition` into
/// concrete frames for each child, and a draggable divider lives as a sibling
/// in the same `ZStack`.
struct SplitContainerView<Content: View>: View {
    @Bindable var splitState: SplitState
    let controller: SplitViewController
    let contentBuilder: (TabItem, PaneID) -> Content
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    /// Callback invoked when geometry changes. `isDragging` is true while the
    /// user is actively dragging the divider, false otherwise.
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    /// Callback invoked once when the user finishes dragging the divider.
    /// Used by hosts that need to restore focus to a child (e.g., Boo pushing
    /// first-responder back into a ghostty surface after the drag steals it).
    var onDividerDragEnd: (() -> Void)?

    /// Whether the entry animation has already run for this split. Using
    /// `@State` ensures we only slide in once per view lifetime.
    @State private var didRunEntryAnimation = false
    @State private var isDragging = false

    // Divider sizing. The visible line is 1pt (matching NSSplitView `.thin`);
    // the invisible grab area around it widens the hitbox so the divider is
    // easy to grab without growing the visual thickness.
    private let visibleThickness: CGFloat = TabBarMetrics.dividerThickness
    private let invisiblePadding: CGFloat = 6
    private var hitboxThickness: CGFloat { visibleThickness + invisiblePadding }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let leftRect = leftRect(for: size)
            let rightRect = rightRect(for: size, leftRect: leftRect)
            let splitterCenter = splitterPoint(for: size, leftRect: leftRect)

            // We deliberately use HStack / VStack instead of ZStack +
            // `.offset` here. `.offset` only shifts rendering, not the
            // view's layout frame, so children of a ZStack whose offset
            // puts them side-by-side still share an origin-anchored
            // layout frame. That means their *hit-test* regions overlap:
            // clicking a nested-pane surface could hit either sibling,
            // and SwiftUI's resolution isn't always stable across
            // re-renders. With deep splits this manifests as focus
            // oscillating between two adjacent panes on click.
            //
            // HStack/VStack places children with real, non-overlapping
            // layout bounds, which fixes hit testing and makes focus
            // routing deterministic. The divider then sits in an
            // `.overlay` layer positioned precisely between them.
            Group {
                switch splitState.orientation {
                case .horizontal:
                    HStack(spacing: 0) {
                        firstNode
                            .frame(width: leftRect.width)
                        secondNode
                            .frame(width: rightRect.width)
                    }
                case .vertical:
                    VStack(spacing: 0) {
                        firstNode
                            .frame(height: leftRect.height)
                        secondNode
                            .frame(height: rightRect.height)
                    }
                }
            }
            .overlay(
                divider(in: size)
                    .position(splitterCenter)
                    .gesture(dragGesture(in: size))
                    .onTapGesture(count: 2) {
                        // NSSplitView had no built-in equalize; this matches
                        // ghostty's SplitView behavior and is a common UX
                        // convention.
                        withAnimation(.easeInOut(duration: 0.16)) {
                            splitState.dividerPosition = 0.5
                        }
                    }
            )
            .onAppear { runEntryAnimationIfNeeded() }
        }
    }

    // MARK: - Children

    private var firstNode: some View {
        SplitNodeView(
            node: splitState.first,
            contentBuilder: contentBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            onDividerDragEnd: onDividerDragEnd
        )
        .environment(controller)
    }

    private var secondNode: some View {
        SplitNodeView(
            node: splitState.second,
            contentBuilder: contentBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            onDividerDragEnd: onDividerDragEnd
        )
        .environment(controller)
    }

    // MARK: - Divider

    /// Divider needs explicit sizing on BOTH axes because it's positioned
    /// absolutely inside a `ZStack` via `.position`, which strips parent size
    /// proposals. Using `nil` for the long axis leaves the inner `Rectangle`
    /// without a height and it collapses to zero, making the divider
    /// invisible. We pull the long axis from the `GeometryReader`.
    @ViewBuilder
    private func divider(in size: CGSize) -> some View {
        let isHorizontal = splitState.orientation == .horizontal
        let longAxis = isHorizontal ? size.height : size.width

        ZStack {
            // Invisible hitbox: wider than the visible line so the divider is
            // easy to grab without bloating the visual. `.contentShape`
            // ensures the transparent rect is hit-testable.
            Color.clear
                .frame(
                    width: isHorizontal ? hitboxThickness : longAxis,
                    height: isHorizontal ? longAxis : hitboxThickness
                )
                .contentShape(Rectangle())
            // Visible 1pt line.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: isHorizontal ? visibleThickness : longAxis,
                    height: isHorizontal ? longAxis : visibleThickness
                )
        }
        // Use ghostty's Backport helper so we get the declarative
        // `pointerStyle` API on macOS 15+ and a no-op on older macOS. We
        // deliberately avoid `NSCursor.push/pop` here: the global cursor
        // stack is shared with `SurfaceView`, which pushes its own IBeam
        // cursor for text selection. Popping when hover ends can corrupt
        // that stack, leaving the terminal with an arrow cursor instead of
        // IBeam and flashing the wrong cursor while dragging the divider.
        //
        // Boo's deployment target is macOS 15+, so the backport's pre-15
        // fallback (no-op) is fine in practice; the divider just won't
        // change the cursor on <15.
        .backport.pointerStyle(isHorizontal ? .resizeLeftRight : .resizeUpDown)
    }

    // MARK: - Drag gesture

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    isDragging = true
                }
                let minPane: CGFloat
                let total: CGFloat
                let location: CGFloat

                switch splitState.orientation {
                case .horizontal:
                    minPane = TabBarMetrics.minimumPaneWidth
                    total = size.width
                    location = gesture.location.x
                case .vertical:
                    minPane = TabBarMetrics.minimumPaneHeight
                    total = size.height
                    location = gesture.location.y
                }

                guard total > 0 else { return }
                let clamped = max(minPane, min(location, total - minPane))
                splitState.dividerPosition = clamped / total
                onGeometryChange?(true)
            }
            .onEnded { _ in
                isDragging = false
                onGeometryChange?(false)
                onDividerDragEnd?()
            }
    }

    // MARK: - Entry animation

    /// Normalize a freshly-created split to its resting position.
    ///
    /// `SplitViewController` creates new splits with `dividerPosition` set to
    /// `0.0` or `1.0` (the edge) together with an `animationOrigin`, on the
    /// assumption that the view layer will animate the divider from that edge
    /// to a visible position. The previous NSSplitView-backed view did this
    /// by ignoring the controller's `dividerPosition` value entirely and
    /// hard-coding the target to `0.5` whenever an `animationOrigin` was
    /// present.
    ///
    /// We preserve that behavior here: if the split was born with an
    /// animation origin, snap the divider to `0.5` so both panes are visible.
    /// The slide-in animation itself is deferred (see note below) — for now
    /// new splits just pop into place at 50/50.
    ///
    /// An earlier version tried `dividerPosition = edge` then
    /// `withAnimation { dividerPosition = 0.5 }` inside a
    /// `DispatchQueue.main.async`, but SwiftUI coalesced the two writes into
    /// a single transaction and the divider stayed pinned at the edge.
    /// Reintroducing a real slide-in will likely need an explicit
    /// `Animatable` wrapper or a two-phase `.task` that awaits a frame
    /// between mutations.
    private func runEntryAnimationIfNeeded() {
        guard !didRunEntryAnimation else { return }
        didRunEntryAnimation = true

        guard splitState.animationOrigin != nil else { return }
        splitState.animationOrigin = nil
        splitState.dividerPosition = 0.5
    }

    // MARK: - Rect math
    //
    // Same scheme as ghostty's SplitView: allocate the first child based on
    // the fraction, subtract half the divider thickness so the divider sits
    // centered on the boundary, and give the rest to the second child.

    private func leftRect(for size: CGSize) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch splitState.orientation {
        case .horizontal:
            rect.size.width = max(0, size.width * splitState.dividerPosition - visibleThickness / 2)
        case .vertical:
            rect.size.height = max(0, size.height * splitState.dividerPosition - visibleThickness / 2)
        }
        return rect
    }

    private func rightRect(for size: CGSize, leftRect: CGRect) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch splitState.orientation {
        case .horizontal:
            rect.origin.x = leftRect.width + visibleThickness / 2
            rect.size.width = max(0, size.width - rect.origin.x)
        case .vertical:
            rect.origin.y = leftRect.height + visibleThickness / 2
            rect.size.height = max(0, size.height - rect.origin.y)
        }
        return rect
    }

    private func splitterPoint(for size: CGSize, leftRect: CGRect) -> CGPoint {
        switch splitState.orientation {
        case .horizontal:
            return CGPoint(x: leftRect.width + visibleThickness / 2, y: size.height / 2)
        case .vertical:
            return CGPoint(x: size.width / 2, y: leftRect.height + visibleThickness / 2)
        }
    }
}
