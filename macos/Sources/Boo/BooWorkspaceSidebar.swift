import AppKit
import SwiftUI

struct BooWorkspaceSidebar: View {
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
        HStack(alignment: .top, spacing: TabBarMetrics.contentSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.workspaceDisplayTitle(workspace))
                    .font(.system(size: TabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(workspaceRowTextColor(for: workspace))

                Text(state.workspaceDisplayPWD(workspace) ?? " ")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(workspaceRowPWDColor(for: workspace))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    private func workspaceRowPWDColor(for workspace: BooWorkspace) -> Color {
        if workspace.id == state.activeWorkspaceId {
            return Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)
        }

        return TabBarColors.inactiveText.opacity(0.75)
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
