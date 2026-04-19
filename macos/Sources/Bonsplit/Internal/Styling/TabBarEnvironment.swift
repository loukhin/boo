import SwiftUI

/// Environment key for the terminal background color
private struct TerminalBackgroundColorKey: EnvironmentKey {
    static let defaultValue: Color = Color(nsColor: .windowBackgroundColor)
}

/// Environment key for whether the window is key (active)
private struct IsWindowKeyEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var terminalBackgroundColor: Color {
        get { self[TerminalBackgroundColorKey.self] }
        set { self[TerminalBackgroundColorKey.self] = newValue }
    }

    var isWindowKey: Bool {
        get { self[IsWindowKeyEnvironmentKey.self] }
        set { self[IsWindowKeyEnvironmentKey.self] = newValue }
    }
}
