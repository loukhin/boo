import SwiftUI
import GhosttyKit
import Combine

/// A view that displays the Boo app icon.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 128)
            .accessibilityLabel("Boo Application Icon")
    }
}
