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
        .accessibilityHidden(true)
    }
}
