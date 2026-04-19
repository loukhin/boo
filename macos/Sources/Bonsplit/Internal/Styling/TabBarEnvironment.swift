import SwiftUI

/// Environment key for the terminal background color
private struct TerminalBackgroundColorKey: EnvironmentKey {
    static let defaultValue: Color = Color(nsColor: .windowBackgroundColor)
}

extension EnvironmentValues {
    var terminalBackgroundColor: Color {
        get { self[TerminalBackgroundColorKey.self] }
        set { self[TerminalBackgroundColorKey.self] = newValue }
    }
}
