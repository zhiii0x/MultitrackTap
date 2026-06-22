import SwiftUI

/// A horizontal audio level meter driven by a 0...1 value.
///
/// Visual craft:
///   - A subtly **inset track**: a hairline-bordered capsule filled with a
///     faint primary tint, so the bar reads as sitting *in* a recessed channel
///     rather than floating on a flat gray pill.
///   - A smooth **gradient fill** (green → amber → red, perceptual stops) with
///     fully rounded ends, plus a thin top **sheen** highlight so the bar has a
///     glassy, lit-from-above feel.
///   - The existing **fast-attack / slow-release** smoothing and a refined
///     **peak-hold tick** (a bright, thin vertical line that snaps to the loudest
///     recent value and decays slowly, like a hardware meter).
///   - A soft **bloom/glow** when the signal is hot: a color-matched shadow whose
///     radius and opacity scale with level. Gated OFF under reduce-motion.
///
/// The `level: Float` input stays the single source of truth; smoothing,
/// peak-hold, and bloom intensity are view-local `@State` so the view model
/// stays simple. Per-frame work is kept cheap (a couple of shapes + one shadow)
/// because these meters redraw constantly while recording.
struct LevelMeter: View {
    /// Current level, 0...1. Values outside the range are clamped.
    var level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Smoothed display level (attack/release applied), 0...1.
    @State private var displayLevel: CGFloat = 0
    /// Peak-hold value, 0...1; jumps to the max and decays slowly.
    @State private var peak: CGFloat = 0

    // Tuning. Attack is fast so transients pop; release is slower so the bar
    // settles musically. Peak holds, then bleeds off gently.
    private let attack: CGFloat = 0.55   // fraction of the gap closed per tick rising
    private let release: CGFloat = 0.14  // fraction closed per tick falling
    private let peakDecay: CGFloat = 0.012

    private let barHeight: CGFloat = 9

    var body: some View {
        let target = CGFloat(max(0, min(level, 1)))
        let active = displayLevel > 0.01
        // Bloom strengthens as the signal climbs into the hot zone.
        let bloom = max(0, displayLevel - 0.45) / 0.55  // 0 below ~0.45, →1 at clip

        return GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * displayLevel)

            ZStack(alignment: .leading) {
                // Inset track: a recessed channel with a hairline rim.
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))

                // Filled level: rounded gradient bar with a glassy top sheen and
                // a level-scaled color bloom (reduce-motion safe).
                Capsule()
                    .fill(meterGradient)
                    .overlay(
                        // Thin top highlight so the bar reads lit-from-above.
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .clear],
                                    startPoint: .top,
                                    endPoint: .center))
                            .padding(0.5)
                            .blendMode(.plusLighter)
                            .opacity(active ? 1 : 0.4))
                    .frame(width: fillWidth)
                    .opacity(active ? 1.0 : 0.5)
                    .shadow(
                        color: bloomColor.opacity(reduceMotion ? 0 : Double(bloom) * 0.55),
                        radius: reduceMotion ? 0 : 2 + bloom * 6)

                // Peak-hold tick: a bright, thin vertical marker that snaps to the
                // loudest recent value and decays slowly.
                if peak > 0.02 {
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: barHeight)
                        .offset(x: min(geo.size.width - 2,
                                       max(0, geo.size.width * peak - 1)))
                        .blendMode(.plusLighter)
                        .shadow(color: bloomColor.opacity(reduceMotion ? 0 : 0.5),
                                radius: reduceMotion ? 0 : 2)
                }
            }
            .animation(.easeOut(duration: 0.09), value: displayLevel)
            .animation(.linear(duration: 0.05), value: peak)
        }
        .frame(height: barHeight)
        // The metering callbacks fire often while recording; each new value is
        // folded into the smoothed display level with asymmetric attack/release.
        .onChange(of: target) { _, newValue in
            advance(to: newValue)
        }
        // A steady timeline so the bar releases and the peak decays even when
        // the input value stops arriving (e.g. signal goes silent).
        .background(decayDriver(target: target))
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(target * 100)) percent")
    }

    /// The bloom/peak glow color, tracking the perceptual zone the level sits in:
    /// green when nominal, warming to red as it approaches clip.
    private var bloomColor: Color {
        if displayLevel > 0.92 { return .red }
        if displayLevel > 0.82 { return .orange }
        return .green
    }

    /// Folds a freshly arrived target into the smoothed display level and
    /// updates the peak-hold value.
    private func advance(to target: CGFloat) {
        if target > displayLevel {
            displayLevel += (target - displayLevel) * attack
        } else {
            displayLevel += (target - displayLevel) * release
        }
        if target > peak { peak = target }
    }

    /// An invisible TimelineView that keeps releasing the bar and decaying the
    /// peak between input updates, so a falling signal animates smoothly even
    /// when no new level values arrive.
    private func decayDriver(target: CGFloat) -> some View {
        // Pause the per-frame timeline once the bar and peak have settled and no
        // signal is arriving. `TimelineView(.animation)` otherwise ticks every
        // display frame FOREVER while on screen — several idle meters then peg a
        // CPU core (~26% measured with just the mic + system meters), starving the
        // main thread and making the whole UI unresponsive on slower Macs. At rest
        // there is nothing to animate, so pausing costs nothing; a rising `target`
        // (new level arriving) re-evaluates the body and un-pauses it instantly.
        let atRest = displayLevel <= 0.001 && peak <= 0.02 && target <= 0.001
        // Cap at 30fps. `.animation` defaults to the display's full refresh rate
        // (60/120Hz); a level meter doesn't need that, and at full rate each tick
        // rebuilds the whole gradient/shadow capsule's DisplayList — several live
        // meters then saturate the main thread. 30fps stays visually smooth at a
        // fraction of the cost.
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: atRest)) { context in
            Color.clear
                .onChange(of: context.date) { _, _ in
                    // Release toward the current target.
                    if displayLevel > target {
                        displayLevel += (target - displayLevel) * release
                        if displayLevel < 0.001 { displayLevel = 0 }
                    }
                    // Bleed the peak down toward the current display level.
                    if peak > displayLevel {
                        peak = max(displayLevel, peak - peakDecay)
                    }
                }
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.20, green: 0.80, blue: 0.45), location: 0.0),
                .init(color: Color(red: 0.20, green: 0.80, blue: 0.45), location: 0.62),
                .init(color: Color(red: 0.95, green: 0.80, blue: 0.25), location: 0.82),
                .init(color: Color(red: 0.98, green: 0.55, blue: 0.15), location: 0.92),
                .init(color: Color(red: 0.95, green: 0.26, blue: 0.21), location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing)
    }
}
