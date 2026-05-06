import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Displays the app's actual bundle icon instead of a separate image asset.
///
/// On macOS this keeps in-app icon previews in sync with the primary app icon
/// generated from `images/Boo.icon`.
struct AppIconView: View {
    var body: some View {
        #if canImport(AppKit)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
        #else
        Image(systemName: "terminal")
            .resizable()
        #endif
    }
}
