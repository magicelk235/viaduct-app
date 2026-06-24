import SwiftUI
import Combine

// MARK: - Glass progress bar

/// Slim Liquid Glass progress track with a green fill that eases continuously
/// between coarse phase markers, plus a soft traveling shine for liveliness.
struct GlassProgressBar: View {
    var fraction: Double
    /// When true, the CLI has finished — race the bar to 100% quickly, then fire
    /// `onComplete` exactly once.
    var finishing: Bool = false
    var onComplete: (() -> Void)? = nil
    /// When set, the bar is cancellable: hovering reveals a stop affordance and
    /// clicking fires this. Disabled during the finishing race.
    var onCancel: (() -> Void)? = nil

    @State private var displayed: CGFloat = 0
    @State private var didComplete = false
    @State private var hovering = false

    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var cancellable: Bool { onCancel != nil && !finishing }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.clear
                    .liquidGlass(radius: Theme.Radius.full)
                    .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))

                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.Colors.accentGreen, Theme.Colors.accentGreen.opacity(0.85)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * displayed))
                    .overlay(ProgressShine().clipShape(Capsule()))
                    .shadow(color: Theme.Colors.accentGreen.opacity(0.5), radius: 6)
                    .opacity(showCancelUI ? 0.35 : 1)
            }
        }
        .frame(height: 8)
        .overlay(cancelOverlay)
        // A taller invisible hit area so the 8px bar is easy to hover/click.
        .contentShape(Rectangle().inset(by: -14))
        .onHover { h in
            guard cancellable else { return }
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        .onTapGesture { if cancellable { onCancel?() } }
        .help(cancellable ? "Cancel conversion" : "")
        .onAppear { displayed = CGFloat(fraction) }
        .onReceive(ticker) { _ in tick() }
    }

    private var showCancelUI: Bool { cancellable && hovering }

    @ViewBuilder
    private var cancelOverlay: some View {
        if showCancelUI {
            ZStack {
                Capsule().fill(Theme.Colors.accentRed)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: Theme.Colors.accentRed.opacity(0.5), radius: 6)
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Cancel")
                        .font(Theme.Font.caption().weight(.semibold))
                }
                .foregroundStyle(.white)
            }
            .frame(height: 22)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .allowsHitTesting(false)
        }
    }

    private func tick() {
        displayed = nextValue(from: displayed)
        // Once the bar lands at 100% during the finishing race, notify once.
        if finishing, !didComplete, displayed >= 0.999 {
            didComplete = true
            onComplete?()
        }
    }

    /// Per-tick easing with three feels:
    ///
    /// 0. **Finishing** (CLI already done): race the remaining distance to 100%
    ///    *fast* with a strong ease — the bar visibly accelerates to full, then
    ///    the flow opens the converted extension.
    /// 1. **Real phase ahead** (`fraction > displayed`): the conversion moved
    ///    faster than the bar — catch up *quickly* so a fast finish reads as fast.
    /// 2. **Bar ahead / waiting** (`fraction <= displayed`): the current phase is
    ///    taking longer than the bar's optimism — keep crawling, but *slower the
    ///    higher it climbs*, asymptoting toward a soft ceiling a little above the
    ///    real phase. It never freezes and never overruns by much, so it can't
    ///    sit dead at 90%.
    private func nextValue(from current: CGFloat) -> CGFloat {
        if finishing {
            // Strong ease straight to 100, with a floor so it never stalls.
            let next = current + (1 - current) * 0.22 + 0.01
            return min(next, 1)
        }

        let target = CGFloat(fraction)
        let gap = target - current

        if gap > 0.001 {
            // Fast catch-up when the real phase has outrun the bar.
            return min(current + gap * 0.28 + 0.002, 0.995)
        }

        // Waiting: crawl toward a ceiling just past the current phase.
        let ceiling = min(target + 0.06, 0.985)
        guard current < ceiling else { return current }

        // Creep decays quadratically with height → slower and slower near the top.
        let remaining = 1 - current
        let creep = 0.006 * remaining * remaining
        return min(current + max(creep, 0.0004), ceiling)
    }
}

/// Horizontal traveling shine over the progress fill.
private struct ProgressShine: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let period = 1.6
                let p = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.4)
                    .offset(x: -w * 0.4 + p * (w + w * 0.4))
                    .blendMode(.softLight)
            }
        }
        .allowsHitTesting(false)
    }
}
