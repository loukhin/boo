import Foundation

/// Represents a tab's metadata (read-only snapshot for library consumers)
public struct Tab: Identifiable, Hashable, Sendable {
    public let id: TabID
    public let title: String
    public let icon: String?
    public let isDirty: Bool
    public let statusIndicator: TabStatusIndicator?

    public init(
        id: TabID = TabID(),
        title: String,
        icon: String? = nil,
        isDirty: Bool = false,
        statusIndicator: TabStatusIndicator? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isDirty = isDirty
        self.statusIndicator = statusIndicator
    }

    internal init(from tabItem: TabItem) {
        self.id = TabID(id: tabItem.id)
        self.title = tabItem.title
        self.icon = tabItem.icon
        self.isDirty = tabItem.isDirty
        self.statusIndicator = tabItem.statusIndicator
    }

    /// The internal representation, carrying every field across moves.
    internal var tabItem: TabItem {
        TabItem(
            id: id.id,
            title: title,
            icon: icon,
            isDirty: isDirty,
            statusIndicator: statusIndicator
        )
    }
}
