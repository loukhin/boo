import SwiftUI

/// Draws a `TabStatusIndicator`: a symbol if it has one, otherwise a dot,
/// with an optional progress ring. Always occupies the same square frame.
struct TabStatusIndicatorView: View {
    let indicator: TabStatusIndicator

    private var color: Color {
        TabBarColors.statusIndicator(indicator.style)
    }

    var body: some View {
        ZStack {
            if let symbol = indicator.symbol {
                Image(systemName: symbol)
                    .font(.system(size: TabBarMetrics.statusIndicatorSymbolSize, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(
                        width: TabBarMetrics.statusIndicatorSize,
                        height: TabBarMetrics.statusIndicatorSize
                    )
            }

            if let progress = indicator.progress, indicator.symbol == nil {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: TabBarMetrics.statusIndicatorRingWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: TabBarMetrics.statusIndicatorRingWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(
            width: TabBarMetrics.statusIndicatorFrame,
            height: TabBarMetrics.statusIndicatorFrame
        )
        .animation(.easeInOut(duration: 0.2), value: indicator.progress)
        .modifier(StatusBreathing(isActive: indicator.style == .active))
        .accessibilityHidden(true)
    }
}

/// Slowly fades in-progress marks in and out so a running tab reads as
/// alive. Other states stay still. Off when Reduce Motion is enabled.
private struct StatusBreathing: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var animates: Bool { isActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(animates && dimmed ? 0.35 : 1)
            .onAppear(perform: sync)
            .onChange(of: animates) { _, _ in sync() }
    }

    private func sync() {
        guard animates else {
            // Stop without animating back; opacity is already 1 because
            // `animates` is false.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}
