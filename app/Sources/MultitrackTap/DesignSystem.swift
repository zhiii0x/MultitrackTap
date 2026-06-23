import SwiftUI

/// The shared visual language for Multitrack Tap.
///
/// One place to keep the palette, surface (card) treatment, and window
/// background cohesive across the record window, the recordings window, and the
/// settings panel — so the whole app reads as a single, crafted product rather
/// than a collection of differently-styled screens.
///
/// Design language: **Premium** — elegant, minimal, sophisticated. Signature
/// easing `cubic-bezier(0.4, 0, 0.2, 1)`, 350–450 ms transitions, no overshoot.
/// Everything is derived from semantic / material colors + opacities so it holds
/// up in both light and dark mode.
enum Theme {
    /// Signature easing for view transitions (idle ↔ recording, summary in/out).
    static func transition(_ duration: Double = 0.4) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }

    /// Press micro-interaction — quick, no bounce.
    static let press = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.12)

    /// The one confident accent used for selection and affordances. A refined
    /// indigo-violet that reads more premium than stock system blue while keeping
    /// strong contrast in both appearances. (Red stays reserved for record.)
    static let accent = Color(red: 0.40, green: 0.36, blue: 0.92)

    /// Record / recording. Reserved exclusively for the live state.
    static let record = Color(red: 0.95, green: 0.26, blue: 0.21)
}

// MARK: - Typography

extension View {
    /// The consistent section-label style: a small, wide-tracked, uppercased
    /// caption in secondary color — the "small caps"-ish label used above cards
    /// and card sections so the hierarchy reads the same everywhere.
    func sectionLabel() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Premium surface (card) treatment

extension View {
    /// The signature card surface: a glass (macOS 26) / material backing with a
    /// **hairline border**, a subtle **top inner highlight** (a thin lighter
    /// line along the top edge), and a **soft drop shadow** to lift the card off
    /// the window. An optional `tint` warms the surface (used for the recording
    /// clock).
    ///
    /// Replaces the old `glassOrMaterial`. All callers route through here so the
    /// depth treatment stays identical everywhere.
    @ViewBuilder
    func premiumCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .background(cardBacking(shape: shape, tint: tint))
            // Hairline rim — a touch brighter than the inner highlight so edges
            // stay crisp against the window.
            .overlay(
                shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .blendMode(.plusLighter))
            // Top inner highlight: a thin lit edge only along the top, fading out
            // quickly, for a "catching the light" feel.
            .overlay(
                shape
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.30), .clear],
                            startPoint: .top,
                            endPoint: .center),
                        lineWidth: 1)
                    .blendMode(.plusLighter)
                    .padding(0.5)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .center)))
            // Soft drop shadow to float the card.
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
            .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func cardBacking(shape: RoundedRectangle, tint: Color?) -> some View {
        // `glassEffect` exists only in the macOS 26 SDK, so REFERENCE it only when
        // compiling with a toolchain that ships it (Swift 6.2 = Xcode 26). Older
        // Xcode (<= 16) compiles the #else branch and never sees the symbol, so
        // the app still builds there. The inner `if #available` is the separate
        // RUNTIME gate: a 26-SDK build still falls back to material on 14.4–25.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                Color.clear.glassEffect(.regular.tint(tint.opacity(0.20)), in: shape)
            } else {
                Color.clear.glassEffect(.regular, in: shape)
            }
        } else {
            materialBacking(shape: shape, tint: tint)
        }
        #else
        materialBacking(shape: shape, tint: tint)
        #endif
    }

    /// The pre-glass material backing — used on macOS < 26, and whenever the app
    /// is built with a toolchain older than the macOS 26 SDK.
    @ViewBuilder
    private func materialBacking(shape: RoundedRectangle, tint: Color?) -> some View {
        if let tint {
            shape.fill(.regularMaterial)
                .overlay(shape.fill(tint.opacity(0.16)))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

// MARK: - Window background

/// A very subtly lifted vertical window background: slightly brighter at the top
/// fading to the base window color at the bottom, for richness instead of a flat
/// fill. Tasteful — barely perceptible — and derived from semantic colors so it
/// works in both light and dark mode. An optional accent/record wash warms the
/// very top to orient the eye toward "live" state.
struct WindowBackground: View {
    /// When true, the top wash warms to the record color; otherwise a faint
    /// accent. `nil` for windows with no live state (history, settings).
    var recording: Bool?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Base: the standard window material so it always looks native.
            Rectangle().fill(.background)

            // Subtle top-to-bottom lift: a hair lighter up top.
            LinearGradient(
                colors: [
                    Color.primary.opacity(scheme == .dark ? 0.05 : 0.03),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .center)

            // Ambient state wash at the very top.
            if let recording {
                LinearGradient(
                    colors: [
                        (recording ? Theme.record : Theme.accent)
                            .opacity(recording ? 0.12 : 0.06),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .center)
                    .animation(Theme.transition(0.45), value: recording)
            }
        }
        .ignoresSafeArea()
    }
}
