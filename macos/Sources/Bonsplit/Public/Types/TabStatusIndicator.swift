import Foundation

/// A transient status mark shown in front of a tab's title.
///
/// The style is semantic so Bonsplit owns the colors. Indicators are not
/// part of `BonsplitRestorableState`; consumers re-derive them from live
/// state after restoration.
public struct TabStatusIndicator: Hashable, Codable, Sendable {
    public enum Style: String, Hashable, Codable, Sendable {
        /// Something is running.
        case active
        /// The tab needs the user to do something.
        case attention
        /// Something finished that the user hasn't looked at yet.
        case success
        /// Something failed.
        case failure
    }

    public var style: Style

    /// An SF Symbol drawn instead of the plain dot, for example to say
    /// what kind of attention is needed.
    public var symbol: String?

    /// Completion from 0 to 1, drawn as a ring around the dot. Nil when
    /// there's no meaningful percentage.
    public var progress: Double?

    /// Tooltip and accessibility text describing the status.
    public var help: String?

    public init(
        style: Style,
        symbol: String? = nil,
        progress: Double? = nil,
        help: String? = nil
    ) {
        self.style = style
        self.symbol = symbol
        self.progress = progress.map { min(max($0, 0), 1) }
        self.help = help
    }
}
